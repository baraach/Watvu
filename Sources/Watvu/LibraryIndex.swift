import Foundation

/// Season and episode read from an M3U series entry's name, e.g.
/// "AR: Blue Bloods S04 Blue Bloods.S04.E07" or "The Future Diary S01 The.Future.Diary.S01E10".
struct EpisodeName: Equatable {
    let show: String
    let season: Int
    let episode: Int

    // "<show> S01 <file name ending in E05 or S05>"
    private static let labelled = try! NSRegularExpression(
        pattern: #"^(.+?)\s+S(\d{1,3})\s+.*?[ES](\d{1,4})\s*$"#, options: .caseInsensitive)
    // "<show> S01E05", "<show>.S01.E05"
    private static let plain = try! NSRegularExpression(
        pattern: #"^(.+?)[\s._-]+S(\d{1,3})[\s._-]*E(\d{1,4})"#, options: .caseInsensitive)
    private static let leadingSeason = try! NSRegularExpression(pattern: #"^S\d{1,3}\s+"#, options: .caseInsensitive)

    static func parse(_ name: String) -> EpisodeName? {
        let range = NSRange(name.startIndex..., in: name)
        guard let match = labelled.firstMatch(in: name, range: range) ?? plain.firstMatch(in: name, range: range),
              let showRange = Range(match.range(at: 1), in: name),
              let seasonRange = Range(match.range(at: 2), in: name),
              let episodeRange = Range(match.range(at: 3), in: name),
              let season = Int(name[seasonRange]), let episode = Int(name[episodeRange]) else { return nil }
        // Some providers repeat the season in front: "S01 Plan Coeur S01 E01".
        var show = String(name[showRange])
        show = leadingSeason.stringByReplacingMatches(in: show, range: NSRange(show.startIndex..., in: show), withTemplate: "")
        show = show.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !show.isEmpty else { return nil }
        return EpisodeName(show: show, season: season, episode: episode)
    }
}

/// A sorted, read-only view of the library, built off the main thread so big
/// playlists never block the interface. M3U series entries (one per episode)
/// are grouped into one card per show.
struct LibraryIndex {
    private(set) var live: [MediaItem] = []
    private(set) var movies: [MediaItem] = []
    /// One entry per show; each show's episodes are in `episodesByShow`.
    private(set) var shows: [MediaItem] = []
    private(set) var groups: [MediaKind: [String]] = [:]
    private(set) var itemCounts: [UUID: Int] = [:]
    /// Changes with every rebuild, so pages know to refresh.
    let revision = UUID()
    private var source: [MediaItem] = []
    private var positions: [String: Int32] = [:]
    private var showPositions: [String: Int32] = [:]
    /// Where each show's episodes are in `source`.
    private var episodesByShow: [String: [Int32]] = [:]
    private var adjust: @Sendable (MediaItem) -> MediaItem = { $0 }

    init() {}

    /// `adjust` applies the user's rename and category overrides. The costly
    /// per-item work (overrides, sort keys, reading episode names) and the
    /// sorts run across all cores; big libraries would otherwise take a second.
    init(items: [MediaItem], adjust: @escaping @Sendable (MediaItem) -> MediaItem = { $0 }) {
        source = items
        self.adjust = adjust
        struct Prepared { var item: MediaItem; var key: String; var showName: String? }
        var prepared = [Prepared?](repeating: nil, count: items.count)
        prepared.withUnsafeMutableBufferPointer { buffer in
            let out = UnsafeSendable(buffer)
            let chunk = Swift.max(items.count / 64, 512)
            DispatchQueue.concurrentPerform(iterations: items.count / chunk + 1) { part in
                for i in (part * chunk)..<Swift.min((part + 1) * chunk, items.count) {
                    let item = adjust(items[i])
                    let groups = item.kind == .series && !item.streamURL.isEmpty
                    out.value[i] = Prepared(item: item, key: Self.sortKey(item.name),
                                            showName: groups ? (EpisodeName.parse(item.name)?.show ?? item.name) : nil)
                }
            }
        }

        positions.reserveCapacity(items.count)
        var showOrder: [String] = []
        var showCards: [String: MediaItem] = [:]
        var liveKeyed: [(String, MediaItem)] = [], movieKeyed: [(String, MediaItem)] = [], showKeyed: [(String, MediaItem)] = []
        var groupSets: [MediaKind: Set<String>] = [:]
        var lastShowName = "", lastShowPlaylist: UUID?, lastShowID = ""
        for (position, entry) in prepared.enumerated() {
            guard let entry else { continue }
            let item = entry.item
            positions[items[position].id] = Int32(position)
            itemCounts[item.playlistID, default: 0] += 1
            groupSets[item.kind, default: []].insert(item.group)
            switch item.kind {
            case .live: liveKeyed.append((entry.key, item))
            case .movie: movieKeyed.append((entry.key, item))
            case .series:
                // Xtream and media-server shows are already one entry per
                // show (no stream of their own); only playable entries group.
                guard let showName = entry.showName else {
                    showKeyed.append((entry.key, item))
                    continue
                }
                // Episodes of a show are usually adjacent: reuse the last ID.
                let id: String
                if showName == lastShowName, item.playlistID == lastShowPlaylist {
                    id = lastShowID
                } else {
                    id = "\(item.playlistID.uuidString)|show|\(showName.lowercased())"
                    (lastShowName, lastShowPlaylist, lastShowID) = (showName, item.playlistID, id)
                }
                if showCards[id] == nil {
                    showOrder.append(id)
                    showCards[id] = MediaItem(id: id, playlistID: item.playlistID, name: showName, group: item.group,
                                              logo: item.logo, backdrop: item.backdrop, streamURL: "", kind: .series)
                }
                episodesByShow[id, default: []].append(Int32(position))
            }
        }
        for id in showOrder {
            guard var card = showCards[id] else { continue }
            let count = episodesByShow[id]?.count ?? 0
            card.subtitle = count == 1 ? "1 episode" : "\(count) episodes"
            let adjusted = adjust(card)
            showKeyed.append((Self.sortKey(adjusted.name), adjusted))
        }
        var lists: [[MediaItem]] = [[], [], []]
        let inputs = [liveKeyed, movieKeyed, showKeyed]
        lists.withUnsafeMutableBufferPointer { buffer in
            let out = UnsafeSendable(buffer)
            DispatchQueue.concurrentPerform(iterations: 3) { out.value[$0] = Self.sorted(inputs[$0]) }
        }
        live = lists[0]
        movies = lists[1]
        shows = lists[2]
        for (index, show) in shows.enumerated() { showPositions[show.id] = Int32(index) }
        groups = groupSets.mapValues { $0.sorted() }
    }

    var isEmpty: Bool { source.isEmpty }

    /// Any item or show by ID.
    func item(id: String) -> MediaItem? {
        if let position = positions[id] { return source[Int(position)] }
        if let position = showPositions[id] { return shows[Int(position)] }
        return nil
    }

    func list(_ kind: MediaKind?) -> [MediaItem] {
        switch kind {
        case .live: return live
        case .movie: return movies
        case .series: return shows
        case nil: return live + movies + shows
        }
    }

    func isGroupedShow(_ id: String) -> Bool { episodesByShow[id] != nil }

    /// Episodes of a grouped show as seasons, in order.
    func seasons(ofShow id: String) -> [SeriesSeason] {
        var bySeason: [Int: [SeriesEpisode]] = [:]
        for position in episodesByShow[id] ?? [] {
            let item = adjust(source[Int(position)])
            let parsed = EpisodeName.parse(item.name)
            let season = parsed?.season ?? 1
            let number = parsed?.episode ?? (bySeason[season]?.count ?? 0) + 1
            bySeason[season, default: []].append(SeriesEpisode(
                id: item.id, title: "Episode \(number)", season: season, number: number,
                streamURL: item.streamURL, artwork: item.logo))
        }
        return bySeason.map { SeriesSeason(number: $0.key, episodes: $0.value.sorted { $0.number < $1.number }) }
            .sorted { $0.number < $1.number }
    }

    private static func sortKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func sorted(_ keyed: [(String, MediaItem)]) -> [MediaItem] {
        keyed.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case name, recentlyAdded, recentlyWatched
    var id: String { rawValue }
}

/// One page's filters, run off the main thread on a snapshot of the data.
struct LibraryQuery: Equatable {
    var kind: MediaKind?
    var favoriteIDs: Set<String>?
    var playlistID: UUID?
    var group: String?
    var hiddenIDs: Set<String> = []
    var hiddenGroups: Set<String> = []
    var search = ""
    var sort: LibrarySort = .name
    var positions: [String: Double] = [:]
    var groupSimilar = false

    func run(on index: LibraryIndex) -> [MediaItem] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = index.list(kind).filter { item in
            if let favoriteIDs, !favoriteIDs.contains(item.id) { return false }
            if let playlistID, item.playlistID != playlistID { return false }
            if let group, item.group != group { return false }
            if hiddenIDs.contains(item.id) || hiddenGroups.contains(item.group) { return false }
            if !needle.isEmpty,
               !item.name.lowercased().contains(needle), !item.group.lowercased().contains(needle) { return false }
            return true
        }
        switch sort {
        case .name: break   // the index is already sorted by name
        case .recentlyAdded: result.sort { $0.id > $1.id }
        case .recentlyWatched: result.sort { (positions[$0.id] ?? 0) > (positions[$1.id] ?? 0) }
        }
        guard groupSimilar else { return result }
        // Collapse entries whose cleaned names match (ignores 1080p/HEVC/region tags).
        var order: [String] = []
        var members: [String: [MediaItem]] = [:]
        for item in result {
            let key = NameCleaner.cleaned(item.name).lowercased()
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(item)
        }
        return order.compactMap { key in
            guard let group = members[key], var card = group.first else { return nil }
            card.name = NameCleaner.cleaned(card.name)
            if group.count > 1 { card.subtitle = "\(group.count) sources" }
            return card
        }
    }
}

/// Passes a buffer whose elements each loop writes separately across threads.
private struct UnsafeSendable<T>: @unchecked Sendable {
    let value: UnsafeMutableBufferPointer<T>
    init(_ value: UnsafeMutableBufferPointer<T>) { self.value = value }
}

/// Reads a saved library across all cores: splits the JSON array between
/// items and decodes the pieces in parallel, in order.
enum LibraryFile {
    static func decode(_ data: Data) -> [MediaItem]? {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        guard data.count > 1_000_000, cores > 1 else { return decodeWhole(data) }
        let ranges = itemRanges(in: data, parts: cores * 2)
        guard ranges.count > 1 else { return decodeWhole(data) }
        var parts = [[MediaItem]?](repeating: nil, count: ranges.count)
        parts.withUnsafeMutableBufferPointer { buffer in
            let out = UnsafeSendable(buffer)
            DispatchQueue.concurrentPerform(iterations: ranges.count) { i in
                var slice = Data("[".utf8)
                slice.append(data[ranges[i]])
                slice.append(contentsOf: Array("]".utf8))
                out.value[i] = decodeWhole(slice)
            }
        }
        var all: [MediaItem] = []
        all.reserveCapacity(parts.reduce(0) { $0 + ($1?.count ?? 0) })
        for i in parts.indices {
            guard let part = parts[i] else { return decodeWhole(data) }   // unexpected shape: read it plainly
            all += part
            parts[i] = nil
        }
        return all
    }

    private static func decodeWhole(_ data: Data) -> [MediaItem]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[StringPool.userInfoKey] = StringPool()
        return try? decoder.decode([MediaItem].self, from: data)
    }

    /// Byte ranges of about equal size, each a run of whole top-level items.
    /// Empty if the data isn't a JSON array.
    static func itemRanges(in data: Data, parts: Int) -> [Range<Int>] {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Range<Int>] in
            let bytes = raw.bindMemory(to: UInt8.self)
            let quote = UInt8(ascii: "\""), slash = UInt8(ascii: "\\"), comma = UInt8(ascii: ",")
            let open1 = UInt8(ascii: "{"), open2 = UInt8(ascii: "[")
            let close1 = UInt8(ascii: "}"), close2 = UInt8(ascii: "]")
            guard let first = bytes.firstIndex(where: { $0 > 32 }), bytes[first] == open2 else { return [] }
            let target = Swift.max(bytes.count / Swift.max(parts, 1), 1)
            var ranges: [Range<Int>] = []
            var start = first + 1, depth = 0, inString = false, index = first + 1
            var end = -1
            while index < bytes.count {
                let byte = bytes[index]
                if inString {
                    if byte == slash { index += 1 } else if byte == quote { inString = false }
                } else if byte == quote {
                    inString = true
                } else if byte == open1 || byte == open2 {
                    depth += 1
                } else if byte == close1 {
                    depth -= 1
                } else if byte == close2 {
                    if depth == 0 { end = index; break }
                    depth -= 1
                } else if byte == comma, depth == 0, index - start >= target {
                    ranges.append(start..<index)
                    start = index + 1
                }
                index += 1
            }
            guard end >= 0 else { return [] }
            if start < end { ranges.append(start..<end) }
            return ranges
        }
    }
}
