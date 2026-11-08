import SwiftUI
import AppKit

@main
struct WatvuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() {
        Self.importSettingsFromOldNames()
        // Artwork loads through URLSession.shared. Keep it on disk, so it's
        // reused rather than re-fetched without holding it in memory.
        URLCache.shared = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                   diskCapacity: 512 * 1024 * 1024)
        // NOTE: do not pin AppleAccentColor/AppleHighlightColor here; that
        // overrides the user's in-app accent choice. Theme.accent follows the
        // root `.tint`/`.accentColor` environment instead.
    }

    /// Settings live under the bundle ID, which changed with the app's name.
    private static func importSettingsFromOldNames() {
        let defaults = UserDefaults.standard
        let doneKey = "importedOldSettings"
        guard !defaults.bool(forKey: doneKey) else { return }
        for domain in ["com.local.watvu", "com.local.vumqel", "com.local.uhfmac"] {
            for (key, value) in defaults.persistentDomain(forName: domain) ?? [:] where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: doneKey)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onOpenURL { url in   // watvu://add?url=…&name=…
                    guard url.scheme == "watvu" || url.scheme == "uhfmac", url.host == "add" else { return }
                    var parts: [String: String] = [:]
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.forEach { parts[$0.name] = $0.value }
                    if let link = parts["url"] {
                        NotificationCenter.default.post(name: .deeplinkAdd, object: nil, userInfo: ["url": link, "name": parts["name"] ?? ""])
                    }
                }
                .frame(minWidth: 1200, minHeight: 780)
                .task {
                await model.bootstrap()
                ICloudDriveSync.shared.start(model: model)
                DownloadManager.shared.streamURLResolver = { try await model.streamURL(for: $0) }
                RecordingManager.shared.streamURLResolver = { try await model.streamURL(for: $0) }
            }
        }
        // Standard title bar + toolbar, so the system draws the glass toolbar
        // (search field) beside the traffic lights.
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1480, height: 940)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Playlist…") {
                    NotificationCenter.default.post(name: .addPlaylist, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(replacing: .appSettings) {
                SettingsMenuButton()
            }

            CommandMenu("Playlists") {
                Button("Refresh All") {
                    Task { await model.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            CommandGroup(after: .textEditing) {
                Button("Search…") {
                    NotificationCenter.default.post(name: .showSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }

        Window("Settings", id: "settings") {
            SettingsWindowView()
                .environmentObject(model)
        }
        // Unified toolbar (empty, no background) so the native close /
        // minimize / zoom buttons sit inset inside the rail panel, like the
        // main window's sidebar, with no title bar strip.
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(SettingsWindowView.size)
        .windowBackgroundDragBehavior(.enabled)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)
    }
}

/// App menu → Settings… (⌘,). Opens (or focuses) the Settings window even
/// when the main window is closed.
private struct SettingsMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { openWindow(id: "settings") }
            .keyboardShortcut(",", modifiers: .command)
    }
}

extension Notification.Name {
    static let addPlaylist = Notification.Name("watvu.addPlaylist")
    static let showSearch = Notification.Name("watvu.showSearch")
    /// Object: the item ID to put in the new list.
    static let newFavoriteList = Notification.Name("watvu.newFavoriteList")
    static let deeplinkAdd = Notification.Name("watvu.deeplinkAdd")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Quit when the window closes: the player lives in the window, so
    /// nothing is left to keep running in the background.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

}
