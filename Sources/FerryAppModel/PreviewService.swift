import Foundation
import Observation
import FerryCore

/// Quick Look needs a local file: this copies one phone file into a private cache and hands back its URL.
/// One preview at a time; starting another (or closing) cancels the copy in progress. Cleared with the session.
@MainActor @Observable
public final class PreviewService {
    /// The file to show. The UI binds Quick Look to it and sets it back to nil when the panel closes.
    public var url: URL?
    /// The item being copied for preview, while that is happening.
    public private(set) var preparing: RemoteItem?
    /// 0…1 while preparing (0 when the size is unknown).
    public private(set) var fraction: Double = 0
    /// Why the last preview couldn't be shown, for the app to present.
    public private(set) var error: UserFacingError?

    /// Previews larger than this are refused: copying them just to look would take minutes.
    @ObservationIgnored public var maxBytes: UInt64 = 2_000_000_000

    @ObservationIgnored private let cacheRoot: URL
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var ready: [ObjectID: URL] = [:]

    public init(cacheRoot: URL) {
        self.cacheRoot = cacheRoot
        try? FileManager.default.removeItem(at: cacheRoot) // leftovers from a previous run
    }

    public var isActive: Bool { url != nil || preparing != nil }

    public func reset(session: DeviceSession?) {
        close()
        self.session = session
        ready.removeAll()
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    /// Space bar behaviour: close what's showing, otherwise preview `item`.
    public func toggle(_ item: RemoteItem?) {
        if isActive { close(); return }
        if let item { show(item) }
    }

    public func show(_ item: RemoteItem) {
        close()
        error = nil
        guard !item.isFolder, let session else { return }
        if let size = item.size, size > maxBytes {
            error = UserFacingError(title: "Too large to preview",
                                    message: "\(item.displayName) is \(ByteFormatter.string(size)). Copy it to your Mac to open it.",
                                    suggestions: [], canRetry: false)
            return
        }
        if let cached = ready[item.id], FileManager.default.fileExists(atPath: cached.path) {
            url = cached
            return
        }
        preparing = item
        fraction = 0
        let root = cacheRoot
        task = Task { [weak self] in
            let received = Locked(UInt64(0))
            let finished = Locked(false)
            let copy = Task.detached { () async throws -> URL in
                defer { finished.withLock { $0 = true } }
                return try await Self.copy(item, from: session, into: root, received: received)
            }
            // Sample progress a few times a second rather than hopping to the main actor per chunk.
            while !finished.current, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.preparing?.id == item.id else { break }
                if let size = item.size, size > 0 { self.fraction = min(1, Double(received.current) / Double(size)) }
            }
            let result = await withTaskCancellationHandler { await copy.result } onCancel: { copy.cancel() }
            guard let self, !Task.isCancelled, self.preparing?.id == item.id else { return }
            self.preparing = nil
            switch result {
            case .success(let url):
                self.ready[item.id] = url
                self.url = url
            case .failure(let e):
                if (e as? FerryError) != .cancelled { self.error = ErrorMapper.map(e) }
            }
        }
    }

    public func close() {
        task?.cancel()
        task = nil
        preparing = nil
        fraction = 0
        url = nil
    }

    public func clearError() { error = nil }

    /// Streams the file into `<root>/<id>/<safe name>` via a partial file, like a normal copy.
    nonisolated static func copy(_ item: RemoteItem, from session: DeviceSession, into root: URL,
                                 received: Locked<UInt64>) async throws -> URL {
        let folder = root.appendingPathComponent(String(item.id), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = FileNameSanitizer.sanitize(item.name).name
        let final = folder.appendingPathComponent(name)
        let partial = folder.appendingPathComponent(LocalFS.partialName(for: name))
        LocalFS.removeIfRegularFile(partial)
        let writer = try LocalFileWriter(partialURL: partial, computeDigest: false)
        do {
            let bytes = try await session.download(item, into: writer) { done in received.withLock { $0 = done } }
            _ = try writer.finish()
            if let size = item.size, bytes != size { throw FerryError.sizeMismatch(expected: size, actual: bytes) }
            try LocalFS.move(partial, to: final, replacing: true)
            if let date = item.modified { LocalFS.setModificationDate(date, of: final) }
            return final
        } catch {
            writer.discard()
            throw error
        }
    }
}
