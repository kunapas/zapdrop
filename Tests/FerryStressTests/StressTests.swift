import Foundation
import XCTest
@testable import FerryAppModel
@testable import FerryCore
@testable import FerryMock
#if canImport(Darwin)
import Darwin
#endif

// Long-running stress and soak tests against the simulated phone. Opt-in:
//   FERRY_STRESS_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter FerryStressTests   (debug is far too slow)
// Randomised tests print their seed; replay a failure with FERRY_STRESS_SEED=<seed>.

enum Stress {
    static var enabled: Bool { ProcessInfo.processInfo.environment["FERRY_STRESS_TESTS"] == "1" }
    static let seed: UInt64 = ProcessInfo.processInfo.environment["FERRY_STRESS_SEED"].flatMap { UInt64($0) } ?? 20_261_017

    static func skipUnlessEnabled() throws {
        try XCTSkipUnless(enabled, "set FERRY_STRESS_TESTS=1")
    }

    /// Highest resident memory this process has used so far, in bytes.
    static func peakResidentBytes() -> UInt64 {
        #if os(Linux)
        let status = (try? String(contentsOfFile: "/proc/self/status", encoding: .utf8)) ?? ""
        let line = status.split(separator: "\n").first { $0.hasPrefix("VmHWM:") } ?? ""
        let kB = line.split(separator: " ").compactMap { UInt64($0) }.first ?? 0
        return kB * 1024
        #else
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return UInt64(usage.ru_maxrss) // bytes on macOS
        #endif
    }
}

/// SplitMix64: small, fast and the same on every platform, so a seed replays exactly.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private struct FixedSpace: VolumeSpaceProvider {
    let bytes: UInt64
    func availableBytes(at url: URL) throws -> UInt64 { bytes }
}

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-stress-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func allPaths(_ root: URL) -> [String] {
    (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []
}

@MainActor
private func waitUntil(_ timeout: Double, file: StaticString = #filePath, line: UInt = #line,
                       _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { XCTFail("timed out after \(timeout) s", file: file, line: line); return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

private func makePhone(_ id: String, chunkSize: Int = 256 * 1024) -> (MockPhone, StorageID) {
    let phone = MockPhone(summary: DeviceSummary(id: DeviceID(id), manufacturer: "Stress", model: id), chunkSize: chunkSize)
    let storage = phone.addStorage("Internal shared storage", capacity: 1 << 40, free: 1 << 39)
    return (phone, storage)
}

final class StressTests: XCTestCase {
    var dest: URL!
    override func setUpWithError() throws { dest = try makeTempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dest) }

    // MARK: Browsing

    /// A camera folder of 50,000 photos: the first rows must show at once, the rest must not take quadratic time,
    /// and the phone must never see overlapping requests.
    @MainActor
    func testListingFiftyThousandItemFolder() async throws {
        try Stress.skipUnlessEnabled()
        let (phone, storage) = makePhone("stress-list")
        let camera = phone.addFolder("Camera", storage: storage)
        for i in 0..<50_000 { phone.addFile("IMG_\(i).jpg", in: camera, storage: storage, size: 3_000_000) }
        phone.listDelayPerItem = 0.000_02 // 1 s of simulated phone time in total

        let session = try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id)
        let browser = DirectoryBrowserViewModel()
        browser.attach(session: session, storages: try await session.storages())
        await waitUntil(30) { !browser.isLoading && !browser.items.isEmpty }

        let started = Date()
        browser.open(browser.items.first { $0.name == "Camera" }!)
        await waitUntil(30) { !browser.items.isEmpty }
        let firstRows = Date().timeIntervalSince(started)
        await waitUntil(300) { !browser.isLoading }
        let total = Date().timeIntervalSince(started)
        print("stress: 50,000-item folder — first rows after \(firstRows) s, complete after \(total) s")

        XCTAssertEqual(browser.items.count, 50_000)
        XCTAssertLessThan(firstRows, 2)
        XCTAssertLessThan(total, 60)
        let inOrder = DirectoryBrowserViewModel.comparator(browser.sortOrder)
        XCTAssertFalse(zip(browser.items, browser.items.dropFirst()).contains { inOrder($1, $0) }, "sorted")
        XCTAssertEqual(phone.maxConcurrentOperations, 1)
    }

    // MARK: Copying

    func testCopyTenThousandSmallFiles() async throws {
        try Stress.skipUnlessEnabled()
        var rng = SeededGenerator(seed: Stress.seed)
        let (phone, storage) = makePhone("stress-small")
        let bulk = phone.addFolder("Bulk", storage: storage)
        var files: [(id: ObjectID, path: String, size: UInt64)] = []
        for d in 0..<20 {
            let sub = phone.addFolder("Sub\(d)", in: bulk, storage: storage)
            for i in 0..<500 {
                let size = UInt64.random(in: 0...40_000, using: &rng)
                files.append((phone.addFile("f\(i).bin", in: sub, storage: storage, size: size), "Bulk/Sub\(d)/f\(i).bin", size))
            }
        }
        let op = TransferOperation(
            request: TransferRequest(items: [phone.item(named: "Bulk")!], storageID: storage, sourceFolderPath: [],
                                     destination: dest, options: TransferOptions()),
            resolver: nil, space: FixedSpace(bytes: 1 << 40))
        let started = Date()
        await op.run(session: try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id))
        print("stress: 10,000 small files copied in \(Date().timeIntervalSince(started)) s (seed \(Stress.seed))")

        let snap = op.snapshot()
        XCTAssertEqual(snap.phase, .completed, "seed \(Stress.seed)")
        XCTAssertEqual(snap.completedFiles, 10_000)
        let paths = allPaths(dest)
        XCTAssertEqual(paths.filter { $0.hasSuffix(".bin") }.count, 10_000)
        XCTAssertFalse(paths.contains { $0.hasSuffix(".zapdroppart") })
        let bytesOnDisk = files.reduce(UInt64(0)) { $0 + (LocalFS.fileSize(of: dest.appendingPathComponent($1.path)) ?? 0) }
        XCTAssertEqual(bytesOnDisk, files.reduce(0) { $0 + $1.size })
        for _ in 0..<100 {
            let f = files.randomElement(using: &rng)!
            let expected = MockContent.bytes(offset: 0, count: Int(f.size), seed: phone.node(f.id)!.seed)
            XCTAssertEqual(Array(try Data(contentsOf: dest.appendingPathComponent(f.path))), expected, f.path)
        }
        XCTAssertEqual(phone.maxConcurrentOperations, 1)
    }

    /// 6.5 GB through the copy and verification path; memory use must not grow with file size.
    func testHugeFilesKeepMemoryFlat() async throws {
        try Stress.skipUnlessEnabled()
        let (phone, storage) = makePhone("stress-huge", chunkSize: 1 << 20)
        let sizes: [UInt64] = [4_500_000_000, 1_000_000_000, 1_000_000_000]
        let ids = sizes.enumerated().map { phone.addFile("video\($0.offset).mp4", storage: storage, size: $0.element) }
        var options = TransferOptions()
        options.verifyAfterCopy = true
        let op = TransferOperation(
            request: TransferRequest(items: ids.map { phone.node($0)!.item }, storageID: storage, sourceFolderPath: [],
                                     destination: dest, options: options),
            resolver: nil, space: FixedSpace(bytes: 1 << 40))
        let before = Stress.peakResidentBytes()
        let started = Date()
        await op.run(session: try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id))
        let peak = Stress.peakResidentBytes()
        let growth = peak &- before
        // Peak is per process: when other tests ran first, growth can be 0 and the absolute peak is what counts.
        print("stress: 6.5 GB copied and verified in \(Date().timeIntervalSince(started)) s; " +
              "peak memory \(peak >> 20) MB (grew \(growth >> 20) MB during the copy)")

        XCTAssertEqual(op.snapshot().phase, .completed)
        for (id, size) in zip(ids, sizes) {
            XCTAssertEqual(LocalFS.fileSize(of: dest.appendingPathComponent(phone.node(id)!.item.name)), size)
        }
        XCTAssertTrue(op.items().allSatisfy { $0.status == .completed(savedAs: nil, verified: true) })
        XCTAssertLessThan(growth, 300 << 20, "memory must stay bounded regardless of file size")
        XCTAssertLessThan(peak, 600 << 20, "whole test process, including everything run before this test")
    }

    // MARK: Failures

    /// Files that fail part-way (some repeatedly) and a cable pulled at random points; Retry Failed is pressed
    /// until everything is there. Every file must end up byte-identical with no partial files left behind.
    func testRandomFaultsRetriedUntilEverythingIsCopied() async throws {
        try Stress.skipUnlessEnabled()
        var rng = SeededGenerator(seed: Stress.seed)
        let (phone, storage) = makePhone("stress-faults")
        let mixed = phone.addFolder("Mixed", storage: storage)
        var files: [(id: ObjectID, size: UInt64)] = []
        for i in 0..<400 {
            // Mostly photos, some documents, a few short videos: roughly 1 KB to 16 MB.
            let size = UInt64(pow(2.0, Double.random(in: 10...24, using: &rng)))
            files.append((phone.addFile("item\(i).dat", in: mixed, storage: storage, size: size), size))
        }
        var faulty = 0
        for f in files where Double.random(in: 0..<1, using: &rng) < 0.15 {
            let code = ["0x2002", "0x2005", "0x201D"].randomElement(using: &rng)!
            phone.inject(.init(.protocolError(detail: "PTP \(code)"), afterBytes: UInt64.random(in: 0...f.size, using: &rng),
                               failures: Int.random(in: 1...3, using: &rng)), for: f.id)
            faulty += 1
        }

        let backend = MockDeviceBackend(phones: [phone])
        var session = try await backend.openSession(phone.summary.id)
        let op = TransferOperation(
            request: TransferRequest(items: [phone.node(mixed)!.item], storageID: storage, sourceFolderPath: [],
                                     destination: dest, options: TransferOptions()),
            resolver: nil, space: FixedSpace(bytes: 1 << 40))
        var rounds = 0, unplugs = 0
        while true {
            rounds += 1
            if Bool.random(using: &rng) { phone.disconnect(afterTotalBytes: UInt64.random(in: 1...300_000_000, using: &rng)) }
            await op.run(session: session)
            if op.snapshot().phase == .completed { break }
            XCTAssertFalse(allPaths(dest).contains { $0.hasSuffix(".zapdroppart") }, "seed \(Stress.seed) round \(rounds)")
            guard rounds < 30 else { return XCTFail("seed \(Stress.seed): still \(op.snapshot().phase) after 30 rounds") }
            if !phone.isConnected {
                unplugs += 1
                await session.close()
                phone.reconnect()
                session = try await backend.openSession(phone.summary.id)
            }
            XCTAssertGreaterThan(op.prepareRetry(), 0, "seed \(Stress.seed) round \(rounds)")
        }
        print("stress: \(faulty) faulty files and \(unplugs) unplugs → complete after \(rounds) rounds (seed \(Stress.seed))")

        XCTAssertFalse(allPaths(dest).contains { $0.hasSuffix(".zapdroppart") })
        for (i, f) in files.enumerated() {
            let data = try Data(contentsOf: dest.appendingPathComponent("Mixed/item\(i).dat"))
            XCTAssertEqual(Array(data), MockContent.bytes(offset: 0, count: Int(f.size), seed: phone.node(f.id)!.seed),
                           "item\(i).dat (seed \(Stress.seed))")
        }
        XCTAssertEqual(phone.maxConcurrentOperations, 1)
    }

    // MARK: Connection handling

    /// Hundreds of random cable, USB-mode, busy and lock changes. Zapdrop must always report a gone or charging-only
    /// phone correctly, recover by itself once the phone is usable, and never leak sessions.
    @MainActor
    func testDeviceMonitorSurvivesHundredsOfStateChanges() async throws {
        try Stress.skipUnlessEnabled()
        var rng = SeededGenerator(seed: Stress.seed)
        let phone = SamplePhones.pixel()
        let monitor = DeviceMonitor(backend: MockDeviceBackend(phones: [phone]))
        var connected = true, charging = false, busy = false, locked = false
        for step in 0..<400 {
            switch Int.random(in: 0..<5, using: &rng) {
            case 0: connected.toggle(); if connected { phone.reconnect() } else { phone.disconnect() }
            case 1: charging.toggle(); phone.setMode(charging ? .chargingOnly : .fileTransfer)
            case 2: busy.toggle(); phone.setBusy(holder: busy ? "ptpcamerad" : nil)
            case 3: locked.toggle(); phone.setLocked(locked)
            default: break // just another poll
            }
            for _ in 0..<Int.random(in: 1...3, using: &rng) { await monitor.retry() }
            let context = "seed \(Stress.seed) step \(step): \(monitor.state)"
            if !connected {
                XCTAssertFalse(monitor.state.isReady, context)
                XCTAssertNil(monitor.session, context)
            } else if charging {
                XCTAssertEqual(monitor.state, .chargingOnly(phone.summary), context)
                XCTAssertNil(monitor.session, context)
            }
        }

        phone.reconnect()
        phone.setMode(.fileTransfer)
        phone.setBusy(holder: nil)
        phone.setLocked(false)
        for _ in 0..<10 where !monitor.state.isReady { await monitor.retry() }
        XCTAssertTrue(monitor.state.isReady, "seed \(Stress.seed): \(monitor.state)")
        await waitUntil(5) { phone.openSessions <= 1 }
        XCTAssertEqual(phone.openSessions, 1, "exactly the current session is open")
        XCTAssertEqual(phone.maxConcurrentOperations, 1)
    }
}
