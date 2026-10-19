import XCTest
@testable import FerryAppModel
@testable import FerryCore
@testable import FerryMock

private func makeTempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-\(label)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func content(_ phone: MockPhone, _ item: RemoteItem) -> Data {
    Data(MockContent.bytes(offset: 0, count: Int(item.size ?? 0), seed: phone.node(item.id)!.seed))
}

@MainActor
final class PhoneDetailsTests: XCTestCase {
    func testBatteryStorageAndUSBSpeed() async throws {
        let phone = SamplePhones.pixel()
        phone.setUSBSpeed(.high)
        let monitor = DeviceMonitor(backend: MockDeviceBackend(phones: [phone]))
        await monitor.refresh()
        XCTAssertEqual(monitor.batteryPercent, 82)
        XCTAssertEqual(monitor.selectedDevice?.usbSpeed, .high)
        XCTAssertEqual(monitor.selectedDevice?.usbSpeed?.isSlow, true)
        XCTAssertEqual(USBSpeed.superSpeed.isSlow, false)
        XCTAssertEqual(monitor.storageTotals.capacity, monitor.storages.reduce(0) { $0 + $1.capacityBytes })
        XCTAssertEqual(monitor.storageTotals.free, monitor.storages.reduce(0) { $0 + $1.freeBytes })

        phone.setBattery(41)
        await monitor.refresh()
        XCTAssertEqual(monitor.batteryPercent, 82, "not asked again before the interval")
        monitor.batteryInterval = 0
        await monitor.refresh()
        XCTAssertEqual(monitor.batteryPercent, 41)
        phone.setBattery(nil)
        await monitor.refresh()
        XCTAssertNil(monitor.batteryPercent, "phones that don't report a battery show none")
        phone.setBattery(60)
        await monitor.refresh()
        await monitor.eject()
        XCTAssertNil(monitor.batteryPercent)
    }
}

@MainActor
final class PreviewServiceTests: XCTestCase {
    // Set up and torn down outside the main actor, only ever before and after each test.
    nonisolated(unsafe) var cache: URL!
    override func setUpWithError() throws { cache = try makeTempDir("preview") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: cache) }

    private func make() async throws -> (PreviewService, MockPhone) {
        let phone = SamplePhones.pixel()
        let service = PreviewService(cacheRoot: cache)
        service.reset(session: try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id))
        return (service, phone)
    }

    func testPreviewCopiesTheFileAndSpaceToggles() async throws {
        let (service, phone) = try await make()
        let item = try XCTUnwrap(phone.item(named: "Documents/Résumé.pdf"))
        service.toggle(item)
        XCTAssertEqual(service.preparing?.id, item.id)
        await waitUntil { service.url != nil }
        let url = try XCTUnwrap(service.url)
        XCTAssertNil(service.preparing)
        XCTAssertEqual(url.lastPathComponent, FileNameSanitizer.sanitize(item.name).name)
        XCTAssertEqual(try Data(contentsOf: url), content(phone, item))

        service.toggle(item) // space again closes it
        XCTAssertNil(service.url)
        let downloads = phone.downloadsStarted
        service.show(item)
        XCTAssertEqual(service.url, url, "the copy already made is shown at once")
        XCTAssertEqual(phone.downloadsStarted, downloads)
    }

    func testFoldersAndHugeFilesAreNotPreviewed() async throws {
        let (service, phone) = try await make()
        service.show(try XCTUnwrap(phone.item(named: "DCIM")))
        XCTAssertFalse(service.isActive)
        service.maxBytes = 1_000_000
        service.show(try XCTUnwrap(phone.item(named: "DCIM/Camera/PXL_20251012_LONG_TRIP.mp4")))
        XCTAssertFalse(service.isActive)
        XCTAssertEqual(service.error?.title, "Too large to preview")
    }

    func testClosingStopsTheCopyAndLeavesNothingBehind() async throws {
        let (service, phone) = try await make()
        phone.bytesPerSecond = 5_000_000 // the 48 MB installer would take ~10 s
        service.show(try XCTUnwrap(phone.item(named: "Download/app-release.apk")))
        await waitUntil { service.fraction > 0 }
        service.close()
        XCTAssertNil(service.preparing)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(service.url)
        let left = (FileManager.default.enumerator(atPath: cache.path)?.allObjects as? [String]) ?? []
        XCTAssertFalse(left.contains { $0.hasSuffix(".zapdroppart") || $0.hasSuffix(".apk") }, "\(left)")
    }
}

@MainActor
final class FinderDragTests: XCTestCase {
    func testDragExportCopiesFilesAndFoldersThroughTheTransferQueue() async throws {
        let cache = try makeTempDir("drag")
        defer { try? FileManager.default.removeItem(at: cache) }
        let model = AppModel<FakeImage>(backend: SamplePhones.backend(throughputMBps: nil), isMock: true,
                                        store: InMemoryStore(), cacheRoot: cache, decodeThumbnail: { _ in nil })
        model.start()
        defer { model.stop() }
        await waitUntil { model.monitor.state.isReady && !model.browser.items.isEmpty }
        model.browser.open(model.browser.items.first { $0.name == "Documents" }!)
        await waitUntil { model.browser.items.count == 2 }

        let file = try XCTUnwrap(model.browser.items.first { $0.name.hasPrefix("Budget") })
        let url = try await model.exportForDrag(file)
        XCTAssertEqual(url.lastPathComponent, "Budget 2026.xlsx")
        XCTAssertTrue(url.path.hasPrefix(cache.path), "staged privately; Finder copies it from there")
        XCTAssertEqual(LocalFS.fileSize(of: url), file.size)
        XCTAssertEqual(model.transfers.rows.count, 1, "shown in the Transfers panel like any copy")

        model.browser.goUp()
        await waitUntil { model.browser.items.first?.name == "Android" }
        let folder = try await model.exportForDrag(try XCTUnwrap(model.browser.items.first { $0.name == "Documents" }))
        XCTAssertEqual(folder.lastPathComponent, "Documents")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
    }
}

@MainActor
final class FolderTipsTests: XCTestCase {
    private func cameraFolder() async throws -> DirectoryBrowserViewModel {
        let phone = SamplePhones.pixel()
        let session = try await MockDeviceBackend(phones: [phone]).openSession(phone.summary.id)
        let browser = DirectoryBrowserViewModel()
        browser.attach(session: session, storages: try await session.storages())
        await waitUntil { !browser.isLoading && !browser.items.isEmpty }
        XCTAssertTrue(browser.folderTips.isEmpty, "nothing to suggest at the top level")
        browser.open(browser.items.first { $0.name == "DCIM" }!)
        await waitUntil { !browser.isLoading && browser.items.first?.name == "Camera" }
        browser.open(browser.items[0])
        await waitUntil { !browser.isLoading && !browser.folderTips.isEmpty }
        return browser
    }

    func testTipsForTheOpenFolderSelectEvenWhenFiltered() async throws {
        let browser = try await cameraFolder()
        let tip = try XCTUnwrap(browser.folderTips.first)
        XCTAssertEqual(tip.kind, .largeVideos, "the 5 GB trip video")
        XCTAssertFalse(browser.folderTips.contains { $0.kind == .lowSpace }, "storage warnings belong to the phone card")

        browser.filter = .documents
        XCTAssertTrue(browser.items.isEmpty)
        browser.select(tip)
        XCTAssertEqual(browser.filter, .all, "selecting a tip's files shows them")
        XCTAssertEqual(browser.selectedItems.map(\.name), ["PXL_20251012_LONG_TRIP.mp4"])
    }

    func testEmptyReasonsAndFilteringKeepsTheSortOrder() async throws {
        let browser = try await cameraFolder()
        browser.sortOrder = SortOrder(key: .size, ascending: false)
        let bySize = browser.items.map(\.id)
        XCTAssertEqual(browser.items.first?.name, "PXL_20251012_LONG_TRIP.mp4")
        XCTAssertNil(browser.emptyReason)

        browser.filter = .videos
        XCTAssertEqual(browser.items.map(\.id), bySize.filter { id in browser.items.contains { $0.id == id } },
                       "filtering keeps the order without re-sorting")
        XCTAssertTrue(browser.items.allSatisfy { $0.kind == .video })

        browser.filter = .audio
        XCTAssertEqual(browser.emptyReason, .filtered(.audio))
        browser.filter = .all
        browser.searchText = "zzz"
        XCTAssertEqual(browser.emptyReason, .noMatches(query: "zzz"))
        browser.searchText = ""
        XCTAssertEqual(browser.items.map(\.id), bySize)
        browser.sortOrder = SortOrder() // back to names for the navigation below

        browser.goUp()
        await waitUntil { browser.items.first?.name == "Camera" }
        browser.goTo(breadcrumbIndex: 0)
        await waitUntil { browser.items.first?.name == "Android" }
        browser.open(browser.items.first { $0.name == "Pictures" }!)
        await waitUntil { !browser.isLoading && browser.items.contains { $0.name == "Empty album" } }
        browser.open(browser.items.first { $0.name == "Empty album" }!)
        await waitUntil { !browser.isLoading }
        XCTAssertEqual(browser.emptyReason, .emptyFolder)
    }
}
