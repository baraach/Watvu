import Foundation

extension AppModel {
    /// Pulls the Trakt watchlist into Favorites and history into Watched
    /// (when the corresponding toggles are on). Returns a status string.
    func syncTrakt(client: TraktClient?) async -> String {
        guard let client else { return L("Not signed in") }
        var added = 0
        var marked = 0
        do {
            if UserDefaults.standard.bool(forKey: "traktWatchlist") {
                for media in try await client.watchlist() {
                    let key = NameCleaner.cleaned(media.title).lowercased()
                    if let match = items.first(where: { NameCleaner.cleaned($0.name).lowercased() == key }) {
                        if !isFavorite(match.id) { toggleFavorite(match.id); added += 1 }
                    }
                }
            }
            if UserDefaults.standard.bool(forKey: "traktHistory") {
                for media in try await client.history() {
                    let key = NameCleaner.cleaned(media.title).lowercased()
                    if let match = items.first(where: { NameCleaner.cleaned($0.name).lowercased() == key }) {
                        if !isWatched(match.id) { toggleWatched(match.id); marked += 1 }
                    }
                }
            }
            return String(format: L("Synced: %d added to Favorites, %d marked watched"), added, marked)
        } catch {
            return "Trakt sync failed: \(error.localizedDescription)"
        }
    }
}

extension AppModel {
    /// Adds a Jellyfin or Emby server (`kind`), which share one API.
    func addMediaServer(_ kind: PlaylistKind, name: String, server: String, username: String, password: String) async throws {
        guard let serverURL = URL(string: server.trimmingCharacters(in: .whitespaces)), serverURL.host != nil else { throw AppError.invalidURL }
        sync = SyncSession(title: "Syncing playlist", steps: Self.serverSteps)
        sync?.start(SyncStep.signIn)
        let client = try await MediaServerClient.signIn(server: serverURL, username: username, password: password)
        var playlist = Playlist(
            name: name.trimmed.isEmpty ? serverURL.host ?? kind.title : name.trimmed,
            kind: kind,
            url: serverURL.absoluteString,
            username: username
        )
        playlist.serverUserID = client.userID
        try await addServerPlaylist(playlist, token: client.token)
    }

    /// Adds a Plex server: at `address` if given, else found through your account.
    func addPlex(name: String, token: String, address: String = "") async throws {
        sync = SyncSession(title: "Syncing playlist", steps: Self.serverSteps)
        sync?.start(SyncStep.signIn)
        let server: (name: String, client: PlexClient)
        if let url = URL(string: address.trimmed), url.host != nil {
            server = (url.host ?? "Plex", PlexClient(serverURL: url, token: token))
        } else {
            server = try await PlexAuth.firstReachableServer(token: token)
        }
        let playlist = Playlist(
            name: name.trimmed.isEmpty ? server.name : name.trimmed,
            kind: .plex,
            url: server.client.serverURL.absoluteString
        )
        try await addServerPlaylist(playlist, token: server.client.token)
    }

    private func addServerPlaylist(_ playlist: Playlist, token: String) async throws {
        CredentialStore.setSecret(token, forAccount: Self.tokenAccount(playlist.id))
        var playlist = playlist
        do {
            sync?.start(SyncStep.libraries)
            let (libraries, loaded) = try await loadServerLibrary(playlist)
            playlist.libraries = libraries
            playlists.append(playlist)
            items.append(contentsOf: loaded)
            itemsDirtyPlaylist = playlist.id
            persist()
            await finishSync(summaryFor: playlist.id)
        } catch {
            CredentialStore.deleteSecret(forAccount: Self.tokenAccount(playlist.id))
            throw error
        }
    }

    // MARK: Loading from media servers

    static func tokenAccount(_ playlistID: UUID) -> String { "playlist.apiKey.\(playlistID)" }

    private func serverToken(_ playlist: Playlist) throws -> String {
        guard let token = CredentialStore.secret(forAccount: Self.tokenAccount(playlist.id)), !token.isEmpty else {
            throw AppError.network("Sign in to “\(playlist.name)” again: remove it and add it back.")
        }
        return token
    }

    private func jellyfinClient(_ playlist: Playlist) throws -> MediaServerClient {
        guard let url = URL(string: playlist.url), let userID = playlist.serverUserID else {
            throw AppError.network("Sign in to “\(playlist.name)” again: remove it and add it back.")
        }
        return MediaServerClient(baseURL: url, token: try serverToken(playlist), userID: userID)
    }

    private func plexClient(_ playlist: Playlist) throws -> PlexClient {
        guard let url = URL(string: playlist.url) else { throw AppError.invalidURL }
        return PlexClient(serverURL: url, token: try serverToken(playlist))
    }

    /// Libraries and items of a Plex, Jellyfin or Emby server. Each library's
    /// name is its items' group, which the playlist page's chips filter on.
    func loadServerLibrary(_ playlist: Playlist) async throws -> ([PlaylistLibrary], [MediaItem]) {
        var libraries: [PlaylistLibrary] = []
        var loaded: [MediaItem] = []
        func itemID(_ serverID: String) -> String { "\(playlist.id.uuidString)|server|\(serverID)" }
        if playlist.kind == .plex {
            let client = try plexClient(playlist)
            for section in try await client.libraries() {
                libraries.append(PlaylistLibrary(id: section.key, name: section.title))
                for item in try await client.items(sectionKey: section.key) {
                    let isShow = item.type == "show"
                    loaded.append(MediaItem(
                        id: itemID(item.ratingKey), playlistID: playlist.id, name: item.title, group: section.title,
                        logo: client.imageURL(item.thumb), backdrop: client.imageURL(item.art),
                        streamURL: isShow ? "" : client.streamURL(for: item), kind: isShow ? .series : .movie,
                        subtitle: Self.serverSubtitle(year: item.year, overview: item.summary)))
                }
            }
        } else {
            let client = try jellyfinClient(playlist)
            for library in try await client.libraries() {
                libraries.append(PlaylistLibrary(id: library.id, name: library.name))
                for item in try await client.items(libraryID: library.id) {
                    let isShow = item.type == "Series"
                    loaded.append(MediaItem(
                        id: itemID(item.id), playlistID: playlist.id, name: item.name, group: library.name,
                        logo: item.imageTags?["Primary"].map { client.imageURL(itemID: item.id, type: "Primary", tag: $0) },
                        backdrop: item.backdropTags?.first.map { client.imageURL(itemID: item.id, type: "Backdrop", tag: $0) },
                        streamURL: isShow ? "" : client.streamURL(itemID: item.id).absoluteString, kind: isShow ? .series : .movie,
                        subtitle: Self.serverSubtitle(year: item.year, overview: item.overview)))
                }
            }
        }
        return (libraries, loaded)
    }

    /// "2012 · A short description": one line on cards, the text in the detail sheet.
    private static func serverSubtitle(year: Int?, overview: String?) -> String? {
        let parts = [year.map(String.init), overview].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Seasons and episodes of a show on a Plex, Jellyfin or Emby server.
    func serverSeriesDetail(_ show: MediaItem, playlist: Playlist) async throws -> SeriesDetail {
        let serverID = show.id.components(separatedBy: "|").last ?? ""
        var episodes: [SeriesEpisode] = []
        if playlist.kind == .plex {
            let client = try plexClient(playlist)
            episodes = try await client.episodes(showKey: serverID).map {
                SeriesEpisode(id: "\(playlist.id.uuidString)|server|\($0.ratingKey)", title: $0.title,
                              season: $0.parentIndex ?? 1, number: $0.index ?? 0,
                              streamURL: client.streamURL(for: $0), artwork: client.imageURL($0.thumb), plot: $0.summary)
            }
        } else {
            let client = try jellyfinClient(playlist)
            episodes = try await client.episodes(seriesID: serverID).map { episode in
                SeriesEpisode(id: "\(playlist.id.uuidString)|server|\(episode.id)", title: episode.name,
                              season: episode.season ?? 1, number: episode.number ?? 0,
                              streamURL: client.streamURL(itemID: episode.id).absoluteString,
                              artwork: episode.imageTags?["Primary"].map { client.imageURL(itemID: episode.id, type: "Primary", tag: $0) },
                              plot: episode.overview)
            }
        }
        let seasons = Dictionary(grouping: episodes, by: \.season)
            .map { SeriesSeason(number: $0.key, episodes: $0.value.sorted { $0.number < $1.number }) }
            .sorted { $0.number < $1.number }
        return SeriesDetail(id: abs(show.id.hashValue), title: show.name, playlistID: playlist.id, seasons: seasons)
    }

    func addSMB(name: String, server: String, username: String, password: String) async throws {
        guard let url = URL(string: server), let host = url.host else { throw AppError.invalidURL }
        let share = url.pathComponents.dropFirst().joined(separator: "/")
        playlists.append(Playlist(
            name: name.trimmed.isEmpty ? host : name.trimmed,
            kind: .smb,
            url: server,
            username: username,
            password: password,
            libraries: [PlaylistLibrary(id: "", name: share.isEmpty ? "root" : share)]
        ))
        persist()
    }

    /// Resolve the playable URL for an item, including backend-specific streams.
    func streamURL(for item: MediaItem) async throws -> URL {
        if let url = item.url { return url }
        throw AppError.invalidURL
    }

    func isWatched(_ id: String) -> Bool { watched.contains(id) }

    func toggleWatched(_ id: String) {
        if watched.contains(id) { watched.remove(id) } else { watched.insert(id) }
        persist()
    }

    func unlockPlaylist(_ playlistID: UUID) {
        for item in items where item.playlistID == playlistID {
            setLocked(false, for: item.id)
        }
    }

    // MARK: - PIN lock (B47)

    var isPINSet: Bool { CredentialStore.secret(forAccount: "app.pin") != nil }

    func setPIN(_ pin: String) {
        CredentialStore.setSecret(pin, forAccount: "app.pin")
    }

    func verifyPIN(_ pin: String) -> Bool {
        CredentialStore.secret(forAccount: "app.pin") == pin
    }


    // MARK: - Hide / Lock (B13, B14)

    private var hiddenKey: String { "hiddenItems" }
    private var lockedKey: String { "lockedItems" }

    func isHidden(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []).contains(id)
    }

    func isLocked(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: lockedKey) ?? []).contains(id)
    }

    func setHidden(_ hidden: Bool, for id: String) {
        var list = UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []
        if hidden { if !list.contains(id) { list.append(id) } } else { list.removeAll { $0 == id } }
        UserDefaults.standard.set(list, forKey: hiddenKey)
    }

    func setLocked(_ locked: Bool, for id: String) {
        var list = UserDefaults.standard.stringArray(forKey: lockedKey) ?? []
        if locked { if !list.contains(id) { list.append(id) } } else { list.removeAll { $0 == id } }
        UserDefaults.standard.set(list, forKey: lockedKey)
    }
}
