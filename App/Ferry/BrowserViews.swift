import AppKit
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
                if model.browser.isLoading {
                    ProgressView("Reading folder…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                } else if let error = model.browser.error {
                    ContentUnavailableView {
                        Label(error.title, systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(([error.message] + error.suggestions).joined(separator: "\n"))
                    } actions: {
                        Button("Try Again") { model.browser.reload() }
                    }
                } else if model.browser.items.isEmpty {
                    ContentUnavailableView(model.browser.searchText.isEmpty ? "Empty Folder" : "No Matches",
                                           systemImage: "folder")
                }
            }
            Divider()
            HStack {
                Text(model.browser.statusText)
                Spacer()
                if let dest = model.destination.destination {
                    Text("Saving to \(dest.lastPathComponent)").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .accessibilityElement(children: .combine)
        }
        .searchable(text: Binding(get: { model.browser.searchText }, set: { model.browser.searchText = $0 }),
                    placement: .toolbar, prompt: "Search this folder")
    }
}

// MARK: - List

struct FileTable: View {
    let model: Model
    @Bindable var browser: DirectoryBrowserViewModel
    @State private var sortOrder = [KeyPathComparator(\RemoteItem.name)]

    var body: some View {
        Table(browser.items, selection: $browser.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 8) {
                    ThumbnailView(model: model, item: item, size: 22)
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
        }
        .contextMenu(forSelectionType: ObjectID.self) { ids in
            if !ids.isEmpty {
                Button("Copy to Mac") { model.copySelection(items(ids)) }
                if ids.count == 1, let item = items(ids).first, item.isFolder {
                    Button("Open") { browser.open(item) }
                }
            }
        } primaryAction: { ids in
            if ids.count == 1, let item = items(ids).first, item.isFolder { browser.open(item) }
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
    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(browser.items) { item in
                    GridCell(model: model, item: item, isSelected: browser.selection.contains(item.id))
                        .onTapGesture(count: 2) { if item.isFolder { browser.open(item) } }
                        .onTapGesture { select(item) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(named: item.isFolder ? "Open" : "Select") {
                            if item.isFolder { browser.open(item) } else { select(item) }
                        }
                }
            }
            .padding(14)
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
        VStack(spacing: 6) {
            ThumbnailView(model: model, item: item, size: 104)
                .frame(width: 112, height: 112)
                .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
            Text(item.displayName)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
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
                    .clipShape(RoundedRectangle(cornerRadius: size > 40 ? 6 : 3))
            } else {
                Image(systemName: item.kind.symbolName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size > 40 ? size * 0.22 : 2)
                    .foregroundStyle(item.isFolder ? Color.accentColor : Color.secondary)
            }
        }
        .frame(width: size, height: size)
        .onAppear { model.thumbnails.request(item) }
        .onDisappear { model.thumbnails.cancel(item) }
        .accessibilityHidden(true)
    }
}
