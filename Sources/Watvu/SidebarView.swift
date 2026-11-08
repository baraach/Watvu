import SwiftUI
import Combine

/// Sidebar content, floated over the page by ContentView in a clear glass
/// panel. Rows are custom (instead of a system List) so selection uses
/// The accent and the highlight can glide between rows.
struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Binding var showingAdd: Bool
    @Binding var isVisible: Bool
    @Namespace private var selectionSpace

    private enum Item: Hashable {
        case section(LibrarySection)
        case playlist(UUID)
    }

    private var selected: Item {
        if model.selection == .live, let id = model.playlistFilter {
            return .playlist(id)
        }
        return .section(model.selection)
    }

    private func select(_ item: Item) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            switch item {
            case .section(let section):
                if section == .live { model.playlistFilter = nil }
                model.selection = section
            case .playlist(let id):
                model.playlistFilter = id
                model.selection = .live
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    row(.home)
                    row(.favorites)

                    sectionTitle("Library")
                    row(.live)
                    row(.movies)
                    row(.series)
                    row(.guide)
                    row(.downloads)
                    row(.recordings)

                    if !model.playlists.isEmpty {
                        sectionTitle("Playlists")
                        ForEach(model.playlists) { playlist in
                            playlistRow(playlist)
                                .onDrag { NSItemProvider(object: playlist.id.uuidString as NSString) }
                                .onDrop(of: [.text], delegate: PlaylistDropDelegate(model: model, target: playlist.id))
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .animation(.smooth, value: model.playlists.map(\.id))
            }

            SidebarRow(
                title: "Settings",
                symbol: "gearshape",
                isSelected: false,
                namespace: selectionSpace
            ) {
                openWindow(id: "settings")
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            Button {
                showingAdd = true
            } label: {
                Label("Add Playlist", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .glassButton()
            .padding(12)
            .help("Add Playlist (⌘N)")
        }
    }

    /// Brand header below the title-bar strip (the title bar swallows
    /// clicks, so the toggle must sit under it to be clickable).
    private var header: some View {
        HStack(alignment: .center) {
            Text("Watvu")
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            Button {
                isVisible = false
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .controlSize(.large)
            .buttonBorderShape(.circle)
            .glassButton()
            .accessibilityLabel("Hide Sidebar")
            .help("Hide Sidebar")
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.top, 46)
        .padding(.bottom, 6)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func row(_ section: LibrarySection) -> some View {
        SidebarRow(
            title: section.title,
            symbol: section.symbol,
            isSelected: selected == .section(section),
            namespace: selectionSpace
        ) {
            select(.section(section))
        }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        SidebarRow(
            title: playlist.name,
            symbol: playlist.kind.symbol,
            isSelected: selected == .playlist(playlist.id),
            namespace: selectionSpace
        ) {
            select(.playlist(playlist.id))
        }
        .contextMenu {
            Button("Refresh") {
                Task { await model.refresh(playlist) }
            }
            Divider()
            Button("Delete", role: .destructive) {
                withAnimation(.smooth) { model.delete(playlist) }
            }
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @StateObject private var hover = RowHover()
    private var isHovering: Bool { hover.isHovering }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : Theme.accent)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.white : Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                if isSelected {
                    // One highlight that glides between rows.
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accent)
                        .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { hover.isHovering = hovering }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private final class RowHover: ObservableObject {
    @Published var isHovering = false
}

/// Reorders playlists by drag & drop in the sidebar.
private struct PlaylistDropDelegate: DropDelegate {
    let model: AppModel
    let target: UUID

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadItem(forTypeIdentifier: "public.text", options: nil) { item, _ in
            guard let data = item as? Data, let id = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: id) else { return }
            DispatchQueue.main.async {   // B63: all model reads on the main queue
                guard let from = model.playlists.firstIndex(where: { $0.id == uuid }),
                      let to = model.playlists.firstIndex(where: { $0.id == self.target }) else { return }
                withAnimation(.smooth) {
                    let moved = model.playlists.remove(at: from)
                    model.playlists.insert(moved, at: to)
                    for (index, p) in model.playlists.enumerated() {
                        if let i = model.playlists.firstIndex(where: { $0.id == p.id }) { model.playlists[i].order = index }
                    }
                    model.save()
                }
            }
        }
        return true
    }
}
