import SwiftUI

/// First-run screen, shown whenever the library has no playlists: pick a list
/// or a service, add from a phone, or restore a backup.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    /// Opens the Add Playlist sheet for a kind (`useFile`: a local M3U file).
    let onAdd: (_ kind: PlaylistKind, _ useFile: Bool) -> Void
    /// Goes to the empty library without adding anything.
    let onSkip: () -> Void
    @StateObject private var ui = WelcomeUI()

    private struct Option: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let kind: PlaylistKind
        var useFile = false
    }

    private var lists: [Option] {
        [
            Option(id: "link", title: L("Playlist link"), detail: L("An M3U or M3U8 address"), symbol: "link", kind: .m3u),
            Option(id: "file", title: L("Playlist file"), detail: L("An M3U file on this Mac"), symbol: "doc.text", kind: .m3u, useFile: true),
            Option(id: "xtream", title: L("Xtream Codes"), detail: L("Server and login"), symbol: "server.rack", kind: .xtream),
        ]
    }

    private var services: [Option] {
        [
            Option(id: "plex", title: "Plex", detail: L("Your Plex account"), symbol: PlaylistKind.plex.symbol, kind: .plex),
            Option(id: "jellyfin", title: "Jellyfin", detail: L("Your Jellyfin server"), symbol: PlaylistKind.jellyfin.symbol, kind: .jellyfin),
            Option(id: "emby", title: "Emby", detail: L("Your Emby server"), symbol: PlaylistKind.emby.symbol, kind: .emby),
            Option(id: "smb", title: L("Network share"), detail: L("An SMB folder"), symbol: PlaylistKind.smb.symbol, kind: .smb),
        ]
    }

    var body: some View {
        ZStack {
            backdrop
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 30) {
                    header
                    section(L("Add a list"), options: lists, columns: 3, compact: false)
                    section(L("Connect a service"), options: services, columns: 4, compact: true)
                    footer
                    Button(L("Add later"), action: onSkip)
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .help(L("Go to the library. You can add playlists from the sidebar at any time."))
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 32)
                .padding(.vertical, 56)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $ui.showingPhoneLink) { PhoneLinkSheet() }
        .fileImporter(isPresented: $ui.showingRestore, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try model.importBackup(from: url)
            } catch {
                model.errorMessage = L("That file isn't a Watvu backup.")
            }
        }
    }

    /// Soft accent wash: gives the clear glass something to refract.
    private var backdrop: some View {
        ZStack {
            Theme.background
            LinearGradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0.04), .clear],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 10) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .accessibilityHidden(true)
            }
            Text(L("Welcome to Watvu"))
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(L("Choose what you'd like to watch. You can add more at any time."))
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private func section(_ title: String, options: [Option], columns: Int, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                ForEach(options) { option in
                    WelcomeCard(title: option.title, detail: option.detail, symbol: option.symbol, compact: compact) {
                        onAdd(option.kind, option.useFile)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { ui.showingPhoneLink = true } label: {
                Label(L("Add from your phone"), systemImage: "qrcode")
            }
            Button { ui.showingRestore = true } label: {
                Label(L("Restore a backup"), systemImage: "arrow.counterclockwise")
            }
            Button { openWindow(id: "settings") } label: {
                Label(L("Settings"), systemImage: "gearshape")
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .glassButton()
    }
}

private final class WelcomeUI: ObservableObject {
    @Published var showingPhoneLink = false
    @Published var showingRestore = false
}

private struct WelcomeCard: View {
    let title: String
    let detail: String
    let symbol: String
    /// Icon above the text (services), instead of beside it (lists).
    let compact: Bool
    let action: () -> Void
    @StateObject private var hover = WelcomeCardHover()

    var body: some View {
        Button(action: action) {
            Group {
                if compact {
                    VStack(spacing: 10) {
                        icon
                        text(alignment: .center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    HStack(spacing: 12) {
                        icon
                        text(alignment: .leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .opacity(hover.isHovering ? 1 : 0.4)
                    }
                }
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .scaleEffect(hover.isHovering ? 1.015 : 1)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { hover.isHovering = hovering }
        }
    }
}

private extension WelcomeCard {
    var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    func text(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }
}

private final class WelcomeCardHover: ObservableObject {
    @Published var isHovering = false
}

/// Runs the phone link while it's open.
private struct PhoneLinkSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var server = LinkServer.shared

    var body: some View {
        Sheet(title: L("Add from your phone"), subtitle: L("Add a playlist link or login from your phone")) {
            Group {
                if server.isRunning, let address = server.address {
                    LinkQRPanel(address: address, code: server.code)
                    Text(server.lastEvent)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.bottom, 16)
                } else {
                    Text(server.lastEvent.isEmpty ? L("Starting…") : server.lastEvent)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(40)
                }
            }
        }
        .frame(width: 560)
        .onAppear { server.start(model: model) }
        .onDisappear { server.stop() }
    }
}
