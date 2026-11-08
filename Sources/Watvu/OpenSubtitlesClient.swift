import Foundation

struct OpenSubtitlesClient {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.opensubtitles.com/api/v1")!
    private let session: URLSession
    private var token: String?

    init(apiKey: String) {
        self.apiKey = apiKey
        self.session = URLSession.shared
    }

    mutating func login() async throws {
        let url = baseURL.appendingPathComponent("login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(OpenSubtitlesLoginResponse.self, from: data)
        token = response.token
    }

    func search(query: String, language: String = "eng") async throws -> [OpenSubtitlesSubtitle] {
        guard let token else { throw OpenSubtitlesError.notLoggedIn }

        let url = baseURL.appendingPathComponent("subtitles")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "query": query,
            "languages": [language]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(OpenSubtitlesSearchResponse.self, from: data)
        return response.data
    }

    func download(subtitleID: String) async throws -> URL {
        guard let token else { throw OpenSubtitlesError.notLoggedIn }

        let url = baseURL.appendingPathComponent("download")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["file_id": subtitleID]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(OpenSubtitlesDownloadResponse.self, from: data)
        
        guard let downloadURL = URL(string: response.link) else {
            throw OpenSubtitlesError.invalidURL
        }
        
        let (tempURL, _) = try await session.download(from: downloadURL)
        return tempURL
    }
}

enum OpenSubtitlesError: Error {
    case notLoggedIn
    case invalidURL
}

struct OpenSubtitlesLoginResponse: Codable {
    let token: String
}

struct OpenSubtitlesSearchResponse: Codable {
    let data: [OpenSubtitlesSubtitle]
}

struct OpenSubtitlesSubtitle: Codable {
    let id: String
    let attributes: OpenSubtitlesSubtitleAttributes
}

struct OpenSubtitlesSubtitleAttributes: Codable {
    let language: String
    let files: [OpenSubtitlesSubtitleFile]
    let featureDetails: OpenSubtitlesFeatureDetails?

    enum CodingKeys: String, CodingKey {
        case language, files
        case featureDetails = "feature_details"
    }
}

struct OpenSubtitlesSubtitleFile: Codable {
    let fileId: Int
    let fileName: String

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case fileName = "file_name"
    }
}

struct OpenSubtitlesFeatureDetails: Codable {
    let title: String?
    let seasonNumber: Int?
    let episodeNumber: Int?

    enum CodingKeys: String, CodingKey {
        case title
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
    }
}

struct OpenSubtitlesDownloadResponse: Codable {
    let link: String
}
