import SwiftUI
import FerryAppModel
import FerryCore
import FerryMock
#if canImport(FerryLibMTP)
import FerryLibMTP
#endif

@main
struct FerryApp: App {
    @State private var model: Model = FerryApp.makeModel()

    var body: some Scene {
        WindowGroup("Zapdrop") {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { model.start() }
        }
        .commands { FerryCommands(model: model) }

        Settings {
            SettingsView(model: model)
        }
    }

    /// `--mock` (or FERRY_MOCK=1) runs against a simulated phone — no hardware needed.
    @MainActor
    static func makeModel() -> Model {
        Log.install(OSLogLogger())
        let args = ProcessInfo.processInfo.arguments
        let wantsMock = args.contains("--mock") || ProcessInfo.processInfo.environment["FERRY_MOCK"] == "1"
        #if canImport(FerryLibMTP)
        let backend: DeviceBackend = wantsMock ? SamplePhones.backend() : LibMTPBackend()
        let isMock = wantsMock
        #else
        let backend: DeviceBackend = SamplePhones.backend() // built with FERRY_MOCK_ONLY=1
        let isMock = true
        #endif
        return Model(backend: backend, isMock: isMock, store: UserDefaults.standard,
                     inspector: IOKitExclusiveAccessInspector(), cameraDaemon: CameraDaemonReleaser(),
                     cacheRoot: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Zapdrop", isDirectory: true),
                     decodeThumbnail: ThumbnailDecoder.decode)
    }
}

struct FerryCommands: Commands {
    let model: Model

    var body: some Commands {
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
        CommandMenu("Go") {
            Button("Enclosing Folder") { model.browser.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!model.browser.canGoUp)
            Button("Open Selected Folder") {
                if let item = model.browser.selectedItems.first, item.isFolder { model.browser.open(item) }
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Button("Reload") { model.browser.reload() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Look for Phone Again") { model.monitor.retryNow() }
        }
    }
}
