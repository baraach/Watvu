import Foundation

/// Backup bundle: everything except credentials (those stay in the Keychain).
struct BackupBundle: Codable {
    var version = 1
    var exportedAt = Date()
    var playlists: [Playlist] = []
    var favorites: [String] = []
    var favoriteLists: [FavoriteList] = []
    var recent: [String] = []
    var positions: [String: PlaybackPosition] = [:]
    var watched: [String] = []
    var overrides: [String: ItemOverride] = [:]
    var channelHistory: [String] = []
    var homeFeeds: [HomeFeed]? = nil
}

extension AppModel {
    /// Removes `username=`/`password=` (and similar) query items from a URL string.
    static func strippedCredentials(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString), !(components.queryItems?.isEmpty ?? true) else { return urlString }
        let sensitive = ["username", "password", "user", "pass", "token", "api_key", "apikey"]
        components.queryItems = components.queryItems?.filter { !sensitive.contains($0.name.lowercased()) }
        return components.url?.absoluteString ?? urlString
    }

    func exportBackup(to url: URL) throws {
        var playlists = self.playlists
        for i in playlists.indices {
            playlists[i].password = ""        // credentials stay in Keychain
            playlists[i].apiKey = ""          // B71: backend tokens stay in Keychain
            playlists[i].url = Self.strippedCredentials(playlists[i].url)   // B71: strip user/pass query items
        }
        let bundle = BackupBundle(
            playlists: playlists,
            favorites: Array(favorites).sorted(),
            favoriteLists: favoriteLists,
            recent: recent,
            positions: positions,
            watched: Array(watched).sorted(),
            overrides: overrides,
            channelHistory: channelHistory,
            homeFeeds: homeFeeds
        )
        let data = try JSONEncoder().encode(bundle)
        try data.write(to: url, options: .atomic)
    }

    /// Merges a backup into the library. `merging` (iCloud Drive sync) keeps
    /// the newer playback position instead of always taking the file's.
    @discardableResult
    func importBackup(from url: URL, merging: Bool = false) throws -> BackupBundle {
        let bundle = try JSONDecoder().decode(BackupBundle.self, from: Data(contentsOf: url))
        // New playlists only; existing ones keep their Keychain credentials.
        // Imported ones have no password: enter it once on this Mac.
        for p in bundle.playlists where !playlists.contains(where: { $0.id == p.id }) {
            playlists.append(p)
        }
        favorites.formUnion(bundle.favorites)
        for list in bundle.favoriteLists where !favoriteLists.contains(where: { $0.id == list.id }) {
            favoriteLists.append(list)
        }
        // Keep this Mac's order, then add the other Mac's entries.
        recent = Array((recent + bundle.recent.filter { !recent.contains($0) }).prefix(200))
        for (key, incoming) in bundle.positions {
            if merging, let local = positions[key],
               (local.updatedAt ?? .distantPast) >= (incoming.updatedAt ?? .distantPast) { continue }
            positions[key] = incoming
        }
        watched.formUnion(bundle.watched)
        for (k, v) in bundle.overrides where !merging || overrides[k] == nil { overrides[k] = v }
        let newFeeds = (bundle.homeFeeds ?? []).filter { feed in !homeFeeds.contains { $0.id == feed.id } }
        if !newFeeds.isEmpty {
            homeFeeds += newFeeds
            saveHomeFeeds()
            Task { for feed in newFeeds { await refreshFeed(feed) } }
        }
        channelHistory = Array((channelHistory + bundle.channelHistory.filter { !channelHistory.contains($0) }).prefix(50))
        save()
        saveOverrides()
        for p in playlists { itemsDirtyPlaylist = p.id; save() }
        return bundle
    }
}
