import AppKit
import Foundation
import ImageIO
import IOKit
import OSLog
import UniformTypeIdentifiers
import FerryAppModel
import FerryCore

typealias Model = AppModel<CGImage>

// MARK: - Logging (local only; file names are marked private so macOS redacts them in logs)

struct OSLogLogger: ApplicationLogger {
    private let subsystem = Bundle.main.bundleIdentifier ?? "io.github.ferry-mtp.Ferry"

    func log(_ level: LogLevel, _ category: String, _ message: String, privateValue: String?) {
        let logger = Logger(subsystem: subsystem, category: category)
        let type: OSLogType
        switch level {
        case .debug: type = .debug
        case .info: type = .info
        case .warning: type = .default
        case .error: type = .error
        }
        if let privateValue {
            logger.log(level: type, "\(message, privacy: .public) \(privateValue, privacy: .private)")
        } else {
            logger.log(level: type, "\(message, privacy: .public)")
        }
    }
}

// MARK: - Thumbnails

enum ThumbnailDecoder {
    /// Downscales on decode so memory stays small regardless of the original image size.
    @Sendable static func decode(_ data: Data) -> (CGImage, cost: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (image, image.bytesPerRow * image.height)
    }
}

// MARK: - Who holds the phone?

/// Reads IORegistry's `UsbExclusiveOwner` ("pid 123, ptpcamerad") for the phone and its interfaces.
struct IOKitExclusiveAccessInspector: ExclusiveAccessInspecting {
    func holderName(vendorID: UInt16, productID: UInt16) -> String? {
        let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        matching["idVendor"] = NSNumber(value: vendorID)
        matching["idProduct"] = NSNumber(value: productID)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFDictionary, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        // `while case let` binds a fresh constant per pass, so `defer` releases the current object.
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let owner = owner(of: service) ?? ownerOfChildren(of: service) { return Self.friendlyName(owner) }
        }
        return nil
    }

    private func owner(of entry: io_registry_entry_t) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(entry, "UsbExclusiveOwner" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        return value as? String
    }

    private func ownerOfChildren(of entry: io_registry_entry_t) -> String? {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            if let o = owner(of: child) { return o }
        }
        return nil
    }

    static func friendlyName(_ raw: String) -> String {
        let process = raw.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? raw
        switch process {
        case "ptpcamerad", "icdd", "PTPCamera": return "the macOS camera service (\(process))"
        case "Image Capture": return "Image Capture"
        case "Photos", "photolibraryd": return "Photos"
        case "Android File Transfer", "Android File Transfer Agent": return "Android File Transfer"
        default: return process
        }
    }
}

// MARK: - Releasing the phone from ptpcamerad (user-initiated only)

struct CameraDaemonReleaser: CameraDaemonReleasing {
    /// Ends the current user's `ptpcamerad`. macOS starts it again when it is next needed.
    func release() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                process.arguments = ["ptpcamerad"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

// MARK: - Finder helpers

@MainActor
enum FinderBridge {
    static func chooseFolder(startingAt url: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Where to Save"
        panel.prompt = "Choose"
        panel.message = "Files from your phone will be copied into this folder."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = url ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Display helpers

extension RemoteItem {
    var sortSize: UInt64 { size ?? 0 }
    var sortDate: Date { modified ?? .distantPast }

    var kindDescription: String {
        let ext = (name as NSString).pathExtension.uppercased()
        switch kind {
        case .folder: return "Folder"
        case .photo: return ext.isEmpty ? "Image" : "\(ext) image"
        case .video: return ext.isEmpty ? "Video" : "\(ext) video"
        case .audio: return ext.isEmpty ? "Audio" : "\(ext) audio"
        case .document: return ext.isEmpty ? "Document" : "\(ext) document"
        case .archive: return "Archive"
        case .app: return "Android app package"
        case .other: return ext.isEmpty ? "File" : "\(ext) file"
        }
    }

    var sizeDescription: String { isFolder ? "—" : (size.map(ByteFormatter.string) ?? "Unknown") }

    var dateDescription: String {
        guard let modified else { return "—" }
        return modified.formatted(date: .abbreviated, time: .shortened)
    }
}

extension FileKind {
    var symbolName: String {
        switch self {
        case .folder: return "folder.fill"
        case .photo: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return "doc.text"
        case .archive: return "doc.zipper"
        case .app: return "shippingbox"
        case .other: return "doc"
        }
    }
}
