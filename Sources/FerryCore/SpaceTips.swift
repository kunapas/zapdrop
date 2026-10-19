import Foundation

/// A file on the phone together with the folders leading to it.
public struct AnalyzedFile: Sendable, Hashable, Identifiable {
    public let item: RemoteItem
    /// Folders from the storage root down to the file's parent.
    public let folders: [RemoteItem]
    public var id: ObjectID { item.id }
    public var size: UInt64 { item.size ?? 0 }
    public var folderPath: [String] { folders.map(\.name) }
    /// "DCIM/Camera" — for display.
    public var folderDescription: String { folders.isEmpty ? "/" : folders.map(\.displayName).joined(separator: "/") }

    public init(item: RemoteItem, folders: [RemoteItem]) {
        self.item = item
        self.folders = folders
    }
}

// MARK: - Tips

/// One suggestion for freeing space. Zapdrop never deletes anything on the phone: tips say what to remove and
/// where, and list the files so they can be copied to the Mac first.
public struct SpaceTip: Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case lowSpace, largeVideos, oldCameraMedia, screenshots, chatMedia, duplicates, installers,
             oldDownloads, archives, thumbnailCache
    }

    public let kind: Kind
    public let title: String
    public let detail: String
    /// Space that acting on the tip could free (for `lowSpace`: what's free now).
    public let bytes: UInt64
    /// The files concerned, largest first (capped; `fileCount` is the full number).
    public let files: [AnalyzedFile]
    public let fileCount: Int
    public var id: Kind { kind }

    public static let maxListedFiles = 200

    static func largestFirst(_ a: AnalyzedFile, _ b: AnalyzedFile) -> Bool {
        a.size != b.size ? a.size > b.size : a.item.id < b.item.id
    }

    /// Tips for `files` (a whole storage area or just one folder), biggest saving first. `maxListed` caps the
    /// files kept per tip; `warnAboutLowSpace` adds a first tip when the storage area is under 10 % free.
    public static func make(storage: StorageInfo, files: [AnalyzedFile], now: Date = Date(),
                            maxListed: Int = maxListedFiles, warnAboutLowSpace: Bool = true) -> [SpaceTip] {
        let mb: UInt64 = 1_000_000
        var tips: [SpaceTip] = []

        func tip(_ kind: Kind, _ matching: [AnalyzedFile], minBytes: UInt64, title: (Int, UInt64) -> String,
                 detail: String) {
            let total = matching.reduce(UInt64(0)) { ProgressMath.add($0, $1.size) }
            guard !matching.isEmpty, total >= minBytes else { return }
            tips.append(SpaceTip(kind: kind, title: title(matching.count, total), detail: detail, bytes: total,
                                 files: Array(matching.sorted(by: largestFirst).prefix(maxListed)),
                                 fileCount: matching.count))
        }
        func lower(_ f: AnalyzedFile) -> [String] { f.folderPath.map { $0.lowercased() } }
        func plural(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }
        let size = ByteFormatter.string

        let yearAgo = now.addingTimeInterval(-365 * 24 * 3600)
        let quarterAgo = now.addingTimeInterval(-90 * 24 * 3600)
        let chatRoots: Set<String> = ["whatsapp", "telegram", "signal", "viber"]
        let chatApps = ["com.whatsapp", "com.whatsapp.w4b", "org.telegram.messenger", "org.thoughtcrime.securesms", "com.viber.voip"]

        tip(.largeVideos, files.filter { $0.item.kind == .video && $0.size >= 500 * mb }, minBytes: 1,
            title: { n, b in "\(plural(n, "large video")) (\(size(b)))" },
            detail: "Videos over 500 MB take the most room. Copy them to your Mac, then delete them on the phone.")

        tip(.oldCameraMedia, files.filter { f in
            let p = lower(f)
            return p.first == "dcim" && p.contains("camera") && (f.item.kind == .photo || f.item.kind == .video)
                && f.size < 500 * mb && (f.item.modified.map { $0 < yearAgo } ?? false)
        }, minBytes: 500 * mb,
            title: { n, b in "\(n == 1 ? "1 photo or video" : "\(n) photos and videos") over a year old (\(size(b)))" },
            detail: "Back them up to your Mac with Zapdrop, then free the space on the phone. In Google Photos, "
                + "“Free up space” removes only photos that are already backed up.")

        tip(.screenshots, files.filter { lower($0).contains("screenshots") && $0.item.kind == .photo },
            minBytes: 50 * mb,
            title: { n, b in "\(plural(n, "screenshot")) (\(size(b)))" },
            detail: "Most screenshots are only needed for a short time. Copy any you want to keep, then delete the rest.")

        tip(.chatMedia, files.filter { f in
            let p = lower(f)
            guard let top = p.first else { return false }
            if chatRoots.contains(top) { return true }
            return top == "android" && p.count > 2 && p[1] == "media" && chatApps.contains(p[2])
        }, minBytes: 200 * mb,
            title: { _, b in "Chat photos and videos (\(size(b)))" },
            detail: "In WhatsApp, Settings › Storage and data › Manage storage shows the biggest chats and forwarded "
                + "files. Telegram can clear its cache in Settings › Data and storage.")

        // Same name (ignoring case) and same size in different folders: almost always copies of one file.
        var groups: [String: [AnalyzedFile]] = [:]
        for f in files where f.size >= 100_000 {
            groups["\(f.item.name.lowercased())|\(f.size)", default: []].append(f)
        }
        let extraCopies = groups.values.filter { $0.count > 1 }.flatMap { $0.sorted(by: largestFirst).dropFirst() }
        tip(.duplicates, extraCopies, minBytes: 20 * mb,
            title: { n, b in "\(plural(n, "duplicate file")) (\(size(b)))" },
            detail: "These files have the same name and size as a file in another folder. Keep one copy of each.")

        tip(.installers, files.filter { $0.item.kind == .app }, minBytes: 10 * mb,
            title: { n, b in "\(plural(n, "app installer")) (\(size(b)))" },
            detail: "Installer files (.apk) aren't needed once an app is installed. Delete them in the Files app.")

        tip(.oldDownloads, files.filter { f in
            lower(f).first == "download" && f.item.kind != .app && (f.item.modified.map { $0 < quarterAgo } ?? false)
        }, minBytes: 200 * mb,
            title: { n, b in "\(plural(n, "old download")) (\(size(b)))" },
            detail: "These were downloaded more than 3 months ago. Copy any you want to keep to your Mac, then delete them on the phone.")

        tip(.archives, files.filter { $0.item.kind == .archive }, minBytes: 100 * mb,
            title: { n, b in "\(plural(n, "archive")) (\(size(b)))" },
            detail: "Zip and other archive files are often already unpacked. Delete the ones you've extracted.")

        tip(.thumbnailCache, files.filter { lower($0).contains(".thumbnails") }, minBytes: 100 * mb,
            title: { _, b in "Picture previews (\(size(b)))" },
            detail: "Android keeps small previews in DCIM/.thumbnails and rebuilds them when needed, so this folder is safe to clear.")

        tips.sort { $0.bytes > $1.bytes }
        if warnAboutLowSpace, storage.capacityBytes > 0, storage.freeBytes < storage.capacityBytes / 10 {
            let percent = Int((Double(storage.freeBytes) / Double(storage.capacityBytes) * 100).rounded())
            tips.insert(SpaceTip(kind: .lowSpace, title: "Only \(size(storage.freeBytes)) free (\(percent)%)",
                                 detail: "Phones slow down and can't save new photos or updates when storage is nearly full. "
                                    + "The suggestions below free the most space first.",
                                 bytes: storage.freeBytes, files: [], fileCount: 0), at: 0)
        }
        return tips
    }
}
