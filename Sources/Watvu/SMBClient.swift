import Foundation

/// Minimal SMB share browser built on the system `mount_smbfs` helper.
/// Avoids third-party dependencies (B27); mounts the share read-only into a
/// temporary directory and lists/downloads through the filesystem.
struct SMBClient {
    private let server: String
    private let share: String
    private let username: String
    private let password: String
    private var mountPoint: URL?

    init(server: String, share: String, username: String, password: String) {
        self.server = server
        self.share = share
        self.username = username
        self.password = password
    }

    mutating func connect() throws {
        if mountPoint != nil { return }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("uhf-smb-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = "//\(username):\(password)@\(server)/\(share)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount_smbfs")
        process.arguments = [url, dir.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SMBError.mountFailed
        }
        mountPoint = dir
    }

    private var root: URL {
        guard let mountPoint else { return URL(fileURLWithPath: "/") }
        return mountPoint
    }

    func contentsOfDirectory(atPath path: String) throws -> [SMBFile] {
        let dir = root.appendingPathComponent(path)
        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
        return entries.map { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            return SMBFile(
                name: url.lastPathComponent,
                path: path.isEmpty ? url.lastPathComponent : "\(path)/\(url.lastPathComponent)",
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0)
            )
        }
    }

    func downloadFile(atPath path: String, to destination: URL) throws {
        let source = root.appendingPathComponent(path)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    mutating func disconnect() {
        guard let mountPoint else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/umount")
        process.arguments = [mountPoint.path]
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: mountPoint)
        self.mountPoint = nil
    }
}

struct SMBFile {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
}

enum SMBError: Error {
    case notConnected
    case mountFailed
}
