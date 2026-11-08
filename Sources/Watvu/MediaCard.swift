import SwiftUI

enum MediaCardStyle {
    case landscape
    case poster

    var width: CGFloat {
        switch self {
        case .landscape: return 300
        case .poster: return 190
        }
    }

    var height: CGFloat {
        switch self {
        case .landscape: return 169
        case .poster: return 285
        }
    }
}

/// Media tile. Reads only what it needs from the model, then hands off to an
/// equatable content view so unrelated model updates don't redraw every card.
struct MediaCard: View {
    @EnvironmentObject var model: AppModel
    let item: MediaItem
    var style: MediaCardStyle = .landscape

    @StateObject private var menuUI = CardMenuUI()

    private var displayItem: MediaItem {
        var copy = item
        copy.name = model.effectiveName(item)
        copy.logo = model.effectiveLogo(item)
        copy.group = model.effectiveGroup(item)
        return copy
    }

    var body: some View {
        MediaCardContent(
            item: displayItem,
            style: style,
            now: model.nowPlaying(for: item),
            resume: model.resumePosition(for: item.id)?.fraction,
            onActivate: { model.activate(item) }
        )
        .equatable()
        .alert(L("Rename"), isPresented: Binding(get: { menuUI.renameTarget != nil }, set: { if !$0 { menuUI.renameTarget = nil } })) {
            TextField(L("Name"), text: Binding(get: { menuUI.renameText }, set: { menuUI.renameText = $0 }))
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Save")) {
                if let target = menuUI.renameTarget { model.renameItem(target.id, to: menuUI.renameText) }
            }
        }
        .alert(L("Thumbnail URL"), isPresented: Binding(get: { menuUI.thumbURLTarget != nil }, set: { if !$0 { menuUI.thumbURLTarget = nil } })) {
            TextField("https://…", text: Binding(get: { menuUI.thumbText }, set: { menuUI.thumbText = $0 }))
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Save")) {
                if let target = menuUI.thumbURLTarget { model.setItemLogo(target.id, url: menuUI.thumbText) }
            }
        }
        .fileImporter(isPresented: Binding(get: { menuUI.showThumbPicker }, set: { menuUI.showThumbPicker = $0 }),
                      allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first, let target = menuUI.thumbTarget {
                model.setItemLogo(target.id, url: url.absoluteString)
            }
        }
        .contextMenu {
            Button(model.isFavorite(item.id) ? L("Remove from Favorites") : L("Add to Favorites")) {
                model.toggleFavorite(item.id)
            }
            Button(model.isWatched(item.id) ? L("Mark Unwatched") : L("Mark Watched")) {
                model.toggleWatched(item.id)
            }
            Button(model.isHidden(item.id) ? L("Unhide") : L("Hide")) {   // B13
                model.setHidden(!model.isHidden(item.id), for: item.id)
            }
            Button(model.isLocked(item.id) ? L("Unlock") : L("Lock")) {   // B14/B47
                if model.isLocked(item.id) {
                    model.unlockAfterPin = true
                    model.pendingUnlock = item   // ask for the PIN first
                } else {
                    model.setLocked(true, for: item.id)
                }
            }
            Button(L("Rename…")) { menuUI.renameText = model.effectiveName(item); menuUI.renameTarget = item }
            Button(L("Set thumbnail from URL…")) { menuUI.thumbText = model.effectiveLogo(item) ?? ""; menuUI.thumbTarget = item; menuUI.thumbURLTarget = item }
            Button(L("Pick thumbnail file…")) { menuUI.thumbTarget = item; menuUI.showThumbPicker = true }
            if item.kind == .live {
                Menu(L("Catch-up offset")) {
                    ForEach([-120, -60, -30, -15, 0, 15, 30, 60, 120], id: \.self) { minutes in
                        Button(minutes == 0 ? L("None") : (minutes > 0 ? "+\(minutes) min" : "\(minutes) min")) {
                            model.setCatchupOffset(minutes * 60, for: item.id)
                        }
                    }
                    if model.catchupOffset(for: item) != 0 {
                        Text("Current: \(model.catchupOffset(for: item) / 60) min").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Menu(L("Move to category")) {
                ForEach(model.groups(kind: item.kind, favoritesOnly: false), id: \.self) { group in
                    Button(group) { model.moveItemToCategory(item.id, group: group) }
                }
            }
            if model.playlists.contains(where: { $0.id == item.playlistID }) {
                Button(L("Download")) {
                    if let playlist = model.playlists.first(where: { $0.id == item.playlistID }) {
                        DownloadManager.shared.startDownload(item, playlist: playlist)
                    }
                }
            }
        }
    }
}

private final class CardMenuUI: ObservableObject {
    @Published var renameTarget: MediaItem?
    @Published var renameText = ""
    @Published var thumbTarget: MediaItem?
    @Published var thumbURLTarget: MediaItem?
    @Published var thumbText = ""
    @Published var showThumbPicker = false
}

struct MediaCardContent: View, Equatable {
    static func == (lhs: MediaCardContent, rhs: MediaCardContent) -> Bool {
        lhs.item.id == rhs.item.id
            && lhs.item.name == rhs.item.name
            && lhs.item.subtitle == rhs.item.subtitle
            && lhs.item.group == rhs.item.group
            && lhs.item.logo == rhs.item.logo
            && lhs.style == rhs.style
            && lhs.now?.id == rhs.now?.id
            && lhs.resume == rhs.resume
    }

    let item: MediaItem
    let style: MediaCardStyle
    let now: EPGProgram?
    let resume: Double?
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            ZStack(alignment: .bottom) {
                Color.clear   // R9: fixed-size container…
                    .aspectRatio(style == .poster ? 0.667 : 1.78, contentMode: .fit)
                    .overlay { artwork }   // …image overlaid and cropped inside it
                    .clipped()

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 4) {
                        Text(item.name)
                            .font(.system(size: style == .poster ? 14 : 16, weight: .semibold))
                            .foregroundStyle(.white)   // R8: readable over any artwork
                            .lineLimit(1)
                        if let rating = item.tmdbMetadata?.voteAverage, rating > 0 {   // B46
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill").font(.system(size: 10))
                                Text(String(format: "%.1f", rating)).font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(.yellow)
                        }
                    }
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.85))   // R8
                            .lineLimit(1)
                    }
                    if style == .landscape, let now {
                        Text("\(now.timeRange)  \(now.title)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                    if style == .landscape {
                        Text(item.group)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))   // R8
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(style == .poster ? 12 : 16)
                .background(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0), location: 0),
                            .init(color: .black.opacity(0.85), location: 1)   // R8
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                if let resume {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.18))
                        Rectangle()
                            .fill(Theme.accent)
                            .scaleEffect(x: resume, y: 1, anchor: .leading)
                    }
                    .frame(height: 3)
                    .accessibilityLabel(L("Progress"))
                    .accessibilityValue(String(format: L("%.0f percent"), resume * 100))
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            // R12: clipping hides overflowing artwork but doesn't stop clicks
            // on it, so limit hit-testing to the visible card.
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityHint(L("Double tap to play"))
        }
        .buttonStyle(.plain)
        .clipped()   // R9: artwork must not spill over neighbouring cells
    }

    /// Channel logos (live items without a TMDB poster) are shown whole;
    /// posters and backdrops fill the card.
    private var showsLogo: Bool {
        item.kind == .live && item.tmdbMetadata?.posterURL == nil
    }

    private var artwork: some View {
        Group {
            if let url = item.tmdbMetadata?.posterURL ?? item.logo.flatMap({ URL(string: $0) }) {   // B46
                if showsLogo {
                    // R11: fit the logo with padding, above the title area.
                    ZStack {
                        Theme.gradient(for: item.name).opacity(0.35)
                        Color.black.opacity(0.35)
                        CachedAsyncImage(url: url) { image in
                            image.resizable().scaledToFit()
                        }
                        .padding(.horizontal, style == .poster ? 18 : 36)
                        .padding(.top, style == .poster ? 18 : 16)
                        .padding(.bottom, style == .poster ? 70 : 62)
                    }
                } else {
                    CachedAsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    }
                }
            } else {
                Theme.gradient(for: item.name)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // R9: image fills the fixed-size container…
        .clipped()                                            // …and is cropped, never grows the card
        .allowsHitTesting(false)                              // R12: overflow never takes clicks
    }
}
