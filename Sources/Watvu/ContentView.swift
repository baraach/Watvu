import SwiftUI
import Combine
import AppKit

struct ContentView: View {
    static let sidebarWidth: CGFloat = 260
    static let sidebarInset: CGFloat = 8

    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var ui = ContentUI()
    @FocusState private var searchFocused: Bool
    @AppStorage(SettingsKeys.appearance) private var appearance = "system"
    @AppStorage(AccentPalette.storageKey) private var accentHex = AccentPalette.defaultOption.id

    /// "Add later" on the welcome screen; cleared once a playlist exists, so
    /// removing the last one brings the welcome screen back.
    @AppStorage(SettingsKeys.welcomeSkipped) private var welcomeSkipped = false
    private var showsWelcome: Bool { model.hasLoadedLibrary && model.playlists.isEmpty && !welcomeSkipped }

    private var searchPrompt: String {
        switch model.selection {
        case .home: return "Search channels, movies, series"
        case .guide: return "Search the guide"
        default: return "Search \(model.selection.title)"
        }
    }

    // The chain is split across three properties: one long chain is more than
    // the compiler can type-check in reasonable time.
    private var window: some View {
        // The sidebar floats over the page in a clear glass panel, so pages
        // are full width and inset their content by `sidebarInset`.
        ZStack(alignment: .topLeading) {
            Theme.background.ignoresSafeArea()

            if showsWelcome {
                WelcomeView(onAdd: { kind, useFile in
                    ui.addKind = kind
                    ui.addUsesFile = useFile
                    ui.showingAdd = true
                }, onSkip: { welcomeSkipped = true })
            } else if !model.hasLoadedLibrary {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L("Loading your library…"))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .topLeading) {

            // The old page leaves at once and the new one fades in over the
            // background. A cross-fade showed both pages (and both pages'
            // glass) at half strength, which looked washed out.
            DetailView()
                .id(model.selection)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18)),
                                        removal: .identity))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.sidebarInset, ui.sidebarVisible ? Self.sidebarWidth + Self.sidebarInset : 0)

            if ui.sidebarVisible {
                SidebarView(showingAdd: $ui.showingAdd, isVisible: $ui.sidebarVisible)
                    .frame(width: Self.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .glassEffect(.clear, in: .rect(cornerRadius: 20))
                    .padding(Self.sidebarInset)
                    .ignoresSafeArea(edges: .top)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
                }
                // One search field for every page: filters the current page, or
                // shows library-wide results from Home and Settings. On the
                // library only, so the welcome screen has none.
                .searchable(text: Binding(get: { model.searchText }, set: { model.setSearchText($0) }), placement: .toolbar, prompt: searchPrompt)
                .searchFocused($searchFocused)
            }
        }
        .id(accentHex)
        .onChange(of: model.playlists.isEmpty) { _, isEmpty in
            if !isEmpty { welcomeSkipped = false }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: ui.sidebarVisible)
        .toolbar(removing: .title)
        // Never draw a toolbar background (it flashed in as pages opened).
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onChange(of: model.selection) { _, _ in
            model.searchText = ""
            model.selectedGroup = "All"
        }
        .toolbar {
            // The sidebar has its own hide button; this one brings it back.
            if !ui.sidebarVisible {
                ToolbarItem(placement: .navigation) {
                    Button {
                        ui.sidebarVisible = true
                    } label: {
                        Label("Show Sidebar", systemImage: "sidebar.left")
                    }
                    .help("Show Sidebar")
                }
            }
            ToolbarSpacer(.flexible)
        }
    }

    private var windowWithSheets: some View {
        window
        .sheet(isPresented: $ui.showingAdd, onDismiss: {
            ui.addKind = .m3u
            ui.addUsesFile = false
        }) {
            AddPlaylistView(initialURL: ui.deeplinkURL, initialName: ui.deeplinkName,
                            initialKind: ui.addKind, initialUsesFile: ui.addUsesFile)
                .environmentObject(model)
                .tint(Theme.accent)
        }
        .sheet(item: $model.seriesDetail) { detail in
            SeriesDetailView(detail: detail)
                .environmentObject(model)
                .tint(Theme.accent)
        }
        .sheet(item: $model.movieDetailItem) { detail in
            MovieDetailView(detail: detail)
                .environmentObject(model)
                .tint(Theme.accent)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    var body: some View {
        windowWithSheets
        .overlay {
            if AppLock.shared.locked {
                AppLockGate(model: model)
                    .transition(.opacity)
                    .zIndex(50)
            }
        }
        .overlay {
            if let item = model.playingItem {
                PlayerView(item: item)
                    .id(item.id) // fresh player when the item changes (next episode)
                    .environmentObject(model)
                    .ignoresSafeArea()
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
                    .zIndex(20)
            }
        }
        // Hide the toolbar under the player so glass doesn't stack on glass.
        .toolbar(model.playingItem == nil ? .automatic : .hidden, for: .windowToolbar)
        .animation(.smooth(duration: 0.35), value: model.playingItem?.id)
        .overlay {
            if let session = model.sync {
                SyncCardHost(session: session) { model.sync = nil }
            }
        }
        .overlay(alignment: .top) {
            if model.isLoading {
                LoadingPill(text: model.statusText.isEmpty ? "Loading…" : model.statusText)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.isLoading)
        .tint(AccentPalette.color(for: accentHex))
        .accessibilityHidden(model.playingItem != nil)   // B56
        .background(WindowConfigurator())
        .onAppear {
            if CommandLine.arguments.contains("--add") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { ui.showingAdd = true }
            }
            if CommandLine.arguments.contains("--settings") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { openWindow(id: "settings") }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .addPlaylist)) { _ in
            ui.showingAdd = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .deeplinkAdd)) { note in
            ui.deeplinkURL = note.userInfo?["url"] as? String ?? ""
            ui.deeplinkName = note.userInfo?["name"] as? String ?? ""
            ui.showingAdd = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .newFavoriteList)) { note in
            ui.newListItemID = note.object as? String ?? ""
        }
        .alert("New List", isPresented: Binding(
            get: { ui.newListItemID != nil },
            set: { if !$0 { ui.newListItemID = nil } }
        )) {
            TextField("List name", text: $ui.newListName)
            Button("Create") {
                let itemID = ui.newListItemID.flatMap { $0.isEmpty ? nil : $0 }
                model.createFavoriteList(named: ui.newListName, adding: itemID)
                ui.newListName = ""
            }
            Button("Cancel", role: .cancel) { ui.newListName = "" }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSearch)) { _ in
            searchFocused = true
        }
        // Theme: applied app-wide on launch and whenever it changes.
        .task { AppAppearance.apply(appearance) }
        .onChange(of: appearance) { _, value in AppAppearance.apply(value) }
    }
}

/// Shows the sync card unless it was sent to the background.
private struct SyncCardHost: View {
    @ObservedObject var session: SyncSession
    let onClose: () -> Void

    var body: some View {
        if session.isHidden {
            VStack {
                LoadingPill(text: L("Syncing playlist…")).padding(.top, 12)
                Spacer()
            }
        } else {
            SyncProgressView(session: session, onClose: onClose)
        }
    }
}

private final class ContentUI: ObservableObject {
    @Published var showingAdd = false
    @Published var sidebarVisible = true
    /// Set while naming a new favorites list ("" when no item is being added).
    @Published var newListItemID: String?
    @Published var newListName = ""
    @Published var deeplinkURL = ""
    @Published var deeplinkName = ""
    /// What the Add Playlist sheet opens on (set by the welcome screen).
    @Published var addKind: PlaylistKind = .m3u
    @Published var addUsesFile = false
}

private struct SidebarInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Width covered by the floating sidebar at the leading edge.
    var sidebarInset: CGFloat {
        get { self[SidebarInsetKey.self] }
        set { self[SidebarInsetKey.self] = newValue }
    }
}

/// The selected page, or library-wide search results while searching from
/// Home.
private struct DetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.sidebarInset) private var sidebarInset

    private var showsSearchResults: Bool {
        !model.searchText.trimmed.isEmpty && model.selection == .home
    }

    var body: some View {
        Group {
            if showsSearchResults {
                SearchResultsView().transition(.opacity)
            } else {
                page
            }
        }
        // Pages start at the sidebar's edge, so nothing scrolls beneath it.
        // Home is the exception: its hero runs under the sidebar's glass on
        // purpose, it insets its own content, and its shelves stop at the edge.
        .sheet(item: $model.pendingUnlock) { item in   // B47 PIN prompt
            PinPromptView(item: item)
        }
        .padding(.leading, model.selection == .home && !showsSearchResults ? 0 : sidebarInset)
        .animation(.smooth(duration: 0.25), value: showsSearchResults)
    }

    @ViewBuilder
    private var page: some View {
        if model.selection == .live, let id = model.playlistFilter,
           let playlist = model.playlists.first(where: { $0.id == id }),
           playlist.kind != .m3u, playlist.kind != .xtream {
            PlaylistBrowserView(playlist: playlist)   // B45
        } else {
        switch model.selection {
        case .home: HomeView()
        case .live: MediaBrowserView(kind: .live, favoritesOnly: false)
        case .movies: MediaBrowserView(kind: .movie, favoritesOnly: false)
        case .series: MediaBrowserView(kind: .series, favoritesOnly: false)
        case .favorites: MediaBrowserView(kind: nil, favoritesOnly: true)
        case .guide: GuideView()
        case .downloads: DownloadsView()
        case .recordings: RecordingsView()
        }
        }
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.enforcer = ClearGlassEnforcer(window: window)
            window.titlebarSeparatorStyle = .none // no divider flash on page open
            let key = "Watvu.InitialFrameSet"
            if !UserDefaults.standard.bool(forKey: key), let screen = NSScreen.main?.visibleFrame {
                let width = min(1480, screen.width - 16)
                let height = min(940, screen.height - 16)
                let frame = NSRect(
                    x: screen.midX - width / 2,
                    y: screen.midY - height / 2,
                    width: width,
                    height: height
                )
                window.setFrame(frame, display: true)
                UserDefaults.standard.set(true, forKey: key)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var enforcer: ClearGlassEnforcer?
    }
}

private struct LoadingPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassSurface(in: Capsule())
    }
}

/// PIN entry shown before opening a locked item (B47).
private struct PinPromptView: View {
    @EnvironmentObject var model: AppModel
    let item: MediaItem
    @StateObject private var ui = PinUI()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Sheet(title: L("Locked"), subtitle: item.name) {
            VStack(spacing: 16) {
                if model.isPINSet {
                    SecureField(L("PIN"), text: Binding(get: { ui.pin }, set: { ui.pin = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Button(L("Unlock")) {
                        if model.verifyPIN(ui.pin) {
                            model.pendingUnlock = nil
                            if model.unlockAfterPin {
                                model.unlockAfterPin = false
                                model.setLocked(false, for: item.id)
                            } else {
                                model.activate(item)
                            }
                        } else {
                            ui.error = true
                        }
                    }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .glassProminentButton()
                    if ui.error { Text(L("Wrong PIN")).font(.caption).foregroundStyle(.red) }
                } else {
                    Text(L("Set a PIN to protect locked items")).font(.caption).foregroundStyle(.secondary)
                    SecureField(L("New PIN"), text: Binding(get: { ui.pin }, set: { ui.pin = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Button(L("Set PIN & Unlock")) {
                        model.setPIN(ui.pin)
                        model.pendingUnlock = nil
                        if model.unlockAfterPin {
                            model.unlockAfterPin = false
                            model.setLocked(false, for: item.id)
                        } else {
                            model.activate(item)
                        }
                    }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .glassProminentButton()
                }
            }
            .padding(24)
        }
    }
}

private final class PinUI: ObservableObject {
    @Published var pin = ""
    @Published var error = false
}

/// Full-screen lock gate shown at launch when App lock is enabled.
private struct AppLockGate: View {
    @ObservedObject var lock = AppLock.shared
    let model: AppModel
    @StateObject private var ui = LockUI()

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accent)
                Text(L("Watvu is locked"))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                if model.isPINSet {
                    SecureField(L("PIN"), text: Binding(get: { ui.pin }, set: { ui.pin = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Button(L("Unlock")) {
                        if lock.unlockWithPIN(ui.pin, model: model) { ui.pin = "" }
                        else { ui.wrong = true }
                    }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .glassProminentButton()
                    if ui.wrong { Text(L("Wrong PIN")).font(.caption).foregroundStyle(.red) }
                }
                Button(L("Use Touch ID")) { lock.unlockWithBiometrics() }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .glassButton()
            }
        }
        .ignoresSafeArea()
        .onAppear {
            if lock.enabled { lock.unlockWithBiometrics() }
        }
    }
}

private final class LockUI: ObservableObject {
    @Published var pin = ""
    @Published var wrong = false
}
