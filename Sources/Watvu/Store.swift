import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var playlists: [Playlist] = []
    @Published var items: [MediaItem] = [] { didSet { groupsCache.removeAll(); scheduleIndexRebuild() } }
    /// Sorted view of `items`, rebuilt off the main thread when they change.
    @Published private(set) var libraryIndex = LibraryIndex()
    /// The add or refresh in progress, shown as the "Syncing playlist" card.
    @Published var sync: SyncSession?
    private var indexGeneration = 0
    private var indexTask: Task<Void, Never>?
    private let persistQueue = DispatchQueue(label: "Watvu.persist", qos: .utility)
    @Published var favorites: Set<String> = [] { didSet { groupsCache.removeAll() } }
    @Published var favoriteLists: [FavoriteList] = [] { didSet { groupsCache.removeAll() } }
    @Published var watched: Set<String> = []
    /// Favorites page filter: a named list, or nil for the main Favorites.
    @Published var favoriteListFilter: UUID? { didSet { groupsCache.removeAll() } }
    @Published var recent: [String] = []
    @Published var positions: [String: PlaybackPosition] = [:]

    @Published var selection: LibrarySection = .home
    @Published var searchText: String = ""
    /// Debounced copy used for filtering (PERF: don't scan the whole library per keystroke).
    @Published private(set) var effectiveSearchText: String = ""
    private var searchDebounce: Task<Void, Never>?

    func setSearchText(_ text: String) {
        searchText = text
        searchDebounce?.cancel()
        searchDebounce = Task {
            try? await Task.sleep(for: .milliseconds(150))
            await MainActor.run { self.effectiveSearchText = text }
        }
    }
    @Published var selectedGroup: String = "All"
    @Published var playlistFilter: UUID? { didSet { groupsCache.removeAll() } }

    /// False until saved data is read, so the welcome screen doesn't flash.
    @Published var hasLoadedLibrary = false
    @Published var isLoading = false
    @Published var statusText = ""
    @Published var errorMessage: String?

    @Published var playingItem: MediaItem?
    @Published var pendingUnlock: MediaItem?   // B47 PIN prompt target
    @Published var channelHistory: [String] = []   // zap history (most recent first)
    @Published var overrides: [String: ItemOverride] = [:] { didSet { groupsCache.removeAll(); scheduleIndexRebuild() } }   // customisation overrides
    /// `groups(kind:favoritesOnly:)` results. Every card's context menu asks
    /// for them, and each call scanned the whole library.
    private var groupsCache: [String: [String]] = [:]
    @Published var trending: [TMDBMovie] = []   // TMDB trending feed
    @Published var popularTV: [TMDBTV] = []   // TMDB popular TV feed
    @Published var recommended: [TMDBMovie] = []   // "Because you watch…" feed
    @Published var homeFeeds: [HomeFeed] = []          // user-defined Home shelves
    @Published var feedResults: [UUID: [FeedEntry]] = [:]
    @Published var feedErrors: [UUID: String] = [:]
    @Published var unlockAfterPin = false   // B47: PIN prompt unlocks instead of playing
    /// The series the playing episode belongs to (for "next episode").
    @Published var playingSeries: SeriesDetail?
    @Published var movieDetailItem: MovieDetailItem?
    /// Set while playing an archive programme, so the player can switch back.
    @Published var catchupSource: MediaItem?
    @Published var catchupProgram: EPGProgram?
    @Published var seriesDetail: SeriesDetail?

    @Published var epgByPlaylist: [UUID: [String: [EPGProgram]]] = [:]
    @Published var epgChannelNames: [UUID: [String: [String]]] = [:] {
        didSet { epgNameIndexes = epgChannelNames.mapValues { EPGNameIndex($0) } }
    }
    /// Name-fallback lookup per playlist, rebuilt only when guides change.
    private var epgNameIndexes: [UUID: EPGNameIndex] = [:]
    @Published var epgUpdatedAt: [UUID: Date] = [:]
    @Published var epgStatus: String?

    private let fileManager = FileManager.default
    /// False only if Keychain writes fail; then JSON keeps the password as a
    /// fallback so the user's playlist still works.
    private var credentialsInKeychain = true
    private var scheduledRefreshTask: Task<Void, Never>?
    private var tmdbClient: TMDBClient? = nil
    /// TMDB key for requests made outside `TMDBClient` (Home feeds).
    var tmdbAPIKey: String? {
        let key = CredentialStore.secret(forAccount: "tmdb.apiKey") ?? UserDefaults.standard.string(forKey: "tmdbApiKey") ?? ""
        return key.isEmpty ? nil : key
    }

    var baseDirectory: URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("Watvu", isDirectory: true)
        // The app has had other names: keep the library from the old folder.
        if !fileManager.fileExists(atPath: dir.path) {
            for old in ["Vumqel", "UHFMac"] {
                let oldDir = support.appendingPathComponent(old, isDirectory: true)
                if fileManager.fileExists(atPath: oldDir.path) {
                    try? fileManager.moveItem(at: oldDir, to: dir)
                    break
                }
            }
        }
        return dir
    }

    private var playlistsURL: URL { baseDirectory.appendingPathComponent("playlists.json") }
    private var itemsURL: URL { baseDirectory.appendingPathComponent("items.json") }
    private func itemsFileURL(_ id: UUID) -> URL { baseDirectory.appendingPathComponent("items-\(id.uuidString).json") }
    private var favoritesURL: URL { baseDirectory.appendingPathComponent("favorites.json") }
    private var recentURL: URL { baseDirectory.appendingPathComponent("recent.json") }
    private var favoriteListsURL: URL { baseDirectory.appendingPathComponent("favorite-lists.json") }
    private var positionsURL: URL { baseDirectory.appendingPathComponent("positions.json") }
    private var watchedURL: URL { baseDirectory.appendingPathComponent("watched.json") }

    private func epgFileURL(_ id: UUID) -> URL {
        baseDirectory.appendingPathComponent("epg-\(id.uuidString).json")
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        playlists = load([Playlist].self, from: playlistsURL) ?? []
        // B59: items live in per-playlist files now; migrate the old monolith.
        if let old = load([MediaItem].self, from: itemsURL) {
            var ok = true
            for playlist in playlists {
                let sub = old.filter { $0.playlistID == playlist.id }
                if !sub.isEmpty {
                    write(sub, to: itemsFileURL(playlist.id))
                    if load([MediaItem].self, from: itemsFileURL(playlist.id))?.count != sub.count { ok = false }   // B67: verify read-back
                }
            }
            if ok { try? fileManager.removeItem(at: itemsURL) }   // only when every file verified
            items = old
        } else {
            // Off the main thread: a big playlist's file takes seconds to decode.
            let files = playlists.map { itemsFileURL($0.id) }
            items = await Task.detached(priority: .userInitiated) {
                files.flatMap { url in
                    // Mapped: the file's bytes never count as the app's memory.
                    (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap(LibraryFile.decode) ?? []
                }
            }.value
        }
        favorites = Set(load([String].self, from: favoritesURL) ?? [])
        recent = load([String].self, from: recentURL) ?? []
        favoriteLists = load([FavoriteList].self, from: favoriteListsURL) ?? []
        positions = load([String: PlaybackPosition].self, from: positionsURL) ?? [:]
        watched = load(Set<String>.self, from: watchedURL) ?? []
        channelHistory = load([String].self, from: baseDirectory.appendingPathComponent("channel-history.json")) ?? []
        migrateLibraryFormat()
        overrides = load([String: ItemOverride].self, from: baseDirectory.appendingPathComponent("customisation.json")) ?? [:]
        hydrateAPIKeys()
        if hydrateCredentials() { save() }
        
        // Initialize TMDB client with API key from settings
        let apiKey = CredentialStore.secret(forAccount: "tmdb.apiKey") ?? UserDefaults.standard.string(forKey: "tmdbApiKey") ?? ""
        if !apiKey.isEmpty {
            tmdbClient = TMDBClient(apiKey: apiKey)
            // PERF: defer metadata feeds until after first paint.
            Task {
                try? await Task.sleep(for: .seconds(2))
                await fetchTrending(); await fetchPopularTV(); await fetchRecommendations()
            }
        }

        // Guides can be large: decode them off the main thread too.
        let guideFiles = playlists.map { ($0.id, epgFileURL($0.id)) }
        let guides = await Task.detached(priority: .userInitiated) {
            guideFiles.compactMap { id, url in Self.decode(EPGGuide.self, from: url).map { (id, $0) } }
        }.value
        for (id, guide) in guides {
            epgByPlaylist[id] = guide.programs
            epgChannelNames[id] = guide.channelNames ?? [:]
            epgUpdatedAt[id] = guide.updatedAt
        }
        await libraryIndexIsReady()
        hasLoadedLibrary = true
        loadHomeFeeds()
        Task { await refreshAllFeeds() }

        if UserDefaults.standard.string(forKey: SettingsKeys.launchSection) == "lastWatched" {
            selection = .home
            if let first = recentItems.first { play(first) }
            return
        }
        if let saved = UserDefaults.standard.string(forKey: SettingsKeys.launchSection),
           let section = LibrarySection(rawValue: saved) {
            selection = section
        }

        applyDeveloperArguments()
        startScheduledRefresh()
        Task { await refreshStaleGuidesOnLaunch() }
    }

    /// Refreshes guides every 6 hours and the playlists themselves once a day
    /// while the app is running. Closing the app cancels the loop.
    private func startScheduledRefresh() {
        guard scheduledRefreshTask == nil else { return }
        scheduledRefreshTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 3600))
                guard let self, !Task.isCancelled else { return }
                await self.refreshEPG()
                ticks += 1
                if ticks % 4 == 0 {
                    // Per-playlist cadence (0 = manual).
                    let defaults = UserDefaults.standard
                    for playlist in self.playlists where playlist.refreshIntervalDays > 0 {
                        let key = "lastRefresh.\(playlist.id)"
                        let last = defaults.object(forKey: key) as? Date ?? .distantPast
                        if Date().timeIntervalSince(last) >= Double(playlist.refreshIntervalDays) * 86400 {
                            await self.refresh(playlist, showsProgress: false)
                            defaults.set(Date(), forKey: key)
                        }
                    }
                }
            }
        }
    }

    private func refreshStaleGuidesOnLaunch() async {
        for playlist in playlists where !playlist.guideSources.isEmpty {
            if let updated = epgUpdatedAt[playlist.id],
               Date().timeIntervalSince(updated) < 6 * 3600 {
                continue
            }
            await fetchEPG(for: playlist)
        }
    }

    /// Developer launch flags (for demos and screenshots):
    /// `--autoplay` plays the first item,
    /// `--section <name>` opens a page, `--search <text>` pre-fills search.
    private func applyDeveloperArguments() {
        let arguments = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        if arguments.contains("--autoplay"), let first = items.first {
            playingItem = first
        }
        if let section = value(after: "--section").flatMap(LibrarySection.init(rawValue:)) {
            selection = section
        }
        if arguments.contains("--movie"), let movie = items.first(where: { $0.kind == .movie }) {
            Task { await loadMovie(movie) }
        }
        if let query = value(after: "--search") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.searchText = query
            }
        }
    }

    /// Moves plaintext passwords into Keychain and restores blank ones on load.
    /// Returns true when the JSON should be rewritten without passwords.
    private func hydrateCredentials() -> Bool {
        var needsSave = false
        for index in playlists.indices {
            let id = playlists[index].id
            if !playlists[index].password.isEmpty {
                if CredentialStore.setPassword(playlists[index].password, for: id) {
                    needsSave = true
                } else {
                    credentialsInKeychain = false
                }
            } else if let stored = CredentialStore.password(for: id) {
                playlists[index].password = stored
            }
        }
        return needsSave
    }

    /// True when an Xtream password couldn't be read back (e.g. Keychain
    /// access denied after the app's signature changed).
    func needsPassword(_ playlist: Playlist) -> Bool {
        playlist.kind == .xtream && playlist.password.isEmpty
    }

    private func missingPasswordMessage(_ playlist: Playlist) -> String {
        "The password for “\(playlist.name)” couldn’t be read from the Keychain. Re-enter it in Settings → Playlists."
    }

    func updatePassword(_ password: String, for playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }), !password.isEmpty else { return }
        playlists[index].password = password
        if !CredentialStore.setPassword(password, for: playlistID) {
            credentialsInKeychain = false
        }
        save()
    }

    // MARK: - Playlist import

    func addM3U(name: String, urlString: String, epgURL: String = "") async throws {
        guard let url = Self.normalizedURL(urlString) else { throw AppError.invalidURL }
        sync = SyncSession(title: "Syncing playlist", steps: Self.m3uSteps)
        sync?.start(SyncStep.checkLink)
        let resolvedName = name.trimmed.isEmpty ? (url.host ?? "M3U Playlist") : name.trimmed
        var playlist = Playlist(name: resolvedName, kind: .m3u, url: url.absoluteString)
        sync?.start(SyncStep.download)
        // B60: stream the download and parse line by line — no full text in memory.
        let parsed = try await parseM3U(url, playlistID: playlist.id)
        if epgURL.trimmed.isEmpty, let detected = await Self.sniffEPGURL(from: url) {
            playlist.epgURL = detected
        } else if !epgURL.trimmed.isEmpty {
            playlist.epgURL = epgURL.trimmed
        }
        guard !parsed.isEmpty else { throw AppError.emptyPlaylist }
        playlists.append(playlist)
        items.append(contentsOf: parsed)
        itemsDirtyPlaylist = playlist.id
        save()
        await finishSync(summaryFor: playlist.id)
        Task { await fetchEPG(for: playlist) }
    }

    private func parseM3U(_ url: URL, playlistID: UUID) async throws -> [MediaItem] {
        let session = sync
        return try await Task.detached(priority: .userInitiated) {
            try await M3UParser.parseStream(from: url, playlistID: playlistID) { count in
                Task { @MainActor in session?.detail = String(format: L("%@ items so far"), count.formatted()) }
            }
        }.value
    }

    /// Reads just the first bytes of a playlist URL to find `url-tvg` (B60).
    private static func sniffEPGURL(from url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-16383", forHTTPHeaderField: "Range")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return EPGParser.epgURL(in: String(decoding: data, as: UTF8.self))
    }

    /// B71: backend API tokens live in the Keychain, not in playlists.json.
    private func hydrateAPIKeys() {
        for index in playlists.indices {
            // Older files kept the server token here: move it to the Keychain.
            if !playlists[index].apiKey.isEmpty {
                CredentialStore.setSecret(playlists[index].apiKey, forAccount: Self.tokenAccount(playlists[index].id))
                playlists[index].apiKey = ""
            }
        }
    }

    /// B62: re-parse old M3U imports once so new kind/group rules apply.
    private func migrateLibraryFormat() {
        let key = "libraryFormatVersion"
        if UserDefaults.standard.integer(forKey: key) >= 3 { return }   // B62: bumped to 3 so the fixed migration re-runs
        Task {
            var allOK = true
            for playlist in playlists where playlist.kind == .m3u {
                statusText = "Updating \(playlist.name)…"   // B68: visible progress
                let before = errorMessage
                await refresh(playlist, showsProgress: false)
                if errorMessage != before { allOK = false }   // refresh failed
            }
            if allOK { UserDefaults.standard.set(3, forKey: key) }   // B62: only when all succeeded
            statusText = ""
            Logger.shared.log("migrate", allOK ? "library format migration complete" : "migration incomplete, will retry")
        }
    }

    func addM3UFile(name: String, fileURL: URL, epgURL: String = "") async throws {
        let resolvedName = name.trimmed.isEmpty
            ? fileURL.deletingPathExtension().lastPathComponent
            : name.trimmed
        var playlist = Playlist(name: resolvedName, kind: .m3u, url: fileURL.absoluteString)
        let text = try await fetchText(fileURL)
        let detected = epgURL.trimmed.isEmpty ? EPGParser.epgURL(in: text) : epgURL.trimmed
        if let detected, !detected.isEmpty { playlist.epgURL = detected }
        let parsed = await Task.detached(priority: .utility) {   // B58
            M3UParser.parse(text: text, playlistID: playlist.id, baseURL: fileURL)
        }.value
        guard !parsed.isEmpty else { throw AppError.emptyPlaylist }
        playlists.append(playlist)
        items.append(contentsOf: parsed)
        itemsDirtyPlaylist = playlist.id
        save()
        Task { await fetchEPG(for: playlist) }
    }

    func addXtream(name: String, server: String, username: String, password: String) async throws {
        guard let client = XtreamClient(server: server, username: username, password: password) else {
            throw AppError.invalidURL
        }

        let host = URL(string: server.contains("://") ? server : "http://\(server)")?.host ?? server
        var playlist = Playlist(
            name: name.trimmed.isEmpty ? host : name.trimmed,
            kind: .xtream,
            url: server.trimmed,
            username: username.trimmed,
            password: password,
            epgURL: client.epgURLString
        )

        sync = SyncSession(title: "Syncing playlist", steps: Self.xtreamSteps)
        sync?.start(SyncStep.checkServer)
        playlist.serverTimeZone = try await client.validate()
        let loaded = await loadXtream(client, playlistID: playlist.id)

        guard !loaded.isEmpty else { throw AppError.emptyPlaylist }

        if !CredentialStore.setPassword(password, for: playlist.id) {
            credentialsInKeychain = false
        }
        playlists.append(playlist)
        items.append(contentsOf: loaded)
        itemsDirtyPlaylist = playlist.id
        save()
        saveWatched()
        await finishSync(summaryFor: playlist.id)
        Task { await fetchEPG(for: playlist) }
    }

    private func loadXtream(_ client: XtreamClient, playlistID: UUID) async -> [MediaItem] {
        var loaded: [MediaItem] = []
        sync?.start(SyncStep.live)
        loaded += (try? await client.liveItems(playlistID: playlistID)) ?? []
        sync?.start(SyncStep.films)
        loaded += (try? await client.movieItems(playlistID: playlistID)) ?? []
        sync?.start(SyncStep.series)
        loaded += (try? await client.seriesItems(playlistID: playlistID)) ?? []
        return loaded
    }

    // MARK: - Refresh / delete

    func refreshAll() async {
        for playlist in playlists {
            await refresh(playlist)
        }
    }

    /// `showsProgress: false` for automatic refreshes, which stay out of the way.
    func refresh(_ playlist: Playlist, showsProgress: Bool = true) async {
        if needsPassword(playlist) {
            errorMessage = missingPasswordMessage(playlist)
            return
        }
        if playlist.kind == .smb { return }   // SMB lists its share when opened
        if showsProgress {
            let steps = playlist.kind == .m3u ? Self.m3uSteps : playlist.kind == .xtream ? Self.xtreamSteps : Self.serverSteps
            sync = SyncSession(title: "Syncing playlist", steps: steps)
        } else {
            isLoading = true
            statusText = "Refreshing \(playlist.name)…"
        }
        defer { isLoading = false }

        do {
            var loaded: [MediaItem] = []

            if playlist.kind == .m3u {
                sync?.start(SyncStep.checkLink)
                guard let url = URL(string: playlist.url) else { throw AppError.invalidURL }
                sync?.start(SyncStep.download)
                if url.isFileURL {
                    let text = try await fetchText(url)
                    loaded = await Task.detached(priority: .utility) {
                        M3UParser.parse(text: text, playlistID: playlist.id, baseURL: url)
                    }.value
                } else {
                    loaded = try await parseM3U(url, playlistID: playlist.id)   // B60/B62: streaming parse
                }
            } else if playlist.kind != .xtream {   // B91: Plex, Jellyfin, Emby
                sync?.start(SyncStep.libraries)
                let (libraries, serverItems) = try await loadServerLibrary(playlist)
                if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                    playlists[index].libraries = libraries
                }
                loaded = serverItems
            } else {
                guard let client = XtreamClient(server: playlist.url, username: playlist.username, password: playlist.password) else {
                    throw AppError.invalidURL
                }
                sync?.start(SyncStep.checkServer)
                let timeZone = try await client.validate()
                if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                    playlists[index].serverTimeZone = timeZone
                }
                loaded = await loadXtream(client, playlistID: playlist.id)
            }

            guard !loaded.isEmpty else { throw AppError.emptyPlaylist }
            items.removeAll { $0.playlistID == playlist.id }
            items.append(contentsOf: loaded)
            itemsDirtyPlaylist = playlist.id   // B62: persist the re-parse
            save()
            await finishSync(summaryFor: playlist.id)
            Task { await fetchEPG(for: playlist, force: true) }
        } catch {
            reportSyncFailure(error)
            Logger.shared.log("error", "refresh \(playlist.name): \(error.localizedDescription)")
        }
    }

    func delete(_ playlist: Playlist) {
        let removedIDs = Set(items.filter { $0.playlistID == playlist.id }.map(\.id))
        playlists.removeAll { $0.id == playlist.id }
        items.removeAll { $0.playlistID == playlist.id }
        favorites.subtract(removedIDs)
        for index in favoriteLists.indices {
            favoriteLists[index].itemIDs.removeAll { removedIDs.contains($0) }
        }
        recent.removeAll { removedIDs.contains($0) }
        positions = positions.filter { !removedIDs.contains($0.key) }
        watched.subtract(removedIDs)
        channelHistory.removeAll { removedIDs.contains($0) }
        write(channelHistory, to: baseDirectory.appendingPathComponent("channel-history.json"))
        if playlistFilter == playlist.id { playlistFilter = nil }
        // Its items file holds stream addresses, which can include credentials.
        try? fileManager.removeItem(at: itemsFileURL(playlist.id))
        CredentialStore.deletePassword(for: playlist.id)
        CredentialStore.deleteSecret(forAccount: Self.tokenAccount(playlist.id))
        epgByPlaylist[playlist.id] = nil
        epgChannelNames[playlist.id] = nil
        epgUpdatedAt[playlist.id] = nil
        try? fileManager.removeItem(at: epgFileURL(playlist.id))
        save()
    }

    // MARK: - Playback

    func activate(_ item: MediaItem) {
        if isLocked(item.id) { pendingUnlock = item; return }   // B47
        switch item.kind {
        case .series where !item.streamURL.isEmpty:
            play(item)   // an M3U episode, e.g. from Continue Watching
        case .series:
            Task { await loadSeries(item) }
        case .movie:
            Task { await loadMovie(item) }
        case .live:
            play(item)
        }
    }

    func loadMovie(_ item: MediaItem) async {
        let playlist = playlists.first { $0.id == item.playlistID }
        guard let playlist, playlist.kind == .xtream, !needsPassword(playlist),
              let movieID = item.movieID,
              let client = XtreamClient(server: playlist.url, username: playlist.username, password: playlist.password) else {
            movieDetailItem = MovieDetailItem(item: item, detail: nil)
            return
        }

        isLoading = true
        statusText = "Loading \(item.name)…"
        defer { isLoading = false }

        do {
            let detail = try await client.movieDetail(movieID: movieID, title: item.name, playlistID: item.playlistID)
            movieDetailItem = MovieDetailItem(item: item, detail: detail)
        } catch {
            // Fall back to the card data rather than blocking playback.
            movieDetailItem = MovieDetailItem(item: item, detail: nil)
        }
    }

    /// Plays `item`. `series` is set for episodes (enables next episode);
    /// `remember: false` keeps one-off streams (catch-up) out of Continue Watching.
    private func traktScrobble(_ phase: String, _ item: MediaItem, progress: Double) {
        guard UserDefaults.standard.bool(forKey: "traktScrobble"),
              let clientID = UserDefaults.standard.string(forKey: "traktClientID"),
              let secret = CredentialStore.secret(forAccount: "trakt.clientSecret"),
              let token = CredentialStore.secret(forAccount: "trakt.accessToken") else { return }
        var client = TraktClient(clientID: clientID, clientSecret: secret)
        client.accessToken = token
        client.refreshToken = CredentialStore.secret(forAccount: "trakt.refreshToken")
        let p = min(max(progress, 0), 100)
        Task {
            do {
                try await client.scrobble(phase, item: item, progress: p)
            } catch { Logger.shared.log("trakt", "\(phase) failed: \(error.localizedDescription)") }
        }
    }

    func play(_ item: MediaItem, series: SeriesDetail? = nil, remember: Bool = true) {
        if isLocked(item.id) { pendingUnlock = item; return }   // B47
        traktScrobble("start", item, progress: 0)
        channelHistory.removeAll { $0 == item.id }
        channelHistory.insert(item.id, at: 0)
        if channelHistory.count > 50 { channelHistory.removeLast() }
        write(channelHistory, to: baseDirectory.appendingPathComponent("channel-history.json"))
        guard item.url != nil else {
            errorMessage = "This item has no playable stream URL."
            return
        }
        playingSeries = series
        catchupSource = nil
        catchupProgram = nil
        playingItem = item
        guard remember else { return }
        recent.removeAll { $0 == item.id }
        recent.insert(item.id, at: 0)
        if recent.count > 12 { recent = Array(recent.prefix(12)) }
        save()
    }

    // MARK: - Resume

    func resumePosition(for id: String) -> PlaybackPosition? { positions[id] }

    /// Remembers where playback is; forgets it near the start or once finished.
    func savePosition(for itemID: String, seconds: Double, duration: Double) {
        guard duration >= 120, seconds.isFinite else { return }
        if seconds < 15 || seconds > duration - 45 {
            guard positions.removeValue(forKey: itemID) != nil else { return }
        } else {
            positions[itemID] = PlaybackPosition(seconds: seconds, duration: duration, updatedAt: Date())
        }
        savePositions()
    }

    private func savePositions() {
        write(positions, to: positionsURL)
    }

    private func saveWatched() {
        write(Array(watched).sorted(), to: watchedURL)
    }

    func clearPosition(for itemID: String) {
        if positions.removeValue(forKey: itemID) != nil { savePositions() }
    }

    func removeFromRecent(_ itemID: String) {
        recent.removeAll { $0 == itemID }
        saveRecent()
    }

    private func saveRecent() {
        write(recent, to: recentURL)
    }

    // MARK: - Series

    var nextEpisode: SeriesEpisode? {
        guard let series = playingSeries, let current = playingItem else { return nil }
        return series.episode(after: current.id)
    }

    func playNextEpisode() {
        guard let series = playingSeries, let next = nextEpisode else { return }
        playEpisode(next, detail: series)
    }

    // MARK: - Catch-up

    func canCatchup(_ channel: MediaItem, _ program: EPGProgram) -> Bool {
        CatchupURL.isAvailable(channel, program: program)
    }

    func playCatchup(_ channel: MediaItem, _ program: EPGProgram) {
        let playlist = playlists.first { $0.id == channel.playlistID }
        let timeZone = playlist?.serverTimeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        var program = program
        let offset = catchupOffset(for: channel)
        if offset != 0 {
            program.start = program.start.addingTimeInterval(Double(offset))
            program.end = program.end.addingTimeInterval(Double(offset))
        }
        guard let url = CatchupURL.url(for: channel, program: program, timeZone: timeZone) else {
            errorMessage = "This channel's archive couldn't be opened."
            return
        }
        var item = channel
        item.id = "\(channel.id)|catchup|\(Int(program.start.timeIntervalSince1970))"
        item.name = "\(channel.name) — \(program.title)"
        item.group = "Catch-up · \(program.timeRange)"
        item.streamURL = url.absoluteString
        item.catchup = nil
        play(item, remember: false)
        catchupSource = channel
        catchupProgram = program
    }

    func endPlayback() {
        if let item = playingItem,
           let pos = positions[item.id] {
            traktScrobble("stop", item, progress: pos.fraction * 100)
        }
        playingItem = nil
        playingSeries = nil
        catchupSource = nil
        catchupProgram = nil
    }

    func loadSeries(_ item: MediaItem) async {
        if let playlist = playlists.first(where: { $0.id == item.playlistID }), needsPassword(playlist) {
            errorMessage = missingPasswordMessage(playlist)
            return
        }
        if libraryIndex.isGroupedShow(item.id) {   // a grouped M3U show
            seriesDetail = SeriesDetail(id: abs(item.id.hashValue), title: item.name, playlistID: item.playlistID,
                                        seasons: libraryIndex.seasons(ofShow: item.id))
            return
        }
        if let playlist = playlists.first(where: { $0.id == item.playlistID }), playlist.kind != .xtream, playlist.kind != .m3u {
            isLoading = true
            statusText = "Loading \(item.name)…"
            defer { isLoading = false }
            do { seriesDetail = try await serverSeriesDetail(item, playlist: playlist) }
            catch { errorMessage = error.localizedDescription }
            return
        }
        guard let seriesID = item.seriesID,
              let playlist = playlists.first(where: { $0.id == item.playlistID }),
              let client = XtreamClient(server: playlist.url, username: playlist.username, password: playlist.password) else {
            errorMessage = "Series information is unavailable for this item."
            return
        }

        isLoading = true
        statusText = "Loading \(item.name)…"
        defer { isLoading = false }

        do {
            seriesDetail = try await client.seriesDetail(seriesID: seriesID, title: item.name, playlistID: item.playlistID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func playEpisode(_ episode: SeriesEpisode, detail: SeriesDetail) {
        let item = MediaItem(
            id: episode.id,
            playlistID: detail.playlistID,
            name: "\(detail.title) — \(episode.title)",
            group: "Series",
            logo: nil,
            streamURL: episode.streamURL,
            kind: .series,
            tvgID: nil,
            subtitle: nil
        )
        play(item, series: detail)
    }

    // MARK: - EPG

    func fetchEPG(for playlist: Playlist, force: Bool = false) async {
        let urls = playlist.guideSources.compactMap(URL.init(string:))
        guard !urls.isEmpty else { return }
        if !force,
           let updated = epgUpdatedAt[playlist.id],
           Date().timeIntervalSince(updated) < 6 * 3600 {
            return
        }

        epgStatus = "Fetching guide for \(playlist.name)…"
        do {
            // Merge every source; one failing source doesn't lose the rest.
            var programs: [String: [EPGProgram]] = [:]
            var channelNames: [String: [String]] = [:]
            var lastError: Error?
            for url in urls {
                do {
                    let data = try await fetchData(url)
                    let offset = playlist.epgTimeOffsetMinutes
                    let parsed = try await Task.detached(priority: .utility) {
                        try EPGParser.parseGuide(data: data, timeOffset: offset)
                    }.value
                    programs.merge(parsed.programs) { existing, _ in existing }
                    for (id, names) in parsed.channelNames {
                        var merged = channelNames[id] ?? []
                        for name in names where !merged.contains(name) { merged.append(name) }
                        channelNames[id] = merged
                    }
                } catch {
                    lastError = error
                }
            }

            guard !programs.isEmpty else {
                throw lastError ?? AppError.file("The guide contains no programmes.")
            }

            let now = Date()
            epgByPlaylist[playlist.id] = programs
            epgChannelNames[playlist.id] = channelNames
            epgUpdatedAt[playlist.id] = now
            write(
                EPGGuide(playlistID: playlist.id, updatedAt: now, programs: programs, channelNames: channelNames),
                to: epgFileURL(playlist.id)
            )
            epgStatus = nil
        } catch {
            epgStatus = "Guide: \(error.localizedDescription)"
        }
    }

    /// Mapping key that survives playlist refreshes: providers often rotate
    /// tokens in stream URLs, but the channel name stays the same.
    private func mappingKey(for item: MediaItem) -> String { "name:\(item.name)" }

    /// Explicit EPG channel mapping for one stream; `nil` clears it.
    func setEPGChannel(_ channelID: String?, for item: MediaItem) {
        guard let index = playlists.firstIndex(where: { $0.id == item.playlistID }) else { return }
        var mapping = playlists[index].epgMapping ?? [:]
        mapping.removeValue(forKey: item.streamURL) // legacy URL-keyed entry
        if let channelID, !channelID.isEmpty {
            mapping[mappingKey(for: item)] = channelID
        } else {
            mapping.removeValue(forKey: mappingKey(for: item))
        }
        playlists[index].epgMapping = mapping.isEmpty ? nil : mapping
        save()
    }

    func epgChannelID(for item: MediaItem) -> String? {
        let mapping = playlists.first { $0.id == item.playlistID }?.epgMapping
        return mapping?[mappingKey(for: item)] ?? mapping?[item.streamURL]
    }

    func setExtraGuideSources(_ sources: [String], for playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let cleaned = sources.map(\.trimmed).filter { !$0.isEmpty }
        playlists[index].extraEPGURLs = cleaned.isEmpty ? nil : cleaned
        save()
    }

    func fetchPopularTV() async {
        guard let tmdbClient else { return }
        do { popularTV = try await tmdbClient.popularTV() } catch { Logger.shared.log("tmdb", "popular TV failed: \(error.localizedDescription)") }
    }

    /// "Because you watch…": recommendations for the most-recently watched movie/series.
    func fetchRecommendations() async {
        guard let tmdbClient else { return }
        let base = recentItems.first(where: { $0.kind == .movie }) ?? items.first(where: { $0.kind == .movie })
        guard let base, let meta = base.tmdbMetadata else { return }
        do { recommended = try await tmdbClient.recommendations(movieID: meta.id) } catch { Logger.shared.log("tmdb", "recommendations failed: \(error.localizedDescription)") }
    }

    func fetchTrending() async {
        guard let tmdbClient else { return }
        do {
            trending = try await tmdbClient.trendingMovies()
        } catch {
            Logger.shared.log("tmdb", "trending failed: \(error.localizedDescription)")
        }
    }

    func refreshEPGIfNeededAfterCleanup() { Task { await refreshEPG() } }

    func refreshEPG() async {
        for playlist in playlists where !playlist.guideSources.isEmpty {
            await fetchEPG(for: playlist, force: true)
        }
    }

    func nowPlaying(for item: MediaItem) -> EPGProgram? {
        let now = Date()
        return programs(for: item).first { $0.start <= now && now < $0.end }
    }

    func nextPlaying(for item: MediaItem) -> EPGProgram? {
        let now = Date()
        return programs(for: item).first { $0.start > now }
    }

    func programs(for item: MediaItem) -> [EPGProgram] {
        guard item.kind == .live else { return [] }
        let guide = epgByPlaylist[item.playlistID] ?? [:]
        if let mapped = epgChannelID(for: item),
           let programs = guide[mapped], !programs.isEmpty {
            return programs
        }

        if let channelID = item.tvgID, !channelID.isEmpty,
           let exact = guide[channelID], !exact.isEmpty {
            return exact
        }

        // Many M3U channels have no tvg-id. Fall back to a unique XMLTV
        // <display-name> match ("BBC News HD" ↔ "BBC News").
        if let matched = epgNameIndexes[item.playlistID]?.channelID(for: item.name),
           let programs = guide[matched] {
            return programs
        }
        return []
    }

    var guideGroups: [String] {
        var base = libraryIndex.live
        if let playlistFilter { base = base.filter { $0.playlistID == playlistFilter } }
        return Set(base.map { effectiveGroup($0) }).filter { !isCategoryHidden($0) }.sorted()
    }

    func guideItems(group: String) -> [MediaItem] {
        var result = libraryIndex.live
        if let playlistFilter { result = result.filter { $0.playlistID == playlistFilter } }
        if group != "All" { result = result.filter { $0.group == group } }

        let query = effectiveSearchText.trimmed.lowercased()
        if !query.isEmpty {
            result = result.filter { item in
                item.name.lowercased().contains(query)
                    || item.group.lowercased().contains(query)
                    || (nowPlaying(for: item)?.title.lowercased().contains(query) ?? false)
            }
        }

        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func fetchData(_ url: URL) async throws -> Data {
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url) else {
                throw AppError.file("Couldn’t read the selected EPG file.")
            }
            return data
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Watvu/0.1", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AppError.network("The guide server returned HTTP \(http.statusCode).")
            }
            return data
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.network("Couldn’t download the guide: \(error.localizedDescription)")
        }
    }

    // MARK: - Favorites & filters

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) {
            favorites.remove(id)
        } else {
            favorites.insert(id)
        }
        save()
    }

    func toggle(_ itemID: String, inList listID: UUID) {
        guard let index = favoriteLists.firstIndex(where: { $0.id == listID }) else { return }
        if let position = favoriteLists[index].itemIDs.firstIndex(of: itemID) {
            favoriteLists[index].itemIDs.remove(at: position)
        } else {
            favoriteLists[index].itemIDs.append(itemID)
        }
        save()
    }

    @discardableResult
    func createFavoriteList(named name: String, adding itemID: String? = nil) -> UUID? {
        let name = name.trimmed
        guard !name.isEmpty else { return nil }
        let list = FavoriteList(name: name, itemIDs: itemID.map { [$0] } ?? [])
        favoriteLists.append(list)
        save()
        return list.id
    }

    func renameFavoriteList(_ id: UUID, to name: String) {
        guard let index = favoriteLists.firstIndex(where: { $0.id == id }), !name.trimmed.isEmpty else { return }
        favoriteLists[index].name = name.trimmed
        save()
    }

    func deleteFavoriteList(_ id: UUID) {
        favoriteLists.removeAll { $0.id == id }
        if favoriteListFilter == id { favoriteListFilter = nil }
        save()
    }

    /// Item IDs shown on the Favorites page for the selected list.
    private var favoritePageIDs: Set<String> {
        if let id = favoriteListFilter, let list = favoriteLists.first(where: { $0.id == id }) {
            return Set(list.itemIDs)
        }
        return favorites
    }

    /// Everything a page's filter needs, copied so it can run off the main thread.
    func libraryQuery(kind: MediaKind?, favoritesOnly: Bool, search: String, sort: LibrarySort, groupSimilar: Bool) -> LibraryQuery {
        LibraryQuery(
            kind: kind,
            favoriteIDs: favoritesOnly ? favoritePageIDs : nil,
            playlistID: playlistFilter,
            group: selectedGroup == "All" ? nil : selectedGroup,
            hiddenIDs: hiddenItemIDs,
            hiddenGroups: hiddenCategories,
            search: search,
            sort: sort,
            positions: sort == .recentlyWatched ? positions.mapValues(\.seconds) : [:],
            groupSimilar: groupSimilar
        )
    }

    private func scheduleIndexRebuild() {
        indexGeneration += 1
        let generation = indexGeneration
        let snapshot = items
        let currentOverrides = overrides
        let isFirstBuild = libraryIndex.isEmpty
        indexTask = Task { [weak self] in
            // Coalesces bursts, e.g. metadata arriving for each visible card.
            if !isFirstBuild { try? await Task.sleep(for: .milliseconds(150)) }
            guard let self, generation == self.indexGeneration else { return }
            let built = await Task.detached(priority: .userInitiated) {
                LibraryIndex(items: snapshot) { item in
                    guard let override = currentOverrides[item.id] else { return item }
                    var copy = item
                    copy.name = override.name ?? item.name
                    copy.group = override.group ?? item.group
                    copy.logo = override.logo ?? item.logo
                    return copy
                }
            }.value
            guard generation == self.indexGeneration else { return }
            self.groupsCache.removeAll()
            self.libraryIndex = built
            // Loading leaves a lot of freed memory behind: hand it back.
            Task.detached(priority: .utility) { malloc_zone_pressure_relief(nil, 0) }
        }
    }

    /// Waits until `libraryIndex` reflects the current items.
    func libraryIndexIsReady() async {
        var seen = -1
        while seen != indexGeneration {
            seen = indexGeneration
            await indexTask?.value
        }
    }

    /// Waits for queued item files to reach the disk.
    func itemsAreSaved() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            persistQueue.async { done.resume() }
        }
    }

    func groups(kind: MediaKind?, favoritesOnly: Bool) -> [String] {
        let key = "\(kind?.rawValue ?? "all")|\(favoritesOnly)|\(playlistFilter?.uuidString ?? "")|\(favoriteListFilter?.uuidString ?? "")"
        if let cached = groupsCache[key] { return cached }
        var base = libraryIndex.list(kind)
        if favoritesOnly {
            let ids = favoritePageIDs
            base = base.filter { ids.contains($0.id) }
        }
        if let playlistFilter { base = base.filter { $0.playlistID == playlistFilter } }
        // Hidden-category check once per category, not once per item.
        let result = Set(base.map { effectiveGroup($0) }).filter { !isCategoryHidden($0) }.sorted()
        groupsCache[key] = result
        return result
    }

    func clearRecents() {
        recent = []
        save()
    }

    func clearFavorites() {
        favorites = []
        save()
    }

    /// Folder holding playlists, items, favorites and guide caches.
    var dataDirectory: URL { baseDirectory }

    var recentItems: [MediaItem] {
        recent.compactMap { libraryIndex.item(id: $0) }
    }

    // MARK: - Persistence

    /// Public persistence trigger (used by extension methods in AppModel.swift).
    func persist() { save() }

    var itemsDirtyPlaylist: UUID?


    func save() {
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let serializedPlaylists = playlists.map { playlist -> Playlist in
            var copy = playlist
            if credentialsInKeychain { copy.password = ""; copy.apiKey = "" }   // B71
            return copy
        }
        write(serializedPlaylists, to: playlistsURL)
        // B59: write only the playlist whose items changed, compactly.
        if itemsDirtyPlaylist != nil {
            let id = itemsDirtyPlaylist!
            let sub = items.filter { $0.playlistID == id }
            let url = itemsFileURL(id)
            itemsDirtyPlaylist = nil
            // A big playlist takes seconds to encode: never on the main thread.
            persistQueue.async {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(sub) { try? data.write(to: url, options: .atomic) }
            }
        }
        write(Array(favorites).sorted(), to: favoritesURL)
        write(recent, to: recentURL)
        write(favoriteLists, to: favoriteListsURL)
    }

    func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        Self.decode(type, from: url)
    }

    nonisolated static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func fetchText(_ url: URL) async throws -> String {
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url) else {
                throw AppError.file("Couldn’t read the selected playlist file.")
            }
            return String(decoding: data, as: UTF8.self)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Watvu/0.1", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AppError.network("The playlist server returned HTTP \(http.statusCode).")
            }
            if let text = String(data: data, encoding: .utf8) { return text }
            if let text = String(data: data, encoding: .isoLatin1) { return text }
            throw AppError.file("The playlist isn’t readable text.")
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.network("Couldn’t download the playlist: \(error.localizedDescription)")
        }
    }

    private static func normalizedURL(_ raw: String) -> URL? {
        var text = raw.trimmed
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        return URL(string: text)
    }
}

extension AppModel {
    func fetchTMDBMetadata(for item: MediaItem) async {
        guard let tmdbClient else { return }
        do {
            if item.kind == .movie {
                let results = try await tmdbClient.searchMovie(query: item.name)
                if let result = results.first {
                    let details = try await tmdbClient.movieDetails(id: result.id)
                    let metadata = TMDBMetadata(
                        id: details.id,
                        title: details.title,
                        posterPath: details.posterPath,
                        overview: details.overview,
                        voteAverage: details.voteAverage,
                        runtime: details.runtime,
                        releaseDate: details.releaseDate,
                        genres: details.genres?.map { $0.name },
                        trailerKey: details.videos?.results.first { $0.site == "YouTube" && $0.type == "Trailer" }?.key
                    )
                    if let index = items.firstIndex(where: { $0.id == item.id }) {
                        items[index].tmdbMetadata = metadata
                        save()
                    }
                }
            } else if item.kind == .series {
                let results = try await tmdbClient.searchTV(query: item.name)
                if let result = results.first {
                    let details = try await tmdbClient.tvDetails(id: result.id)
                    let metadata = TMDBMetadata(
                        id: details.id,
                        title: details.name,
                        posterPath: details.posterPath,
                        overview: details.overview,
                        voteAverage: details.voteAverage,
                        runtime: nil,
                        releaseDate: details.firstAirDate,
                        genres: details.genres?.map { $0.name },
                        trailerKey: details.videos?.results.first { $0.site == "YouTube" && $0.type == "Trailer" }?.key
                    )
                    if let index = items.firstIndex(where: { $0.id == item.id }) {
                        items[index].tmdbMetadata = metadata
                        save()
                    }
                }
            }
        } catch {
            Logger.shared.log("tmdb", "metadata failed: \(error.localizedDescription)")
        }
    }
}
