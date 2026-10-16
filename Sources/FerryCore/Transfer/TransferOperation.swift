import Foundation

/// One copy job: a selection on the phone → a folder on the Mac.
///
/// Thread model: `run` executes on one task at a time (enforced). Progress callbacks arrive from the device
/// queue and only touch lock-protected state. The UI reads `snapshot()` at its own pace.
public final class TransferOperation: @unchecked Sendable, Identifiable {
    public let id = UUID()
    public let request: TransferRequest
    public let title: String

    private struct State {
        var snapshot = TransferSnapshot.empty
        var items: [ItemState] = []
        var plan: TransferPlan?
        var planSession: ObjectIdentifier?
        var speed = SpeedEstimator()
        var userCancelled = false
        var isRunning = false
        var flag = CancellationFlag()
        var finishedBytes: UInt64 = 0
        var activeIndex: Int?
        var foldersCreated = 0
    }

    private let state = Locked(State())
    private let duplicates: DuplicateResolutionService
    private let space: VolumeSpaceProvider
    private let clock: TimeSource

    public init(request: TransferRequest, resolver: DuplicateResolver?, title: String? = nil,
                space: VolumeSpaceProvider = SystemVolumeSpace(), clock: TimeSource = MonotonicClock()) {
        self.request = request
        self.duplicates = DuplicateResolutionService(policy: request.options.duplicatePolicy, resolver: resolver)
        self.space = space
        self.clock = clock
        if let title {
            self.title = title
        } else if request.items.count == 1 {
            self.title = request.items[0].displayName
        } else {
            self.title = "\(request.items.count) items"
        }
    }

    // MARK: - Reading state

    public func snapshot() -> TransferSnapshot { state.withLock { $0.snapshot } }
    public func items() -> [ItemState] { state.withLock { $0.items } }
    public var plan: TransferPlan? { state.withLock { $0.plan } }

    public func summary() -> TransferSummary {
        let (items, foldersCreated) = state.withLock { ($0.items, $0.foldersCreated) }
        var summary = TransferSummary(copied: [], renamed: [], skipped: [], failed: [], cancelled: [],
                                      foldersCreated: foldersCreated)
        for item in items where !item.entry.isDirectory || isProblem(item.status) {
            switch item.status {
            case .completed(let savedAs, _):
                summary.copied.append(item)
                if savedAs != nil { summary.renamed.append(item) }
            case .skipped: summary.skipped.append(item)
            case .failed: summary.failed.append(item)
            case .cancelled, .pending, .active: summary.cancelled.append(item)
            }
        }
        return summary
    }

    private func isProblem(_ s: ItemStatus) -> Bool {
        switch s { case .failed: return true; default: return false }
    }

    // MARK: - Control

    /// Cancels safely: the current file's partial data is deleted, finished files are kept.
    public func cancel() {
        let flag: CancellationFlag = state.withLock { s in
            s.userCancelled = true
            if !s.isRunning, s.snapshot.phase == .queued {
                for i in s.items.indices where s.items[i].status == .pending { setStatus(&s, i, .cancelled) }
                s.snapshot.phase = .cancelled
            }
            return s.flag
        }
        flag.cancel()
    }

    /// Resets failed (retryable) and cancelled items so `run` processes only them. Returns how many were reset.
    @discardableResult
    public func prepareRetry() -> Int {
        state.withLock { s in
            guard !s.isRunning, s.snapshot.phase.isFinished else { return 0 }
            var count = 0
            for i in s.items.indices {
                if s.items[i].status.isRetryable {
                    setStatus(&s, i, .pending)
                    s.items[i].bytesTransferred = 0
                    count += 1
                } else if s.items[i].status == .pending {
                    count += 1 // left pending by a preflight failure (e.g. not enough space)
                }
            }
            // A plan that never finished (e.g. cancelled while preparing) is rebuilt from scratch.
            if s.plan == nil { count = max(count, 1) }
            if count > 0 {
                s.snapshot.phase = .queued
                s.snapshot.lastError = nil
                s.userCancelled = false
            }
            return count
        }
    }

    // MARK: - Running

    public func run(session: DeviceSession) async {
        let flag = CancellationFlag()
        let canStart: Bool = state.withLock { s in
            guard !s.isRunning, !s.snapshot.phase.isFinished else { return false }
            if s.userCancelled { return false }
            s.isRunning = true
            s.flag = flag
            s.snapshot.transferredBytes = 0
            s.speed = SpeedEstimator()
            return true
        }
        guard canStart else { return }
        await withTaskCancellationHandler {
            await runBody(session: session, flag: flag)
        } onCancel: {
            flag.cancel()
        }
        state.withLock { s in
            s.isRunning = false
            s.activeIndex = nil
            s.snapshot.currentFileName = nil
            s.snapshot.bytesPerSecond = 0
            s.snapshot.secondsRemaining = nil
        }
    }

    private func runBody(session: DeviceSession, flag: CancellationFlag) async {
        // 1. Plan (once; retries reuse it).
        if state.withLock({ $0.plan == nil }) {
            state.withLock { $0.snapshot.phase = .preparing(itemsFound: 0) }
            do {
                let planner = TransferPlanner(session: session, caseInsensitive: request.destinationIsCaseInsensitive)
                let plan = try await planner.plan(request, cancellation: flag) { [weak self] n in
                    self?.state.withLock { $0.snapshot.phase = .preparing(itemsFound: n) }
                }
                state.withLock { s in
                    s.plan = plan
                    s.planSession = ObjectIdentifier(session)
                    s.items = plan.entries.map { ItemState(entry: $0, status: .pending, bytesTransferred: 0) }
                    s.snapshot.totalBytes = plan.totalBytes
                    s.snapshot.totalFiles = plan.fileCount
                    s.snapshot.itemsVersion += 1
                }
            } catch {
                finish(error: (error as? FerryError) ?? .io(detail: "\(error)"), flag: flag)
                return
            }
        }

        // 2. Destination still there?
        do { try LocalFS.validateRoot(request.destination) } catch {
            finish(error: (error as? FerryError) ?? .destinationUnavailable, flag: flag)
            return
        }

        // 3. After a reconnect, object IDs may have changed: find pending files again by path.
        if state.withLock({ $0.planSession }) != ObjectIdentifier(session) {
            await reresolvePendingItems(session: session, flag: flag)
            state.withLock { $0.planSession = ObjectIdentifier(session) }
        }

        // 4. Free space preflight (files that already exist at the destination may be skipped, so they don't count).
        let needed = bytesNeeded()
        if needed > 0 {
            if let available = try? space.availableBytes(at: request.destination),
               available < ProgressMath.add(needed, request.options.freeSpaceMargin) {
                finish(error: .insufficientSpace(needed: ProgressMath.add(needed, request.options.freeSpaceMargin),
                                                 available: available), flag: flag, leavePending: true)
                return
            }
        }

        // 5. Copy, strictly one item at a time.
        state.withLock { $0.snapshot.phase = .running; $0.speed.rebase() }
        var reserved = state.withLock { $0.plan?.reservedNames } ?? [:]
        var failedFolders: [(prefix: [String], error: FerryError)] = []
        let indices: [Int] = state.withLock { s in s.items.indices.filter { s.items[$0].status == .pending } }

        for index in indices {
            if flag.isCancelled { break }
            let entry = state.withLock { $0.items[index].entry }

            if let blocked = failedFolders.first(where: { entry.directory.starts(with: $0.prefix) }) {
                state.withLock { setStatus(&$0, index, .failed(blocked.error)) }
                continue
            }
            state.withLock { s in
                setStatus(&s, index, .active)
                s.activeIndex = index
                s.snapshot.currentFileName = entry.isDirectory ? nil : entry.source.displayName
                s.snapshot.currentFileBytes = 0
                s.snapshot.currentFileTotal = entry.size
            }

            let status: ItemStatus
            do {
                if entry.isDirectory {
                    try LocalFS.ensureDirectory(root: request.destination, components: entry.directory + [entry.name])
                    state.withLock { $0.foldersCreated += 1 }
                    status = .completed(savedAs: entry.rename == nil ? nil : entry.name, verified: false)
                } else {
                    status = try await copyFile(index: index, entry: entry, session: session, flag: flag,
                                                reserved: &reserved)
                }
            } catch {
                let e = (error as? FerryError) ?? .io(detail: "\(error)")
                if e == .cancelled || flag.isCancelled {
                    state.withLock { setStatus(&$0, index, .cancelled) }
                    break
                }
                Log.warning("transfer", "Item failed: \(e)", entry.source.name)
                state.withLock { s in
                    setStatus(&s, index, .failed(e))
                    s.snapshot.lastError = e
                }
                if entry.isDirectory { failedFolders.append((entry.directory + [entry.name], e)) }
                if e.stopsQueue { break }
                continue
            }
            state.withLock { setStatus(&$0, index, status) }
        }
        finish(error: nil, flag: flag)
    }

    // MARK: - One file

    private func copyFile(index: Int, entry: PlannedEntry, session: DeviceSession, flag: CancellationFlag,
                          reserved: inout [String: Set<String>]) async throws -> ItemStatus {
        let dirURL = try LocalFS.ensureDirectory(root: request.destination, components: entry.directory)
        let dirKey = entry.directory.joined(separator: "/")
        var name = entry.name
        var replacing = false
        let target = try SafePath.join(root: dirURL, components: [name])

        switch LocalFS.kind(of: target) {
        case .missing:
            break
        case .file:
            let existing = try? FileManager.default.attributesOfItem(atPath: target.path)
            let conflict = DuplicateConflict(
                fileName: name, destination: target, incomingSize: entry.source.size,
                incomingModified: entry.source.modified,
                existingSize: (existing?[.size] as? NSNumber)?.uint64Value,
                existingModified: existing?[.modificationDate] as? Date,
                remainingFiles: remainingFileCount())
            guard let action = await duplicates.decide(conflict) else {
                state.withLock { $0.userCancelled = true }
                flag.cancel()
                throw FerryError.cancelled
            }
            if flag.isCancelled { throw FerryError.cancelled }
            switch action {
            case .skip: return .skipped(.alreadyExists)
            case .replace: replacing = true
            case .keepBoth: name = try uniqueName(for: entry.name, in: dirURL, dirKey: dirKey, reserved: reserved)
            }
        case .directory, .symlink, .other:
            // Never replace a folder or follow a link: save alongside instead.
            name = try uniqueName(for: entry.name, in: dirURL, dirKey: dirKey, reserved: reserved)
        }
        reserved[dirKey, default: []].insert(collisionKey(name))

        if let size = entry.source.size, size > 0, let available = try? space.availableBytes(at: dirURL),
           available < ProgressMath.add(size, request.options.freeSpaceMargin / 10) {
            throw FerryError.insufficientSpace(needed: ProgressMath.add(size, request.options.freeSpaceMargin / 10),
                                               available: available)
        }

        let finalURL = try SafePath.join(root: dirURL, components: [name])
        let partialURL = try SafePath.join(root: dirURL, components: [LocalFS.partialName(for: name)])
        let writer = try LocalFileWriter(partialURL: partialURL, computeDigest: request.options.verifyAfterCopy,
                                         cancellation: flag)
        do {
            _ = try await session.download(entry.source, into: writer) { [weak self] bytes in
                self?.recordProgress(index: index, fileBytes: bytes)
            }
            if flag.isCancelled { throw FerryError.cancelled }
            let digest = try writer.finish()
            if let expected = entry.source.size, writer.bytesWritten != expected {
                throw FerryError.sizeMismatch(expected: expected, actual: writer.bytesWritten)
            }
            var verified = false
            if request.options.verifyAfterCopy, let digest {
                let reread = try ReadBackVerifier.digest(of: partialURL, cancellation: flag)
                guard reread == digest else { throw FerryError.verificationFailed }
                verified = true
            }
            if request.options.preserveModificationDates, let date = entry.source.modified {
                LocalFS.setModificationDate(date, of: partialURL)
            }
            try LocalFS.move(partialURL, to: finalURL, replacing: replacing)
            return .completed(savedAs: name == entry.source.name ? nil : name, verified: verified)
        } catch {
            writer.discard()
            throw error
        }
    }

    private func uniqueName(for name: String, in dir: URL, dirKey: String, reserved: [String: Set<String>]) throws -> String {
        let taken = reserved[dirKey] ?? []
        for n in 1...10_000 {
            let candidate = FileNameSanitizer.numberedVariant(of: name, number: n)
            let url = try SafePath.join(root: dir, components: [candidate])
            if LocalFS.kind(of: url) == .missing, !taken.contains(collisionKey(candidate)) { return candidate }
        }
        throw FerryError.destinationConflict(name: name)
    }

    private func collisionKey(_ name: String) -> String {
        FileNameSanitizer.collisionKey(name, caseSensitive: !request.destinationIsCaseInsensitive)
    }

    // MARK: - Re-resolving after reconnect

    private func reresolvePendingItems(session: DeviceSession, flag: CancellationFlag) async {
        var listings: [String: [RemoteItem]] = [:]
        let pending: [(Int, PlannedEntry)] = state.withLock { s in
            s.items.indices.filter { s.items[$0].status == .pending && !s.items[$0].entry.isDirectory }.map { ($0, s.items[$0].entry) }
        }
        for (index, entry) in pending {
            if flag.isCancelled { return }
            do {
                var parent = rootParentID
                var found: RemoteItem?
                for (depth, component) in entry.remotePath.enumerated() {
                    let key = entry.remotePath[..<depth].joined(separator: "/")
                    let children: [RemoteItem]
                    if let cached = listings[key] { children = cached } else {
                        children = try await session.children(of: RemoteLocation(storageID: request.storageID, folderID: parent))
                        listings[key] = children
                    }
                    guard let match = children.first(where: { $0.name == component }) else { found = nil; break }
                    found = match
                    parent = match.id
                }
                if let found, !found.isFolder {
                    state.withLock { $0.items[index] = ItemState(entry: withSource(entry, found), status: .pending, bytesTransferred: 0) }
                } else {
                    state.withLock { setStatus(&$0, index, .failed(.sourceRemoved)) }
                }
            } catch {
                let e = (error as? FerryError) ?? .io(detail: "\(error)")
                state.withLock { setStatus(&$0, index, .failed(e)) }
                if e.stopsQueue { return }
            }
        }
    }

    private func withSource(_ e: PlannedEntry, _ source: RemoteItem) -> PlannedEntry {
        var copy = e
        copy.source = source
        return copy
    }

    // MARK: - Bookkeeping

    private func bytesNeeded() -> UInt64 {
        let entries: [PlannedEntry] = state.withLock { s in
            s.items.filter { $0.status == .pending && !$0.entry.isDirectory }.map(\.entry)
        }
        var needed: UInt64 = 0
        for entry in entries {
            guard let url = try? SafePath.join(root: request.destination, components: entry.directory + [entry.name]),
                  LocalFS.kind(of: url) == .missing else { continue }
            needed = ProgressMath.add(needed, entry.size)
        }
        return needed
    }

    private func remainingFileCount() -> Int {
        state.withLock { s in s.items.reduce(0) { $0 + ((!$1.entry.isDirectory && $1.status == .pending) ? 1 : 0) } }
    }

    private func recordProgress(index: Int, fileBytes: UInt64) {
        let now = clock.now()
        state.withLock { s in
            guard s.activeIndex == index, s.items.indices.contains(index) else { return }
            let previous = s.items[index].bytesTransferred
            let delta = fileBytes >= previous ? fileBytes - previous : 0
            s.items[index].bytesTransferred = fileBytes
            s.snapshot.transferredBytes = ProgressMath.add(s.snapshot.transferredBytes, delta)
            s.snapshot.currentFileBytes = fileBytes
            s.snapshot.processedBytes = ProgressMath.add(s.finishedBytes, min(fileBytes, s.items[index].entry.size))
            s.speed.record(totalBytes: s.snapshot.transferredBytes, at: now)
            s.snapshot.bytesPerSecond = s.speed.bytesPerSecond
            s.snapshot.secondsRemaining = s.speed.secondsRemaining(
                remainingBytes: ProgressMath.remaining(done: s.snapshot.processedBytes, total: s.snapshot.totalBytes))
        }
    }

    /// Single place where an item's status changes, keeping counters consistent.
    private func setStatus(_ s: inout State, _ index: Int, _ new: ItemStatus) {
        let old = s.items[index].status
        let isFile = !s.items[index].entry.isDirectory
        let size = s.items[index].entry.size
        if isFile {
            adjust(&s, old, -1, size)
            adjust(&s, new, +1, size)
        }
        s.items[index].status = new
        s.snapshot.processedBytes = s.finishedBytes
        s.snapshot.itemsVersion += 1
    }

    private func adjust(_ s: inout State, _ status: ItemStatus, _ sign: Int, _ size: UInt64) {
        func bump(_ v: inout Int) { v += sign }
        let finished: Bool
        switch status {
        case .completed: bump(&s.snapshot.completedFiles); finished = true
        case .skipped: bump(&s.snapshot.skippedFiles); finished = true
        case .failed: bump(&s.snapshot.failedFiles); finished = true
        case .cancelled: bump(&s.snapshot.cancelledFiles); finished = true
        case .pending, .active: finished = false
        }
        if finished {
            s.finishedBytes = sign > 0 ? ProgressMath.add(s.finishedBytes, size) : ProgressMath.remaining(done: size, total: s.finishedBytes)
        }
    }

    private func finish(error: FerryError?, flag: CancellationFlag, leavePending: Bool = false) {
        state.withLock { s in
            let cancelled = s.userCancelled || flag.isCancelled || error == .cancelled
            if !leavePending || cancelled {
                for i in s.items.indices where s.items[i].status == .pending || s.items[i].status == .active {
                    setStatus(&s, i, .cancelled)
                }
            }
            if let error, error != .cancelled { s.snapshot.lastError = error }
            let snap = s.snapshot
            if cancelled {
                s.snapshot.phase = .cancelled
            } else if let error, s.plan == nil || leavePending {
                s.snapshot.phase = .failed(error)
            } else if snap.failedFiles == 0 && snap.cancelledFiles == 0 && !s.items.contains(where: { if case .failed = $0.status { return true }; return false }) {
                s.snapshot.phase = .completed
            } else if snap.completedFiles + snap.skippedFiles > 0 || s.foldersCreated > 0 {
                s.snapshot.phase = .partiallyCompleted
            } else {
                s.snapshot.phase = .failed(s.snapshot.lastError ?? error ?? .io(detail: "unknown"))
            }
            s.snapshot.currentFileName = nil
        }
    }
}
