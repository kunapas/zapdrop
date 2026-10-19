import Foundation
import FerryCore

/// A scripted phone for development and tests. Everything is in memory; file contents are generated on the fly,
/// so files of many gigabytes cost nothing.
public final class MockPhone: @unchecked Sendable {
    public struct Node: Sendable {
        public var item: RemoteItem
        public var seed: UInt32
        public var hasThumbnail: Bool
    }

    /// Failure injected for one object.
    public struct Fault: Sendable {
        public var error: FerryError
        /// Fail only after this many bytes have been delivered (0 = fail immediately).
        public var afterBytes: UInt64
        /// How many attempts fail before the object starts working (nil = always fails).
        public var remainingFailures: Int?
        public init(_ error: FerryError, afterBytes: UInt64 = 0, failures: Int? = 1) {
            self.error = error; self.afterBytes = afterBytes; self.remainingFailures = failures
        }
    }

    struct State {
        var summary: DeviceSummary
        var mode: DiscoveredDevice.Mode = .fileTransfer
        var connected = true
        var locked = false
        var busyHolder: String?
        var authorizationPendingAttempts = 0
        var storages: [StorageInfo] = []
        var nodes: [ObjectID: Node] = [:]
        var nextID: ObjectID = 1
        var faults: [ObjectID: Fault] = [:]
        var disconnectAfterTotalBytes: UInt64?
        var deliveredTotalBytes: UInt64 = 0
        var openSessions = 0
        var downloadsStarted = 0
        var maxConcurrentOperations = 0
        var currentOperations = 0
        var batteryPercent: Int? = 82
        var usbSpeed: USBSpeed? = .superSpeed
    }

    let state: Locked<State>
    /// Simulated throughput in bytes per second; `nil` delivers as fast as possible.
    public var bytesPerSecond: Double? { get { _bps.current } set { _bps.withLock { $0 = newValue } } }
    private let _bps = Locked<Double?>(nil)
    /// Simulated time to read one object's metadata while listing (real Android phones: ~10–50 ms).
    public var listDelayPerItem: Double? { get { _listDelay.current } set { _listDelay.withLock { $0 = newValue } } }
    private let _listDelay = Locked<Double?>(nil)
    public let chunkSize: Int

    public init(summary: DeviceSummary, chunkSize: Int = 256 * 1024) {
        self.state = Locked(State(summary: summary))
        self.chunkSize = chunkSize
    }

    public var summary: DeviceSummary { state.current.summary }

    // MARK: Building the tree

    @discardableResult
    public func addStorage(_ description: String, capacity: UInt64, free: UInt64, removable: Bool = false) -> StorageID {
        state.withLock { s in
            let id = StorageID(0x0001_0001 + UInt32(s.storages.count) * 0x0001_0000)
            s.storages.append(StorageInfo(id: id, description: description, capacityBytes: capacity,
                                          freeBytes: free, isRemovable: removable))
            return id
        }
    }

    @discardableResult
    public func addFolder(_ name: String, in parent: ObjectID = rootParentID, storage: StorageID, modified: Date? = nil) -> ObjectID {
        add(name: name, parent: parent, storage: storage, isFolder: true, size: nil, modified: modified, thumbnail: false)
    }

    @discardableResult
    public func addFile(_ name: String, in parent: ObjectID = rootParentID, storage: StorageID, size: UInt64?,
                        modified: Date? = nil, thumbnail: Bool? = nil) -> ObjectID {
        let thumb = thumbnail ?? (FileKind.classify(fileName: name, isFolder: false) == .photo)
        return add(name: name, parent: parent, storage: storage, isFolder: false, size: size, modified: modified, thumbnail: thumb)
    }

    private func add(name: String, parent: ObjectID, storage: StorageID, isFolder: Bool, size: UInt64?,
                     modified: Date?, thumbnail: Bool) -> ObjectID {
        state.withLock { s in
            let id = s.nextID
            s.nextID += 1
            let item = RemoteItem(id: id, storageID: storage, parentID: parent, name: name, isFolder: isFolder,
                                  size: size, modified: modified)
            s.nodes[id] = Node(item: item, seed: id &* 2_654_435_761, hasThumbnail: thumbnail)
            return id
        }
    }

    // MARK: Scenario controls

    public func setMode(_ mode: DiscoveredDevice.Mode) { state.withLock { $0.mode = mode } }
    public func setLocked(_ locked: Bool) { state.withLock { $0.locked = locked } }
    public func setBusy(holder: String?) { state.withLock { $0.busyHolder = holder } }
    public func setBattery(_ percent: Int?) { state.withLock { $0.batteryPercent = percent } }
    public func setUSBSpeed(_ speed: USBSpeed?) { state.withLock { $0.usbSpeed = speed } }
    /// The next `attempts` session opens fail as "not authorised yet".
    public func requireAuthorization(attempts: Int) { state.withLock { $0.authorizationPendingAttempts = attempts } }
    public func disconnect() { state.withLock { $0.connected = false } }
    public func reconnect() { state.withLock { $0.connected = true; $0.disconnectAfterTotalBytes = nil } }
    public func inject(_ fault: Fault, for id: ObjectID) { state.withLock { $0.faults[id] = fault } }
    public func disconnect(afterTotalBytes bytes: UInt64) {
        state.withLock { $0.disconnectAfterTotalBytes = $0.deliveredTotalBytes + bytes }
    }
    public func removeObject(_ id: ObjectID) { state.withLock { _ = $0.nodes.removeValue(forKey: id) } }

    // MARK: Inspection (tests)

    public var isConnected: Bool { state.current.connected }
    public var downloadsStarted: Int { state.current.downloadsStarted }
    /// Highest number of overlapping operations seen — must stay 1 to model MTP correctly.
    public var maxConcurrentOperations: Int { state.current.maxConcurrentOperations }
    /// Sessions opened and not yet closed — anything above 1 after things settle is a leak.
    public var openSessions: Int { state.current.openSessions }
    public func node(_ id: ObjectID) -> Node? { state.current.nodes[id] }
    public func item(named path: String, storage: StorageID? = nil) -> RemoteItem? {
        let parts = path.split(separator: "/").map(String.init)
        let s = state.current
        guard let storageID = storage ?? s.storages.first?.id else { return nil }
        var parent = rootParentID
        var found: RemoteItem?
        for part in parts {
            found = s.nodes.values.first {
                $0.item.parentID == parent && $0.item.name == part && $0.item.storageID == storageID
            }?.item
            guard let f = found else { return nil }
            parent = f.id
        }
        return found
    }
}

/// `DeviceBackend` over a set of `MockPhone`s.
public final class MockDeviceBackend: DeviceBackend, @unchecked Sendable {
    private let phones: Locked<[MockPhone]>

    public init(phones: [MockPhone]) { self.phones = Locked(phones) }

    public func add(_ phone: MockPhone) { phones.withLock { $0.append(phone) } }
    public var allPhones: [MockPhone] { phones.current }

    public func discover() async throws -> [DiscoveredDevice] {
        phones.current.compactMap { p in
            let s = p.state.current
            return s.connected ? DiscoveredDevice(summary: s.summary, mode: s.mode, usbSpeed: s.usbSpeed) : nil
        }
    }

    public func openSession(_ id: DeviceID) async throws -> any DeviceSession {
        guard let phone = phones.current.first(where: { $0.summary.id == id && $0.isConnected }) else {
            throw FerryError.deviceDisconnected
        }
        let error: FerryError? = phone.state.withLock { s in
            if s.mode == .chargingOnly { return .chargingOnlyMode }
            if let holder = s.busyHolder { return .deviceBusy(holder: holder) }
            if s.authorizationPendingAttempts > 0 { s.authorizationPendingAttempts -= 1; return .notAuthorized }
            s.openSessions += 1
            return nil
        }
        if let error { throw error }
        return MockSession(phone: phone)
    }
}

final class MockSession: DeviceSession, @unchecked Sendable {
    let phone: MockPhone
    private let closed = Locked(false)

    init(phone: MockPhone) { self.phone = phone }

    var summary: DeviceSummary { phone.summary }

    /// Models MTP's one-request-at-a-time rule and records any overlap.
    private func operation<T>(_ body: () async throws -> T) async throws -> T {
        try phone.state.withLock { s in
            guard s.connected, !closed.current else { throw FerryError.deviceDisconnected }
            s.currentOperations += 1
            s.maxConcurrentOperations = max(s.maxConcurrentOperations, s.currentOperations)
        }
        defer { phone.state.withLock { $0.currentOperations -= 1 } }
        return try await body()
    }

    func storages() async throws -> [StorageInfo] {
        try await operation {
            let s = phone.state.current
            return s.locked ? [] : s.storages
        }
    }

    func children(of location: RemoteLocation) async throws -> [RemoteItem] {
        try await operation {
            let s = phone.state.current
            if s.locked { throw FerryError.deviceLocked }
            if !location.isRoot, s.nodes[location.folderID] == nil { throw FerryError.sourceRemoved }
            return s.nodes.values
                .filter { $0.item.storageID == location.storageID && $0.item.parentID == location.folderID }
                .map(\.item)
                .sorted { $0.id < $1.id }
        }
    }

    func children(of location: RemoteLocation, batchSize: Int,
                  onBatch: @escaping @Sendable (_ batch: [RemoteItem], _ total: Int) async -> Void) async throws -> [RemoteItem] {
        let all = try await children(of: location)
        let size = max(1, batchSize)
        for start in stride(from: 0, to: all.count, by: size) {
            if Task.isCancelled { throw FerryError.cancelled }
            let batch = Array(all[start..<min(start + size, all.count)])
            if let delay = phone.listDelayPerItem, delay > 0 {
                try await operation { try? await Task.sleep(nanoseconds: UInt64(delay * Double(batch.count) * 1e9)) }
            }
            await onBatch(batch, all.count)
        }
        return all
    }

    func refreshItem(_ item: RemoteItem) async throws -> RemoteItem? {
        try await operation { phone.state.current.nodes[item.id]?.item }
    }

    func batteryPercent() async -> Int? {
        (try? await operation { phone.state.current.batteryPercent }) ?? nil
    }

    func thumbnail(for item: RemoteItem) async throws -> Data? {
        try await operation {
            guard let node = phone.state.current.nodes[item.id], node.hasThumbnail else { return nil }
            return MockPNG.gradient(seed: node.seed)
        }
    }

    func download(_ item: RemoteItem, into sink: ByteSink,
                  progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        try await operation {
            let (node, fault) = try phone.state.withLock { s -> (MockPhone.Node, MockPhone.Fault?) in
                guard let node = s.nodes[item.id] else { throw FerryError.sourceRemoved }
                s.downloadsStarted += 1
                var fault = s.faults[item.id]
                if var f = fault, let remaining = f.remainingFailures {
                    if remaining <= 0 { fault = nil } else { f.remainingFailures = remaining - 1; s.faults[item.id] = f }
                }
                return (node, fault)
            }
            let total = node.item.size ?? 0
            let chunk = phone.chunkSize
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
            defer { buffer.deallocate() }
            var offset: UInt64 = 0
            while offset < total {
                if Task.isCancelled { throw FerryError.cancelled }
                if let f = fault, offset >= f.afterBytes { throw f.error }
                let disconnected = phone.state.withLock { s -> Bool in
                    if let limit = s.disconnectAfterTotalBytes, s.deliveredTotalBytes >= limit { s.connected = false }
                    return !s.connected
                }
                if disconnected { throw FerryError.deviceDisconnected }

                var n = Int(min(UInt64(chunk), total - offset))
                if let f = fault, f.afterBytes > offset { n = Int(min(UInt64(n), f.afterBytes - offset)) }
                let slice = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<n])
                MockContent.fill(slice, offset: offset, seed: node.seed)
                try sink.write(UnsafeRawBufferPointer(slice))
                offset += UInt64(n)
                phone.state.withLock { $0.deliveredTotalBytes += UInt64(n) }
                progress(offset)
                if let bps = phone.bytesPerSecond, bps > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(Double(n) / bps * 1e9))
                }
            }
            if let f = fault { throw f.error }
            return offset
        }
    }

    func close() async {
        let wasOpen = closed.withLock { c in defer { c = true }; return !c }
        if wasOpen { phone.state.withLock { $0.openSessions -= 1 } }
    }
}
