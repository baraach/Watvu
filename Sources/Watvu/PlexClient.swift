import Foundation

/// Plex sign-in: the app gets a PIN, you approve it on plex.tv in your
/// browser, and the app polls until the token arrives.
enum PlexAuth {
    private static let api = URL(string: "https://plex.tv/api/v2")!

    static func request(_ path: String, method: String = "GET", token: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: api)!.absoluteURL)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(MediaServerIdentity.product, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(MediaServerIdentity.deviceID, forHTTPHeaderField: "X-Plex-Client-Identifier")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        return request
    }

    struct Pin: Decodable {
        let id: Int
        let code: String
        let authToken: String?
    }

    static func requestPIN() async throws -> Pin {
        let (data, _) = try await URLSession.shared.data(for: request("api/v2/pins?strong=true", method: "POST"))
        return try JSONDecoder().decode(Pin.self, from: data)
    }

    /// The plex.tv page where the user approves the PIN.
    static func approvalURL(for pin: Pin) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.")
        let product = MediaServerIdentity.product.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "https://app.plex.tv/auth#?clientID=\(MediaServerIdentity.deviceID)&code=\(pin.code)&context%5Bdevice%5D%5Bproduct%5D=\(product)")!
    }

    /// Waits for approval (up to 5 minutes) and returns the token.
    static func waitForToken(pin: Pin) async throws -> String {
        for _ in 0..<150 {
            try await Task.sleep(for: .seconds(2))
            let (data, _) = try await URLSession.shared.data(for: request("api/v2/pins/\(pin.id)"))
            if let token = try JSONDecoder().decode(Pin.self, from: data).authToken, !token.isEmpty {
                return token
            }
        }
        throw AppError.network("Plex sign-in timed out. Try again.")
    }

    struct Resource: Decodable {
        struct Connection: Decodable {
            let uri: String
            let local: Bool?
            let relay: Bool?
        }
        let name: String
        let provides: String
        let accessToken: String?
        let connections: [Connection]?
    }

    /// Finds your Plex servers and connects to the first one that answers,
    /// preferring local addresses, then direct remote ones, then Plex's relay.
    static func firstReachableServer(token: String) async throws -> (name: String, client: PlexClient) {
        let (data, response) = try await URLSession.shared.data(for: request("api/v2/resources?includeHttps=1&includeRelay=1", token: token))
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw AppError.network("Plex didn't accept that token.")
        }
        let servers = try JSONDecoder().decode([Resource].self, from: data).filter { $0.provides.contains("server") }
        guard !servers.isEmpty else { throw AppError.network("No Plex servers found on this account.") }
        for server in servers {
            let connections = (server.connections ?? []).sorted { rank($0) < rank($1) }
            for connection in connections {
                guard let url = URL(string: connection.uri) else { continue }
                let client = PlexClient(serverURL: url, token: server.accessToken ?? token)
                if await client.isReachable() { return (server.name, client) }
            }
        }
        throw AppError.network("Couldn't reach your Plex server from this Mac.")
    }

    private static func rank(_ connection: Resource.Connection) -> Int {
        if connection.relay == true { return 2 }
        return connection.local == true ? 0 : 1
    }
}

/// One Plex server.
struct PlexClient {
    let serverURL: URL
    let token: String

    private func get(_ path: String) async throws -> PlexContainer {
        let url = URL(string: serverURL.absoluteString.trimmingCharacters(in: ["/"]) + path)!
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(MediaServerIdentity.deviceID, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(MediaServerIdentity.product, forHTTPHeaderField: "X-Plex-Product")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw AppError.network("Plex's sign-in has expired. Remove this playlist and add it again.")
        }
        return try JSONDecoder().decode(PlexResponse.self, from: data).container
    }

    func isReachable() async -> Bool {
        var request = URLRequest(url: serverURL.appendingPathComponent("identity"), timeoutInterval: 3)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Movie and show libraries.
    func libraries() async throws -> [PlexDirectory] {
        try await get("/library/sections").directories.filter { $0.type == "movie" || $0.type == "show" }
    }

    func items(sectionKey: String) async throws -> [PlexMetadata] {
        try await get("/library/sections/\(sectionKey)/all").metadata
    }

    func episodes(showKey: String) async throws -> [PlexMetadata] {
        try await get("/library/metadata/\(showKey)/allLeaves").metadata
    }

    /// Files AVPlayer can open play directly; anything else goes through the
    /// server's transcoder as HLS.
    func streamURL(for item: PlexMetadata) -> String {
        let base = serverURL.absoluteString.trimmingCharacters(in: ["/"])
        if let media = item.media?.first, let part = media.parts?.first?.key,
           ["mp4", "m4v", "mov"].contains(media.container ?? "") {
            return "\(base)\(part)?X-Plex-Token=\(token)"
        }
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "path", value: "/library/metadata/\(item.ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "session", value: item.ratingKey),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: MediaServerIdentity.deviceID),
            URLQueryItem(name: "X-Plex-Product", value: MediaServerIdentity.product),
            URLQueryItem(name: "X-Plex-Platform", value: "Safari"),
            URLQueryItem(name: "X-Plex-Token", value: token),
        ]
        return "\(base)/video/:/transcode/universal/start.m3u8?\(components.percentEncodedQuery ?? "")"
    }

    func imageURL(_ path: String?) -> String? {
        guard let path else { return nil }
        return "\(serverURL.absoluteString.trimmingCharacters(in: ["/"]))\(path)?X-Plex-Token=\(token)"
    }
}

private struct PlexResponse: Decodable {
    let container: PlexContainer
    enum CodingKeys: String, CodingKey { case container = "MediaContainer" }
}

struct PlexContainer: Decodable {
    let directories: [PlexDirectory]
    let metadata: [PlexMetadata]
    enum CodingKeys: String, CodingKey { case directories = "Directory", metadata = "Metadata" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        directories = try c.decodeIfPresent([PlexDirectory].self, forKey: .directories) ?? []
        metadata = try c.decodeIfPresent([PlexMetadata].self, forKey: .metadata) ?? []
    }
}

struct PlexDirectory: Decodable {
    let key: String
    let title: String
    let type: String
}

struct PlexMetadata: Decodable {
    struct Media: Decodable {
        struct Part: Decodable { let key: String? }
        let container: String?
        let parts: [Part]?
        enum CodingKeys: String, CodingKey { case container, parts = "Part" }
    }
    let ratingKey: String
    let title: String
    let type: String
    let summary: String?
    let year: Int?
    let thumb: String?
    let art: String?
    let index: Int?
    let parentIndex: Int?
    let media: [Media]?
    enum CodingKeys: String, CodingKey {
        case ratingKey, title, type, summary, year, thumb, art, index, parentIndex, media = "Media"
    }
}
