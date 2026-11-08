import SwiftUI
import Foundation

struct AccentOption: Identifiable, Hashable {
    let id: String          // six-digit RGB hex
    let name: String

    var color: Color { Color(hex: id) ?? .orange }
}

enum AccentPalette {
    static let storageKey = "settings.accent"

    static let options: [AccentOption] = [
        AccentOption(id: "FF3800", name: "Watvu Orange"),
        AccentOption(id: "FF2D55", name: "Pink"),
        AccentOption(id: "BF5AF2", name: "Purple"),
        AccentOption(id: "0A84FF", name: "Blue"),
        AccentOption(id: "64D2FF", name: "Teal"),
        AccentOption(id: "30D158", name: "Green"),
        AccentOption(id: "FFD60A", name: "Yellow"),
        AccentOption(id: "FF453A", name: "Red"),
        AccentOption(id: "8E8E93", name: "Graphite")
    ]

    static var defaultOption: AccentOption { options[0] }

    static func option(for hex: String) -> AccentOption {
        options.first { $0.id.caseInsensitiveCompare(hex) == .orderedSame } ?? defaultOption
    }

    static func color(for hex: String) -> Color {
        option(for: hex).color
    }

    /// Current accent from UserDefaults, for places without an @AppStorage.
    static var current: AccentOption {
        let stored = UserDefaults.standard.string(forKey: storageKey) ?? defaultOption.id
        return option(for: stored)
    }
}

extension Color {
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6 || cleaned.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value) else { return nil }
        let r, g, b, a: Double
        if cleaned.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
