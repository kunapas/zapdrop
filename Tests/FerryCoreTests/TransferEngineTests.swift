import XCTest
@testable import FerryCore
@testable import FerryMock

// MARK: - Helpers

final class SequenceSpace: VolumeSpaceProvider, @unchecked Sendable {
    let values: Locked<[UInt64]>
    init(_ v: [UInt64]) { values = Locked(v) }
    func availableBytes(at url: URL) throws -> UInt64 { values.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] } }
}

struct FixedSpace: VolumeSpaceProvider {
    let bytes: UInt64
    func availableBytes(at url: URL) throws -> UInt64 { bytes }
}

final class ScriptedResolver: DuplicateResolver, @unchecked Sendable {
    let answers: Locked<[DuplicateDecision?]>
    let calls = Locked(0)
    init(_ answers: [DuplicateDecision?]) { self.answers = Locked(answers) }
    func resolve(_ conflict: DuplicateConflict) async -> DuplicateDecision? {
        calls.withLock { $0 += 1 }
        return answers.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

func makeTempDir(_ name: String = #function) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ferry-tests-\(name.filter { $0.isLetter })-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func allFiles(_ root: URL) -> [String] {
    guard let e = FileManager.default.enumerator(atPath: root.path) else { return [] }
    return (e.allObjects as? [String] ?? []).sorted()
}

func expectedContent(_ phone: MockPhone, _ item: RemoteItem) -> Data {
    Data(MockContent.bytes(offset: 0, count: Int(item.size ?? 0), seed: phone.node(item.id)!.seed))
}

final class TransferEngineTests: XCTestCase {
    var dest: URL!
    override func setUpWithError() throws { dest = try makeTempDir(name) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dest) }

    private func session(_ phone: MockPhone) async throws -> DeviceSession {
        try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id)
    }

    private func request(_ phone: MockPhone, _ paths: [String], folder: [String] = [], options: TransferOptions = .init(),
                         caseInsensitive: Bool = true) -> TransferRequest {
        let items = paths.map { phone.item(named: (folder + [$0]).joined(separator: "/"))! }
        return TransferRequest(items: items, storageID: items[0].storageID, sourceFolderPath: folder,
                               destination: dest, options: options, destinationIsCaseInsensitive: caseInsensitive)
    }

    // MARK: Planning

    func testRecursivePlanningAndNameHandling() async throws {
        let phone = SamplePhones.pixel()
        let s = try await session(phone)
        let plan = try await TransferPlanner(session: s, caseInsensitive: true)
            .plan(request(phone, ["DCIM", "Download"]))
        XCTAssertEqual(plan.folderCount, 3) // DCIM, DCIM/Camera, Download
        XCTAssertTrue(plan.totalBytes > UInt64(UInt32.max), "includes the >4 GiB video")
        let paths = plan.entries.map(\.relativePath)
        XCTAssertTrue(paths.contains("DCIM/Camera/PXL_20251012_LONG_TRIP.mp4"))
        XCTAssertTrue(paths.contains("Download/notes.txt"))
        XCTAssertTrue(paths.contains("Download/Notes (1).txt"), "case clash renamed: \(paths)")
        XCTAssertTrue(paths.contains("Download/backup_2025.zip"))
        XCTAssertTrue(paths.contains("Download/invoice_fdp.exe"))
        let clash = plan.entries.first { $0.name == "Notes (1).txt" }!
        XCTAssertEqual(clash.rename, .nameClash(original: "Notes.txt"))
        XCTAssertEqual(clash.remotePath, ["Download", "Notes.txt"])
        // Folders come before their contents.
        let dcim = paths.firstIndex(of: "DCIM")!, camera = paths.firstIndex(of: "DCIM/Camera")!
        XCTAssertLessThan(dcim, camera)
        XCTAssertLessThan(camera, paths.firstIndex(of: "DCIM/Camera/PXL_20251012_LONG_TRIP.mp4")!)
    }

    func testCaseSensitiveDestinationKeepsBothNames() async throws {
        let phone = SamplePhones.pixel()
        let plan = try await TransferPlanner(session: try await session(phone), caseInsensitive: false)
            .plan(request(phone, ["Download"], caseInsensitive: false))
        XCTAssertTrue(plan.entries.contains { $0.relativePath == "Download/Notes.txt" })
    }

    func testPlanningCopesWithFolderLoops() async throws {
        // Malformed device: a folder that lists itself as a child.
        let phone = MockPhone(summary: DeviceSummary(id: DeviceID("loop")))
        let st = phone.addStorage("S", capacity: 10, free: 5)
        let a = phone.addFolder("A", storage: st)
        phone.state.withLock { s in
            s.nodes[999] = MockPhone.Node(item: RemoteItem(id: a, storageID: st, parentID: a, name: "A", isFolder: true,
                                                           size: nil, modified: nil), seed: 1, hasThumbnail: false)
        }
        let plan = try await TransferPlanner(session: try await session(phone), caseInsensitive: true)
            .plan(TransferRequest(items: [phone.node(a)!.item], storageID: st, sourceFolderPath: [], destination: dest))
        XCTAssertLessThan(plan.entries.count, 5)
    }

    // MARK: Copying

    func testCopiesFolderWithContentDatesAndNoLeftovers() async throws {
        let phone = SamplePhones.pixel()
        let op = TransferOperation(request: request(phone, ["Download", "Documents"]), resolver: nil, space: FixedSpace(bytes: 1 << 40))
        await op.run(session: try await session(phone))
        let snap = op.snapshot()
        XCTAssertEqual(snap.phase, .completed)
        XCTAssertEqual(snap.completedFiles, 9)
        XCTAssertEqual(snap.failedFiles, 0)
        XCTAssertEqual(snap.processedBytes, snap.totalBytes)
        let files = allFiles(dest)
        XCTAssertFalse(files.contains { $0.hasSuffix(".zapdroppart") })
        XCTAssertTrue(files.contains("Download/Notes (1).txt"))
        let pdf = phone.item(named: "Download/Boarding pass.pdf")!
        let url = dest.appendingPathComponent("Download/Boarding pass.pdf")
        XCTAssertEqual(try Data(contentsOf: url), expectedContent(phone, pdf))
        let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
        XCTAssertEqual(mtime.timeIntervalSince1970, pdf.modified!.timeIntervalSince1970, accuracy: 1)
        let summary = op.summary()
        XCTAssertEqual(summary.copied.count, 9)
        XCTAssertTrue(summary.renamed.contains { $0.entry.name == "Notes (1).txt" })
        XCTAssertTrue(summary.renamed.contains { $0.entry.name == "invoice_fdp.exe" })
    }

    func testEmptyFoldersAreRecreated() async throws {
        let phone = SamplePhones.pixel()
        let op = TransferOperation(request: request(phone, ["Empty album"], folder: ["Pictures"]), resolver: nil,
                                   space: FixedSpace(bytes: 1 << 40))
        await op.run(session: try await session(phone))
        XCTAssertEqual(op.snapshot().phase, .completed)
        XCTAssertEqual(LocalFS.kind(of: dest.appendingPathComponent("Empty album")), .directory)
    }

    func testVerifyAfterCopy() async throws {
        let phone = SamplePhones.pixel()
        var options = TransferOptions(); options.verifyAfterCopy = true
        let op = TransferOperation(request: request(phone, ["Résumé.pdf"], folder: ["Documents"], options: options),
                                   resolver: nil, space: FixedSpace(bytes: 1 << 40))
        await op.run(session: try await session(phone))
        XCTAssertEqual(op.items().first?.status, .completed(savedAs: nil, verified: true))
    }

    // MARK: Duplicates

    private func seedExisting(_ name: String, contents: String = "old") throws -> URL {
        let url = dest.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testDuplicateSkip() async throws {
        let phone = SamplePhones.pixel()
        let existing = try seedExisting("notes.txt")
        let op = TransferOperation(request: request(phone, ["notes.txt"], folder: ["Download"],
                                                    options: .init(duplicatePolicy: .always(.skip))),
                                   resolver: nil, space: FixedSpace(bytes: 1 << 40))
        await op.run(session: try await session(phone))
        XCTAssertEqual(op.items()[0].status, .skipped(.alreadyExists))
        XCTAssertEqual(op.snapshot().phase, .completed)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "old")
        XCTAssertEqual(phone.downloadsStarted, 0)
    }

    func testDuplicateReplaceIsAtomic() async throws {
        let phone = SamplePhones.pixel()
        let existing = try seedExisting("notes.txt")
        let op = TransferOperation(request: request(phone, ["notes.txt"], folder: ["Download"],
                                                    options: .init(duplicatePolicy: .always(.replace))),
                                   resolver: nil, space: FixedSpace(bytes: 1 << 40))
        await op.run(session: try await session(phone))
        XCTAssertEqual(try Data(contentsOf: existing), expectedContent(phone, phone.item(named: "Download/notes.txt")!))
        XCTAssertEqual(allFiles(dest), ["notes.txt"])
    }

    func testDuplicateKeepBoth() async throws {
        let phone = SamplePhones.pixel()
        _ = try seedExisting("notes.txt")
        _ = try seedExisting("notes (1).txt")
        let op = TransferOperation(request: request(phone, ["notes.txt"], folder: ["Download"],
                                                    options: .init(duplicatePolicy: .always(.keepBoth))),
                                   resolver: nil, space: FixedSpace(bytes: 1 << 40))
        await op.run(session: try await session(phone))
        XCTAssertEqual(op.items()[0].status, .completed(savedAs: "notes (2).txt", verified: false))
        XCTAssertEqual(allFiles(dest), ["notes (1).txt", "notes (2).txt", "notes.txt"])
    }

    func testAskWithApplyToAllAsksOnce() async throws {
        let phone = SamplePhones.pixel()
        for i in 0..<3 { _ = try seedExisting(String(format: "Screenshot_20251010-%06d.png", 90_000 + i * 11)) }
        let resolver = ScriptedResolver([DuplicateDecision(.skip, applyToAll: true)])
        let op = TransferOperation(request: request(phone, ["Screenshots"], folder: ["Pictures"]), resolver: resolver,
                                   space: FixedSpace(bytes: 1 << 40))
        // Folder already exists too; it is merged, not treated as a duplicate.
        try FileManager.default.createDirectory(at: dest.appendingPathComponent("Screenshots"), withIntermediateDirectories: true)
        for i in 0..<3 {
            try FileManager.default.moveItem(at: dest.appendingPathComponent(String(format: "Screenshot_20251010-%06d.png", 90_000 + i * 11)),
                                             to: dest.appendingPathComponent("Screenshots/" + String(format: "Screenshot_20251010-%06d.png", 90_000 + i * 11)))
        }
        await op.run(session: try await session(phone))
        XCTAssertEqual(resolver.calls.current, 1)
        let snap = op.snapshot()
        XCTAssertEqual(snap.skippedFiles, 3)
        XCTAssertEqual(snap.completedFiles, 9)
        XCTAssertEqual(snap.phase, .completed)
    }

    func testAskWithoutResolverNeverOverwrites() async throws {
        let phone = SamplePhones.pixel()
        let existing = try seedExisting("notes.txt")
        let op = TransferOperation(request: request(phone, ["notes.txt"], folder: ["Download"]), resolver: nil,
                                   space: FixedSpace(bytes: 1 << 40))
        await op.run(session: try await session(phone))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "old")
        XCTAssertEqual(allFiles(dest).count, 2)
    }

    func testCancellingTheDuplicatePromptCancelsTheJob() async throws {
        let phone = SamplePhones.pixel()
        _ = try seedExisting("notes.txt")
        let op = TransferOperation(request: request(phone, ["notes.txt", "Boarding pass.pdf"], folder: ["Download"]),
                                   resolver: ScriptedResolver([nil]), space: FixedSpace(bytes: 1 << 40))
        await op.run(session: try await session(phone))
        XCTAssertEqual(op.snapshot().phase, .cancelled)
        XCTAssertFalse(allFiles(dest).contains { $0.hasSuffix(".zapdroppart") })
    }

    // MARK: Cancellation, failures, retry

    func testCancelMidFileRemovesPartialAndKeepsFinishedFiles() async throws {
        let phone = SamplePhones.pixel()
        phone.bytesPerSecond = 200_000_000
        let op = TransferOperation(request: request(phone, ["PXL_20251009_101500.jpg", "PXL_20251012_LONG_TRIP.mp4"],
                                                    folder: ["DCIM", "Camera"]),
                                   resolver: nil, space: FixedSpace(bytes: 1 << 40))
        let s = try await session(phone)
        let task = Task { await op.run(session: s) }
        // Wait until the 5 GB video is in flight.
        for _ in 0..<1000 {
            let snap = op.snapshot()
            if snap.currentFileName == "PXL_20251012_LONG_TRIP.mp4", snap.currentFileBytes > 0 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        op.cancel()
        await task.value
        let snap = op.snapshot()
        XCTAssertEqual(snap.phase, .cancelled)
        XCTAssertEqual(snap.completedFiles, 1)
        XCTAssertEqual(snap.cancelledFiles, 1)
        XCTAssertEqual(allFiles(dest), ["PXL_20251009_101500.jpg"])
    }

    func testTaskCancellationAlsoStopsTheJob() async throws {
        let phone = SamplePhones.pixel()
        phone.bytesPerSecond = 50_000_000
        let op = TransferOperation(request: request(phone, ["app-release.apk"], folder: ["Download"]), resolver: nil,
                                   space: FixedSpace(bytes: 1 << 40))
        let s = try await session(phone)
        let task = Task { await op.run(session: s) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await task.value
        XCTAssertEqual(op.snapshot().phase, .cancelled)
        XCTAssertTrue(allFiles(dest).isEmpty)
    }

    func testFailedFileDoesNotStopOthersAndRetryCopiesOnlyIt() async throws {
        let phone = SamplePhones.pixel()
        let bad = phone.item(named: "Download/Quarterly report v3.docx")!
        phone.inject(.init(.protocolError(detail: "PTP 0x2002"), afterBytes: 300_000, failures: 1), for: bad.id)
        let op = TransferOperation(request: request(phone, ["Download"]), resolver: nil, space: FixedSpace(bytes: 1 << 40))
        let s = try await session(phone)
        await op.run(session: s)
        var snap = op.snapshot()
        XCTAssertEqual(snap.phase, .partiallyCompleted)
        XCTAssertEqual(snap.failedFiles, 1)
        XCTAssertEqual(snap.completedFiles, 6)
        XCTAssertFalse(allFiles(dest).contains { $0.hasSuffix(".zapdroppart") }, "partial removed")
        XCTAssertEqual(op.summary().failed.map(\.entry.name), ["Quarterly report v3.docx"])

        let before = phone.downloadsStarted
        XCTAssertEqual(op.prepareRetry(), 1)
        await op.run(session: s)
        snap = op.snapshot()
        XCTAssertEqual(snap.phase, .completed)
        XCTAssertEqual(phone.downloadsStarted - before, 1, "only the failed file was downloaded again")
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("Download/Quarterly report v3.docx")),
                       expectedContent(phone, bad))
    }

    func testSourceRemovedIsReportedAndNotRetried() async throws {
        let phone = SamplePhones.pixel()
        let gone = phone.item(named: "Download/notes.txt")!
        phone.inject(.init(.sourceRemoved, failures: nil), for: gone.id)
        let op = TransferOperation(request: request(phone, ["notes.txt", "Boarding pass.pdf"], folder: ["Download"]),
                                   resolver: nil, space: FixedSpace(bytes: 1 << 40))
        await op.run(session: try await session(phone))
        XCTAssertEqual(op.snapshot().phase, .partiallyCompleted)
        XCTAssertEqual(op.items().first { $0.entry.name == "notes.txt" }?.status, .failed(.sourceRemoved))
        XCTAssertEqual(op.prepareRetry(), 0)
    }

    func testDisconnectDuringTransferThenRetryOnNewSessionWithNewIDs() async throws {
        let phone = SamplePhones.pixel()
        let op = TransferOperation(request: request(phone, ["Download"]), resolver: nil, space: FixedSpace(bytes: 1 << 40))
        phone.disconnect(afterTotalBytes: 1_500_000) // during the second file
        await op.run(session: try await session(phone))
        let snap = op.snapshot()
        XCTAssertEqual(snap.lastError, .deviceDisconnected)
        XCTAssertEqual(snap.phase, .partiallyCompleted)
        XCTAssertGreaterThan(snap.cancelledFiles, 0, "remaining files are reported, not silently dropped")
        XCTAssertFalse(allFiles(dest).contains { $0.hasSuffix(".zapdroppart") })

        // The phone comes back with a fresh session where every object has a different ID (Android does this).
        let reborn = MockPhone(summary: phone.summary)
        let st = reborn.addStorage("Internal shared storage", capacity: 1 << 40, free: 1 << 39)
        for i in 0..<50 { reborn.addFolder("filler\(i)", storage: st) }
        let dl = reborn.addFolder("Download", storage: st)
        for name in ["Boarding pass.pdf", "Quarterly report v3.docx", "notes.txt", "Notes.txt", "backup:2025.zip",
                     "invoice\u{202E}fdp.exe", "app-release.apk"] {
            let old = phone.item(named: "Download/\(name)")!
            reborn.addFile(name, in: dl, storage: st, size: old.size, modified: old.modified)
        }
        XCTAssertEqual(op.prepareRetry() > 0, true)
        await op.run(session: try await MockDeviceBackend(phones: [reborn]).openSession(reborn.summary.id))
        XCTAssertEqual(op.snapshot().phase, .completed)
        let apk = reborn.item(named: "Download/app-release.apk")!
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("Download/app-release.apk")), expectedContent(reborn, apk))
    }

    func testInsufficientSpaceIsCaughtBeforeStartingAndRetryWorks() async throws {
        let phone = SamplePhones.pixel()
        let req = request(phone, ["Download"])
        let op = TransferOperation(request: req, resolver: nil, space: FixedSpace(bytes: 10_000_000))
        await op.run(session: try await session(phone))
        guard case .failed(.insufficientSpace(let needed, let available)) = op.snapshot().phase else {
            return XCTFail("expected insufficient space, got \(op.snapshot().phase)")
        }
        XCTAssertGreaterThan(needed, available)
        XCTAssertTrue(allFiles(dest).isEmpty, "nothing written")
        XCTAssertEqual(phone.downloadsStarted, 0)
        XCTAssertTrue(ErrorMapper.map(.insufficientSpace(needed: needed, available: available)).canRetry)
        // Space is freed (simulated by a fresh operation with the same plan semantics via retry).
        XCTAssertGreaterThan(op.prepareRetry(), 0)
    }

    func testDiskFullDuringCopyStopsQueue() async throws {
        let phone = SamplePhones.pixel()
        // Plenty of space at preflight; the disk then fills up before the big file.
        // Copy order is by name: app-release.apk, Boarding pass.pdf, notes.txt.
        let space = SequenceSpace([1 << 40, 1 << 40, 1_000_000])
        let op = TransferOperation(request: request(phone, ["Boarding pass.pdf", "app-release.apk", "notes.txt"], folder: ["Download"]),
                                   resolver: nil, space: space)
        await op.run(session: try await session(phone))
        let snap = op.snapshot()
        XCTAssertEqual(snap.lastError, .insufficientSpace(needed: 180_000 + 10_000_000, available: 1_000_000))
        XCTAssertEqual(snap.completedFiles, 1)
        XCTAssertEqual(snap.failedFiles, 1)
        XCTAssertEqual(snap.cancelledFiles, 1, "the file after the failure is reported as not copied")
        XCTAssertEqual(snap.phase, .partiallyCompleted)
        XCTAssertEqual(op.summary().cancelled.map(\.entry.name), ["notes.txt"])
    }

    // MARK: Destination safety

    func testRefusesToWriteThroughSymlinkInDestination() async throws {
        let phone = SamplePhones.pixel()
        let outside = try makeTempDir("outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: dest.appendingPathComponent("Documents"), withDestinationURL: outside)
        let op = TransferOperation(request: request(phone, ["Documents"]), resolver: nil, space: FixedSpace(bytes: 1 << 40))
        await op.run(session: try await session(phone))
        XCTAssertTrue(allFiles(outside).isEmpty, "nothing escaped through the link")
        XCTAssertEqual(op.items().first?.status, .failed(.unsafeDestinationPath))
        XCTAssertEqual(op.snapshot().failedFiles, 2, "children are reported as failed, not dropped")
    }

    func testMaliciousNamesStayInsideDestination() async throws {
        let phone = MockPhone(summary: DeviceSummary(id: DeviceID("evil")))
        let st = phone.addStorage("S", capacity: 1 << 30, free: 1 << 29)
        let names = ["../../escape.txt", "..", "/etc/passwd", "a\u{0}b", "dir/../../x"]
        let items = names.map { n -> RemoteItem in phone.node(phone.addFile(n, storage: st, size: 10))!.item }
        let op = TransferOperation(request: TransferRequest(items: items, storageID: st, sourceFolderPath: [], destination: dest),
                                   resolver: nil, space: FixedSpace(bytes: 1 << 40))
        await op.run(session: try await session(phone))
        XCTAssertEqual(op.snapshot().completedFiles, 5)
        let files = allFiles(dest)
        XCTAssertEqual(files.count, 5)
        XCTAssertTrue(files.allSatisfy { !$0.contains("/") }, "\(files)")
    }

    func testSizeMismatchIsDetectedAndPartialRemoved() async throws {
        let phone = SamplePhones.pixel()
        let s = ShortReadSession(inner: try await session(phone))
        let op = TransferOperation(request: request(phone, ["notes.txt"], folder: ["Download"]), resolver: nil,
                                   space: FixedSpace(bytes: 1 << 40))
        await op.run(session: s)
        XCTAssertEqual(op.items()[0].status, .failed(.sizeMismatch(expected: 2_048, actual: 2_047)))
        XCTAssertTrue(allFiles(dest).isEmpty)
    }

    // MARK: Coordinator

    func testCoordinatorRunsJobsOneAtATime() async throws {
        let phone = SamplePhones.pixel()
        phone.bytesPerSecond = 500_000_000
        let s = try await session(phone)
        let coordinator = TransferCoordinator()
        let a = TransferOperation(request: request(phone, ["Download"]), resolver: nil, space: FixedSpace(bytes: 1 << 40))
        let destB = try makeTempDir("b"); defer { try? FileManager.default.removeItem(at: destB) }
        var reqB = request(phone, ["Documents"]); reqB.destination = destB
        let b = TransferOperation(request: reqB, resolver: nil, space: FixedSpace(bytes: 1 << 40))
        let c = TransferOperation(request: request(phone, ["Music"]), resolver: nil, space: FixedSpace(bytes: 1 << 40))
        await coordinator.enqueue(a, session: s)
        await coordinator.enqueue(b, session: s)
        await coordinator.enqueue(c, session: s)
        await coordinator.cancel(c)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(a.snapshot().phase, .completed)
        XCTAssertEqual(b.snapshot().phase, .completed)
        XCTAssertEqual(c.snapshot().phase, .cancelled)
        XCTAssertEqual(phone.maxConcurrentOperations, 1, "never more than one MTP request in flight")
    }

    // MARK: Large files

    /// Writes a real 4.5 GB file. Opt-in: FERRY_LARGE_TESTS=1 swift test
    func testRealFileLargerThan4GB() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FERRY_LARGE_TESTS"] == "1", "set FERRY_LARGE_TESTS=1")
        let phone = MockPhone(summary: DeviceSummary(id: DeviceID("big")), chunkSize: 1 << 20)
        let st = phone.addStorage("S", capacity: 1 << 40, free: 1 << 39)
        let size: UInt64 = 4_500_000_000
        let id = phone.addFile("big.mp4", storage: st, size: size, modified: Date(timeIntervalSince1970: 1_700_000_000))
        var options = TransferOptions(); options.verifyAfterCopy = true
        let op = TransferOperation(request: TransferRequest(items: [phone.node(id)!.item], storageID: st, sourceFolderPath: [],
                                                            destination: dest, options: options),
                                   resolver: nil)
        await op.run(session: try await session(phone))
        XCTAssertEqual(op.snapshot().phase, .completed)
        XCTAssertEqual(op.items()[0].status, .completed(savedAs: nil, verified: true))
        let url = dest.appendingPathComponent("big.mp4")
        XCTAssertEqual(LocalFS.fileSize(of: url), size)
        // Spot-check bytes beyond the 4 GiB boundary.
        let h = try FileHandle(forReadingFrom: url)
        try h.seek(toOffset: 4_294_967_296 - 3)
        let tail = try h.read(upToCount: 4096)!
        try h.close()
        XCTAssertEqual(Array(tail), MockContent.bytes(offset: 4_294_967_296 - 3, count: 4096, seed: phone.node(id)!.seed))
    }
}

/// Delivers one byte less than the phone reports — models a truncated USB transfer.
final class ShortReadSession: DeviceSession, @unchecked Sendable {
    let inner: DeviceSession
    init(inner: DeviceSession) { self.inner = inner }
    var summary: DeviceSummary { inner.summary }
    func storages() async throws -> [StorageInfo] { try await inner.storages() }
    func children(of l: RemoteLocation) async throws -> [RemoteItem] { try await inner.children(of: l) }
    func thumbnail(for item: RemoteItem) async throws -> Data? { nil }
    func refreshItem(_ item: RemoteItem) async throws -> RemoteItem? { item }
    func close() async {}
    func download(_ item: RemoteItem, into sink: ByteSink, progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        final class Trim: ByteSink {
            let inner: ByteSink; var left: UInt64
            init(_ i: ByteSink, _ l: UInt64) { inner = i; left = l }
            func write(_ b: UnsafeRawBufferPointer) throws {
                let n = Int(min(UInt64(b.count), left)); left -= UInt64(n)
                if n > 0 { try inner.write(UnsafeRawBufferPointer(rebasing: b[0..<n])) }
            }
        }
        return try await inner.download(item, into: Trim(sink, (item.size ?? 1) - 1), progress: progress) - 1
    }
}
