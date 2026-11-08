import SwiftUI
import AVFoundation
import Combine

struct GuideView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var state = GuideState()

    private var items: [MediaItem] { model.guideItems(group: state.group) }
    private var hasGuideSource: Bool {
        model.playlists.contains { !$0.guideSources.isEmpty }
    }

    var body: some View {
        Group {
            if state.mode == .timeline, !items.isEmpty {
                GuideTimeline(channels: items, onSelect: { channel, program in
                    state.detail = ProgramDetailItem(channel: channel, program: program)
                }, dayOffset: state.dayOffset)
                    .pinnedHeader {
                        VStack(alignment: .leading, spacing: 0) { header }
                    }
                    .background(Theme.background)
            } else {
                LibraryPage { header } content: { list }
            }
        }
        .background(Theme.background)
        .overlay(alignment: .bottom) { statusPill }
        .animation(.snappy, value: model.epgStatus)
        .navigationTitle("TV Guide")
        .sheet(item: $state.detail) { detail in
            ProgramDetailSheet(item: detail)
                .environmentObject(model)
        }
        .sheet(item: $state.mappingChannel) { channel in
            ChannelMappingView(channel: channel)
                .environmentObject(model)
        }
        .onAppear {
            if !model.guideGroups.contains(state.group) { state.group = "All" }
        }
    }

    @ViewBuilder
    private var header: some View {
        PageHeader(title: "TV Guide") {
            Button {
                withAnimation(.smooth) { state.mode = state.mode == .list ? .timeline : .list }
            } label: {
                Label(state.mode == .list ? "Timeline" : "List",
                      systemImage: state.mode == .list ? "calendar.day.timeline.left" : "list.bullet")
            }
            .help(state.mode == .list ? "Show timeline" : "Show list")

            Button {
                Task { await model.refreshEPG() }
            } label: {
                Label("Refresh Guide", systemImage: "arrow.clockwise")
            }
            .help("Refresh guide")

            if state.mode == .timeline {
                Button { withAnimation { state.dayOffset = max(-7, state.dayOffset - 1) } } label: {
                    Label("Yesterday", systemImage: "chevron.left")
                }
                .help("Previous day")
                Button { withAnimation { state.dayOffset = min(7, state.dayOffset + 1) } } label: {
                    Label("Tomorrow", systemImage: "chevron.right")
                }
                .help("Next day")
                if state.dayOffset != 0 {
                    Button { withAnimation { state.dayOffset = 0 } } label: {
                        Label("Today", systemImage: "circle.fill")
                    }
                    .help("Jump to today")
                }
            }
        }
        FilterChipBar(options: ["All"] + model.guideGroups, selection: $state.group)
    }

    @ViewBuilder
    private var list: some View {
        if items.isEmpty {
            emptyState
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(items) { item in
                    GuideRow(item: item, isPreviewing: state.previewID == item.id && guidePreviewsEnabled) { program in
                        state.detail = ProgramDetailItem(channel: item, program: program)
                    }
                    .onHover { hovering in   // B69: hover-only, after a short delay
                        if hovering {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                if state.hoverID == item.id { state.previewID = item.id }
                            }
                            state.hoverID = item.id
                        } else {
                            state.hoverID = nil
                            state.previewID = nil
                        }
                    }
                    .contextMenu {
                        Button("Map EPG Channel…") {
                            state.mappingChannel = item
                        }
                        if model.epgChannelID(for: item) != nil {
                            Button("Clear EPG Mapping") {
                                model.setEPGChannel(nil, for: item)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .animation(.smooth(duration: 0.3), value: state.group)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Theme.textSecondary)

            if model.playlists.isEmpty {
                Text("Add a playlist first")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("The guide needs a playlist with an EPG URL.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            } else if !hasGuideSource {
                Text("No EPG source")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Add an EPG URL when creating an M3U playlist, or use an Xtream account — its xmltv.php guide is detected automatically.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            } else {
                Text("No programmes in the guide")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Button("Refresh Guide") {
                    Task { await model.refreshEPG() }
                }
                .controlSize(.large)
                .glassProminentButton()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private var statusPill: some View {
        if let status = model.epgStatus {
            Text(status)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassSurface(in: Capsule())
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private final class GuideState: ObservableObject {
    enum Mode { case list, timeline }
    @Published var group = "All"
    @Published var mode = Mode.list
    @Published var dayOffset = 0
    @Published var previewID: String?   // B69: only the hovered row previews
    @Published var hoverID: String?
    @Published var detail: ProgramDetailItem?
    @Published var mappingChannel: MediaItem?
}

/// Bare video layer preview (no AVKit controls) with the channel's HTTP headers.
private struct PreviewPlayer: View {
    let item: MediaItem
    let active: Bool   // B69: only one row previews, and only when enabled
    @StateObject private var holder = PlayerHolder()

    var body: some View {
        PreviewSurface(player: holder.player, gravity: .resizeAspectFill)
            .onAppear { start() }
            .onChange(of: active) { _, isActive in isActive ? start() : holder.player?.pause() }
            .onDisappear { holder.player?.pause() }
    }

    private func start() {
        guard active, let url = item.url else { return }
        let asset = AVURLAsset(url: url)
        if let headers = item.httpHeaders, !headers.isEmpty {
            let loader = PreviewHeaderLoader(headers: headers)
            asset.resourceLoader.setDelegate(loader, queue: .main)
            holder.retain(loader)
        }
        let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        p.isMuted = true
        holder.player = p
        p.play()
    }
}

private final class PreviewHeaderLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let headers: [String: String]
    init(headers: [String: String]) { self.headers = headers }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = request.request.url else { return false }
        var r = URLRequest(url: url)
        headers.forEach { r.setValue($0.value, forHTTPHeaderField: $0.key) }   // B69: channel headers
        let task = URLSession.shared.dataTask(with: r) { data, response, error in
            if let error { request.finishLoading(with: error); return }
            if let response {
                request.contentInformationRequest?.contentType = response.mimeType
                request.contentInformationRequest?.contentLength = response.expectedContentLength
                request.contentInformationRequest?.isByteRangeAccessSupported = true
            }
            if let data { request.dataRequest?.respond(with: data); request.finishLoading() }
        }
        task.resume()
        return true
    }
}

private final class PlayerHolder: ObservableObject {
    @Published var player: AVPlayer? = AVPlayer()
    private var retainers: [Any] = []
    func retain(_ object: Any) { retainers.append(object) }
}

private struct PreviewSurface: NSViewRepresentable {
    let player: AVPlayer?
    let gravity: AVLayerVideoGravity

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = gravity
        layer.frame = view.bounds
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVPlayerLayer)?.player = player
    }
}


private var guidePreviewsEnabled: Bool {
    UserDefaults.standard.object(forKey: "guidePreviews") as? Bool ?? false   // B69: off by default
}


private struct GuideRow: View {
    @EnvironmentObject var model: AppModel
    let item: MediaItem
    var isPreviewing = false   // B69
    let onDetails: (EPGProgram) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            logo

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(item.group)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                if let now = model.nowPlaying(for: item) {
                    Text("Now: \(now.title)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(GuideStyle.current == .greyscale ? Theme.textSecondary : Theme.accent)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        Text(now.timeRange)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                        ProgressView(value: progress(now))
                            .tint(Theme.accent)
                            .frame(maxWidth: 320)
                    }
                } else {
                    Text("No guide data")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }

                if let next = model.nextPlaying(for: item) {
                    Text("Next \(next.timeRange): \(next.title)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if item.url != nil {
                PreviewPlayer(item: item, active: isPreviewing)
                    .frame(width: 160, height: 90)
                    .cornerRadius(8)
                    .shadow(radius: 4)
            }

            if let now = model.nowPlaying(for: item) {
                Button {
                    onDetails(now)
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .glassButton()
                .accessibilityLabel("Details for \(now.title)")
                .help("Programme details")
            }

            if let now = model.nowPlaying(for: item), model.canCatchup(item, now) {
                Button {
                    model.playCatchup(item, now)
                } label: {
                    Image(systemName: "gobackward")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .glassButton()
                .accessibilityLabel("Watch \(now.title) from the start")
                .help("Watch from the start")
            }

            Button {
                let program = model.nowPlaying(for: item) ?? EPGProgram(
                    id: UUID().uuidString, channelID: model.epgChannelID(for: item) ?? item.id,
                    title: L("Recording"), subtitle: nil, description: nil, category: nil,
                    start: Date(), end: Date().addingTimeInterval(3600))
                RecordingManager.shared.scheduleRecording(program, channel: item)   // B4/B54
            } label: {
                    Image(systemName: "record.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .glassButton()
                .accessibilityLabel(L("Record"))
                .help(L("Record this programme"))

            Button {
                model.activate(item)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .glassProminentButton()
            .accessibilityLabel("Play \(item.name)")
            .help("Play \(item.name)")
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var logo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.gradient(for: item.group))
            if let logo = item.logo, let url = URL(string: logo) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit().padding(8)
                    case .failure: fallback
                    case .empty: ProgressView().controlSize(.small).tint(.white)
                    @unknown default: fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: 68, height: 48)
    }

    private var fallback: some View {
        Image(systemName: "tv")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
    }

    private func progress(_ program: EPGProgram) -> Double {
        let total = program.end.timeIntervalSince(program.start)
        guard total > 0 else { return 0 }
        return min(max(Date().timeIntervalSince(program.start) / total, 0), 1)
    }
}

enum GuideStyle: String, CaseIterable {
    case colour, greyscale
    static var current: GuideStyle {
        GuideStyle(rawValue: UserDefaults.standard.string(forKey: "guideStyle") ?? "colour") ?? .colour
    }
}
