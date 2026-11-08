import Foundation
import AppKit
import Combine

/// Syncs the library (playlists, favorites, lists, positions, watched,
/// customisation) between Macs through a file in iCloud Drive. CloudKit would
/// need a paid developer account; iCloud Drive doesn't.
///
/// Each sync merges the file into this Mac (union, newest position wins) and
/// writes the merged result back, so Macs converge. Passwords never leave the
/// Keychain: on another Mac, enter a playlist's password once. Deletions don't
/// sync (a merge can't tell "deleted here" from "not added yet").
@MainActor
final class ICloudDriveSync: ObservableObject {
    static let shared = ICloudDriveSync()
    static let enabledKey = "iCloudDriveSync"

    @Published private(set) var status: String = ""
    @Published private(set) var isSyncing = false

    private weak var model: AppModel?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let lastImportKey = "iCloudDriveSync.lastImported"

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Watvu", isDirectory: true)
    }
    static var file: URL { folder.appendingPathComponent("library-sync.json") }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path)
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// Called once at launch: syncs now and then every 5 minutes and whenever
    /// the app goes to the background.
    func start(model: AppModel) {
        self.model = model
        guard isEnabled else { return }
        sync()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in ICloudDriveSync.shared.sync() }
        }
        if observers.isEmpty {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in ICloudDriveSync.shared.sync() }
            })
        }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled, let model { start(model: model) } else {
            timer?.invalidate(); timer = nil
            status = L("Off")
        }
    }

    func sync() {
        guard isEnabled, let model, !isSyncing else { return }
        guard Self.isAvailable else { status = L("iCloud Drive isn't turned on for this Mac."); return }
        isSyncing = true
        defer { isSyncing = false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            // A file evicted to the cloud shows up as ".library-sync.json.icloud".
            let placeholder = Self.folder.appendingPathComponent(".library-sync.json.icloud")
            if fm.fileExists(atPath: placeholder.path) {
                try? fm.startDownloadingUbiquitousItem(at: Self.file)
                status = L("Downloading from iCloud…")
                return
            }
            if fm.fileExists(atPath: Self.file.path) {
                let modified = (try? fm.attributesOfItem(atPath: Self.file.path)[.modificationDate] as? Date) ?? .distantPast
                let lastImported = UserDefaults.standard.object(forKey: lastImportKey) as? Date ?? .distantPast
                if modified > lastImported {
                    try model.importBackup(from: Self.file, merging: true)
                }
            }
            try model.exportBackup(to: Self.file)
            let written = (try? fm.attributesOfItem(atPath: Self.file.path)[.modificationDate] as? Date) ?? Date()
            UserDefaults.standard.set(written, forKey: lastImportKey)
            status = String(format: L("Synced %@"), Date().formatted(date: .omitted, time: .shortened))
        } catch {
            status = L("Sync failed: ") + error.localizedDescription
            Logger.shared.log("sync", "iCloud Drive sync failed: \(error.localizedDescription)")
        }
    }
}
