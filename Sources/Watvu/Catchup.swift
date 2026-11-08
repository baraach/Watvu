import Foundation

/// Builds archive (catch-up) URLs for past programmes.
enum CatchupURL {
    static func url(for channel: MediaItem, program: EPGProgram, timeZone: TimeZone) -> URL? {
        guard let catchup = channel.catchup else { return nil }
        let start = program.start, end = program.end
        let stream = channel.streamURL

        let text: String?
        switch catchup.mode {
        case .xtream:
            text = xtream(stream: stream, start: start, end: end, timeZone: timeZone)
        case .append:
            text = catchup.source.map { stream + fill($0, start: start, end: end) }
        case .shift:
            let separator = stream.contains("?") ? "&" : "?"
            text = stream + separator + fill("utc={utc}&lutc={lutc}", start: start, end: end)
        case .flussonic:
            text = flussonic(stream: stream, start: start, end: end)
        case .template:
            text = catchup.source.map { fill($0, start: start, end: end) }
        }
        return text.flatMap(URL.init(string:))
    }

    /// Whether `program` has started (a minute ago, so there's something to
    /// rewind — this includes restarting the current show) and is still
    /// within the archive window.
    static func isAvailable(_ channel: MediaItem, program: EPGProgram, now: Date = Date()) -> Bool {
        guard let catchup = channel.catchup, catchup.days > 0 else { return false }
        return program.start <= now.addingTimeInterval(-60)
            && program.start >= now.addingTimeInterval(-Double(catchup.days) * 86_400)
    }

    // `…/live/user/pass/id.ext` → `…/timeshift/user/pass/<minutes>/<yyyy-MM-dd:HH-mm>/id.m3u8`
    private static func xtream(stream: String, start: Date, end: Date, timeZone: TimeZone) -> String? {
        guard let range = stream.range(of: "/live/") else { return nil }
        let parts = stream[range.upperBound...].split(separator: "/").map(String.init)
        guard parts.count == 3 else { return nil }
        let id = parts[2].split(separator: ".").first.map(String.init) ?? parts[2]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd:HH-mm"
        let minutes = max(1, Int(end.timeIntervalSince(start) / 60))
        let base = stream[..<range.lowerBound]
        return "\(base)/timeshift/\(parts[0])/\(parts[1])/\(minutes)/\(formatter.string(from: start))/\(id).m3u8"
    }

    // Flussonic: `…/mpegts` → `…/timeshift_abs-<start>.ts`,
    // `…/index.m3u8` → `…/index-<start>-<duration>.m3u8`.
    private static func flussonic(stream: String, start: Date, end: Date) -> String? {
        guard var url = URL(string: stream) else { return nil }
        let utc = Int(start.timeIntervalSince1970)
        let duration = Int(end.timeIntervalSince(start))
        let last = url.lastPathComponent
        url.deleteLastPathComponent()
        let file = last == "mpegts" ? "timeshift_abs-\(utc).ts" : "index-\(utc)-\(duration).m3u8"
        return url.appendingPathComponent(file).absoluteString
    }

    /// Fills the common catch-up placeholders (Kodi / TiviMate style).
    static func fill(_ template: String, start: Date, end: Date, now: Date = Date()) -> String {
        let utc = Int(start.timeIntervalSince1970)
        let utcEnd = Int(end.timeIntervalSince1970)
        let lutc = Int(now.timeIntervalSince1970)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }

        let values: [String: String] = [
            "{utc}": "\(utc)", "${start}": "\(utc)", "{start}": "\(utc)",
            "{utcend}": "\(utcEnd)", "${end}": "\(utcEnd)", "{end}": "\(utcEnd)",
            "{lutc}": "\(lutc)", "${timestamp}": "\(lutc)", "${now}": "\(lutc)", "{now}": "\(lutc)",
            "{duration}": "\(utcEnd - utc)", "${duration}": "\(utcEnd - utc)",
            "{offset}": "\(lutc - utc)", "${offset}": "\(lutc - utc)",
            "{Y}": "\(c.year ?? 0)", "{m}": two(c.month), "{d}": two(c.day),
            "{H}": two(c.hour), "{M}": two(c.minute), "{S}": two(c.second)
        ]
        return values.reduce(template) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }
}
