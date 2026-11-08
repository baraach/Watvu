import SwiftUI
import AVKit
import AVFoundation
import AppKit
import Combine
import MediaPlayer
import UniformTypeIdentifiers

/// In-window player with glass chrome. Chrome auto-hides while playing.
struct PlayerView: View {
    @EnvironmentObject var model: AppModel
    let item: MediaItem
    @StateObject private var player = PlayerController()
    @StateObject private var chrome = ChromeState()
    @StateObject private var ui = PlayerUI()
    @FocusState private var hasKeyboardFocus: Bool
    @AppStorage("subtitleSize") private var subtitleSize = 18
    @AppStorage("subtitleColor") private var subtitleColor = "white"
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var nowProgram: EPGProgram? {
        guard let epg = model.epgByPlaylist[item.playlistID] else { return nil }
        return epg[model.epgChannelID(for: item) ?? ""]?.first { $0.contains(Date()) }
    }

    var body: some View {
        ZStack {
            Color.black

            Group {
                if player.usingMPV, let engine = player.mpv {   // B74
                    MPVSurface(engine: engine, inPiP: ui.pipWindow != nil)
                } else {
                    VideoSurface(controller: player)
                }
            }
                .gesture(MagnificationGesture()
                    .onChanged { player.zoomScale = max(1.0, min($0.magnitude, 4.0)) }
                    .onEnded { player.zoomScale = max(1.0, min($0.magnitude, 4.0)) })
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { if player.zoomScale > 1.0 { player.zoomOffset = $0.translation } }
                    .onEnded { if player.zoomScale > 1.0 { player.zoomOffset = $0.translation } })
                .onTapGesture(count: 2) { player.zoomScale = 1; player.zoomOffset = .zero }

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { player.toggleFullScreen() }
                .onTapGesture {
                    if chrome.panel != nil { chrome.panel = nil } else { player.togglePlay() }
                    reveal()
                }

            if let session = player.cast {
                CastingOverlay(session: session, title: item.name) { player.stopCasting(resumeLocally: true) }
            }

            if let cue = player.cueText, player.cast == nil { cueView(cue) }

            if let message = player.failed { failureView(message) }

            if chrome.visible { chromeView }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onContinuousHover { if case .active = $0 { reveal() } }
        .onReceive(tick) { _ in
            autoHide()
            player.sampleBrightness()
        }
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onKeyPress(.space) { player.togglePlay(); reveal(); return .handled }
        .onKeyPress(.leftArrow) { player.seek(by: -10); reveal(); return .handled }
        .onKeyPress(.rightArrow) { player.seek(by: 10); reveal(); return .handled }
        .onKeyPress(.upArrow) { if player.isLive { zap(-1); reveal(); return .handled }; return .ignored }
        .onKeyPress(.downArrow) { if player.isLive { zap(1); reveal(); return .handled }; return .ignored }
        .onKeyPress("f") { player.toggleFullScreen(); return .handled }
        .onKeyPress(.escape) {
            if chrome.panel != nil { chrome.panel = nil }
            else if player.isFullScreen { player.toggleFullScreen() }
            else { close() }
            return .handled
        }
        .onAppear {
            start()
            // Take the keyboard; a sheet that's closing can hold it for a moment.
            hasKeyboardFocus = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { hasKeyboardFocus = true }
        }
        .onDisappear { closePiPWindow(); player.teardown() }
        .alert(L("Resume Playback"), isPresented: Binding(get: { player.showResumePrompt }, set: { player.showResumePrompt = $0 })) {
            Button(L("Resume")) { player.handleResumeChoice(resume: true) }
            Button(L("Play from beginning"), role: .destructive) { player.handleResumeChoice(resume: false) }
        } message: {
            Text(String(format: L("You stopped watching at %@. Resume or play from the beginning?"), Self.format(player.pendingResumeAt ?? 0)))
        }
        .sheet(isPresented: Binding(get: { ui.showingSubtitlePicker }, set: { ui.showingSubtitlePicker = $0 })) {
            FilePickerView { urls in urls.forEach { player.loadSubtitles(from: $0) } }
        }
        .sheet(isPresented: Binding(get: { ui.showingOpenSubtitles }, set: { ui.showingOpenSubtitles = $0 })) {
            OpenSubtitlesView(isPresented: Binding(get: { ui.showingOpenSubtitles }, set: { ui.showingOpenSubtitles = $0 }), item: item, player: player)
        }
        .sheet(isPresented: Binding(get: { ui.showingStats }, set: { ui.showingStats = $0 })) {
            if let stats = player.stats { statsSheet(stats) }
        }
        .sheet(isPresented: Binding(get: { ui.showingMultiview }, set: { ui.showingMultiview = $0 })) { Multiview() }
    }

    // MARK: - Chrome

    private var chromeView: some View {
        ZStack {
            VStack {
                topBar
                Spacer()
                if let panel = chrome.panel {
                    bottomPanel(panel)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: 1100, alignment: .trailing)
                        .transition(.scale(scale: 0.94, anchor: .bottomTrailing).combined(with: .opacity))
                }
                controlBar
            }
        }
        .animation(.easeInOut(duration: 0.25), value: chrome.visible)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { close() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(PlayerIconButtonStyle())
                .glassSurface(in: Circle())
                .help(L("Close"))
                .accessibilityLabel(L("Close"))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let now = nowProgram {
                    Text("\(now.timeRange)  \(now.title)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    /// Floating clear-glass control panel. Every control uses one icon style
    /// (`PlayerIconButtonStyle`); less-used actions live in the More panel.
    private var controlBar: some View {
        VStack(spacing: 6) {
            timeline
            HStack(spacing: 4) {
                Button { player.seek(by: -10); reveal() } label: { Image(systemName: "gobackward.10") }
                    .help(L("Skip Backward"))
                    .accessibilityLabel(L("Skip Backward"))
                    .disabled(player.isLive)
                Button { player.togglePlay(); reveal() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PlayerIconButtonStyle(prominent: true))
                .help(player.isPlaying ? L("Pause") : L("Play"))
                .accessibilityLabel(player.isPlaying ? L("Pause") : L("Play"))
                Button { player.seek(by: 30); reveal() } label: { Image(systemName: "goforward.30") }
                    .help(L("Skip Forward"))
                    .accessibilityLabel(L("Skip Forward"))
                    .disabled(player.isLive)

                if model.catchupSource != nil {
                    Button { if let live = model.catchupSource { model.play(live) } } label: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    .help(L("Watch Live"))
                    .accessibilityLabel(L("Watch Live"))
                } else if player.isLive, let now = nowProgram, model.canCatchup(item, now) {
                    Button { model.playCatchup(item, now) } label: { Image(systemName: "backward.end.alt") }
                        .help(L("Watch from start"))
                        .accessibilityLabel(L("Watch from start"))
                }
                if showsNextEpisode {
                    Button { model.playNextEpisode() } label: { Image(systemName: "forward.end.fill") }
                        .help(L("Next episode"))
                        .accessibilityLabel(L("Next episode"))
                }

                Spacer(minLength: 12)

                if !player.isLive {
                    panelButton(.speed, L("Playback Speed")) {
                        Text(Self.rateLabel(player.rate))
                            .font(.system(size: 12, weight: .bold))
                            .monospacedDigit()
                    }
                }
                panelButton(.tracks, L("Subtitles and Audio")) { Image(systemName: "captions.bubble") }
                panelButton(.aspect, L("Video aspect")) { Image(systemName: "aspectratio") }
                panelButton(.epg, L("TV Guide")) { Image(systemName: "calendar") }
                panelButton(.channels, L("Channels")) { Image(systemName: "list.bullet") }
                panelButton(.cast, player.cast == nil ? L("Cast to a TV") : L("Casting")) {
                    Image(systemName: player.cast == nil ? "tv.badge.wifi" : "tv.fill")
                        .foregroundStyle(player.cast == nil ? Color.primary : Theme.accent)
                }
                if !player.usingMPV, player.cast == nil {   // AirPlay video needs AVPlayer
                    AirPlayButton(player: player.player)
                        .frame(width: 22, height: 22)
                        .frame(width: 36, height: 36)
                        .help(L("AirPlay"))
                        .accessibilityLabel(L("AirPlay"))
                }
                Button { togglePiP() } label: { Image(systemName: "pip.enter") }
                    .help(L("Picture in Picture"))
                    .accessibilityLabel(L("Picture in Picture"))
                Button { player.toggleFullScreen() } label: {
                    Image(systemName: player.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(L("Full Screen"))
                .accessibilityLabel(L("Full Screen"))
                panelButton(.more, L("More")) { Image(systemName: "ellipsis") }
            }
            .buttonStyle(PlayerIconButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .foregroundStyle(.primary)
        .glassSurface(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        // Adaptive controls: dark glyphs over bright video, white otherwise.
        .environment(\.colorScheme, player.bottomIsBright ? .light : .dark)
        .animation(.easeOut(duration: 0.3), value: player.bottomIsBright)
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .frame(maxWidth: 1100)
        .onHover { chrome.hoveringControls = $0 }
    }

    private static func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%g×", rate)
    }

    private var timeline: some View {
        HStack(spacing: 12) {
            Text(Self.format(player.currentTime))
                .frame(minWidth: 46, alignment: .leading)
            if player.isLive {
                HStack(spacing: 5) {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    Text("LIVE").tracking(1)
                }
                .font(.system(size: 11, weight: .bold))
                Spacer()
            } else {
                Slider(value: Binding(get: { player.currentTime }, set: { player.currentTime = $0 }),
                       in: 0...max(player.duration, 1),
                       onEditingChanged: { editing in
                           player.isScrubbing = editing
                           if !editing { player.seek(to: player.currentTime) }
                       })
                .controlSize(.small)
                .accessibilityLabel(L("Playback position"))
                Text("-" + Self.format(max(player.duration - player.currentTime, 0)))
                    .frame(minWidth: 56, alignment: .trailing)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
    }

    // MARK: - Panels

    private func panelButton<Label: View>(_ kind: PlayerPanelKind, _ label: String,
                                          @ViewBuilder content: () -> Label) -> some View {
        let isOpen = chrome.panel == kind
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { chrome.panel = isOpen ? nil : kind }
            reveal()
        } label: {
            content()
        }
        .buttonStyle(PlayerIconButtonStyle(active: isOpen))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }

    @ViewBuilder
    private func bottomPanel(_ kind: PlayerPanelKind) -> some View {
        switch kind {
        case .speed:
            GlassPanel(title: L("Playback Speed"), onClose: { chrome.panel = nil }) {
                ForEach([0.5, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    MenuRow(title: String(format: "%.2f×", rate), isSelected: player.rate == Float(rate)) {
                        player.setRate(Float(rate))
                    }
                }
            }
        case .tracks:
            GlassPanel(title: L("Subtitles & Audio"), onClose: { chrome.panel = nil }) {
                if player.usingMPV {
                    mpvTracks
                } else {
                    avTracks
                }
            }
        case .aspect:
            GlassPanel(title: L("Video aspect"), onClose: { chrome.panel = nil }) {
                ForEach(AspectOption.allCases) { option in
                    MenuRow(title: option.title, subtitle: option.detail, isSelected: player.videoGravity == option.gravity) {
                        player.videoGravity = option.gravity
                    }
                }
            }
        case .epg:
            GlassPanel(title: L("TV Guide"), width: 360, maxHeight: 400, onClose: { chrome.panel = nil }) {
                epgTab
            }
        case .channels:
            channelsPanel
        case .cast:
            GlassPanel(title: L("Cast"), width: 300, onClose: { chrome.panel = nil }) {
                CastPanelContent(player: player, item: item) { chrome.panel = nil }
            }
            .onAppear { CastBrowser.shared.start() }
        case .more:
            GlassPanel(title: L("More"), width: 280, onClose: { chrome.panel = nil }) {
                MenuRow(title: L("Load subtitle file…"), symbol: "doc.text", isSelected: false) {
                    chrome.panel = nil; ui.showingSubtitlePicker = true
                }
                MenuRow(title: L("Search OpenSubtitles…"), symbol: "magnifyingglass", isSelected: false) {
                    chrome.panel = nil; ui.showingOpenSubtitles = true
                }
                MenuRow(title: L("Stream stats"), symbol: "info.circle", isSelected: false) {
                    chrome.panel = nil; player.updateStats(); ui.showingStats = true
                }
                MenuRow(title: L("Multiview"), symbol: "rectangle.split.2x2", isSelected: false) {
                    chrome.panel = nil; ui.showingMultiview = true
                }
                let players = installedExternalPlayers()
                if !players.isEmpty {
                    MenuSection(title: L("Open in"))
                    ForEach(players, id: \.path) { app in
                        MenuRow(title: app.deletingPathExtension().lastPathComponent, symbol: "arrow.up.forward.app", isSelected: false) {
                            chrome.panel = nil; openInExternalPlayer(app)
                        }
                    }
                }
            }
        }
    }

    /// Subtitles from a loaded .srt/.vtt file, drawn by the app (AVPlayer mode).
    private func cueView(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: CGFloat(subtitleSize) * 1.4, weight: .semibold))
                .foregroundStyle(PlayerController.subtitleSwiftUIColor(subtitleColor))
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.9), radius: 3, y: 1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 60)
                .padding(.bottom, chrome.visible ? 120 : 44)
                .animation(.easeOut(duration: 0.2), value: chrome.visible)
        }
        .allowsHitTesting(false)
    }

    /// −/+ control for the subtitle delay, in 0.1 s steps.
    private var subtitleDelayRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            MenuSection(title: L("Subtitle delay"))
            HStack(spacing: 8) {
                delayButton("minus", -0.1, L("Show subtitles earlier"))
                Text(String(format: "%+.1f s", player.subtitleDelay))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .frame(minWidth: 64)
                delayButton("plus", 0.1, L("Show subtitles later"))
                Spacer()
                Button(L("Reset")) { player.subtitleDelay = 0 }
                    .buttonBorderShape(.capsule)
                    .glassButton()
                    .disabled(player.subtitleDelay == 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            if !player.usingMPV && !player.hasLoadedSubtitles {
                Text(L("Works with mpv, or with a subtitle file you load."))
                    .font(.system(size: 11))
                    .opacity(0.6)
                    .padding(.horizontal, 10)
            }
        }
    }

    private func delayButton(_ symbol: String, _ step: Double, _ label: String) -> some View {
        Button {
            player.subtitleDelay = ((player.subtitleDelay + step) * 10).rounded() / 10
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 26, height: 26)
        }
        .buttonBorderShape(.circle)
        .glassButton()
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var avTracks: some View {
                if player.hasLoadedSubtitles {
                    MenuSection(title: L("Loaded subtitles"))
                    MenuRow(title: L("Remove loaded subtitles"), symbol: "xmark.circle", isSelected: false) {
                        player.clearLoadedSubtitles()
                    }
                }
                subtitleDelayRow
                if !player.subtitleOptions.isEmpty {
                    MenuSection(title: L("Subtitles"))
                    MenuRow(title: L("Off"), isSelected: player.selectedSubtitle == nil) { player.selectSubtitle(nil) }
                    ForEach(player.subtitleOptions, id: \.self) { option in
                        MenuRow(title: option.displayName, isSelected: player.selectedSubtitle == option) {
                            player.selectSubtitle(option)
                        }
                    }
                }
                if !player.audioOptions.isEmpty {
                    MenuSection(title: L("Audio"))
                    ForEach(player.audioOptions, id: \.self) { option in
                        MenuRow(title: option.displayName, isSelected: player.selectedAudio == option) {
                            player.selectAudio(option)
                        }
                    }
                }
    }

    /// Track menu when mpv is playing (B77).
    @ViewBuilder
    private var mpvTracks: some View {
        subtitleDelayRow
        MenuSection(title: L("Subtitles"))
        MenuRow(title: L("Off"), isSelected: player.mpvSelectedSubtitle == nil) { player.selectMPVSubtitle(nil) }
        ForEach(player.mpvSubtitleTracks) { track in
            MenuRow(title: track.title, isSelected: player.mpvSelectedSubtitle == track.id) {
                player.selectMPVSubtitle(track.id)
            }
        }
        if !player.mpvAudioTracks.isEmpty {
            MenuSection(title: L("Audio"))
            ForEach(player.mpvAudioTracks) { track in
                MenuRow(title: track.title, isSelected: player.mpvSelectedAudio == track.id) {
                    player.selectMPVAudio(track.id)
                }
            }
        }
    }

    private var channelsPanel: some View {
            GlassPanel(title: L("Channels"), width: 320, maxHeight: 400, onClose: { chrome.panel = nil }) {
                if !model.channelHistory.isEmpty {
                    MenuSection(title: L("History"))
                    ForEach(model.channelHistory.prefix(10), id: \.self) { id in
                        if let channel = model.libraryIndex.item(id: id) {
                            MenuRow(title: channel.name, subtitle: channel.group, isSelected: channel.id == item.id) {
                                model.play(channel)
                            }
                        }
                    }
                }
                ForEach(playlistChannels) { channel in
                    MenuRow(title: channel.name, subtitle: channel.group, isSelected: channel.id == item.id) {
                        model.play(channel)
                    }
                }
            }
    }

    private var playlistChannels: [MediaItem] {
        model.libraryIndex.live.filter { $0.playlistID == item.playlistID }
    }

    // MARK: - Behaviour

    private func reveal() {
        chrome.lastActivity = Date()
        if !chrome.visible { chrome.visible = true }
    }

    private func autoHide() {
        let delay = UserDefaults.standard.double(forKey: SettingsKeys.controlsAutoHide)
        guard chrome.visible, player.isPlaying, !chrome.hoveringControls, chrome.panel == nil,
              Date().timeIntervalSince(chrome.lastActivity) > (delay > 0 ? delay : 3) else { return }
        chrome.visible = false
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func start() {
        reveal()
        guard let url = item.url else { player.failed = L("This item has no stream URL."); return }
        let itemID = item.id
        // Engine: per-playlist override, else the global setting. The
        // controller handles the AVPlayer → mpv fallback itself.
        let playlist = model.playlists.first { $0.id == item.playlistID }
        let engine = EnginePicker.engine(playlistOverride: playlist?.engineOverride)
        player.onProgress = { [weak model] seconds, duration in
            model?.savePosition(for: itemID, seconds: seconds, duration: duration)
        }
        player.onEnded = { [weak model] in
            if model?.nextEpisode != nil { model?.playNextEpisode() }
        }
        player.load(url: url, headers: item.httpHeaders, resumeAt: model.resumePosition(for: itemID)?.seconds,
                    engine: engine)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.yellow)
            Text(L("Can't play this stream"))
                .font(.system(size: 16, weight: .bold))
            Text(message)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .opacity(0.8)
                .frame(maxWidth: 420)
            if !installedExternalPlayers().isEmpty {
                Menu(L("Open in external player")) {
                    ForEach(installedExternalPlayers(), id: \.path) { app in
                        Button(app.deletingPathExtension().lastPathComponent) { openInExternalPlayer(app) }
                    }
                }
                .fixedSize()
                .buttonBorderShape(.capsule)
                .glassButton()
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func close() {
        if player.isFullScreen { player.toggleFullScreen() }
        player.teardown()
        model.endPlayback()
    }

    private let externalPlayers = ["VLC", "IINA", "Infuse"]

    private func installedExternalPlayers() -> [URL] {
        externalPlayers.compactMap { name in
            let url = URL(fileURLWithPath: "/Applications/\(name).app")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    // MARK: PiP


    private func togglePiP() {
        guard player.usingMPV, let engine = player.mpv else { player.togglePiP(); return }
        if ui.pipWindow != nil { closePiPWindow(); return }
        // mpv has no system PiP: move its video view into a floating panel.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = item.name
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = content
        engine.hostView.removeFromSuperview()
        engine.hostView.frame = content.bounds
        content.addSubview(engine.hostView)
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 24, y: screen.minY + 24))
        }
        panel.orderFront(nil)
        ui.pipObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            Task { @MainActor in ui.pipWindow = nil }   // MPVSurface takes the view back
        }
        ui.pipWindow = panel
    }

    private func closePiPWindow() {
        if let observer = ui.pipObserver { NotificationCenter.default.removeObserver(observer) }
        ui.pipObserver = nil
        ui.pipWindow?.close()
        ui.pipWindow = nil
    }

    private func openInExternalPlayer(_ app: URL) {
        guard let url = item.url else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private var showsNextEpisode: Bool {
        !player.isLive && player.duration > 0 && player.duration - player.currentTime < 90 && model.nextEpisode != nil
    }

    private func zap(_ delta: Int) {
        let channels = playlistChannels
        guard channels.count > 1,
              let index = channels.firstIndex(where: { $0.id == item.id }) else { return }
        model.play(channels[(index + delta + channels.count) % channels.count])
    }

    private func statsSheet(_ stats: StreamStats) -> some View {
        Sheet(title: L("Stats")) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { Text(L("Resolution")); Text(stats.resolution) }
                GridRow { Text(L("Bitrate")); Text(stats.indicatedBitrate) }
                GridRow { Text(L("Throughput")); Text(stats.observedBitrate) }
                GridRow { Text(L("Buffer")); Text(stats.buffer) }
                GridRow { Text(L("Dropped frames")); Text("\(stats.droppedFrames)") }
            }
            .font(.system(size: 13))
            .padding(24)
        }
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - EPG panel content

private extension PlayerView {
    var epgPrograms: [EPGProgram] {
        guard let epg = model.epgByPlaylist[item.playlistID] else { return [] }
        return epg[model.epgChannelID(for: item) ?? ""] ?? []
    }

    var filteredEPGPrograms: [EPGProgram] {
        let now = Date()
        switch chrome.epgMode {
        case .past: return epgPrograms.filter { $0.end <= now }
        case .now: return epgPrograms.filter { $0.contains(now) }
        case .later: return epgPrograms.filter { $0.start >= now }
        }
    }

    var epgTab: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(EPGMode.allCases, id: \.self) { mode in
                    Button {
                        chrome.epgMode = mode
                    } label: {
                        Text(mode.title)
                            .font(.system(size: 13, weight: chrome.epgMode == mode ? .bold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(chrome.epgMode == mode ? Color.accentColor.opacity(0.2) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredEPGPrograms) { program in
                        Button { remind(program) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(program.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(program.timeRange).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("Remind me"))
                    }
            }
        }
    }

    func remind(_ program: EPGProgram) {   // B15
        Task {
            try? await Reminders.schedule(id: program.id, title: L("Program starting soon"),
                                          body: String(format: L("%@ on %@"), program.title, item.name), at: program.start)
        }
    }
}

enum EPGMode: CaseIterable {
    case past, now, later
    var title: String {
        switch self {
        case .past: return L("Past")
        case .now: return L("Now")
        case .later: return L("Later")
        }
    }
}

private enum PlayerPanelKind: Equatable {
    case speed, tracks, aspect, channels, epg, more, cast
}

/// Device list for the Cast panel. Searching starts when the panel opens.
private struct CastPanelContent: View {
    @ObservedObject var player: PlayerController
    @ObservedObject private var browser = CastBrowser.shared
    let item: MediaItem
    let onDone: () -> Void

    var body: some View {
        if let session = player.cast {
            MenuRow(title: session.device.name, subtitle: L("Casting"), symbol: "tv.fill", isSelected: true) {}
            MenuRow(title: L("Stop casting"), symbol: "stop.circle", isSelected: false) {
                player.stopCasting(resumeLocally: true)
                onDone()
            }
        } else if let blocker = player.castBlocker {
            note(blocker)
        } else {
            if browser.devices.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(browser.error ?? L("Looking for TVs on your network…"))
                        .font(.system(size: 12))
                        .opacity(0.75)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            ForEach(browser.devices) { device in
                MenuRow(title: device.name, subtitle: device.model, symbol: "tv", isSelected: false) {
                    player.startCasting(to: device, title: item.name, imageURL: item.logo.flatMap(URL.init(string:)))
                    onDone()
                }
            }
            if let headers = item.httpHeaders, !headers.isEmpty {
                note(L("This stream needs custom headers, which TVs can't send, so it may not play."))
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .opacity(0.7)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }
}

/// Shown over the video while a TV is playing the stream.
private struct CastingOverlay: View {
    @ObservedObject var session: CastSession
    let title: String
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tv")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(String(format: L("Casting to %@"), session.device.name))
                .font(.system(size: 20, weight: .bold))
            Text(title)
                .font(.system(size: 14))
                .opacity(0.7)
                .lineLimit(1)
            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isFailed ? Color.yellow : Color.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(L("Stop casting"), action: onStop)
                .buttonBorderShape(.capsule)
                .glassButton()
                .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var isFailed: Bool {
        if case .failed = session.state { return true }
        return false
    }

    private var statusText: String {
        switch session.state {
        case .connecting: return L("Connecting…")
        case .launching: return L("Starting the player on the TV…")
        case .loading, .buffering: return L("Loading…")
        case .playing: return L("Playing on the TV")
        case .paused: return L("Paused")
        case .idle: return L("Stopped")
        case .failed(let message): return message
        }
    }
}

/// The player's one control style: a white icon in a 36 pt circle that
/// highlights on hover; `active` for an open panel, `prominent` for Play.
private struct PlayerIconButtonStyle: ButtonStyle {
    var prominent = false
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        PlayerIconBody(configuration: configuration, prominent: prominent, active: active)
    }
}

private struct PlayerIconBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let active: Bool
    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var hover = PlayerIconHover()

    var body: some View {
        configuration.label
            .font(.system(size: prominent ? 18 : 15, weight: prominent ? .bold : .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(width: prominent ? 44 : 36, height: prominent ? 44 : 36)
            .background {
                Circle().fill(fill)
            }
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { hover.isHovering = hovering }
            }
    }

    private var fill: Color {
        if prominent { return Theme.accent.opacity(configuration.isPressed ? 0.8 : 1) }
        if active { return Color.primary.opacity(0.2) }
        return Color.primary.opacity(configuration.isPressed ? 0.18 : (hover.isHovering ? 0.1 : 0))
    }
}

private final class PlayerIconHover: ObservableObject {
    @Published var isHovering = false
}

private final class ChromeState: ObservableObject {
    @Published var visible = true
    @Published var panel: PlayerPanelKind?
    @Published var epgMode: EPGMode = .now
    var lastActivity = Date()
    var hoveringControls = false
}

private enum AspectOption: String, CaseIterable, Identifiable {
    case fit, fill, stretch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fit: return L("Fit")
        case .fill: return L("Fill")
        case .stretch: return L("Stretch")
        }
    }
    var detail: String {
        switch self {
        case .fit: return L("Whole picture, may letterbox")
        case .fill: return L("Fill the window, may crop")
        case .stretch: return L("Fill the window, may distort")
        }
    }
    var gravity: AVLayerVideoGravity {
        switch self {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }
}

struct StreamStats: Equatable {
    var resolution: String
    var indicatedBitrate: String
    var observedBitrate: String
    var buffer: String
    var droppedFrames: Int
}

// MARK: - Glass panel & rows

/// A compact clear-glass panel that opens above its control-bar button:
/// small caption, rows, sized to its content (scrolls past `maxHeight`).
/// It closes with Esc, a click on the video, or its button again.
private struct GlassPanel<Content: View>: View {
    let title: String
    var width: CGFloat = 260
    var maxHeight: CGFloat = 360
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuSection(title: title)
                .padding(.horizontal, 4)
                .padding(.top, 4)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 1) { content }
            }
            .scrollBounceBehavior(.basedOnSize)
            // Ideal height = content height, capped at maxHeight: the panel
            // hugs short lists and scrolls long ones.
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(width: width)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onExitCommand(perform: onClose)
    }
}

// MARK: - AppKit bridges

private final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct VideoSurface: NSViewRepresentable {
    @ObservedObject var controller: PlayerController

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = controller.player
        view.playerLayer.videoGravity = controller.videoGravity
        if AVPictureInPictureController.isPictureInPictureSupported() {
            controller.pip = AVPictureInPictureController(playerLayer: view.playerLayer)
        }
        DispatchQueue.main.async {
            if let window = view.window { controller.attach(window: window) }
        }
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.playerLayer.player = controller.player
        nsView.playerLayer.videoGravity = controller.videoGravity
        var transform = CATransform3DIdentity
        transform = CATransform3DScale(transform, controller.zoomScale, controller.zoomScale, 1)
        transform = CATransform3DTranslate(transform, controller.zoomOffset.width, controller.zoomOffset.height, 0)
        nsView.playerLayer.transform = transform
        if let window = nsView.window { controller.attach(window: window) }
    }

    static func dismantleNSView(_ nsView: PlayerLayerView, coordinator: ()) {
        nsView.playerLayer.player = nil
    }
}

private extension EPGProgram {
    func contains(_ date: Date) -> Bool { date >= start && date <= end }
}

// MARK: - File picker & OpenSubtitles

private struct FilePickerView: View {
    let onPick: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ui = PickerUI()

    var body: some View {
        Sheet(title: L("Load Subtitles")) {
            VStack(spacing: 16) {
                Button(L("Select .srt / .vtt files")) { ui.isImporting = true }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .glassProminentButton()
            }
            .padding(24)
            .fileImporter(isPresented: Binding(get: { ui.isImporting }, set: { ui.isImporting = $0 }), allowedContentTypes: [.plainText, .text] + ["srt", "vtt"].compactMap { UTType(filenameExtension: $0) }, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { onPick(urls) }
                dismiss()
            }
        }
    }
}

private struct OpenSubtitlesView: View {
    @Binding var isPresented: Bool
    let item: MediaItem
    let player: PlayerController
    @StateObject private var ui = OpenSubtitlesUI()

    var body: some View {
        Sheet(title: L("Search OpenSubtitles"), subtitle: L("Search and download subtitles")) {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    TextField(L("Search..."), text: Binding(get: { ui.searchQuery }, set: { ui.searchQuery = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Button(L("Search")) { search() }
                        .controlSize(.large)
                        .buttonBorderShape(.capsule)
                        .glassButton()
                        .disabled(ui.searchQuery.trimmed.isEmpty || ui.isSearching)
                }
                .padding(.horizontal, 16)

                if ui.isSearching {
                    ProgressView().padding(.top, 20)
                } else if !ui.results.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(ui.results, id: \.id) { sub in
                                Button { download(sub) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(sub.attributes.featureDetails?.title ?? item.name)
                                                .font(.system(size: 13, weight: .semibold))
                                            Text(sub.attributes.language)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.down.circle.fill")
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                } else if let errorText = ui.errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red).padding(.top, 20)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func apiKey() -> String {
        CredentialStore.secret(forAccount: "openSubtitles.apiKey") ?? ""   // B2/B26: no hardcoded key, Keychain-backed
    }

    private func search() {
        Task {
            await MainActor.run { ui.isSearching = true; ui.errorText = nil }
            do {
                var client = OpenSubtitlesClient(apiKey: apiKey())
                try await client.login()
                let found = try await client.search(query: ui.searchQuery)
                await MainActor.run { ui.results = found; ui.isSearching = false }
            } catch {
                await MainActor.run { ui.errorText = error.localizedDescription; ui.isSearching = false }
            }
        }
    }

    private func download(_ sub: OpenSubtitlesSubtitle) {
        Task {
            do {
                var client = OpenSubtitlesClient(apiKey: apiKey())
                try await client.login()
                let url = try await client.download(subtitleID: sub.id)
                let data = try Data(contentsOf: url)
                if let text = String(data: data, encoding: .utf8) {
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sub.srt")
                    try text.write(to: tmp, atomically: true, encoding: .utf8)
                    await MainActor.run {
                        player.loadSubtitles(from: tmp)
                        isPresented = false
                    }
                }
            } catch {
                await MainActor.run { ui.errorText = error.localizedDescription }
            }
        }
    }
}

private final class PlayerUI: ObservableObject {
    @Published var pipWindow: NSWindow?
    var pipObserver: NSObjectProtocol?
    @Published var showingSubtitlePicker = false
    @Published var showingOpenSubtitles = false
    @Published var showingStats = false
    @Published var showingMultiview = false
}

private final class PickerUI: ObservableObject {
    @Published var isImporting = false
}

private final class OpenSubtitlesUI: ObservableObject {
    @Published var searchQuery = ""
    @Published var results: [OpenSubtitlesSubtitle] = []
    @Published var isSearching = false
    @Published var errorText: String?
}

/// Hosts mpv's video view in the player. While the mpv Picture in Picture
/// panel is open the view lives there; it's taken back when the panel closes.
private struct MPVSurface: NSViewRepresentable {
    let engine: MPVEngine
    let inPiP: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        adopt(into: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        adopt(into: nsView)
    }

    private func adopt(into container: NSView) {
        guard !inPiP, engine.hostView.superview !== container else { return }
        engine.hostView.removeFromSuperview()
        engine.hostView.frame = container.bounds
        container.addSubview(engine.hostView)
    }
}

private struct AirPlayButton: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
