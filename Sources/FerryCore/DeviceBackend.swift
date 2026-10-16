import Foundation

/// What a USB scan found, before any session is opened.
public struct DiscoveredDevice: Hashable, Sendable, Identifiable {
    public enum Mode: Hashable, Sendable {
        /// The phone exposes an MTP (or PTP) interface — file transfer is switched on.
        case fileTransfer
        /// A known phone vendor with no file-transfer interface: probably "Charging only" / "No data transfer".
        case chargingOnly
    }
    public var summary: DeviceSummary
    public var mode: Mode
    public var id: DeviceID { summary.id }

    public init(summary: DeviceSummary, mode: Mode) {
        self.summary = summary
        self.mode = mode
    }
}

/// Receives file data as it arrives from the phone. Called serially, never concurrently.
/// Implementations must not retain the buffer beyond the call.
public protocol ByteSink: AnyObject {
    func write(_ bytes: UnsafeRawBufferPointer) throws
}

/// Entry point to a family of devices (real libmtp, or the mock).
public protocol DeviceBackend: Sendable {
    /// Cheap scan; must not disturb an open session or an active transfer.
    func discover() async throws -> [DiscoveredDevice]
    /// Opens an MTP session. Throws `FerryError.deviceBusy`, `.notAuthorized`, `.deviceDisconnected`, …
    func openSession(_ id: DeviceID) async throws -> any DeviceSession
}

/// An open MTP session with one phone. Implementations serialise all device I/O internally.
public protocol DeviceSession: AnyObject, Sendable {
    var summary: DeviceSummary { get }

    /// Storage areas. An empty list usually means the phone is locked or awaiting "Allow access".
    func storages() async throws -> [StorageInfo]

    /// Direct children of a folder (lazy, one level).
    func children(of location: RemoteLocation) async throws -> [RemoteItem]

    /// Streams one file into `sink` in bounded chunks. Returns the number of bytes delivered.
    /// `progress` receives the cumulative byte count. Honours task cancellation by throwing `FerryError.cancelled`.
    func download(_ item: RemoteItem, into sink: ByteSink,
                  progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64

    /// A small preview image supplied by the phone, if it has one. Returns `nil` when unsupported.
    func thumbnail(for item: RemoteItem) async throws -> Data?

    /// Metadata for one object, or nil if it no longer exists. Note: libmtp caches names and dates for the
    /// whole session (sizes are re-read), so a rename on the phone may only show after reconnecting.
    func refreshItem(_ item: RemoteItem) async throws -> RemoteItem?

    func close() async
}

/// USB vendor IDs of Android phone makers, used only to recognise a phone in "charging only" mode.
public enum KnownPhoneVendors {
    public static let names: [UInt16: String] = [
        0x18D1: "Google", 0x04E8: "Samsung", 0x22B8: "Motorola", 0x1004: "LG", 0x0BB4: "HTC",
        0x0FCE: "Sony", 0x12D1: "Huawei", 0x339B: "Honor", 0x2717: "Xiaomi", 0x2A70: "OnePlus",
        0x22D9: "OPPO", 0x2D95: "vivo", 0x0B05: "ASUS", 0x17EF: "Lenovo", 0x19D2: "ZTE",
        0x2E04: "Nokia", 0x2AE5: "Fairphone", 0x2A45: "Meizu", 0x1BBB: "TCL", 0x1949: "Amazon",
        0x04DD: "Sharp", 0x0482: "Kyocera", 0x2E17: "Essential", 0x05C6: "Qualcomm",
        0x0E8D: "MediaTek", 0x1EBF: "Coolpad",
    ]
    // Deliberately excluded: vendors whose IDs mostly belong to non-phones (Intel, Dell, HP, NVIDIA…).
    // Add entries only from a verifiable source (Android OEM USB driver list or the vendor's own docs).

    public static func name(for vendorID: UInt16) -> String? { names[vendorID] }
    public static func isPhoneVendor(_ vendorID: UInt16) -> Bool { names[vendorID] != nil }
}
