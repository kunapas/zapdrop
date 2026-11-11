import SwiftUI
import ZapdropAppModel
import ZapdropCore

enum ViewMode: String, CaseIterable {
    case list, grid
}

struct ContentView: View {
    let model: Model
    @AppStorage("viewMode") private var viewMode: ViewMode = .list
    @State private var summaryJob: UUID?

    // One page, no sidebar: the welcome page until a phone is ready, then the phone's cards with its files below.
    var body: some View {
        VStack(spacing: 0) {
            if model.isMock {
                MockBanner()
            }
            if model.monitor.state.isReady {
                BrowserContainer(model: model, viewMode: viewMode)
            } else {
                DeviceStatusView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !model.transfers.rows.isEmpty {
                Divider()
                TransferPanel(model: model, summaryJob: $summaryJob)
                    .frame(maxHeight: 260)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // The standard window title: the folder being shown, like Finder.
        .navigationTitle(model.monitor.state.isReady ? (model.browser.breadcrumb.last ?? AppInfo.name) : AppInfo.name)
        .toolbar { if model.monitor.state.isReady { BrowserToolbar(model: model, viewMode: $viewMode) } }
        .sheet(item: duplicateBinding) { prompt in
            DuplicateSheet(prompt: prompt) { decision in model.transfers.answerPrompt(decision) }
                .interactiveDismissDisabled()
        }
        .sheet(item: summaryBinding) { job in
            TransferSummaryView(model: model, jobID: job.id) { summaryJob = nil }
        }
        .alert(model.notice?.title ?? "", isPresented: noticeBinding, presenting: model.notice) { _ in
            Button("OK") { model.notice = nil }
        } message: { notice in
            Text(([notice.message] + notice.suggestions).joined(separator: "\n"))
        }
    }

    private var duplicateBinding: Binding<DuplicatePrompt?> {
        Binding(get: { model.transfers.duplicatePrompt }, set: { _ in })
    }

    private var summaryBinding: Binding<JobID?> {
        Binding(get: { summaryJob.map(JobID.init) }, set: { summaryJob = $0?.id })
    }

    private var noticeBinding: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }
}

struct JobID: Identifiable {
    let id: UUID
}

struct MockBanner: View {
    var body: some View {
        VStack(spacing: 0) {
            Label("Demo mode: showing a simulated phone. No real device is used.", systemImage: "testtube.2")
                .font(.callout)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.yellow.opacity(0.18))
            Divider()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Toolbar

struct BrowserToolbar: ToolbarContent {
    let model: Model
    @Binding var viewMode: ViewMode

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.browser.goUp()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!model.browser.canGoUp)
            .help("Back (⌘[)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                let urls = FinderBridge.chooseItemsToSend()
                if !urls.isEmpty { model.copyToPhone(urls) }
            } label: {
                Label("Copy to Phone", systemImage: "square.and.arrow.up")
            }
            .disabled(!model.canCopyToPhone)
            .help("Copy files or folders from your Mac into this folder on the phone. You can also drag them in from Finder.")

            Picker("View", selection: $viewMode) {
                Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                Label("Icons", systemImage: "square.grid.2x2").tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help("Show items as a list or as icons")

            Picker("Show", selection: Binding(get: { model.browser.filter }, set: { model.browser.filter = $0 })) {
                ForEach(FileFilter.allCases) { f in Text(f.title).tag(f) }
            }
            .pickerStyle(.menu)
            .help("Show only some kinds of files")

            Button {
                if model.destination.destination == nil,
                   let url = FinderBridge.chooseFolder(startingAt: nil) {
                    model.destination.choose(url)
                }
                model.copySelection()
            } label: {
                Label("Copy to Mac", systemImage: "square.and.arrow.down")
            }
            .disabled(!model.canCopy)
            .help("Copy the selected items to \(model.destination.destination?.lastPathComponent ?? "a folder on your Mac") (⇧⌘C)")
        }
    }
}

/// Where you are on the phone, as a path bar along the bottom of the window (Finder's "Show Path Bar"). Long paths
/// keep the first and last two places and fold the rest into "…".
struct Breadcrumb: View {
    let model: Model

    private enum Crumb: Hashable {
        case place(Int)
        case folded([Int])
    }

    var body: some View {
        let parts = model.browser.breadcrumb
        let crumbs: [Crumb] = parts.count > 4
            ? [.place(0), .folded(Array(1..<(parts.count - 2))), .place(parts.count - 2), .place(parts.count - 1)]
            : parts.indices.map(Crumb.place)
        HStack(spacing: 5) {
            ForEach(Array(crumbs.enumerated()), id: \.element) { position, crumb in
                if position > 0 {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                switch crumb {
                case .place(let index):
                    place(index, parts: parts)
                case .folded(let indices):
                    Menu {
                        ForEach(indices, id: \.self) { i in
                            Button(parts[i]) { model.browser.goTo(breadcrumbIndex: i) }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.caption.weight(.semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(indices.map { parts[$0] }.joined(separator: " › "))
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Location")
    }

    @ViewBuilder
    private func place(_ index: Int, parts: [String]) -> some View {
        let isCurrent = index == parts.count - 1
        Button {
            model.browser.goTo(breadcrumbIndex: index)
        } label: {
            HStack(spacing: 5) {
                if index == 0 {
                    Image(systemName: model.browser.storage?.isRemovable == true ? "sdcard" : "internaldrive")
                        .foregroundStyle(.secondary)
                } else if index - 1 < model.browser.path.count {
                    Image(nsImage: FileIcons.image(for: model.browser.path[index - 1]))
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(parts[index])
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: isCurrent ? 200 : 130, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .help(parts[index])
    }
}
