import SwiftUI
import Network
import CoreImage
import CoreImage.CIFilterBuiltins

/// "Add from your phone": while on, the Mac serves a small page on the local
/// network. Scan the QR code, fill in an M3U link or Xtream login, and the
/// playlist is added here. No server or account needed.
///
/// Protection: a random 6-digit code (in the QR link) is required for every
/// request; 5 wrong codes switch it off. Traffic is plain HTTP on your own
/// network, so use it on a network you trust.
@MainActor
final class LinkServer: ObservableObject {
    static let shared = LinkServer()

    @Published private(set) var isRunning = false
    @Published private(set) var address: URL?
    @Published private(set) var code = ""
    @Published private(set) var lastEvent = ""

    private var listener: NWListener?
    private weak var model: AppModel?
    private var failedAttempts = 0
    private let queue = DispatchQueue(label: "Watvu.link-server")

    func start(model: AppModel) {
        guard !isRunning else { return }
        self.model = model
        code = String(format: "%06d", Int.random(in: 0...999_999))
        failedAttempts = 0
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            lastEvent = L("Couldn't start: ") + error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        address = nil
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue, let ip = Self.lanIPAddress() else {
                lastEvent = L("No local network connection.")
                stop()
                return
            }
            address = URL(string: "http://\(ip):\(port)/?code=\(code)")
            isRunning = true
            lastEvent = L("Waiting for your phone…")
        case .failed(let error):
            lastEvent = L("Stopped: ") + error.localizedDescription
            stop()
        default: break
        }
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(buffer) {
                Task { @MainActor in await self?.respond(to: request, on: connection) }
            } else if done || error != nil || buffer.count > 1_000_000 {
                connection.cancel()
            } else {
                Task { @MainActor in self?.receive(on: connection, buffer: buffer) }
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        let params = request.method == "POST" ? request.form : request.query
        guard params["code"] == code else {
            failedAttempts += 1
            if failedAttempts >= 5 {
                lastEvent = L("Switched off after 5 wrong codes.")
                send(LinkPages.message(L("Not allowed"), L("Too many wrong codes. Turn it on again on your Mac.")), status: 403, on: connection)
                stop()
            } else {
                send(LinkPages.message(L("Code needed"), L("Scan the QR code shown on your Mac.")), status: 403, on: connection)
            }
            return
        }
        switch (request.method, request.path) {
        case ("GET", "/"):
            lastEvent = L("Phone connected")
            send(LinkPages.form(code: code), on: connection)
        case ("POST", "/add"):
            let result = await addPlaylist(params)
            send(LinkPages.message(result.ok ? L("Added ✓") : L("Couldn't add"), result.text, back: !result.ok ? code : nil),
                 on: connection)
        default:
            send(LinkPages.message(L("Not found"), ""), status: 404, on: connection)
        }
    }

    private func addPlaylist(_ form: [String: String]) async -> (ok: Bool, text: String) {
        guard let model else { return (false, L("Watvu isn't ready.")) }
        let name = form["name"] ?? ""
        do {
            if form["type"] == "xtream" {
                let server = form["server"] ?? "", user = form["username"] ?? "", pass = form["password"] ?? ""
                guard !server.isEmpty, !user.isEmpty, !pass.isEmpty else { return (false, L("Fill in server, username and password.")) }
                lastEvent = L("Adding Xtream account…")
                try await model.addXtream(name: name, server: server, username: user, password: pass)
            } else {
                let url = form["url"] ?? ""
                guard !url.isEmpty else { return (false, L("Enter the playlist link.")) }
                lastEvent = L("Adding playlist…")
                try await model.addM3U(name: name, urlString: url, epgURL: form["epg"] ?? "")
            }
            let added = model.playlists.last?.name ?? name
            lastEvent = String(format: L("Added “%@” from your phone"), added)
            return (true, String(format: L("“%@” is on your Mac now."), added))
        } catch {
            lastEvent = L("Add failed: ") + error.localizedDescription
            return (false, error.localizedDescription)
        }
    }

    private nonisolated func send(_ html: String, status: Int = 200, on connection: NWConnection) {
        let body = Data(html.utf8)
        let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Forbidden")
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Helpers

    /// The Mac's IPv4 address on Wi-Fi/Ethernet (en*), private ranges only.
    static func lanIPAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidates: [(String, String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = entry.pointee
            guard let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (iface.ifa_flags & UInt32(IFF_UP)) != 0, (iface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host), name = String(cString: iface.ifa_name)
            if name.hasPrefix("en"), ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.range(of: #"^172\.(1[6-9]|2\d|3[01])\."#, options: .regularExpression) != nil {
                candidates.append((name, ip))
            }
        }
        return candidates.sorted { $0.0 < $1.0 }.first?.1
    }

    /// QR code for `text`, scaled up crisply.
    static func qrImage(for text: String, size: CGFloat = 220) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// QR code, address and code for the phone link (Settings and welcome screen).
struct LinkQRPanel: View {
    let address: URL
    let code: String

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            if let qr = LinkServer.qrImage(for: address.absoluteString) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 150, height: 150)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel(L("QR code for adding a playlist"))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Scan with your phone's camera"))
                    .font(.system(size: 14, weight: .semibold))
                Text(L("Or open this address on a phone on the same Wi-Fi:"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Text(address.absoluteString)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                Text(String(format: L("Code: %@"), code))
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                Text(L("Works only on your local network and only with this code, until you turn it off or close this."))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

/// Minimal HTTP/1.1 request parser (enough for a form page).
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let form: [String: String]

    /// Returns nil until the headers and the full body have arrived.
    init?(_ data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard parts.count >= 2 else { return nil }
        let length = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        method = parts[0]
        let target = URLComponents(string: parts[1])
        path = target?.path.isEmpty == false ? target!.path : "/"
        query = Self.pairs(target?.percentEncodedQuery ?? "")
        form = Self.pairs(String(data: body.prefix(length), encoding: .utf8) ?? "")
    }

    /// Decodes `a=1&b=x+y` (form-urlencoded).
    static func pairs(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = kv.first?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { continue }
            let value = kv.count > 1 ? (kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "") : ""
            result[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}

/// The phone-side pages: plain HTML/CSS, light and dark.
enum LinkPages {
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func page(_ body: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Watvu</title><style>
        :root{--bg:#f4f2ef;--card:#fff;--text:#1d1d1f;--muted:#6e6e73;--line:#e3e1dd;--accent:#ee5a24}
        @media (prefers-color-scheme:dark){:root{--bg:#141414;--card:#1f1f1f;--text:#f5f5f7;--muted:#9a9aa0;--line:#333}}
        *{box-sizing:border-box}body{margin:0;font:16px -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--text)}
        main{max-width:460px;margin:0 auto;padding:28px 16px}h1{font-size:26px;margin:0 0 4px}p{color:var(--muted);margin:0 0 20px}
        .card{background:var(--card);border-radius:18px;padding:18px;border:1px solid var(--line)}
        label{display:block;font-size:13px;font-weight:600;margin:14px 0 6px}
        input{width:100%;padding:12px;border-radius:12px;border:1px solid var(--line);background:var(--bg);color:var(--text);font-size:16px}
        .seg{display:flex;gap:6px;background:var(--bg);padding:4px;border-radius:12px}
        .seg label{flex:1;margin:0;text-align:center;padding:9px;border-radius:9px;cursor:pointer;font-size:14px}
        .seg input{display:none}.seg input:checked+span{color:#fff}.seg label:has(input:checked){background:var(--accent);color:#fff}
        button,.btn{display:block;width:100%;margin-top:20px;padding:14px;border:0;border-radius:14px;background:var(--accent);color:#fff;font-size:17px;font-weight:600;text-align:center;text-decoration:none}
        .xt{display:none}form:has(#t-x:checked) .xt{display:block}form:has(#t-x:checked) .m3u{display:none}
        </style></head><body><main>\(body)</main></body></html>
        """
    }

    static func form(code: String) -> String {
        page("""
        <h1>Add to Watvu</h1><p>The playlist is added on your Mac.</p>
        <form class="card" method="post" action="/add">
        <input type="hidden" name="code" value="\(escape(code))">
        <div class="seg"><label><input id="t-m" type="radio" name="type" value="m3u" checked><span>M3U link</span></label>
        <label><input id="t-x" type="radio" name="type" value="xtream"><span>Xtream login</span></label></div>
        <label>Name (optional)</label><input name="name" autocomplete="off">
        <div class="m3u"><label>Playlist link</label><input name="url" type="url" inputmode="url" autocapitalize="off" placeholder="https://…/playlist.m3u">
        <label>Guide (EPG) link, optional</label><input name="epg" type="url" inputmode="url" autocapitalize="off"></div>
        <div class="xt"><label>Server</label><input name="server" inputmode="url" autocapitalize="off" placeholder="http://example.com:8080">
        <label>Username</label><input name="username" autocapitalize="off" autocomplete="off">
        <label>Password</label><input name="password" type="password" autocomplete="off"></div>
        <button type="submit">Add playlist</button></form>
        """)
    }

    static func message(_ title: String, _ text: String, back code: String? = nil) -> String {
        let link = code.map { "<a class=\"btn\" href=\"/?code=\(escape($0))\">Try again</a>" } ?? ""
        return page("<h1>\(escape(title))</h1><p>\(escape(text))</p>\(link)")
    }
}
