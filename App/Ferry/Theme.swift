import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FerryCore

// MARK: - Glass

/// See-through window background: the desktop shows through frosted glass, with a soft wash of colour.
struct GlassBackdrop: View {
    var body: some View {
        ZStack {
            VisualEffectBackground(material: .underWindowBackground, blending: .behindWindow)
            LinearGradient(colors: [Color.indigo.opacity(0.16), Color.teal.opacity(0.09), Color.pink.opacity(0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// AppKit's behind-window blur, which SwiftUI materials can't do on their own.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

extension View {
    /// A floating panel: Liquid Glass on macOS 26, frosted material before.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .background((tint ?? .clear).opacity(0.5), in: shape)
        }
        #else
        background(.regularMaterial, in: shape)
            .background((tint ?? .clear).opacity(0.5), in: shape)
        #endif
    }
}

/// Zapdrop's accent: teal into indigo, used sparingly for the phone and empty states.
enum Brand {
    static let gradient = LinearGradient(colors: [Color(red: 0.16, green: 0.72, blue: 0.70), Color(red: 0.36, green: 0.36, blue: 0.86)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
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
