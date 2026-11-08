import Foundation

/// Identifies this app to Jellyfin, Emby and Plex (a stable per-install ID).
enum MediaServerIdentity {
    static let product = "Watvu"
    static let version = "0.1.0"
    static var deviceID: String {
        let key = "mediaServerDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}

/// Jellyfin and Emby speak the same API (Jellyfin began as a fork of Emby).
struct MediaServerClient {
    let baseURL: URL
    let token: String
    let userID: String

    /// Video library types with something to play (not music, photos, etc.).
    private static let playableLibraries: Set<String> = ["movies", "tvshows", "homevideos", "mixed"]

    /// Signs in with a username and password; returns a client holding the token.
    static func signIn(server: URL, username: String, password: String) async throws -> MediaServerClient {
        var request = URLRequest(url: server.appendingPathComponent("Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Required: servers answer 400 without it.
        request.setValue("MediaBrowser Client=\"\(MediaServerIdentity.product)\", Device=\"Mac\", DeviceId=\"\(MediaServerIdentity.deviceID)\", Version=\"\(MediaServerIdentity.version)\"",
                         forHTTPHeaderField: "X-Emby-Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw AppError.network("Wrong username or password.")
        }
        struct SignIn: Decodable {
            struct User: Decodable { let Id: String }
            let AccessToken: String
            let User: User
        }
        guard let result = try? JSONDecoder().decode(SignIn.self, from: data) else {
            throw AppError.network("That server didn't accept the sign-in. Check the address.")
        }
        return MediaServerClient(baseURL: server, token: result.AccessToken, userID: result.User.Id)
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type = T.self) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw AppError.network("The server's sign-in has expired. Remove this playlist and add it again.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func libraries() async throws -> [MediaServerLibrary] {
        let response: MediaServerPage<MediaServerLibrary> = try await get("Users/\(userID)/Views")
        return response.items.filter { Self.playableLibraries.contains($0.collectionType ?? "mixed") }
    }

    /// Movies, shows and videos in a library, a page at a time.
    func items(libraryID: String) async throws -> [MediaServerItem] {
        var all: [MediaServerItem] = []
        let pageSize = 500
        while true {
            let page: MediaServerPage<MediaServerItem> = try await get("Users/\(userID)/Items", query: [
                URLQueryItem(name: "ParentId", value: libraryID),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Video"),
                URLQueryItem(name: "Fields", value: "Overview"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "StartIndex", value: String(all.count)),
                URLQueryItem(name: "Limit", value: String(pageSize)),
            ])
            all += page.items
            if page.items.count < pageSize { return all }
        }
    }

    func episodes(seriesID: String) async throws -> [MediaServerItem] {
        let page: MediaServerPage<MediaServerItem> = try await get("Shows/\(seriesID)/Episodes", query: [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "Fields", value: "Overview"),
        ])
        return page.items
    }

    /// HLS playlist: the server passes through what AVPlayer can play and
    /// transcodes the rest, so any file in the library works.
    func streamURL(itemID: String) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("Videos/\(itemID)/master.m3u8"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "MediaSourceId", value: itemID),
            URLQueryItem(name: "DeviceId", value: MediaServerIdentity.deviceID),
            URLQueryItem(name: "VideoCodec", value: "h264,hevc"),
            URLQueryItem(name: "AudioCodec", value: "aac,ac3,eac3"),
            URLQueryItem(name: "api_key", value: token),
        ]
        return components.url!
    }

    func imageURL(itemID: String, type: String, tag: String) -> String {
        baseURL.appendingPathComponent("Items/\(itemID)/Images/\(type)").absoluteString + "?tag=\(tag)"
    }
}

struct MediaServerPage<Item: Decodable>: Decodable {
    let items: [Item]
    enum CodingKeys: String, CodingKey { case items = "Items" }
}

struct MediaServerLibrary: Decodable {
    let id: String
    let name: String
    let collectionType: String?
    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", collectionType = "CollectionType"
    }
}

struct MediaServerItem: Decodable {
    let id: String
    let name: String
    let type: String
    let overview: String?
    let year: Int?
    let imageTags: [String: String]?
    let backdropTags: [String]?
    let number: Int?
    let season: Int?
    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type", overview = "Overview", year = "ProductionYear"
        case imageTags = "ImageTags", backdropTags = "BackdropImageTags"
        case number = "IndexNumber", season = "ParentIndexNumber"
    }
}
