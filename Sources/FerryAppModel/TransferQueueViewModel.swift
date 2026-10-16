import Foundation
import Observation
import FerryCore

/// A duplicate question waiting for the user.
public struct DuplicatePrompt: Identifiable, Sendable {
    public let id = UUID()
    public let conflict: DuplicateConflict
}

/// Bridges the transfer engine's duplicate questions to the UI. One question at a time.
public final class PromptingDuplicateResolver: DuplicateResolver, @unchecked Sendable {
    private let present: @MainActor @Sendable (DuplicatePrompt, @escaping @MainActor (DuplicateDecision?) -> Void) -> Void

    public init(present: @escaping @MainActor @Sendable (DuplicatePrompt, @escaping @MainActor (DuplicateDecision?) -> Void) -> Void) {
        self.present = present
    }

    public func resolve(_ conflict: DuplicateConflict) async -> DuplicateDecision? {
        let answer = OneShotAnswer()
        let present = self.present
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<DuplicateDecision?, Never>) in
                guard answer.install(continuation) else {
                    continuation.resume(returning: nil) // cancelled before the question was shown
                    return
                }
                Task { @MainActor in
                    present(DuplicatePrompt(conflict: conflict)) { decision in answer.finish(decision) }
                }
            }
        } onCancel: {
            answer.finish(nil)
        }
    }
}

/// Resumes a continuation exactly once, whichever comes first: the user's answer or cancellation.
private final class OneShotAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DuplicateDecision?, Never>?
    private var done = false

    func install(_ c: CheckedContinuation<DuplicateDecision?, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        continuation = c
        return true
    }

    func finish(_ decision: DuplicateDecision?) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: decision)
    }
}

/// One row in the transfer panel.
public struct TransferRow: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let destination: URL
    public var snapshot: TransferSnapshot
}

@MainActor @Observable
public final class TransferQueueViewModel {
    public private(set) var rows: [TransferRow] = []
    /// The duplicate question currently shown, if any.
    public private(set) var duplicatePrompt: DuplicatePrompt?

    @ObservationIgnored public let coordinator = TransferCoordinator()
    @ObservationIgnored private var operations: [UUID: TransferOperation] = [:]
    @ObservationIgnored private var order: [UUID] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var promptReply: (@MainActor (DuplicateDecision?) -> Void)?
    @ObservationIgnored private var promptQueue: [(DuplicatePrompt, @MainActor (DuplicateDecision?) -> Void)] = []
    @ObservationIgnored private let space: VolumeSpaceProvider
    /// Called when a job fails because the phone disconnected.
    @ObservationIgnored public var onDisconnect: () -> Void = {}

    public init(space: VolumeSpaceProvider = SystemVolumeSpace()) {
        self.space = space
    }

    public var hasActiveTransfer: Bool { rows.contains { $0.snapshot.phase.isActive || $0.snapshot.phase == .queued } }

    @ObservationIgnored private var _resolver: PromptingDuplicateResolver?
    public var resolver: PromptingDuplicateResolver {
        if let r = _resolver { return r }
        let r = PromptingDuplicateResolver { [weak self] prompt, reply in self?.enqueuePrompt(prompt, reply: reply) }
        _resolver = r
        return r
    }

    // MARK: - Starting and controlling jobs

    @discardableResult
    public func start(_ request: TransferRequest, session: DeviceSession) -> UUID {
        let op = TransferOperation(request: request, resolver: resolver, space: space)
        operations[op.id] = op
        order.append(op.id)
        rows.append(TransferRow(id: op.id, title: op.title, destination: request.destination, snapshot: op.snapshot()))
        let coordinator = self.coordinator
        Task { await coordinator.enqueue(op, session: session) }
        startPolling()
        return op.id
    }

    public func cancel(_ id: UUID) {
        guard let op = operations[id] else { return }
        let coordinator = self.coordinator
        Task { await coordinator.cancel(op); self.refresh() }
        if duplicatePrompt != nil { answerPrompt(nil) }
    }

    public func cancelAll() {
        let coordinator = self.coordinator
        Task { await coordinator.cancelAll(); self.refresh() }
        while duplicatePrompt != nil { answerPrompt(nil) }
    }

    public func canRetry(_ id: UUID) -> Bool {
        guard let row = rows.first(where: { $0.id == id }) else { return false }
        let s = row.snapshot
        return s.phase.isFinished && s.phase != .completed && (s.failedFiles + s.cancelledFiles > 0 || {
            if case .failed = s.phase { return true } else { return false }
        }())
    }

    public func retry(_ id: UUID, session: DeviceSession) {
        guard let op = operations[id] else { return }
        let coordinator = self.coordinator
        Task {
            await coordinator.retry(op, session: session)
            self.refresh()
            self.startPolling()
        }
    }

    public func clearFinished() {
        let finished = rows.filter { $0.snapshot.phase.isFinished }.map(\.id)
        for id in finished { operations[id] = nil }
        order.removeAll { finished.contains($0) }
        rows.removeAll { finished.contains($0.id) }
        let coordinator = self.coordinator
        Task { await coordinator.clearFinished() }
    }

    public func summary(for id: UUID) -> TransferSummary? { operations[id]?.summary() }
    public func items(for id: UUID) -> [ItemState] { operations[id]?.items() ?? [] }

    // MARK: - Duplicate prompts

    private func enqueuePrompt(_ prompt: DuplicatePrompt, reply: @escaping @MainActor (DuplicateDecision?) -> Void) {
        if duplicatePrompt == nil {
            duplicatePrompt = prompt
            promptReply = reply
        } else {
            promptQueue.append((prompt, reply))
        }
    }

    /// The UI calls this with the user's choice (nil = cancel the transfer).
    public func answerPrompt(_ decision: DuplicateDecision?) {
        let reply = promptReply
        promptReply = nil
        duplicatePrompt = nil
        reply?(decision)
        if !promptQueue.isEmpty {
            let (next, nextReply) = promptQueue.removeFirst()
            duplicatePrompt = next
            promptReply = nextReply
        }
    }

    // MARK: - Progress sampling

    /// Samples every job's snapshot (~8 times a second while anything is running).
    public func refresh() {
        var anyDisconnected = false
        for i in rows.indices {
            guard let op = operations[rows[i].id] else { continue }
            let before = rows[i].snapshot
            let now = op.snapshot()
            rows[i].snapshot = now
            if !before.phase.isFinished, now.phase.isFinished, now.lastError == .deviceDisconnected { anyDisconnected = true }
        }
        if anyDisconnected { onDisconnect() }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 125_000_000)
                guard let self else { return }
                self.refresh()
                if !self.hasActiveTransfer {
                    self.pollTask = nil
                    return
                }
            }
        }
    }
}
