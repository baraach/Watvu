import Foundation

struct XtreamClient {
    let base: URL
    let username: String
    let password: String

    init?(server: String, username: String, password: String) {
        var text = server.trimmed
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text) else { return nil }
        self.base = url
        self.username = username.trimmed
        self.password = password
    }

    private var baseString: String { base.absoluteString }

    var epgURLString: String {
        var components = URLComponents(
            url: base.appendingPathComponent("xmltv.php"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password)
        ]
        return components?.url?.absoluteString ?? ""
    }

    private func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    struct AccountInfo: Codable {
        let auth: Int
        let status: String
        let expDate: String?
        let isTrial: String?
        let activeCons: String?
        let maxConnections: String?

        enum CodingKeys: String, CodingKey {
            case auth, status
            case expDate = "exp_date"
            case isTrial = "is_trial"
            case activeCons = "active_cons"
            case maxConnections = "max_connections"
        }
    }

    /// Signs in; returns the server's time zone (catch-up uses local time).
    @discardableResult
    func validate() async throws -> String? {
        let object = try await getJSON(action: nil)
        let serverInfo = (object as? [String: Any])?["server_info"] as? [String: Any]
        return string(serverInfo?["timezone"])
    }

    func accountInfo() async throws -> AccountInfo {
        let object = try await getJSON(action: "get_user_info")
        guard let userInfo = (object as? [String: Any])?["user_info"] else {
            throw AppError.xtream("The Xtream server returned an unexpected response.")
        }
        return try JSONDecoder().decode(AccountInfo.self, from: JSONSerialization.data(withJSONObject: userInfo))
    }

    func liveItems(playlistID: UUID) async throws -> [MediaItem] {
        let categories = try await categoryMap(action: "get_live_categories")
        let object = try await getJSON(action: "get_live_streams")
        guard let rows = object as? [[String: Any]] else { return [] }

        return rows.compactMap { row in
            guard let streamID = intValue(row["stream_id"]),
                  let name = string(row["name"]) else { return nil }
            let categoryID = string(row["category_id"]) ?? ""
            let group = categories[categoryID] ?? "Live TV"
            let url = "\(baseString)/live/\(encoded(username))/\(encoded(password))/\(streamID).m3u8"
            let archiveDays = intValue(row["tv_archive"]) == 1 ? (intValue(row["tv_archive_duration"]) ?? 0) : 0
            return MediaItem(
                id: "\(playlistID.uuidString)|live|\(streamID)",
                playlistID: playlistID,
                name: name,
                group: group,
                logo: string(row["stream_icon"]),
                streamURL: url,
                kind: .live,
                tvgID: string(row["epg_channel_id"]),
                subtitle: nil,
                catchup: archiveDays > 0 ? Catchup(mode: .xtream, days: archiveDays) : nil
            )
        }
    }

    func movieItems(playlistID: UUID) async throws -> [MediaItem] {
        let categories = try await categoryMap(action: "get_vod_categories")
        let object = try await getJSON(action: "get_vod_streams")
        guard let rows = object as? [[String: Any]] else { return [] }

        return rows.compactMap { row in
            guard let streamID = intValue(row["stream_id"]),
                  let name = string(row["name"]) else { return nil }
            let categoryID = string(row["category_id"]) ?? ""
            let group = categories[categoryID] ?? "Movies"
            let ext = string(row["container_extension"]) ?? "mp4"
            let url = "\(baseString)/movie/\(encoded(username))/\(encoded(password))/\(streamID).\(ext)"
            return MediaItem(
                id: "\(playlistID.uuidString)|movie|\(streamID)",
                playlistID: playlistID,
                name: name,
                group: group,
                logo: string(row["stream_icon"]),
                streamURL: url,
                kind: .movie,
                tvgID: nil,
                subtitle: string(row["rating"]),
                movieID: streamID
            )
        }
    }

    func movieDetail(movieID: Int, title: String, playlistID: UUID) async throws -> MovieDetail {
        let object = try await getJSON(
            action: "get_vod_info",
            extra: [URLQueryItem(name: "vod_id", value: String(movieID))]
        )
        guard let dictionary = object as? [String: Any],
              let info = dictionary["info"] as? [String: Any] else {
            throw AppError.xtream("This movie has no detail data.")
        }

        // Most panels nest `backdrop_path` (array or string) inside `info`.
        let backdrop = firstImage(info["backdrop_path"]) ?? firstImage(dictionary["backdrop_path"])
        let poster = firstImage(info["movie_image"]) ?? firstImage(dictionary["movie_image"])
            ?? firstImage(info["cover_big"])
        let trailerID = string(info["youtube_trailer"])
        return MovieDetail(
            id: movieID,
            title: string(info["name"]) ?? title,
            plot: string(info["plot"]) ?? string(info["description"]),
            cast: string(info["cast"]),
            director: string(info["director"]),
            genre: string(info["genre"]),
            releaseDate: string(info["releasedate"]) ?? string(info["release_date"]),
            rating: doubleValue(info["rating"]),
            duration: string(info["duration"]),
            backdrop: backdrop,
            poster: poster,
            trailer: trailerID.flatMap { $0.isEmpty ? nil : "https://www.youtube.com/watch?v=\($0)" }
        )
    }

    func seriesItems(playlistID: UUID) async throws -> [MediaItem] {
        let categories = try await categoryMap(action: "get_series_categories")
        let object = try await getJSON(action: "get_series")
        guard let rows = object as? [[String: Any]] else { return [] }

        return rows.compactMap { row in
            guard let seriesID = intValue(row["series_id"]),
                  let name = string(row["name"]) else { return nil }
            let categoryID = string(row["category_id"]) ?? ""
            let group = categories[categoryID] ?? "Series"
            return MediaItem(
                id: "\(playlistID.uuidString)|series|\(seriesID)",
                playlistID: playlistID,
                name: name,
                group: group,
                logo: string(row["cover"]),
                streamURL: "",
                kind: .series,
                tvgID: nil,
                subtitle: string(row["plot"]),
                seriesID: seriesID
            )
        }
    }

    func seriesDetail(seriesID: Int, title: String, playlistID: UUID) async throws -> SeriesDetail {
        let object = try await getJSON(
            action: "get_series_info",
            extra: [URLQueryItem(name: "series_id", value: String(seriesID))]
        )
        guard let dictionary = object as? [String: Any],
              let episodeDictionary = dictionary["episodes"] as? [String: [[String: Any]]] else {
            throw AppError.xtream("This series has no episode data.")
        }

        var seasons: [SeriesSeason] = []
        for (key, rows) in episodeDictionary {
            let seasonNumber = Int(key) ?? 0
            var episodes: [SeriesEpisode] = []

            for row in rows {
                guard let episodeID = string(row["id"]) else { continue }
                let ext = string(row["container_extension"]) ?? "mp4"
                let number = intValue(row["episode_num"]) ?? 0
                let episodeTitle = string(row["title"]) ?? "Episode \(number)"
                let url = "\(baseString)/series/\(encoded(username))/\(encoded(password))/\(episodeID).\(ext)"
                episodes.append(
                    SeriesEpisode(
                        id: "\(playlistID.uuidString)|episode|\(episodeID)",
                        title: episodeTitle,
                        season: seasonNumber,
                        number: number,
                        streamURL: url
                    )
                )
            }

            if !episodes.isEmpty {
                seasons.append(SeriesSeason(number: seasonNumber, episodes: episodes.sorted { $0.number < $1.number }))
            }
        }

        guard !seasons.isEmpty else {
            throw AppError.xtream("This series has no playable episodes.")
        }

        return SeriesDetail(
            id: seriesID,
            title: title,
            playlistID: playlistID,
            seasons: seasons.sorted { $0.number < $1.number }
        )
    }

    private func categoryMap(action: String) async throws -> [String: String] {
        let object = try await getJSON(action: action)
        guard let rows = object as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for row in rows {
            guard let id = string(row["category_id"]) else { continue }
            result[id] = string(row["category_name"]) ?? "Other"
        }
        return result
    }

    private func getJSON(action: String?, extra: [URLQueryItem] = []) async throws -> Any {
        guard let url = apiURL(action: action, extra: extra) else { throw AppError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Watvu/0.1", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AppError.network("Couldn’t reach the Xtream server: \(error.localizedDescription)")
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppError.network("Xtream server returned HTTP \(http.statusCode).")
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AppError.xtream("The Xtream server returned an unexpected response.")
        }

        if let dictionary = object as? [String: Any],
           let userInfo = dictionary["user_info"] as? [String: Any],
           let auth = intValue(userInfo["auth"]), auth == 0 {
            throw AppError.xtream("Xtream login failed. Check the server, username, and password.")
        }

        return object
    }

    private func apiURL(action: String?, extra: [URLQueryItem]) -> URL? {
        var components = URLComponents(
            url: base.appendingPathComponent("player_api.php"),
            resolvingAgainstBaseURL: false
        )
        var query = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password)
        ]
        if let action {
            query.append(URLQueryItem(name: "action", value: action))
        }
        query.append(contentsOf: extra)
        components?.queryItems = query
        return components?.url
    }

    private func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let integer = value as? Int { return String(integer) }
        return nil
    }

    /// First non-empty image URL from a string or an array of strings.
    func firstImage(_ value: Any?) -> String? {
        let candidates: [String]
        if let list = value as? [Any] {
            candidates = list.compactMap { $0 as? String }
        } else if let single = value as? String {
            candidates = [single]
        } else {
            candidates = []
        }
        return candidates.map(\.trimmed).first { !$0.isEmpty }
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let integer = value as? Int { return integer }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
