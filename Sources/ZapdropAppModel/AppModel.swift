import Foundation
import Observation
import ZapdropCore

/// Releases the phone from macOS's camera daemon (implemented in the app; see docs/DECISIONS.md D5).
/// Frees a phone that another program on the Mac holds (user-initiated only).
public protocol PhoneReleasing: Sendable {
    /// Open apps that commonly take phones over USB, by display name. Shown before freeing so nothing closes by surprise.
    func competingApps() async -> [String]
    /// Ends macOS's camera service, which grabs phones on its own, and, if `quittingApps`, first quits those apps
    /// (a normal Quit, not a force-kill). Returns when done.
    func release(quittingApps: Bool) async
}

/// Top-level state for one window: device, browser, transfers, destination and settings, wired together.
@MainActor @Observable
public final class AppModel<Image: AnyObject> {
    public let monitor: DeviceMonitor
    public let browser: DirectoryBrowserViewModel
    public let transfers: TransferQueueViewModel
    /// Copies from the Mac to the phone.
    public let uploads = UploadService()
    public let destination: LocalDestinationService
    public let settings: AppSettings
    public let thumbnails: ThumbnailService<Image>
    public let preview: PreviewService
    public let isMock: Bool

    /// A message for an alert (e.g. "Choose a destination first").
    public var notice: UserFacingError?

    @ObservationIgnored private let phoneReleaser: PhoneReleasing?
    /// True while "Free Up Phone & Connect" is working.
    public private(set) var isFreeingPhone = false
    /// Set when freeing didn't help (the phone is still claimed); cleared on the next attempt.
    public private(set) var freeingPhoneFailed = false
    /// Apps that may be holding the phone, refreshed while the busy screen is shown.
    public private(set) var competingApps: [String] = []
    /// Phones whose automatic attempt didn't get them open. Cleared once Zapdrop opens the phone (even just to ask for
    /// access) or it's unplugged: tapping Allow makes Android reconnect, often at the same USB address, and the
    /// camera service grabs it again — that must be handled again, without a click. Only a failed attempt blocks a repeat.
    @ObservationIgnored private var autoFreedDevices: Set<DeviceID> = []
    @ObservationIgnored private let dragRoot: URL
    @ObservationIgnored private var observedGeneration = -1
    @ObservationIgnored private var observedStorages: [StorageInfo] = []

    public init(backend: DeviceBackend, isMock: Bool, store: KeyValueStore,
                inspector: ExclusiveAccessInspecting? = nil, phoneReleaser: PhoneReleasing? = nil,
                bookmarkCodec: BookmarkCodec = SystemBookmarkCodec(), space: VolumeSpaceProvider = SystemVolumeSpace(),
                cacheRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Zapdrop", isDirectory: true),
                decodeThumbnail: @escaping @Sendable (Data) -> (Image, cost: Int)?) {
        self.isMock = isMock
        self.monitor = DeviceMonitor(backend: backend, inspector: inspector)
        self.browser = DirectoryBrowserViewModel()
        self.transfers = TransferQueueViewModel(space: space)
        self.destination = LocalDestinationService(store: store, codec: bookmarkCodec)
        self.settings = AppSettings(store: store)
        self.thumbnails = ThumbnailService(decode: decodeThumbnail)
        self.preview = PreviewService(cacheRoot: cacheRoot.appendingPathComponent("Previews", isDirectory: true))
        let dragRoot = cacheRoot.appendingPathComponent("Drag", isDirectory: true)
        try? FileManager.default.removeItem(at: dragRoot) // staging left by a previous run
        self.dragRoot = dragRoot
        self.phoneReleaser = phoneReleaser

        browser.showHiddenFiles = settings.showHiddenFiles
        browser.onDisconnect = { [weak self] in self?.monitor.reportDisconnected() }
        transfers.onDisconnect = { [weak self] in self?.monitor.reportDisconnected() }
        monitor.isTransferActive = { [weak self] in self?.transfers.hasActiveTransfer ?? false }
        // Previews wait while copying or reading a folder: both matter more and share the phone's one channel.
        thumbnails.isPaused = { [weak self] in
            guard let self else { return false }
            return self.transfers.hasActiveTransfer || self.browser.isLoading
        }
    }

    public func start() {
        monitor.onChange = { [weak self] in self?.syncSession() }
        monitor.start()
    }

    public func stop() {
        monitor.stop()
    }

    /// Pushes session/storage changes from the monitor into the browser and thumbnail loader.
    public func syncSession() {
        if monitor.session != nil, let id = monitor.selectedDeviceID { autoFreedDevices.remove(id) }
        autoFreedDevices = autoFreedDevices.filter { id in monitor.devices.contains { $0.id == id } }
        if monitor.isBusy { freeAutomaticallyIfAllowed() }
        let session = monitor.state.isReady ? monitor.session : nil
        let generation = monitor.sessionGeneration
        let hasSession = session != nil
        guard generation != observedGeneration || hasSession != browserHasSession || monitor.storages != observedStorages else {
            return
        }
        if generation != observedGeneration || !hasSession {
            thumbnails.reset(session: session)
            preview.reset(session: session)
            clearDragStaging()
        }
        observedGeneration = generation
        observedStorages = monitor.storages
        browserHasSession = hasSession
        browser.attach(session: session, storages: hasSession ? monitor.storages : [])
    }

    @ObservationIgnored private var browserHasSession = false

    // MARK: - Actions

    public var canCopy: Bool { monitor.state.isReady && !browser.selection.isEmpty }

    /// Copies the selection (or the given items) to the remembered destination.
    @discardableResult
    public func copySelection(_ items: [RemoteItem]? = nil, to url: URL? = nil) -> Bool {
        let selected = items ?? browser.selectedItems
        guard !selected.isEmpty else { return false }
        guard monitor.state.isReady, let session = monitor.session, let location = browser.currentLocation else {
            notice = ErrorMapper.map(ZapdropError.noDevice)
            return false
        }
        if let url { destination.choose(url) }
        guard let dest = destination.destination else {
            notice = UserFacingError(title: "Choose where to save", message: "Pick a folder on your Mac first.",
                                     suggestions: [], canRetry: false)
            return false
        }
        guard destination.isAvailable else {
            notice = ErrorMapper.map(ZapdropError.destinationUnavailable)
            return false
        }
        let request = TransferRequest(items: selected, storageID: location.storageID,
                                      sourceFolderPath: browser.currentFolderPath, destination: dest,
                                      options: settings.transferOptions,
                                      destinationIsCaseInsensitive: LocalDestinationService.isCaseInsensitive(dest))
        transfers.start(request, session: session)
        return true
    }

    public func retry(_ id: UUID) {
        guard let session = monitor.session, monitor.state.isReady else {
            notice = ErrorMapper.map(ZapdropError.noDevice)
            return
        }
        transfers.retry(id, session: session)
    }

    /// Ejecting is refused while copying: the phone must finish (or the copy be cancelled) first.
    public var canEject: Bool { monitor.session != nil && !transfers.hasActiveTransfer && !uploads.isActive }

    public func ejectPhone() {
        guard canEject else { return }
        Task { await monitor.eject() }
    }

    // MARK: - Copy to the phone

    public var canCopyToPhone: Bool { monitor.state.isReady && browser.currentLocation != nil && !uploads.isActive }

    /// Copies files and folders from the Mac into the folder being shown. Nothing on the phone is overwritten: a
    /// name that's taken gets a number.
    public func copyToPhone(_ urls: [URL]) {
        guard canCopyToPhone, let session = monitor.session, let location = browser.currentLocation else { return }
        uploads.start(urls, to: location, session: session) { [weak self] outcome in
            guard let self else { return }
            browser.reload()
            if let error = outcome.firstError {
                let mapped = ErrorMapper.map(error)
                let count = outcome.failed.count
                notice = count == 0 ? mapped : UserFacingError(
                    title: count == 1 ? "1 item wasn't copied to the phone" : "\(count) items weren't copied to the phone",
                    message: ([mapped.message] + outcome.failed.prefix(5)).joined(separator: "\n"),
                    suggestions: mapped.suggestions, canRetry: false)
            }
        }
    }

    // MARK: - Drag to Finder

    /// Removes the copies made for drags into Finder. Called when the phone goes away and when the app quits;
    /// Finder has long finished its own copy by then.
    public func clearDragStaging() {
        try? FileManager.default.removeItem(at: dragRoot)
    }

    /// Call when the app quits: nothing copied for previews or drags stays in the cache.
    public func clearCaches() {
        preview.reset(session: nil)
        clearDragStaging()
    }

    /// Copies `item` for a drag into Finder. It runs as an ordinary job in the Transfers panel, with the usual
    /// safety checks, into a private staging folder; Finder then copies the finished file or folder into place.
    /// `progress` gets 0…1 while copying.
    public func exportForDrag(_ item: RemoteItem, progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> URL {
        guard monitor.state.isReady, let session = monitor.session else { throw ZapdropError.noDevice }
        let staging = dragRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var options = settings.transferOptions
        options.duplicatePolicy = .always(.keepBoth) // the staging folder is empty; never ask
        let request = TransferRequest(items: [item], storageID: item.storageID, sourceFolderPath: browser.currentFolderPath,
                                      destination: staging, options: options,
                                      destinationIsCaseInsensitive: LocalDestinationService.isCaseInsensitive(staging))
        let id = transfers.start(request, session: session)
        while true {
            try? await Task.sleep(nanoseconds: 150_000_000)
            transfers.refresh()
            guard let snapshot = transfers.rows.first(where: { $0.id == id })?.snapshot else { throw ZapdropError.cancelled }
            progress(snapshot.fraction)
            guard snapshot.phase.isFinished else { continue }
            let produced = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
            guard snapshot.phase == .completed, produced.count == 1 else {
                if case .failed(let e) = snapshot.phase { throw e }
                throw snapshot.lastError ?? ZapdropError.cancelled
            }
            return produced[0]
        }
    }

    /// Space bar / ⌘Y / right-click: Quick Look the selected file, or close the preview that's showing.
    public func togglePreview(_ item: RemoteItem? = nil) {
        preview.toggle(item ?? browser.selectedItems.first { !$0.isFolder })
    }

    public var canFreePhone: Bool { phoneReleaser != nil }

    public func refreshCompetingApps() async {
        competingApps = await phoneReleaser?.competingApps() ?? []
    }

    /// "Free Up Phone & Connect": quit the apps holding the phone, release the camera service, connect.
    public func freeUpPhone() {
        guard phoneReleaser != nil, !isFreeingPhone else { return }
        isFreeingPhone = true
        performFree(quittingApps: true)
    }

    /// The phone was just claimed by another program: take it back without bothering the user when that's safe —
    /// always for the camera service (if enabled), for apps only once the user has said so. One try per connection.
    private func freeAutomaticallyIfAllowed() {
        guard let phoneReleaser, !isFreeingPhone, settings.autoReleaseCameraService,
              let id = monitor.selectedDeviceID, !autoFreedDevices.contains(id) else { return }
        autoFreedDevices.insert(id)
        isFreeingPhone = true // shows "Connecting…" rather than flashing the busy screen
        Task {
            let apps = await phoneReleaser.competingApps()
            competingApps = apps
            guard monitor.isBusy else { isFreeingPhone = false; return }
            if !apps.isEmpty, !settings.autoQuitPhoneApps {
                isFreeingPhone = false // an app of the user's is open: ask first
                return
            }
            performFree(quittingApps: !apps.isEmpty)
        }
    }

    private func performFree(quittingApps: Bool) {
        guard let phoneReleaser else { isFreeingPhone = false; return }
        freeingPhoneFailed = false
        Task {
            await phoneReleaser.release(quittingApps: quittingApps)
            // macOS relaunches the camera service within about a second and it grabs the phone again, so open
            // straight away and keep trying briefly; once Zapdrop holds the phone the service can't take it back.
            for _ in 0..<20 {
                await monitor.retry()
                if !monitor.isBusy { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            freeingPhoneFailed = monitor.isBusy
            isFreeingPhone = false
            await refreshCompetingApps()
        }
    }

    public func setShowHiddenFiles(_ show: Bool) {
        settings.showHiddenFiles = show
        browser.showHiddenFiles = show
    }
}
