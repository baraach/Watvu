import Foundation
import Combine
import AVFoundation

/// Simple, correct download manager: queued downloads with progress, pause,
/// resume, cancel and delete. State mutations happen on the main actor (B28)
/// and files live in Application Support (B12).
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var downloads: [Download] = []

    /// Resolves a MediaItem to a stream URL. Set by the app at launch.
    var streamURLResolver: ((MediaItem) async throws -> URL)?

    private var tasks: [UUID: URLSessionTask] = [:]
    var resumeData: [UUID: Data] = [:]
    private var session: URLSession!
    private var assetSession: AVAssetDownloadURLSession!
    private let maxConcurrent = 2

    nonisolated private var storageDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Watvu/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: Delegate.shared, delegateQueue: OperationQueue.main)   // B40
        let assetConfig = URLSessionConfiguration.background(withIdentifier: "com.watvu.hls")
        assetSession = AVAssetDownloadURLSession(configuration: assetConfig, assetDownloadDelegate: AssetDelegate.shared, delegateQueue: OperationQueue.main)   // B40
        load()
    }

    func startDownload(_ item: MediaItem, playlist: Playlist) {
        guard !downloads.contains(where: { $0.item.id == item.id && $0.status == .downloading || $0.status == .queued }) else { return }
        let download = Download(id: UUID(), item: item, playlist: playlist, status: .queued, progress: 0)
        downloads.append(download)
        save()
        pump()
    }

    func pauseDownload(_ id: UUID) {
        // B9: keep the resume data so resume continues where it stopped.
        if let task = tasks[id] as? URLSessionDownloadTask {
            task.cancel { data in Task { @MainActor in if let data { DownloadManager.shared.resumeData[id] = data } } }
        } else {
            tasks[id]?.cancel()
        }
        tasks[id] = nil
        update(id) { $0.status = .paused }
    }

    func resumeDownload(_ id: UUID) {
        update(id) { $0.status = .queued }
        pump()
    }

    func cancelDownload(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        update(id) { $0.status = .cancelled }
    }

    func deleteDownload(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        if let index = downloads.firstIndex(where: { $0.id == id }) {
            if let local = downloads[index].localURL { try? FileManager.default.removeItem(at: local) }
            downloads.remove(at: index)
            save()
        }
    }

    func clearCompleted() {
        for d in downloads where d.status == .completed {
            if let local = d.localURL { try? FileManager.default.removeItem(at: local) }
        }
        downloads.removeAll { $0.status == .completed || $0.status == .cancelled || $0.status == .failed }
        save()
    }

    private func pump() {
        let active = downloads.filter { $0.status == .downloading }.count
        guard active < maxConcurrent,
              let next = downloads.first(where: { $0.status == .queued }) else { return }
        update(next.id) { $0.status = .downloading }
        Task {
            do {
                guard let resolve = streamURLResolver else { throw AppError.invalidURL }
                let url = try await resolve(next.item)
                let id = next.id
                if url.absoluteString.contains(".m3u8") {
                    // B8: HLS — download the whole asset via AVAssetDownloadURLSession.
                    let asset = AVURLAsset(url: url)
                    if let task = assetSession.makeAssetDownloadTask(asset: asset, assetTitle: next.item.name, assetArtworkData: nil, options: nil) {
                        task.taskDescription = id.uuidString
                        tasks[id] = task
                        task.resume()
                    }
                } else if let data = resumeData[id] {
                    let task = session.downloadTask(withResumeData: data)
                    task.taskDescription = id.uuidString
                    resumeData[id] = nil
                    tasks[id] = task
                    task.resume()
                } else {
                    let task = session.downloadTask(with: url)
                    task.taskDescription = id.uuidString
                    tasks[id] = task
                    task.resume()
                }
            } catch {
                update(next.id) { $0.status = .failed; $0.error = error.localizedDescription }
                pump()
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Download) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        change(&downloads[index])
        save()
    }

    // Called by the URLSession delegate (background); hop to main actor.
    nonisolated func didProgress(_ id: UUID, _ fraction: Double) {
        Task { @MainActor in
            self.update(id) { $0.progress = fraction }
        }
    }

    nonisolated func moveToStorage(id: UUID, from location: URL) -> URL {
        let dest = storageDir.appendingPathComponent("\(id.uuidString).mp4")
        try? FileManager.default.removeItem(at: dest)
        if (try? FileManager.default.moveItem(at: location, to: dest)) != nil { return dest }
        return location
    }

    nonisolated func didFinish(_ id: UUID, location: URL?, error: Error?) {
        Task { @MainActor in
            self.tasks[id] = nil
            guard let index = self.downloads.firstIndex(where: { $0.id == id }) else { return }
            if let error {
                self.downloads[index].status = .failed
                self.downloads[index].error = error.localizedDescription
            } else if let location {
                self.downloads[index].status = .completed
                self.downloads[index].progress = 1
                self.downloads[index].localURL = location
            }
            self.save()
            self.pump()
        }
    }

    private func save() {
        let url = storageDir.appendingPathComponent("downloads.json")
        try? JSONEncoder().encode(downloads).write(to: url)
    }

    private func load() {
        let url = storageDir.appendingPathComponent("downloads.json")
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Download].self, from: data) {
            downloads = list
        }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate {
        static let shared = Delegate()
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard let id = taskID(for: downloadTask), totalBytesExpectedToWrite > 0 else { return }
            MainActor.assumeIsolated {   // B40: delegate queue is the main queue
                DownloadManager.shared.didProgress(id, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let id = taskID(for: downloadTask) else { return }
            MainActor.assumeIsolated {
                let dest = DownloadManager.shared.moveToStorage(id: id, from: location)
                DownloadManager.shared.didFinish(id, location: dest, error: nil)
            }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let id = taskID(for: task as? URLSessionDownloadTask) else { return }
            MainActor.assumeIsolated {
                DownloadManager.shared.didFinish(id, location: nil, error: error)
            }
        }
        private func taskID(for task: URLSessionTask?) -> UUID? {
            guard let task else { return nil }
            return UUID(uuidString: task.taskDescription ?? "")
        }
    }
}

struct Download: Codable, Identifiable {
    let id: UUID
    let item: MediaItem
    let playlist: Playlist
    var status: DownloadStatus
    var progress: Double
    var localURL: URL?
    var error: String?
}

enum DownloadStatus: String, Codable {
    case queued, downloading, paused, completed, failed, cancelled
}

/// Delegate for HLS asset downloads (B8).
private final class AssetDelegate: NSObject, AVAssetDownloadDelegate {
    static let shared = AssetDelegate()
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = UUID(uuidString: assetDownloadTask.taskDescription ?? "") else { return }
        MainActor.assumeIsolated {
            DownloadManager.shared.didFinish(id, location: DownloadManager.shared.moveToStorage(id: id, from: location), error: nil)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = UUID(uuidString: task.taskDescription ?? "") else { return }
        if error == nil { return }
        MainActor.assumeIsolated {
            DownloadManager.shared.didFinish(id, location: nil, error: error)
        }
    }
}
