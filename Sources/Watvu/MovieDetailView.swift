import SwiftUI
import AppKit

/// Detail sheet for a movie. Uses Xtream `get_vod_info` when available and
/// falls back to the card data for M3U movies.
struct MovieDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let detail: MovieDetailItem

    private var item: MediaItem { detail.item }
    private var info: MovieDetail? { detail.detail }

    private var title: String { info?.title ?? item.name }
    private var backdropURL: URL? {
        (info?.backdrop ?? item.backdrop).flatMap(URL.init(string:))
    }
    private var posterURL: URL? {
        (item.tmdbMetadata?.posterURL?.absoluteString ?? info?.poster ?? item.logo).flatMap(URL.init(string:))   // B46
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if let plot = (item.tmdbMetadata?.overview).nonEmpty ?? info?.plot ?? item.subtitle, !plot.isEmpty {   // B46
                        Text(plot)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        Text("No description available.")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                    }

                    if let cast = info?.cast, !cast.isEmpty {
                        creditRow("Cast", cast)
                    }
                    if let director = info?.director, !director.isEmpty {
                        creditRow("Director", director)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .frame(width: 760, height: 640)
        .background(Theme.background)
    }

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            backdrop
                .frame(height: 300)
                .clipped()

            LinearGradient(
                colors: [.black.opacity(0.15), .black.opacity(0.15), .black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(alignment: .bottom, spacing: 18) {
                poster
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    metadata
                    if let genre = info?.genre, !genre.isEmpty {
                        Text(genre)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(24)

            SheetCloseButton { dismiss() }
                .environment(\.colorScheme, .dark)
                .padding(16)
        }
        .frame(height: 300)
    }

    @ViewBuilder
    private var backdrop: some View {
        if let url = backdropURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    Color.clear.overlay { image.resizable().scaledToFill() }
                default:
                    Theme.heroGradient(for: item.group)
                }
            }
        } else {
            Theme.heroGradient(for: item.group)
        }
    }

    private var poster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.gradient(for: title))
            if let url = posterURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        Color.clear.overlay { image.resizable().scaledToFill() }
                    }
                }
            } else {
                Text(item.name.prefix(2).uppercased())
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: 130, height: 195)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            if let year = info?.releaseDate?.prefix(4), !year.isEmpty {
                Text(String(year))
            }
            if let rating = item.tmdbMetadata?.voteAverage ?? info?.rating, rating > 0 {   // B46
                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                    .labelStyle(.titleAndIcon)
            }
            if let duration = info?.duration, !duration.isEmpty {
                Text(duration)
            }
            Text(item.kind.title)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white.opacity(0.82))
    }

    private func creditRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                model.toggleFavorite(item.id)
            } label: {
                Label(
                    model.isFavorite(item.id) ? "Favorited" : "Favorite",
                    systemImage: model.isFavorite(item.id) ? "heart.fill" : "heart"
                )
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .glassButton()

            if let trailer = info?.trailer, let url = URL(string: trailer) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Trailer", systemImage: "play.rectangle")
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .glassButton()
            }

            Spacer()

            Button {
                model.play(item)
                dismiss()
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .glassProminentButton()
        }
        .padding(20)
    }
}
