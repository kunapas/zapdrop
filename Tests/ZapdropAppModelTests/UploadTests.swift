import XCTest
@testable import ZapdropAppModel
@testable import ZapdropCore
@testable import ZapdropMock

final class UploadTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("zapdrop-upload-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ path: String, bytes: Int) throws -> URL {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    private func phone() -> (MockPhone, StorageID) {
        let phone = MockPhone(summary: DeviceSummary(id: DeviceID("upload-test"), manufacturer: "Test", model: "Phone",
                                                     friendlyName: nil))
        let storage = phone.addStorage("Internal", capacity: 1 << 30, free: 1 << 29)
        return (phone, storage)
    }

    private func names(_ session: DeviceSession, _ location: RemoteLocation) async throws -> [String] {
        try await session.children(of: location).map(\.name).sorted()
    }

    func testFilesAndFoldersArriveWithTheirSizes() async throws {
        let (phone, storage) = phone()
        let session = try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id)
        let file = try write("notes.txt", bytes: 300_000)
        _ = try write("Album/one.jpg", bytes: 10)
        _ = try write("Album/Inner/two.jpg", bytes: 20)
        _ = try write("Album/.DS_Store", bytes: 5)
        let root = RemoteLocation(storageID: storage)

        let outcome = await UploadService.copy([file, folder.appendingPathComponent("Album")], to: root, session: session) { _ in }

        XCTAssertEqual(outcome.copied, 3)
        XCTAssertEqual(outcome.failed, [])
        XCTAssertNil(outcome.firstError)
        let atRoot = try await names(session, root)
        XCTAssertEqual(atRoot, ["Album", "notes.txt"])
        XCTAssertEqual(phone.item(named: "notes.txt")?.size, 300_000)
        XCTAssertEqual(phone.item(named: "Album/Inner/two.jpg")?.size, 20)
        XCTAssertNil(phone.item(named: "Album/.DS_Store"), "Finder's bookkeeping files stay on the Mac")
    }

    func testNothingOnThePhoneIsOverwritten() async throws {
        let (phone, storage) = phone()
        let original = phone.addFile("Photo.jpg", storage: storage, size: 111)
        let album = phone.addFolder("Album", storage: storage)
        phone.addFile("one.jpg", in: album, storage: storage, size: 222)
        let session = try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id)
        let root = RemoteLocation(storageID: storage)
        let file = try write("photo.JPG", bytes: 5) // same name on Android, which ignores case
        _ = try write("Album/one.jpg", bytes: 6)

        let outcome = await UploadService.copy([file, folder.appendingPathComponent("Album")], to: root, session: session) { _ in }

        XCTAssertEqual(outcome.copied, 2)
        XCTAssertEqual(phone.node(original)?.item.size, 111, "the phone's own file is untouched")
        let atRoot = try await names(session, root)
        XCTAssertEqual(atRoot, ["Album", "Photo.jpg", "photo (1).JPG"])
        let inAlbum = try await names(session, RemoteLocation(storageID: storage, folderID: album))
        XCTAssertEqual(inAlbum, ["one (1).jpg", "one.jpg"], "merged into the existing folder, beside the existing file")
        XCTAssertEqual(phone.item(named: "Album/one.jpg")?.size, 222)
    }

    func testProgressReachesTheTotals() async throws {
        let (phone, storage) = phone()
        let session = try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id)
        let a = try write("a.bin", bytes: 400_000)
        let b = try write("b.bin", bytes: 100_000)
        let seen = Locked<[UploadService.Progress]>([])

        _ = await UploadService.copy([a, b], to: RemoteLocation(storageID: storage), session: session) { p in
            seen.withLock { $0.append(p) }
        }

        let last = try XCTUnwrap(seen.current.last)
        XCTAssertEqual(last.filesTotal, 2)
        XCTAssertEqual(last.filesDone, 2)
        XCTAssertEqual(last.bytesDone, 500_000)
        XCTAssertEqual(last.bytesTotal, 500_000)
        XCTAssertTrue(zip(seen.current, seen.current.dropFirst()).allSatisfy { $0.bytesDone <= $1.bytesDone }, "never goes backwards")
    }

    func testUnpluggingStopsTheCopyAndSaysWhy() async throws {
        let (phone, storage) = phone()
        let session = try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id)
        let a = try write("a.bin", bytes: 10)
        phone.disconnect()

        let outcome = await UploadService.copy([a], to: RemoteLocation(storageID: storage), session: session) { _ in }

        XCTAssertEqual(outcome.copied, 0)
        XCTAssertEqual(outcome.firstError, .deviceDisconnected)
        XCTAssertFalse(outcome.cancelled)
    }
}
