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
                .navigationSplitViewColumnWidth(min: 240, ideal: 272, max: 340)
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
            .background(GlassBackdrop())
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
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .glassPanel(cornerRadius: 20, tint: .yellow.opacity(0.35))
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    let model: Model

    // A plain scroll view of glass cards rather than a List: List rows dim their text depending on window focus,
    // which fought the cards and made Storage and Save To look disabled.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SidebarSection("Phones") {
                    if model.monitor.devices.isEmpty {
                        Label("No phone connected", systemImage: "cable.connector.slash")
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassPanel(cornerRadius: 14)
                    }
                    ForEach(model.monitor.devices) { device in
                        if device.id == model.monitor.session?.summary.id {
                            PhoneCard(model: model, device: device, name: name(for: device))
                        } else {
                            OtherPhoneRow(model: model, device: device, name: name(for: device))
                        }
                    }
                }
                if model.monitor.state.isReady {
                    SidebarSection("Storage") {
                        ForEach(model.browser.storages) { storage in
                            StorageTile(model: model, storage: storage)
                        }
                    }
                }
                SidebarSection("Save To") {
                    DestinationCard(model: model)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func name(for device: DiscoveredDevice) -> String {
        if device.id == model.monitor.session?.summary.id, let s = model.monitor.session?.summary { return s.displayName }
        return device.summary.displayName
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// A phone that's plugged in but not the one being browsed (or ejected, or only charging).
private struct OtherPhoneRow: View {
    let model: Model
    let device: DiscoveredDevice
    let name: String

    var body: some View {
        let ejected = device.id == model.monitor.ejectedDeviceID
        Button {
            model.monitor.select(device.id)
        } label: {
            Label(name, systemImage: device.mode == .chargingOnly ? "bolt.fill" : ejected ? "eject" : "iphone.gen3")
                .lineLimit(1)
                .foregroundStyle(ejected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassPanel(cornerRadius: 14)
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .help(ejected ? "Ejected — click to connect again" : device.mode == .chargingOnly ? "Only charging" : "Show this phone")
    }
}

private struct StorageTile: View {
    let model: Model
    let storage: StorageInfo

    var body: some View {
        let selected = storage.id == model.browser.storage?.id
        let low = storage.capacityBytes > 0 && storage.freeBytes < storage.capacityBytes / 10
        Button {
            model.browser.open(storage: storage)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: storage.isRemovable ? "sdcard.fill" : "internaldrive.fill")
                        .font(.title3)
                        .foregroundStyle(Brand.gradient)
                        .accessibilityHidden(true)
                    Text(storage.displayName)
                        .fontWeight(selected ? .semibold : .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                if storage.capacityBytes > 0 {
                    ProgressView(value: ProgressMath.fraction(done: storage.usedBytes, total: storage.capacityBytes))
                        .controlSize(.small)
                        .tint(low ? .orange : .teal)
                    Text("\(ByteFormatter.string(storage.freeBytes)) free of \(ByteFormatter.string(storage.capacityBytes))")
                        .font(.caption)
                        .foregroundStyle(low ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: 14, tint: selected ? Color.accentColor.opacity(0.22) : nil)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.65) : .clear, lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(storage.displayName), \(ByteFormatter.string(storage.freeBytes)) free")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The connected phone: name, maker, storage, battery and USB link, with Eject.
/// MTP doesn't report RAM, the Android version or the model year, so those can't be shown.
struct PhoneCard: View {
    let model: Model
    let device: DiscoveredDevice
    let name: String

    var body: some View {
        let totals = model.monitor.storageTotals
        let lowSpace = totals.capacity > 0 && totals.free < totals.capacity / 10
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.gradient)
                    Image(systemName: "iphone.gen3").font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.headline).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.85)
                    if let maker = model.monitor.session?.summary.manufacturer.map(DisplayText.clean), !maker.isEmpty {
                        Text(maker).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    model.ejectPhone()
                } label: {
                    Image(systemName: "eject.fill")
                }
                .buttonStyle(.borderless)
                .disabled(!model.canEject)
                .help(model.canEject ? "Eject — then it's safe to unplug the phone (⌘E)"
                                     : "Can't eject while copying. Wait for the copy to finish or cancel it.")
                .accessibilityLabel("Eject \(name)")
            }
            if totals.capacity > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: ProgressMath.fraction(done: totals.capacity - totals.free, total: totals.capacity))
                        .tint(lowSpace ? .orange : .teal)
                    Text("\(ByteFormatter.string(totals.free)) free of \(ByteFormatter.string(totals.capacity))")
                        .font(.caption)
                        .foregroundStyle(lowSpace ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            }
            HStack(spacing: 14) {
                if let percent = model.monitor.batteryPercent {
                    HStack(spacing: 6) {
                        BatteryRing(percent: percent)
                        Text("Battery").font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Battery \(percent) percent")
                }
                if let speed = device.usbSpeed {
                    Label(speed.shortName, systemImage: speed.isSlow ? "exclamationmark.triangle.fill" : "bolt.horizontal.fill")
                        .font(.caption)
                        .foregroundStyle(speed.isSlow ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .help(speed.isSlow
                              ? "\(speed.displayName): copies are limited to about 40 MB/s. Plug the phone straight into the Mac with a USB 3 cable (not through a hub or adapter) for faster copies."
                              : "\(speed.displayName)")
                }
            }
        }
        .padding(12)
        .glassPanel(cornerRadius: 16)
    }
}

/// A small circular battery gauge, green to red.
struct BatteryRing: View {
    let percent: Int

    var body: some View {
        let color: Color = percent <= 15 ? .red : percent <= 35 ? .orange : .green
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, percent))) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(percent)").font(.system(size: 8, weight: .bold)).monospacedDigit()
        }
        .frame(width: 24, height: 24)
    }
}

/// Where copies go: the folder's own Finder icon, its name and location, and buttons to change or show it.
struct DestinationCard: View {
    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = model.destination.destination {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent).fontWeight(.medium).foregroundStyle(.primary).lineLimit(1)
                        Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .help(url.path)
                if !model.destination.isAvailable {
                    Label("Not available — is the disk connected?", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Label("Choose a folder on your Mac", systemImage: "folder.badge.plus")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button(model.destination.destination == nil ? "Choose…" : "Change…") {
                    if let url = FinderBridge.chooseFolder(startingAt: model.destination.destination) {
                        model.destination.choose(url)
                    }
                }
                .accessibilityLabel("Choose destination folder")
                if let url = model.destination.destination, model.destination.isAvailable {
                    Button("Show in Finder") { FinderBridge.reveal(url) }
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 14)
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

/// Where you are on the phone. Long paths keep the first and last two places and fold the rest into "…".
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
                    Image(systemName: "chevron.compact.right").font(.callout).foregroundStyle(.tertiary)
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
        .padding(.horizontal, 6)
        .frame(maxWidth: 460)
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
                    Image(systemName: model.browser.storage?.isRemovable == true ? "sdcard.fill" : "internaldrive.fill")
                        .foregroundStyle(Brand.gradient)
                } else if index - 1 < model.browser.path.count {
                    Image(nsImage: FileIcons.image(for: model.browser.path[index - 1]))
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(parts[index])
                    .fontWeight(isCurrent ? .semibold : .regular)
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
