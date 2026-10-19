import Foundation
import Observation
import FerryCore

public enum SortKey: String, CaseIterable, Sendable {
    case name, kind, size, modified
}

public struct SortOrder: Equatable, Sendable {
    public var key: SortKey
    public var ascending: Bool
    public init(key: SortKey = .name, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }
}

public enum FileFilter: String, CaseIterable, Sendable, Identifiable {
    case all, photos, videos, audio, documents
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: return "All Files"
        case .photos: return "Photos"
        case .videos: return "Videos"
        case .audio: return "Audio"
        case .documents: return "Documents"
        }
    }
    func matches(_ kind: FileKind) -> Bool {
        switch self {
        case .all: return true
        case .photos: return kind == .photo
        case .videos: return kind == .video
        case .audio: return kind == .audio
        case .documents: return kind == .document
        }
    }
}

/// Finder-like browsing of one phone: storage → folders → files. Folders are listed lazily and cached briefly.
@MainActor @Observable
public final class DirectoryBrowserViewModel {
    public private(set) var storages: [StorageInfo] = []
    public private(set) var storage: StorageInfo?
    /// Folders from the storage root to the current folder.
    public private(set) var path: [RemoteItem] = []
    public private(set) var isLoading = false
    /// While a folder is being read: items read so far and the folder's total.
    public private(set) var loadProgress: (loaded: Int, total: Int)?
    public private(set) var error: UserFacingError?
    /// Items shown (filtered and sorted).
    public private(set) var items: [RemoteItem] = []

    public var sortOrder = SortOrder() { didSet { if oldValue != sortOrder { needsSort = true; rebuild() } } }
    public var filter: FileFilter = .all { didSet { if oldValue != filter { rebuild() } } }
    public var searchText = "" { didSet { if oldValue != searchText { rebuild() } } }
    public var showHiddenFiles = false { didSet { if oldValue != showHiddenFiles { rebuild() } } }
    public var selection: Set<ObjectID> = []

    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var listing: [RemoteItem] = [] { didSet { needsSort = true } }
    /// `listing` in display order. Filtering and searching reuse it, so only a new listing or sort order re-sorts.
    @ObservationIgnored private var sortedListing: [RemoteItem] = []
    @ObservationIgnored private var needsSort = true
    @ObservationIgnored private var cache: [RemoteLocation: [RemoteItem]] = [:]
    @ObservationIgnored private var cacheOrder: [RemoteLocation] = []
    @ObservationIgnored private let cacheLimit = 24
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var lastPartialRebuild = Date.distantPast
    /// Items per listing piece: small enough that the first rows appear within a second or two on a slow phone.
    @ObservationIgnored public var listingBatchSize = 50
    /// Called when listing discovers the phone is gone.
    @ObservationIgnored public var onDisconnect: () -> Void = {}

    public init() {}

    // MARK: - Session

    public func attach(session: DeviceSession?, storages: [StorageInfo]) {
        let sameSession = session != nil && session === self.session
        self.session = session
        self.storages = storages
        if !sameSession {
            cancelLoading()
            cache.removeAll()
            cacheOrder.removeAll()
            path = []
            selection = []
            listing = []
            items = []
            error = nil
            storage = nil
        }
        if let current = storage, let refreshed = storages.first(where: { $0.id == current.id }) {
            storage = refreshed
        } else if let first = storages.first {
            open(storage: first)
        } else {
            storage = nil
            listing = []
            rebuild()
        }
    }

    // MARK: - Navigation

    public var currentLocation: RemoteLocation? {
        guard let storage else { return nil }
        return RemoteLocation(storageID: storage.id, folderID: path.last?.id ?? rootParentID)
    }

    /// Raw names from the storage root to the current folder (used to find files again after a reconnect).
    public var currentFolderPath: [String] { path.map(\.name) }

    public var breadcrumb: [String] {
        [storage?.displayName ?? "Phone"] + path.map(\.displayName)
    }

    public var canGoUp: Bool { !path.isEmpty }

    public func open(storage: StorageInfo) {
        self.storage = storage
        path = []
        load()
    }

    public func open(_ item: RemoteItem) {
        guard item.isFolder else { return }
        path.append(item)
        load()
    }

    public func goUp() {
        guard !path.isEmpty else { return }
        path.removeLast()
        load()
    }

    /// 0 = storage root, n = n-th folder in the breadcrumb.
    public func goTo(breadcrumbIndex index: Int) {
        guard index >= 0, index <= path.count, index != path.count else { return }
        path = Array(path.prefix(index))
        load()
    }

    // MARK: - Space tips

    /// Ways to free space found in the open folder (big videos, old camera photos, installers…), biggest first.
    /// Worked out from the listing already on screen, so they cost the phone nothing.
    public private(set) var folderTips: [SpaceTip] = []

    /// Selects the files a tip is about, ready to copy before deleting them on the phone. Clears any filter or
    /// search first so every one of them is visible.
    public func select(_ tip: SpaceTip) {
        filter = .all
        searchText = ""
        let ids = Set(tip.files.map(\.id))
        selection = Set(items.lazy.filter { ids.contains($0.id) }.map(\.id))
    }

    // MARK: - Empty states

    /// Why nothing is listed: the folder is empty, or a filter or search hides what's there.
    public enum EmptyReason: Equatable {
        case emptyFolder
        case noMatches(query: String)
        case filtered(FileFilter)
    }

    public var emptyReason: EmptyReason? {
        guard items.isEmpty, !isLoading else { return nil }
        let visible = showHiddenFiles ? listing.count : listing.filter { !$0.name.hasPrefix(".") }.count
        if visible == 0 { return .emptyFolder }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { return .noMatches(query: query) }
        return filter == .all ? .emptyFolder : .filtered(filter)
    }

    private func updateTips() {
        guard let storage, !listing.isEmpty else { folderTips = []; return }
        let files = listing.filter { !$0.isFolder }.map { AnalyzedFile(item: $0, folders: path) }
        folderTips = SpaceTip.make(storage: storage, files: files, maxListed: .max, warnAboutLowSpace: false)
    }

    public func reload() {
        if let location = currentLocation { cache[location] = nil }
        load(force: true)
    }

    // MARK: - Selection

    public var selectedItems: [RemoteItem] { items.filter { selection.contains($0.id) } }

    public func selectAll() { selection = Set(items.map(\.id)) }
    public func clearSelection() { selection = [] }

    public var statusText: String {
        if isLoading, let progress = loadProgress {
            return "Reading folder… \(progress.loaded) of \(progress.total) items"
        }
        let count = items.count
        let base = count == 1 ? "1 item" : "\(count) items"
        let selected = selectedItems
        guard !selected.isEmpty else { return base }
        let bytes = selected.reduce(UInt64(0)) { ProgressMath.add($0, $1.size ?? 0) }
        let folders = selected.filter(\.isFolder).count
        var text = "\(selected.count) of \(count) selected"
        if bytes > 0 { text += ", \(ByteFormatter.string(bytes))" }
        if folders > 0 { text += folders == 1 ? " plus 1 folder" : " plus \(folders) folders" }
        return text
    }

    // MARK: - Loading

    private func load(force: Bool = false) {
        selection = []
        error = nil
        folderTips = []
        cancelLoading()
        guard let session, let location = currentLocation else {
            listing = []
            rebuild()
            return
        }
        if !force, let cached = cache[location] {
            listing = cached
            rebuild()
            updateTips()
            return
        }
        let token = loadToken
        isLoading = true
        listing = []
        rebuild()
        let onBatch: @Sendable ([RemoteItem], Int) async -> Void = { [weak self] batch, total in
            await self?.receive(batch, total: total, token: token)
        }
        loadTask = Task { [weak self, listingBatchSize] in
            do {
                let children = try await session.children(of: location, batchSize: listingBatchSize, onBatch: onBatch)
                guard let self, token == self.loadToken else { return }
                self.store(children, for: location)
                self.listing = children
                self.isLoading = false
                self.loadProgress = nil
                self.rebuild()
                self.updateTips()
            } catch {
                guard let self, token == self.loadToken else { return }
                self.isLoading = false
                self.loadProgress = nil
                let e = (error as? FerryError) ?? .io(detail: "\(error)")
                self.error = ErrorMapper.map(e)
                if e == .deviceDisconnected { self.onDisconnect() }
                if e == .sourceRemoved, !self.path.isEmpty { self.path.removeLast(); self.load(force: true) }
            }
        }
    }

    /// Stops reading the previous folder (or session) so the phone is free for what is wanted now.
    private func cancelLoading() {
        loadToken += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        loadProgress = nil
    }

    /// Shows a newly read piece of the folder straight away.
    private func receive(_ batch: [RemoteItem], total: Int, token: Int) {
        guard token == loadToken, isLoading else { return }
        let isFirst = listing.isEmpty
        listing += batch
        loadProgress = (listing.count, total)
        // Re-sorting everything per piece is quadratic on folders of tens of thousands; a few times a second is
        // plenty to watch it fill in (the finished listing is always rebuilt).
        let now = Date()
        if isFirst || now.timeIntervalSince(lastPartialRebuild) >= 0.25 {
            lastPartialRebuild = now
            rebuild()
        }
    }

    private func store(_ children: [RemoteItem], for location: RemoteLocation) {
        cache[location] = children
        cacheOrder.removeAll { $0 == location }
        cacheOrder.append(location)
        while cacheOrder.count > cacheLimit { cache[cacheOrder.removeFirst()] = nil }
    }

    private func rebuild() {
        if needsSort {
            sortedListing = listing.sorted(by: Self.comparator(sortOrder))
            needsSort = false
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filter = self.filter, showHidden = showHiddenFiles
        let result: [RemoteItem]
        if filter == .all, query.isEmpty, showHidden {
            result = sortedListing
        } else {
            result = sortedListing.filter { item in
                if !showHidden, item.name.hasPrefix(".") { return false }
                if !item.isFolder, filter != .all, !filter.matches(item.kind) { return false }
                if !query.isEmpty, item.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
                return true
            }
        }
        // Unchanged rows mean no work for the table.
        if result != items { items = result }
        if !selection.isEmpty {
            let kept = selection.intersection(result.map(\.id))
            if kept != selection { selection = kept }
        }
    }

    /// Folders first (like Finder), then by the chosen key; ties broken by name, then ID, for stable order.
    nonisolated static func comparator(_ order: SortOrder) -> (RemoteItem, RemoteItem) -> Bool {
        { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            func byName() -> ComparisonResult { a.name.compare(b.name, options: [.caseInsensitive, .numeric]) }
            var result: ComparisonResult
            switch order.key {
            case .name: result = byName()
            case .kind:
                result = a.kind.rawValue == b.kind.rawValue ? .orderedSame : (a.kind.rawValue < b.kind.rawValue ? .orderedAscending : .orderedDescending)
            case .size:
                let x = a.size ?? 0, y = b.size ?? 0
                result = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            case .modified:
                let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
                result = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            }
            if result == .orderedSame { result = byName() }
            if result == .orderedSame { return order.ascending ? a.id < b.id : a.id > b.id }
            return order.ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }
}
