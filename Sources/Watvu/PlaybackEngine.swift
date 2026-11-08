import Foundation

/// Which playback engine renders a stream.
enum EngineKind: String, Codable, CaseIterable, Identifiable {
    case auto, avplayer, mpv
    var id: String { rawValue }
}

/// Picks an engine for an item: per-playlist override, else the global setting.
/// `PlayerController` does the switching (and the AVPlayer → mpv fallback).
enum EnginePicker {
    static let settingKey = "playbackEngine"

    static func engine(playlistOverride: EngineKind?) -> EngineKind {
        if let playlistOverride { return playlistOverride }
        let raw = UserDefaults.standard.string(forKey: settingKey) ?? EngineKind.auto.rawValue
        return EngineKind(rawValue: raw) ?? .auto
    }

    /// Containers AVPlayer can't open → go straight to mpv in Auto mode.
    static let mpvFirstExtensions: Set<String> = ["mkv", "avi", "flv", "wmv", "vob", "mpg", "mpeg", "m2ts", "3gp", "webm", "ogv"]

    static func needsMPV(url: URL) -> Bool {
        mpvFirstExtensions.contains(url.pathExtension.lowercased())
    }
}
