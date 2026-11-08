import SwiftUI

// MARK: - Model

/// A user-defined Home shelf. Feeds can be grouped into named collections.
struct HomeFeed: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var source: Source
    /// Optional collection name; feeds with the same name show under one heading.
    var collection: String = ""

    enum Source: Codable, Hashable {
        /// TMDB /discover: movies or shows, optional genre, minimum rating, year.
        case tmdbDiscover(tv: Bool, genreID: Int?, sort: String, minRating: Double, year: Int?)
        /// A Trakt list: `user` ("me" for yours), `list` slug or "watchlist".
        case traktList(user: String, list: String)
        /// Upcoming programmes in your guide matching a team, league or event.
        case guideEvents(keyword: String)
    }

    var kindLabel: String {
        switch source {
        case .tmdbDiscover(let tv, _, _, _, _): return tv ? L("TMDB shows") : L("TMDB movies")
        case .traktList(let user, let list): return list == "watchlist" ? L("Trakt watchlist") : "Trakt · \(user)/\(list)"
        case .guideEvents(let keyword): return L("Sports & events") + " · \(keyword)"
        }
    }

    var symbol: String {
        switch source {
        case .tmdbDiscover: return "film.stack"
        case .traktList: return "list.star"
        case .guideEvents: return "sportscourt"
        }
    }
}

/// One card in a feed shelf.
struct FeedEntry: Identifiable, Hashable {
    let id: String
    let title: String
    var subtitle: String? = nil
    var posterPath: String? = nil      // TMDB image path
    var imageURL: URL? = nil           // other artwork (channel logo)
    var rating: Double = 0
    var tmdbID: Int? = nil
    var isTV = false
    var channelID: String? = nil       // guide events: channel to play
    var start: Date? = nil
    var end: Date? = nil
}

enum TMDBGenres {
    static let movie: [(Int, String)] = [
        (28, "Action"), (12, "Adventure"), (16, "Animation"), (35, "Comedy"), (80, "Crime"),
        (99, "Documentary"), (18, "Drama"), (10751, "Family"), (14, "Fantasy"), (27, "Horror"),
        (9648, "Mystery"), (10749, "Romance"), (878, "Science Fiction"), (53, "Thriller"),
    ]
    static let tv: [(Int, String)] = [
        (10759, "Action & Adventure"), (16, "Animation"), (35, "Comedy"), (80, "Crime"),
        (99, "Documentary"), (18, "Drama"), (10751, "Family"), (9648, "Mystery"),
        (10765, "Sci-Fi & Fantasy"), (10768, "War & Politics"),
    ]
}

// MARK: - Loading

extension AppModel {
    private static let feedsKey = "homeFeeds"

    func loadHomeFeeds() {
        guard let data = UserDefaults.standard.data(forKey: Self.feedsKey),
              let feeds = try? JSONDecoder().decode([HomeFeed].self, from: data) else { return }
        homeFeeds = feeds
    }

    func saveHomeFeeds() {
        if let data = try? JSONEncoder().encode(homeFeeds) {
            UserDefaults.standard.set(data, forKey: Self.feedsKey)
        }
    }

    func addHomeFeed(_ feed: HomeFeed) {
        homeFeeds.append(feed)
        saveHomeFeeds()
        Task { await refreshFeed(feed) }
    }

    func removeHomeFeed(_ id: UUID) {
        homeFeeds.removeAll { $0.id == id }
        feedResults[id] = nil
        saveHomeFeeds()
    }

    func moveHomeFeed(_ id: UUID, up: Bool) {
        guard let index = homeFeeds.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 1
        guard homeFeeds.indices.contains(target) else { return }
        homeFeeds.swapAt(index, target)
        saveHomeFeeds()
    }

    func refreshAllFeeds() async {
        for feed in homeFeeds { await refreshFeed(feed) }
    }

    func refreshFeed(_ feed: HomeFeed) async {
        do {
            let entries: [FeedEntry]
            switch feed.source {
            case .tmdbDiscover(let tv, let genre, let sort, let minRating, let year):
                entries = try await discover(tv: tv, genre: genre, sort: sort, minRating: minRating, year: year)
            case .traktList(let user, let list):
                entries = try await traktListEntries(user: user, list: list)
            case .guideEvents(let keyword):
                entries = guideEvents(matching: keyword)
            }
            feedResults[feed.id] = entries
            feedErrors[feed.id] = nil
        } catch {
            feedErrors[feed.id] = error.localizedDescription
            Logger.shared.log("feeds", "\(feed.title): \(error.localizedDescription)")
        }
    }

    // TMDB /discover
    private func discover(tv: Bool, genre: Int?, sort: String, minRating: Double, year: Int?) async throws -> [FeedEntry] {
        guard let key = tmdbAPIKey else { throw FeedError.needsTMDB }
        var components = URLComponents(string: "https://api.themoviedb.org/3/discover/\(tv ? "tv" : "movie")")!
        var query = [URLQueryItem(name: "api_key", value: key),
                     URLQueryItem(name: "sort_by", value: sort),
                     URLQueryItem(name: "include_adult", value: "false")]
        if let genre { query.append(URLQueryItem(name: "with_genres", value: String(genre))) }
        if minRating > 0 {
            query.append(URLQueryItem(name: "vote_average.gte", value: String(minRating)))
            query.append(URLQueryItem(name: "vote_count.gte", value: "200"))
        }
        if let year { query.append(URLQueryItem(name: tv ? "first_air_date_year" : "primary_release_year", value: String(year))) }
        components.queryItems = query
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        if tv {
            return try JSONDecoder().decode(TMDBSearchResponse<TMDBTV>.self, from: data).results.prefix(20).map {
                FeedEntry(id: "tv\($0.id)", title: $0.name, posterPath: $0.posterPath, rating: $0.voteAverage, tmdbID: $0.id, isTV: true)
            }
        }
        return try JSONDecoder().decode(TMDBSearchResponse<TMDBMovie>.self, from: data).results.prefix(20).map {
            FeedEntry(id: "m\($0.id)", title: $0.title, posterPath: $0.posterPath, rating: $0.voteAverage, tmdbID: $0.id)
        }
    }

    // Trakt list or watchlist (posters looked up on TMDB when a key is set)
    private func traktListEntries(user: String, list: String) async throws -> [FeedEntry] {
        guard let clientID = UserDefaults.standard.string(forKey: "traktClientID"), !clientID.isEmpty else {
            throw FeedError.needsTrakt
        }
        let safeUser = user.trimmingCharacters(in: .whitespaces).isEmpty ? "me" : user
        let path = list == "watchlist" ? "users/\(safeUser)/watchlist" : "users/\(safeUser)/lists/\(list)/items"
        var request = URLRequest(url: URL(string: "https://api.trakt.tv/" + path)!)
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        if let token = CredentialStore.secret(forAccount: "trakt.accessToken") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FeedError.http(http.statusCode)
        }
        let rows = try JSONDecoder().decode([TraktListRow].self, from: data)
        var entries: [FeedEntry] = []
        for row in rows.prefix(20) {
            guard let media = row.movie ?? row.show else { continue }
            let isTV = row.show != nil
            var entry = FeedEntry(id: "t\(media.ids.trakt ?? 0)\(isTV)", title: media.title,
                                  subtitle: media.year.map(String.init), tmdbID: media.ids.tmdb, isTV: isTV)
            if let key = tmdbAPIKey, let id = media.ids.tmdb {
                entry.posterPath = await Self.tmdbPoster(id: id, tv: isTV, key: key)
            }
            entries.append(entry)
        }
        return entries
    }

    private static func tmdbPoster(id: Int, tv: Bool, key: String) async -> String? {
        guard let url = URL(string: "https://api.themoviedb.org/3/\(tv ? "tv" : "movie")/\(id)?api_key=\(key)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["poster_path"] as? String
    }

    /// Upcoming (next 7 days) and live programmes whose title or description
    /// mention `keyword` — e.g. a team, a league or "Formula 1".
    func guideEvents(matching keyword: String) -> [FeedEntry] {
        let needle = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let now = Date(), horizon = now.addingTimeInterval(7 * 86_400)
        var entries: [FeedEntry] = []
        for channel in items where channel.kind == .live && !isItemHidden(channel.id) {
            for program in programs(for: channel) where program.end > now && program.start < horizon {
                let haystack = (program.title + " " + (program.description ?? "")).lowercased()
                guard haystack.contains(needle) else { continue }
                entries.append(FeedEntry(
                    id: "\(channel.id)|\(program.start.timeIntervalSince1970)",
                    title: program.title,
                    subtitle: effectiveName(channel),
                    imageURL: effectiveLogo(channel).flatMap(URL.init(string:)),
                    channelID: channel.id, start: program.start, end: program.end))
            }
        }
        // One entry per programme (the same match is often on several channels).
        var seen = Set<String>()
        return entries.sorted { ($0.start ?? now) < ($1.start ?? now) }
            .filter { seen.insert("\($0.title)|\($0.start?.timeIntervalSince1970 ?? 0)").inserted }
            .prefix(24).map { $0 }
    }

    /// Opens a feed card: plays a library match or a live event, schedules a
    /// reminder for an upcoming event, otherwise opens the title on TMDB.
    func openFeedEntry(_ entry: FeedEntry) {
        if let channelID = entry.channelID, let channel = items.first(where: { $0.id == channelID }) {
            if let start = entry.start, start > Date() {
                scheduleEventReminder(entry)
            } else {
                activate(channel)
            }
            return
        }
        let key = NameCleaner.cleaned(entry.title).lowercased()
        if let match = items.first(where: {
            ($0.kind == (entry.isTV ? .series : .movie)) && NameCleaner.cleaned(effectiveName($0)).lowercased() == key
        }) {
            activate(match)
        } else if let id = entry.tmdbID,
                  let url = URL(string: "https://www.themoviedb.org/\(entry.isTV ? "tv" : "movie")/\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func scheduleEventReminder(_ entry: FeedEntry) {
        guard let start = entry.start else { return }
        Task {
            let body = String(format: L("%@ starts at %@."), entry.title, start.formatted(date: .omitted, time: .shortened))
            guard (try? await Reminders.schedule(id: "event-\(entry.id)", title: entry.subtitle ?? L("Starting soon"),
                                                 body: body, at: start)) == true else { return }
            statusText = String(format: L("Reminder set for %@"), entry.title)
        }
    }
}

enum FeedError: LocalizedError {
    case needsTMDB, needsTrakt, http(Int)
    var errorDescription: String? {
        switch self {
        case .needsTMDB: return L("Add a TMDB API key in Settings → Services.")
        case .needsTrakt: return L("Sign in to Trakt in Settings → Services.")
        case .http(let code): return String(format: L("The service answered with error %d."), code)
        }
    }
}

private struct TraktListRow: Decodable {
    struct Media: Decodable {
        struct IDs: Decodable { let trakt: Int?; let tmdb: Int? }
        let title: String
        let year: Int?
        let ids: IDs
    }
    let movie: Media?
    let show: Media?
}

// MARK: - Home UI

/// The "Your feeds" Home section: each feed is a shelf, grouped under its
/// collection's heading.
struct HomeFeedsSection: View {
    @EnvironmentObject var model: AppModel
    let lead: CGFloat

    private var collections: [(String, [HomeFeed])] {
        var order: [String] = []
        var groups: [String: [HomeFeed]] = [:]
        for feed in model.homeFeeds {
            if groups[feed.collection] == nil { order.append(feed.collection) }
            groups[feed.collection, default: []].append(feed)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            ForEach(collections, id: \.0) { name, feeds in
                VStack(alignment: .leading, spacing: 20) {
                    if !name.isEmpty {
                        Text(name.uppercased())
                            .font(.system(size: 12, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(Theme.accent)
                            .padding(.leading, lead)
                    }
                    ForEach(feeds) { feed in shelf(feed) }
                }
            }
        }
    }

    @ViewBuilder
    private func shelf(_ feed: HomeFeed) -> some View {
        let entries = model.feedResults[feed.id] ?? []
        if !entries.isEmpty || model.feedErrors[feed.id] != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: feed.symbol).foregroundStyle(Theme.accent)
                    Text(feed.title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(.leading, lead)
                if let error = model.feedErrors[feed.id], entries.isEmpty {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.leading, lead)
                } else {
                    SlidingRow(margin: 36, trailingMargin: 36, spacing: 20) {
                        ForEach(entries) { entry in
                            FeedEntryCard(entry: entry) { model.openFeedEntry(entry) }
                        }
                    }
                    .stopsAtSidebar(lead - 36)
                }
            }
        }
    }
}

/// Poster card (TMDB/Trakt) or event card (guide: logo, time, channel).
private struct FeedEntryCard: View {
    let entry: FeedEntry
    let onTap: () -> Void

    private var isEvent: Bool { entry.channelID != nil }
    private var isLive: Bool {
        guard let start = entry.start, let end = entry.end else { return false }
        return start <= Date() && Date() < end
    }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottom) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    if isEvent {
                        Text(isLive ? L("LIVE NOW") : (entry.start.map(Self.when) ?? ""))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isLive ? Theme.accent : .white.opacity(0.85))
                    }
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(isEvent ? 2 : 1)
                    HStack(spacing: 4) {
                        if let subtitle = entry.subtitle {
                            Text(subtitle).lineLimit(1)
                        }
                        if entry.rating > 0 {
                            Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                            Text(String(format: "%.1f", entry.rating)).foregroundStyle(.yellow)
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                                   .init(color: .black.opacity(0.85), location: 1)],
                                           startPoint: .top, endPoint: .bottom))
            }
            .frame(width: isEvent ? 260 : 184, height: isEvent ? 160 : 276)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isEvent && !isLive ? L("Click to get a reminder") : entry.title)
    }

    @ViewBuilder
    private var artwork: some View {
        if let path = entry.posterPath, let url = URL(string: "https://image.tmdb.org/t/p/w342\(path)") {
            CachedAsyncImage(url: url) { $0.resizable().scaledToFill() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else if let url = entry.imageURL {
            ZStack {
                Theme.gradient(for: entry.subtitle ?? entry.title).opacity(0.5)
                Color.black.opacity(0.35)
                CachedAsyncImage(url: url) { $0.resizable().scaledToFit() }
                    .padding(.horizontal, 40)
                    .padding(.top, 16)
                    .padding(.bottom, 70)
            }
        } else {
            Theme.gradient(for: entry.title)
        }
    }

    private static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return L("Today") + " " + time }
        if calendar.isDateInTomorrow(date) { return L("Tomorrow") + " " + time }
        return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
    }
}
