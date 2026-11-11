import SwiftUI

/// Help ▸ Zapdrop Help. A short built-in guide, so help works offline and without a help book.
struct HelpView: View {
    static let windowID = "help"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(AppInfo.name) Help").font(.title.weight(.bold))
                        Text(AppInfo.tagline).foregroundStyle(.secondary)
                    }
                }

                HelpSection("Connect your phone", systemImage: "cable.connector") {
                    HelpStep(1, "Unlock your phone and plug it into your Mac with a USB cable that carries data (some cables only charge).")
                    HelpStep(2, "On the phone, swipe down, tap the USB notification and choose \u{201C}File Transfer / Android Auto\u{201D} (or \u{201C}MTP\u{201D}, or a similar option).")
                    HelpStep(3, "If the phone asks whether to allow access to its files, tap Allow. \(AppInfo.name) opens the phone by itself; there's nothing to click.")
                }

                HelpSection("If another app has your phone", systemImage: "exclamationmark.triangle") {
                    Text("Only one app can talk to a phone at a time. macOS's camera service, Photos, Image Capture and Android File Transfer often grab it first. Click Free Up Phone & Connect and \(AppInfo.name) takes it back.")
                    Text("To do this without asking, open \(AppInfo.name) ▸ Settings… and look under \u{201C}When another app has the phone\u{201D}.")
                        .foregroundStyle(.secondary)
                }

                HelpSection("Copy files to your Mac", systemImage: "square.and.arrow.down") {
                    Text("Select files or folders, then click Copy to Mac, or drag them straight into a Finder window. Copies go to the Save To folder in the sidebar; click it to choose another.")
                    Text("Files arrive under a temporary name and are renamed only once they're complete, so you never get a half-copied file. Nothing on the phone is changed or deleted.")
                        .foregroundStyle(.secondary)
                }

                HelpSection("Before you unplug", systemImage: "eject") {
                    Text("Click the eject button next to your phone (or press ⌘E) so no copy is cut off halfway.")
                }

                HelpSection("Keyboard shortcuts", systemImage: "keyboard") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        ShortcutRow("Return or double-click", "Open a folder")
                        ShortcutRow("⌘[", "Back")
                        ShortcutRow("⇧⌘↑", "Back to the top of the phone")
                        ShortcutRow("⌘1, ⌘2…", "Switch between phone storage and SD card")
                        ShortcutRow("Space or ⌘Y", "Quick Look")
                        ShortcutRow("⇧⌘C", "Copy to Mac")
                        ShortcutRow("⇧⌘D", "Choose where to save")
                        ShortcutRow("⌥⌘L", "Show the Save To folder in Finder")
                        ShortcutRow("⌘R", "Reload the folder")
                        ShortcutRow("⌘E", "Eject the phone")
                    }
                }

                HelpSection("Privacy", systemImage: "lock") {
                    Text("\(AppInfo.name) works entirely on your Mac. It makes no network requests and never uploads file names or contents.")
                }
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(minWidth: 480, idealWidth: 600, minHeight: 420, idealHeight: 640)
    }
}

private struct HelpSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
            content
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HelpStep: View {
    let number: Int
    let text: String

    init(_ number: Int, _ text: String) {
        self.number = number
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            Text(text)
        }
    }
}

private struct ShortcutRow: View {
    let keys: String
    let action: String

    init(_ keys: String, _ action: String) {
        self.keys = keys
        self.action = action
    }

    var body: some View {
        GridRow {
            Text(keys).font(.body.monospaced()).foregroundStyle(.secondary)
            Text(action)
        }
    }
}
