import XCTest
@testable import FerryAppModel
import FerryCore
@testable import FerryMock

final class FakeImage {
    let bytes: Int
    init(bytes: Int) { self.bytes = bytes }
}

@MainActor
func waitUntil(_ timeout: Double = 5, file: StaticString = #filePath, line: UInt = #line,
               _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { XCTFail("timed out", file: file, line: line); return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// Counts listing calls so caching can be checked.
final class CountingSession: DeviceSession, @unchecked Sendable {
    let inner: DeviceSession
    let listCalls = Locked(0)
    init(_ inner: DeviceSession) { self.inner = inner }
    var summary: DeviceSummary { inner.summary }
    func storages() async throws -> [StorageInfo] { try await inner.storages() }
    func children(of l: RemoteLocation) async throws -> [RemoteItem] {
        listCalls.withLock { $0 += 1 }
        return try await inner.children(of: l)
    }
    func download(_ item: RemoteItem, into sink: ByteSink, progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        try await inner.download(item, into: sink, progress: progress)
    }
    func thumbnail(for item: RemoteItem) async throws -> Data? { try await inner.thumbnail(for: item) }
    func refreshItem(_ item: RemoteItem) async throws -> RemoteItem? { try await inner.refreshItem(item) }
    func close() async { await inner.close() }
}

struct FakeInspector: ExclusiveAccessInspecting {
    func holderName(vendorID: UInt16, productID: UInt16) -> String? { "Image Capture" }
}

@MainActor
final class DirectoryBrowserTests: XCTestCase {
    private func makeBrowser() async throws -> (DirectoryBrowserViewModel, CountingSession, MockPhone) {
        let phone = SamplePhones.pixel()
        let inner = try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id)
        let session = CountingSession(inner)
        let browser = DirectoryBrowserViewModel()
        browser.attach(session: session, storages: try await session.storages())
        await waitUntil { !browser.isLoading && !browser.items.isEmpty }
        return (browser, session, phone)
    }

    func testOpensFirstStorageRootWithFoldersFirst() async throws {
        let (browser, _, _) = try await makeBrowser()
        XCTAssertEqual(browser.storage?.displayName, "Internal shared storage")
        XCTAssertEqual(browser.breadcrumb, ["Internal shared storage"])
        XCTAssertEqual(browser.items.map(\.name), ["Android", "DCIM", "Documents", "Download", "Music", "Pictures", "WhatsApp"])
        XCTAssertFalse(browser.canGoUp)
    }

    func testNavigationBreadcrumbAndCache() async throws {
        let (browser, session, _) = try await makeBrowser()
        browser.open(browser.items.first { $0.name == "DCIM" }!)
        await waitUntil { !browser.isLoading && browser.items.first?.name == "Camera" }
        browser.open(browser.items[0])
        await waitUntil { !browser.isLoading && browser.items.count > 10 }
        XCTAssertEqual(browser.breadcrumb, ["Internal shared storage", "DCIM", "Camera"])
        XCTAssertEqual(browser.currentFolderPath, ["DCIM", "Camera"])
        let calls = session.listCalls.current
        browser.goTo(breadcrumbIndex: 0)
        await waitUntil { browser.items.first?.name == "Android" }
        browser.open(browser.items.first { $0.name == "DCIM" }!)
        await waitUntil { browser.items.first?.name == "Camera" }
        XCTAssertEqual(session.listCalls.current, calls, "cached folders are not listed again")
        browser.reload()
        await waitUntil { !browser.isLoading && browser.items.first?.name == "Camera" }
        XCTAssertEqual(session.listCalls.current, calls + 1)
        browser.goUp()
        await waitUntil { browser.items.first?.name == "Android" }
        XCTAssertFalse(browser.canGoUp)
    }

    /// A phone that takes `delay` seconds per item to list, with a 400-photo folder "Big" at the root.
    private func makeSlowBrowser(delay: Double) async throws -> DirectoryBrowserViewModel {
        let phone = SamplePhones.pixel()
        let session = try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id)
        let storages = try await session.storages()
        let big = phone.addFolder("Big", storage: storages[0].id)
        for i in 0..<400 { phone.addFile("IMG_\(i).jpg", in: big, storage: storages[0].id, size: 1000) }
        phone.listDelayPerItem = delay
        let browser = DirectoryBrowserViewModel()
        browser.attach(session: session, storages: storages)
        await waitUntil { !browser.isLoading && !browser.items.isEmpty }
        return browser
    }

    func testLargeFolderShowsItemsWhileStillReading() async throws {
        let browser = try await makeSlowBrowser(delay: 0.005) // 2 s for the whole folder
        browser.open(browser.items.first { $0.name == "Big" }!)
        await waitUntil { !browser.items.isEmpty }
        XCTAssertTrue(browser.isLoading)
        XCTAssertLessThan(browser.items.count, 400)
        XCTAssertEqual(browser.loadProgress?.total, 400)
        XCTAssertTrue(browser.statusText.hasPrefix("Reading folder…"), browser.statusText)
        await waitUntil(10) { !browser.isLoading }
        XCTAssertEqual(browser.items.count, 400)
        XCTAssertNil(browser.loadProgress)
        XCTAssertEqual(browser.statusText, "400 items")
    }

    func testLeavingAFolderStopsReadingIt() async throws {
        let browser = try await makeSlowBrowser(delay: 0.02) // 8 s for the whole folder
        browser.open(browser.items.first { $0.name == "Big" }!)
        await waitUntil { !browser.items.isEmpty }
        browser.goUp()
        browser.reload() // ask the phone again rather than using the cached root
        // The root must not wait behind the rest of "Big" (at most one more piece of 50 × 20 ms).
        await waitUntil(2.5) { !browser.isLoading && browser.items.first?.name == "Android" }
        XCTAssertNil(browser.loadProgress)
        // The abandoned listing was not cached as if it were complete.
        browser.open(browser.items.first { $0.name == "Big" }!)
        XCTAssertTrue(browser.isLoading)
    }

    func testSortingFilteringSearchAndHiddenFiles() async throws {
        let (browser, _, _) = try await makeBrowser()
        browser.open(browser.items.first { $0.name == "Download" }!)
        await waitUntil { !browser.isLoading && browser.items.count == 7 }

        browser.sortOrder = SortOrder(key: .size, ascending: false)
        XCTAssertEqual(browser.items.first?.name, "app-release.apk")
        browser.sortOrder = SortOrder(key: .size, ascending: true)
        XCTAssertEqual(browser.items.first?.name, "notes.txt")

        browser.filter = .documents
        XCTAssertTrue(browser.items.allSatisfy { $0.kind == .document })
        browser.filter = .all
        browser.searchText = "BOARD"
        XCTAssertEqual(browser.items.map(\.name), ["Boarding pass.pdf"])
        browser.searchText = ""

        browser.goUp()
        await waitUntil { browser.items.first?.name == "Android" }
        browser.open(browser.items.first { $0.name == "WhatsApp" }!)
        await waitUntil { browser.items.first?.name == "Media" }
        browser.open(browser.items[0])
        await waitUntil { browser.items.first?.name == "WhatsApp Images" }
        XCTAssertFalse(browser.items.contains { $0.name == ".nomedia" })
        browser.showHiddenFiles = true
        XCTAssertTrue(browser.items.contains { $0.name == ".nomedia" })
    }

    func testFilterKeepsFoldersForNavigation() async throws {
        let (browser, _, _) = try await makeBrowser()
        browser.filter = .photos
        XCTAssertEqual(browser.items.count, 7, "folders stay visible")
        browser.open(browser.items.first { $0.name == "DCIM" }!)
        await waitUntil { browser.items.first?.name == "Camera" }
        browser.open(browser.items[0])
        await waitUntil { !browser.isLoading && browser.items.count > 10 }
        XCTAssertTrue(browser.items.allSatisfy { $0.kind == .photo })
        browser.filter = .videos
        XCTAssertTrue(browser.items.allSatisfy { $0.kind == .video })
        XCTAssertTrue(browser.items.contains { $0.name == "PXL_20251012_LONG_TRIP.mp4" })
    }

    func testSelectionAndStatusText() async throws {
        let (browser, _, _) = try await makeBrowser()
        browser.open(browser.items.first { $0.name == "Documents" }!)
        await waitUntil { browser.items.count == 2 }
        XCTAssertEqual(browser.statusText, "2 items")
        browser.selectAll()
        XCTAssertEqual(browser.selectedItems.count, 2)
        XCTAssertEqual(browser.statusText, "2 of 2 selected, 284 KB")
        browser.filter = .photos
        XCTAssertTrue(browser.selection.isEmpty, "hidden items leave the selection")
        browser.filter = .all
        browser.selection = [browser.items[0].id]
        browser.goUp()
        XCTAssertTrue(browser.selection.isEmpty, "navigation clears selection")
    }

    func testSortComparatorIsStableAndHandlesMissingValues() async {
        let a = RemoteItem(id: 1, storageID: 1, parentID: 0, name: "img10.jpg", isFolder: false, size: nil, modified: nil)
        let b = RemoteItem(id: 2, storageID: 1, parentID: 0, name: "img9.jpg", isFolder: false, size: 5, modified: Date())
        let f = RemoteItem(id: 3, storageID: 1, parentID: 0, name: "zz", isFolder: true, size: nil, modified: nil)
        let byName = [a, b, f].sorted(by: DirectoryBrowserViewModel.comparator(SortOrder(key: .name)))
        XCTAssertEqual(byName.map(\.id), [3, 2, 1], "folders first, numeric-aware names")
        let byDate = [a, b, f].sorted(by: DirectoryBrowserViewModel.comparator(SortOrder(key: .modified, ascending: true)))
        XCTAssertEqual(byDate.map(\.id), [3, 1, 2], "unknown dates sort as oldest")
    }

    func testDisconnectWhileBrowsingIsReported() async throws {
        let (browser, _, phone) = try await makeBrowser()
        var disconnected = false
        browser.onDisconnect = { disconnected = true }
        phone.disconnect()
        browser.open(browser.items.first { $0.name == "DCIM" }!)
        await waitUntil { disconnected }
        XCTAssertEqual(browser.error?.title, "Phone disconnected")
    }
}

@MainActor
final class DeviceMonitorTests: XCTestCase {
    func testReadyLockedUnlocked() async throws {
        let phone = SamplePhones.pixel()
        phone.setLocked(true)
        let monitor = DeviceMonitor(backend: MockDeviceBackend(phones: [phone]))
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .locked(phone.summary))
        phone.setLocked(false)
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .ready(phone.summary))
        XCTAssertEqual(monitor.storages.count, 2)
    }

    func testNoDeviceChargingOnlyBusyAndAuthorization() async throws {
        let phone = SamplePhones.pixel()
        let backend = MockDeviceBackend(phones: [])
        let monitor = DeviceMonitor(backend: backend, inspector: FakeInspector())
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .noDevice)

        phone.setMode(.chargingOnly)
        backend.add(phone)
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .chargingOnly(phone.summary))

        phone.setMode(.fileTransfer)
        phone.setBusy(holder: "ptpcamerad")
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .busy(phone.summary, holder: "Image Capture"))

        phone.setBusy(holder: nil)
        phone.requireAuthorization(attempts: 1)
        monitor.retryNow()
        await waitUntil { if case .awaitingAuthorization = monitor.state { return true }; return monitor.state.isReady }
        for _ in 0..<4 where !monitor.state.isReady { await monitor.refresh() }
        XCTAssertEqual(monitor.state, .ready(phone.summary))
    }

    func testDisconnectAndReconnect() async throws {
        let phone = SamplePhones.pixel()
        let monitor = DeviceMonitor(backend: MockDeviceBackend(phones: [phone]))
        await monitor.refresh()
        XCTAssertTrue(monitor.state.isReady)
        let generation = monitor.sessionGeneration
        phone.disconnect()
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .disconnected(phone.summary))
        XCTAssertNil(monitor.session)
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .disconnected(phone.summary), "stays visible until the phone returns")
        phone.reconnect()
        await monitor.refresh()
        XCTAssertTrue(monitor.state.isReady)
        XCTAssertGreaterThan(monitor.sessionGeneration, generation)
    }

    func testEjectLetsGoUntilConnectedAgain() async throws {
        let phone = SamplePhones.pixel()
        let monitor = DeviceMonitor(backend: MockDeviceBackend(phones: [phone]))
        await monitor.refresh()
        XCTAssertEqual(phone.openSessions, 1)
        await monitor.eject()
        XCTAssertEqual(monitor.state, .ejected(phone.summary))
        XCTAssertNil(monitor.session)
        XCTAssertTrue(monitor.storages.isEmpty)
        XCTAssertEqual(phone.openSessions, 0, "the phone is released before Zapdrop says it's safe to unplug")
        for _ in 0..<3 { await monitor.retry() }
        XCTAssertEqual(monitor.state, .ejected(phone.summary), "polling and Try Again don't reconnect an ejected phone")
        XCTAssertEqual(phone.openSessions, 0)

        monitor.select(phone.summary.id) // clicking the phone in the sidebar
        await waitUntil { monitor.state.isReady }
        XCTAssertEqual(phone.openSessions, 1)
        XCTAssertNil(monitor.ejectedDeviceID)
    }

    func testEjectedPhoneConnectsAgainWhenPluggedBackIn() async throws {
        let phone = SamplePhones.pixel()
        let monitor = DeviceMonitor(backend: MockDeviceBackend(phones: [phone]))
        await monitor.refresh()
        await monitor.eject()
        phone.disconnect()
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .noDevice)
        phone.reconnect()
        await monitor.refresh()
        XCTAssertTrue(monitor.state.isReady)
    }

    func testEjectIsRefusedWhileCopying() async throws {
        let phone = SamplePhones.pixel()
        let monitor = DeviceMonitor(backend: MockDeviceBackend(phones: [phone]))
        monitor.isTransferActive = { true }
        await monitor.refresh()
        await monitor.eject()
        XCTAssertTrue(monitor.state.isReady)
        XCTAssertNotNil(monitor.session)
        XCTAssertNil(monitor.ejectedDeviceID)
    }

    func testMultipleDevicesAndSelection() async throws {
        let a = SamplePhones.pixel(id: "a")
        let b = SamplePhones.pixel(id: "b")
        let monitor = DeviceMonitor(backend: MockDeviceBackend(phones: [a, b]))
        await monitor.refresh()
        XCTAssertTrue(monitor.hasMultipleDevices)
        XCTAssertEqual(monitor.selectedDeviceID, DeviceID("a"))
        monitor.select(DeviceID("b"))
        await waitUntil { monitor.state.isReady && monitor.session?.summary.id == DeviceID("b") }
    }
}

@MainActor
final class TransferQueueTests: XCTestCase {
    var dest: URL!
    override func setUp() async throws {
        dest = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-vm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dest) }

    func testDuplicatePromptRoundTrip() async throws {
        let phone = SamplePhones.pixel()
        let session = try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id)
        try Data("old".utf8).write(to: dest.appendingPathComponent("notes.txt"))
        let queue = TransferQueueViewModel()
        let items = ["notes.txt", "Boarding pass.pdf"].map { phone.item(named: "Download/\($0)")! }
        let id = queue.start(TransferRequest(items: items, storageID: items[0].storageID, sourceFolderPath: ["Download"],
                                             destination: dest), session: session)
        await waitUntil { queue.duplicatePrompt != nil }
        XCTAssertEqual(queue.duplicatePrompt?.conflict.fileName, "notes.txt")
        XCTAssertEqual(queue.duplicatePrompt?.conflict.existingSize, 3)
        queue.answerPrompt(DuplicateDecision(.keepBoth))
        await waitUntil { queue.rows.first?.snapshot.phase.isFinished == true }
        XCTAssertEqual(queue.rows.first?.snapshot.phase, .completed)
        XCTAssertEqual(queue.summary(for: id)?.renamed.first?.status, .completed(savedAs: "notes (1).txt", verified: false))
        XCTAssertFalse(queue.canRetry(id))
        queue.clearFinished()
        XCTAssertTrue(queue.rows.isEmpty)
    }

    func testCancelWhilePromptIsShownCancelsJob() async throws {
        let phone = SamplePhones.pixel()
        let session = try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id)
        try Data("old".utf8).write(to: dest.appendingPathComponent("notes.txt"))
        let queue = TransferQueueViewModel()
        let item = phone.item(named: "Download/notes.txt")!
        let id = queue.start(TransferRequest(items: [item], storageID: item.storageID, sourceFolderPath: ["Download"],
                                             destination: dest), session: session)
        await waitUntil { queue.duplicatePrompt != nil }
        queue.cancel(id)
        await waitUntil { queue.rows.first?.snapshot.phase.isFinished == true }
        XCTAssertEqual(queue.rows.first?.snapshot.phase, .cancelled)
        XCTAssertNil(queue.duplicatePrompt)
        XCTAssertTrue(queue.canRetry(id))
    }

    func testRetryFromViewModel() async throws {
        let phone = SamplePhones.pixel()
        let item = phone.item(named: "Download/Boarding pass.pdf")!
        phone.inject(.init(.protocolError(detail: "x"), afterBytes: 10, failures: 1), for: item.id)
        let session = try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id)
        let queue = TransferQueueViewModel()
        let id = queue.start(TransferRequest(items: [item], storageID: item.storageID, sourceFolderPath: ["Download"],
                                             destination: dest), session: session)
        await waitUntil { queue.rows.first?.snapshot.phase.isFinished == true }
        XCTAssertTrue(queue.canRetry(id))
        queue.retry(id, session: session)
        await waitUntil { queue.rows.first?.snapshot.phase == .completed }
    }
}

@MainActor
final class ServicesTests: XCTestCase {
    func testSettingsPersist() async {
        let store = InMemoryStore()
        let s = AppSettings(store: store)
        XCTAssertTrue(s.preserveDates)
        XCTAssertEqual(s.transferOptions.duplicatePolicy, .ask)
        s.verifyAfterCopy = true
        s.defaultDuplicateAction = .skip
        let again = AppSettings(store: store)
        XCTAssertTrue(again.verifyAfterCopy)
        XCTAssertEqual(again.transferOptions.duplicatePolicy, .always(.skip))
    }

    func testDestinationIsRememberedAndValidated() async throws {
        let store = InMemoryStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-dest-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let service = LocalDestinationService(store: store)
        XCTAssertNil(service.destination)
        service.choose(dir)
        XCTAssertTrue(service.isAvailable)
        let restored = LocalDestinationService(store: store)
        XCTAssertEqual(restored.destination?.standardizedFileURL.path, dir.standardizedFileURL.path)
        try FileManager.default.removeItem(at: dir)
        XCTAssertFalse(restored.isAvailable, "an ejected/removed folder is detected")
        XCTAssertNil(LocalDestinationService(store: store).destination, "missing folders are not restored")
        restored.forget()
        XCTAssertNil(store.data(forKey: "destinationBookmark"))
    }

    func testCostLimitedCacheEvictsLeastRecentlyUsed() async {
        var cache = CostLimitedCache<Int, String>(costLimit: 100)
        cache.insert("a", for: 1, cost: 40)
        cache.insert("b", for: 2, cost: 40)
        _ = cache.value(for: 1) // 1 is now most recent
        cache.insert("c", for: 3, cost: 40)
        XCTAssertNil(cache.peek(2))
        XCTAssertEqual(cache.peek(1), "a")
        XCTAssertEqual(cache.peek(3), "c")
        XCTAssertLessThanOrEqual(cache.totalCost, 100)
        cache.insert("huge", for: 4, cost: 500) // a single oversized entry is still kept
        XCTAssertEqual(cache.count, 1)
    }

    func testThumbnailsLoadAndPauseDuringTransfers() async throws {
        let phone = SamplePhones.pixel()
        let session = try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id)
        let service = ThumbnailService<FakeImage>(costLimit: 1_000_000) { data in
            data.starts(with: [0x89, 0x50]) ? (FakeImage(bytes: data.count), data.count) : nil
        }
        service.reset(session: session)
        var paused = true
        service.isPaused = { paused }
        let photo = phone.item(named: "DCIM/Camera/PXL_20251009_101500.jpg")!
        let doc = phone.item(named: "Download/Boarding pass.pdf")!
        service.request(photo)
        service.request(doc) // not a photo/video: ignored
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(service.image(for: photo), "paused while a transfer runs")
        paused = false
        await waitUntil { service.image(for: photo) != nil }
        XCTAssertNil(service.image(for: doc))
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    func testEndToEndCopyThroughTheAppModel() async throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-app-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let model = AppModel<FakeImage>(backend: SamplePhones.backend(throughputMBps: nil), isMock: true, store: InMemoryStore(),
                                        decodeThumbnail: { _ in nil })
        model.start()
        defer { model.stop() }
        await waitUntil { model.monitor.state.isReady && !model.browser.items.isEmpty }
        XCTAssertFalse(model.copySelection(), "nothing selected")
        model.browser.open(model.browser.items.first { $0.name == "Documents" }!)
        await waitUntil { model.browser.items.count == 2 }
        model.browser.selectAll()
        XCTAssertTrue(model.canCopy)
        XCTAssertFalse(model.copySelection(), "no destination yet")
        XCTAssertEqual(model.notice?.title, "Choose where to save")
        XCTAssertTrue(model.copySelection(to: dest))
        await waitUntil { model.transfers.rows.first?.snapshot.phase == .completed }
        let files = (try FileManager.default.contentsOfDirectory(atPath: dest.path)).sorted()
        XCTAssertEqual(files, ["Budget 2026.xlsx", "Résumé.pdf"].map { $0.precomposedStringWithCanonicalMapping }.sorted())
    }
}
