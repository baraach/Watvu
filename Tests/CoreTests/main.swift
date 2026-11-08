import Foundation
import Darwin

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String,
            file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL \(file):\(line): \(message)")
    }
}

func fixture(_ name: String) -> Data {
    let url = URL(fileURLWithPath: "Tests/Fixtures/\(name)")
    return (try? Data(contentsOf: url)) ?? Data()
}

func testM3U() {
    let text = String(data: fixture("sample.m3u"), encoding: .utf8) ?? ""
    let base = URL(string: "https://example.com/lists/main.m3u")!
    let items = M3UParser.parse(text: text, playlistID: UUID(), baseURL: base)
    expect(items.count == 3, "M3U should parse 3 entries, got \(items.count)")
    let news = items.first { $0.name == "BBC News HD" }
    expect(news?.tvgID == "news.1", "unquoted tvg-id should parse")
    expect(news?.group == "News", "quoted group should parse")
    expect(news?.httpHeaders?["User-Agent"] == "Kodi/21", "KODIPROP stream headers should parse")
    expect(news?.httpHeaders?["Referer"] == "https://example.com/", "KODIPROP referer should parse")
    expect(news?.catchup?.days == 7, "catchup-days default should apply")
    let sports = items.first { $0.name == "Sky Sports" }
    expect(sports?.group == "Sports", "#EXTGRP should apply to the next entry")
    let movie = items.first { $0.name == "A Movie" }
    expect(movie?.group == "Movies", "#EXTGRP must not leak into the next entry")
    expect(movie?.kind == .movie, "relative .mp4 should infer a movie")
    expect(movie?.streamURL == "https://example.com/lists/relative/movie.mp4",
           "relative URL should resolve against the playlist, got \(movie?.streamURL ?? "nil")")

    let noBase = M3UParser.parse(text: text, playlistID: UUID())
    expect(noBase.count == 2, "relative streams without a base should be skipped")
}

func testEPG() {
    let plain = (try? EPGParser.parse(data: fixture("sample.xml"))) ?? [:]
    expect(plain["news.1"]?.count == 2, "plain XMLTV should parse 2 news programmes")
    expect(plain["sports.1"]?.first?.title == "Match Day", "sports programme should parse")
    expect(plain["news.1"]?.first?.description == "The midday bulletin.", "description should parse")

    let result = try? EPGParser.parseGuide(data: fixture("sample.xml.gz"))
    expect(result?.programs["news.1"]?.count == 2, "gzip XMLTV should parse")
    expect(result?.channelNames["news.1"]?.first == "BBC News HD", "channel display names should parse")

    let names = result?.channelNames ?? [:]
    expect(EPGMatch.channelID(for: "BBC News HD", channelNames: names) == "news.1",
           "name fallback should match quality suffix")
    expect(EPGMatch.channelID(for: "Sky Sports Main Event", channelNames: names) == "sports.1",
           "name fallback should match display name")
    expect(EPGMatch.channelID(for: "Unknown Channel", channelNames: names) == nil,
           "unknown channel should not match")
}

func testCatchup() {
    let start = Date(timeIntervalSince1970: 1_767_268_800) // 2026-01-01 12:00 UTC
    let end = start.addingTimeInterval(3600)
    let template = CatchupURL.fill("?utc={utc}&lutc={lutc}&dur={duration}", start: start, end: end)
    expect(template.contains("utc=1767268800"), "catch-up utc placeholder")
    expect(template.contains("dur=3600"), "catch-up duration placeholder")

    var channel = MediaItem(
        id: "test", playlistID: UUID(), name: "Test", group: "News",
        streamURL: "http://host/live/user/pass/123.m3u8", kind: .live,
        tvgID: nil, subtitle: nil
    )
    channel.catchup = Catchup(mode: .xtream, days: 7)
    let program = EPGProgram(
        id: "p", channelID: "c", title: "Show", subtitle: nil,
        description: nil, category: nil, start: start, end: end
    )
    let url = CatchupURL.url(for: channel, program: program, timeZone: TimeZone(secondsFromGMT: 0)!)
    expect(url?.absoluteString.contains("/timeshift/user/pass/60/2026-01-01:12-00/123.m3u8") == true,
           "Xtream catch-up URL shape, got \(url?.absoluteString ?? "nil")")
}

func testM3UEdgeCases() {
    let text = """
    #EXTM3U
    #EXTVLCOPT:http-user-agent=EarlyAgent/1
    #EXTINF:-1 tvg-id="w.1" group-title="News, Weather",News, Weather & Sport
    http://example.com/a.m3u8|Cookie=a=1&b=2&Referer=https://r.example/?x=1
    #EXTINF:-1 group-title="Misc",Show a=b
    http://example.com/b.m3u8
    """
    let items = M3UParser.parse(text: text, playlistID: UUID())
    expect(items.count == 2, "edge-case M3U should parse 2 entries, got \(items.count)")
    let first = items.first
    expect(first?.name == "News, Weather & Sport", "comma in title should survive, got \(first?.name ?? "nil")")
    expect(first?.group == "News, Weather", "comma in quoted group should survive")
    expect(first?.httpHeaders?["User-Agent"] == "EarlyAgent/1", "#EXTVLCOPT before #EXTINF should apply")
    expect(first?.httpHeaders?["Cookie"] == "a=1&b=2", "& inside a cookie value should not split, got \(first?.httpHeaders?["Cookie"] ?? "nil")")
    expect(first?.httpHeaders?["Referer"] == "https://r.example/?x=1", "referer after cookie should parse")
    let second = items.last
    expect(second?.name == "Show a=b", "= in title should stay in the title")
    expect(second?.httpHeaders == nil, "headers must not leak into the next entry")
}

func testNameIndex() {
    let names = ["a": ["Channel One HD"], "b": ["Channel One"], "c": ["Unique TV"]]
    let index = EPGNameIndex(names)
    expect(index.channelID(for: "Channel One") == nil, "ambiguous names should not match")
    expect(index.channelID(for: "unique tv fhd") == "c", "index should match normalised names")

    var many: [String: [String]] = [:]
    for i in 0..<3000 { many["ch\(i)"] = ["Channel \(i) HD", "Channel \(i)"] }
    let big = EPGNameIndex(many)
    let start = Date()
    for i in 0..<3000 { _ = big.channelID(for: "Channel \(i)") }
    let elapsed = Date().timeIntervalSince(start)
    expect(elapsed < 0.5, "3000 lookups should be fast, took \(elapsed)s")
}

func testXtreamImages() {
    let client = XtreamClient(server: "http://host:80", username: "u", password: "p")
    expect(client?.firstImage(["", "https://img/b.jpg"]) == "https://img/b.jpg", "array backdrop should pick first non-empty")
    expect(client?.firstImage("https://img/p.jpg") == "https://img/p.jpg", "string image should parse")
    expect(client?.firstImage(nil) == nil, "missing image should be nil")
}

testM3U()
testM3UEdgeCases()
testEPG()
testNameIndex()
testXtreamImages()
testCatchup()

func testCleanUpNames() {
    expect(NameCleaner.cleaned("BBC News HD [1080p]") == "BBC News", "quality tags stripped")
    expect(NameCleaner.cleaned("Sky.Sports.F1.HD") == "Sky Sports F1", "dots become spaces")
    expect(NameCleaner.cleaned("Channel (HEVC) (UK)") == "Channel", "brackets stripped")
    expect(NameCleaner.cleaned("  Movie  WEB-DL  ") == "Movie", "trimmed")
    expect(NameCleaner.cleaned("(The Hook Up Plan)") == "(The Hook Up Plan)", "all-bracket name isn't blanked")
}

// B48/B43: old saved files (without newer fields) must still decode.
// Uses the app's date strategy so `addedAt` parses.
enum TestDecoder {
    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
do {
    let oldPlaylist = #"{"name":"Demo","kind":"m3u","url":"https://x/list.m3u","username":"","password":"","epgURL":null,"addedAt":"2026-01-01T00:00:00Z"}"#
    let p = try TestDecoder.makeDecoder().decode(Playlist.self, from: Data(oldPlaylist.utf8))
    expect(p.name == "Demo" && p.order == 0 && p.apiKey == "" && p.libraries.isEmpty, "old playlists.json must decode with defaults")
    let oldItem = #"{"id":"a","playlistID":"00000000-0000-0000-0000-000000000000","name":"Ch","group":"G","streamURL":"https://x/a.m3u8","kind":"live"}"#
    let m = try TestDecoder.makeDecoder().decode(MediaItem.self, from: Data(oldItem.utf8))
    expect(m.tmdbMetadata == nil, "old items.json must decode without tmdbMetadata")
    let oldPos = #"{"seconds":12.0,"duration":3600.0}"#
    let pp = try TestDecoder.makeDecoder().decode(PlaybackPosition.self, from: Data(oldPos.utf8))
    expect(pp.updatedAt == nil, "old positions.json must decode without updatedAt")
} catch {
    expect(false, "B43 decode failed: \(error)")
}


// Customisation: rule-based name clean-up
testCleanUpNames()

// Playback engine choice (mpv fallback)
func testEnginePicker() {
    expect(EnginePicker.needsMPV(url: URL(string: "http://h/movie/u/p/1.mkv")!), ".mkv goes to mpv")
    expect(EnginePicker.needsMPV(url: URL(string: "http://h/x.AVI")!), "extension check ignores case")
    expect(!EnginePicker.needsMPV(url: URL(string: "http://h/live/1.m3u8")!), "HLS stays on AVPlayer")
    expect(EnginePicker.engine(playlistOverride: .mpv) == .mpv, "playlist override wins")
    var playlist = Playlist(name: "P", kind: .m3u)
    playlist.engineOverride = .avplayer
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let data = (try? encoder.encode(playlist)) ?? Data()
    let back = try? TestDecoder.makeDecoder().decode(Playlist.self, from: data)
    expect(back?.engineOverride == .avplayer, "engine override survives save/load")
}
testEnginePicker()

// Loaded subtitle files (.srt / .vtt) and the delay lookup
func testSubtitles() {
    let srt = "1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Hello</i>\r\n\r\n2\r\n00:00:04,000 --> 00:00:06,000\r\n{\\an8}Line one\r\nLine two\r\n"
    let cues = SubtitleParser.parse(text: srt)
    expect(cues.count == 2, "SRT should parse 2 cues, got \(cues.count)")
    expect(cues.first?.text == "Hello", "tags stripped, got \(cues.first?.text ?? "nil")")
    expect(cues.last?.text == "Line one\nLine two", "multi-line cue and {\\an8} stripped")
    expect(SubtitleParser.cue(at: 2, in: cues)?.text == "Hello", "cue at 2 s")
    expect(SubtitleParser.cue(at: 3.7, in: cues) == nil, "gap between cues")
    // A +2 s delay shows the 1–3.5 s cue at 4 s on the video clock.
    expect(SubtitleParser.cue(at: 4 - 2, in: cues)?.text == "Hello", "delay shifts lookup")
    let vtt = "WEBVTT\n\nintro\n00:01.500 --> 00:02.000 align:start\nHi\n"
    let v = SubtitleParser.parse(text: vtt)
    expect(v.count == 1 && v.first?.start == 1.5 && v.first?.end == 2, "VTT short times and cue settings")
    expect(SubtitleParser.time("01:02:03,250") == 3723.25, "hh:mm:ss,ms")
}
testSubtitles()

// Google Cast message encoding (hand-written protobuf + length prefix)
func testCastProtocol() {
    let message = CastMessage(source: "sender-0", destination: "receiver-0",
                              namespace: CastMessage.Namespace.receiver,
                              payload: #"{"type":"LAUNCH","appId":"CC1AD845","requestId":1}"#)
    let frame = message.framed()
    expect(CastMessage.frameLength(frame) == frame.count - 4, "length prefix matches body")
    let decoded = CastMessage.decode(frame.dropFirst(4))
    expect(decoded == message, "Cast message round-trips")
    // Known bytes from the Cast spec layout: version 0 then field 2 "sender-0".
    expect(Array(message.encoded().prefix(4)) == [0x08, 0x00, 0x12, 0x08], "protobuf field order and tags")
    var big = Data(); CastMessage.appendVarint(300, to: &big)
    var i = 0
    expect(Array(big) == [0xAC, 0x02] && CastMessage.readVarint(Array(big), &i) == 300, "varint 300")
    let long = CastMessage(source: "a", destination: "b", namespace: "c", payload: String(repeating: "x", count: 1000))
    expect(CastMessage.decode(long.encoded())?.payload.count == 1000, "multi-byte length")
    expect(CastContentType.forURL(URL(string: "http://h/live/1.m3u8")!) == "application/x-mpegURL", "HLS content type")
    expect(CastContentType.forURL(URL(string: "http://h/movie/1.mp4")!) == "video/mp4", "MP4 content type")
}
testCastProtocol()

// Media servers: responses as the Jellyfin/Emby and Plex APIs return them
func testMediaServers() {
    let page = #"{"Items":[{"Name":"Big Buck","Id":"abc","Type":"Movie","ProductionYear":2008,"ImageTags":{"Primary":"t1"},"BackdropImageTags":["b1"],"Container":"mkv"},{"Name":"Show","Id":"s1","Type":"Series"}],"TotalRecordCount":2}"#
    let items = (try? JSONDecoder().decode(MediaServerPage<MediaServerItem>.self, from: Data(page.utf8)))?.items
    expect(items?.count == 2 && items?.first?.id == "abc" && items?.first?.year == 2008, "Jellyfin items decode")
    expect(items?.first?.imageTags?["Primary"] == "t1" && items?.last?.type == "Series", "Jellyfin tags and types")
    let client = MediaServerClient(baseURL: URL(string: "http://h:8096/jf")!, token: "tok", userID: "u1")
    let stream = client.streamURL(itemID: "abc").absoluteString
    expect(stream.hasPrefix("http://h:8096/jf/Videos/abc/master.m3u8?") && stream.contains("api_key=tok"), "Jellyfin stream is HLS on the server, got \(stream)")
    expect(client.imageURL(itemID: "abc", type: "Primary", tag: "t1") == "http://h:8096/jf/Items/abc/Images/Primary?tag=t1", "Jellyfin image URL")

    let plexJSON = #"{"MediaContainer":{"size":2,"Metadata":[{"ratingKey":"10","title":"Clip","type":"movie","year":2020,"thumb":"/library/metadata/10/thumb/1","Media":[{"container":"mp4","Part":[{"key":"/library/parts/1/file.mp4"}]}]},{"ratingKey":"11","title":"Film","type":"movie","Media":[{"container":"mkv","Part":[{"key":"/library/parts/2/file.mkv"}]}]}]}}"#
    struct Wrapper: Decodable { let MediaContainer: PlexContainer }
    let meta = (try? JSONDecoder().decode(Wrapper.self, from: Data(plexJSON.utf8)))?.MediaContainer.metadata ?? []
    expect(meta.count == 2 && meta.first?.media?.first?.parts?.first?.key == "/library/parts/1/file.mp4", "Plex metadata decodes")
    let plex = PlexClient(serverURL: URL(string: "http://h:32400")!, token: "tok")
    if meta.count == 2 {
        expect(plex.streamURL(for: meta[0]) == "http://h:32400/library/parts/1/file.mp4?X-Plex-Token=tok", "Plex MP4 plays directly")
        let hls = plex.streamURL(for: meta[1])
        expect(hls.hasPrefix("http://h:32400/video/:/transcode/universal/start.m3u8?") && hls.contains("X-Plex-Token=tok"), "Plex MKV goes through the transcoder, got \(hls)")
    }
    expect(plex.imageURL("/thumb/1") == "http://h:32400/thumb/1?X-Plex-Token=tok", "Plex image URL")
    let empty = #"{"MediaContainer":{"size":0}}"#
    expect((try? JSONDecoder().decode(Wrapper.self, from: Data(empty.utf8)))?.MediaContainer.metadata.isEmpty == true, "Empty Plex library decodes")
}
testMediaServers()

// Library index: real M3U series naming patterns, grouping, filtering
func testLibraryIndex() {
    func parsed(_ name: String) -> String {
        guard let e = EpisodeName.parse(name) else { return "nil" }
        return "\(e.show)|\(e.season)|\(e.episode)"
    }
    expect(parsed("AR: Blue Bloods S04 Blue Bloods.S04.E07") == "AR: Blue Bloods|4|7", "show S04 file.S04.E07, got \(parsed("AR: Blue Bloods S04 Blue Bloods.S04.E07"))")
    expect(parsed("The Future Diary S01 The.Future.Diary.S01E10") == "The Future Diary|1|10", "S01E10 ending")
    expect(parsed("S01 Plan Coeur S01 E01") == "Plan Coeur|1|1", "leading season removed, got \(parsed("S01 Plan Coeur S01 E01"))")
    expect(parsed("AR: Outlander S03 outlander.S03.S05") == "AR: Outlander|3|5", "episode written as S05")
    expect(parsed("Marvels Agents of S.H.I.E.L.D. S06 AgentsOfShield-Ar.S06.E02") == "Marvels Agents of S.H.I.E.L.D.|6|2", "dots in the show name")
    expect(parsed("Some Show S02E03") == "Some Show|2|3", "plain S02E03")
    expect(parsed("A Movie Name") == "nil", "no season or episode")

    let playlist = UUID()
    func entry(_ name: String, _ kind: MediaKind, url: String = "http://h/x.mp4", group: String = "G") -> MediaItem {
        MediaItem(id: name, playlistID: playlist, name: name, group: group, streamURL: url, kind: kind)
    }
    let items = [
        entry("b Show S01 b.S01.E02", .series), entry("b Show S01 b.S01.E01", .series), entry("b Show S02 b.S02.E01", .series),
        entry("Áa Film", .movie), entry("c film", .movie, group: "H"), entry("Ch 1", .live),
        entry("Xtream Show", .series, url: ""),
    ]
    let index = LibraryIndex(items: items)
    expect(index.shows.count == 2, "episodes group into shows, got \(index.shows.count)")
    let show = index.shows.first { $0.name == "b Show" }
    expect(show?.subtitle == "3 episodes" && show?.streamURL == "", "show card")
    let seasons = index.seasons(ofShow: show?.id ?? "")
    expect(seasons.map(\.number) == [1, 2] && seasons.first?.episodes.map(\.number) == [1, 2], "seasons and episodes in order")
    expect(index.movies.first?.name == "Áa Film", "sort ignores case and accents")
    expect(index.item(id: "Ch 1")?.kind == .live && index.item(id: show?.id ?? "")?.name == "b Show", "lookup by ID")
    expect(index.itemCounts[playlist] == 7, "item count per playlist")

    var query = LibraryQuery(kind: .movie)
    expect(query.run(on: index).count == 2, "kind filter")
    query.group = "H"
    expect(query.run(on: index).map(\.name) == ["c film"], "group filter")
    query = LibraryQuery(kind: nil, hiddenIDs: ["Ch 1"], search: "FILM")
    expect(query.run(on: index).count == 2, "search is case-insensitive")
    query = LibraryQuery(kind: .live, hiddenIDs: ["Ch 1"])
    expect(query.run(on: index).isEmpty, "hidden items stay out")
}
testLibraryIndex()

// Reading a saved library in parallel gives the same result as reading it whole
func testLibraryFile() {
    let playlist = UUID()
    var source: [MediaItem] = []
    for i in 0..<40_000 {
        source.append(MediaItem(id: "id\(i)", playlistID: playlist, name: "Name \"q\" , ] } { [ \\ \(i)", group: "G,\(i % 7)",
                                streamURL: "http://h/\(i).m3u8?a=1,b=[2]", kind: i % 2 == 0 ? .live : .movie,
                                httpHeaders: i % 5 == 0 ? ["User-Agent": "x,y"] : nil))
    }
    let encoder = JSONEncoder()
    let data = (try? encoder.encode(source)) ?? Data()
    expect(data.count > 1_000_000, "fixture is big enough to split")
    let ranges = LibraryFile.itemRanges(in: data, parts: 8)
    expect(ranges.count > 1, "splits into several parts, got \(ranges.count)")
    let read = LibraryFile.decode(data) ?? []
    expect(read.count == source.count, "keeps every item, got \(read.count)")
    expect(read.map(\.id) == source.map(\.id), "keeps the order")
    expect(read[7].name == source[7].name && read[5].httpHeaders == source[5].httpHeaders, "fields survive the split")
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let pretty = (try? encoder.encode(Array(source.prefix(12_000)))) ?? Data()
    expect(LibraryFile.decode(pretty)?.count == 12_000, "older pretty-printed files still read")
    expect(LibraryFile.decode(Data("[]".utf8))?.isEmpty == true, "empty library")
    expect(LibraryFile.decode(Data("not json".utf8)) == nil, "bad file doesn't crash")
    expect(LibraryFile.itemRanges(in: Data("{\"a\":1}".utf8), parts: 2).isEmpty, "not an array: no split")

    let index = LibraryIndex(items: source) { var c = $0; c.group = "X"; return c }
    expect(index.live.count == 20_000 && index.movies.count == 20_000 && index.groups[.live] == ["X"], "parallel index applies overrides")
    expect(index.item(id: "id39999")?.id == "id39999" && index.movies.first != nil, "parallel index lookups")
}
testLibraryFile()

func testMemoryShape() {
    expect(MemoryLayout<MediaItem>.stride <= 112, "items stay small, got \(MemoryLayout<MediaItem>.stride) bytes")
    let playlist = UUID()
    let plain = MediaItem(id: "a", playlistID: playlist, name: "A", group: "G", streamURL: "http://h/a", kind: .movie)
    var rich = plain
    rich.backdrop = "http://h/b.jpg"; rich.tvgID = "t"; rich.subtitle = "s"; rich.seriesID = 7; rich.movieID = 8
    rich.httpHeaders = ["User-Agent": "x"]; rich.tags = ["one"]
    rich.catchup = Catchup(mode: .shift, days: 3, source: nil)
    expect(rich != plain, "extras count towards equality")
    expect(rich.hashValue != plain.hashValue, "extras count towards the hash")
    var cleared = rich
    cleared.backdrop = nil; cleared.tvgID = nil; cleared.subtitle = nil; cleared.seriesID = nil; cleared.movieID = nil
    cleared.httpHeaders = nil; cleared.tags = nil; cleared.catchup = nil
    expect(cleared == plain, "clearing every extra matches an item that never had any")
    expect(rich.seriesID == 7 && rich.tags == ["one"], "copies don't share changes")

    // The saved format is unchanged: plain items list only what they have.
    let plainJSON = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(plain))) as? [String: Any]
    expect(Set(plainJSON?.keys.map { $0 } ?? []) == ["id", "playlistID", "name", "group", "streamURL", "kind"],
           "empty fields aren't saved, got \(plainJSON?.keys.sorted() ?? [])")
    let back = try? JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(rich))
    expect(back == rich, "every field survives saving and loading")
    let oldStyle = Data("""
    {"id":"x","name":"X","streamURL":"u","seriesID":4,"subtitle":"sub","logo":"l","tags":["t"]}
    """.utf8)
    let old = try? JSONDecoder().decode(MediaItem.self, from: oldStyle)
    expect(old?.seriesID == 4 && old?.subtitle == "sub" && old?.tags == ["t"] && old?.group == "" && old?.kind == .live,
           "older files still read")

    // Repeated groups and logos share one copy.
    let pool = StringPool()
    let long = "https://example.com/logos/a-rather-long-logo-name.png"
    let copy = String(long.utf8.map { Character(UnicodeScalar($0)) })
    let one = pool.share(long), two = pool.share(copy)
    let address: (String) -> UInt? = { $0.utf8.withContiguousStorageIfAvailable { UInt(bitPattern: $0.baseAddress) } ?? nil }
    expect(one == long && two == long, "sharing keeps the text")
    expect(address(one) == address(two), "equal strings share storage")
    expect(pool.share("short") == "short", "short strings pass through")

    // Episode lookups still apply overrides without storing a second copy.
    let episodes = (1...3).map { MediaItem(id: "e\($0)", playlistID: playlist, name: "Show S01E0\($0)", group: "G",
                                           logo: "old", streamURL: "http://h/\($0)", kind: .series) }
    let index = LibraryIndex(items: episodes) { var c = $0; c.logo = "new"; return c }
    let show = index.shows.first?.id ?? ""
    expect(index.isGroupedShow(show) && !index.isGroupedShow("e1"), "grouped shows are known")
    let season = index.seasons(ofShow: show).first
    expect(season?.episodes.map(\.number) == [1, 2, 3], "episodes in order")
    expect(season?.episodes.first?.artwork == "new", "overrides reach episodes")
    expect(index.item(id: "e2")?.streamURL == "http://h/2", "items found by ID")
}

testMemoryShape()

print("\(checks) checks, \(failures) failure\(failures == 1 ? "" : "s")")
exit(failures == 0 ? 0 : 1)

