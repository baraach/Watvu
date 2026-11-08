import Foundation
import AppKit
import AVFoundation
import Combine

/// One audio or subtitle track reported by mpv.
struct MPVTrack: Identifiable, Hashable {
    let id: Int
    let title: String
}

/// libmpv-backed engine, loaded at runtime with `dlopen` so the app builds and
/// runs without bundling mpv. Video is embedded with mpv's `wid` option, which
/// on macOS takes an `NSView` pointer (libmpv adds its own subview to it).
///
/// Threading: libmpv calls are thread-safe. Events are read on a dedicated
/// thread (B79) and state is published on the main queue.
final class MPVEngine: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var failed: String?
    @Published private(set) var audioTracks: [MPVTrack] = []
    @Published private(set) var subtitleTracks: [MPVTrack] = []
    @Published private(set) var selectedAudio: Int?
    @Published private(set) var selectedSubtitle: Int?

    var onEnded: (() -> Void)?

    /// The view mpv renders into. It's created once and re-parented (player
    /// window ↔ Picture in Picture panel) so mpv keeps its surface.
    let hostView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.autoresizingMask = [.width, .height]
        return view
    }()

    private let api: MPVAPI?
    private var handle: OpaquePointer?
    private var eventThread: Thread?
    private let threadDone = DispatchSemaphore(value: 0)

    static var isAvailable: Bool { MPVAPI.shared != nil }

    override init() {
        api = MPVAPI.shared
        super.init()
        createHandle()   // B73
    }

    deinit { teardown() }

    // MARK: Setup

    private func createHandle() {
        guard let api, let mpv = api.create() else { return }
        // Options must be set before mpv_initialize.
        let wid = Int(bitPattern: Unmanaged.passUnretained(hostView).toOpaque())
        api.setOption(mpv, "wid", String(wid))   // B75: NSView pointer, not a window number
        api.setOption(mpv, "vo", "gpu-next,gpu")
        api.setOption(mpv, "hwdec", "auto-safe")
        api.setOption(mpv, "keep-open", "no")
        api.setOption(mpv, "ytdl", "no")
        api.setOption(mpv, "input-default-bindings", "no")
        api.setOption(mpv, "osc", "no")
        api.setOption(mpv, "cache", "yes")
        let language = UserDefaults.standard.string(forKey: "preferredLanguage") ?? ""
        if !language.isEmpty {
            api.setOption(mpv, "alang", language)
            api.setOption(mpv, "slang", language)
        }
        guard api.initialize(mpv) >= 0 else {
            api.terminateDestroy(mpv)
            return
        }
        handle = mpv
        // B76: observe properties instead of polling on unrelated events.
        api.observe(mpv, 1, "time-pos", MPVFormat.double)
        api.observe(mpv, 2, "duration", MPVFormat.double)
        api.observe(mpv, 3, "pause", MPVFormat.flag)
        api.observe(mpv, 4, "paused-for-cache", MPVFormat.flag)
        api.observe(mpv, 5, "track-list/count", MPVFormat.int64)
        api.observe(mpv, 6, "aid", MPVFormat.string)
        api.observe(mpv, 7, "sid", MPVFormat.string)
        startEventThread(mpv)
    }

    // MARK: Playback

    func load(url: URL, headers: [String: String]?) {
        guard let api, let mpv = handle else {
            fail(L("mpv couldn't start. Install mpv (brew install mpv) or switch the engine to AVPlayer."))
            return
        }
        failed = nil
        isBuffering = true
        currentTime = 0
        duration = 0
        // HTTP headers: User-Agent and Referer have their own options; the rest
        // are appended one by one so commas inside values aren't split.
        var rest = headers ?? [:]
        let agent = rest.removeValue(forKey: "User-Agent") ?? rest.removeValue(forKey: "user-agent")
        let referer = rest.removeValue(forKey: "Referer") ?? rest.removeValue(forKey: "referer")
        api.setOption(mpv, "user-agent", agent ?? "libmpv")
        api.setOption(mpv, "referrer", referer ?? "")
        api.setOption(mpv, "http-header-fields", "")
        for (key, value) in rest {
            api.setOption(mpv, "http-header-fields-append", "\(key): \(value)")
        }
        let path = url.isFileURL ? url.path : url.absoluteString
        api.command(mpv, ["loadfile", path, "replace"])
        api.setProperty(mpv, "pause", "no")
    }

    func play() { setProperty("pause", "no") }
    func pause() { setProperty("pause", "yes") }
    func togglePlay() { isPlaying ? pause() : play() }
    func seek(to seconds: Double) {
        currentTime = seconds
        command(["seek", String(format: "%.3f", seconds), "absolute+exact"])
    }
    func setRate(_ rate: Float) { setProperty("speed", String(rate)) }
    func setVolume(_ volume: Float) { setProperty("volume", String(Int((volume * 100).rounded()))) }
    func setMuted(_ muted: Bool) { setProperty("mute", muted ? "yes" : "no") }

    func setGravity(_ gravity: AVLayerVideoGravity) {
        switch gravity {
        case .resizeAspectFill:
            setProperty("keepaspect", "yes"); setProperty("panscan", "1.0")
        case .resize:
            setProperty("keepaspect", "no"); setProperty("panscan", "0.0")
        default:
            setProperty("keepaspect", "yes"); setProperty("panscan", "0.0")
        }
    }

    func selectAudio(_ id: Int) { setProperty("aid", String(id)) }
    func selectSubtitle(_ id: Int?) { setProperty("sid", id.map(String.init) ?? "no") }
    func addSubtitle(_ url: URL) { command(["sub-add", url.path, "select"]) }
    func setSubtitleDelay(_ seconds: Double) { setProperty("sub-delay", String(format: "%.3f", seconds)) }

    /// Stream details for the Stats sheet.
    func stats() -> StreamStats {
        let width = getString("width"), height = getString("height")
        let bitrate = Double(getString("video-bitrate") ?? "") ?? 0
        let cache = Double(getString("demuxer-cache-duration") ?? "") ?? 0
        let dropped = Int(getString("frame-drop-count") ?? "") ?? 0
        let codec = getString("video-codec") ?? ""
        return StreamStats(
            resolution: width.flatMap { w in height.map { "\(w)×\($0)" } } ?? "—",
            indicatedBitrate: bitrate > 0 ? String(format: "%.1f Mbps", bitrate / 1_000_000) : "—",
            observedBitrate: codec.isEmpty ? "—" : codec,
            buffer: cache > 0 ? String(format: "%.1f s", cache) : "—",
            droppedFrames: dropped
        )
    }


    func teardown() {
        guard let api, let mpv = handle else { return }
        handle = nil
        api.command(mpv, ["quit"])
        api.wakeup(mpv)
        // Destroy only after the event thread has stopped using the handle.
        if eventThread != nil { _ = threadDone.wait(timeout: .now() + 2) }
        eventThread = nil
        api.terminateDestroy(mpv)
    }

    // MARK: Events (B76, B79)

    private func startEventThread(_ mpv: OpaquePointer) {
        guard let api else { return }
        let box = MPVHandleBox(mpv)
        let done = threadDone
        let thread = Thread { [weak self] in
            defer { done.signal() }
            while true {
                guard let event = api.waitEvent(box.handle, -1)?.pointee else { continue }
                switch event.eventID {
                case MPVEventID.shutdown:
                    return
                case MPVEventID.endFile:
                    let reason = event.data?.assumingMemoryBound(to: MPVEventEndFile.self).pointee
                    self?.handleEndFile(reason: reason?.reason ?? 0, error: reason?.error ?? 0)
                case MPVEventID.fileLoaded:
                    self?.refreshTracks()
                case MPVEventID.propertyChange:
                    guard let property = event.data?.assumingMemoryBound(to: MPVEventProperty.self).pointee else { continue }
                    self?.handleProperty(property, userdata: event.replyUserdata)
                default:
                    continue
                }
            }
        }
        thread.name = "Watvu.mpv-events"
        thread.qualityOfService = .userInitiated
        eventThread = thread
        thread.start()
    }

    private func handleProperty(_ property: MPVEventProperty, userdata: UInt64) {
        let data = property.data
        switch (userdata, property.format) {
        case (1, MPVFormat.double):
            let value = data?.assumingMemoryBound(to: Double.self).pointee ?? 0
            onMain { $0.currentTime = value }
        case (2, MPVFormat.double):
            let value = data?.assumingMemoryBound(to: Double.self).pointee ?? 0
            onMain { $0.duration = value }
        case (3, MPVFormat.flag):
            let paused = (data?.assumingMemoryBound(to: Int32.self).pointee ?? 1) != 0
            onMain { $0.isPlaying = !paused }
        case (4, MPVFormat.flag):
            let waiting = (data?.assumingMemoryBound(to: Int32.self).pointee ?? 0) != 0
            onMain { $0.isBuffering = waiting }
        case (5, _), (6, _), (7, _):
            refreshTracks()
        case (2, MPVFormat.none):
            onMain { $0.duration = 0 }   // live streams have no duration
        default:
            break
        }
    }

    private func handleEndFile(reason: Int32, error: Int32) {
        switch reason {
        case MPVEndReason.eof:
            onMain { $0.isPlaying = false; $0.onEnded?() }
        case MPVEndReason.error:
            let message = api?.errorString(error) ?? "unknown error"
            onMain { $0.fail(String(format: L("mpv couldn't play this stream (%@)."), message)) }
        default:
            break   // stop / replaced by the next file
        }
    }

    private func refreshTracks() {
        let count = Int(getString("track-list/count") ?? "") ?? 0
        var audio: [MPVTrack] = [], subs: [MPVTrack] = []
        var audioSel: Int?, subSel: Int?
        for i in 0..<count {
            let prefix = "track-list/\(i)/"
            guard let type = getString(prefix + "type"),
                  let id = Int(getString(prefix + "id") ?? "") else { continue }
            let lang = getString(prefix + "lang") ?? ""
            let title = getString(prefix + "title") ?? ""
            let codec = getString(prefix + "codec") ?? ""
            let name = [title, lang.uppercased(), codec].filter { !$0.isEmpty }.joined(separator: " · ")
            let track = MPVTrack(id: id, title: name.isEmpty ? "Track \(id)" : name)
            let selected = getString(prefix + "selected") == "yes"
            if type == "audio" { audio.append(track); if selected { audioSel = id } }
            if type == "sub" { subs.append(track); if selected { subSel = id } }
        }
        onMain {
            $0.audioTracks = audio; $0.subtitleTracks = subs
            $0.selectedAudio = audioSel; $0.selectedSubtitle = subSel
        }
    }

    private func fail(_ message: String) {
        failed = message
        isBuffering = false
    }

    private func onMain(_ body: @escaping (MPVEngine) -> Void) {
        DispatchQueue.main.async { [weak self] in
            if let self { body(self) }
        }
    }

    // MARK: Small helpers

    private func command(_ args: [String]) {
        guard let api, let mpv = handle else { return }
        api.command(mpv, args)
    }

    private func setProperty(_ name: String, _ value: String) {
        guard let api, let mpv = handle else { return }
        api.setProperty(mpv, name, value)
    }

    private func getString(_ name: String) -> String? {
        guard let api, let mpv = handle else { return nil }
        return api.getString(mpv, name)
    }
}

// MARK: - libmpv C API (loaded with dlopen)

/// Constants from `mpv/client.h`.
private enum MPVFormat {
    static let none: Int32 = 0, string: Int32 = 1, flag: Int32 = 3, int64: Int32 = 4, double: Int32 = 5
}
private enum MPVEventID {
    static let shutdown: Int32 = 1, endFile: Int32 = 7, fileLoaded: Int32 = 8, propertyChange: Int32 = 22
}
private enum MPVEndReason {
    static let eof: Int32 = 0, error: Int32 = 4
}

/// `mpv_event` — field order and sizes match the C struct.
private struct MPVEvent {
    var eventID: Int32
    var error: Int32
    var replyUserdata: UInt64
    var data: UnsafeMutableRawPointer?
}

/// `mpv_event_property`.
private struct MPVEventProperty {
    var name: UnsafePointer<CChar>?
    var format: Int32
    var data: UnsafeMutableRawPointer?
}

/// `mpv_event_end_file` (leading fields only).
private struct MPVEventEndFile {
    var reason: Int32
    var error: Int32
}

private struct MPVHandleBox: @unchecked Sendable {
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
}

/// Function pointers resolved once from libmpv.
private final class MPVAPI: @unchecked Sendable {
    typealias CreateFn = @convention(c) () -> OpaquePointer?
    typealias HandleFn = @convention(c) (OpaquePointer?) -> Int32
    typealias VoidHandleFn = @convention(c) (OpaquePointer?) -> Void
    typealias SetStringFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    typealias CommandFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    typealias GetStringFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    typealias FreeFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias ObserveFn = @convention(c) (OpaquePointer?, UInt64, UnsafePointer<CChar>?, Int32) -> Int32
    typealias WaitFn = @convention(c) (OpaquePointer?, Double) -> UnsafeMutableRawPointer?
    typealias ErrorStringFn = @convention(c) (Int32) -> UnsafePointer<CChar>?

    static let shared: MPVAPI? = MPVAPI()

    /// Where libmpv is looked for: the app's own Frameworks folder (if it's
    /// ever bundled), then Homebrew on Apple silicon and Intel.
    static var searchPaths: [String] {
        var paths: [String] = []
        if let frameworks = Bundle.main.privateFrameworksPath {
            paths += ["\(frameworks)/libmpv.2.dylib", "\(frameworks)/libmpv.dylib"]
        }
        for prefix in ["/opt/homebrew", "/usr/local"] {
            paths += ["\(prefix)/lib/libmpv.2.dylib", "\(prefix)/lib/libmpv.dylib",
                      "\(prefix)/opt/mpv/lib/libmpv.2.dylib", "\(prefix)/opt/mpv/lib/libmpv.dylib"]
        }
        return paths
    }

    private let createFn: CreateFn
    private let initializeFn: HandleFn
    private let terminateFn: VoidHandleFn
    private let wakeupFn: VoidHandleFn
    private let setOptionFn: SetStringFn
    private let setPropertyFn: SetStringFn
    private let commandFn: CommandFn
    private let getStringFn: GetStringFn
    private let freeFn: FreeFn
    private let observeFn: ObserveFn
    private let waitFn: WaitFn
    private let errorStringFn: ErrorStringFn

    private init?() {
        guard let lib = Self.searchPaths.lazy.compactMap({ dlopen($0, RTLD_NOW | RTLD_LOCAL) }).first else { return nil }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            dlsym(lib, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let create = sym("mpv_create", CreateFn.self),
              let initialize = sym("mpv_initialize", HandleFn.self),
              let terminate = sym("mpv_terminate_destroy", VoidHandleFn.self),
              let wakeup = sym("mpv_wakeup", VoidHandleFn.self),
              let setOption = sym("mpv_set_option_string", SetStringFn.self),
              let setProperty = sym("mpv_set_property_string", SetStringFn.self),
              let command = sym("mpv_command", CommandFn.self),
              let getString = sym("mpv_get_property_string", GetStringFn.self),
              let free = sym("mpv_free", FreeFn.self),
              let observe = sym("mpv_observe_property", ObserveFn.self),
              let wait = sym("mpv_wait_event", WaitFn.self),
              let errorString = sym("mpv_error_string", ErrorStringFn.self)
        else { return nil }
        createFn = create; initializeFn = initialize; terminateFn = terminate; wakeupFn = wakeup
        setOptionFn = setOption; setPropertyFn = setProperty; commandFn = command
        getStringFn = getString; freeFn = free; observeFn = observe; waitFn = wait
        errorStringFn = errorString
    }

    func create() -> OpaquePointer? { createFn() }
    func initialize(_ mpv: OpaquePointer) -> Int32 { initializeFn(mpv) }
    func terminateDestroy(_ mpv: OpaquePointer) { terminateFn(mpv) }
    func wakeup(_ mpv: OpaquePointer) { wakeupFn(mpv) }

    @discardableResult
    func setOption(_ mpv: OpaquePointer, _ name: String, _ value: String) -> Int32 {
        name.withCString { n in value.withCString { v in setOptionFn(mpv, n, v) } }
    }

    @discardableResult
    func setProperty(_ mpv: OpaquePointer, _ name: String, _ value: String) -> Int32 {
        name.withCString { n in value.withCString { v in setPropertyFn(mpv, n, v) } }
    }

    /// `mpv_command` with a NULL-terminated argv that stays valid for the call (B75).
    @discardableResult
    func command(_ mpv: OpaquePointer, _ args: [String]) -> Int32 {
        let copies = args.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        var argv: [UnsafePointer<CChar>?] = copies.map { $0.map { UnsafePointer($0) } }
        argv.append(nil)
        return argv.withUnsafeMutableBufferPointer { commandFn(mpv, $0.baseAddress) }
    }

    func getString(_ mpv: OpaquePointer, _ name: String) -> String? {
        guard let raw = name.withCString({ getStringFn(mpv, $0) }) else { return nil }
        defer { freeFn(raw) }
        return String(cString: raw)
    }

    func observe(_ mpv: OpaquePointer, _ id: UInt64, _ name: String, _ format: Int32) {
        _ = name.withCString { observeFn(mpv, id, $0, format) }
    }

    func waitEvent(_ mpv: OpaquePointer, _ timeout: Double) -> UnsafeMutablePointer<MPVEvent>? {
        waitFn(mpv, timeout)?.assumingMemoryBound(to: MPVEvent.self)
    }

    func errorString(_ code: Int32) -> String {
        errorStringFn(code).map { String(cString: $0) } ?? "error \(code)"
    }
}
