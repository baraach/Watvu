import SwiftUI

/// Reruns a page's filter when the filter or the library changes.
struct LibraryPageKey: Equatable {
    let query: LibraryQuery
    let indexCount: UUID
}

/// A page's results, filtered off the main thread. Grids draw in pages so a
/// list of 50,000 films costs no more than a list of 200.
@MainActor
final class LibraryResults: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var isLoading = true
    @Published private(set) var displayCount = LibraryResults.pageSize
    static let pageSize = 200

    var visible: ArraySlice<MediaItem> { items.prefix(displayCount) }

    func load(_ query: LibraryQuery, index: LibraryIndex) async {
        if !query.search.isEmpty {   // wait for typing to pause
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
        isLoading = true
        let found = await Task.detached(priority: .userInitiated) { query.run(on: index) }.value
        if Task.isCancelled { return }
        items = found
        displayCount = Self.pageSize
        isLoading = false
    }

    func showMore(after item: MediaItem) {
        guard displayCount < items.count,
              item.id == items[min(displayCount, items.count) - 1].id else { return }
        displayCount += Self.pageSize
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case name, recentlyAdded, recentlyWatched

    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return L("Name")
        case .recentlyAdded: return L("Recently Added")
        case .recentlyWatched: return L("Recently Watched")
        }
    }
    var symbol: String {
        switch self {
        case .name: return "textformat"
        case .recentlyAdded: return "calendar.badge.plus"
        case .recentlyWatched: return "clock.arrow.circlepath"
        }
    }
}

struct MediaBrowserView: View {
    @EnvironmentObject var model: AppModel
    let kind: MediaKind?
    let favoritesOnly: Bool
    @StateObject private var ui = BrowserUI()
    @StateObject private var results = LibraryResults()
    @AppStorage("groupSimilar") private var groupSimilar = false   // rule-based ChannelExtractor stand-in

    /// `filtered` already drops hidden items and categories (B13).
    private var query: LibraryQuery {
        model.libraryQuery(kind: kind, favoritesOnly: favoritesOnly, search: model.searchText,
                           sort: LibrarySort(rawValue: ui.sortOption.rawValue) ?? .name,
                           groupSimilar: groupSimilar)
    }

    private var groups: [String] { model.groups(kind: kind, favoritesOnly: favoritesOnly).filter { !model.isCategoryHidden($0) } }
    private var title: String { favoritesOnly ? L("Favorites") : (kind?.title ?? L("Library")) }
    private var isPosterSection: Bool { !favoritesOnly && kind != .live }
    private var columns: [GridItem] {
        if ui.listMode { return [GridItem(.flexible())] }
        return isPosterSection
            ? [GridItem(.adaptive(minimum: 184, maximum: 220), spacing: 20)]
            : [GridItem(.adaptive(minimum: 292, maximum: 380), spacing: 20)]
    }

    @ViewBuilder
    private var headerActions: some View {
        HeaderDropdown(
            title: L("Playlists"),
            systemImage: "line.3.horizontal.decrease",
            options: [DropdownOption<UUID?>(value: nil, title: L("All Playlists"), symbol: "square.stack.3d.up")]
                + model.playlists.map {
                    DropdownOption<UUID?>(value: $0.id, title: $0.name, symbol: $0.kind == .xtream ? "server.rack" : "list.bullet.rectangle")
                },
            selection: Binding(get: { model.playlistFilter }, set: { model.playlistFilter = $0 }),
            isActive: model.playlistFilter != nil
        )

        HeaderDropdown(
            title: L("Sort"),
            systemImage: "arrow.up.arrow.down",
            options: SortOption.allCases.map { DropdownOption(value: $0, title: $0.title, symbol: $0.symbol) },
            selection: Binding(get: { ui.sortOption }, set: { ui.sortOption = $0 }),
            isActive: ui.sortOption != .name
        )

        Button { withAnimation(.smooth) { groupSimilar.toggle() } } label: {
            Label(L("Group similar"), systemImage: "square.3.layers.3d")
        }
        .buttonStyle(HeaderIconButtonStyle(active: groupSimilar))
        .help(groupSimilar ? L("Show every source separately") : L("Group similar items"))
        .accessibilityLabel(L("Group similar items"))
        .accessibilityValue(groupSimilar ? L("On") : L("Off"))

        Button { ui.listMode.toggle() } label: {
            Label(ui.listMode ? L("Grid") : L("List"), systemImage: ui.listMode ? "square.grid.2x2" : "list.bullet")
        }
        .help(ui.listMode ? L("Show as grid") : L("Show as list"))

        Button { ui.showingCommandPalette = true } label: {
            Label(L("Command Palette"), systemImage: "command")
        }
        .keyboardShortcut("k", modifiers: .command)
        .help(L("Command Palette (⌘K)"))

        Button { ui.showingAdd = true } label: {
            Label(L("Add Playlist"), systemImage: "plus")
        }
        .buttonStyle(HeaderIconButtonStyle(prominent: true))
        .help(L("Add Playlist"))
    }

    var body: some View {
        LibraryPage {
            PageHeader(title: title) { headerActions }
            FilterChipBar(options: [L("All")] + groups, selection: $model.selectedGroup)
        } content: {
            if results.items.isEmpty && results.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
            } else if results.items.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(L("No items found"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {   // B51: no nested ScrollView
                        ForEach(results.visible) { item in
                            MediaCard(item: item, style: ui.listMode ? .landscape : (isPosterSection ? .poster : .landscape))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .onAppear { results.showMore(after: item) }
                                .task {
                                    // PERF: stagger metadata lookups so scrolling doesn't fire hundreds at once.
                                    if item.kind != .live && item.tmdbMetadata == nil {
                                        try? await Task.sleep(for: .milliseconds(50))
                                        await model.fetchTMDBMetadata(for: item)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
            }
        }
        .task(id: LibraryPageKey(query: query, indexCount: model.libraryIndex.revision)) { await results.load(query, index: model.libraryIndex) }
        .sheet(isPresented: Binding(get: { ui.showingAdd }, set: { ui.showingAdd = $0 })) { AddPlaylistView() }
        .sheet(isPresented: Binding(get: { ui.showingCommandPalette }, set: { ui.showingCommandPalette = $0 })) {
            CommandPalette(isPresented: Binding(get: { ui.showingCommandPalette }, set: { ui.showingCommandPalette = $0 }), items: results.items)
        }
    }
}

private struct CommandPalette: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    let items: [MediaItem]
    @StateObject private var ui = PaletteUI()

    private var results: [MediaItem] {
        guard !ui.query.trimmed.isEmpty else { return Array(items.prefix(8)) }
        return items.filter { $0.name.localizedCaseInsensitiveContains(ui.query.trimmed) }.prefix(20).map { $0 }
    }

    var body: some View {
        Sheet(title: L("Command Palette")) {
            VStack(spacing: 12) {
                TextField(L("Search"), text: Binding(get: { ui.query }, set: { ui.query = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(results) { item in
                            Button {
                                model.activate(item)
                                isPresented = false
                            } label: {
                                HStack {
                                    Text(item.name).lineLimit(1)
                                    Spacer()
                                    if model.isWatched(item.id) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }
}

private final class BrowserUI: ObservableObject {
    @Published var listMode = false
    @Published var sortOption: SortOption = .name
    @Published var showingCommandPalette = false
    @Published var showingAdd = false
}

private final class PaletteUI: ObservableObject {
    @Published var query = ""
}
