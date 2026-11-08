import Foundation
import Combine
import UserNotifications

/// Simple recording manager: schedules a programme, starts capturing the
/// channel stream at the programme start (B4) and writes it to a file (B3).
/// All @Published mutations happen on the main actor (B28).
@MainActor
final class RecordingManager: ObservableObject {
    static let shared = RecordingManager()

    @Published var recordings: [Recording] = []
    @Published var scheduled: [ScheduledRecording] = []

    var streamURLResolver: ((MediaItem) async throws -> URL)?

    private var timers: [UUID: DispatchSourceTimer] = [:]
    private var session: URLSession!
    var hlsRecorders: [UUID: HLSRecorder] = [:]

    nonisolated var storageDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Watvu/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        session = URLSession(configuration: .default, delegate: StreamDelegate.shared, delegateQueue: OperationQueue.main)   // B40
        load()
    }

    func scheduleRecording(_ program: EPGProgram, channel: MediaItem) {
        let item = ScheduledRecording(id: UUID(), program: program, channel: channel, status: .scheduled)
        scheduled.append(item)
        saveScheduled()
        armTimer(for: item)
        scheduleNotification(for: item)
    }

    func cancelRecording(_ id: UUID) {
        timers[id]?.cancel()
        timers[id] = nil
        if let writer = StreamWriter.registry[id] { writer.task?.cancel() }
        hlsRecorders[id]?.stop()
        hlsRecorders[id] = nil
        if let index = scheduled.firstIndex(where: { $0.id == id }) {
            scheduled[index].status = .cancelled
            saveScheduled()
        }
        if let rIndex = recordings.firstIndex(where: { $0.id == id }) {
            recordings[rIndex].status = .cancelled
            save()
        }
    }

    func deleteRecording(_ id: UUID) {
        if let index = recordings.firstIndex(where: { $0.id == id }) {
            if let local = recordings[index].localURL { try? FileManager.default.removeItem(at: local) }
            recordings.remove(at: index)
            save()
        }
    }

    func clearCompleted() {
        for r in recordings where r.status == .completed {
            if let local = r.localURL { try? FileManager.default.removeItem(at: local) }
        }
        recordings.removeAll { $0.status == .completed || $0.status == .cancelled || $0.status == .failed }
        save()
    }

    private func armTimer(for item: ScheduledRecording) {
        let start = item.program.start
        let delay = max(0, start.timeIntervalSinceNow)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in self?.startRecording(item) }
        timer.resume()
        timers[item.id] = timer
    }

    private func startRecording(_ item: ScheduledRecording) {
        timers[item.id]?.cancel()
        timers[item.id] = nil
        guard let resolve = streamURLResolver else { return }
        let recording = Recording(id: item.id, program: item.program, channel: item.channel, status: .recording, progress: 0)
        recordings.append(recording)
        save()
        Task {
            do {
                let url = try await resolve(item.channel)
                let id = item.id
                if url.absoluteString.contains(".m3u8") {
                    // B41: live HLS — poll the media playlist and append new segments.
                    let rec = HLSRecorder(id: id, playlistURL: url, title: item.program.title, headers: item.channel.httpHeaders ?? [:])
                    hlsRecorders[id] = rec
                    rec.start(stopAt: item.program.end)
                } else {
                    // B3: stream the bytes to a file so stopping keeps what was captured.
                    let dest = storageDir.appendingPathComponent("\(id.uuidString).ts")
                    FileManager.default.createFile(atPath: dest.path, contents: nil)   // B39
                    let handle = try FileHandle(forWritingTo: dest)
                    let writer = StreamWriter(id: id, handle: handle)
                    let task = session.dataTask(with: url)
                    task.taskDescription = id.uuidString
                    writer.task = task
                    StreamWriter.registry[id] = writer
                    task.resume()
                }
                // stop at programme end
                let duration = max(1, item.program.end.timeIntervalSinceNow)
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    Task { @MainActor in RecordingManager.shared.stopRecording(id) }
                }
            } catch {
                if let index = recordings.firstIndex(where: { $0.id == item.id }) {
                    recordings[index].status = .failed
                    recordings[index].error = error.localizedDescription
                    save()
                }
            }
        }
    }

    private func stopRecording(_ id: UUID) {
        if let writer = StreamWriter.registry[id] {
            writer.task?.cancel()
            writer.finish()
        }
    }

    nonisolated func didFinish(_ id: UUID, error: Error?) {
        Task { @MainActor in
            guard let index = self.recordings.firstIndex(where: { $0.id == id }) else { return }
            if let error, (error as NSError).code != NSURLErrorCancelled {
                self.recordings[index].status = .failed
                self.recordings[index].error = error.localizedDescription
            }
            self.save()
        }
    }

    private func scheduleNotification(for item: ScheduledRecording) {
        let content = UNMutableNotificationContent()
        content.title = L("Recording Started")
        content.body = String(format: L("Recording %@ on %@"), item.program.title, item.channel.name)
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, item.program.start.timeIntervalSinceNow), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: trigger))
    }

    func save() {
        try? JSONEncoder().encode(recordings).write(to: storageDir.appendingPathComponent("recordings.json"))
    }

    func saveScheduled() {
        try? JSONEncoder().encode(scheduled).write(to: storageDir.appendingPathComponent("scheduled.json"))
    }

    private func load() {
        if let data = try? Data(contentsOf: storageDir.appendingPathComponent("recordings.json")),
           let list = try? JSONDecoder().decode([Recording].self, from: data) { recordings = list }
        if let data = try? Data(contentsOf: storageDir.appendingPathComponent("scheduled.json")),
           let list = try? JSONDecoder().decode([ScheduledRecording].self, from: data) {
            scheduled = list.filter { $0.status == .scheduled }
        }
    }
}

struct Recording: Codable, Identifiable {
    let id: UUID
    let program: EPGProgram
    let channel: MediaItem
    var status: RecordingStatus
    var progress: Double
    var localURL: URL?
    var error: String?
}

struct ScheduledRecording: Codable, Identifiable {
    let id: UUID
    let program: EPGProgram
    let channel: MediaItem
    var status: ScheduledRecordingStatus
}

enum RecordingStatus: String, Codable {
    case recording, completed, failed, cancelled
}

enum ScheduledRecordingStatus: String, Codable {
    case scheduled, recording, completed, failed, cancelled
}

/// Streams a recording's bytes to a file handle (B3).
private final class StreamWriter: NSObject, URLSessionDataDelegate {
    static var registry: [UUID: StreamWriter] = [:]
    let id: UUID
    private let handle: FileHandle
    var task: URLSessionDataTask?
    private var received = 0

    init(id: UUID, handle: FileHandle) {
        self.id = id
        self.handle = handle
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        try? handle.write(contentsOf: data)
        received += data.count
        if received % (5 * 1024 * 1024) < data.count {
            Task { @MainActor in
                if let i = RecordingManager.shared.recordings.firstIndex(where: { $0.id == self.id }) {
                    RecordingManager.shared.recordings[i].progress = min(1, Double(self.received) / 50_000_000)
                }
            }
        }
    }

    func finish() {
        try? handle.close()
        MainActor.assumeIsolated {
            let part = RecordingManager.shared.storageDir.appendingPathComponent("\(id.uuidString).ts")   // B44: MPEG-TS extension
            let dest = RecordingManager.shared.storageDir.appendingPathComponent("\(id.uuidString).ts")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: part, to: dest)
            if let i = RecordingManager.shared.recordings.firstIndex(where: { $0.id == self.id }) {
                RecordingManager.shared.recordings[i].status = .completed
                RecordingManager.shared.recordings[i].progress = 1
                RecordingManager.shared.recordings[i].localURL = dest
            }
            RecordingManager.shared.save()
            StreamWriter.registry[id] = nil
        }
    }
}

private final class StreamDelegate: NSObject, URLSessionDataDelegate {
    static let shared = StreamDelegate()
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let id = UUID(uuidString: dataTask.taskDescription ?? "") else { return }
        MainActor.assumeIsolated {   // B40
            StreamWriter.registry[id]?.urlSession(session, dataTask: dataTask, didReceive: data)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = UUID(uuidString: task.taskDescription ?? "") else { return }
        MainActor.assumeIsolated {
            if let error, (error as NSError).code != NSURLErrorCancelled {
                RecordingManager.shared.didFinish(id, error: error)
            } else if let writer = StreamWriter.registry[id] {
                writer.finish()
            }
        }
    }
}

/// Captures a live HLS stream by polling its media playlist and appending new
/// segments to a single `.ts` file (B41).
final class HLSRecorder {
    let id: UUID
    private var playlistURL: URL
    private let title: String
    private var seen = Set<String>()
    private var task: Task<Void, Never>?
    private var stopAt: Date?
    private var dest: URL?
    private var resolved = false
    private var polledOnce = false
    private var playlistURLOverride: URL?

    private var headers: [String: String]

    init(id: UUID, playlistURL: URL, title: String, headers: [String: String] = [:]) {
        self.id = id
        self.playlistURL = playlistURL
        self.title = title
        self.headers = headers
    }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        headers.forEach { r.setValue($0.value, forHTTPHeaderField: $0.key) }   // B53: channel headers
        return r
    }

    /// B53: master playlists list variant playlists — resolve to one variant.
    private func resolveMediaPlaylist(_ url: URL) async throws -> URL {
        let (data, _) = try await URLSession.shared.data(for: request(url))
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        if let i = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }), i + 1 < lines.count,
           let variant = URL(string: lines[i + 1], relativeTo: url)?.absoluteURL {
            return variant
        }
        return url
    }

    func start(stopAt: Date) {
        self.stopAt = stopAt
        task = Task { await run() }
    }

    func stop() {
        task?.cancel()
        finish()
    }

    private func run() async {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Watvu/Recordings", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(id.uuidString).ts")
        self.dest = dest
        fm.createFile(atPath: dest.path, contents: nil)

        while !Task.isCancelled {
            if let stopAt, Date() >= stopAt { break }
            do {
                // B53: resolve master → variant once at the start.
                if !resolved {
                    playlistURLOverride = try await resolveMediaPlaylist(playlistURL)
                    resolved = true
                }
                let base = playlistURLOverride ?? playlistURL
                let (data, _) = try await URLSession.shared.data(for: request(base))
                guard let text = String(data: data, encoding: .utf8) else { break }
                let target = Self.targetDuration(text) ?? 4
                let segments = Self.segmentURLs(text, base: base)
                var fresh = segments.filter { !seen.contains($0.absoluteString) }
                // B61: first poll of a live window — keep only the newest 2 segments.
                if !polledOnce && fresh.count > 2 { fresh = Array(fresh.suffix(2)) }
                // B61: fMP4 init segment (#EXT-X-MAP) must be written first.
                if !polledOnce, let mapURI = Self.mapURI(text, base: base) {
                    let (mapData, _) = try await URLSession.shared.data(for: request(mapURI))
                    let handle0 = try FileHandle(forWritingTo: dest)
                    try handle0.write(contentsOf: mapData)
                    try handle0.close()
                }
                polledOnce = true
                if !fresh.isEmpty {
                    let handle = try FileHandle(forWritingTo: dest)
                    handle.seekToEndOfFile()
                    for seg in fresh {
                        seen.insert(seg.absoluteString)
                        let (segData, _) = try await URLSession.shared.data(for: request(seg))
                        try handle.write(contentsOf: segData)
                    }
                    try handle.close()
                    if text.contains("#EXT-X-ENDLIST") { break } // VOD complete
                }
                try await Task.sleep(for: .seconds(Double(max(1, target))))
            } catch {
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        finish()
    }

    private func finish() {
        task?.cancel()
        Task { @MainActor in
            let mgr = RecordingManager.shared
            mgr.hlsRecorders[id] = nil
            if let dest, let i = mgr.recordings.firstIndex(where: { $0.id == self.id }) {
                mgr.recordings[i].status = .completed
                mgr.recordings[i].progress = 1
                mgr.recordings[i].localURL = dest
                mgr.save()
            }
        }
    }

    private static func mapURI(_ playlist: String, base: URL) -> URL? {
        for line in playlist.split(separator: "\n") where line.contains("#EXT-X-MAP:") {
            if let range = line.range(of: "URI=\"") ,
               let end = line[range.upperBound...].firstIndex(of: "\"") {
                return URL(string: String(line[range.upperBound..<end]), relativeTo: base)?.absoluteURL
            }
        }
        return nil
    }

    private static func targetDuration(_ playlist: String) -> Int? {
        for line in playlist.split(separator: "\n") where line.hasPrefix("#EXT-X-TARGETDURATION:") {
            return Int(line.dropFirst("#EXT-X-TARGETDURATION:".count))
        }
        return nil
    }

    private static func segmentURLs(_ playlist: String, base: URL) -> [URL] {
        playlist.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), !t.isEmpty else { return nil }
            return URL(string: t, relativeTo: base)?.absoluteURL
        }
    }
}
