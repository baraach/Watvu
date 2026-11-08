import Foundation

struct TMDBClient {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.themoviedb.org/3")!

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type = T.self) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)] + query
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func list<T: Codable>(_ path: String, query: [URLQueryItem] = []) async throws -> [T] {
        try await get(path, query: query, as: TMDBSearchResponse<T>.self).results
    }

    func popularTV() async throws -> [TMDBTV] { try await list("tv/popular") }
    func recommendations(movieID: Int) async throws -> [TMDBMovie] { try await list("movie/\(movieID)/recommendations") }
    func trendingMovies() async throws -> [TMDBMovie] { try await list("trending/movie/week") }
    func searchMovie(query: String) async throws -> [TMDBMovie] {
        try await list("search/movie", query: [URLQueryItem(name: "query", value: query)])
    }
    func searchTV(query: String) async throws -> [TMDBTV] {
        try await list("search/tv", query: [URLQueryItem(name: "query", value: query)])
    }
    func movieDetails(id: Int) async throws -> TMDBMovie { try await get("movie/\(id)") }
    func tvDetails(id: Int) async throws -> TMDBTV { try await get("tv/\(id)") }
}

struct TMDBSearchResponse<T: Codable>: Codable {
    let results: [T]
}

struct TMDBMovie: Codable, Identifiable {
    let id: Int
    let title: String
    let posterPath: String?
    let overview: String
    let voteAverage: Double
    let runtime: Int?
    let releaseDate: String?
    let genres: [TMDBGenre]?
    let videos: TMDBVideosResponse?

    enum CodingKeys: String, CodingKey {
        case id, title, overview, runtime, genres
        case posterPath = "poster_path"
        case voteAverage = "vote_average"
        case releaseDate = "release_date"
        case videos
    }
}

struct TMDBTV: Codable, Identifiable {
    let id: Int
    let name: String
    let posterPath: String?
    let overview: String
    let voteAverage: Double
    let numberOfSeasons: Int?
    let firstAirDate: String?
    let genres: [TMDBGenre]?
    let videos: TMDBVideosResponse?

    enum CodingKeys: String, CodingKey {
        case id, name, overview, genres
        case posterPath = "poster_path"
        case voteAverage = "vote_average"
        case numberOfSeasons = "number_of_seasons"
        case firstAirDate = "first_air_date"
        case videos
    }
}

struct TMDBGenre: Codable {
    let id: Int
    let name: String
}

struct TMDBVideosResponse: Codable {
    let results: [TMDBVideo]
}

struct TMDBVideo: Codable {
    let key: String
    let site: String
    let type: String
}
