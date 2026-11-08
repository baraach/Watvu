import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct EPGSource: Identifiable {
    let id = UUID()
    let name: String
    let url: String
}

enum SettingsKeys {
    static let welcomeSkipped = "welcomeSkipped"
    static let appearance = "settings.appearance"          // system | light | dark
    static let launchSection = "settings.launchSection"    // LibrarySection raw value
    static let playerVolume = "settings.playerVolume"      // 0...1
    static let controlsAutoHide = "settings.controlsAutoHide" // seconds
    static let adaptiveControls = "settings.adaptiveControls" // Bool
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, playback, playlists, guide, data, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .playback: return "Playback"
        case .playlists: return "Playlists"
        case .guide: return "Guide"
        case .data: return "Library"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Appearance, accent color and startup."
        case .playback: return "Defaults for every player window."
        case .playlists: return "Your lists and services."
        case .guide: return "Extra XMLTV sources for each playlist."
        case .data: return "Watch history, favorites and storage."
        case .about: return "Version and supported formats."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .playback: return "play.rectangle.fill"
        case .playlists: return "list.bullet.rectangle.fill"
        case .guide: return "calendar"
        case .data: return "square.stack.3d.up.fill"
        case .about: return "info.circle.fill"
        }
    }

    /// Icon tile color, like System Settings.
    var tileColor: Color {
        switch self {
        case .general: return Color(red: 0.55, green: 0.56, blue: 0.60)
        case .playback: return Color(red: 1.00, green: 0.27, blue: 0.23)
        case .playlists: return Color(red: 0.04, green: 0.52, blue: 1.00)
        case .guide: return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .data: return Color(red: 0.75, green: 0.35, blue: 0.95)
        case .about: return Color(red: 0.39, green: 0.40, blue: 0.95)
        }
    }
}

/// Standalone Settings window, opened with ⌘, or the sidebar Settings row.
/// Native window controls, no title bar strip, clear glass panels over a
/// soft color backdrop.
struct SettingsWindowView: View {
    static let size = CGSize(width: 900, height: 640)

    @EnvironmentObject var model: AppModel
    @StateObject var ui = SettingsWindowUI()

    @Namespace private var railSelection

    @AppStorage(SettingsKeys.appearance) private var appearance = "system"
    @AppStorage("appLanguage") private var appLanguage = "en"
    @AppStorage(AccentPalette.storageKey) private var accentHex = AccentPalette.defaultOption.id
    @AppStorage(SettingsKeys.launchSection) private var launchSection = LibrarySection.home.rawValue
    @AppStorage(SettingsKeys.playerVolume) private var playerVolume = 1.0
    @AppStorage(SettingsKeys.controlsAutoHide) private var controlsAutoHide = 3.0
    @AppStorage(SettingsKeys.adaptiveControls) private var adaptiveControls = true
    @AppStorage("subtitleSize") private var subtitleSize = 18
    @AppStorage("subtitleColor") private var subtitleColor = "white"
    @AppStorage("preferredLanguage") private var preferredLanguage = ""
    @AppStorage("guideStyle") private var guideStyle = "colour"
    @AppStorage("playbackEngine") private var playbackEngine = "auto"
    @AppStorage("guidePreviews") private var guidePreviews = false   // B72: off by default

    private var accent: Color { AccentPalette.color(for: accentHex) }

    var body: some View {
        HStack(spacing: 0) {
            rail
            page
        }
        // Fills the window (a fixed size here would leave a title-bar-high
        // gap at the bottom, because the hidden title bar still counts).
        .frame(minWidth: Self.size.width, maxWidth: .infinity,
               minHeight: Self.size.height, maxHeight: .infinity)
        .background(SettingsBackdrop(accent: accent))
        // Content runs under the invisible toolbar; the system draws the
        // close / minimize / zoom buttons inside the rail panel.
        .ignoresSafeArea()
        .toolbar { ToolbarSpacer(.flexible) }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onChange(of: appearance) { _, value in AppAppearance.apply(value) }
        .onChange(of: appLanguage) { _, value in
            Bundle.setLanguage(value)
            UserDefaults.standard.set([value], forKey: "AppleLanguages")
            UserDefaults.standard.synchronize()
        }
        .tint(accent)
        .sheet(isPresented: $ui.showingAdd) {
            AddPlaylistView()
                .environmentObject(model)
                .tint(accent)
        }
        .confirmationDialog(
            "Delete “\(ui.pendingDelete?.name ?? "")”?",
            isPresented: Binding(
                get: { ui.pendingDelete != nil },
                set: { if !$0 { ui.pendingDelete = nil } }
            ),
            presenting: ui.pendingDelete
        ) { playlist in
            Button("Delete Playlist", role: .destructive) {
                withAnimation(.smooth) { model.delete(playlist) }
            }
        } message: { _ in
            Text("Its channels, movies and series are removed from the library.")
        }
        .confirmationDialog("Clear all favorites?", isPresented: $ui.confirmClearFavorites) {
            Button("Clear Favorites", role: .destructive) {
                withAnimation(.smooth) { model.clearFavorites() }
            }
        }
        .alert(
            "Password for “\(ui.passwordPlaylist?.name ?? "")”",
            isPresented: Binding(
                get: { ui.passwordPlaylist != nil },
                set: { if !$0 { ui.passwordPlaylist = nil } }
            ),
            presenting: ui.passwordPlaylist
        ) { playlist in
            SecureField("Password", text: $ui.passwordDraft)
            Button("Save") {
                model.updatePassword(ui.passwordDraft, for: playlist.id)
                ui.passwordDraft = ""
            }
            Button("Cancel", role: .cancel) { ui.passwordDraft = "" }
        } message: { _ in
            Text("Stored in the macOS Keychain.")
        }
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 38, height: 38)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Settings")
                        .font(.system(size: 17, weight: .bold))
                    Text("Watvu")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            // Clears the window buttons drawn above.
            .padding(.top, 52)
            .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    railRow(tab)
                }
            }
            // Only the selection highlight glides; pages switch instantly.
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: ui.tab)

            Spacer(minLength: 0)

            Text("Version \(appVersion)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 8)
        .frame(width: 228)
        .frame(maxHeight: .infinity)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(10)
    }

    private func railRow(_ tab: SettingsTab) -> some View {
        let selected = ui.tab == tab
        return Button {
            ui.tab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(tab.tileColor.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(tab.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(accent)
                        .shadow(color: accent.opacity(0.35), radius: 8, y: 3)
                        .matchedGeometryEffect(id: "rail", in: railSelection)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Page

    private var page: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ui.tab.title)
                        .font(.system(size: 30, weight: .bold))
                    Text(ui.tab.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                pageContent
            }
            // New page each tab (resets scroll). Switched without animation:
            // animated glass panels linger and overlap the next page.
            .id(ui.tab)
            .padding(.horizontal, 26)
            .padding(.top, 40)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectHidden(true, for: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var pageContent: some View {
        Group {
        switch ui.tab {
        case .general: generalPage
        case .playback: playbackPage
        case .playlists: VStack(spacing: 16) { playlistsPage; traktSection }
        case .guide: guidePage
        case .data: dataPage
        case .about: aboutPage
        }
        }
        .sheet(item: Binding(get: { ui.passwordPlaylist }, set: { ui.passwordPlaylist = $0 })) { _ in
            passwordSheet
        }
        .alert(L("Rename category"), isPresented: Binding(get: { ui.renameCategoryTarget != nil }, set: { if !$0 { ui.renameCategoryTarget = nil } })) {
            TextField(L("Name"), text: Binding(get: { ui.renameText }, set: { ui.renameText = $0 }))
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Save")) {
                if let old = ui.renameCategoryTarget { model.renameCategory(old, to: ui.renameText) }
            }
        }
    }

    // MARK: General

    private var generalPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Appearance") {
                SettingsRow(title: "Theme", subtitle: "Main window and Settings") {
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
                SettingsDivider()
                SettingsRow(title: "Accent color", subtitle: AccentPalette.option(for: accentHex).name) {
                    accentPicker
                }
                SettingsDivider()
                SettingsRow(title: L("Language"), subtitle: L("Applies after relaunch")) {
                    Picker(L("Language"), selection: $appLanguage) {
                        Text(L("English")).tag("en")
                        Text(L("Arabic")).tag("ar")
                        Text(L("Turkish")).tag("tr")
                        Text(L("German")).tag("de")
                        Text(L("Polish")).tag("pl")
                        Text(L("Spanish")).tag("es")
                        Text(L("French")).tag("fr")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            SettingsCard(title: L("Privacy")) {
                SettingsRow(title: L("App lock"), subtitle: L("Touch ID or PIN required at launch")) {
                    Toggle("", isOn: Binding(
                        get: { AppLock.shared.enabled },
                        set: { AppLock.shared.setEnabled($0) }
                    ))
                    .labelsHidden()
                }
            }

            SettingsCard(title: "Startup") {
                SettingsRow(title: "Open at launch", subtitle: "The first page shown") {
                    DropdownField(
                        title: "Open at launch",
                        options: LibrarySection.allCases.map {
                            DropdownOption(value: $0.rawValue, title: $0.title, symbol: $0.symbol)
                        } + [DropdownOption(value: "lastWatched", title: L("Last watched"), symbol: "play.circle")],
                        selection: $launchSection
                    )
                }
            }
        }
    }

    private var accentPicker: some View {
        HStack(spacing: 8) {
            ForEach(AccentPalette.options) { option in
                let selected = accentHex.caseInsensitiveCompare(option.id) == .orderedSame
                Button {
                    withAnimation(.snappy(duration: 0.2)) { accentHex = option.id }
                } label: {
                    Circle()
                        .fill(option.color.gradient)
                        .frame(width: 20, height: 20)
                        .overlay {
                            if selected {
                                Circle().fill(.white).frame(width: 7, height: 7)
                            }
                        }
                        .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                        .padding(2)
                        .overlay(Circle().stroke(selected ? option.color : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .help(option.name)
                .accessibilityLabel(option.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    // MARK: Playback

    private var playbackPage: some View {
        SettingsCard(title: "Player") {
            SettingsRow(title: L("Playback engine"),
                        subtitle: MPVEngine.isAvailable
                            ? L("mpv is installed — used for MKV, DTS and streams AVPlayer can't play")
                            : L("mpv isn't installed (brew install mpv), so AVPlayer is used")) {
                DropdownField(
                    title: L("Playback engine"),
                    options: EngineKind.allCases.map {
                        DropdownOption(value: $0.rawValue, title: $0.title, symbol: $0.symbol, subtitle: $0.detail)
                    },
                    selection: $playbackEngine,
                    width: 260
                )
            }
            SettingsDivider()
            SettingsRow(title: "Default volume", subtitle: "Used when a player opens") {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill")
                        .foregroundStyle(.secondary)
                    Slider(value: $playerVolume, in: 0...1)
                        .frame(width: 170)
                    Text("\(Int((playerVolume * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            SettingsDivider()
            SettingsRow(title: L("Preferred language"), subtitle: L("Audio/subtitle track auto-select (e.g. en, tr)")) {
                TextField("en", text: $preferredLanguage)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            SettingsDivider()
            SettingsRow(title: "Hide controls after", subtitle: "While a video is playing") {
                DropdownField(
                    title: "Hide controls after",
                    options: [2.0, 3.0, 5.0, 10.0].map {
                        DropdownOption(value: $0, title: "\(Int($0)) seconds", symbol: "timer")
                    },
                    selection: $controlsAutoHide,
                    width: 200
                )
            }
            SettingsDivider()
            SettingsRow(title: "Adaptive controls", subtitle: "Dark icons over bright scenes") {
                Toggle("Adaptive controls", isOn: $adaptiveControls)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            SettingsDivider()
            SettingsRow(title: "Subtitle size", subtitle: "Default size for subtitles") {
                DropdownField(
                    title: "Subtitle size",
                    options: [12, 14, 16, 18, 20, 24, 28, 32].map {
                        DropdownOption(value: $0, title: "\($0) pt", symbol: "textformat.size")
                    },
                    selection: Binding(
                        get: { subtitleSize },
                        set: { subtitleSize = $0 }
                    ),
                    width: 120
                )
            }
            SettingsRow(title: "Subtitle color", subtitle: "Default color for subtitles") {
                HStack(spacing: 8) {
                    ForEach(["white", "black", "yellow", "red", "green", "blue"], id: \.self) { color in
                        Button {
                            subtitleColor = color
                        } label: {
                            Circle()
                                .fill(PlayerController.subtitleSwiftUIColor(color))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                                .overlay {
                                    if subtitleColor == color {
                                        Circle().stroke(Color.accentColor, lineWidth: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Playlists

    private var playlistsPage: some View {
        VStack(spacing: 16) {
            LinkFromPhoneCard()

            SettingsCard(title: "Sources") {
                if model.playlists.isEmpty {
                    EmptyRow(symbol: "tray", text: "No playlists yet. Add an M3U file or an Xtream account.")
                } else {
                    ForEach(Array(model.playlists.enumerated()), id: \.element.id) { index, playlist in
                        playlistRow(playlist)
                        if index < model.playlists.count - 1 { SettingsDivider() }
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    ui.showingAdd = true
                } label: {
                    Label("Add Playlist", systemImage: "plus")
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .glassProminentButton()

                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .glassButton()
                .disabled(model.playlists.isEmpty)

                Spacer()
            }
        }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        let count = model.libraryIndex.itemCounts[playlist.id] ?? 0
        let guide = model.epgUpdatedAt[playlist.id]
        return HStack(spacing: 12) {
            Image(systemName: playlist.kind.symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(accent.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(playlist.kind.title) · \(count) items"
                     + (guide.map { " · Guide \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if playlist.kind == .xtream {
                    if let info = ui.xtreamAccountInfo[playlist.id] {
                        Text("Status: \(info.status) · Expires: \(info.expDate ?? "Never") · Connections: \(info.activeCons ?? "1")/\(info.maxConnections ?? "1")")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Loading account info...")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .task {
                                await loadXtreamAccountInfo(for: playlist)
                            }
                    }
                }

                Spacer()

                Button {
                    ui.passwordPlaylist = playlist
                    ui.passwordDraft = "edit"
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit Playlist")
                if model.needsPassword(playlist) {
                    Label("Password missing — enter it again", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            if playlist.kind == .xtream {
                iconButton("key.fill", help: "Enter password for \(playlist.name)") {
                    ui.passwordDraft = ""
                    ui.passwordPlaylist = playlist
                }
            }
            iconButton("arrow.clockwise", help: "Refresh \(playlist.name)") {
                Task { await model.refresh(playlist) }
            }
            iconButton("trash", help: "Delete \(playlist.name)") {
                ui.pendingDelete = playlist
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonBorderShape(.circle)
        .glassButton()
        .help(help)
        .accessibilityLabel(help)
    }

    private func loadXtreamAccountInfo(for playlist: Playlist) async {
        guard playlist.kind == .xtream else { return }
        do {
            let client = XtreamClient(server: playlist.url, username: playlist.username, password: playlist.password)
            let info = try await client?.accountInfo()
            await MainActor.run {
                if let info {
                    ui.xtreamAccountInfo[playlist.id] = info
                }
            }
        } catch {
            Logger.shared.log("xtream", "account info failed: \(error.localizedDescription)")
        }
    }

    // MARK: Guide

    private var guidePage: some View {
        VStack(spacing: 16) {
            if model.playlists.isEmpty {
                SettingsCard(title: "Guide sources") {
                    EmptyRow(symbol: "calendar.badge.plus", text: "Add a playlist first, then add guide sources here.")
                }
            } else {
                SettingsCard(title: "EPG Source Catalog") {
                    VStack(spacing: 8) {
                        TextField("Search EPG sources", text: Binding(get: { ui.epgSearchQuery }, set: { ui.epgSearchQuery = $0 }))
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(filteredEPGSources) { source in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(source.name)
                                                .font(.system(size: 13, weight: .semibold))
                                            Text(source.url)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button {
                                            if let playlist = model.playlists.first {
                                                var sources = playlist.extraEPGURLs ?? []
                                                if !sources.contains(source.url) { sources.append(source.url) }
                                                model.setExtraGuideSources(sources, for: playlist.id)
                                            }
                                        } label: {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.system(size: 16))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        .frame(height: 200)
                    }
                    .padding(8)
                }
                ForEach(Array(model.playlists.enumerated()), id: \.element.id) { index, playlist in
                    SettingsCard(title: playlist.name) {
                        GuideSourcesEditor(playlist: playlist)
                        SettingsDivider()
                        SettingsRow(title: L("Time offset"), subtitle: L("Guide clock for this playlist (per-channel catch-up offset wins for playback)")) {   // B70
                            DropdownField(
                                title: L("Time offset"),
                                options: [-120, -60, -30, -15, 0, 15, 30, 60, 120].map {
                                    DropdownOption(value: $0, title: $0 == 0 ? L("None") : "\($0) min", symbol: "clock.arrow.2.circlepath")
                                },
                                selection: Binding(
                                    get: { model.playlists[index].epgTimeOffsetMinutes },
                                    set: { model.playlists[index].epgTimeOffsetMinutes = $0; model.save() }
                                ),
                                width: 180
                            )
                        }
                        SettingsDivider()
                        SettingsRow(title: L("Auto-refresh"), subtitle: L("How often this playlist reloads")) {
                            DropdownField(
                                title: L("Auto-refresh"),
                                options: Self.refreshOptions,
                                selection: Binding(
                                    get: { model.playlists[index].refreshIntervalDays },
                                    set: { model.playlists[index].refreshIntervalDays = $0; model.save() }
                                ),
                                width: 180
                            )
                        }
                        SettingsDivider()
                        SettingsRow(title: L("Playback engine"), subtitle: L("Overrides the Player setting for this playlist")) {   // B78
                            DropdownField(
                                title: L("Playback engine"),
                                options: [DropdownOption(value: "", title: L("Default"), symbol: "gearshape")]
                                    + EngineKind.allCases.map {
                                        DropdownOption(value: $0.rawValue, title: $0.title, symbol: $0.symbol, subtitle: $0.detail)
                                    },
                                selection: Binding(
                                    get: { model.playlists[index].engineOverride?.rawValue ?? "" },
                                    set: { model.playlists[index].engineOverride = EngineKind(rawValue: $0); model.save() }
                                ),
                                width: 220
                            )
                        }
                    }
                }
                SettingsRow(title: L("Live previews in guide"), subtitle: L("Hover a row to preview the channel (off by default)")) {
                    Toggle("", isOn: $guidePreviews).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: L("Guide style"), subtitle: L("Colour or greyscale programme blocks")) {
                    Picker(L("Guide style"), selection: $guideStyle) {
                        Text(L("Colour")).tag(GuideStyle.colour)
                        Text(L("Greyscale")).tag(GuideStyle.greyscale)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                HStack {
                    Button {
                        Task { await model.refreshEPG() }
                    } label: {
                        Label("Refresh All Guides", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .glassButton()
                    Spacer()
                }
            }
        }
    }

    private static var refreshOptions: [DropdownOption<Int>] {
        [0, 1, 3, 7, 30].map { days in
            let title: String
            switch days {
            case 0: title = L("Manual")
            case 1: title = L("Daily")
            case 7: title = L("Weekly")
            case 30: title = L("Monthly")
            default: title = "\(days) days"
            }
            return DropdownOption(value: days, title: title, symbol: "arrow.clockwise")
        }
    }

    private var storageSummary: String { ui.storageSummary }

    private var epgSources: [EPGSource] {
        [
            EPGSource(name: "EPG.Best", url: "https://epg.best/epg/guide.xml.gz"),
            EPGSource(name: "IPTV-ORG", url: "https://iptv-org.github.io/epg/guides/us.xml.gz"),
            EPGSource(name: "XMLTV.se", url: "https://xmltv.se/epg.xml.gz"),
            EPGSource(name: "TVGuide.co.uk", url: "https://tvguide.co.uk/epg.xml.gz"),
            EPGSource(name: "OnTV Tonight", url: "https://ontvtonight.com/epg.xml.gz")
        ]
    }

    private func cleanUpStorage() {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        // guide caches
        if let e = fm.enumerator(at: support.appendingPathComponent("Watvu"), includingPropertiesForKeys: nil) {
            for case let f as URL in e where f.lastPathComponent.hasPrefix("epg-") { try? fm.removeItem(at: f) }
        }
        // temp
        let temp = fm.temporaryDirectory
        if let e = fm.enumerator(at: temp, includingPropertiesForKeys: nil) {
            for case let f as URL in e where f.lastPathComponent.hasPrefix("uhf") { try? fm.removeItem(at: f) }
        }
        ImageCache.shared.clear()
        model.refreshEPGIfNeededAfterCleanup()
    }


    private var filteredEPGSources: [EPGSource] {
        if ui.epgSearchQuery.isEmpty {
            return epgSources
        } else {
            return epgSources.filter { $0.name.localizedCaseInsensitiveContains(ui.epgSearchQuery) || $0.url.localizedCaseInsensitiveContains(ui.epgSearchQuery) }
        }
    }

    // MARK: Library

    private var dataPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "History") {
                SettingsRow(title: "Continue Watching", subtitle: "\(model.recent.count) items") {
                    Button("Clear") {
                        withAnimation(.smooth) { model.clearRecents() }
                    }
                    .buttonBorderShape(.capsule)
                    .glassButton()
                    .disabled(model.recent.isEmpty)
                }
                SettingsDivider()
                SettingsRow(title: "Favorites", subtitle: "\(model.favorites.count) items") {
                    Button("Clear…") { ui.confirmClearFavorites = true }
                        .buttonBorderShape(.capsule)
                        .glassButton()
                        .disabled(model.favorites.isEmpty)
                }
            }

            SettingsCard(title: L("Home sections")) {
                ForEach(Array(model.homeOrder.enumerated()), id: \.element.id) { index, section in
                    SettingsRow(title: section.title, subtitle: nil) {
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { model.isHomeSectionVisible(section) },
                                set: { visible in
                                    var hidden = model.hiddenHomeSections
                                    if visible { hidden.remove(section) } else { hidden.insert(section) }
                                    model.hiddenHomeSections = hidden
                                }
                            )).labelsHidden()
                            Button { model.moveHomeSection(section, up: true) } label: {
                                Image(systemName: "chevron.up")
                            }.disabled(index == 0).buttonStyle(.plain)
                            Button { model.moveHomeSection(section, up: false) } label: {
                                Image(systemName: "chevron.down")
                            }.disabled(index == model.homeOrder.count - 1).buttonStyle(.plain)
                        }
                    }
                }
            }

            HomeFeedsSettings()

            SettingsCard(title: L("Categories")) {
                let groups = model.groups(kind: nil, favoritesOnly: false)
                if groups.isEmpty {
                    EmptyRow(symbol: "square.grid.2x2", text: L("No categories yet"))
                }
                ForEach(groups, id: \.self) { group in
                    SettingsRow(title: group, subtitle: model.isCategoryHidden(group) ? L("Hidden") : nil) {
                        HStack(spacing: 8) {
                            Button(L("Rename…")) { ui.renameCategoryTarget = group }
                            Button(model.isCategoryHidden(group) ? L("Show") : L("Hide")) {
                                model.setCategoryHidden(!model.isCategoryHidden(group), group)
                            }
                            .buttonBorderShape(.capsule)
                            .glassButton()
                            Menu(L("Merge into…")) {
                                ForEach(groups.filter { $0 != group }, id: \.self) { other in
                                    Button(other) { model.mergeCategory(group, into: other) }
                                }
                            }
                            .buttonBorderShape(.capsule)
                            .glassButton()
                        }
                    }
                }
            }

            SettingsCard(title: L("Customisation")) {
                SettingsRow(title: L("Clean up names"), subtitle: L("Strip quality tags like 1080p, HEVC, [FHD] from channel names")) {
                    Button(L("Run")) {
                        let n = model.cleanUpNames()
                        ui.statusMessage = String(format: L("%d names cleaned"), n)
                    }
                    .buttonBorderShape(.capsule)
                    .glassButton()
                }
                SettingsDivider()
                SettingsRow(title: L("Reset customisations"), subtitle: L("Undo all renames, thumbnails, moves and hides")) {
                    Button(L("Reset")) { model.resetCustomisations() }
                        .buttonBorderShape(.capsule)
                        .glassDestructiveButton()
                }
                if let msg = ui.statusMessage {
                    SettingsRow(title: "", subtitle: msg) { EmptyView() }
                }
            }

            if !model.favoriteLists.isEmpty {
                SettingsCard(title: "Favorite lists") {
                    ForEach(Array(model.favoriteLists.enumerated()), id: \.element.id) { index, list in
                        FavoriteListRow(list: list)
                        if index < model.favoriteLists.count - 1 { SettingsDivider() }
                    }
                }
            }

            SettingsCard(title: "Storage") {
                SettingsRow(title: "Data folder", subtitle: storageSummary) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.dataDirectory])
                    }
                    .buttonBorderShape(.capsule)
                    .glassButton()
                }
                SettingsDivider()
                SettingsRow(title: L("Backup"), subtitle: L("Export playlists, favorites and settings (no passwords)")) {
                    HStack(spacing: 8) {
                        Button(L("Export…")) { ui.showExport = true }
                        Button(L("Import…")) { ui.showImport = true }
                    }
                    .buttonBorderShape(.capsule)
                    .glassButton()
                }
                .fileExporter(isPresented: Binding(get: { ui.showExport }, set: { ui.showExport = $0 }),
                              document: BackupDocument(model: model),
                              contentType: .json,
                              defaultFilename: "watvu-backup.json") { _ in }
                .fileImporter(isPresented: Binding(get: { ui.showImport }, set: { ui.showImport = $0 }),
                              allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        do { try model.importBackup(from: url); ui.statusMessage = L("Backup imported") }
                        catch { ui.statusMessage = error.localizedDescription }
                    }
                }
                SettingsDivider()
                ICloudSyncRow()
                SettingsDivider()
                SettingsRow(title: L("Clean up"), subtitle: L("Guide caches, temp files, image cache")) {
                    Button(L("Clean up")) {
                        cleanUpStorage()
                        ui.storageSummary = StorageSummary.compute()
                    }
                    .buttonBorderShape(.capsule)
                    .glassButton()
                }
            }
        }
    }

    // MARK: About

    private var aboutPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Watvu") {
                SettingsRow(title: "Version") {
                    Text(appVersion)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                SettingsDivider()
                SettingsRow(title: "Playlists") {
                    Text("M3U · M3U8 · Xtream Codes")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                SettingsDivider()
                SettingsRow(title: "Guide") {
                    Text("XMLTV · XMLTV.gz")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                SettingsDivider()
                SettingsRow(title: L("Debug log"), subtitle: L("Recent app events")) {
                    Button(L("View")) { ui.showLog = true }
                        .buttonBorderShape(.capsule)
                        .glassButton()
                }
                .sheet(isPresented: Binding(get: { ui.showLog }, set: { ui.showLog = $0 })) {
                    Sheet(title: L("Debug log")) {
                        ScrollView {
                            Text(Logger.shared.text)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .textSelection(.enabled)
                        }
                        HStack {
                            Button(L("Copy")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(Logger.shared.text, forType: .string)
                            }
                            .buttonBorderShape(.capsule)
                            .glassButton()
                        }
                        .padding(.bottom, 12)
                    }
                }
            }

            SettingsCard(title: L("What's new")) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(changelog, id: \.version) { entry in
                        Text(entry.version).font(.system(size: 12, weight: .bold))
                        Text(entry.notes).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }

            SettingsCard(title: L("Help")) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(faq, id: \.0) { q, a in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(q).font(.system(size: 12, weight: .semibold))
                            Text(a).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
            }

            Text("Watvu is a local client for playlists you supply. It is not affiliated with UHF (iOS).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    private var changelog: [(version: String, notes: String)] {
        [("0.1.0", L("Initial macOS build: M3U/Xtream/Plex/Jellyfin/Emby/SMB sources, guide, player, downloads, recordings, multiview, 7 languages."))]
    }

    private var faq: [(String, String)] {
        [
            (L("How do I add a playlist?"), L("Sidebar ＋, ⌘N, or a watvu://add?url=… link.")),
            (L("Why does a channel not play?"), L("Public playlists often have dead streams. Try another entry or refresh the playlist.")),
            (L("Where is my data stored?"), L("Application Support/Watvu. Passwords are in the Keychain, never in the files.")),
            (L("How do I back up?"), L("Settings → Storage → Backup → Export…")),
        ]
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

final class SettingsWindowUI: ObservableObject {
    @Published var epgSearchQuery = ""
    @Published var tab: SettingsTab = .general
    @Published var showingAdd = false
    @Published var pendingDelete: Playlist?
    @Published var showingTraktAuth = false
    @Published var traktSignedOut = false
    @Published var xtreamAccountInfo: [UUID: XtreamClient.AccountInfo] = [:]
    @Published var confirmClearFavorites = false
    @Published var storageSummary = StorageSummary.compute()
    @Published var statusMessage: String?
    @Published var showExport = false
    @Published var showImport = false
    @Published var showLog = false
    @Published var renameCategoryTarget: String?
    @Published var renameText = ""
    @Published var traktSyncStatus = ""
    @Published var passwordPlaylist: Playlist?
    @Published var passwordDraft = ""
}

// MARK: - Building blocks

/// Grouped section: a small caption above a clear glass panel.
private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)

            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 50)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, 16)
    }
}

private struct EmptyRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

/// Soft color fields behind the clear panels, so the glass has something to
/// bend instead of reading as flat gray.
private struct SettingsBackdrop: View {
    let accent: Color

    var body: some View {
        ZStack {
            Theme.background
            Circle()
                .fill(accent.opacity(0.30))
                .frame(width: 520, height: 520)
                .blur(radius: 120)
                .offset(x: 300, y: -260)
            Circle()
                .fill(Color(red: 0.25, green: 0.45, blue: 1.0).opacity(0.18))
                .frame(width: 460, height: 460)
                .blur(radius: 120)
                .offset(x: -320, y: 260)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Inline editors

/// Extra guide (XMLTV) sources for one playlist.
private struct GuideSourcesEditor: View {
    @EnvironmentObject var model: AppModel
    let playlist: Playlist
    @StateObject private var draft = GuideSourcesDraft()

    private var isDirty: Bool {
        draft.sources.map(\.trimmed).filter { !$0.isEmpty } != (playlist.extraEPGURLs ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let main = playlist.epgURL, !main.isEmpty {
                SettingsRow(title: "Main guide") {
                    Text(main)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 360, alignment: .trailing)
                        .textSelection(.enabled)
                }
                SettingsDivider()
            }

            ForEach(draft.sources.indices, id: \.self) { index in
                HStack(spacing: 10) {
                    TextField("https://…/guide.xml.gz", text: $draft.sources[index])
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Button {
                        draft.sources.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove source")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            HStack(spacing: 8) {
                Button("Add URL") { draft.sources.append("") }
                    .buttonBorderShape(.capsule)
                    .glassButton()
                Button("Add File…") { draft.isImporting = true }
                    .buttonBorderShape(.capsule)
                    .glassButton()
                Spacer()
                Button("Save & Refresh") {
                    model.setExtraGuideSources(draft.sources, for: playlist.id)
                    if let updated = model.playlists.first(where: { $0.id == playlist.id }) {
                        Task { await model.fetchEPG(for: updated, force: true) }
                    }
                }
                .buttonBorderShape(.capsule)
                .glassProminentButton()
                .disabled(!isDirty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .onAppear { draft.sources = playlist.extraEPGURLs ?? [] }
        .fileImporter(
            isPresented: $draft.isImporting,
            allowedContentTypes: epgTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let selected = urls.first {
                draft.sources.append(selected.absoluteString)
            }
        }
    }

    private var epgTypes: [UTType] {
        ["xml", "xmltv", "gz", "gzip"].compactMap { UTType(filenameExtension: $0) }
    }
}

private final class GuideSourcesDraft: ObservableObject {
    @Published var sources: [String] = []
    @Published var isImporting = false
}

/// Rename (on Return or losing focus) or delete a named favorites list.
private struct FavoriteListRow: View {
    @EnvironmentObject var model: AppModel
    let list: FavoriteList
    @StateObject private var draft = NameDraft()
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.fill")
                .font(.system(size: 12))
                .foregroundStyle(.pink)
            TextField("List name", text: $draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            Text("\(list.itemIDs.count) items")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button {
                withAnimation(.smooth) { model.deleteFavoriteList(list.id) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonBorderShape(.circle)
            .glassButton()
            .help("Delete \(list.name)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onAppear { draft.name = list.name }
    }

    private func commit() {
        if draft.name.trimmed.isEmpty {
            draft.name = list.name
        } else if draft.name != list.name {
            model.renameFavoriteList(list.id, to: draft.name)
        }
    }
}

private final class NameDraft: ObservableObject {
    @Published var name = ""
}

private struct PlaylistEditor: View {
    @EnvironmentObject var model: AppModel
    let playlist: Playlist
    @StateObject private var ui: PlaylistEditorUI

    init(playlist: Playlist) {
        self.playlist = playlist
        self._ui = StateObject(wrappedValue: PlaylistEditorUI(playlist))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(L("Server / Playlist URL"), text: Binding(get: { ui.draft.url }, set: { ui.draft.url = $0 }))
                    .textFieldStyle(.roundedBorder)
                TextField(L("EPG URL (optional)"), text: Binding(get: { ui.draft.epgURL ?? "" }, set: { ui.draft.epgURL = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                TextField(L("Username"), text: Binding(get: { ui.draft.username }, set: { ui.draft.username = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 16) {
                Button {
                    ui.showingCoverPicker = true
                } label: {
                    if let cover = ui.draft.cover, let url = URL(string: cover) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                Image(systemName: "photo")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 60, height: 60)
                        .cornerRadius(8)
                        .clipped()
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                            .frame(width: 60, height: 60)
                            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .buttonStyle(.plain)
                .fileImporter(
                    isPresented: Binding(get: { ui.showingCoverPicker }, set: { ui.showingCoverPicker = $0 }),
                    allowedContentTypes: [.image],
                    allowsMultipleSelection: false
                ) { result in
                    if let url = try? result.get().first {
                        ui.draft.cover = url.absoluteString
                    }
                }

                Button {
                    ui.showingIconPicker = true
                } label: {
                    if let icon = ui.draft.icon, let url = URL(string: icon) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                Image(systemName: "app.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 60, height: 60)
                        .cornerRadius(8)
                        .clipped()
                    } else {
                        Image(systemName: "app.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                            .frame(width: 60, height: 60)
                            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .buttonStyle(.plain)
                .fileImporter(
                    isPresented: Binding(get: { ui.showingIconPicker }, set: { ui.showingIconPicker = $0 }),
                    allowedContentTypes: [.image],
                    allowsMultipleSelection: false
                ) { result in
                    if let url = try? result.get().first {
                        ui.draft.icon = url.absoluteString
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: $ui.draft.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                    TextField("Category", text: Binding(
                        get: { ui.draft.category ?? "" },
                        set: { ui.draft.category = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button {
                save()
            } label: {
                Text("Save")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .glassButton()
        }
        .padding(16)
    }

    private func save() {
        if let index = model.playlists.firstIndex(where: { $0.id == playlist.id }) {
            model.playlists[index] = ui.draft
            model.save()
        }
    }
}

extension SettingsWindowView {
    var passwordSheet: some View {
        Group {
            if ui.passwordDraft == "edit" {
                Sheet(title: "Edit Playlist", subtitle: playlistName) {
                    if let p = ui.passwordPlaylist { PlaylistEditor(playlist: p) }
                }
            } else {
                Sheet(title: "Enter Password", subtitle: "This playlist is password-protected") {
                    VStack(spacing: 16) {
                        SecureField("Password", text: $ui.passwordDraft)
                            .textFieldStyle(.roundedBorder)

                        Button("Unlock") {
                            if let p = ui.passwordPlaylist { model.unlockPlaylist(p.id) }
                        }
                        .controlSize(.large)
                        .buttonBorderShape(.capsule)
                        .glassButton()
                        .disabled(ui.passwordDraft.isEmpty)
                    }
                    .padding(20)
                }
            }
        }
    }

    var playlistName: String {
        ui.passwordPlaylist?.name ?? ""
    }

    private var traktSection: some View {
        SettingsCard(title: L("Trakt")) {
            if traktClient == nil {
                SettingsRow(title: L("Sign In"), subtitle: L("Connect to Trakt.tv")) {
                    Button(L("Sign In")) {
                        ui.showingTraktAuth = true
                    }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .glassButton()
                }
            } else {
                SettingsRow(title: L("Scrobble"), subtitle: L("Automatically track watched content")) {
                    Toggle("", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "traktScrobble") },
                        set: { UserDefaults.standard.set($0, forKey: "traktScrobble") }
                    ))
                    .toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(title: L("Watchlist"), subtitle: L("Sync your Trakt watchlist")) {
                    Toggle("", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "traktWatchlist") },
                        set: { UserDefaults.standard.set($0, forKey: "traktWatchlist") }
                    ))
                    .toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(title: L("History"), subtitle: L("Sync your Trakt history")) {
                    Toggle("", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "traktHistory") },
                        set: { UserDefaults.standard.set($0, forKey: "traktHistory") }
                    ))
                    .toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(title: L("Sync now"), subtitle: ui.traktSyncStatus.isEmpty ? L("Pull watchlist & history") : ui.traktSyncStatus) {
                    Button(L("Sync")) {
                        Task {
                            ui.traktSyncStatus = await model.syncTrakt(client: traktClient)
                        }
                    }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .glassButton()
                }
                SettingsDivider()
                SettingsRow(title: L("Sign Out"), subtitle: L("Disconnect from Trakt.tv")) {
                    Button(L("Sign Out")) {
                        ui.traktSignedOut = true
                        CredentialStore.deleteSecret(forAccount: "trakt.accessToken")
                        CredentialStore.deleteSecret(forAccount: "trakt.refreshToken")
                    }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .glassButton()
                }
            }
        }
        .sheet(isPresented: Binding(get: { ui.showingTraktAuth }, set: { ui.showingTraktAuth = $0 })) {
            TraktAuthView(isPresented: Binding(get: { ui.showingTraktAuth }, set: { ui.showingTraktAuth = $0 }))
        }
    }

    var traktClient: TraktClient? {
        get {
            if ui.traktSignedOut { return nil }
            guard let clientID = UserDefaults.standard.string(forKey: "traktClientID"),
                  let clientSecret = CredentialStore.secret(forAccount: "trakt.clientSecret"),
                  let accessToken = CredentialStore.secret(forAccount: "trakt.accessToken") else { return nil }
            var client = TraktClient(clientID: clientID, clientSecret: clientSecret)
            client.accessToken = accessToken
            client.refreshToken = CredentialStore.secret(forAccount: "trakt.refreshToken")
            return client
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.clientID, forKey: "traktClientID")
                CredentialStore.setSecret(newValue.clientSecret, forAccount: "trakt.clientSecret")
                if let token = newValue.accessToken { CredentialStore.setSecret(token, forAccount: "trakt.accessToken") }
                if let refresh = newValue.refreshToken { CredentialStore.setSecret(refresh, forAccount: "trakt.refreshToken") }
            } else {
                UserDefaults.standard.removeObject(forKey: "traktClientID")
                CredentialStore.deleteSecret(forAccount: "trakt.clientSecret")
                CredentialStore.deleteSecret(forAccount: "trakt.accessToken")
                CredentialStore.deleteSecret(forAccount: "trakt.refreshToken")
            }
        }
    }
}

private struct TraktAuthView: View {
    @Binding var isPresented: Bool
    @StateObject private var ui = TraktAuthUI()

    var body: some View {
        Sheet(title: L("Trakt Authentication"), subtitle: L("Sign in to Trakt.tv")) {
            VStack(spacing: 16) {
                if ui.isLoading {
                    ProgressView()
                        .padding(.top, 20)
                } else if let authURL = ui.authURL {
                    WebView(url: authURL) { url in
                        if let code = extractCode(from: url) {
                            exchangeCodeForToken(code: code)
                        }
                    }
                } else if let errorText = ui.errorText {
                    Text(errorText)
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                        .padding(.top, 20)
                } else {
                    Button(L("Sign In with Trakt")) {
                        authenticate()
                    }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .glassButton()
                }
            }
            .padding(16)
        }
    }

    private func authenticate() {
        Task {
            ui.isLoading = true
            ui.errorText = nil
            do {
                var client = TraktClient(
                    clientID: UserDefaults.standard.string(forKey: "traktClientID") ?? "",
                    clientSecret: CredentialStore.secret(forAccount: "trakt.clientSecret") ?? ""
                )
                ui.authURL = try await client.authenticate()
            } catch {
                ui.errorText = L("Failed to authenticate: ") + error.localizedDescription
            }
            ui.isLoading = false
        }
    }

    private func exchangeCodeForToken(code: String) {
        Task {
            ui.isLoading = true
            ui.errorText = nil
            do {
                var client = TraktClient(
                    clientID: UserDefaults.standard.string(forKey: "traktClientID") ?? "",
                    clientSecret: CredentialStore.secret(forAccount: "trakt.clientSecret") ?? ""
                )
                try await client.exchangeCodeForToken(code: code)
                
                // Save the authenticated client
                if let window = NSApplication.shared.keyWindow?.contentView?.window {
                    for subview in window.contentView?.subviews ?? [] {
                        if let hostingView = subview as? NSHostingView<SettingsWindowView> {
                            hostingView.rootView.traktClient = client
                            break
                        }
                    }
                }
                
                isPresented = false
            } catch {
                ui.errorText = L("Failed to exchange code: ") + error.localizedDescription
            }
            ui.isLoading = false
        }
    }

    private func extractCode(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.scheme == "watvu" || components.scheme == "uhfmac",
              components.host == "trakt",
              components.path == "/auth",
              let queryItems = components.queryItems,
              let codeItem = queryItems.first(where: { $0.name == "code" }),
              let code = codeItem.value else {
            return nil
        }
        return code
    }
}

private final class PlaylistEditorUI: ObservableObject {
    @Published var draft: Playlist
    @Published var showingCoverPicker = false
    @Published var showingIconPicker = false
    init(_ playlist: Playlist) { self.draft = playlist }
}

private final class TraktAuthUI: ObservableObject {
    @Published var authURL: URL?
    @Published var isLoading = false
    @Published var errorText: String?
}

enum StorageSummary {
    static func compute() -> String {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return "" }
        var total: Int64 = 0
        let dirs = [support.appendingPathComponent("Watvu"), fm.temporaryDirectory]
        for dir in dirs {
            if let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            }
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

/// Writable document for the backup file exporter.
private struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }
    let model: AppModel

    init(model: AppModel) { self.model = model }

    init(configuration: ReadConfiguration) throws {
        fatalError("import handled via fileImporter")
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("backup.json")
        try MainActor.assumeIsolated { try model.exportBackup(to: url) }
        return try FileWrapper(url: url)
    }
}

/// Display text for the engine pickers (kept out of `PlaybackEngine.swift`,
/// which the core tests compile without the localisation helpers).
extension EngineKind {
    var title: String {
        switch self {
        case .auto: return L("Auto")
        case .avplayer: return "AVPlayer"
        case .mpv: return "mpv"
        }
    }
    var detail: String {
        switch self {
        case .auto: return L("AVPlayer, mpv if it can't play")
        case .avplayer: return L("Apple's player only")
        case .mpv: return L("Always mpv (MKV, DTS, ASS)")
        }
    }
    var symbol: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .avplayer: return "applelogo"
        case .mpv: return "film.stack"
        }
    }
}

// MARK: - Home feeds settings

/// Settings → Library → Home feeds: list, reorder, remove and add feeds.
private struct HomeFeedsSettings: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var ui = HomeFeedsSettingsUI()

    var body: some View {
        SettingsCard(title: L("Home feeds")) {
            if model.homeFeeds.isEmpty {
                EmptyRow(symbol: "rectangle.stack.badge.plus",
                         text: L("Add shelves from TMDB, Trakt lists, or sports and events in your guide"))
            }
            ForEach(Array(model.homeFeeds.enumerated()), id: \.element.id) { index, feed in
                if index > 0 { SettingsDivider() }
                SettingsRow(title: feed.title,
                            subtitle: feed.collection.isEmpty ? feed.kindLabel : "\(feed.collection) · \(feed.kindLabel)") {
                    HStack(spacing: 10) {
                        if let error = model.feedErrors[feed.id] {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .help(error)
                        }
                        Button { model.moveHomeFeed(feed.id, up: true) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.plain).disabled(index == 0)
                        Button { model.moveHomeFeed(feed.id, up: false) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.plain).disabled(index == model.homeFeeds.count - 1)
                        Button { model.removeHomeFeed(feed.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                            .help(L("Remove feed"))
                    }
                }
            }
            SettingsDivider()
            SettingsRow(title: L("Add feed"), subtitle: L("Shown in the “Your feeds” Home section")) {
                HStack(spacing: 8) {
                    Button(L("Refresh")) { Task { await model.refreshAllFeeds() } }
                        .buttonBorderShape(.capsule)
                        .glassButton()
                        .disabled(model.homeFeeds.isEmpty)
                    Button { ui.showingAdd = true } label: { Label(L("Add feed"), systemImage: "plus") }
                        .buttonBorderShape(.capsule)
                        .glassProminentButton()
                }
            }
        }
        .sheet(isPresented: $ui.showingAdd) { AddFeedSheet() }
    }
}

private final class HomeFeedsSettingsUI: ObservableObject {
    @Published var showingAdd = false
}

private enum FeedKind: String, CaseIterable, Hashable {
    case tmdb, trakt, events
    var title: String {
        switch self {
        case .tmdb: return L("TMDB discover")
        case .trakt: return L("Trakt list")
        case .events: return L("Sports & events")
        }
    }
    var symbol: String {
        switch self {
        case .tmdb: return "film.stack"
        case .trakt: return "list.star"
        case .events: return "sportscourt"
        }
    }
    var detail: String {
        switch self {
        case .tmdb: return L("Popular or top-rated titles by genre and year")
        case .trakt: return L("Your watchlist, your lists or a public list")
        case .events: return L("Upcoming games for a team, league or event in your guide")
        }
    }
}

private final class AddFeedState: ObservableObject {
    @Published var kind: FeedKind = .events
    @Published var title = ""
    @Published var collection = ""
    @Published var tv = false
    @Published var genre = 0            // 0 = any
    @Published var sort = "popularity.desc"
    @Published var minRating = 0.0
    @Published var year = ""
    @Published var traktUser = "me"
    @Published var traktList = "watchlist"
    @Published var keyword = ""
}

private struct AddFeedSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = AddFeedState()

    private var genres: [(Int, String)] { state.tv ? TMDBGenres.tv : TMDBGenres.movie }

    private var canSave: Bool {
        switch state.kind {
        case .tmdb: return true
        case .trakt: return !state.traktList.trimmed.isEmpty
        case .events: return !state.keyword.trimmed.isEmpty
        }
    }

    private var defaultTitle: String {
        switch state.kind {
        case .tmdb:
            let genre = genres.first { $0.0 == state.genre }?.1
            let base = state.sort == "vote_average.desc" ? L("Top rated") : L("Popular")
            return [base, genre, state.tv ? L("shows") : L("movies")].compactMap { $0 }.joined(separator: " ")
        case .trakt: return state.traktList == "watchlist" ? L("Trakt watchlist") : state.traktList
        case .events: return state.keyword.trimmed
        }
    }

    var body: some View {
        Sheet(title: L("Add Home feed"), subtitle: L("A new shelf in “Your feeds”")) {
            VStack(alignment: .leading, spacing: 14) {
                DropdownField(title: L("Feed type"),
                              options: FeedKind.allCases.map { DropdownOption(value: $0, title: $0.title, symbol: $0.symbol, subtitle: $0.detail) },
                              selection: $state.kind, width: 300)

                switch state.kind {
                case .tmdb:
                    Picker("", selection: $state.tv) {
                        Text(L("Movies")).tag(false)
                        Text(L("Shows")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    .onChange(of: state.tv) { _, _ in state.genre = 0 }
                    HStack(spacing: 10) {
                        DropdownField(title: L("Genre"),
                                      options: [DropdownOption(value: 0, title: L("Any genre"), symbol: "square.grid.2x2")]
                                        + genres.map { DropdownOption(value: $0.0, title: $0.1) },
                                      selection: $state.genre, width: 220)
                        DropdownField(title: L("Order"),
                                      options: [DropdownOption(value: "popularity.desc", title: L("Popular"), symbol: "flame"),
                                                DropdownOption(value: "vote_average.desc", title: L("Top rated"), symbol: "star"),
                                                DropdownOption(value: "primary_release_date.desc", title: L("Newest"), symbol: "calendar")],
                                      selection: $state.sort, width: 200)
                    }
                    HStack(spacing: 10) {
                        TextField(L("Year (optional)"), text: $state.year)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        Text(L("Minimum rating"))
                        Slider(value: $state.minRating, in: 0...9, step: 0.5).frame(width: 140)
                        Text(state.minRating == 0 ? L("Any") : String(format: "%.1f", state.minRating))
                            .monospacedDigit()
                    }
                    .font(.system(size: 12))
                    if model.tmdbAPIKey == nil {
                        hint(L("Needs a TMDB API key (Settings → Services)."))
                    }
                case .trakt:
                    HStack(spacing: 10) {
                        TextField(L("User (me = you)"), text: $state.traktUser)
                            .textFieldStyle(.roundedBorder).frame(width: 160)
                        TextField(L("List slug or “watchlist”"), text: $state.traktList)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                    hint(L("Use “me” and “watchlist” for your watchlist, or the user and list name from a trakt.tv list address."))
                case .events:
                    TextField(L("Team, league or event (e.g. Real Madrid, Premier League, Formula 1)"), text: $state.keyword)
                        .textFieldStyle(.roundedBorder)
                    if !state.keyword.trimmed.isEmpty {
                        let count = model.guideEvents(matching: state.keyword).count
                        hint(count == 0 ? L("Nothing in your guide for the next 7 days yet — the shelf fills in as the guide updates.")
                                        : String(format: L("%d upcoming in your guide."), count))
                    }
                }

                Divider()
                HStack(spacing: 10) {
                    TextField(defaultTitle.isEmpty ? L("Shelf title") : defaultTitle, text: $state.title)
                        .textFieldStyle(.roundedBorder)
                    TextField(L("Collection (optional)"), text: $state.collection)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
                HStack {
                    Spacer()
                    Button(L("Cancel")) { dismiss() }
                        .buttonBorderShape(.capsule)
                        .glassButton()
                    Button(L("Add feed")) { save() }
                        .buttonBorderShape(.capsule)
                        .glassProminentButton()
                        .disabled(!canSave)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 600)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        let source: HomeFeed.Source
        switch state.kind {
        case .tmdb:
            source = .tmdbDiscover(tv: state.tv, genreID: state.genre == 0 ? nil : state.genre,
                                   sort: state.tv && state.sort == "primary_release_date.desc" ? "first_air_date.desc" : state.sort,
                                   minRating: state.minRating, year: Int(state.year.trimmed))
        case .trakt:
            source = .traktList(user: state.traktUser.trimmed.isEmpty ? "me" : state.traktUser.trimmed,
                                list: state.traktList.trimmed)
        case .events:
            source = .guideEvents(keyword: state.keyword.trimmed)
        }
        let title = state.title.trimmed.isEmpty ? defaultTitle : state.title.trimmed
        model.addHomeFeed(HomeFeed(title: title, source: source, collection: state.collection.trimmed))
        dismiss()
    }
}

/// Settings → Storage → iCloud Drive sync.
private struct ICloudSyncRow: View {
    @ObservedObject private var sync = ICloudDriveSync.shared

    var body: some View {
        SettingsRow(title: L("Sync with iCloud Drive"),
                    subtitle: sync.status.isEmpty
                        ? L("Keeps playlists, favorites, progress and feeds the same on your Macs (no passwords)")
                        : sync.status) {
            HStack(spacing: 8) {
                if sync.isEnabled {
                    Button(L("Sync now")) { sync.sync() }
                        .buttonBorderShape(.capsule)
                        .glassButton()
                        .disabled(sync.isSyncing)
                }
                Toggle("", isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!ICloudDriveSync.isAvailable)
            }
        }
        .help(ICloudDriveSync.isAvailable ? L("Uses the “Watvu” folder in iCloud Drive") : L("Turn on iCloud Drive in System Settings first"))
    }
}

/// Settings → Playlists → Add from your phone (QR code + local web page).
private struct LinkFromPhoneCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var server = LinkServer.shared

    var body: some View {
        SettingsCard(title: L("Add from your phone")) {
            SettingsRow(title: L("Allow adding from your phone"),
                        subtitle: server.isRunning ? server.lastEvent
                            : L("Scan a QR code and type the playlist link or login on your phone")) {
                Toggle("", isOn: Binding(get: { server.isRunning },
                                         set: { $0 ? server.start(model: model) : server.stop() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if server.isRunning, let address = server.address {
                SettingsDivider()
                LinkQRPanel(address: address, code: server.code)
            }
        }
    }
}
