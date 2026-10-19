import Foundation

/// Opaque identifier for a connected phone. For libmtp it encodes USB bus/address; for the mock it is a label.
public struct DeviceID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public typealias StorageID = UInt32
public typealias ObjectID = UInt32

/// MTP's "parent" value for the top level of a storage.
public let rootParentID: ObjectID = 0xFFFF_FFFF

public struct DeviceSummary: Hashable, Sendable, Identifiable {
    public let id: DeviceID
    public var manufacturer: String?
    public var model: String?
    public var friendlyName: String?
    public var vendorID: UInt16
    public var productID: UInt16

    public init(id: DeviceID, manufacturer: String? = nil, model: String? = nil, friendlyName: String? = nil,
                vendorID: UInt16 = 0, productID: UInt16 = 0) {
        self.id = id
        self.manufacturer = manufacturer
        self.model = model
        self.friendlyName = friendlyName
        self.vendorID = vendorID
        self.productID = productID
    }

    /// Best human-readable name. Device-provided strings are untrusted: they are cleaned for display.
    public var displayName: String {
        for candidate in [friendlyName, model, manufacturer.map { "\($0) phone" }] {
            if let c = candidate.map(DisplayText.clean), !c.isEmpty { return c }
        }
        if let vendor = KnownPhoneVendors.name(for: vendorID) { return "\(vendor) phone" }
        return "Android phone"
    }
}

public struct StorageInfo: Hashable, Sendable, Identifiable {
    public let id: StorageID
    public var description: String
    public var volumeLabel: String?
    public var capacityBytes: UInt64
    public var freeBytes: UInt64
    public var isRemovable: Bool
    public var isReadOnly: Bool

    public init(id: StorageID, description: String, volumeLabel: String? = nil, capacityBytes: UInt64,
                freeBytes: UInt64, isRemovable: Bool = false, isReadOnly: Bool = false) {
        self.id = id
        self.description = description
        self.volumeLabel = volumeLabel
        self.capacityBytes = capacityBytes
        self.freeBytes = freeBytes
        self.isRemovable = isRemovable
        self.isReadOnly = isReadOnly
    }

    public var displayName: String {
        let d = DisplayText.clean(description)
        if !d.isEmpty { return d }
        if let l = volumeLabel.map(DisplayText.clean), !l.isEmpty { return l }
        return isRemovable ? "SD card" : "Internal storage"
    }

    public var usedBytes: UInt64 { capacityBytes >= freeBytes ? capacityBytes - freeBytes : 0 }
}

/// Broad kind used for icons and filters.
public enum FileKind: String, CaseIterable, Sendable, Hashable {
    case folder, photo, video, audio, document, archive, app, other

    private static let table: [String: FileKind] = {
        var t: [String: FileKind] = [:]
        func add(_ k: FileKind, _ exts: String) { for e in exts.split(separator: " ") { t[String(e)] = k } }
        add(.photo, "jpg jpeg jpe png heic heif gif webp bmp tif tiff dng raw cr2 cr3 nef arw orf rw2 avif jxl")
        add(.video, "mp4 m4v mov 3gp 3g2 mkv webm avi wmv mts m2ts ts mpg mpeg")
        add(.audio, "mp3 m4a aac wav flac ogg oga opus amr awb wma mid midi aiff aif")
        add(.document, "pdf doc docx xls xlsx ppt pptx txt rtf odt ods odp csv tsv md epub pages numbers key json xml html htm vcf ics log")
        add(.archive, "zip rar 7z tar gz tgz bz2 xz zst")
        add(.app, "apk apks xapk aab obb")
        return t
    }()

    public static func classify(fileName: String, isFolder: Bool) -> FileKind {
        if isFolder { return .folder }
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return .other }
        let ext = fileName[fileName.index(after: dot)...].lowercased()
        return table[ext] ?? .other
    }
}

/// A file or folder on the phone. All metadata comes from the device and is treated as untrusted.
public struct RemoteItem: Hashable, Sendable, Identifiable {
    public let id: ObjectID
    public let storageID: StorageID
    public let parentID: ObjectID
    /// The exact name reported by the phone. Never used as a path without `FileNameSanitizer`.
    public let name: String
    public let isFolder: Bool
    /// Size in bytes (64-bit). `nil` when the phone did not report a usable size.
    public let size: UInt64?
    public let modified: Date?

    public init(id: ObjectID, storageID: StorageID, parentID: ObjectID, name: String, isFolder: Bool,
                size: UInt64?, modified: Date?) {
        self.id = id
        self.storageID = storageID
        self.parentID = parentID
        self.name = name
        self.isFolder = isFolder
        self.size = isFolder ? nil : size
        self.modified = modified
    }

    public var kind: FileKind { FileKind.classify(fileName: name, isFolder: isFolder) }
    public var displayName: String { DisplayText.clean(name) }
}

/// A folder location on the phone: storage + folder object (or the storage root).
public struct RemoteLocation: Hashable, Sendable {
    public let storageID: StorageID
    public let folderID: ObjectID
    public init(storageID: StorageID, folderID: ObjectID = rootParentID) {
        self.storageID = storageID
        self.folderID = folderID
    }
    public var isRoot: Bool { folderID == rootParentID }
}

/// Connection state of the currently selected phone, as shown to the user.
public enum DeviceConnectionState: Equatable, Sendable {
    case noDevice
    case chargingOnly(DeviceSummary)
    case awaitingAuthorization(DeviceSummary)
    case locked(DeviceSummary)
    case busy(DeviceSummary, holder: String?)
    case ready(DeviceSummary)
    case unsupported(DeviceSummary, reason: String)
    case disconnected(DeviceSummary)
    /// The user ejected the phone: Zapdrop has let go of it and won't reconnect until asked or it is plugged in again.
    case ejected(DeviceSummary)

    public var device: DeviceSummary? {
        switch self {
        case .noDevice: return nil
        case .chargingOnly(let d), .awaitingAuthorization(let d), .locked(let d), .ready(let d),
             .disconnected(let d), .ejected(let d): return d
        case .busy(let d, _), .unsupported(let d, _): return d
        }
    }

    public var isReady: Bool { if case .ready = self { return true } else { return false } }
}

/// Strips control and bidirectional-override characters from device-provided text before display.
public enum DisplayText {
    public static func clean(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if FileNameSanitizer.isUnsafeScalar(scalar) { continue }
            out.append(scalar)
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
