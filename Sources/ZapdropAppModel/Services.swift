import Foundation
import Observation
import ZapdropCore

// MARK: - Settings

/// Small key-value store abstraction so settings can be tested without touching real preferences.
public protocol KeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStore {}

public final class InMemoryStore: KeyValueStore {
    private var values: [String: Any] = [:]
    public init() {}
    public func data(forKey key: String) -> Data? { values[key] as? Data }
    public func string(forKey key: String) -> String? { values[key] as? String }
    public func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    public func object(forKey key: String) -> Any? { values[key] }
    public func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor @Observable
public final class AppSettings {
    @ObservationIgnored private let store: KeyValueStore

    public var verifyAfterCopy: Bool { didSet { store.set(verifyAfterCopy, forKey: "verifyAfterCopy") } }
    public var preserveDates: Bool { didSet { store.set(preserveDates, forKey: "preserveDates") } }
    public var showHiddenFiles: Bool { didSet { store.set(showHiddenFiles, forKey: "showHiddenFiles") } }
    /// nil = ask every time.
    public var defaultDuplicateAction: DuplicateAction? {
        didSet { store.set(defaultDuplicateAction?.rawValue, forKey: "duplicateAction") }
    }
    /// Take the phone back from macOS's camera service without asking. It grabs phones by itself (again each time the
    /// phone reconnects, e.g. after tapping Allow), and nothing is lost by freeing it.
    public var autoReleaseCameraService: Bool { didSet { store.set(autoReleaseCameraService, forKey: "autoReleaseCameraService") } }
    /// Also quit phone apps (Photos, Image Capture, Android File Transfer…) without asking. Off until the user ticks
    /// "Always do this automatically" on the busy screen or in Settings.
    public var autoQuitPhoneApps: Bool { didSet { store.set(autoQuitPhoneApps, forKey: "autoQuitPhoneApps") } }

    public init(store: KeyValueStore) {
        self.store = store
        verifyAfterCopy = store.bool(forKey: "verifyAfterCopy")
        preserveDates = store.object(forKey: "preserveDates") as? Bool ?? true
        showHiddenFiles = store.bool(forKey: "showHiddenFiles")
        defaultDuplicateAction = store.string(forKey: "duplicateAction").flatMap(DuplicateAction.init(rawValue:))
        autoReleaseCameraService = store.object(forKey: "autoReleaseCameraService") as? Bool ?? true
        autoQuitPhoneApps = store.bool(forKey: "autoQuitPhoneApps")
    }

    public var transferOptions: TransferOptions {
        TransferOptions(duplicatePolicy: defaultDuplicateAction.map { .always($0) } ?? .ask,
                        preserveModificationDates: preserveDates, verifyAfterCopy: verifyAfterCopy)
    }
}

// MARK: - Destination

/// Turns a folder URL into persistable bytes and back. On macOS this is a bookmark (security-scoped when sandboxed),
/// so the folder is still found after it is renamed or moved.
public protocol BookmarkCodec: Sendable {
    func encode(_ url: URL) throws -> Data
    /// Returns the URL and whether the bookmark should be re-saved.
    func decode(_ data: Data) throws -> (URL, isStale: Bool)
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

public struct SystemBookmarkCodec: BookmarkCodec {
    public init() {}

    #if os(macOS)
    private var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    public func encode(_ url: URL) throws -> Data {
        try url.bookmarkData(options: isSandboxed ? [.withSecurityScope] : [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func decode(_ data: Data) throws -> (URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: isSandboxed ? [.withSecurityScope] : [],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    public func startAccessing(_ url: URL) -> Bool { isSandboxed ? url.startAccessingSecurityScopedResource() : true }
    public func stopAccessing(_ url: URL) { if isSandboxed { url.stopAccessingSecurityScopedResource() } }
    #else
    public func encode(_ url: URL) throws -> Data { Data(url.path.utf8) }
    public func decode(_ data: Data) throws -> (URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self), isDirectory: true), false)
    }
    public func startAccessing(_ url: URL) -> Bool { true }
    public func stopAccessing(_ url: URL) {}
    #endif
}

/// Remembers the last folder the user copied into.
@MainActor @Observable
public final class LocalDestinationService {
    public private(set) var destination: URL?

    @ObservationIgnored private let store: KeyValueStore
    @ObservationIgnored private let codec: BookmarkCodec
    @ObservationIgnored private var accessing: URL?
    @ObservationIgnored private let key = "destinationBookmark"

    public init(store: KeyValueStore, codec: BookmarkCodec = SystemBookmarkCodec()) {
        self.store = store
        self.codec = codec
        restore()
    }

    private func restore() {
        guard let data = store.data(forKey: key), let (url, stale) = try? codec.decode(data) else { return }
        guard LocalFS.kind(of: url) == .directory || (try? LocalFS.validateRoot(url)) != nil else { return }
        begin(url)
        if stale { save(url) }
    }

    public func choose(_ url: URL) {
        begin(url)
        save(url)
    }

    public func forget() {
        end()
        destination = nil
        store.set(nil, forKey: key)
    }

    /// Whether the destination is still usable (e.g. external disk not ejected).
    public var isAvailable: Bool {
        guard let destination else { return false }
        return (try? LocalFS.validateRoot(destination)) != nil
    }

    private func save(_ url: URL) {
        if let data = try? codec.encode(url) { store.set(data, forKey: key) }
    }

    private func begin(_ url: URL) {
        end()
        if codec.startAccessing(url) { accessing = url }
        destination = url
    }

    private func end() {
        if let url = accessing { codec.stopAccessing(url) }
        accessing = nil
    }

    /// Default macOS volumes are case-insensitive; names differing only by case then clash.
    nonisolated public static func isCaseInsensitive(_ url: URL) -> Bool {
        #if os(macOS)
        if let values = try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]),
           let sensitive = values.volumeSupportsCaseSensitiveNames {
            return !sensitive
        }
        return true
        #else
        return false
        #endif
    }
}

// MARK: - Thumbnails

/// Least-recently-used cache bounded by total cost (bytes).
public struct CostLimitedCache<Key: Hashable, Value> {
    private var values: [Key: (value: Value, cost: Int)] = [:]
    private var order: [Key] = []
    public private(set) var totalCost = 0
    public let costLimit: Int

    public init(costLimit: Int) { self.costLimit = costLimit }

    public var count: Int { values.count }

    public mutating func value(for key: Key) -> Value? {
        guard let entry = values[key] else { return nil }
        touch(key)
        return entry.value
    }

    public func peek(_ key: Key) -> Value? { values[key]?.value }

    public mutating func insert(_ value: Value, for key: Key, cost: Int) {
        if let old = values[key] { totalCost -= old.cost }
        values[key] = (value, cost)
        totalCost += cost
        touch(key)
        while totalCost > costLimit, let oldest = order.first, oldest != key {
            order.removeFirst()
            if let removed = values.removeValue(forKey: oldest) { totalCost -= removed.cost }
        }
    }

    public mutating func removeAll() {
        values.removeAll()
        order.removeAll()
        totalCost = 0
    }

    private mutating func touch(_ key: Key) {
        if let i = order.lastIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }
}

/// Loads previews one at a time from the phone, most recently requested first, never during a transfer
/// (the phone handles one request at a time and copying matters more).
@MainActor @Observable
public final class ThumbnailService<Image: AnyObject> {
    /// Changes whenever new previews arrive; views read it to refresh.
    public private(set) var version = 0

    @ObservationIgnored private var cache: CostLimitedCache<ObjectID, Image>
    @ObservationIgnored private var failed = Set<ObjectID>()
    @ObservationIgnored private var queue: [RemoteItem] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private let decode: @Sendable (Data) -> (Image, cost: Int)?
    @ObservationIgnored public var isPaused: () -> Bool = { false }
    /// Largest file downloaded just to make a preview when the phone has none (small photos only).
    @ObservationIgnored public var maxFallbackBytes: UInt64 = 8_000_000

    public init(costLimit: Int = 96 * 1024 * 1024, decode: @escaping @Sendable (Data) -> (Image, cost: Int)?) {
        self.cache = CostLimitedCache(costLimit: costLimit)
        self.decode = decode
    }

    public func reset(session: DeviceSession?) {
        worker?.cancel()
        worker = nil
        self.session = session
        cache.removeAll()
        failed.removeAll()
        queue.removeAll()
        version += 1
    }

    public func image(for item: RemoteItem) -> Image? { cache.peek(item.id) }

    public func request(_ item: RemoteItem) {
        guard !item.isFolder, item.kind == .photo || item.kind == .video, cache.peek(item.id) == nil,
              !failed.contains(item.id), !queue.contains(where: { $0.id == item.id }) else { return }
        queue.append(item)
        if queue.count > 300 { queue.removeFirst(queue.count - 300) }
        startWorker()
    }

    public func cancel(_ item: RemoteItem) { queue.removeAll { $0.id == item.id } }

    private func startWorker() {
        guard worker == nil, let session else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.isPaused() { try? await Task.sleep(nanoseconds: 500_000_000); continue }
                guard let item = self.queue.popLast() else { break }
                let data = await Self.fetch(item, session: session, maxFallback: self.maxFallbackBytes)
                guard !Task.isCancelled, self.session === session else { return }
                let decode = self.decode
                let decoded = await Task.detached { UncheckedBox(data.flatMap { decode($0) }) }.value.value
                if let pair = decoded {
                    self.cache.insert(pair.0, for: item.id, cost: pair.cost)
                    self.version += 1
                } else {
                    self.failed.insert(item.id)
                }
            }
            self?.worker = nil
        }
    }

    nonisolated private static func fetch(_ item: RemoteItem, session: DeviceSession, maxFallback: UInt64) async -> Data? {
        if let data = try? await session.thumbnail(for: item), !data.isEmpty { return data }
        guard item.kind == .photo, let size = item.size, size > 0, size <= maxFallback else { return nil }
        let sink = MemorySink(limit: maxFallback)
        guard (try? await session.download(item, into: sink) { _ in }) != nil else { return nil }
        return sink.data
    }
}

/// Carries a non-Sendable value (e.g. a decoded image) out of a background decode. The value is not shared.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Collects a small file in memory, refusing to grow past `limit`.
final class MemorySink: ByteSink {
    var data = Data()
    let limit: UInt64
    init(limit: UInt64) { self.limit = limit }
    func write(_ bytes: UnsafeRawBufferPointer) throws {
        let total = UInt64(data.count + bytes.count)
        guard total <= limit else { throw ZapdropError.sizeMismatch(expected: limit, actual: total) }
        data.append(contentsOf: bytes)
    }
}
