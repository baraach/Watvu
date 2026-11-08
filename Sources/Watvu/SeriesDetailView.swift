import SwiftUI
import Combine

/// Series sheet: season chips (sliding bar) and episode rows with resume
/// progress. Clicking an episode plays it.
struct SeriesDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let detail: SeriesDetail
    @StateObject private var state = SeriesDetailState()

    private var seasonKey: String { state.season ?? detail.seasons.first.map { "\($0.number)" } ?? "" }

    private var episodes: [SeriesEpisode] {
        detail.seasons.first { "\($0.number)" == seasonKey }?.episodes ?? []
    }

    private var subtitle: String {
        let seasons = detail.seasons.count
        let episodes = detail.allEpisodes.count
        return "\(seasons) season\(seasons == 1 ? "" : "s") · \(episodes) episode\(episodes == 1 ? "" : "s")"
    }

    private var tmdb: TMDBMetadata? {
        model.libraryIndex.shows.first(where: { $0.name == detail.title })?.tmdbMetadata
    }

    var body: some View {
        VStack(spacing: 0) {
            if let tmdb {   // TMDB header on the series page
                HStack(alignment: .top, spacing: 14) {
                    if let poster = tmdb.posterURL {
                        CachedAsyncImage(url: poster) { image in
                            image.resizable().scaledToFit()
                        }
                        .frame(width: 92, height: 138)
                        .cornerRadius(10)
                        .clipped()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(detail.title).font(.system(size: 18, weight: .bold))
                            if tmdb.voteAverage > 0 {
                                Label(String(format: "%.1f", tmdb.voteAverage), systemImage: "star.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.yellow)
                            }
                        }
                        if !tmdb.overview.isEmpty {
                            Text(tmdb.overview).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(4)
                        }
                        if let genres = tmdb.genres, !genres.isEmpty {
                            Text(genres.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            SheetHeader(title: detail.title, subtitle: subtitle) {
                SheetArtwork(key: detail.title, logo: nil, size: CGSize(width: 40, height: 40))
                    .overlay {
                        Image(systemName: "tv")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            } onClose: { dismiss() }

            if detail.seasons.count > 1 {
                FilterChipBar(
                    options: detail.seasons.map { "\($0.number)" },
                    selection: Binding(get: { seasonKey }, set: { state.season = $0 }),
                    labels: Dictionary(uniqueKeysWithValues: detail.seasons.map { ("\($0.number)", "Season \($0.number)") })
                )
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(episodes) { episode in
                        EpisodeRow(episode: episode, position: model.resumePosition(for: episode.id)) {
                            model.playEpisode(episode, detail: detail)
                            dismiss()
                        }
                        .contextMenu {
                            Button(model.isWatched(episode.id) ? L("Mark Unwatched") : L("Mark Watched")) {
                                model.toggleWatched(episode.id)
                            }
                            Button(L("Play from beginning")) {
                                model.clearPosition(for: episode.id)
                                model.playEpisode(episode, detail: detail)
                                dismiss()
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .id(seasonKey)
        }
        .frame(width: 620, height: 600)
        .background(Theme.background)
    }
}

private final class SeriesDetailState: ObservableObject {
    @Published var season: String?
}

private struct EpisodeRow: View {
    let episode: SeriesEpisode
    let position: PlaybackPosition?
    let action: () -> Void
    @StateObject private var hover = EpisodeHover()

    private var progress: Double? {
        guard let position, position.duration > 0 else { return nil }
        return min(max(position.seconds / position.duration, 0), 1)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text("\(episode.number)")
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(hover.isHovering ? Color.white : Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(
                        hover.isHovering ? Theme.accent : Theme.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text(episode.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let progress {
                        HStack(spacing: 8) {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .tint(Theme.accent)
                                .frame(width: 120)
                            Text("Resume")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } else {
                        Text("Episode \(episode.number)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(hover.isHovering ? Theme.accent : Theme.textSecondary.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Color.primary.opacity(hover.isHovering ? 0.07 : 0.03),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { hover.isHovering = hovering }
        }
        .accessibilityLabel("Play episode \(episode.number), \(episode.title)")
    }
}

private final class EpisodeHover: ObservableObject {
    @Published var isHovering = false
}


