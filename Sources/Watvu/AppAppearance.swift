import AppKit

/// Applies the Theme setting (system | light | dark) to every window.
///
/// Uses `NSApp.appearance` rather than SwiftUI's `preferredColorScheme`:
/// once that has forced light or dark, passing `nil` doesn't hand control
/// back to the system, so "System" got stuck on the last forced theme.
enum AppAppearance {
    @MainActor
    static func apply(_ setting: String) {
        let appearance: NSAppearance?
        switch setting {
        case "light": appearance = NSAppearance(named: .aqua)
        case "dark": appearance = NSAppearance(named: .darkAqua)
        default: appearance = nil // follow System Settings
        }
        NSApp.appearance = appearance
        // Clear any per-window override so windows inherit the app's.
        for window in NSApp.windows where window.appearance != nil {
            window.appearance = nil
        }
    }
}
