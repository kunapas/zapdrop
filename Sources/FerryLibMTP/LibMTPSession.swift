import Foundation
import FerryCore
import CFerryMTP

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

private let writeCallback: ferry_write_fn = { ctx, data, length in
    guard let ctx else { return 1 }
    let c = Unmanaged<DownloadContext>.fromOpaque(ctx).takeUnretainedValue()
    if c.flag.isCancelled { return 2 }
    do {
        try c.sink.write(UnsafeRawBufferPointer(start: data, count: Int(length)))
        c.bytes = ProgressMath.add(c.bytes, UInt64(length))
        c.progress(c.bytes)
        return 0
    } catch let e as FerryError where e == .cancelled {
        return 2
    } catch {
        c.sinkError = error
        return 1
    }
}

private let progressCallback: ferry_progress_fn = { ctx, _, _ in
    guard let ctx else { return 0 }
    return Unmanaged<DownloadContext>.fromOpaque(ctx).takeUnretainedValue().flag.isCancelled ? 1 : 0
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

    /// Turns a C status into a `FerryError`, checking whether the phone is still plugged in.
    private func error(for status: ferry_status, device: OpaquePointer?, context: String) -> FerryError {
        let detail = device.map { String(cString: ferry_last_error($0)) } ?? ""
        Log.warning("mtp", "\(context) failed: status \(status.rawValue) \(detail)")
        switch status {
        case FERRY_ERR_CANCELLED: return .cancelled
        case FERRY_ERR_NOT_FOUND: return .sourceRemoved
        case FERRY_ERR_DISCONNECTED, FERRY_ERR_NO_DEVICE: return .deviceDisconnected
        case FERRY_ERR_UNSUPPORTED: return .fileTooLargeForPhone
        case FERRY_ERR_BUSY: return .deviceBusy(holder: nil)
        case FERRY_ERR_STORAGE_FULL, FERRY_ERR_NO_MEMORY:
            return .protocolError(detail: "\(context): \(detail)")
        default:
            let code = device.map { ferry_last_ptp_code($0) } ?? 0
            return .protocolError(detail: "\(context): PTP 0x\(String(code, radix: 16)) \(detail)")
        }
    }

    /// A protocol error while the phone has vanished from USB is really a disconnect.
    private func refine(_ e: FerryError) async -> FerryError {
        if case .protocolError = e, !(await LibMTPBackend.isPresent(usb)) { return .deviceDisconnected }
        return e
    }

    private func call<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
        do {
            let handle = self.handle
            return try await queue.run { try body(try handle.get()) }
        } catch let e as FerryError {
            throw await refine(e)
        }
    }

    func storages() async throws -> [StorageInfo] {
        let list = try await rawStorages()
        // libmtp reports a failed storage request as "no storage" — the same as a locked phone.
        if list.isEmpty, !(await LibMTPBackend.isPresent(usb)) { throw FerryError.deviceDisconnected }
        return list
    }

    private func rawStorages() async throws -> [StorageInfo] {
        try await call { dev in
            var buffer = [ferry_storage](repeating: ferry_storage(), count: 16)
            var count: Int32 = 0
            let status = buffer.withUnsafeMutableBufferPointer { ferry_storages(dev, $0.baseAddress, Int32($0.count), &count) }
            guard status == FERRY_OK else { throw self.error(for: status, device: dev, context: "storages") }
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

    static func item(from o: ferry_object, location: RemoteLocation?) -> RemoteItem {
        let name = o.name.map { String(cString: $0) } ?? ""
        // 0xFFFFFFFF: the phone reported a large file without its exact 64-bit size.
        let size: UInt64? = o.size == 0xFFFF_FFFF ? nil : o.size
        let modified: Date? = o.mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(o.mtime)) : nil
        return RemoteItem(id: o.id, storageID: location?.storageID ?? o.storage_id,
                          parentID: location?.folderID ?? o.parent_id, name: name, isFolder: o.is_folder != 0,
                          size: size, modified: modified)
    }

    func children(of location: RemoteLocation) async throws -> [RemoteItem] {
        try await call { dev in
            var objects: UnsafeMutablePointer<ferry_object>?
            var count: Int32 = 0
            let status = ferry_list(dev, location.storageID, location.folderID, &objects, &count)
            guard status == FERRY_OK else { throw self.error(for: status, device: dev, context: "list") }
            defer { ferry_free_objects(objects, count) }
            guard let objects, count > 0 else { return [] }
            return UnsafeBufferPointer(start: objects, count: Int(count))
                .filter { $0.id != location.folderID } // malformed devices sometimes list a folder inside itself
                .map { Self.item(from: $0, location: location) }
        }
    }

    func refreshItem(_ item: RemoteItem) async throws -> RemoteItem? {
        do {
            return try await call { dev in
                var o = ferry_object()
                let status = ferry_object_info(dev, item.id, &o)
                guard status == FERRY_OK else { throw self.error(for: status, device: dev, context: "info") }
                defer { ferry_free(o.name) }
                return Self.item(from: o, location: RemoteLocation(storageID: item.storageID, folderID: item.parentID))
            }
        } catch FerryError.sourceRemoved {
            return nil
        }
    }

    func thumbnail(for item: RemoteItem) async throws -> Data? {
        try await call { dev in
            var data: UnsafeMutablePointer<UInt8>?
            var size: UInt32 = 0
            let status = ferry_thumbnail(dev, item.id, &data, &size)
            defer { ferry_free(data) }
            if status == FERRY_ERR_DISCONNECTED { throw FerryError.deviceDisconnected }
            guard status == FERRY_OK, let data, size > 0, size < 16 * 1024 * 1024 else { return nil }
            return Data(bytes: data, count: Int(size))
        }
    }

    func download(_ item: RemoteItem, into sink: ByteSink,
                  progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        let flag = CancellationFlag()
        let context = DownloadContext(sink: sink, progress: progress, flag: flag)
        let expected = item.size ?? FERRY_SIZE_UNKNOWN
        return try await withTaskCancellationHandler {
            try await call { dev in
                if flag.isCancelled { throw FerryError.cancelled }
                let ctx = Unmanaged.passUnretained(context).toOpaque()
                let status = withExtendedLifetime(context) {
                    ferry_download(dev, item.id, expected, largeFileWindow, writeCallback, progressCallback, ctx)
                }
                if status == FERRY_ERR_SINK, let e = context.sinkError { throw e }
                guard status == FERRY_OK else { throw self.error(for: status, device: dev, context: "download") }
                return context.bytes
            }
        } onCancel: {
            flag.cancel()
        }
    }

    func close() async {
        let handle = self.handle
        _ = try? await queue.run { handle.closeNow() }
    }
}
