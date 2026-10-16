import Foundation

/// Runs transfer jobs one at a time (MTP devices handle one request at a time; see docs/DECISIONS.md D3).
public actor TransferCoordinator {
    public private(set) var operations: [TransferOperation] = []
    private var queue: [(TransferOperation, DeviceSession)] = []
    private var running: (op: TransferOperation, task: Task<Void, Never>)?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var activeOperation: TransferOperation? { running?.op }

    public func enqueue(_ op: TransferOperation, session: DeviceSession) {
        if !operations.contains(where: { $0 === op }) { operations.append(op) }
        queue.append((op, session))
        startNextIfIdle()
    }

    /// Re-queues only the failed or cancelled items of a finished job. Returns false if nothing to retry.
    @discardableResult
    public func retry(_ op: TransferOperation, session: DeviceSession) -> Bool {
        guard running?.op !== op, !queue.contains(where: { $0.0 === op }) else { return false }
        guard op.prepareRetry() > 0 else { return false }
        enqueue(op, session: session)
        return true
    }

    public func cancel(_ op: TransferOperation) {
        op.cancel()
        queue.removeAll { $0.0 === op }
    }

    public func cancelAll() {
        for (op, _) in queue { op.cancel() }
        queue.removeAll()
        running?.op.cancel()
    }

    /// Removes finished jobs from the list.
    public func clearFinished() {
        operations.removeAll { $0.snapshot().phase.isFinished && $0 !== running?.op }
    }

    public func waitUntilIdle() async {
        if running == nil && queue.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func startNextIfIdle() {
        guard running == nil else { return }
        while let (op, session) = queue.first {
            queue.removeFirst()
            if op.snapshot().phase.isFinished { continue } // cancelled while queued
            let task = Task { [weak self] in
                await op.run(session: session)
                await self?.didFinish(op)
            }
            running = (op, task)
            return
        }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func didFinish(_ op: TransferOperation) {
        if running?.op === op { running = nil }
        startNextIfIdle()
    }
}
