import SwiftUI
import AppKit

/// App colors and the per-group artwork gradients.
enum Theme {
    /// The current accent, read from the persisted palette. The roots also
    /// set `.tint`, but macOS's `Color.accentColor` does not follow `.tint`,
    /// so views that draw accent-colored shapes use this explicit value and
    /// the roots key their content on the accent to force a redraw.
    static var accent: Color { AccentPalette.current.color }

    /// The app's background: light #EDF0F5,
    /// dark #121212.
    static let background = Color(nsColor: NSColor(name: "WatvuBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255, alpha: 1)
            : NSColor(srgbRed: 0xED / 255, green: 0xF0 / 255, blue: 0xF5 / 255, alpha: 1)
    })
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary


    /// Placeholder artwork gradients; a group always maps to the same one.
    private static let cardGradients: [[Color]] = [
        [Color(red: 0.52, green: 0.17, blue: 0.24), Color(red: 0.31, green: 0.09, blue: 0.14)],
        [Color(red: 0.77, green: 0.58, blue: 0.08), Color(red: 0.52, green: 0.37, blue: 0.04)],
        [Color(red: 0.14, green: 0.43, blue: 0.39), Color(red: 0.06, green: 0.25, blue: 0.23)],
        [Color(red: 0.21, green: 0.36, blue: 0.61), Color(red: 0.10, green: 0.20, blue: 0.40)],
        [Color(red: 0.45, green: 0.25, blue: 0.56), Color(red: 0.26, green: 0.13, blue: 0.35)],
        [Color(red: 0.62, green: 0.34, blue: 0.18), Color(red: 0.38, green: 0.18, blue: 0.09)],
        [Color(red: 0.24, green: 0.49, blue: 0.26), Color(red: 0.11, green: 0.30, blue: 0.14)]
    ]

    /// Stable FNV-1a hash, so a key keeps its gradient across launches.
    private static func colors(for key: String) -> [Color] {
        var hash: UInt64 = 14695981039346656037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return cardGradients[Int(hash % UInt64(cardGradients.count))]
    }

    static func gradient(for key: String) -> LinearGradient {
        LinearGradient(colors: colors(for: key), startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func heroGradient(for key: String) -> LinearGradient {
        let colors = colors(for: key)
        return LinearGradient(
            colors: [colors[0], colors[1].opacity(0.85), background],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
