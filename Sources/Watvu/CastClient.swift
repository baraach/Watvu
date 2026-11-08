import Foundation
import Network
import Combine

/// A Google Cast device found on the local network.
struct CastDevice: Identifiable, Hashable {
    let id: String          // Bonjour service name
    let name: String        // friendly name (TXT "fn")
    let model: String       // TXT "md"
    let endpoint: NWEndpoint
}

/// Finds Cast devices (`_googlecast._tcp`) with Bonjour. Needs the Local
/// Network permission (Info.plist: NSLocalNetworkUsageDescription and
/// NSBonjourServices).
final class CastBrowser: ObservableObject, @unchecked Sendable {
    static let shared = CastBrowser()

    @Published private(set) var devices: [CastDevice] = []
    @Published private(set) var error: String?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "Watvu.cast-browser")

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.publish { $0.error = L("Couldn't search the network: ") + error.localizedDescription }
            case .ready:
                self?.publish { $0.error = nil }
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap(Self.device(from:)).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self?.publish { $0.devices = found }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private static func device(from result: NWBrowser.Result) -> CastDevice? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var friendly = name, model = ""
        if case .bonjour(let txt) = result.metadata {
            friendly = txt["fn"] ?? name
            model = txt["md"] ?? ""
        }
        return CastDevice(id: name, name: friendly, model: model, endpoint: result.endpoint)
    }

    private func publish(_ change: @escaping (CastBrowser) -> Void) {
        DispatchQueue.main.async { [weak self] in if let self { change(self) } }
    }
}

/// One Cast session: connects to a device over TLS (port 8009), launches the
/// Default Media Receiver and plays a URL. The device fetches the stream
/// itself, so the URL must be reachable from the TV and can't carry custom
/// HTTP headers.
final class CastSession: ObservableObject, @unchecked Sendable {
    enum State: Equatable {
        case connecting, launching, loading, playing, paused, buffering, idle
        case failed(String)
    }

    let device: CastDevice
    @Published private(set) var state: State = .connecting
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    var onEnded: (() -> Void)?

    private static let defaultMediaReceiver = "CC1AD845"
    private static let sender = "sender-0"
    private let queue = DispatchQueue(label: "Watvu.cast-session")
    private var connection: NWConnection?
    private var buffer = Data()
    private var requestID = 1
    private var transportID: String?
    private var mediaSessionID: Int?
    private var pendingLoad: [String: Any]?
    private var heartbeat: DispatchSourceTimer?
    private var statusPoll: DispatchSourceTimer?
    private var stopped = false

    init(device: CastDevice) {
        self.device = device
    }

    deinit { disconnect() }

    // MARK: Public

    /// Connects, launches the media receiver and loads the stream.
    func cast(url: URL, title: String, imageURL: URL?, isLive: Bool, startAt: Double) {
        var metadata: [String: Any] = ["metadataType": 0, "title": title]
        if let imageURL { metadata["images"] = [["url": imageURL.absoluteString]] }
        var load: [String: Any] = [
            "type": "LOAD",
            "autoplay": true,
            "media": [
                "contentId": url.absoluteString,
                "contentType": CastContentType.forURL(url),
                "streamType": isLive ? "LIVE" : "BUFFERED",
                "metadata": metadata,
            ] as [String: Any],
        ]
        if !isLive, startAt > 5 { load["currentTime"] = startAt }
        queue.async { [self] in
            pendingLoad = load
            connect()
        }
    }

    func play() { mediaCommand(["type": "PLAY"]) }
    func pause() { mediaCommand(["type": "PAUSE"]) }
    func seek(to seconds: Double) {
        publish { $0.currentTime = seconds }
        mediaCommand(["type": "SEEK", "currentTime": seconds])
    }

    func setVolume(_ level: Float) {
        queue.async { [self] in
            send(namespace: CastMessage.Namespace.receiver, to: "receiver-0",
                 ["type": "SET_VOLUME", "volume": ["level": Double(min(max(level, 0), 1))]])
        }
    }

    /// Stops playback on the TV and closes the connection.
    func stop() {
        queue.async { [self] in
            if let mediaSessionID, let transportID {
                send(namespace: CastMessage.Namespace.media, to: transportID,
                     ["type": "STOP", "mediaSessionId": mediaSessionID])
            }
            queue.asyncAfter(deadline: .now() + 0.3) { [self] in disconnect() }
        }
    }

    // MARK: Connection

    private func connect() {
        let tls = NWProtocolTLS.Options()
        // Cast devices use self-signed certificates.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 8
        let connection = NWConnection(to: device.endpoint, using: NWParameters(tls: tls, tcp: tcp))
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.didConnect()
            case .failed(let error), .waiting(let error):
                self.fail(L("Couldn't connect to ") + self.device.name + " (\(error.localizedDescription))")
            default: break
            }
        }
        self.connection = connection
        publish { $0.state = .connecting }
        connection.start(queue: queue)
        receiveFrame()
    }

    private func didConnect() {
        send(namespace: CastMessage.Namespace.connection, to: "receiver-0", ["type": "CONNECT"])
        startHeartbeat()
        publish { $0.state = .launching }
        send(namespace: CastMessage.Namespace.receiver, to: "receiver-0",
             ["type": "LAUNCH", "appId": Self.defaultMediaReceiver])
    }

    private func disconnect() {
        stopped = true
        heartbeat?.cancel(); heartbeat = nil
        statusPoll?.cancel(); statusPoll = nil
        if let transportID {
            send(namespace: CastMessage.Namespace.connection, to: transportID, ["type": "CLOSE"])
        }
        connection?.cancel()
        connection = nil
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        Logger.shared.log("error", "cast: \(message)")
        disconnect()
        publish { $0.state = .failed(message) }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.send(namespace: CastMessage.Namespace.heartbeat, to: "receiver-0", ["type": "PING"])
        }
        timer.resume()
        heartbeat = timer
    }

    /// The TV only reports status when something changes, so ask once a
    /// second while a stream is loaded to keep the position current.
    private func startStatusPolling() {
        guard statusPoll == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let transportID = self.transportID else { return }
            self.send(namespace: CastMessage.Namespace.media, to: transportID, ["type": "GET_STATUS"])
        }
        timer.resume()
        statusPoll = timer
    }

    // MARK: Sending

    private func mediaCommand(_ payload: [String: Any]) {
        queue.async { [self] in
            guard let transportID, let mediaSessionID else { return }
            var body = payload
            body["mediaSessionId"] = mediaSessionID
            send(namespace: CastMessage.Namespace.media, to: transportID, body)
        }
    }

    private func send(namespace: String, to destination: String, _ payload: [String: Any]) {
        guard let connection else { return }
        var body = payload
        if namespace != CastMessage.Namespace.heartbeat && namespace != CastMessage.Namespace.connection {
            body["requestId"] = requestID
            requestID += 1
        }
        guard let json = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: json, encoding: .utf8) else { return }
        let message = CastMessage(source: Self.sender, destination: destination, namespace: namespace, payload: text)
        connection.send(content: message.framed(), completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(error.localizedDescription) }
        })
    }

    // MARK: Receiving

    private func receiveFrame() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data); self.drainBuffer() }
            if let error { self.fail(error.localizedDescription); return }
            if isComplete { self.fail(L("The TV closed the connection.")); return }
            if !self.stopped { self.receiveFrame() }
        }
    }

    private func drainBuffer() {
        while let length = CastMessage.frameLength(buffer), buffer.count >= 4 + length {
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + length)
            if let message = CastMessage.decode(body) { handle(message) }
        }
    }

    private func handle(_ message: CastMessage) {
        guard let data = message.payload.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch (message.namespace, type) {
        case (CastMessage.Namespace.heartbeat, "PING"):
            send(namespace: CastMessage.Namespace.heartbeat, to: message.source, ["type": "PONG"])
        case (CastMessage.Namespace.receiver, "RECEIVER_STATUS"):
            handleReceiverStatus(json)
        case (CastMessage.Namespace.receiver, "LAUNCH_ERROR"):
            fail(L("The TV couldn't start the media player."))
        case (CastMessage.Namespace.media, "MEDIA_STATUS"):
            handleMediaStatus(json)
        case (CastMessage.Namespace.media, "LOAD_FAILED"), (CastMessage.Namespace.media, "LOAD_CANCELLED"):
            fail(L("The TV couldn't play this stream. It may need headers or a format the TV doesn't support."))
        case (CastMessage.Namespace.connection, "CLOSE"):
            if message.source == transportID { fail(L("Casting ended on the TV.")) }
        default:
            break
        }
    }

    private func handleReceiverStatus(_ json: [String: Any]) {
        guard let status = json["status"] as? [String: Any] else { return }
        let apps = status["applications"] as? [[String: Any]] ?? []
        guard let app = apps.first(where: { ($0["appId"] as? String) == Self.defaultMediaReceiver }),
              let transport = app["transportId"] as? String else { return }
        guard transportID != transport else { return }
        transportID = transport
        send(namespace: CastMessage.Namespace.connection, to: transport, ["type": "CONNECT"])
        if let load = pendingLoad {
            pendingLoad = nil
            publish { $0.state = .loading }
            send(namespace: CastMessage.Namespace.media, to: transport, load)
        }
        startStatusPolling()
    }

    private func handleMediaStatus(_ json: [String: Any]) {
        guard let status = (json["status"] as? [[String: Any]])?.first else { return }
        if let id = status["mediaSessionId"] as? Int { mediaSessionID = id }
        let time = status["currentTime"] as? Double
        let length = (status["media"] as? [String: Any])?["duration"] as? Double
        let playerState = status["playerState"] as? String ?? ""
        let idleReason = status["idleReason"] as? String
        publish { session in
            if let time { session.currentTime = time }
            if let length, length.isFinite, length > 0 { session.duration = length }
            switch playerState {
            case "PLAYING": session.state = .playing
            case "PAUSED": session.state = .paused
            case "BUFFERING", "LOADING": session.state = .buffering
            case "IDLE":
                if idleReason == "FINISHED" { session.state = .idle; session.onEnded?() }
                else if idleReason == "ERROR" { session.state = .failed(L("The TV couldn't play this stream.")) }
                else if session.state != .loading { session.state = .idle }
            default: break
            }
        }
    }

    private func publish(_ change: @escaping (CastSession) -> Void) {
        DispatchQueue.main.async { [weak self] in if let self { change(self) } }
    }
}
