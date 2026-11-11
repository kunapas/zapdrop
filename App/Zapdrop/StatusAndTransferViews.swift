import SwiftUI
import ZapdropAppModel
import ZapdropCore

// MARK: - Device status / connection help

struct DeviceStatusView: View {
    let model: Model

    var body: some View {
        let content = model.isFreeingPhone && model.monitor.isBusy
            ? Self.connecting
            : Self.content(for: model.monitor.state)
        // Scrolls only when the window is too short for the page.
        ViewThatFits(in: .vertical) {
            page(content)
            ScrollView { page(content) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .task(id: model.monitor.state) {
            if case .busy = model.monitor.state { await model.refreshCompetingApps() }
        }
    }

    /// Every state shares the welcome page: the app, what it does, then a panel for what's happening with the phone
    /// right now (nothing plugged in, only charging, locked, unplugged…) and what to do about it.
    private func page(_ content: Content) -> some View {
        VStack(spacing: 22) {
            hero
            VStack(spacing: 8) {
                Text("Welcome to \(AppInfo.name)")
                    .font(.system(size: 30, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(AppInfo.tagline)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 16) {
                feature("folder.fill", .blue, "Browse your phone like a folder",
                        "Photos, videos, music and documents, in a list or as thumbnails.")
                feature("arrow.left.arrow.right", .green, "Copy both ways, safely",
                        "From phone to Mac and back. Nothing is ever overwritten or deleted on your phone.")
                feature("eye.fill", .purple, "Look before you copy",
                        "Press Space to preview a file, or drag it straight into Finder.")
                feature("cursorarrow.click.2", .orange, "One-click copy to your folder",
                        "Pick a folder on your Mac once. After that, right-click anything and choose Copy to Mac.")
            }
            .frame(maxWidth: 440, alignment: .leading)
            // What's happening with the phone: the heading sits on an accent-coloured ribbon so it catches the eye;
            // the steps underneath stay on a quiet panel.
            VStack(alignment: .leading, spacing: 0) {
                Label(content.title, systemImage: content.symbol)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor)
                if !content.steps.isEmpty || !content.message.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(content.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(Color.accentColor, in: Circle())
                                Text(step).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if !content.message.isEmpty {
                            Text(content.message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: 476)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            action(content.action)
            if let waiting = content.waiting {
                // Zapdrop checks the phone every second or two by itself, so there's nothing to press.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(waiting).foregroundStyle(.secondary)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(36)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
    }

    /// The app's icon heads every page shown while no phone is being browsed.
    private var hero: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 128, height: 128)
            .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
            .accessibilityHidden(true)
    }

    private func feature(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: symbol, color: color, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func action(_ action: Content.Action) -> some View {
        switch action {
        case .none:
            EmptyView()
        case .freeUpPhone:
            VStack(spacing: 10) {
                if !model.competingApps.isEmpty {
                    Text("Zapdrop will quit \(ListFormatter.localizedString(byJoining: model.competingApps)) "
                         + "and release the macOS camera service.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button {
                    model.freeUpPhone()
                } label: {
                    HStack(spacing: 8) {
                        if model.isFreeingPhone { ProgressView().controlSize(.small) }
                        Text(model.isFreeingPhone ? "Freeing Up Phone…" : "Free Up Phone & Connect")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isFreeingPhone || !model.canFreePhone)
                .help("Quits other apps that use phones and ends macOS's camera service (ptpcamerad) for your account. "
                      + "macOS starts that service again when it needs it.")
                if !model.competingApps.isEmpty {
                    Toggle("Always do this automatically", isOn: Binding(get: { model.settings.autoQuitPhoneApps },
                                                                      set: { model.settings.autoQuitPhoneApps = $0 }))
                        .toggleStyle(.checkbox)
                        .help("Next time, quit these apps and connect without asking. You can change this in Settings.")
                }
                if model.freeingPhoneFailed {
                    Text("Still blocked. Unplug the phone, plug it back in, then try once more.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        case .connect:
            Button("Connect") { model.monitor.connectEjected() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        case .tryAgain:
            Button("Try Again") { model.monitor.retryNow() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }

    struct Content {
        enum Action { case none, freeUpPhone, connect, tryAgain }
        var symbol: String
        var title: String
        var message: String
        var steps: [String] = []
        var action: Action = .none
        /// Shown with a spinner where Zapdrop carries on by itself once the phone is ready.
        var waiting: String? = nil
    }

    /// While Zapdrop takes the phone back from another program (usually the macOS camera service).
    static var connecting: Content {
        Content(symbol: "cable.connector", title: "Connecting to your phone…",
                message: "Taking the phone back from the app that grabbed it.",
                waiting: "Connecting…")
    }

    static func content(for state: DeviceConnectionState) -> Content {
        switch state {
        case .noDevice:
            return Content(symbol: "cable.connector", title: "Connect your Android phone",
                           message: "Use a USB cable that carries data. The one that came with your phone is best.",
                           steps: ["Plug the phone into your Mac and unlock it.",
                                   "On the phone, swipe down, tap the USB notification and choose \u{201C}File Transfer / Android Auto\u{201D} (or \u{201C}MTP\u{201D}, or a similar option)."],
                           waiting: "Looking for your phone…")
        case .chargingOnly(let d):
            return Content(symbol: "bolt.batteryblock", title: "Turn on file transfer",
                           message: "\(d.displayName) is plugged in, but it's only charging.",
                           steps: ["On the phone, swipe down from the top and tap the USB notification "
                                   + "(\u{201C}Charging this device via USB\u{201D}).",
                                   "Choose \u{201C}File Transfer / Android Auto\u{201D} (or \u{201C}MTP\u{201D}, or a similar option).",
                                   "No notification? Open Settings \u{203A} Connected devices \u{203A} USB."],
                           waiting: "Waiting for file transfer…")
        case .awaitingAuthorization(let d), .locked(let d):
            return Content(symbol: "lock.iphone", title: "Allow access to your files",
                           message: "\(d.displayName) is connected. Android keeps your photos and files private "
                                + "until you unlock the phone and allow access.",
                           steps: ["Unlock your phone.",
                                   "If the phone asks \u{201C}Allow access to phone data?\u{201D}, tap Allow.",
                                   "No question? Swipe down, tap the USB notification and choose \u{201C}File Transfer / Android Auto\u{201D} (or \u{201C}MTP\u{201D}, or a similar option)."],
                           waiting: "Waiting for your phone…")
        case .busy(_, let holder):
            // The model name isn't known until Zapdrop can talk to the phone, so say "your phone".
            let who = holder.map { "Right now it's \($0)." } ?? "Another app on your Mac has it right now."
            return Content(symbol: "exclamationmark.lock", title: "Another app is using your phone",
                           message: "Only one app can use a phone over USB at a time. \(who)",
                           action: .freeUpPhone)
        case .unsupported(let d, _):
            return Content(symbol: "questionmark.diamond", title: "\(d.displayName) isn't responding",
                           message: "The phone connected, but didn't answer the way Zapdrop expects.",
                           steps: ["Unplug the phone, restart it, and plug it in again.",
                                   "Try a different cable or USB port, plugged straight into the Mac."],
                           action: .tryAgain)
        case .disconnected(let d):
            return Content(symbol: "cable.connector.slash", title: "\(d.displayName) disconnected",
                           message: "Files that finished copying are safe on your Mac. A file that was only partly "
                                + "copied was removed, so nothing is left half-done.",
                           steps: ["Plug the phone back in and unlock it. Zapdrop reconnects on its own.",
                                   "If a copy was interrupted, click Retry Failed in the transfer list to finish it."],
                           waiting: "Waiting for your phone…")
        case .ejected(let d):
            return Content(symbol: "eject.circle", title: "\(d.displayName) was ejected",
                           message: "It's safe to unplug the phone now, and other apps can use it.",
                           action: .connect)
        case .ready(let d):
            return Content(symbol: "checkmark.circle", title: "\(d.displayName) is ready", message: "")
        }
    }
}

// MARK: - Transfer panel

struct TransferPanel: View {
    let model: Model
    @Binding var summaryJob: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear Finished") { model.transfers.clearFinished() }
                    .controlSize(.small)
                    .disabled(!model.transfers.rows.contains { $0.snapshot.phase.isFinished })
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.transfers.rows) { row in
                        Divider()
                        TransferRowView(model: model, row: row, summaryJob: $summaryJob)
                    }
                }
            }
        }
        .background(.bar)
    }
}

struct TransferRowView: View {
    let model: Model
    let row: TransferRow
    @Binding var summaryJob: UUID?

    var body: some View {
        let s = row.snapshot
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon(s.phase)).foregroundStyle(color(s.phase)).accessibilityHidden(true)
                Text(row.title).fontWeight(.medium).lineLimit(1)
                Text("→ \(row.destination.lastPathComponent)").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                buttons(s)
            }
            if s.phase.isActive || s.phase == .queued {
                ProgressView(value: s.fraction)
                    .accessibilityLabel("Copying \(row.title)")
                    .accessibilityValue("\(Int(s.fraction * 100)) percent")
            }
            Text(detail(s)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if s.phase == .completed, s.completedFiles > 0 {
                // The point of copying first: now the phone's copies can go.
                Label("Safely on your Mac. You can delete \(s.completedFiles == 1 ? "it" : "these") on your phone to free "
                      + "\(ByteFormatter.string(s.transferredBytes)).", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func buttons(_ s: TransferSnapshot) -> some View {
        if s.phase.isActive || s.phase == .queued {
            Button("Cancel") { model.transfers.cancel(row.id) }
                .controlSize(.small)
                .accessibilityLabel("Cancel copying \(row.title)")
        } else {
            if model.transfers.canRetry(row.id) {
                Button("Retry Failed") { model.retry(row.id) }.controlSize(.small)
            }
            Button("Details") { summaryJob = row.id }.controlSize(.small)
            Button("Show in Finder") { FinderBridge.show(copiedItems(), in: row.destination) }.controlSize(.small)
        }
    }

    /// The top-level files and folders this job put in the destination (under their saved names), to select in Finder.
    private func copiedItems() -> [URL] {
        var names: [String] = []
        for item in model.transfers.items(for: row.id) {
            guard case .completed(let savedAs, _) = item.status else { continue }
            let top = item.entry.directory.first ?? savedAs ?? item.entry.name
            if !names.contains(top) { names.append(top) }
        }
        return names.map { row.destination.appendingPathComponent($0) }
    }

    private func detail(_ s: TransferSnapshot) -> String {
        switch s.phase {
        case .queued:
            return "Waiting…"
        case .preparing(let n):
            return "Preparing — found \(n) item\(n == 1 ? "" : "s")…"
        case .running:
            var parts = ["\(ByteFormatter.string(s.processedBytes)) of \(ByteFormatter.string(s.totalBytes))",
                         "\(s.completedFiles + s.skippedFiles) of \(s.totalFiles) files"]
            if s.bytesPerSecond > 0 { parts.append(ByteFormatter.rate(s.bytesPerSecond)) }
            parts.append(ByteFormatter.duration(s.secondsRemaining))
            if let name = s.currentFileName { parts.append(DisplayText.clean(name)) }
            return parts.joined(separator: " · ")
        case .completed:
            var text = "Copied \(s.completedFiles) file\(s.completedFiles == 1 ? "" : "s") (\(ByteFormatter.string(s.transferredBytes)))"
            if s.skippedFiles > 0 { text += ", skipped \(s.skippedFiles) already on your Mac" }
            return text
        case .partiallyCompleted:
            var text = "Copied \(s.completedFiles), failed \(s.failedFiles)"
            if s.cancelledFiles > 0 { text += ", not copied \(s.cancelledFiles)" }
            if let e = s.lastError { text += " — \(ErrorMapper.map(e).title)" }
            return text
        case .failed(let e):
            let u = ErrorMapper.map(e)
            return "\(u.title). \(u.message)"
        case .cancelled:
            return "Cancelled — \(s.completedFiles) file\(s.completedFiles == 1 ? "" : "s") copied before cancelling were kept."
        }
    }

    private func icon(_ p: TransferPhase) -> String {
        switch p {
        case .queued: return "clock"
        case .preparing, .running: return "arrow.down.circle"
        case .completed: return "checkmark.circle.fill"
        case .partiallyCompleted: return "exclamationmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle"
        }
    }

    private func color(_ p: TransferPhase) -> Color {
        switch p {
        case .completed: return .green
        case .partiallyCompleted: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }
}

// MARK: - Summary

struct TransferSummaryView: View {
    let model: Model
    let jobID: UUID
    let close: () -> Void

    var body: some View {
        let summary = model.transfers.summary(for: jobID)
        VStack(alignment: .leading, spacing: 12) {
            Text("Transfer Summary").font(.title2).fontWeight(.semibold)
            if let summary {
                HStack(spacing: 18) {
                    stat("Copied", summary.copied.count, .green)
                    stat("Renamed", summary.renamed.count, .blue)
                    stat("Skipped", summary.skipped.count, .secondary)
                    stat("Failed", summary.failed.count, .red)
                    stat("Not copied", summary.cancelled.count, .orange)
                }
                List {
                    section("Failed", summary.failed)
                    section("Not copied", summary.cancelled)
                    section("Skipped (already on your Mac)", summary.skipped)
                    section("Saved under a different name", summary.renamed)
                }
                .frame(minHeight: 240)
            }
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }

    private func stat(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack {
            Text("\(value)").font(.title3).fontWeight(.semibold).foregroundStyle(color).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [ItemState]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items.prefix(500)) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.entry.relativePath).lineLimit(1).truncationMode(.middle)
                        if let reason = reason(item.status) {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if items.count > 500 { Text("…and \(items.count - 500) more").foregroundStyle(.secondary) }
            }
        }
    }

    private func reason(_ status: ItemStatus) -> String? {
        switch status {
        case .failed(let e): let u = ErrorMapper.map(e); return "\(u.title): \(u.message)"
        case .cancelled, .pending, .active: return "Stopped before this item was copied."
        case .skipped: return "A file with this name already exists in the destination."
        case .completed(let savedAs, let verified):
            var parts: [String] = []
            if let savedAs { parts.append("Saved as \"\(savedAs)\"") }
            if verified { parts.append("verified") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }
}

// MARK: - Duplicate prompt

struct DuplicateSheet: View {
    let prompt: DuplicatePrompt
    let answer: (DuplicateDecision?) -> Void
    @State private var applyToAll = false

    var body: some View {
        let c = prompt.conflict
        VStack(alignment: .leading, spacing: 14) {
            Text("\"\(DisplayText.clean(c.fileName))\" already exists").font(.title3).fontWeight(.semibold)
            Text("A file with this name is already in \(c.destination.deletingLastPathComponent().lastPathComponent).")
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Size").foregroundStyle(.secondary)
                    Text("Modified").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("On your Mac")
                    Text(c.existingSize.map(ByteFormatter.string) ?? "—")
                    Text(c.existingModified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                }
                GridRow {
                    Text("From the phone")
                    Text(c.incomingSize.map(ByteFormatter.string) ?? "—")
                    Text(c.incomingModified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                }
            }
            if c.remainingFiles > 0 {
                Toggle("Do this for all remaining duplicates", isOn: $applyToAll)
            }
            HStack {
                Button("Stop Transfer", role: .cancel) { answer(nil) }
                Spacer()
                Button("Skip") { answer(DuplicateDecision(.skip, applyToAll: applyToAll)) }
                Button("Keep Both") { answer(DuplicateDecision(.keepBoth, applyToAll: applyToAll)) }
                    .keyboardShortcut(.defaultAction)
                Button("Replace") { answer(DuplicateDecision(.replace, applyToAll: applyToAll)) }
            }
        }
        .padding(22)
        .frame(width: 500)
    }
}

// MARK: - Settings

struct SettingsView: View {
    let model: Model

    var body: some View {
        TabView {
            GeneralSettings(settings: model.settings, model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutSettings(isMock: model.isMock)
                .tabItem { Label("About & Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 520, height: 360)
    }
}

struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    let model: Model

    var body: some View {
        Form {
            Picker("When a file already exists", selection: $settings.defaultDuplicateAction) {
                Text("Ask me").tag(DuplicateAction?.none)
                Text("Keep both").tag(DuplicateAction?.some(.keepBoth))
                Text("Skip").tag(DuplicateAction?.some(.skip))
                Text("Replace").tag(DuplicateAction?.some(.replace))
            }
            Toggle("Keep original modification dates", isOn: $settings.preserveDates)
            Toggle("Verify each file after copying", isOn: $settings.verifyAfterCopy)
            Text("Re-reads every saved file and compares it with the data received over USB. Slower. Android doesn't provide checksums, so this confirms your Mac's copy is intact — not that the phone's copy was.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Show hidden files", isOn: Binding(get: { settings.showHiddenFiles }, set: { model.setShowHiddenFiles($0) }))
            Section("When another app has the phone") {
                Toggle("Take it back from the macOS camera service automatically", isOn: $settings.autoReleaseCameraService)
                    .help("macOS's camera service (ptpcamerad) grabs phones as soon as they're plugged in. Releasing it loses nothing.")
                Toggle("Also quit phone apps automatically (Photos, Image Capture, Android File Transfer…)",
                       isOn: $settings.autoQuitPhoneApps)
            }
        }
        .padding(20)
    }
}

struct AboutSettings: View {
    let isMock: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppInfo.name).font(.title2).fontWeight(.semibold)
            Text(AppInfo.tagline).foregroundStyle(.secondary)
            Text("Free and open source (MIT). Uses libmtp and libusb (LGPL-2.1-or-later), bundled unmodified as separate libraries.")
            Text("Privacy").font(.headline)
            Text("Zapdrop works entirely on your Mac. It makes no network requests, has no accounts, analytics or telemetry, and never uploads file names, metadata or contents. Diagnostic logs stay on your Mac and hide file names.")
            if isMock { Text("Running in demo mode with a simulated phone.").foregroundStyle(.orange) }
            if let support = SupportLink.url {
                Text("Enjoying Zapdrop? It's free and made in spare time.").padding(.top, 4)
                Button("Buy Me a Coffee…") { NSWorkspace.shared.open(support) }
            }
            Spacer()
        }
        .padding(20)
    }
}
