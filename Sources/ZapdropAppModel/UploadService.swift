import Foundation
import Observation
import ZapdropCore

/// Reads a file on the Mac for sending to the phone.
final class LocalFileSource: ByteSource {
    private let handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit { try? handle.close() }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let data = try handle.read(upToCount: buffer.count), !data.isEmpty else { return 0 }
        data.copyBytes(to: buffer.bindMemory(to: UInt8.self), count: data.count)
        return data.count
    }
}

/// Copies files and folders from the Mac into a folder on the phone, one file at a time.
///
/// It only ever adds. A file whose name is already taken on the phone is saved alongside as "name (1)"; a folder
/// with the same name is merged into, by the same rule. Nothing on the phone is overwritten or deleted.
@MainActor @Observable
public final class UploadService {
    public struct Progress: Equatable, Sendable {
        public var currentName = ""
        public var filesDone = 0
        public var filesTotal = 0
        public var bytesDone: UInt64 = 0
        public var bytesTotal: UInt64 = 0

        public var fraction: Double { ProgressMath.fraction(done: bytesDone, total: bytesTotal) }
    }

    public struct Outcome: Equatable, Sendable {
        public var copied = 0
        /// Names of files that couldn't be sent.
        public var failed: [String] = []
        public var cancelled = false
        /// What stopped the copy or failed first, for the message shown afterwards.
        public var firstError: ZapdropError?
    }

    public private(set) var progress: Progress?
    public var isActive: Bool { progress != nil }
    @ObservationIgnored private var task: Task<Void, Never>?

    public init() {}

    /// Starts copying `urls` into `location`. One copy runs at a time; a second request is ignored until it ends.
    public func start(_ urls: [URL], to location: RemoteLocation, session: DeviceSession,
                      onFinished: @escaping @MainActor (Outcome) -> Void) {
        guard !isActive, !urls.isEmpty else { return }
        progress = Progress()
        task = Task { [weak self] in
            let outcome = await Self.copy(urls, to: location, session: session) { update in
                Task { @MainActor in
                    if self?.progress != nil { self?.progress = update }
                }
            }
            self?.progress = nil
            self?.task = nil
            onFinished(outcome)
        }
    }

    public func cancel() {
        task?.cancel()
    }

    // MARK: - The copy itself

    /// Files to skip: Finder's bookkeeping, which means nothing on a phone.
    nonisolated static func isSkipped(_ url: URL) -> Bool {
        url.lastPathComponent == ".DS_Store" || url.lastPathComponent.hasPrefix("._")
    }

    private enum LocalKind: Sendable { case file(UInt64), folder, other }

    /// Symbolic links are never followed: only real files and folders are sent.
    private nonisolated static func kind(of url: URL) -> LocalKind {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]),
              values.isSymbolicLink != true else { return .other }
        if values.isDirectory == true { return .folder }
        if values.isRegularFile == true { return .file(UInt64(values.fileSize ?? 0)) }
        return .other
    }

    private nonisolated static func contents(of folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !isSkipped($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Counts the files and bytes under `urls`, for the progress bar.
    nonisolated static func measure(_ urls: [URL]) -> (files: Int, bytes: UInt64) {
        var files = 0
        var bytes: UInt64 = 0
        var pending = urls.filter { !isSkipped($0) }
        while let url = pending.popLast() {
            switch kind(of: url) {
            case .file(let size):
                files += 1
                bytes = ProgressMath.add(bytes, size)
            case .folder:
                pending += contents(of: url)
            case .other:
                break
            }
        }
        return (files, bytes)
    }

    /// Android's shared storage ignores case, so "Photo.jpg" and "photo.JPG" are the same name there.
    private nonisolated static func key(_ name: String) -> String {
        FileNameSanitizer.collisionKey(name, caseSensitive: false)
    }

    private nonisolated static func freeName(for name: String, taken: Set<String>) -> String {
        if !taken.contains(key(name)) { return name }
        for n in 1...10_000 {
            let candidate = FileNameSanitizer.numberedVariant(of: name, number: n)
            if !taken.contains(key(candidate)) { return candidate }
        }
        return FileNameSanitizer.numberedVariant(of: name, number: Int.random(in: 10_001...999_999))
    }

    nonisolated static func copy(_ urls: [URL], to location: RemoteLocation, session: DeviceSession,
                                 report: @escaping @Sendable (Progress) -> Void) async -> Outcome {
        let totals = measure(urls)
        var progress = Progress(filesTotal: totals.files, bytesTotal: totals.bytes)
        var outcome = Outcome()
        report(progress)

        /// Errors after which carrying on is pointless.
        func isFatal(_ error: ZapdropError) -> Bool {
            switch error {
            case .cancelled, .deviceDisconnected, .deviceLocked, .noDevice, .unsupportedDevice: return true
            default: return false
            }
        }

        // Depth-first with an explicit stack: (things to send, the phone folder they go into).
        var stack: [([URL], RemoteLocation)] = [(urls.filter { !isSkipped($0) }, location)]
        do {
            while let (items, folder) = stack.popLast() {
                let existing = try await session.children(of: folder)
                var taken = Set(existing.map { key($0.name) })
                for url in items {
                    if Task.isCancelled { throw ZapdropError.cancelled }
                    let wanted = FileNameSanitizer.sanitize(url.lastPathComponent).name
                    switch kind(of: url) {
                    case .folder:
                        let target: RemoteItem
                        if let same = existing.first(where: { $0.isFolder && key($0.name) == key(wanted) }) {
                            target = same // merge into the folder that's already there
                        } else {
                            let name = freeName(for: wanted, taken: taken)
                            target = try await session.createFolder(named: name, in: folder)
                            taken.insert(key(name))
                        }
                        stack.append((contents(of: url), RemoteLocation(storageID: folder.storageID, folderID: target.id)))
                    case .file(let size):
                        let name = freeName(for: wanted, taken: taken)
                        progress.currentName = name
                        report(progress)
                        let before = progress.bytesDone
                        do {
                            let source = try LocalFileSource(url: url)
                            let base = progress
                            _ = try await session.upload(named: name, size: size, to: folder, from: source) { sent in
                                var update = base
                                update.bytesDone = ProgressMath.add(before, sent)
                                report(update)
                            }
                            taken.insert(key(name))
                            outcome.copied += 1
                        } catch {
                            let mapped = (error as? ZapdropError) ?? .io(detail: "read")
                            if isFatal(mapped) { throw mapped }
                            outcome.failed.append(url.lastPathComponent)
                            outcome.firstError = outcome.firstError ?? mapped
                            Log.warning("upload", "Item failed: \(mapped.logName)", url.lastPathComponent)
                        }
                        progress.filesDone += 1
                        progress.bytesDone = ProgressMath.add(before, size)
                        report(progress)
                    case .other:
                        break
                    }
                }
            }
        } catch {
            let mapped = (error as? ZapdropError) ?? .io(detail: "upload")
            outcome.cancelled = mapped == .cancelled
            if !outcome.cancelled { outcome.firstError = outcome.firstError ?? mapped }
        }
        return outcome
    }
}
