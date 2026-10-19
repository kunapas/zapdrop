import XCTest
@testable import FerryCore

final class SpaceTipsTests: XCTestCase {
    private let mb: UInt64 = 1_000_000
    private let now = Date(timeIntervalSince1970: 1_790_000_000) // Sep 2026
    private var yearsAgo: Date { now.addingTimeInterval(-2 * 365 * 24 * 3600) }
    private var nextID: ObjectID = 100

    private func storage(capacity: UInt64, free: UInt64) -> StorageInfo {
        StorageInfo(id: 0x0001_0001, description: "Internal shared storage", capacityBytes: capacity, freeBytes: free)
    }

    /// A file at "A/B/name" with made-up folder items leading to it.
    private func file(_ path: String, _ size: UInt64, modified: Date? = nil) -> AnalyzedFile {
        let parts = path.split(separator: "/").map(String.init)
        var folders: [RemoteItem] = []
        var parent = rootParentID
        for name in parts.dropLast() {
            nextID += 1
            folders.append(RemoteItem(id: nextID, storageID: 0x0001_0001, parentID: parent, name: name, isFolder: true,
                                      size: nil, modified: nil))
            parent = nextID
        }
        nextID += 1
        let item = RemoteItem(id: nextID, storageID: 0x0001_0001, parentID: parent, name: parts.last!, isFolder: false,
                              size: size, modified: modified ?? now)
        return AnalyzedFile(item: item, folders: folders)
    }

    /// Something for every rule.
    private func clutteredFiles() -> [AnalyzedFile] {
        var files: [AnalyzedFile] = []
        for i in 0..<200 { files.append(file("DCIM/Camera/PXL_\(i).jpg", 3 * mb, modified: yearsAgo)) }
        files.append(file("DCIM/Camera/PXL_new.jpg", 3 * mb))
        files.append(file("DCIM/Camera/Holiday.mp4", 900 * mb))
        files.append(file("DCIM/Camera/Wedding.mp4", 700 * mb, modified: yearsAgo))
        for i in 0..<4 { files.append(file("DCIM/.thumbnails/\(i).jpg", 30 * mb)) }
        for i in 0..<60 { files.append(file("Pictures/Screenshots/Screenshot_\(i).png", 1 * mb)) }
        files.append(file("Pictures/Trip/IMG_1.jpg", 30 * mb))
        files.append(file("Pictures/Trip copy/IMG_1.jpg", 30 * mb))
        for i in 0..<50 { files.append(file("Android/media/com.whatsapp/VID-\(i).mp4", 5 * mb)) }
        files.append(file("Download/game.apk", 30 * mb))
        files.append(file("Download/photos.zip", 150 * mb, modified: yearsAgo))
        files.append(file("Download/manual.pdf", 250 * mb, modified: yearsAgo))
        return files
    }

    func testEveryRuleOnAClutteredPhone() {
        let tips = SpaceTip.make(storage: storage(capacity: 64_000 * mb, free: 4_000 * mb), files: clutteredFiles(), now: now)
        let byKind = Dictionary(uniqueKeysWithValues: tips.map { ($0.kind, $0) })

        XCTAssertEqual(tips.first?.kind, .lowSpace, "a nearly full phone is mentioned first")
        XCTAssertEqual(byKind[.lowSpace]?.title, "Only 4 GB free (6%)")
        XCTAssertEqual(byKind[.largeVideos]?.fileCount, 2)
        XCTAssertEqual(byKind[.largeVideos]?.bytes, 1_600 * mb)
        XCTAssertEqual(byKind[.largeVideos]?.files.first?.item.name, "Holiday.mp4", "largest first")
        XCTAssertEqual(byKind[.oldCameraMedia]?.fileCount, 200, "old photos only; big videos are their own tip")
        XCTAssertEqual(byKind[.screenshots]?.bytes, 60 * mb)
        XCTAssertEqual(byKind[.chatMedia]?.bytes, 250 * mb)
        XCTAssertEqual(byKind[.duplicates]?.fileCount, 1, "one of the two identical files is extra")
        XCTAssertEqual(byKind[.duplicates]?.bytes, 30 * mb)
        XCTAssertEqual(byKind[.installers]?.bytes, 30 * mb)
        XCTAssertEqual(byKind[.oldDownloads]?.bytes, 400 * mb, "installers are counted under their own tip")
        XCTAssertEqual(byKind[.archives]?.bytes, 150 * mb)
        XCTAssertEqual(byKind[.thumbnailCache]?.bytes, 120 * mb)
        let rest = tips.dropFirst().map(\.bytes)
        XCTAssertEqual(rest, rest.sorted(by: >), "biggest savings first")
    }

    func testOptionsForAFolderView() {
        let files = clutteredFiles()
        let tips = SpaceTip.make(storage: storage(capacity: 64_000 * mb, free: 4_000 * mb), files: files, now: now,
                                 maxListed: 10, warnAboutLowSpace: false)
        XCTAssertFalse(tips.contains { $0.kind == .lowSpace })
        let old = tips.first { $0.kind == .oldCameraMedia }
        XCTAssertEqual(old?.files.count, 10, "listed files are capped")
        XCTAssertEqual(old?.fileCount, 200, "but the count is complete")
    }

    func testATidyPhoneGetsNoTips() {
        var files: [AnalyzedFile] = []
        for i in 0..<20 { files.append(file("DCIM/Camera/PXL_\(i).jpg", 3 * mb)) }
        for i in 0..<5 { files.append(file("Pictures/Screenshots/Screenshot_\(i).png", 1 * mb)) }
        files.append(file("Download/game.apk", 5 * mb))
        XCTAssertTrue(SpaceTip.make(storage: storage(capacity: 128_000 * mb, free: 90_000 * mb), files: files, now: now).isEmpty)
    }
}
