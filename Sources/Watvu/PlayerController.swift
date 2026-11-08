import AVFoundation
import AVKit
import AppKit
import Combine
import MediaPlayer
import SwiftUI

/// Drives playback for the player view. AVPlayer is the primary engine; when
/// the engine setting allows it, mpv takes over for formats AVPlayer can't
/// play. Every control goes through this class, so the UI works the same with
/// either engine (B77).
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    @Published var isPlaying = false
    @Published var isBuffering = true
    @Published var isLive = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isScrubbing = false
    @Published var failed: String?
    @Published var isFullScreen = false
    @Published var videoGravity: AVLayerVideoGravity = .resizeAspect { didSet { mpv?.setGravity(videoGravity) } }
    /// Whether the video under the bottom control bar is bright.
    @Published var bottomIsBright = false
    private let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    @Published var volume: Float = PlayerController.savedVolume {
        didSet {
            player.volume = volume
            mpv?.setVolume(volume)
            cast?.setVolume(volume)
            UserDefaults.standard.set(Double(volume), forKey: SettingsKeys.playerVolume)
            if volume > 0, isMuted { isMuted = false }
        }
    }
    @Published var isMuted = false { didSet { player.isMuted = isMuted; mpv?.setMuted(isMuted) } }
    @Published var audioOptions: [AVMediaSelectionOption] = []
    @Published var subtitleOptions: [AVMediaSelectionOption] = []
    @Published var selectedAudio: AVMediaSelectionOption?
    @Published var selectedSubtitle: AVMediaSelectionOption?
    @Published var rate: Float = 1
    @Published var stats: StreamStats?
    @Published var showResumePrompt = false
    @AppStorage("subtitleSize") private var subtitleSize = 18
    @AppStorage("subtitleColor") private var subtitleColor = "white"
    /// Subtitle delay in seconds (positive = subtitles later). Applies to mpv
    /// subtitles and to subtitle files loaded into the AVPlayer layer.
    @Published var subtitleDelay: Double = 0 {
        didSet { mpv?.setSubtitleDelay(subtitleDelay); updateCue() }
    }
    /// Text of the loaded subtitle file currently on screen (AVPlayer mode).
    @Published private(set) var cueText: String?
    @Published private(set) var hasLoadedSubtitles = false
    private var cues: [SubtitleCue] = []
    @Published var zoomScale: CGFloat = 1.0
    @Published var zoomOffset: CGSize = .zero

    /// Called every few seconds (and on close) with position and duration.
    var onProgress: ((Double, Double) -> Void)?
    var onEnded: (() -> Void)?

    // mpv engine state (B77)
    @Published private(set) var usingMPV = false
    @Published private(set) var mpvAudioTracks: [MPVTrack] = []
    @Published private(set) var mpvSubtitleTracks: [MPVTrack] = []
    @Published private(set) var mpvSelectedAudio: Int?
    @Published private(set) var mpvSelectedSubtitle: Int?
    private(set) var mpv: MPVEngine?
    private var mpvCancellables = Set<AnyCancellable>()
    private var itemCancellables = Set<AnyCancellable>()
    private var source: (url: URL, headers: [String: String]?)?
    private var requestedResume: Double?
    private var allowsFallback = false

    // Google Cast: while casting, the local player is paused and every
    // control goes to the TV.
    @Published private(set) var cast: CastSession?
    private var castCancellables = Set<AnyCancellable>()
    private var lastProgressReport = Date.distantPast
    private var resumeAt: Double?
    var pendingResumeAt: Double?

    weak var window: NSWindow?
    var pip: AVPictureInPictureController?
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    private var remoteCommandCenter: MPRemoteCommandCenter?
    private var headerLoader: HeaderLoader?
    private var nowPlayingSession: MPNowPlayingInfoCenter?

    func attach(window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        isFullScreen = window.styleMask.contains(.fullScreen)
        let center = NotificationCenter.default
        center.publisher(for: NSWindow.didEnterFullScreenNotification, object: window)
            .sink { [weak self] _ in self?.isFullScreen = true }
            .store(in: &cancellables)
        center.publisher(for: NSWindow.didExitFullScreenNotification, object: window)
            .sink { [weak self] _ in self?.isFullScreen = false }
            .store(in: &cancellables)
        setupNowPlaying()
    }

    private func setupNowPlaying() {
        nowPlayingSession = MPNowPlayingInfoCenter.default()
        remoteCommandCenter = MPRemoteCommandCenter.shared()

        remoteCommandCenter?.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        remoteCommandCenter?.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        remoteCommandCenter?.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlay()
            return .success
        }
        remoteCommandCenter?.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }

        updateNowPlayingInfo()
    }

    private func updateNowPlayingInfo() {
        guard player.currentItem != nil else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = "Watvu Player"
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0
        nowPlayingSession?.nowPlayingInfo = info
    }

    /// Loads a stream with the engine the settings ask for. `.auto` uses
    /// AVPlayer and retries with mpv if AVPlayer fails (or goes straight to
    /// mpv for containers AVPlayer can't open).
    func load(url: URL, headers: [String: String]? = nil, resumeAt: Double? = nil, engine: EngineKind = .avplayer) {
        source = (url, headers)
        requestedResume = resumeAt
        allowsFallback = engine == .auto
        let wantsMPV = engine == .mpv || (engine == .auto && EnginePicker.needsMPV(url: url))
        if wantsMPV, MPVEngine.isAvailable {
            startMPV()
            return
        }
        if engine == .mpv {
            Logger.shared.log("info", "mpv requested but libmpv isn't installed; using AVPlayer")
        }
        loadAVPlayer(url: url, headers: headers, resumeAt: resumeAt)
    }

    private func loadAVPlayer(url: URL, headers: [String: String]?, resumeAt: Double?) {
        if let resumeAt, resumeAt > 5 {
            pendingResumeAt = resumeAt
            showResumePrompt = true
            self.resumeAt = nil
        } else {
            self.resumeAt = resumeAt
        }
        let asset = AVURLAsset(url: url)
        if let headers, !headers.isEmpty {
            // B30: inject custom headers through the public resource-loader
            // delegate instead of the undocumented options key.
            headerLoader = HeaderLoader(headers: headers)
            asset.resourceLoader.setDelegate(headerLoader, queue: .main)
        }
        let item = AVPlayerItem(asset: asset)
        item.add(videoOutput)
        player.volume = volume
        player.replaceCurrentItem(with: item)
        // B55: dead/slow streams get feedback instead of a black screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.usingMPV, self.cast == nil, self.failed == nil, !self.isPlaying, self.currentTime == 0 else { return }
            Logger.shared.log("error", "stream load timeout")
            self.handleAVFailure(L("Couldn't load this stream (timed out)."))
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, !self.isScrubbing, time.seconds.isFinite else { return }
            self.currentTime = time.seconds
            self.updateCue()
            self.reportProgress(time.seconds)
            self.updateNowPlayingInfo()
        }

        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.onEnded?() }
            .store(in: &itemCancellables)

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPlaying = status != .paused
                self?.isBuffering = status == .waitingToPlayAtSpecifiedRate
            }
            .store(in: &itemCancellables)

        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    let duration = item.duration
                    self.isLive = duration.isIndefinite
                    self.duration = duration.isIndefinite ? 0 : duration.seconds
                    self.loadMediaOptions(item.asset)
                    self.applySubtitleStyling()
                    if let resume = self.resumeAt, !self.isLive, resume < self.duration - 5 {
                        self.seek(to: resume)
                    }
                    self.resumeAt = nil
                case .failed:
                    self.isBuffering = false
                    self.handleAVFailure(item.error?.localizedDescription ?? L("The stream couldn’t be loaded."))
                default:
                    break
                }
            }
            .store(in: &itemCancellables)

        player.play()
    }

    private func reportProgress(_ seconds: Double) {
        guard !isLive, duration > 0, Date().timeIntervalSince(lastProgressReport) > 5 else { return }
        lastProgressReport = Date()
        onProgress?(seconds, duration)
    }

    /// AVPlayer failed or timed out: retry with mpv when allowed, else show the error.
    private func handleAVFailure(_ message: String) {
        guard !usingMPV else { return }
        if allowsFallback, MPVEngine.isAvailable {
            Logger.shared.log("info", "AVPlayer failed (\(message)); retrying with mpv")
            startMPV()
            return
        }
        failed = message
    }

    private func stopAVPlayer() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        itemCancellables.removeAll()
        player.replaceCurrentItem(with: nil)
    }

    private func startMPV() {
        guard let source else { return }
        stopAVPlayer()
        let engine = mpv ?? MPVEngine()
        mpv = engine
        usingMPV = true
        failed = nil
        isBuffering = true
        bind(engine)
        engine.setVolume(volume)
        engine.setMuted(isMuted)
        engine.setRate(rate)
        engine.setGravity(videoGravity)
        engine.setSubtitleDelay(subtitleDelay)
        cues = []; cueText = nil; hasLoadedSubtitles = false
        engine.load(url: source.url, headers: source.headers)
        if let resume = requestedResume, resume > 5 {
            pendingResumeAt = resume
            showResumePrompt = true
        }
    }

    /// Mirrors mpv's state into this controller so the view needs no changes.
    private func bind(_ engine: MPVEngine) {
        mpvCancellables.removeAll()
        engine.$currentTime.sink { [weak self] time in
            guard let self, !self.isScrubbing else { return }
            self.currentTime = time
            self.reportProgress(time)
        }.store(in: &mpvCancellables)
        engine.$duration.sink { [weak self] value in
            self?.duration = value
            self?.isLive = value <= 0
        }.store(in: &mpvCancellables)
        engine.$isPlaying.sink { [weak self] in self?.isPlaying = $0 }.store(in: &mpvCancellables)
        engine.$isBuffering.sink { [weak self] in self?.isBuffering = $0 }.store(in: &mpvCancellables)
        engine.$failed.compactMap { $0 }.sink { [weak self] in self?.failed = $0 }.store(in: &mpvCancellables)
        engine.$audioTracks.sink { [weak self] in self?.mpvAudioTracks = $0 }.store(in: &mpvCancellables)
        engine.$subtitleTracks.sink { [weak self] in self?.mpvSubtitleTracks = $0 }.store(in: &mpvCancellables)
        engine.$selectedAudio.sink { [weak self] in self?.mpvSelectedAudio = $0 }.store(in: &mpvCancellables)
        engine.$selectedSubtitle.sink { [weak self] in self?.mpvSelectedSubtitle = $0 }.store(in: &mpvCancellables)
        engine.onEnded = { [weak self] in self?.onEnded?() }
    }

    // MARK: Google Cast

    /// Why the current stream can't be cast, if it can't.
    var castBlocker: String? {
        guard let url = source?.url else { return L("Nothing is playing.") }
        guard url.scheme == "http" || url.scheme == "https" else {
            return L("Only web streams can be cast (not local files).")
        }
        return nil
    }

    /// Starts playing the current stream on a Cast device and pauses here.
    func startCasting(to device: CastDevice, title: String, imageURL: URL?) {
        guard castBlocker == nil, let url = source?.url else { return }
        stopCasting(resumeLocally: false)
        let resumeAt = currentTime
        if usingMPV { mpv?.pause() } else { player.pause() }
        let session = CastSession(device: device)
        cast = session
        castCancellables.removeAll()
        session.$currentTime.sink { [weak self] time in
            guard let self, !self.isScrubbing else { return }
            self.currentTime = time
            self.reportProgress(time)
        }.store(in: &castCancellables)
        session.$duration.sink { [weak self] value in
            if value > 0 { self?.duration = value }
        }.store(in: &castCancellables)
        session.$state.sink { [weak self] state in
            guard let self else { return }
            self.isPlaying = state == .playing || state == .buffering
            self.isBuffering = state == .buffering || state == .loading || state == .connecting || state == .launching
        }.store(in: &castCancellables)
        session.onEnded = { [weak self] in self?.onEnded?() }
        session.setVolume(volume)
        session.cast(url: url, title: title, imageURL: imageURL, isLive: isLive, startAt: resumeAt)
    }

    /// Stops casting. With `resumeLocally`, playback continues here from the
    /// TV's position.
    func stopCasting(resumeLocally: Bool) {
        guard let session = cast else { return }
        let position = session.currentTime
        castCancellables.removeAll()
        session.stop()
        cast = nil
        guard resumeLocally else { return }
        if !isLive, position > 0 { seek(to: position) }
        if usingMPV { mpv?.play() } else { player.play() }
    }

    func selectMPVAudio(_ id: Int) { mpv?.selectAudio(id) }
    func selectMPVSubtitle(_ id: Int?) { mpv?.selectSubtitle(id) }

    private func loadMediaOptions(_ asset: AVAsset) {
        // Preferred language from Settings auto-selects matching tracks.
        let preferred = UserDefaults.standard.string(forKey: "preferredLanguage") ?? ""

        Task { @MainActor [weak self] in
            let audio = (try? await asset.loadMediaSelectionGroup(for: .audible)) ?? nil
            let legible = (try? await asset.loadMediaSelectionGroup(for: .legible)) ?? nil
            do {
                guard let self else { return }
                self.audioGroup = audio
                self.subtitleGroup = legible
                self.audioOptions = audio?.options ?? []
                self.subtitleOptions = legible?.options ?? []
                let selection = self.player.currentItem?.currentMediaSelection
                self.selectedAudio = audio.flatMap { selection?.selectedMediaOption(in: $0) }
                self.selectedSubtitle = legible.flatMap { selection?.selectedMediaOption(in: $0) }
                // B64: apply the preferred language to both track groups.
                if !preferred.isEmpty {
                    if let audio, let match = PlayerController.preferred(in: audio.options, language: preferred) {
                        self.selectedAudio = match
                        self.player.currentItem?.select(match, in: audio)
                    }
                    if let legible, let match = PlayerController.preferred(in: legible.options, language: preferred) {
                        self.selectedSubtitle = match
                        self.player.currentItem?.select(match, in: legible)
                    }
                }
            }
        }
    }

    /// Samples the current frame's luminance where the control bar sits
    /// (bottom-center) and flips `bottomIsBright` with hysteresis so the
    /// glyphs don't flicker around the threshold.
    static var savedVolume: Float {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: SettingsKeys.playerVolume) != nil else { return 1 }
        return Float(defaults.double(forKey: SettingsKeys.playerVolume))
    }

    func sampleBrightness() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: SettingsKeys.adaptiveControls) != nil,
           !defaults.bool(forKey: SettingsKeys.adaptiveControls) {
            if bottomIsBright { bottomIsBright = false }
            return
        }
        let time = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard let buffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0 else { return }

        let x0 = width / 5, x1 = width * 4 / 5
        let y0 = height * 3 / 4, y1 = height
        let xStep = max(1, (x1 - x0) / 48), yStep = max(1, (y1 - y0) / 16)
        var sum = 0.0, count = 0.0
        for y in stride(from: y0, to: y1, by: yStep) {
            let row = base + y * rowBytes
            for x in stride(from: x0, to: x1, by: xStep) {
                let p = row + x * 4 // BGRA
                sum += 0.0722 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.2126 * Double(p[2])
                count += 1
            }
        }
        guard count > 0 else { return }
        let luminance = sum / count / 255
        if !bottomIsBright, luminance > 0.62 { bottomIsBright = true }
        else if bottomIsBright, luminance < 0.48 { bottomIsBright = false }
    }

    func selectAudio(_ option: AVMediaSelectionOption) {
        guard let group = audioGroup else { return }
        player.currentItem?.select(option, in: group)
        selectedAudio = option
    }

    func selectSubtitle(_ option: AVMediaSelectionOption?) {
        guard let group = subtitleGroup else { return }
        player.currentItem?.select(option, in: group)
        selectedSubtitle = option
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if usingMPV { mpv?.setRate(newRate); return }
        player.defaultRate = newRate
        if player.timeControlStatus != .paused { player.rate = newRate }
    }

    func updateStats() {
        if usingMPV, let mpv { stats = mpv.stats(); return }
        guard let item = player.currentItem else { return }
        let event = item.accessLog()?.events.last
        let size = item.presentationSize
        let buffered = item.loadedTimeRanges.last.map { CMTimeRangeGetEnd($0.timeRangeValue).seconds - currentTime } ?? 0
        stats = StreamStats(
            resolution: size.width > 0 ? "\(Int(size.width))×\(Int(size.height))" : "—",
            indicatedBitrate: Self.bitrate(event?.indicatedBitrate),
            observedBitrate: Self.bitrate(event?.observedBitrate),
            buffer: buffered > 0 ? String(format: "%.1f s", buffered) : "—",
            droppedFrames: max(event?.numberOfDroppedVideoFrames ?? 0, 0)
        )
    }

    private static func bitrate(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return value >= 1_000_000 ? String(format: "%.1f Mbps", value / 1_000_000) : String(format: "%.0f kbps", value / 1_000)
    }

    func play() { if !isPlaying { togglePlay() } }
    func pause() { if isPlaying { togglePlay() } }

    func togglePlay() {
        if let cast { isPlaying ? cast.pause() : cast.play(); return }
        if usingMPV, let mpv { mpv.togglePlay(); return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        updateNowPlayingInfo()
    }

    func seek(by delta: Double) {
        guard !isLive else { return }
        seek(to: min(max(currentTime + delta, 0), duration))
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        if let cast { cast.seek(to: seconds); return }
        if usingMPV, let mpv { mpv.seek(to: seconds); return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlayingInfo()
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    func togglePiP() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }


    /// Loads an .srt / .vtt file. mpv adds it as a track; with AVPlayer the
    /// app draws it itself (AVPlayer can't attach a side-loaded file to a
    /// stream), which also makes the subtitle delay work.
    func loadSubtitles(from url: URL) {
        if usingMPV, let mpv { mpv.addSubtitle(url); return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            Logger.shared.log("error", "couldn't read subtitle file \(url.lastPathComponent)")
            return
        }
        let parsed = SubtitleParser.parse(data: data)
        guard !parsed.isEmpty else {
            Logger.shared.log("error", "no subtitles found in \(url.lastPathComponent)")
            return
        }
        cues = parsed
        hasLoadedSubtitles = true
        selectSubtitle(nil)   // hide the stream's own subtitles
        updateCue()
    }

    func clearLoadedSubtitles() {
        cues = []
        cueText = nil
        hasLoadedSubtitles = false
    }

    private func updateCue() {
        guard !usingMPV, !cues.isEmpty else {
            if cueText != nil { cueText = nil }
            return
        }
        let text = SubtitleParser.cue(at: currentTime - subtitleDelay, in: cues)?.text
        if text != cueText { cueText = text }
    }

    /// Styles the stream's own subtitles from Settings. Size is in points,
    /// relative to an 18 pt default (AVFoundation takes a percentage).
    private func applySubtitleStyling() {
        guard player.currentItem != nil else { return }
        let percent = Double(subtitleSize) / 18 * 100
        guard let textStyle = AVTextStyleRule(textMarkupAttributes: [
            kCMTextMarkupAttribute_FontFamilyName as String: "Helvetica",
            kCMTextMarkupAttribute_ForegroundColorARGB as String: Self.argb(subtitleColor),
            kCMTextMarkupAttribute_RelativeFontSize as String: percent
        ]) else { return }
        player.currentItem?.textStyleRules = [textStyle]
    }

    /// Alpha, red, green, blue (0–1) for a subtitle colour name.
    static func argb(_ color: String) -> [Double] {
        switch color {
        case "black": return [1, 0, 0, 0]
        case "yellow": return [1, 1, 1, 0]
        case "red": return [1, 1, 0, 0]
        case "green": return [1, 0, 1, 0]
        case "blue": return [1, 0, 0, 1]
        default: return [1, 1, 1, 1]
        }
    }

    /// SwiftUI colour for a subtitle colour name (Settings swatches, the
    /// player's own subtitle layer).
    static func subtitleSwiftUIColor(_ color: String) -> Color {
        let v = argb(color)
        return Color(red: v[1], green: v[2], blue: v[3])
    }

    func handleResumeChoice(resume: Bool) {
        if resume, let resumeAt = pendingResumeAt {
            seek(to: resumeAt)
        } else {
            pendingResumeAt = nil
        }
        showResumePrompt = false
    }

    func teardown() {
        if !isLive, duration > 0 { onProgress?(currentTime, duration) }
        stopCasting(resumeLocally: false)
        stopAVPlayer()
        cancellables.removeAll()
        mpvCancellables.removeAll()
        mpv?.teardown()
        mpv = nil
        usingMPV = false
    }
}

/// Injects custom HTTP headers into AVAsset resource loads via the public
/// AVAssetResourceLoaderDelegate API (replaces AVURLAssetHTTPHeaderFieldsKey).
private final class HeaderLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let headers: [String: String]

    init(headers: [String: String]) {
        self.headers = headers
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard var urlRequest = request.request.url.map({ URLRequest(url: $0) }) else { return false }
        headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            if let error {
                request.finishLoading(with: error)
                return
            }
            if let response {
                request.contentInformationRequest?.contentType = response.mimeType
                request.contentInformationRequest?.contentLength = response.expectedContentLength
                request.contentInformationRequest?.isByteRangeAccessSupported = true
            }
            if let data {
                request.dataRequest?.respond(with: data)
                request.finishLoading()
            } else {
                request.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown))
            }
        }
        task.resume()
        return true
    }
}

extension PlayerController {
    static func preferred(in options: [AVMediaSelectionOption], language: String) -> AVMediaSelectionOption? {
        guard !language.isEmpty else { return nil }
        let want = language.lowercased()
        return options.first {
            ($0.locale.map { $0.identifier.lowercased() }.map { $0.hasPrefix(want) } ?? false)
                || ($0.extendedLanguageTag?.lowercased().hasPrefix(want) ?? false)
                || ($0.displayName.lowercased().contains(want))
        }
    }
}
