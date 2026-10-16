import XCTest
import FerryCore
@testable import FerryMock

final class CountingSink: ByteSink {
    var count: UInt64 = 0
    var maxChunk = 0
    var hasher = SHA256Hasher()
    var hash = false
    func write(_ bytes: UnsafeRawBufferPointer) throws {
        count += UInt64(bytes.count)
        maxChunk = max(maxChunk, bytes.count)
        if hash { hasher.update(bytes) }
    }
}

final class MockBackendTests: XCTestCase {
    func testDiscoveryAndStorages() async throws {
        let backend = SamplePhones.backend(throughputMBps: nil)
        let found = try await backend.discover()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].mode, .fileTransfer)
        XCTAssertEqual(found[0].summary.displayName, "Sam's Pixel")
        let session = try await backend.openSession(found[0].id)
        let storages = try await session.storages()
        XCTAssertEqual(storages.map(\.displayName), ["Internal shared storage", "SD card"])
        let root = try await session.children(of: RemoteLocation(storageID: storages[0].id))
        XCTAssertTrue(root.contains { $0.name == "DCIM" && $0.isFolder })
    }

    func testLockedPhoneHidesStorage() async throws {
        let phone = SamplePhones.pixel()
        phone.setLocked(true)
        let session = try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id)
        let storages = try await session.storages()
        XCTAssertTrue(storages.isEmpty)
    }

    func testBusyChargingAndAuthorizationStates() async throws {
        let phone = SamplePhones.pixel()
        let backend = MockDeviceBackend(phones: [phone])
        phone.setBusy(holder: "ptpcamerad")
        await assertThrows(try await backend.openSession(phone.summary.id), .deviceBusy(holder: "ptpcamerad"))
        phone.setBusy(holder: nil)
        phone.setMode(.chargingOnly)
        await assertThrows(try await backend.openSession(phone.summary.id), .chargingOnlyMode)
        phone.setMode(.fileTransfer)
        phone.requireAuthorization(attempts: 1)
        await assertThrows(try await backend.openSession(phone.summary.id), .notAuthorized)
        _ = try await backend.openSession(phone.summary.id)
    }

    func testStreamingAHugeVirtualFileUsesBoundedChunks() async throws {
        let phone = MockPhone(summary: DeviceSummary(id: DeviceID("big")), chunkSize: 4 * 1024 * 1024)
        let s = phone.addStorage("Internal", capacity: 1 << 40, free: 1 << 39)
        let size: UInt64 = 6 * 1024 * 1024 * 1024 + 7 // 6 GiB + 7 bytes, beyond UInt32
        let id = phone.addFile("huge.mkv", storage: s, size: size)
        let session = try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id)
        let sink = CountingSink()
        let lastProgress = Locked<UInt64>(0)
        let item = phone.node(id)!.item
        let delivered = try await session.download(item, into: sink) { p in lastProgress.withLock { $0 = p } }
        XCTAssertEqual(delivered, size)
        XCTAssertEqual(sink.count, size)
        XCTAssertEqual(lastProgress.current, size)
        XCTAssertLessThanOrEqual(sink.maxChunk, 4 * 1024 * 1024) // memory bounded by chunk, not file size
    }

    func testContentIsDeterministicAcrossChunkBoundaries() {
        let whole = MockContent.bytes(offset: 0, count: 200_000, seed: 42)
        let part = MockContent.bytes(offset: 65_000, count: 70_000, seed: 42)
        XCTAssertEqual(Array(whole[65_000..<135_000]), part)
    }

    func testDisconnectMidDownload() async throws {
        let phone = SamplePhones.pixel()
        let video = phone.item(named: "DCIM/Camera/PXL_20251012_LONG_TRIP.mp4")!
        let session = try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id)
        phone.disconnect(afterTotalBytes: 10_000_000)
        do {
            _ = try await session.download(video, into: CountingSink()) { _ in }
            XCTFail("expected disconnect")
        } catch let e as FerryError {
            XCTAssertEqual(e, .deviceDisconnected)
        }
        XCTAssertFalse(phone.isConnected)
        let after = try await MockDeviceBackend(phones: [phone]).discover()
        XCTAssertTrue(after.isEmpty)
    }

    func testThumbnailIsAValidPNG() async throws {
        let phone = SamplePhones.pixel()
        let photo = phone.item(named: "DCIM/Camera/PXL_20251009_101500.jpg")!
        let session = try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id)
        let data = try await session.thumbnail(for: photo)
        XCTAssertEqual(data?.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    private func assertThrows<T>(_ body: @autoclosure () async throws -> T, _ expected: FerryError,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await body(); XCTFail("expected \(expected)", file: file, line: line) }
        catch let e as FerryError { XCTAssertEqual(e, expected, file: file, line: line) }
        catch { XCTFail("unexpected \(error)", file: file, line: line) }
    }
}
