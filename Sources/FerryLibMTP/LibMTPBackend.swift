import Foundation
import FerryCore
import CFerryMTP

/// Every libmtp call runs here, one at a time (docs/DECISIONS.md D3). Blocking this queue is expected.
final class DeviceQueue: @unchecked Sendable {
    static let shared = DeviceQueue(label: "ferry.mtp.device")
    /// USB scanning uses its own libusb context and queue, so discovery never waits for a long transfer.
    static let scan = DeviceQueue(label: "ferry.usb.scan")

    let queue: DispatchQueue
    init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }

    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}

/// Owns the C device pointer and guarantees it is closed exactly once, on the device queue.
final class DeviceHandle: @unchecked Sendable {
    private var pointer: OpaquePointer?
    init(_ pointer: OpaquePointer) { self.pointer = pointer }

    /// Only call on the device queue.
    func get() throws -> OpaquePointer {
        guard let p = pointer else { throw FerryError.deviceDisconnected }
        return p
    }

    /// Only call on the device queue.
    func closeNow() {
        if let p = pointer { ferry_close(p) }
        pointer = nil
    }

    deinit {
        if let p = pointer {
            let box = UnsafeSendablePointer(p)
            DeviceQueue.shared.queue.async { ferry_close(box.pointer) }
        }
    }
}

struct UnsafeSendablePointer: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ p: OpaquePointer) { pointer = p }
}

/// USB identity of a device; encoded in `DeviceID` as "usb:<bus>:<address>:<vid>:<pid>".
struct USBAddress: Hashable, Sendable {
    let bus: UInt32
    let address: UInt8
    let vendorID: UInt16
    let productID: UInt16

    var deviceID: DeviceID {
        DeviceID("usb:\(bus):\(address):\(String(vendorID, radix: 16)):\(String(productID, radix: 16))")
    }

    init(bus: UInt32, address: UInt8, vendorID: UInt16, productID: UInt16) {
        self.bus = bus; self.address = address; self.vendorID = vendorID; self.productID = productID
    }

    init?(_ id: DeviceID) {
        let parts = id.rawValue.split(separator: ":")
        guard parts.count == 5, parts[0] == "usb", let bus = UInt32(parts[1]), let addr = UInt8(parts[2]),
              let vid = UInt16(parts[3], radix: 16), let pid = UInt16(parts[4], radix: 16) else { return nil }
        self.init(bus: bus, address: addr, vendorID: vid, productID: pid)
    }
}

public final class LibMTPBackend: DeviceBackend, @unchecked Sendable {
    /// Apple devices expose a PTP camera interface but are not MTP phones.
    static let ignoredVendors: Set<UInt16> = [0x05AC]

    public init(debugLogging: Bool = false) {
        ferry_init(debugLogging ? 1 : 0)
    }

    public static var libmtpVersion: String { String(cString: ferry_libmtp_version()) }

    static func scanUSB() async throws -> [ferry_usb_device] {
        try await DeviceQueue.scan.run {
            var buffer = [ferry_usb_device](repeating: ferry_usb_device(), count: 64)
            let n = buffer.withUnsafeMutableBufferPointer { ferry_usb_scan($0.baseAddress, Int32($0.count)) }
            guard n >= 0 else { throw FerryError.protocolError(detail: "libusb scan failed") }
            return Array(buffer.prefix(Int(n)))
        }
    }

    static func isPresent(_ usb: USBAddress) async -> Bool {
        guard let devices = try? await scanUSB() else { return true } // unknown: assume present
        return devices.contains { $0.bus == usb.bus && $0.address == usb.address }
    }

    public func discover() async throws -> [DiscoveredDevice] {
        let devices = try await Self.scanUSB()
        var result: [DiscoveredDevice] = []
        for d in devices where !Self.ignoredVendors.contains(d.vendor_id) {
            let usb = USBAddress(bus: d.bus, address: d.address, vendorID: d.vendor_id, productID: d.product_id)
            let summary = DeviceSummary(id: usb.deviceID, manufacturer: KnownPhoneVendors.name(for: d.vendor_id),
                                        vendorID: d.vendor_id, productID: d.product_id)
            if d.has_mtp_interface != 0 {
                result.append(DiscoveredDevice(summary: summary, mode: .fileTransfer))
            } else if KnownPhoneVendors.isPhoneVendor(d.vendor_id), d.has_excluded_class == 0 {
                result.append(DiscoveredDevice(summary: summary, mode: .chargingOnly))
            }
        }
        return result.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func openSession(_ id: DeviceID) async throws -> any DeviceSession {
        guard let usb = USBAddress(id) else { throw FerryError.noDevice }
        let (handle, summary): (DeviceHandle, DeviceSummary) = try await DeviceQueue.shared.run {
            var pointer: OpaquePointer?
            let status = ferry_open(usb.bus, usb.address, &pointer)
            switch status {
            case FERRY_OK: break
            case FERRY_ERR_BUSY: throw FerryError.deviceBusy(holder: nil)
            case FERRY_ERR_NO_DEVICE: throw FerryError.deviceDisconnected
            case FERRY_ERR_CONNECTING: throw FerryError.notAuthorized
            default: throw FerryError.unsupportedDevice(detail: "ferry_open status \(status.rawValue)")
            }
            guard let pointer else { throw FerryError.unsupportedDevice(detail: "no handle") }
            var manufacturer: UnsafeMutablePointer<CChar>?, model: UnsafeMutablePointer<CChar>?
            var friendly: UnsafeMutablePointer<CChar>?, serial: UnsafeMutablePointer<CChar>?
            ferry_device_strings(pointer, &manufacturer, &model, &friendly, &serial)
            defer { ferry_free(manufacturer); ferry_free(model); ferry_free(friendly); ferry_free(serial) }
            func str(_ p: UnsafeMutablePointer<CChar>?) -> String? { p.map { String(cString: $0) } }
            let summary = DeviceSummary(id: id, manufacturer: str(manufacturer) ?? KnownPhoneVendors.name(for: usb.vendorID),
                                        model: str(model), friendlyName: str(friendly),
                                        vendorID: usb.vendorID, productID: usb.productID)
            return (DeviceHandle(pointer), summary)
        }
        Log.info("mtp", "Opened session with libmtp \(Self.libmtpVersion)")
        return LibMTPSession(handle: handle, usb: usb, summary: summary)
    }
}
