import SwiftUI
import Combine

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.sidebarInset) private var sidebarInset
    @StateObject private var scroll = ScrollActivity()
    @AppStorage(SettingsKeys.welcomeSkipped) private var welcomeSkipped = false
    private var lead: CGFloat { sidebarInset + 36 }

    private func isVisible(_ item: MediaItem, hiddenIDs: Set<String>, hiddenGroups: Set<String>) -> Bool {
        !hiddenIDs.contains(item.id) && !hiddenGroups.contains(item.group)
    }

    /// One from each kind, so the banner shows everything the library has.
    /// Posters first: channel logos look poor at this size.
    private var featuredItems: [MediaItem] {
        [MediaKind.movie, .series, .live].compactMap { firstItems($0, limit: 1).first }
    }

    // Lazy: stop after the ones shown instead of filtering the whole library.
    // Entries with artwork come first; the rest only fill a short shelf.
    private func firstItems(_ kind: MediaKind, limit: Int = 20) -> [MediaItem] {
        let hiddenIDs = model.hiddenItemIDs, hiddenGroups = model.hiddenCategories
        let visible = model.libraryIndex.list(kind).lazy
            .filter { isVisible($0, hiddenIDs: hiddenIDs, hiddenGroups: hiddenGroups) }
        let withArt = Array(visible.filter { !($0.logo ?? "").isEmpty }.prefix(limit))
        return withArt.count == limit ? withArt : Array(visible.prefix(limit))
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                if model.items.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 32) {
                        ForEach(model.homeOrder) { section in
                            if model.isHomeSectionVisible(section) {
                                sectionView(section)
                            }
                        }
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 48)
                }
            }
        }
        .tracksScrolling(scroll)
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
        .navigationTitle("Home")
    }

    @ViewBuilder
    private func sectionView(_ section: HomeSection) -> some View {
        switch section {
        case .hero:
            HeroCarousel(items: featuredItems)
        case .continueWatching:
            let recents = model.recentItems.filter { !model.isItemHidden($0.id) }
            if !recents.isEmpty { shelf("Continue watching", items: recents, style: .landscape) }
        case .trending:
            if !model.trending.isEmpty { feedShelf("Trending", movies: model.trending) }
        case .recommended:
            if !model.recommended.isEmpty { feedShelf("Because you watch", movies: model.recommended) }
        case .popularTV:
            if !model.popularTV.isEmpty {
                feedShelfTV("Popular on TV", shows: model.popularTV)
            }
        case .customFeeds:
            if !model.homeFeeds.isEmpty { HomeFeedsSection(lead: lead) }
        case .live:
            shelf("Live TV", items: firstItems(.live), style: .landscape, section: .live)
        case .movies:
            shelf("Movies", items: firstItems(.movie), style: .poster, section: .movies)
        case .series:
            shelf("Series", items: firstItems(.series), style: .poster, section: .series)
        }
    }

    @ViewBuilder
    private func shelf(_ title: String, items: [MediaItem], style: MediaCardStyle, section: LibrarySection? = nil) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)

                    Spacer()

                    if let section {
                        Button {
                            model.selection = section
                        } label: {
                            HStack(spacing: 3) {
                                Text("See All")
                                Image(systemName: "chevron.right")
                                    .imageScale(.small)
                            }
                        }
                        .buttonBorderShape(.capsule)
                        .glassButton()
                    }
                }
                .padding(.leading, lead)
                .padding(.trailing, 36)

                // Cards stop at the sidebar's edge; hover arrows page the row,
                // cards snap into place.
                SlidingRow(margin: 36, trailingMargin: 36, spacing: 20) {
                    ForEach(items) { item in
                        MediaCard(item: item, style: style)
                            .frame(width: style == .poster ? 184 : 300, height: style.height)   // R6/R7
                            .clipped()
                            .contextMenu {
                                Button("Remove from Recent") {
                                    model.removeFromRecent(item.id)
                                }
                            }
                    }
                }
                .stopsAtSidebar(sidebarInset)
            }
        }
    }

    private func feedShelf(_ title: String, movies: [TMDBMovie]) -> some View {
        shelfShell(title) {
            ForEach(movies.prefix(12)) { movie in
                FeedCard(title: movie.title, posterPath: movie.posterPath, rating: movie.voteAverage, tmdbID: movie.id) {
                    if let match = model.libraryIndex.movies.first(where: { NameCleaner.cleaned($0.name).lowercased() == movie.title.lowercased() }) {
                        model.activate(match)
                    } else if let url = URL(string: "https://www.themoviedb.org/movie/\(movie.id)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func feedShelfTV(_ title: String, shows: [TMDBTV]) -> some View {
        shelfShell(title) {
            ForEach(shows.prefix(12)) { show in
                FeedCard(title: show.name, posterPath: show.posterPath, rating: show.voteAverage, tmdbID: show.id) {
                    if let match = model.libraryIndex.shows.first(where: { NameCleaner.cleaned($0.name).lowercased() == NameCleaner.cleaned(show.name).lowercased() }) {
                        model.activate(match)
                    } else if let url = URL(string: "https://www.themoviedb.org/tv/\(show.id)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func shelfShell<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(title))
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.leading, lead)
                .padding(.trailing, 36)
            SlidingRow(margin: 36, trailingMargin: 36, spacing: 20) {
                content()
            }
            .stopsAtSidebar(sidebarInset)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "tray")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Theme.accent)

            Text(model.playlists.isEmpty ? L("No playlists yet") : L("Nothing to show yet"))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.textPrimary)

            Text(model.playlists.isEmpty
                 ? L("Add a playlist or connect a service to start watching.")
                 : L("Your playlists don't have any items. Refresh them, or add another."))
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)

            Button {
                NotificationCenter.default.post(name: .addPlaylist, object: nil)
            } label: {
                Label("Add Playlist", systemImage: "plus")
                    .padding(.horizontal, 8)
            }
            .controlSize(.extraLarge)
            .buttonBorderShape(.capsule)
            .glassProminentButton()
            .padding(.top, 6)

            if model.playlists.isEmpty {
                Button(L("Show the setup screen")) { welcomeSkipped = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, sidebarInset)
        .padding(.top, 120)
        .padding(.bottom, 120)
    }
}

private struct HeroCarousel: View {
    @EnvironmentObject var model: AppModel
    let items: [MediaItem]
    @StateObject private var state = HeroState()
    private let timer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if let item = current {
                HeroBanner(item: item, index: state.index, count: items.count) { newIndex in
                    withAnimation(.smooth(duration: 0.7)) {
                        state.index = newIndex
                    }
                }
                .id(item.id)
                .transition(.opacity)
            }
        }
        .onReceive(timer) { _ in
            advance()
        }
        .onChange(of: items.count) { _, count in
            if state.index >= count { state.index = 0 }
        }
    }

    private func advance() {
        guard items.count > 1 else { return }
        withAnimation(.smooth(duration: 0.7)) {
            state.index = (state.index + 1) % items.count
        }
    }

    private var current: MediaItem? {
        guard !items.isEmpty else { return nil }
        return items[min(state.index, items.count - 1)]
    }
}

private final class HeroState: ObservableObject {
    @Published var index = 0
}

private struct HeroBanner: View {
    @EnvironmentObject var model: AppModel
    let item: MediaItem
    let index: Int
    let count: Int
    let onSelect: (Int) -> Void
    @Environment(\.sidebarInset) private var sidebarInset

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                // Artwork + scrims flattened into one GPU layer (no glass
                // inside); the glass Play button and dots stay live above.
                ZStack {
                    backdrop(width: proxy.size.width, height: proxy.size.height)

                    LinearGradient(
                        colors: [.black.opacity(0.35), .clear, .black.opacity(0.1), Theme.background],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    LinearGradient(
                        colors: [.black.opacity(0.55), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .drawingGroup()

                content

                if count > 1 {
                    dots
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: 400)   // leaves room for the shelves on the first screen
        .clipped()
        // Fade into the page (no hard edge under the sidebar glass). An
        // overlay, not a mask: a mask re-renders the whole hero offscreen.
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 112)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func backdrop(width: CGFloat, height: CGFloat) -> some View {
        if let backdrop = item.backdrop, let url = URL(string: backdrop) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Theme.heroGradient(for: item.group)
                case .empty:
                    Theme.heroGradient(for: item.group)
                @unknown default:
                    Theme.heroGradient(for: item.group)
                }
            }
            .frame(width: width, height: height)
            .clipped()
        } else {
            ZStack {
                Theme.heroGradient(for: item.group)

                if let logo = item.logo, let url = URL(string: logo) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFit()
                        }
                    }
                    .frame(width: min(width * 0.36, 460))
                    .opacity(0.9)
                    .offset(x: width * 0.2)
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
                }
            }
            .frame(width: width, height: height)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.kind == .live ? L("FEATURED · LIVE") : L("FEATURED"))
                .font(.system(size: 12, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.9))

            Text(item.name)
                .font(.system(size: 52, weight: .heavy))
                .lineLimit(2)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)

            HStack(spacing: 6) {
                Text(item.kind.title)
                    .font(.system(size: 14, weight: .semibold))
                if let now = model.nowPlaying(for: item) {
                    Text("·")
                    Text(now.timeRange)
                    Text("·")
                    Text(now.title)
                        .lineLimit(1)
                } else if !item.group.isEmpty {
                    Text("·")
                    Text(item.group)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.82))

            if let description = descriptionText {
                Text(description)
                    .font(.system(size: 15))
                    .lineLimit(3)
                    .frame(maxWidth: 640, alignment: .leading)
                    .foregroundStyle(.white.opacity(0.8))
            }

            Button {
                model.activate(item)
            } label: {
                Label(item.kind == .series ? "More Info" : "Play", systemImage: item.kind == .series ? "info.circle.fill" : "play.fill")
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
            }
            .controlSize(.extraLarge)
            .buttonBorderShape(.capsule)
            // Clear glass over artwork.
            .glassButton()
            .environment(\.colorScheme, .dark)
            .padding(.top, 6)
        }
        .padding(.leading, sidebarInset + 36)
        .padding(.trailing, 36)
        .padding(.bottom, 104)
        .frame(maxWidth: 760 + sidebarInset, alignment: .leading)
    }

    private var descriptionText: String? {
        if let now = model.nowPlaying(for: item), let description = now.description, !description.isEmpty {
            return description
        }
        if let subtitle = item.subtitle, !subtitle.isEmpty {
            return subtitle
        }
        return nil
    }

    private var dots: some View {
        VStack {
            Spacer()
            HStack(spacing: 7) {
                ForEach(0..<count, id: \.self) { dot in
                    Button {
                        onSelect(dot)
                    } label: {
                        Capsule()
                            .fill(dot == index ? Color.white : Color.white.opacity(0.4))
                            .frame(width: dot == index ? 18 : 7, height: 7)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Featured item \(dot + 1) of \(count)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassSurface(in: Capsule())
            .environment(\.colorScheme, .dark)
            .animation(.snappy, value: index)
            .padding(.bottom, 124)
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, sidebarInset)
    }
}

/// Poster card for a TMDB trending title (not necessarily in the library).
private struct FeedCard: View {
    let title: String
    let posterPath: String?
    let rating: Double
    let tmdbID: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottom) {
                if let path = posterPath,
                   let url = URL(string: "https://image.tmdb.org/t/p/w342\(path)") {
                    CachedAsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    }
                } else {
                    Theme.gradient(for: title)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 4) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if rating > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill").font(.system(size: 9))
                                Text(String(format: "%.1f", rating)).font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(.yellow)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(LinearGradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black.opacity(0.85), location: 1)], startPoint: .top, endPoint: .bottom))
            }
            .frame(width: 184, height: 276)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
