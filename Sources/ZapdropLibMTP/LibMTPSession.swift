import Foundation
import ZapdropCore
import CZapdropMTP

/// Context handed to the C download callbacks through an opaque pointer.
private final class DownloadContext: @unchecked Sendable {
    let sink: ByteSink
    let progress: @Sendable (UInt64) -> Void
    let flag: CancellationFlag
    var bytes: UInt64 = 0
    var sinkError: Error?

    init(sink: ByteSink, progress: @escaping @Sendable (UInt64) -> Void, flag: CancellationFlag) {
        self.sink = sink
        self.progress = progress
        self.flag = flag
    }
}

/// Read window for files of 4 GiB or more (Android GetPartialObject64).
let largeFileWindow: UInt32 = 8 * 1024 * 1024

private let writeCallback: zapdrop_write_fn = { ctx, data, length in
    guard let ctx else { return 1 }
    let c = Unmanaged<DownloadContext>.fromOpaque(ctx).takeUnretainedValue()
    if c.flag.isCancelled { return 2 }
    do {
        try c.sink.write(UnsafeRawBufferPointer(start: data, count: Int(length)))
        c.bytes = ProgressMath.add(c.bytes, UInt64(length))
        c.progress(c.bytes)
        return 0
    } catch let e as ZapdropError where e == .cancelled {
        return 2
    } catch {
        c.sinkError = error
        return 1
    }
}

private let progressCallback: zapdrop_progress_fn = { ctx, _, _ in
    guard let ctx else { return 0 }
    return Unmanaged<DownloadContext>.fromOpaque(ctx).takeUnretainedValue().flag.isCancelled ? 1 : 0
}

/// Context handed to the C upload callbacks through an opaque pointer.
private final class UploadContext: @unchecked Sendable {
    let source: ByteSource
    let progress: @Sendable (UInt64) -> Void
    let flag: CancellationFlag
    var bytes: UInt64 = 0
    var sourceError: Error?

    init(source: ByteSource, progress: @escaping @Sendable (UInt64) -> Void, flag: CancellationFlag) {
        self.source = source
        self.progress = progress
        self.flag = flag
    }
}

private let readCallback: zapdrop_read_fn = { ctx, data, wanted, got in
    guard let ctx, let data, let got else { return 1 }
    let c = Unmanaged<UploadContext>.fromOpaque(ctx).takeUnretainedValue()
    if c.flag.isCancelled { return 2 }
    do {
        let n = try c.source.read(into: UnsafeMutableRawBufferPointer(start: data, count: Int(wanted)))
        guard n >= 0, n <= Int(wanted) else { return 1 }
        got.pointee = UInt32(n)
        c.bytes = ProgressMath.add(c.bytes, UInt64(n))
        c.progress(c.bytes)
        return 0
    } catch let e as ZapdropError where e == .cancelled {
        return 2
    } catch {
        c.sourceError = error
        return 1
    }
}

private let uploadProgressCallback: zapdrop_progress_fn = { ctx, _, _ in
    guard let ctx else { return 0 }
    return Unmanaged<UploadContext>.fromOpaque(ctx).takeUnretainedValue().flag.isCancelled ? 1 : 0
}

final class LibMTPSession: DeviceSession, @unchecked Sendable {
    let handle: DeviceHandle
    let usb: USBAddress
    let summary: DeviceSummary
    private let queue = DeviceQueue.shared

    init(handle: DeviceHandle, usb: USBAddress, summary: DeviceSummary) {
        self.handle = handle
        self.usb = usb
        self.summary = summary
    }

    /// Turns a C status into a `ZapdropError`, checking whether the phone is still plugged in.
    private func error(for status: zapdrop_status, device: OpaquePointer?, context: String) -> ZapdropError {
        let detail = device.map { String(cString: zapdrop_last_error($0)) } ?? ""
        Log.warning("mtp", "\(context) failed: status \(status.rawValue)", detail)
        switch status {
        case ZAPDROP_ERR_CANCELLED: return .cancelled
        case ZAPDROP_ERR_NOT_FOUND: return .sourceRemoved
        case ZAPDROP_ERR_DISCONNECTED, ZAPDROP_ERR_NO_DEVICE: return .deviceDisconnected
        case ZAPDROP_ERR_UNSUPPORTED: return .fileTooLargeForPhone
        case ZAPDROP_ERR_BUSY: return .deviceBusy(holder: nil)
        case ZAPDROP_ERR_STORAGE_FULL, ZAPDROP_ERR_NO_MEMORY:
            return .protocolError(detail: "\(context): \(detail)")
        default:
            let code = device.map { zapdrop_last_ptp_code($0) } ?? 0
            return .protocolError(detail: "\(context): PTP 0x\(String(code, radix: 16)) \(detail)")
        }
    }

    /// A protocol error while the phone has vanished from USB is really a disconnect.
    private func refine(_ e: ZapdropError) async -> ZapdropError {
        if case .protocolError = e, !(await LibMTPBackend.isPresent(usb)) { return .deviceDisconnected }
        return e
    }

    private func call<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
        do {
            let handle = self.handle
            return try await queue.run { try body(try handle.get()) }
        } catch let e as ZapdropError {
            throw await refine(e)
        }
    }

    func storages() async throws -> [StorageInfo] {
        let list = try await rawStorages()
        // libmtp reports a failed storage request as "no storage" — the same as a locked phone.
        if list.isEmpty, !(await LibMTPBackend.isPresent(usb)) { throw ZapdropError.deviceDisconnected }
        return list
    }

    private func rawStorages() async throws -> [StorageInfo] {
        try await call { dev in
            var buffer = [zapdrop_storage](repeating: zapdrop_storage(), count: 16)
            var count: Int32 = 0
            let status = buffer.withUnsafeMutableBufferPointer { zapdrop_storages(dev, $0.baseAddress, Int32($0.count), &count) }
            guard status == ZAPDROP_OK else { throw self.error(for: status, device: dev, context: "storages") }
            return buffer.prefix(Int(count)).map { s in
                var st = s
                let description = withUnsafeBytes(of: &st.description) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                let volume = withUnsafeBytes(of: &st.volume) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                return StorageInfo(id: s.id, description: description, volumeLabel: volume.isEmpty ? nil : volume,
                                   capacityBytes: s.capacity, freeBytes: s.free_bytes,
                                   isRemovable: s.storage_type == 2 || s.storage_type == 4,
                                   isReadOnly: s.access_capability != 0)
            }
        }
    }

    static func item(from o: zapdrop_object, location: RemoteLocation?) -> RemoteItem {
        let name = o.name.map { String(cString: $0) } ?? ""
        // 0xFFFFFFFF: the phone reported a large file without its exact 64-bit size.
        let size: UInt64? = o.size == 0xFFFF_FFFF ? nil : o.size
        let modified: Date? = o.mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(o.mtime)) : nil
        return RemoteItem(id: o.id, storageID: location?.storageID ?? o.storage_id,
                          parentID: location?.folderID ?? o.parent_id, name: name, isFolder: o.is_folder != 0,
                          size: size, modified: modified)
    }

    func children(of location: RemoteLocation) async throws -> [RemoteItem] {
        try await children(of: location, batchSize: 200) { _, _ in }
    }

    /// One request for the handles, then one metadata request per object, in separate device-queue jobs of
    /// `batchSize` so other work (and cancellation) can get in between on folders of thousands of items.
    func children(of location: RemoteLocation, batchSize: Int,
                  onBatch: @escaping @Sendable (_ batch: [RemoteItem], _ total: Int) async -> Void) async throws -> [RemoteItem] {
        let started = Date()
        let ids: [UInt32] = try await call { dev in
            var ids: UnsafeMutablePointer<UInt32>?
            var count: Int32 = 0
            let status = zapdrop_list_handles(dev, location.storageID, location.folderID, &ids, &count)
            guard status == ZAPDROP_OK else { throw self.error(for: status, device: dev, context: "list") }
            defer { zapdrop_free(ids) }
            guard let ids, count > 0 else { return [] }
            return Array(UnsafeBufferPointer(start: ids, count: Int(count)))
        }
        var all: [RemoteItem] = []
        all.reserveCapacity(ids.count)
        for start in stride(from: 0, to: ids.count, by: max(1, batchSize)) {
            if Task.isCancelled { throw ZapdropError.cancelled }
            let slice = Array(ids[start..<min(start + max(1, batchSize), ids.count)])
            let batch: [RemoteItem] = try await call { dev in
                var objects: UnsafeMutablePointer<zapdrop_object>?
                var count: Int32 = 0
                let status = slice.withUnsafeBufferPointer {
                    zapdrop_list_objects(dev, location.storageID, location.folderID, $0.baseAddress, Int32($0.count),
                                       &objects, &count)
                }
                guard status == ZAPDROP_OK else { throw self.error(for: status, device: dev, context: "list") }
                defer { zapdrop_free_objects(objects, count) }
                guard let objects, count > 0 else { return [] }
                return UnsafeBufferPointer(start: objects, count: Int(count))
                    .filter { $0.id != location.folderID } // malformed devices sometimes list a folder inside itself
                    .map { Self.item(from: $0, location: location) }
            }
            all += batch
            await onBatch(batch, ids.count)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Log.info("mtp", "Listed \(all.count) items in \(ms) ms (\(ids.isEmpty ? 0 : ms / ids.count) ms per item)")
        return all
    }

    func refreshItem(_ item: RemoteItem) async throws -> RemoteItem? {
        do {
            return try await call { dev in
                var o = zapdrop_object()
                let status = zapdrop_object_info(dev, item.id, &o)
                guard status == ZAPDROP_OK else { throw self.error(for: status, device: dev, context: "info") }
                defer { zapdrop_free(o.name) }
                return Self.item(from: o, location: RemoteLocation(storageID: item.storageID, folderID: item.parentID))
            }
        } catch ZapdropError.sourceRemoved {
            return nil
        }
    }

    func thumbnail(for item: RemoteItem) async throws -> Data? {
        try await call { dev in
            var data: UnsafeMutablePointer<UInt8>?
            var size: UInt32 = 0
            let status = zapdrop_thumbnail(dev, item.id, &data, &size)
            defer { zapdrop_free(data) }
            if status == ZAPDROP_ERR_DISCONNECTED { throw ZapdropError.deviceDisconnected }
            guard status == ZAPDROP_OK, let data, size > 0, size < 16 * 1024 * 1024 else { return nil }
            return Data(bytes: data, count: Int(size))
        }
    }

    func download(_ item: RemoteItem, into sink: ByteSink,
                  progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        let flag = CancellationFlag()
        let context = DownloadContext(sink: sink, progress: progress, flag: flag)
        let expected = item.size ?? ZAPDROP_SIZE_UNKNOWN
        return try await withTaskCancellationHandler {
            try await call { dev in
                if flag.isCancelled { throw ZapdropError.cancelled }
                let ctx = Unmanaged.passUnretained(context).toOpaque()
                let status = withExtendedLifetime(context) {
                    zapdrop_download(dev, item.id, expected, largeFileWindow, writeCallback, progressCallback, ctx)
                }
                if status == ZAPDROP_ERR_SINK, let e = context.sinkError { throw e }
                guard status == ZAPDROP_OK else { throw self.error(for: status, device: dev, context: "download") }
                return context.bytes
            }
        } onCancel: {
            flag.cancel()
        }
    }

    func createFolder(named name: String, in location: RemoteLocation) async throws -> RemoteItem {
        try await call { dev in
            var id: UInt32 = 0
            let status = zapdrop_create_folder(dev, location.storageID, location.folderID, name, &id)
            guard status == ZAPDROP_OK else { throw self.error(for: status, device: dev, context: "create folder") }
            return RemoteItem(id: id, storageID: location.storageID, parentID: location.folderID, name: name,
                              isFolder: true, size: nil, modified: Date())
        }
    }

    func upload(named name: String, size: UInt64, to location: RemoteLocation, from source: ByteSource,
                progress: @escaping @Sendable (UInt64) -> Void) async throws -> RemoteItem {
        // One MTP SendObject carries a 32-bit length.
        guard size < 0xFFFF_FFFF else { throw ZapdropError.fileTooLargeForPhone }
        let flag = CancellationFlag()
        let context = UploadContext(source: source, progress: progress, flag: flag)
        return try await withTaskCancellationHandler {
            try await call { dev in
                if flag.isCancelled { throw ZapdropError.cancelled }
                var id: UInt32 = 0
                let ctx = Unmanaged.passUnretained(context).toOpaque()
                let status = withExtendedLifetime(context) {
                    zapdrop_upload(dev, location.storageID, location.folderID, name, size, readCallback,
                                   uploadProgressCallback, ctx, &id)
                }
                if status == ZAPDROP_ERR_SINK, let e = context.sourceError { throw e }
                guard status == ZAPDROP_OK else { throw self.error(for: status, device: dev, context: "upload") }
                return RemoteItem(id: id, storageID: location.storageID, parentID: location.folderID, name: name,
                                  isFolder: false, size: size, modified: Date())
            }
        } onCancel: {
            flag.cancel()
        }
    }

    func batteryPercent() async -> Int? {
        guard let percent = try? await call({ dev in zapdrop_battery_percent(dev) }), percent >= 0 else { return nil }
        return Int(percent)
    }

    func close() async {
        let handle = self.handle
        _ = try? await queue.run { handle.closeNow() }
    }
}
