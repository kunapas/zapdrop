import SwiftUI
import FerryAppModel
import FerryCore

// MARK: - Device status / connection help

struct DeviceStatusView: View {
    let model: Model

    var body: some View {
        let content = Self.content(for: model.monitor.state)
        VStack(spacing: 16) {
            Image(systemName: content.symbol)
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(content.title).font(.title2).fontWeight(.semibold)
            if !content.message.isEmpty {
                Text(content.message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if !content.steps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(content.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(step)
                        }
                    }
                }
                .frame(maxWidth: 440, alignment: .leading)
                .padding(14)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                if isBusy && model.canReleaseCameraDaemon {
                    Button("Release Phone from macOS Camera Service") { model.releaseCameraDaemon() }
                        .help("Ends macOS's ptpcamerad for your user account so Ferry can connect. macOS starts it again when needed.")
                }
                if model.monitor.state != .noDevice {
                    Button("Try Again") { model.monitor.retryNow() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(32)
        .accessibilityElement(children: .contain)
    }

    private var isBusy: Bool {
        if case .busy = model.monitor.state { return true }
        return false
    }

    struct Content {
        var symbol: String
        var title: String
        var message: String
        var steps: [String]
    }

    static func content(for state: DeviceConnectionState) -> Content {
        switch state {
        case .noDevice:
            return Content(symbol: "cable.connector", title: "Connect your Android phone",
                           message: "Ferry works over USB. Nothing is sent to the internet.",
                           steps: ["Connect the phone with a USB cable that supports data.",
                                   "Unlock the phone.",
                                   "Swipe down from the top and tap the USB notification.",
                                   "Choose \"File transfer\" (also called \"File Transfer / Android Auto\" or MTP)."])
        case .chargingOnly(let d):
            let e = ErrorMapper.map(FerryError.chargingOnlyMode)
            return Content(symbol: "bolt.batteryblock", title: "\(d.displayName) is only charging", message: e.message, steps: e.suggestions)
        case .awaitingAuthorization(let d):
            let e = ErrorMapper.map(FerryError.notAuthorized)
            return Content(symbol: "hand.raised", title: "Waiting for \(d.displayName)", message: e.message, steps: e.suggestions)
        case .locked(let d):
            let e = ErrorMapper.map(FerryError.deviceLocked)
            return Content(symbol: "lock.iphone", title: "Unlock \(d.displayName)", message: e.message, steps: e.suggestions)
        case .busy(_, let holder):
            let e = ErrorMapper.map(FerryError.deviceBusy(holder: holder))
            return Content(symbol: "exclamationmark.lock", title: e.title, message: e.message, steps: e.suggestions)
        case .unsupported(let d, _):
            let e = ErrorMapper.map(FerryError.unsupportedDevice(detail: ""))
            return Content(symbol: "questionmark.diamond", title: "\(d.displayName) isn't responding normally",
                           message: e.message, steps: e.suggestions)
        case .disconnected(let d):
            return Content(symbol: "cable.connector.slash", title: "\(d.displayName) was disconnected",
                           message: "Files already copied are safe. Unfinished files were removed and can be retried.",
                           steps: ["Reconnect the cable and unlock the phone.",
                                   "Make sure the USB mode is still \"File transfer\"."])
        case .ready(let d):
            return Content(symbol: "checkmark.circle", title: "\(d.displayName) is ready", message: "", steps: [])
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
                VStack(spacing: 10) {
                    ForEach(model.transfers.rows) { row in
                        TransferRowView(model: model, row: row, summaryJob: $summaryJob)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(.background)
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
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
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
            Button("Show in Finder") { FinderBridge.reveal(row.destination) }.controlSize(.small)
        }
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
        }
        .padding(20)
    }
}

struct AboutSettings: View {
    let isMock: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ferry").font(.title2).fontWeight(.semibold)
            Text("Free and open source (MIT). Uses libmtp and libusb (LGPL-2.1-or-later), bundled unmodified as separate libraries.")
            Text("Privacy").font(.headline)
            Text("Ferry works entirely on your Mac. It makes no network requests, has no accounts, analytics or telemetry, and never uploads file names, metadata or contents. Diagnostic logs stay on your Mac and hide file names.")
            if isMock { Text("Running in demo mode with a simulated phone.").foregroundStyle(.orange) }
            Spacer()
        }
        .padding(20)
    }
}
