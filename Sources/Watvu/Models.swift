import Foundation

enum PlaylistKind: String, Codable, CaseIterable, Identifiable {
    case m3u
    case xtream
    case jellyfin
    case emby
    case plex
    case smb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .m3u: return "M3U / M3U8"
        case .xtream: return "Xtream Codes"
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        case .plex: return "Plex"
        case .smb: return "SMB"
        }
    }

    var symbol: String {
        switch self {
        case .m3u: return "doc.text"
        case .xtream: return "server.rack"
        case .jellyfin: return "waveform"
        case .emby: return "play.rectangle"
        case .plex: return "play.tv"
        case .smb: return "externaldrive"
        }
    }
}

struct PlaylistLibrary: Identifiable, Codable, Hashable {
    var id: String
    var name: String
}

struct Playlist: Identifiable, Codable, Hashable {
    init(id: UUID = UUID(), name: String, kind: PlaylistKind, url: String = "", username: String = "",
         password: String = "", epgURL: String? = nil, addedAt: Date = Date(), extraEPGURLs: [String]? = nil,
         serverTimeZone: String? = nil, epgMapping: [String: String]? = nil, cover: String? = nil,
         icon: String? = nil, category: String? = nil, order: Int = 0, apiKey: String = "",
         libraries: [PlaylistLibrary] = [], epgTimeOffsetMinutes: Int = 0, refreshIntervalDays: Int = 1,
         engineOverride: EngineKind? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.url = url; self.username = username
        self.password = password; self.epgURL = epgURL; self.addedAt = addedAt
        self.extraEPGURLs = extraEPGURLs; self.serverTimeZone = serverTimeZone
        self.epgMapping = epgMapping; self.cover = cover; self.icon = icon; self.category = category
        self.order = order; self.apiKey = apiKey; self.libraries = libraries
        self.epgTimeOffsetMinutes = epgTimeOffsetMinutes; self.refreshIntervalDays = refreshIntervalDays
        self.engineOverride = engineOverride
    }

    // B43: tolerate old playlists.json files that predate newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(PlaylistKind.self, forKey: .kind) ?? .m3u
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        epgURL = try c.decodeIfPresent(String.self, forKey: .epgURL)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        extraEPGURLs = try c.decodeIfPresent([String].self, forKey: .extraEPGURLs)
        serverTimeZone = try c.decodeIfPresent(String.self, forKey: .serverTimeZone)
        epgMapping = try c.decodeIfPresent([String: String].self, forKey: .epgMapping)
        cover = try c.decodeIfPresent(String.self, forKey: .cover)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        epgTimeOffsetMinutes = try c.decodeIfPresent(Int.self, forKey: .epgTimeOffsetMinutes) ?? 0
        refreshIntervalDays = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalDays) ?? 1
        engineOverride = try c.decodeIfPresent(String.self, forKey: .engineOverride).flatMap(EngineKind.init)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        serverUserID = try c.decodeIfPresent(String.self, forKey: .serverUserID)
        libraries = try c.decodeIfPresent([PlaylistLibrary].self, forKey: .libraries) ?? []
    }


    var id: UUID = UUID()
    var name: String
    var kind: PlaylistKind
    var url: String = ""
    var username: String = ""
    var password: String = ""
    var epgURL: String? = nil
    var addedAt: Date = Date()
    /// Additional XMLTV sources merged into this playlist's guide.
    var extraEPGURLs: [String]? = nil
    /// Xtream server time zone (catch-up times are in server local time).
    var serverTimeZone: String? = nil
    /// Manual channel ↔ XMLTV id mapping, keyed by stream URL so it survives
    /// playlist refreshes.
    var epgMapping: [String: String]? = nil
    var cover: String? = nil
    var icon: String? = nil
    var category: String? = nil
    var order: Int = 0
    var apiKey: String = ""
    /// Jellyfin/Emby: the signed-in user's ID (their API paths need it).
    var serverUserID: String? = nil
    var libraries: [PlaylistLibrary] = []
    /// Per-playlist EPG time offset in minutes (applied when parsing the guide).
    var epgTimeOffsetMinutes: Int = 0
    /// Auto-refresh cadence in days (0 = manual).
    var refreshIntervalDays: Int = 1
    /// Per-playlist playback engine override (nil = global setting).
    var engineOverride: EngineKind? = nil

    /// Every guide source for this playlist, main one first.
    var guideSources: [String] {
        var sources: [String] = []
        if let epgURL, !epgURL.trimmed.isEmpty { sources.append(epgURL.trimmed) }
        if let extraEPGURLs { sources += extraEPGURLs.map { $0.trimmed }.filter { !$0.isEmpty } }
        return sources
    }
}

enum MediaKind: String, Codable, CaseIterable, Identifiable {
    case live
    case movie
    case series

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "Live TV"
        case .movie: return "Movies"
        case .series: return "Series"
        }
    }

    var symbol: String {
        switch self {
        case .live: return "dot.radiowaves.left.and.right"
        case .movie: return "film"
        case .series: return "tv"
        }
    }
}

struct MediaItem: Identifiable, Codable, Hashable {
    var id: String
    var playlistID: UUID
    var name: String
    var group: String
    var logo: String?
    var streamURL: String
    var kind: MediaKind
    /// Everything most entries leave empty lives behind one pointer. Big
    /// playlists keep hundreds of thousands of items in memory, so this takes
    /// an item from 352 bytes to 112.
    private var box: Box?

    private struct Extras: Hashable {
        var backdrop: String?
        var tvgID: String?
        var subtitle: String?
        var seriesID: Int?
        var movieID: Int?
        var httpHeaders: [String: String]?
        var catchup: Catchup?
        var tmdbMetadata: TMDBMetadata?
        var tags: [String]?
    }

    private indirect enum Box: Hashable { case extras(Extras) }

    private var extras: Extras {
        get {
            guard case .extras(let extras)? = box else { return Extras() }
            return extras
        }
        set { box = newValue == Extras() ? nil : .extras(newValue) }
    }

    var backdrop: String? { get { extras.backdrop } set { extras.backdrop = newValue } }
    var tvgID: String? { get { extras.tvgID } set { extras.tvgID = newValue } }
    var subtitle: String? { get { extras.subtitle } set { extras.subtitle = newValue } }
    var seriesID: Int? { get { extras.seriesID } set { extras.seriesID = newValue } }
    var movieID: Int? { get { extras.movieID } set { extras.movieID = newValue } }
    /// Extra HTTP headers the stream needs (from `#EXTVLCOPT` etc.).
    var httpHeaders: [String: String]? { get { extras.httpHeaders } set { extras.httpHeaders = newValue } }
    /// How to build archive URLs for past programmes, if the channel has one.
    var catchup: Catchup? { get { extras.catchup } set { extras.catchup = newValue } }
    var tmdbMetadata: TMDBMetadata? { get { extras.tmdbMetadata } set { extras.tmdbMetadata = newValue } }
    /// Extra `;`-separated group tags from the playlist (primary group is `group`).
    var tags: [String]? { get { extras.tags } set { extras.tags = newValue } }

    var url: URL? { URL(string: streamURL) }

    init(id: String, playlistID: UUID, name: String, group: String, logo: String? = nil,
         backdrop: String? = nil, streamURL: String, kind: MediaKind, tvgID: String? = nil,
         subtitle: String? = nil, seriesID: Int? = nil, movieID: Int? = nil,
         httpHeaders: [String: String]? = nil, catchup: Catchup? = nil, tmdbMetadata: TMDBMetadata? = nil,
         tags: [String]? = nil) {
        self.id = id; self.playlistID = playlistID; self.name = name; self.group = group
        self.logo = logo; self.streamURL = streamURL; self.kind = kind
        extras = Extras(backdrop: backdrop, tvgID: tvgID, subtitle: subtitle, seriesID: seriesID, movieID: movieID,
                        httpHeaders: httpHeaders, catchup: catchup, tmdbMetadata: tmdbMetadata, tags: tags)
    }

    private enum CodingKeys: String, CodingKey {
        case id, playlistID, name, group, logo, backdrop, streamURL, kind, tvgID, subtitle
        case seriesID, movieID, httpHeaders, catchup, tmdbMetadata, tags
    }

    // B43: tolerate old items.json files missing newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let pool = decoder.userInfo[StringPool.userInfoKey] as? StringPool
        id = try c.decode(String.self, forKey: .id)
        playlistID = try c.decodeIfPresent(UUID.self, forKey: .playlistID) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        let group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        self.group = pool?.share(group) ?? group
        let logo = try c.decodeIfPresent(String.self, forKey: .logo)
        self.logo = logo.map { pool?.share($0) ?? $0 }
        streamURL = try c.decode(String.self, forKey: .streamURL)
        kind = try c.decodeIfPresent(MediaKind.self, forKey: .kind) ?? .live
        extras = Extras(
            backdrop: try c.decodeIfPresent(String.self, forKey: .backdrop),
            tvgID: try c.decodeIfPresent(String.self, forKey: .tvgID),
            subtitle: try c.decodeIfPresent(String.self, forKey: .subtitle),
            seriesID: try c.decodeIfPresent(Int.self, forKey: .seriesID),
            movieID: try c.decodeIfPresent(Int.self, forKey: .movieID),
            httpHeaders: try c.decodeIfPresent([String: String].self, forKey: .httpHeaders),
            catchup: try c.decodeIfPresent(Catchup.self, forKey: .catchup),
            tmdbMetadata: try c.decodeIfPresent(TMDBMetadata.self, forKey: .tmdbMetadata),
            tags: try c.decodeIfPresent([String].self, forKey: .tags))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(playlistID, forKey: .playlistID)
        try c.encode(name, forKey: .name)
        try c.encode(group, forKey: .group)
        try c.encodeIfPresent(logo, forKey: .logo)
        try c.encode(streamURL, forKey: .streamURL)
        try c.encode(kind, forKey: .kind)
        guard case .extras(let extras)? = box else { return }
        try c.encodeIfPresent(extras.backdrop, forKey: .backdrop)
        try c.encodeIfPresent(extras.tvgID, forKey: .tvgID)
        try c.encodeIfPresent(extras.subtitle, forKey: .subtitle)
        try c.encodeIfPresent(extras.seriesID, forKey: .seriesID)
        try c.encodeIfPresent(extras.movieID, forKey: .movieID)
        try c.encodeIfPresent(extras.httpHeaders, forKey: .httpHeaders)
        try c.encodeIfPresent(extras.catchup, forKey: .catchup)
        try c.encodeIfPresent(extras.tmdbMetadata, forKey: .tmdbMetadata)
        try c.encodeIfPresent(extras.tags, forKey: .tags)
    }
}

/// Makes equal strings share one copy. Playlists repeat the same group and logo
/// across thousands of entries. Use one pool per thread.
final class StringPool {
    static let userInfoKey = CodingUserInfoKey(rawValue: "watvu.stringPool")!
    private var seen: Set<String> = []

    func share(_ string: String) -> String {
        // Up to 15 bytes is stored inside the String itself: nothing to share.
        string.utf8.count <= 15 ? string : seen.insert(string).memberAfterInsert
    }
}

/// A channel's catch-up (timeshift) archive.
struct Catchup: Codable, Hashable {
    enum Mode: String, Codable {
        case xtream     // /timeshift/user/pass/minutes/start/id
        case append     // stream URL + filled-in source
        case shift      // stream URL + ?utc=…&lutc=…
        case flussonic  // …/index-<start>-<duration>.m3u8
        case template   // source is a full URL template
    }

    var mode: Mode
    var days: Int
    var source: String? = nil
}

/// A named favorites list; the built-in "Favorites" list is `AppModel.favorites`.
struct FavoriteList: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var itemIDs: [String] = []
}

/// Where playback stopped, for resuming movies and episodes.
struct PlaybackPosition: Codable, Hashable {
    init(seconds: Double, duration: Double, updatedAt: Date? = nil) {
        self.seconds = seconds; self.duration = duration; self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seconds = try c.decode(Double.self, forKey: .seconds)
        duration = try c.decode(Double.self, forKey: .duration)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }


    var seconds: Double
    var duration: Double
    var updatedAt: Date? = nil

    var fraction: Double { duration > 0 ? min(seconds / duration, 1) : 0 }
}

enum LibrarySection: String, CaseIterable, Identifiable, Hashable {
    case home
    case live
    case movies
    case series
    case guide
    case favorites
    case downloads
    case recordings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .live: return "Live TV"
        case .movies: return "Movies"
        case .series: return "Series"
        case .guide: return "TV Guide"
        case .favorites: return "Favorites"
        case .downloads: return "Downloads"
        case .recordings: return "Recordings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .live: return "dot.radiowaves.left.and.right"
        case .movies: return "film"
        case .series: return "tv"
        case .guide: return "calendar"
        case .favorites: return "heart"
        case .downloads: return "arrow.down.circle"
        case .recordings: return "recordingtape"
        }
    }
}

struct SeriesEpisode: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var season: Int
    var number: Int
    var streamURL: String
    var artwork: String? = nil
    var plot: String? = nil
}

struct SeriesSeason: Identifiable, Hashable, Codable {
    var number: Int
    var episodes: [SeriesEpisode]

    var id: Int { number }
}

struct MovieDetail: Identifiable, Hashable, Codable {
    var id: Int
    var title: String
    var plot: String?
    var cast: String?
    var director: String?
    var genre: String?
    var releaseDate: String?
    var rating: Double?
    var duration: String?
    var backdrop: String?
    var poster: String?
    var trailer: String?
}

struct MovieDetailItem: Identifiable {
    var id: String { item.id }
    let item: MediaItem
    let detail: MovieDetail?
}

struct SeriesDetail: Identifiable, Hashable, Codable {
    var id: Int
    var title: String
    var playlistID: UUID
    var seasons: [SeriesSeason]

    var allEpisodes: [SeriesEpisode] { seasons.flatMap(\.episodes) }

    func episode(after id: String) -> SeriesEpisode? {
        let episodes = allEpisodes
        guard let index = episodes.firstIndex(where: { $0.id == id }), index + 1 < episodes.count else { return nil }
        return episodes[index + 1]
    }
}

struct EPGProgram: Identifiable, Codable, Hashable {
    var id: String
    var channelID: String
    var title: String
    var subtitle: String?
    var description: String?
    var category: String?
    var start: Date
    var end: Date

    var timeRange: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: start))–\(formatter.string(from: end))"
    }
}

struct EPGGuide: Codable {
    init(playlistID: UUID = UUID(), updatedAt: Date = Date(), programs: [String: [EPGProgram]] = [:], channelNames: [String: [String]]? = nil) {
        self.playlistID = playlistID; self.updatedAt = updatedAt; self.programs = programs; self.channelNames = channelNames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playlistID = try c.decodeIfPresent(UUID.self, forKey: .playlistID) ?? UUID()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        programs = try c.decodeIfPresent([String: [EPGProgram]].self, forKey: .programs) ?? [:]
        channelNames = try c.decodeIfPresent([String: [String]].self, forKey: .channelNames)
    }


    var playlistID: UUID
    var updatedAt: Date
    var programs: [String: [EPGProgram]]
    /// XMLTV channel id → display names, used for name-based channel matching.
    var channelNames: [String: [String]]? = nil
}

enum AppError: LocalizedError {
    case invalidURL
    case network(String)
    case emptyPlaylist
    case xtream(String)
    case file(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That URL doesn’t look valid."
        case .network(let message):
            return message
        case .emptyPlaylist:
            return "No channels or movies were found in this playlist."
        case .xtream(let message):
            return message
        case .file(let message):
            return message
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? { self?.isEmpty == false ? self : nil }
}

struct TMDBMetadata: Codable, Hashable {
    let id: Int
    let title: String
    let posterPath: String?
    let overview: String
    let voteAverage: Double
    let runtime: Int?
    let releaseDate: String?
    let genres: [String]?
    let trailerKey: String?

    var posterURL: URL? {
        guard let posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(posterPath)")
    }
}

/// Rule-based channel-name clean-up (ChannelExtractor-style, rules only).
enum NameCleaner {
    // Compiled once. Compiling 31 patterns per name made "Group similar"
    // take ~1 s per pass over 11k channels (and it ran on every redraw).
    private static let brackets = try! NSRegularExpression(pattern: "\\s*[\\[\\(][^\\]\\)]*[\\]\\)]")
    private static let tags: NSRegularExpression = {
        let tokens = ["4K", "UHD", "FHD", "HD", "SD", "1080p", "720p", "576p", "480p", "2160p",
                      "HEVC", "x265", "x264", "H.264", "H.265", "H264", "H265", "AAC", "AC3", "EAC3",
                      "WEB-DL", "WEBRip", "BluRay", "BDRip", "HDTV", "DVDRip", "HQ", "LQ"]
        let alternation = tokens.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try! NSRegularExpression(pattern: "\\b(?:" + alternation + ")\\b", options: .caseInsensitive)
    }()
    private static let separators = try! NSRegularExpression(pattern: "[._]+")
    private static let spaces = try! NSRegularExpression(pattern: "\\s+")

    static func cleaned(_ name: String) -> String {
        var n = replace(brackets, in: name, with: "")
        n = replace(tags, in: n, with: "")
        n = replace(separators, in: n, with: " ")
        n = replace(spaces, in: n, with: " ")
        n = n.trimmingCharacters(in: .whitespacesAndNewlines)
        // A name that's all tags or brackets: keep it rather than go blank.
        return n.isEmpty ? name : n
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
