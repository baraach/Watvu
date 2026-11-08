import Foundation

/// One timed subtitle line.
struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// Parses SubRip (.srt) and WebVTT (.vtt) files for the player's own subtitle
/// layer. AVPlayer can't attach a side-loaded subtitle file to a stream or
/// delay subtitles, so the app draws loaded subtitles itself.
enum SubtitleParser {
    static func parse(data: Data) -> [SubtitleCue] {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return parse(text: text)
    }

    static func parse(text: String) -> [SubtitleCue] {
        let normalised = text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalised.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = time(parts[0]),
                  let end = time(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
            else { continue }
            let body = lines[(timeIndex + 1)...].map(clean).filter { !$0.isEmpty }.joined(separator: "\n")
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: max(end, start), text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// The cue showing at `time` (binary search; cues are sorted by start).
    static func cue(at time: Double, in cues: [SubtitleCue]) -> SubtitleCue? {
        var low = 0, high = cues.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        guard let index = found else { return nil }
        // Overlapping cues: walk back a little to find one still showing.
        for i in stride(from: index, through: max(0, index - 5), by: -1) where cues[i].end > time {
            return cues[i]
        }
        return nil
    }

    /// "01:02:03,456", "01:02:03.456" or "02:03.456" → seconds.
    static func time(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let fields = value.split(separator: ":").map(String.init)
        guard (2...3).contains(fields.count) else { return nil }
        var seconds = 0.0
        for field in fields {
            guard let number = Double(field) else { return nil }
            seconds = seconds * 60 + number
        }
        return seconds
    }

    /// Removes formatting tags such as `<i>`, `<font …>` and `{\an8}`.
    private static func clean(_ line: String) -> String {
        line.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
