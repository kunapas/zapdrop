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
    public let preview: PreviewService
    public let isMock: Bool

    /// A message for an alert (e.g. "Choose a destination first").
    public var notice: UserFacingError?

    @ObservationIgnored private let cameraDaemon: CameraDaemonReleasing?
    @ObservationIgnored private let dragRoot: URL
    @ObservationIgnored private var observedGeneration = -1
    @ObservationIgnored private var observedStorages: [StorageInfo] = []

    public init(backend: DeviceBackend, isMock: Bool, store: KeyValueStore,
                inspector: ExclusiveAccessInspecting? = nil, cameraDaemon: CameraDaemonReleasing? = nil,
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
        self.cameraDaemon = cameraDaemon

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
        let session = monitor.state.isReady ? monitor.session : nil
        let generation = monitor.sessionGeneration
        let hasSession = session != nil
        guard generation != observedGeneration || hasSession != browserHasSession || monitor.storages != observedStorages else {
            return
        }
        if generation != observedGeneration || !hasSession {
            thumbnails.reset(session: session)
            preview.reset(session: session)
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

    /// Ejecting is refused while copying: the phone must finish (or the copy be cancelled) first.
    public var canEject: Bool { monitor.session != nil && !transfers.hasActiveTransfer }

    public func ejectPhone() {
        guard canEject else { return }
        Task { await monitor.eject() }
    }

    // MARK: - Drag to Finder

    /// Copies `item` for a drag into Finder. It runs as an ordinary job in the Transfers panel, with the usual
    /// safety checks, into a private staging folder; Finder then copies the finished file or folder into place.
    /// `progress` gets 0…1 while copying.
    public func exportForDrag(_ item: RemoteItem, progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> URL {
        guard monitor.state.isReady, let session = monitor.session else { throw FerryError.noDevice }
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
            guard let snapshot = transfers.rows.first(where: { $0.id == id })?.snapshot else { throw FerryError.cancelled }
            progress(snapshot.fraction)
            guard snapshot.phase.isFinished else { continue }
            let produced = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
            guard snapshot.phase == .completed, produced.count == 1 else {
                if case .failed(let e) = snapshot.phase { throw e }
                throw snapshot.lastError ?? FerryError.cancelled
            }
            return produced[0]
        }
    }

    /// Space bar / ⌘Y / right-click: Quick Look the selected file, or close the preview that's showing.
    public func togglePreview(_ item: RemoteItem? = nil) {
        preview.toggle(item ?? browser.selectedItems.first { !$0.isFolder })
    }

    public var canReleaseCameraDaemon: Bool { cameraDaemon != nil }

    public func releaseCameraDaemon() {
        guard let cameraDaemon else { return }
        Task {
            _ = await cameraDaemon.release()
            // macOS relaunches the camera service within about a second and it grabs the phone again, so open
            // straight away and keep trying briefly; once Zapdrop holds the phone the service can't take it back.
            for _ in 0..<10 {
                await monitor.retry()
                guard monitor.isBusy else { return }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    public func setShowHiddenFiles(_ show: Bool) {
        settings.showHiddenFiles = show
        browser.showHiddenFiles = show
    }
}
