import Foundation

/// Turns an untrusted phone file name into a single safe path component for the Mac.
///
/// Rules (documented in docs/ARCHITECTURE.md):
/// - `/` and `:` become `_` (a component can never introduce a path separator; `:` shows as `/` in Finder).
/// - NUL, control characters and bidirectional-override characters (used to disguise extensions) are replaced.
/// - Empty names, `.` and `..` become "Untitled".
/// - Unicode is normalised to NFC.
/// - Length is capped at 255 UTF-8 bytes, keeping the extension and whole characters.
/// Leading dots are preserved (Android uses `.nomedia` etc.); such files are hidden in Finder, as on the phone.
public enum FileNameSanitizer {
    public static let maxComponentBytes = 255
    public static let placeholder = "Untitled"

    public struct Result: Equatable, Sendable {
        public let name: String
        public let wasChanged: Bool
    }

    static func isUnsafeScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x00...0x1F, 0x7F...0x9F: return true                 // C0/C1 controls, DEL
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true // bidi marks/overrides/isolates
        case 0xFEFF: return true                                     // BOM / zero-width no-break space
        default: return false
        }
    }

    public static func sanitize(_ raw: String) -> Result {
        var scalars = String.UnicodeScalarView()
        for s in raw.unicodeScalars {
            if s == "/" || s == ":" || isUnsafeScalar(s) {
                scalars.append("_")
            } else {
                scalars.append(s)
            }
        }
        var name = String(scalars).precomposedStringWithCanonicalMapping

        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." {
            name = placeholder
        }
        name = truncate(name, toUTF8Bytes: maxComponentBytes)
        return Result(name: name, wasChanged: name != raw)
    }

    /// Splits "photo.jpg" → ("photo", ".jpg"); ".nomedia" → (".nomedia", ""); "archive.tar.gz" → ("archive.tar", ".gz").
    public static func splitExtension(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = String(name[dot...])
        // Treat very long or space-containing "extensions" as part of the name.
        if ext.utf8.count > 33 || ext.contains(" ") { return (name, "") }
        return (String(name[..<dot]), ext)
    }

    static func truncate(_ name: String, toUTF8Bytes limit: Int) -> String {
        guard name.utf8.count > limit else { return name }
        let (base, ext) = splitExtension(name)
        let budget = max(1, limit - ext.utf8.count)
        var out = ""
        var used = 0
        for ch in base { // whole grapheme clusters only
            let n = String(ch).utf8.count
            if used + n > budget { break }
            out.append(ch); used += n
        }
        if out.isEmpty { out = "_" }
        let result = out + ext
        // If the extension alone was too long, fall back to a hard cut on characters.
        if result.utf8.count > limit {
            var hard = ""
            for ch in result { if (hard + String(ch)).utf8.count > limit { break }; hard.append(ch) }
            return hard
        }
        return result
    }

    /// The name used for the n-th "keep both" copy: "photo.jpg" → "photo (1).jpg".
    public static func numberedVariant(of name: String, number: Int) -> String {
        let (base, ext) = splitExtension(name)
        let suffix = " (\(number))"
        let candidate = base + suffix + ext
        if candidate.utf8.count <= maxComponentBytes { return candidate }
        let shortenedBase = truncate(base, toUTF8Bytes: maxComponentBytes - suffix.utf8.count - ext.utf8.count)
        return shortenedBase + suffix + ext
    }

    /// Key used to detect names that collide on the Mac's (usually case-insensitive) file system.
    public static func collisionKey(_ name: String, caseSensitive: Bool) -> String {
        let nfc = name.precomposedStringWithCanonicalMapping
        return caseSensitive ? nfc : nfc.lowercased()
    }
}

/// Builds destination paths that are guaranteed to stay inside the chosen root folder.
public enum SafePath {
    /// Joins already-sanitised components under `root`, rejecting anything that could escape it.
    public static func join(root: URL, components: [String]) throws -> URL {
        var url = root.standardizedFileURL
        for c in components {
            guard !c.isEmpty, c != ".", c != "..", !c.contains("/"), !c.contains("\0") else {
                throw FerryError.unsafeDestinationPath
            }
            url.appendPathComponent(c, isDirectory: false)
        }
        let rootPath = root.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let resolved = url.standardizedFileURL.path
        guard components.isEmpty || resolved.hasPrefix(rootPrefix) else { throw FerryError.unsafeDestinationPath }
        return url
    }
}
