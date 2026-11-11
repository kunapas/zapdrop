import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import ZapdropAppModel
import ZapdropCore

struct BrowserContainer: View {
    let model: Model
    let viewMode: ViewMode

    var body: some View {
        VStack(spacing: 0) {
            DeviceHeader(model: model)
            VStack(spacing: 0) {
            ZStack {
                switch viewMode {
                case .list: FileTable(model: model, browser: model.browser)
                case .grid: FileGrid(model: model, browser: model.browser)
                }
                // Large folders fill in piece by piece; only cover the list while nothing has arrived yet.
                if model.browser.isLoading && model.browser.items.isEmpty {
                    ProgressView("Reading folder…")
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if let error = model.browser.error {
                    ContentUnavailableView {
                        Label(error.title, systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(([error.message] + error.suggestions).joined(separator: "\n"))
                    } actions: {
                        Button("Try Again") { model.browser.reload() }
                    }
                } else if let reason = model.browser.emptyReason {
                    EmptyFolderView(model: model, reason: reason)
                }
                if let item = model.preview.preparing {
                    PreviewProgress(model: model, item: item)
                }
            }
            if let upload = model.uploads.progress {
                Divider()
                UploadStrip(model: model, progress: upload)
            }
            Divider()
            // Path bar, then status bar: the same two strips Finder puts under its file list.
            HStack {
                Breadcrumb(model: model)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            Divider()
            HStack(spacing: 12) {
                TipsButton(model: model)
                Spacer()
                Text(model.browser.statusText).lineLimit(1)
                Spacer()
                if let support = SupportLink.url {
                    Button {
                        NSWorkspace.shared.open(support)
                    } label: {
                        Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Enjoying \(AppInfo.name)? Opens \(support.host ?? "the support page") in your browser")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            .accessibilityElement(children: .contain)
            }
            // The files sit in their own rounded panel under the cards.
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator) }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        // Drop files or folders from Finder to copy them into the folder being shown.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard model.canCopyToPhone, !files.isEmpty else { return false }
            model.copyToPhone(files)
            return true
        }
        .searchable(text: Binding(get: { model.browser.searchText }, set: { model.browser.searchText = $0 }),
                    placement: .toolbar, prompt: "Search this folder")
        .quickLookPreview(Binding(get: { model.preview.url }, set: { model.preview.url = $0 }))
        .onChange(of: model.preview.error) { _, error in
            if let error { model.notice = error; model.preview.clearError() }
        }
    }
}

/// The connected phone at the top of the page, in the style of the welcome page: the phone itself, then a card for
/// each storage and one for where copies go.
struct DeviceHeader: View {
    let model: Model

    var body: some View {
        let summary = model.monitor.session?.summary
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Brand.gradient)
                    .frame(width: 72, height: 72)
                    .overlay {
                        Image(systemName: "smartphone").font(.system(size: 36, weight: .medium)).foregroundStyle(.white)
                    }
                    .shadow(color: Brand.indigo.opacity(0.35), radius: 10, y: 5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        Text(summary?.displayName ?? "Phone").font(.system(size: 26, weight: .bold)).lineLimit(1)
                        Button {
                            model.ejectPhone()
                        } label: {
                            Image(systemName: "eject.circle.fill").font(.title2)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!model.canEject)
                        .help(model.canEject ? "Eject, then it's safe to unplug the phone (⌘E)"
                                             : "Can't eject while copying. Wait for the copy to finish or cancel it.")
                        .accessibilityLabel("Eject \(summary?.displayName ?? "phone")")
                    }
                    HStack(spacing: 12) {
                        if let maker = summary?.manufacturer.map(DisplayText.clean), !maker.isEmpty {
                            Text(maker)
                        }
                        if let percent = model.monitor.batteryPercent {
                            Label("\(percent)%", systemImage: Self.batterySymbol(percent))
                                .accessibilityLabel("Battery \(percent) percent")
                        }
                        if let speed = model.monitor.devices.first(where: { $0.id == summary?.id })?.usbSpeed {
                            Label(speed.shortName, systemImage: speed.isSlow ? "exclamationmark.triangle.fill" : "bolt.horizontal.fill")
                                .foregroundStyle(speed.isSlow ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                .help(speed.isSlow
                                      ? "\(speed.displayName): copies are limited to about 40 MB/s. Plug the phone straight into the Mac with a USB 3 cable (not through a hub or adapter) for faster copies."
                                      : "\(speed.displayName)")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 12)
                if model.monitor.devices.count > 1 {
                    Menu("Switch Phone") {
                        ForEach(model.monitor.devices.filter { $0.id != summary?.id }) { device in
                            Button(device.summary.displayName) { model.monitor.select(device.id) }
                        }
                    }
                    .fixedSize()
                }
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(model.browser.storages) { storage in
                    StorageCard(model: model, storage: storage)
                }
                DestinationCard(model: model)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    static func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// The rounded panel the welcome page uses, for the cards under the phone.
private struct CardBackground: ViewModifier {
    var selected = false

    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: 380, minHeight: 86, alignment: .topLeading) // cards keep their shape in a wide window
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
            }
    }
}

/// One of the phone's storages: click to browse it. The one being shown is outlined.
private struct StorageCard: View {
    let model: Model
    let storage: StorageInfo

    var body: some View {
        let selected = storage.id == model.browser.storage?.id
        let low = storage.capacityBytes > 0 && storage.freeBytes < storage.capacityBytes / 10
        Button {
            model.browser.open(storage: storage)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    IconTile(symbol: storage.isRemovable ? "sdcard.fill" : "internaldrive.fill",
                             color: storage.isRemovable ? .orange : .blue, size: 30)
                    Text(storage.displayName).fontWeight(.semibold).lineLimit(1)
                }
                if storage.capacityBytes > 0 {
                    CapacityBar(fraction: ProgressMath.fraction(done: storage.usedBytes, total: storage.capacityBytes), low: low)
                    Text("\(ByteFormatter.string(storage.freeBytes)) free of \(ByteFormatter.string(storage.capacityBytes))")
                        .font(.callout)
                        .foregroundStyle(low ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .monospacedDigit()
                }
            }
            .modifier(CardBackground(selected: selected && model.browser.storages.count > 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(storage.displayName), \(ByteFormatter.string(storage.freeBytes)) free")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Where copies go: the folder's own Finder icon, its name and location, and buttons to change or show it.
private struct DestinationCard: View {
    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let url = model.destination.destination {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Save to \(url.lastPathComponent)").fontWeight(.semibold).lineLimit(1)
                        Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .help(url.path)
                } else {
                    IconTile(symbol: "folder.fill.badge.plus", color: .teal, size: 30)
                    Text("Choose where to save").fontWeight(.semibold)
                }
            }
            if model.destination.destination != nil, !model.destination.isAvailable {
                Label("Not available. Is the disk connected?", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 6) {
                Button(model.destination.destination == nil ? "Choose…" : "Change…") {
                    if let url = FinderBridge.chooseFolder(startingAt: model.destination.destination) {
                        model.destination.choose(url)
                    }
                }
                .accessibilityLabel("Choose destination folder")
                if let url = model.destination.destination, model.destination.isAvailable {
                    Button("Show in Finder") { FinderBridge.open(folder: url) }
                }
            }
        }
        .modifier(CardBackground())
    }
}

/// "Paste" in the right-click menus: copies what was copied in Finder into the folder being shown.
struct PasteToPhoneButton: View {
    let model: Model

    var body: some View {
        let count = FinderBridge.filesOnPasteboard().count
        Button(count > 1 ? "Paste \(count) Items" : count == 1 ? "Paste Item" : "Paste") {
            model.copyToPhone(FinderBridge.filesOnPasteboard())
        }
        .disabled(count == 0 || !model.canCopyToPhone)
    }
}

/// Progress of a copy from the Mac to the phone, with Cancel.
struct UploadStrip: View {
    let model: Model
    let progress: UploadService.Progress

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up").foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(progress.filesTotal == 0 ? "Getting ready to copy to the phone…"
                     : "Copying to the phone: \(progress.currentName)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: progress.fraction)
                    .accessibilityLabel("Copying to the phone")
                    .accessibilityValue("\(Int(progress.fraction * 100)) percent")
            }
            Text("\(min(progress.filesDone + 1, max(progress.filesTotal, 1))) of \(max(progress.filesTotal, 1))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Cancel") { model.uploads.cancel() }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Shown while a file is copied from the phone so Quick Look can open it.
struct PreviewProgress: View {
    let model: Model
    let item: RemoteItem

    var body: some View {
        VStack(spacing: 10) {
            Text("Preparing preview of \(item.displayName)…").lineLimit(1).truncationMode(.middle)
            if item.size != nil {
                ProgressView(value: model.preview.fraction).frame(width: 220)
            } else {
                ProgressView().controlSize(.small)
            }
            Button("Cancel") { model.preview.close() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(18)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Explains an empty list: an empty folder, or a filter or search hiding what's there (with a way back).
struct EmptyFolderView: View {
    let model: Model
    let reason: DirectoryBrowserViewModel.EmptyReason

    var body: some View {
        switch reason {
        case .emptyFolder:
            ContentUnavailableView("Empty Folder", systemImage: "folder")
        case .noMatches(let query):
            ContentUnavailableView.search(text: query)
        case .filtered(let filter):
            ContentUnavailableView {
                Label("No \(filter.title) Here", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("This folder has files, just none of this kind.")
            } actions: {
                Button("Show All Files") { model.browser.filter = .all }
            }
        }
    }
}

/// "💡 2 ways to free space" in the status bar, shown only for folders where a tip applies. The popover explains
/// each one and can select its files, ready to copy to the Mac before deleting them on the phone.
struct TipsButton: View {
    let model: Model
    @State private var showing = false

    var body: some View {
        let tips = model.browser.folderTips
        if !tips.isEmpty {
            Button {
                showing.toggle()
            } label: {
                Label(tips.count == 1 ? "1 way to free space" : "\(tips.count) ways to free space", systemImage: "lightbulb")
            }
            .buttonStyle(.borderless)
            .help("Ways to free space on your phone, based on this folder")
            .popover(isPresented: $showing, arrowEdge: .top) {
                TipsPopover(model: model, tips: tips) { showing = false }
            }
        }
    }
}

private struct TipsPopover: View {
    let model: Model
    let tips: [SpaceTip]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Free up space on your phone").font(.headline)
                Text("Zapdrop never deletes anything on your phone. Copy these files to your Mac first, then delete them on the phone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(tips) { tip in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: TipStyle.symbol(tip.kind))
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tip.title).fontWeight(.semibold)
                        Text(tip.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(tip.fileCount == 1 ? "Select This File" : "Select \(tip.fileCount) Files") {
                            model.browser.select(tip)
                            close()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

// MARK: - List

struct FileTable: View {
    let model: Model
    @Bindable var browser: DirectoryBrowserViewModel
    @State private var sortOrder = [KeyPathComparator(\RemoteItem.name)]

    var body: some View {
        Table(of: RemoteItem.self, selection: $browser.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 8) {
                    ThumbnailView(model: model, item: item, size: 20)
                    Text(item.displayName).lineLimit(1).truncationMode(.middle)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText(item))
            }
            .width(min: 220, ideal: 360)
            TableColumn("Date Modified", value: \.sortDate) { item in
                Text(item.dateDescription).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Size", value: \.sortSize) { item in
                Text(item.sizeDescription).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Kind", value: \.kindDescription) { item in
                Text(item.kindDescription).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)
        } rows: {
            ForEach(browser.items) { item in
                // Drag rows into Finder to copy them there (all selected rows travel together).
                TableRow(item).itemProvider { FinderDrag.provider(for: item, model: model) }
            }
        }
        .contextMenu(forSelectionType: ObjectID.self) { ids in
            if !ids.isEmpty {
                if ids.count == 1, let item = items(ids).first {
                    if item.isFolder {
                        Button("Open") { browser.open(item) }
                    } else {
                        Button("Quick Look") { model.preview.show(item) }
                    }
                    Divider()
                }
                Button("Copy to Mac") { model.copySelection(items(ids)) }
                Divider()
            }
            // Also on empty space: paste what was copied in Finder into this folder.
            PasteToPhoneButton(model: model)
        } primaryAction: { ids in
            if ids.count == 1, let item = items(ids).first, item.isFolder { browser.open(item) }
        }
        .onKeyPress(.space) {
            model.togglePreview()
            return .handled
        }
        .onPasteCommand(of: [.fileURL]) { _ in model.copyToPhone(FinderBridge.filesOnPasteboard()) } // ⌘V
        .onAppear {
            // The column header starts at Name ↑; keep the rows in step with it.
            browser.sortOrder = ZapdropAppModel.SortOrder(key: .name, ascending: true)
        }
        .onChange(of: sortOrder) { _, newValue in
            guard let first = newValue.first else { return }
            let path = first.keyPath
            let key: SortKey
            if path == (\RemoteItem.sortSize as PartialKeyPath<RemoteItem>) {
                key = .size
            } else if path == (\RemoteItem.sortDate as PartialKeyPath<RemoteItem>) {
                key = .modified
            } else if path == (\RemoteItem.kindDescription as PartialKeyPath<RemoteItem>) {
                key = .kind
            } else {
                key = .name
            }
            browser.sortOrder = ZapdropAppModel.SortOrder(key: key, ascending: first.order == .forward)
        }
    }

    private func items(_ ids: Set<ObjectID>) -> [RemoteItem] { browser.items.filter { ids.contains($0.id) } }
}

func accessibilityText(_ item: RemoteItem) -> String {
    item.isFolder ? "\(item.displayName), folder" : "\(item.displayName), \(item.kindDescription), \(item.sizeDescription)"
}

// MARK: - Thumbnails grid

struct FileGrid: View {
    let model: Model
    @Bindable var browser: DirectoryBrowserViewModel
    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(browser.items) { item in
                    GridCell(model: model, item: item, isSelected: browser.selection.contains(item.id))
                        .onTapGesture(count: 2) { if item.isFolder { browser.open(item) } }
                        .onTapGesture { select(item) }
                        .onDrag { FinderDrag.provider(for: item, model: model) ?? NSItemProvider() }
                        .contextMenu {
                            if item.isFolder {
                                Button("Open") { browser.open(item) }
                            } else {
                                Button("Quick Look") { model.preview.show(item) }
                            }
                            Divider()
                            Button("Copy to Mac") {
                                model.copySelection(browser.selection.contains(item.id) ? browser.selectedItems : [item])
                            }
                            Divider()
                            PasteToPhoneButton(model: model)
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(named: item.isFolder ? "Open" : "Select") {
                            if item.isFolder { browser.open(item) } else { select(item) }
                        }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .contextMenu { PasteToPhoneButton(model: model) } // right-click on empty space
        .onPasteCommand(of: [.fileURL]) { _ in model.copyToPhone(FinderBridge.filesOnPasteboard()) } // ⌘V
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            model.togglePreview()
            return .handled
        }
    }

    private func select(_ item: RemoteItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if browser.selection.contains(item.id) { browser.selection.remove(item.id) } else { browser.selection.insert(item.id) }
        } else {
            browser.selection = [item.id]
        }
    }
}

struct GridCell: View {
    let model: Model
    let item: RemoteItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 7) {
            ThumbnailView(model: model, item: item, size: 104)
                .frame(width: 116, height: 116)
                // Finder's icon-view selection: a grey plate behind the icon, the name on the accent colour.
                .background(isSelected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(item.displayName)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(item))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ThumbnailView: View {
    let model: Model
    let item: RemoteItem
    let size: CGFloat

    var body: some View {
        let _ = model.thumbnails.version // re-render when previews arrive
        Group {
            if let image = model.thumbnails.image(for: item) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size > 40 ? 10 : 3, style: .continuous))
            } else {
                Image(nsImage: FileIcons.image(for: item))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(size > 40 ? size * 0.06 : 0)
            }
        }
        .frame(width: size, height: size)
        .onAppear { model.thumbnails.request(item) }
        .onDisappear { model.thumbnails.cancel(item) }
        .accessibilityHidden(true)
    }
}
