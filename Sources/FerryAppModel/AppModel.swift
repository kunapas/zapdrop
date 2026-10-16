import Foundation
import Observation
import FerryCore

/// Releases the phone from macOS's camera daemon (implemented in the app; see docs/DECISIONS.md D5).
public protocol CameraDaemonReleasing: Sendable {
    /// Returns true if the daemon was asked to quit.
    func release() async -> Bool
}

/// Top-level state for one window: device, browser, transfers, destination and settings, wired together.
@MainActor @Observable
public final class AppModel<Image: AnyObject> {
    public let monitor: DeviceMonitor
    public let browser: DirectoryBrowserViewModel
    public let transfers: TransferQueueViewModel
    public let destination: LocalDestinationService
    public let settings: AppSettings
    public let thumbnails: ThumbnailService<Image>
    public let isMock: Bool

    /// A message for an alert (e.g. "Choose a destination first").
    public var notice: UserFacingError?

    @ObservationIgnored private let cameraDaemon: CameraDaemonReleasing?
    @ObservationIgnored private var observedGeneration = -1
    @ObservationIgnored private var observedStorages: [StorageInfo] = []

    public init(backend: DeviceBackend, isMock: Bool, store: KeyValueStore,
                inspector: ExclusiveAccessInspecting? = nil, cameraDaemon: CameraDaemonReleasing? = nil,
                bookmarkCodec: BookmarkCodec = SystemBookmarkCodec(), space: VolumeSpaceProvider = SystemVolumeSpace(),
                decodeThumbnail: @escaping @Sendable (Data) -> (Image, cost: Int)?) {
        self.isMock = isMock
        self.monitor = DeviceMonitor(backend: backend, inspector: inspector)
        self.browser = DirectoryBrowserViewModel()
        self.transfers = TransferQueueViewModel(space: space)
        self.destination = LocalDestinationService(store: store, codec: bookmarkCodec)
        self.settings = AppSettings(store: store)
        self.thumbnails = ThumbnailService(decode: decodeThumbnail)
        self.cameraDaemon = cameraDaemon

        browser.showHiddenFiles = settings.showHiddenFiles
        browser.onDisconnect = { [weak self] in self?.monitor.reportDisconnected() }
        transfers.onDisconnect = { [weak self] in self?.monitor.reportDisconnected() }
        monitor.isTransferActive = { [weak self] in self?.transfers.hasActiveTransfer ?? false }
        thumbnails.isPaused = { [weak self] in self?.transfers.hasActiveTransfer ?? false }
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
        let session = monitor.state.isReady ? monitor.session : nil
        let generation = monitor.sessionGeneration
        let hasSession = session != nil
        guard generation != observedGeneration || hasSession != browserHasSession || monitor.storages != observedStorages else {
            return
        }
        if generation != observedGeneration || !hasSession { thumbnails.reset(session: session) }
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
            notice = ErrorMapper.map(FerryError.noDevice)
            return false
        }
        if let url { destination.choose(url) }
        guard let dest = destination.destination else {
            notice = UserFacingError(title: "Choose where to save", message: "Pick a folder on your Mac first.",
                                     suggestions: [], canRetry: false)
            return false
        }
        guard destination.isAvailable else {
            notice = ErrorMapper.map(FerryError.destinationUnavailable)
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
            notice = ErrorMapper.map(FerryError.noDevice)
            return
        }
        transfers.retry(id, session: session)
    }

    public var canReleaseCameraDaemon: Bool { cameraDaemon != nil }

    public func releaseCameraDaemon() {
        guard let cameraDaemon else { return }
        Task {
            _ = await cameraDaemon.release()
            try? await Task.sleep(nanoseconds: 700_000_000)
            monitor.retryNow()
        }
    }

    public func setShowHiddenFiles(_ show: Bool) {
        settings.showHiddenFiles = show
        browser.showHiddenFiles = show
    }
}
