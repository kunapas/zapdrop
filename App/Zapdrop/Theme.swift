import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZapdropCore

/// The app's name and tagline, shown in About and Help.
enum AppInfo {
    static let name = "Zapdrop"
    static let tagline = "Android files to your Mac, in a zap!"
}

/// Zapdrop's colours, taken from its icon: teal into indigo. Used for the artwork on the welcome page and the
/// device header, never for controls (those follow the system accent colour).
enum Brand {
    static let teal = Color(red: 0.16, green: 0.72, blue: 0.70)
    static let indigo = Color(red: 0.36, green: 0.36, blue: 0.86)
    static let gradient = LinearGradient(colors: [teal, indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// A rounded, coloured square with a white symbol: the icon style of System Settings and Finder's sidebar.
struct IconTile: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.54, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// A thick, rounded capacity bar, like the storage bar in iTunes and in About This Mac.
struct CapacityBar: View {
    let fraction: Double
    var low = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(low ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(Brand.gradient))
                    .frame(width: max(8, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

// MARK: - Finder icons

/// The icons Finder uses: folder icons (with the special ones for Downloads, Music, Pictures…) and each
/// document type's own icon. Looked up once per kind and cached.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func image(for item: RemoteItem) -> NSImage {
        let key = item.isFolder ? "folder:" + specialFolder(item.name).map(\.path).orEmpty : "file:" + fileExtension(item.name)
        if let icon = cache[key] { return icon }
        let icon: NSImage
        if item.isFolder {
            if let special = specialFolder(item.name), FileManager.default.fileExists(atPath: special.path) {
                icon = NSWorkspace.shared.icon(forFile: special.path)
            } else {
                icon = NSWorkspace.shared.icon(for: .folder)
            }
        } else {
            icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: fileExtension(item.name)) ?? .data)
        }
        cache[key] = icon
        return icon
    }

    private static func fileExtension(_ name: String) -> String {
        String(FileNameSanitizer.splitExtension(name).ext.dropFirst()).lowercased()
    }

    /// Android's standard folders get the matching Mac folder icon.
    private static func specialFolder(_ name: String) -> URL? {
        let directory: FileManager.SearchPathDirectory?
        switch name.lowercased() {
        case "download", "downloads": directory = .downloadsDirectory
        case "music", "podcasts", "audiobooks": directory = .musicDirectory
        case "pictures", "dcim": directory = .picturesDirectory
        case "movies": directory = .moviesDirectory
        case "documents": directory = .documentDirectory
        default: directory = nil
        }
        return directory.flatMap { FileManager.default.urls(for: $0, in: .userDomainMask).first }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

// MARK: - Space tips

enum TipStyle {
    static func symbol(_ kind: SpaceTip.Kind) -> String {
        switch kind {
        case .lowSpace: return "exclamationmark.triangle.fill"
        case .largeVideos: return "film.stack"
        case .oldCameraMedia: return "camera"
        case .screenshots: return "camera.viewfinder"
        case .chatMedia: return "bubble.left.and.bubble.right"
        case .duplicates: return "doc.on.doc"
        case .installers: return "shippingbox"
        case .oldDownloads: return "arrow.down.circle"
        case .archives: return "archivebox"
        case .thumbnailCache: return "photo.stack"
        }
    }
}
