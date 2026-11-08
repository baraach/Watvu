import SwiftUI

/// Shows the items of a single playlist. For M3U/Xtream playlists the items
/// are already loaded into the model; other backends list their libraries.
struct PlaylistBrowserView: View {
    @EnvironmentObject var model: AppModel
    let playlist: Playlist
    @StateObject private var ui = BrowserUI()

    @StateObject private var smbUI = SMBUI()

    private var items: [MediaItem] {
        if playlist.kind == .smb { return smbUI.items }
        return model.items.filter {
            $0.playlistID == playlist.id && !model.isHidden($0.id)
                && (ui.selectedLibrary == nil || $0.group == ui.selectedLibrary?.name)
        }
    }

    var body: some View {
        LibraryPage {
            PageHeader(title: playlist.name, subtitle: L("Playlist")) {
                if playlist.kind != .smb {
                    Button {
                        Task { await model.refresh(playlist) }
                    } label: {
                        Label(L("Refresh"), systemImage: "arrow.clockwise")
                    }
                    .help(L("Refresh playlist"))
                }
            }
            if !playlist.libraries.isEmpty {
                FilterChipBar(
                    options: [L("All")] + playlist.libraries.map { $0.name },
                    selection: Binding(
                        get: { ui.selectedLibrary?.name ?? L("All") },
                        set: { name in ui.selectedLibrary = playlist.libraries.first { $0.name == name } }
                    )
                )
            }
        } content: {
            if items.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(L("No items found"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 292, maximum: 380), spacing: 20)], spacing: 24) {
                        ForEach(items) { item in
                            MediaCard(item: item, style: .landscape)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .onTapGesture {
                                    if playlist.kind == .smb { playSMB(item) }
                                }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }
            }
        }
        .navigationTitle(playlist.name)
        .task {
            if playlist.kind == .smb { await smbUI.load(playlist: playlist) }
        }
    }

    private func playSMB(_ item: MediaItem) {
        Task {
            guard let url = URL(string: playlist.url), let host = url.host else { return }
            let share = url.pathComponents.dropFirst().joined(separator: "/")
            let path = item.streamURL.replacingOccurrences(of: "smb://\(host)/\(share)/", with: "")
            var client = SMBClient(server: host, share: share, username: playlist.username, password: playlist.password)
            do {
                try client.connect()
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(item.id.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression) + ".mp4")
                try client.downloadFile(atPath: path, to: dest)
                var local = item
                local.streamURL = dest.absoluteString
                await MainActor.run { model.activate(local) }
            } catch {
                await MainActor.run { smbUI.errorText = error.localizedDescription }
            }
        }
    }
}

private final class SMBUI: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var errorText: String?
    private var client: SMBClient?
    private var playlist: Playlist?

    func load(playlist: Playlist) async {
        self.playlist = playlist
        guard let url = URL(string: playlist.url), let host = url.host else { return }
        let share = url.pathComponents.dropFirst().joined(separator: "/")
        var client = SMBClient(server: host, share: share, username: playlist.username, password: playlist.password)
        do {
            try client.connect()
            let files = try client.contentsOfDirectory(atPath: "")
            await MainActor.run {
                self.items = files.map { f in
                    MediaItem(
                        id: "\(playlist.id)|\(f.path)",
                        playlistID: playlist.id,
                        name: f.name,
                        group: playlist.name,
                        logo: nil,
                        streamURL: "smb://\(host)/\(share)/\(f.path)",
                        kind: f.isDirectory ? .live : .movie
                    )
                }
            }
            self.client = client
        } catch {
            await MainActor.run { self.errorText = error.localizedDescription }
        }
    }
}

private final class BrowserUI: ObservableObject {
    @Published var selectedLibrary: PlaylistLibrary?
}
