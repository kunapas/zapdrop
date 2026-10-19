import AppKit
import QuickLook
import SwiftUI
import FerryAppModel
import FerryCore

struct BrowserContainer: View {
    let model: Model
    let viewMode: ViewMode

    var body: some View {
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
                        .glassPanel(cornerRadius: 14)
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
            Divider()
            HStack(spacing: 12) {
                Text(model.browser.statusText).lineLimit(1)
                Spacer()
                TipsButton(model: model)
                if let dest = model.destination.destination {
                    Text("Saving to \(dest.lastPathComponent)").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .accessibilityElement(children: .contain)
        }
        .searchable(text: Binding(get: { model.browser.searchText }, set: { model.browser.searchText = $0 }),
                    placement: .toolbar, prompt: "Search this folder")
        .quickLookPreview(Binding(get: { model.preview.url }, set: { model.preview.url = $0 }))
        .onChange(of: model.preview.error) { _, error in
            if let error { model.notice = error; model.preview.clearError() }
        }
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
        .glassPanel(cornerRadius: 14)
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
                Label(tips.count == 1 ? "1 way to free space" : "\(tips.count) ways to free space", systemImage: "lightbulb.max")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .glassPanel(cornerRadius: 11, tint: .yellow.opacity(0.22))
            }
            .buttonStyle(.plain)
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
                Text("Zapdrop only reads your phone. Copy these files to your Mac first, then delete them on the phone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(tips) { tip in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: TipStyle.symbol(tip.kind))
                        .font(.title3)
                        .foregroundStyle(Brand.gradient)
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
            }
        } primaryAction: { ids in
            if ids.count == 1, let item = items(ids).first, item.isFolder { browser.open(item) }
        }
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .onKeyPress(.space) {
            model.togglePreview()
            return .handled
        }
        .onAppear {
            // The column header starts at Name ↑; keep the rows in step with it.
            browser.sortOrder = FerryAppModel.SortOrder(key: .name, ascending: true)
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
            browser.sortOrder = FerryAppModel.SortOrder(key: key, ascending: first.order == .forward)
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
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(named: item.isFolder ? "Open" : "Select") {
                            if item.isFolder { browser.open(item) } else { select(item) }
                        }
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
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
                .shadow(color: .black.opacity(model.thumbnails.image(for: item) == nil ? 0 : 0.18), radius: 6, y: 3)
                .background(isSelected ? Color.accentColor.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                }
            Text(item.displayName)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(isSelected ? Color.accentColor : .clear, in: Capsule())
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
