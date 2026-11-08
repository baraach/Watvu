import Foundation

enum M3UParser {
    /// Parses M3U/M3U8 text. `baseURL` resolves relative stream and logo URLs
    /// against the playlist location.
    static func parse(text: String, playlistID: UUID, baseURL: URL? = nil) -> [MediaItem] {
        let state = ParserState(playlistID: playlistID, baseURL: baseURL)
        // B60: stream line by line; substrings share storage, no line array.
        var remaining = Substring(text)
        while !remaining.isEmpty {
            let rawLine: Substring
            if let nl = remaining.rangeOfCharacter(from: .newlines) {
                rawLine = remaining[..<nl.lowerBound]
                remaining = remaining[nl.upperBound...]
            } else {
                rawLine = remaining
                remaining = ""
            }
            state.feed(String(rawLine).trimmed)
        }
        return state.finish()
    }

    /// Incremental M3U parser — feed lines as they arrive (chunked downloads).
    static func parse<S: Sequence>(lines: S, playlistID: UUID, baseURL: URL? = nil) -> [MediaItem]
        where S.Element == String {
        let state = ParserState(playlistID: playlistID, baseURL: baseURL)
        for line in lines { state.feed(line.trimmed) }
        return state.finish()
    }

    /// B60: download and parse an M3U in one streaming pass (no full text in memory).
    /// `progress` gets the number of entries read so far, now and then.
    static func parseStream(from url: URL, playlistID: UUID,
                            progress: (@Sendable (Int) -> Void)? = nil) async throws -> [MediaItem] {
        let state = ParserState(playlistID: playlistID, baseURL: url)
        let (bytes, _) = try await URLSession.shared.bytes(for: URLRequest(url: url))
        var reported = 0
        for try await line in bytes.lines {
            state.feed(line)
            if state.items.count >= reported + 5000 {
                reported = state.items.count
                progress?(reported)
            }
        }
        return state.finish()
    }

    private final class ParserState {
        let playlistID: UUID
        let baseURL: URL?
        var items: [MediaItem] = []
        private var seen = Set<String>()
        private var defaults: [String: String] = [:]
        private var attributes: [String: String]?
        private var name = ""
        private var extGroup = ""
        private var headers: [String: String] = [:]

        private let pool = StringPool()

        init(playlistID: UUID, baseURL: URL?) {
            self.playlistID = playlistID
            self.baseURL = baseURL
        }

        func feed(_ line: String) {
            guard !line.isEmpty else { return }

            if line.hasPrefix("#EXTM3U") {
                defaults = M3UParser.parseAttributes(in: line)
            } else if line.hasPrefix("#EXTINF:") {
                let parts = M3UParser.splitExtinf(line)
                attributes = M3UParser.parseAttributes(in: parts.attributes)
                name = parts.title
            } else if line.hasPrefix("#EXTGRP:") {
                extGroup = String(line.dropFirst("#EXTGRP:".count)).trimmed
            } else if line.hasPrefix("#EXTVLCOPT:") {
                let option = String(line.dropFirst("#EXTVLCOPT:".count))
                if let (header, value) = M3UParser.vlcHeader(option) { merge(&headers, [header: value]) }
            } else if line.hasPrefix("#KODIPROP:") {
                let option = String(line.dropFirst("#KODIPROP:".count))
                merge(&headers, M3UParser.kodipropHeaders(option))
            } else if line.hasPrefix("#EXTHTTP:") {
                let json = String(line.dropFirst("#EXTHTTP:".count))
                merge(&headers, M3UParser.jsonHeaders(json))
            } else if line.hasPrefix("#") {
                return
            } else if attributes == nil || name.isEmpty {
                attributes = nil
                headers = [:]
                extGroup = ""
            } else if let entry = attributes {
                defer {
                    attributes = nil
                    name = ""
                    headers = [:]
                    extGroup = ""
                }

                let pieces = line.split(separator: "|", maxSplits: 1).map(String.init)
                guard let resolved = URL(string: pieces[0], relativeTo: baseURL),
                      resolved.scheme != nil else { return }
                let stream = resolved.absoluteString

                if pieces.count == 2 { merge(&headers, M3UParser.pipeHeaders(pieces[1])) }
                if let agent = M3UParser.nonEmpty(entry["http-user-agent"] ?? entry["user-agent"]) {
                    merge(&headers, ["User-Agent": agent])
                }
                if let referrer = M3UParser.nonEmpty(entry["http-referrer"] ?? entry["referrer"]) {
                    merge(&headers, ["Referer": referrer])
                }

                let rawGroup = M3UParser.nonEmpty(entry["group-title"]) ?? M3UParser.nonEmpty(extGroup) ?? "Ungrouped"
                let groupParts = rawGroup.split(separator: ";").map { String($0).trimmed }.filter { !$0.isEmpty }
                let group = groupParts.first ?? "Ungrouped"
                let tags = groupParts.count > 1 ? Array(groupParts.dropFirst()) : nil
                let itemID = "\(playlistID.uuidString)|\(stream)|\(name)"
                guard seen.insert(itemID).inserted else { return }

                let logo = M3UParser.nonEmpty(entry["tvg-logo"]).flatMap {
                    URL(string: $0, relativeTo: baseURL)?.absoluteString
                }
                let kind = M3UParser.inferKind(name: name, group: group, stream: stream)
                items.append(
                    MediaItem(
                        id: itemID,
                        playlistID: playlistID,
                        name: name,
                        group: pool.share(group),
                        logo: logo.map(pool.share),
                        streamURL: stream,
                        kind: kind,
                        tvgID: M3UParser.nonEmpty(entry["tvg-id"]),
                        subtitle: nil,
                        httpHeaders: headers.isEmpty ? nil : headers,
                        catchup: kind == .live ? M3UParser.catchup(entry, defaults: defaults, stream: stream) : nil,
                        tags: tags
                    )
                )
            }
        }

        func finish() -> [MediaItem] { items }
    }


    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func merge(_ base: inout [String: String], _ extra: [String: String]) {
        for (key, value) in extra where !value.isEmpty { base[key] = value }
    }

    private static func canonicalHeader(_ name: String) -> String {
        switch name.lowercased() {
        case "user-agent", "user agent", "http-user-agent": return "User-Agent"
        case "referer", "referrer", "http-referrer": return "Referer"
        case "origin": return "Origin"
        case "cookie": return "Cookie"
        default: return name
        }
    }

    private static let knownHeaderKeys: Set<String> = ["user-agent", "referer", "referrer", "cookie", "origin"]

    /// Splits `a=1&b=2` header lists; `&` inside a known multi-value header
    /// (e.g. Cookie) stays in the value.
    private static func splitHeaderPairs(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var lastKey: String?
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let key = canonicalHeader(kv[0])
            if knownHeaderKeys.contains(kv[0].lowercased()) || result.isEmpty {
                result[key] = kv[1]
                lastKey = key
            } else if let lastKey {
                result[lastKey] = (result[lastKey] ?? "") + "&" + String(pair)
            }
        }
        return result
    }

    private static func vlcHeader(_ option: String) -> (String, String)? {
        let kv = option.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { return nil }
        return (canonicalHeader(kv[0]), kv[1])
    }

    private static func kodipropHeaders(_ option: String) -> [String: String] {
        // inputstream.adaptive.stream_headers=User-Agent=…&Referer=…
        let kv = option.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2, kv[0].contains("stream_headers") else { return [:] }
        return splitHeaderPairs(kv[1])
    }

    private static func jsonHeaders(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in obj where value is String {
            result[canonicalHeader(key)] = value as? String ?? ""
        }
        return result
    }

    private static func pipeHeaders(_ tail: String) -> [String: String] {
        splitHeaderPairs(tail)
    }

    private static func catchup(_ entry: [String: String], defaults: [String: String], stream: String) -> Catchup? {
        let merged = defaults.merging(entry) { _, new in new }
        let hasCatchup = nonEmpty(merged["catchup"]) != nil || nonEmpty(merged["catchup-source"]) != nil
            || nonEmpty(merged["timeshift"]) != nil || nonEmpty(merged["tvg-rec"]) != nil
            || stream.contains("/live/")
        guard hasCatchup else { return nil }
        let days = Int(nonEmpty(merged["catchup-days"]) ?? "") ?? 7
        let source = nonEmpty(merged["catchup-source"])
        let kind = (nonEmpty(merged["catchup"]) ?? nonEmpty(merged["tvg-rec"]))?.lowercased()
        let mode: Catchup.Mode
        if let kind {
            switch kind {
            case "xtream": mode = .xtream
            case "append": mode = .append
            case "shift", "timeshift": mode = .shift
            case "flussonic": mode = .flussonic
            default: mode = .template
            }
        } else if let src = source {
            mode = src.contains("{") ? .template : .append
        } else if stream.contains("/live/") {
            mode = .xtream
        } else {
            mode = .shift
        }
        return Catchup(mode: mode, days: days, source: source)
    }

    private static func parseAttributes(in line: String) -> [String: String] {
        var result: [String: String] = [:]
        // Quoted or unquoted values: tvg-id="x", tvg-id=x
        let pattern = #"([A-Za-z0-9_-]+)\s*=\s*(?:"([^"]*)"|([^"\s,]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        for match in regex.matches(in: line, range: range) {
            guard match.numberOfRanges == 4,
                  let keyRange = Range(match.range(at: 1), in: line) else { continue }
            let valueRange = match.range(at: 2).location != NSNotFound
                ? Range(match.range(at: 2), in: line)
                : Range(match.range(at: 3), in: line)
            guard let valueRange else { continue }
            result[String(line[keyRange]).lowercased()] = String(line[valueRange])
        }
        return result
    }

    /// Display name = text after the first comma that is outside quotes, so
    /// both `group-title="A, B"` and names like "News, Weather" survive.
    static func title(in line: String) -> String {
        splitExtinf(line).title
    }

    /// Splits `#EXTINF:-1 attrs…,Title` at the first unquoted comma, so `=`
    /// inside a title isn't read as an attribute.
    static func splitExtinf(_ line: String) -> (attributes: String, title: String) {
        // B57: scan unicodeScalars — combining marks merge with quotes/commas
        // into one grapheme when scanning Characters, dropping Arabic titles.
        var inQuotes = false
        var attrs = String.UnicodeScalarView()
        var title = String.UnicodeScalarView()
        var inTitle = false
        for sc in line.unicodeScalars {
            if inTitle { title.append(sc); continue }
            switch sc {
            case "\"": inQuotes.toggle(); attrs.append(sc)
            case "," where !inQuotes:
                inTitle = true
            default: attrs.append(sc)
            }
        }
        return (String(attrs), String(title).trimmed)
    }

    private static func inferKind(name: String, group: String, stream: String) -> MediaKind {
        // B49: the URL path carries the truth for Xtream-style playlists —
        // check it before guessing from names/extensions.
        let lower = stream.lowercased()
        if lower.contains("/series/") { return .series }
        if lower.contains("/movie/") { return .movie }
        if lower.contains("/live/") { return .live }
        let ext = URL(string: stream)?.pathExtension.lowercased() ?? ""
        if ext == "ts" || lower.contains(".m3u8") { return .live }
        if ["mp4", "mkv", "avi", "mov", "m4v"].contains(ext) { return .movie }
        // B49: plain-M3U entries default to live; only trust name words when
        // the "URL" isn't an http(s) stream at all.
        if lower.hasPrefix("http") { return .live }
        let haystack = "\(name) \(group)".lowercased()
        if haystack.contains("series") || haystack.contains("show") || haystack.contains("season") {
            return .series
        }
        if haystack.contains("movie") || haystack.contains("vod") || haystack.contains("film") {
            return .movie
        }
        return .live
    }
}
