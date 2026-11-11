import SwiftUI
import ZapdropAppModel
import ZapdropCore
import ZapdropMock
#if canImport(ZapdropLibMTP)
import ZapdropLibMTP
#endif

@main
struct ZapdropApp: App {
    @State private var model: Model = ZapdropApp.makeModel()

    var body: some Scene {
        WindowGroup("Zapdrop") {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { model.start() }
                .task { await WindowSnapshot.runIfRequested(model: model) }
                // Copies made for previews and drags don't outlive the app.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.clearCaches()
                }
        }
        .commands { ZapdropCommands(model: model) }

        Settings {
            SettingsView(model: model)
        }

        Window("\(AppInfo.name) Help", id: HelpView.windowID) {
            HelpView()
        }
        .windowResizability(.contentSize)
    }

    /// `--mock` (or ZAPDROP_MOCK=1) runs against a simulated phone — no hardware needed.
    @MainActor
    static func makeModel() -> Model {
        Log.install(OSLogLogger())
        let args = ProcessInfo.processInfo.arguments
        let wantsMock = args.contains("--mock") || ProcessInfo.processInfo.environment["ZAPDROP_MOCK"] == "1"
        #if canImport(ZapdropLibMTP)
        let backend: DeviceBackend = wantsMock ? SamplePhones.backend() : LibMTPBackend()
        let isMock = wantsMock
        #else
        let backend: DeviceBackend = SamplePhones.backend() // built with ZAPDROP_MOCK_ONLY=1
        let isMock = true
        #endif
        return Model(backend: backend, isMock: isMock, store: UserDefaults.standard,
                     inspector: IOKitExclusiveAccessInspector(), phoneReleaser: PhoneReleaser(),
                     cacheRoot: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Zapdrop", isDirectory: true),
                     decodeThumbnail: ThumbnailDecoder.decode)
    }
}

struct ZapdropCommands: Commands {
    let model: Model
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Optional donation link (Scripts/config.sh SUPPORT_URL); hidden when not configured.
        if let support = SupportLink.url {
            CommandGroup(after: .appInfo) {
                Button("Buy Me a Coffee…") { NSWorkspace.shared.open(support) }
            }
        }
        // The built-in guide replaces the standard item, which only says "Help isn't available" without a help book.
        CommandGroup(replacing: .help) {
            Button("\(AppInfo.name) Help") { openWindow(id: HelpView.windowID) }
                .keyboardShortcut("?", modifiers: .command)
            if let support = SupportLink.url {
                Divider()
                Button("Buy Me a Coffee…") { NSWorkspace.shared.open(support) }
            }
        }
        CommandGroup(after: .newItem) {
            Button("Copy to Mac") { model.copySelection() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!model.canCopy)
            Button("Choose Destination…") {
                if let url = FinderBridge.chooseFolder(startingAt: model.destination.destination) {
                    model.destination.choose(url)
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Quick Look") { model.togglePreview() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(!model.preview.isActive && !model.browser.selectedItems.contains { !$0.isFolder })
            Divider()
            Button("Eject Phone") { model.ejectPhone() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!model.canEject)
        }
        // Places to go: on the phone, then on the Mac. (Opening a folder is Return or a double-click; phones are
        // found automatically, so there's nothing to "look for".)
        CommandMenu("Go") {
            let ready = model.monitor.state.isReady
            Button("Back") { model.browser.goUp() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!ready || !model.browser.canGoUp)
            Button("Back to Top") { model.browser.goTo(breadcrumbIndex: 0) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                .disabled(!ready || !model.browser.canGoUp)
            if ready, model.browser.storages.count > 1 {
                Divider()
                ForEach(Array(model.browser.storages.enumerated()), id: \.element.id) { index, storage in
                    // ⌘1…⌘9 for the first nine; a phone may report more storages than there are digits.
                    if index < 9 {
                        Button(storage.displayName) { model.browser.open(storage: storage) }
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    } else {
                        Button(storage.displayName) { model.browser.open(storage: storage) }
                    }
                }
            }
            Divider()
            Button("Save To Folder in Finder") {
                if let folder = model.destination.destination { FinderBridge.open(folder: folder) }
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(model.destination.destination == nil)
            Divider()
            Button("Reload") { model.browser.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!ready)
        }
    }
}
