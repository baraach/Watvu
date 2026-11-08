import Foundation

struct TraktClient {
    let clientID: String
    let clientSecret: String
    private let redirectURI = "watvu://trakt/auth"
    private let baseURL = URL(string: "https://api.trakt.tv")!
    private let session: URLSession
    var accessToken: String?
    var refreshToken: String?

    init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.session = URLSession.shared
    }

    mutating func authenticate() async throws -> URL {
        let url = baseURL.appendingPathComponent("oauth/authorize")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code")
        ]
        return components.url!
    }

    mutating func exchangeCodeForToken(code: String) async throws {
        let url = baseURL.appendingPathComponent("oauth/token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(TraktTokenResponse.self, from: data)
        accessToken = response.accessToken
        refreshToken = response.refreshToken
    }

    mutating func refreshAccessToken() async throws {
        guard let refreshToken else { throw TraktError.noRefreshToken }

        let url = baseURL.appendingPathComponent("oauth/token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "refresh_token": refreshToken,
            "client_id": clientID,
            "client_secret": clientSecret,
            "grant_type": "refresh_token"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(TraktTokenResponse.self, from: data)
        accessToken = response.accessToken
        self.refreshToken = response.refreshToken ?? refreshToken
    }

    /// Reports playback to Trakt. `phase` is "start", "pause" or "stop".
    func scrobble(_ phase: String, item: MediaItem, progress: Double) async throws {
        var request = try authorisedRequest(baseURL.appendingPathComponent("scrobble/\(phase)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "movie": ["title": item.name],
            "progress": progress,
        ] as [String: Any])
        _ = try await session.data(for: request)
    }

    private func authorisedRequest(_ url: URL) throws -> URLRequest {
        guard let accessToken else { throw TraktError.notAuthenticated }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        return request
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        // `path` may carry a query, so it can't go through appendingPathComponent.
        guard let url = URL(string: path, relativeTo: baseURL) else { throw URLError(.badURL) }
        var request = try authorisedRequest(url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func watchlist() async throws -> [TraktMedia] {
        try await get("sync/watchlist/movies", as: [TraktEntry].self).map(\.movie)
    }

    func history() async throws -> [TraktMedia] {
        try await get("sync/history/movies?page=1&limit=100", as: [TraktEntry].self).map(\.movie)
    }
}

enum TraktError: Error {
    case notAuthenticated
    case noRefreshToken
}

struct TraktTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

struct TraktMedia: Codable {
    let title: String
    let year: Int?
}

private struct TraktEntry: Codable {
    let movie: TraktMedia
}
