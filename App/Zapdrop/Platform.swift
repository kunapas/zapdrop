import AppKit
import SwiftUI
import Foundation
import ImageIO
import IOKit
import OSLog
import UniformTypeIdentifiers
import ZapdropAppModel
import ZapdropCore

typealias Model = AppModel<CGImage>

// MARK: - Logging (local only; file names are marked private so macOS redacts them in logs)

struct OSLogLogger: ApplicationLogger {
    private let subsystem = Bundle.main.bundleIdentifier ?? "io.github.kunapas.Zapdrop"

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
    /// The bytes come from the phone. Only the formats phones really use for pictures are handed to ImageIO, which
    /// keeps its many rarer parsers (TIFF, PSD, camera RAW, PDF…) out of reach of a hostile device.
    static func isCommonImage(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(12))
        guard head.count == 12 else { return false }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return true }                          // JPEG
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true } // PNG
        if head.starts(with: Array("GIF8".utf8)) { return true }
        if head.starts(with: Array("RIFF".utf8)), Array(head[8...]) == Array("WEBP".utf8) { return true }
        if Array(head[4..<8]) == Array("ftyp".utf8) {                                     // HEIC / HEIF / AVIF
            return ["heic", "heix", "hevc", "mif1", "msf1", "avif"].contains(String(decoding: head[8...], as: UTF8.self))
        }
        return false
    }

    /// Downscales on decode so memory stays small regardless of the original image size.
    @Sendable static func decode(_ data: Data) -> (CGImage, cost: Int)? {
        guard isCommonImage(data) else { return nil }
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

// MARK: - Freeing the phone (user-initiated only)

/// Ends macOS's camera service (`ptpcamerad`), which grabs phones on its own, and, when asked, first quits apps that
/// commonly take phones over USB. Apps are only quit after the user clicks "Free Up Phone & Connect" or chooses
/// "Always do this automatically"; the camera service is released automatically unless turned off in Settings.
struct PhoneReleaser: PhoneReleasing {
    /// Display names and bundle IDs of apps known to claim Android phones (MTP/PTP) while they're open.
    private static let names: Set<String> = ["image capture", "photos", "android file transfer", "android file transfer agent",
                                             "smart switch", "openmtp", "macdroid", "handshaker", "commander one"]
    private static let bundleIDs: Set<String> = ["com.apple.Image_Capture", "com.apple.Photos", "com.google.android.mtpviewer",
                                                 "com.google.android.mtpagent"]

    @MainActor
    private static func running() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            // Apple's and Google's by bundle ID. The rest by name, but never an app from Apple: another app that
            // merely shares a name with one of these must not be asked to quit.
            guard let id = app.bundleIdentifier else { return false }
            if bundleIDs.contains(id) { return true }
            if id.hasPrefix("com.apple.") { return false }
            return app.localizedName.map { names.contains($0.lowercased()) } ?? false
        }
    }

    func competingApps() async -> [String] {
        await MainActor.run {
            // The Android File Transfer agent is part of Android File Transfer; show one name.
            let display = Self.running().compactMap { $0.localizedName?.replacingOccurrences(of: " Agent", with: "") }
            return Array(Set(display)).sorted()
        }
    }

    func release(quittingApps: Bool) async {
        guard quittingApps else { return await Self.endCameraService() }
        let count = await MainActor.run { () -> Int in
            let apps = Self.running()
            apps.forEach { $0.terminate() } // a normal Quit: apps can save what they're doing
            return apps.count
        }
        if count > 0 {
            // Give them up to three seconds to let go of the phone.
            for _ in 0..<20 {
                if await MainActor.run(body: { Self.running().isEmpty }) { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        await Self.endCameraService()
    }

    /// Ends the current user's `ptpcamerad`. macOS starts it again when it is next needed (about a second later
    /// while a phone is plugged in). It ignores SIGTERM on recent macOS, so it has to be SIGKILL.
    private static func endCameraService() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                process.arguments = ["-KILL", "ptpcamerad"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                if (try? process.run()) != nil { process.waitUntilExit() }
                continuation.resume()
            }
        }
    }
}

// MARK: - Support link

/// The optional "Buy Me a Coffee" link, set at build time (Scripts/config.sh SUPPORT_URL → Info.plist
/// ZapdropSupportURL). Only https links are accepted; anything else hides the menu items.
enum SupportLink {
    static let url: URL? = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ZapdropSupportURL") as? String,
              let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }()
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

    /// Files and folders copied in Finder (⌘C), ready to paste onto the phone.
    static func filesOnPasteboard() -> [URL] {
        let found = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (found as? [URL]) ?? []
    }

    /// Files and folders on the Mac to copy to the phone.
    static func chooseItemsToSend() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Copy to Phone"
        panel.prompt = "Copy"
        panel.message = "Choose files or folders to copy into the folder shown on your phone."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Opens the folder itself in Finder (not its parent with the folder selected).
    static func open(folder url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Opens `folder` in Finder with the given items in it selected; just the folder if none of them exist.
    static func show(_ items: [URL], in folder: URL) {
        let existing = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty { open(folder: folder) } else { NSWorkspace.shared.activateFileViewerSelecting(existing) }
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

// MARK: - Window pictures (design aid)

/// `--snapshot=/path/to/file.png [--snapshot-delay=seconds]` saves a picture of the main window, title bar included,
/// then quits. For reviewing the design without screen recording: the window draws itself into the file.
/// (One word each: AppKit takes a bare path on the command line for a document to open.)
@MainActor
enum WindowSnapshot {
    static func runIfRequested(model: Model) async {
        func value(_ name: String) -> String? {
            ProcessInfo.processInfo.arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
        }
        guard let path = value("--snapshot") else { return }
        let delay = value("--snapshot-delay").flatMap(Double.init) ?? 3
        try? await Task.sleep(for: .seconds(delay))
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
           let frame = window.contentView?.superview,
           let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        // Plain SwiftUI pages don't draw into the window picture, so the status page is also rendered on its own.
        let page = DeviceStatusView(model: model)
            .frame(width: 640, height: 860)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
        let renderer = ImageRenderer(content: page)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            let pagePath = (path as NSString).deletingPathExtension + "-status.png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: pagePath))
        }
        NSApp.terminate(nil)
    }
}
