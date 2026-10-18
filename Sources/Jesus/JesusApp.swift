import AppKit
import SwiftUI

/// Jesus lives in the menu bar. Drag files anywhere and press Shift to open the quick action menu.
@main
struct JesusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            Text("Drag files and press ⇧ Shift for quick actions")
            Divider()
            Button("Choose Files…") { model.choose() }
                .keyboardShortcut("o")
                .disabled(model.isRunning)
            if !model.files.isEmpty {
                Button(model.isRunning ? "Show Progress" : "Show Last Files") { QuickPanel.shared.showCentered() }
            }
            if !FolderAccess.hasFullDiskAccess {
                Button("Allow Access to All Folders…") { FolderAccess.openSettings() }
            }
            Divider()
            SettingsButton()
            Button("Quit Jesus") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.register()
        MainActor.assumeIsolated {
            DragWatcher.shared.start()
            QuickPanel.shared.prepare()
        }
    }

    /// Files opened with “Open With › Jesus” or dropped on the app in Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.open(urls) }
    }
}

enum Preferences {
    static let sounds = "playsSounds"
    static let haptics = "playsHaptics"

    static func register() {
        UserDefaults.standard.register(defaults: [sounds: true, haptics: true])
    }
}

private struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            // A menu bar app has to come forward for its window to show in front.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
    }
}

private struct SettingsView: View {
    @AppStorage(Preferences.sounds) private var playsSounds = true
    @AppStorage(Preferences.haptics) private var playsHaptics = true

    var body: some View {
        Form {
            Toggle("Sound", isOn: $playsSounds)
            Toggle("Haptics", isOn: $playsHaptics)
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .fixedSize()
    }
}

/// Five dots in a ring, drawn as a template image so it follows the menu bar's appearance.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            for index in 0..<5 {
                let angle = CGFloat.pi / 2 + CGFloat(index) * 2 * .pi / 5
                let dot = CGPoint(x: center.x + cos(angle) * 6, y: center.y + sin(angle) * 6)
                NSBezierPath(ovalIn: NSRect(x: dot.x - 2, y: dot.y - 2, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// Full Disk Access lets Jesus save next to files anywhere without asking folder by folder.
enum FolderAccess {
    /// The TCC database is only readable with Full Disk Access.
    static var hasFullDiskAccess: Bool {
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        try? handle.close()
        return true
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}
