import SwiftUI
import FerryAppModel
import FerryCore

enum ViewMode: String, CaseIterable {
    case list, grid
}

struct ContentView: View {
    let model: Model
    @AppStorage("viewMode") private var viewMode: ViewMode = .list
    @State private var summaryJob: UUID?

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
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
            .toolbar { BrowserToolbar(model: model, viewMode: $viewMode) }
        }
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
        HStack(spacing: 6) {
            Image(systemName: "testtube.2")
            Text("Demo mode — showing a simulated phone. No real device is used.")
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.25))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    let model: Model

    var body: some View {
        List {
            Section("Phones") {
                if model.monitor.devices.isEmpty {
                    Text("No phone connected").foregroundStyle(.secondary)
                }
                ForEach(model.monitor.devices) { device in
                    Button {
                        model.monitor.select(device.id)
                    } label: {
                        Label(name(for: device), systemImage: device.mode == .chargingOnly ? "bolt.fill" : "iphone.gen3")
                    }
                    .buttonStyle(.plain)
                    .fontWeight(device.id == model.monitor.selectedDeviceID ? .semibold : .regular)
                    .accessibilityAddTraits(device.id == model.monitor.selectedDeviceID ? .isSelected : [])
                }
            }
            if model.monitor.state.isReady {
                Section("Storage") {
                    ForEach(model.browser.storages) { storage in
                        Button {
                            model.browser.open(storage: storage)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(storage.displayName, systemImage: storage.isRemovable ? "sdcard" : "internaldrive")
                                if storage.capacityBytes > 0 {
                                    ProgressView(value: ProgressMath.fraction(done: storage.usedBytes, total: storage.capacityBytes))
                                        .controlSize(.small)
                                    Text("\(ByteFormatter.string(storage.freeBytes)) free of \(ByteFormatter.string(storage.capacityBytes))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .fontWeight(storage.id == model.browser.storage?.id ? .semibold : .regular)
                        .accessibilityLabel("\(storage.displayName), \(ByteFormatter.string(storage.freeBytes)) free")
                    }
                }
            }
            Section("Save To") {
                DestinationRow(model: model)
            }
        }
        .listStyle(.sidebar)
    }

    private func name(for device: DiscoveredDevice) -> String {
        if device.id == model.monitor.session?.summary.id, let s = model.monitor.session?.summary { return s.displayName }
        return device.summary.displayName
    }
}

struct DestinationRow: View {
    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url = model.destination.destination {
                Label(url.lastPathComponent, systemImage: model.destination.isAvailable ? "folder" : "exclamationmark.triangle")
                    .help(url.path)
                    .accessibilityLabel("Destination folder \(url.lastPathComponent)")
            } else {
                Text("No folder chosen").foregroundStyle(.secondary)
            }
            Button("Choose…") {
                if let url = FinderBridge.chooseFolder(startingAt: model.destination.destination) {
                    model.destination.choose(url)
                }
            }
            .controlSize(.small)
            .accessibilityLabel("Choose destination folder")
        }
    }
}

// MARK: - Toolbar

struct BrowserToolbar: ToolbarContent {
    let model: Model
    @Binding var viewMode: ViewMode

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.browser.goUp()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!model.browser.canGoUp)
            .help("Enclosing folder (⌘↑)")
        }
        ToolbarItem(placement: .principal) {
            Breadcrumb(model: model)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Show", selection: Binding(get: { model.browser.filter }, set: { model.browser.filter = $0 })) {
                ForEach(FileFilter.allCases) { f in Text(f.title).tag(f) }
            }
            .pickerStyle(.menu)
            .help("Show only some kinds of files")

            Picker("View", selection: $viewMode) {
                Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                Label("Thumbnails", systemImage: "square.grid.2x2").tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help("List or thumbnails")

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

struct Breadcrumb: View {
    let model: Model

    var body: some View {
        HStack(spacing: 2) {
            let parts = model.browser.breadcrumb
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                Button(part) { model.browser.goTo(breadcrumbIndex: index) }
                    .buttonStyle(.plain)
                    .fontWeight(index == parts.count - 1 ? .semibold : .regular)
                    .lineLimit(1)
                    .disabled(index == parts.count - 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Location")
    }
}
