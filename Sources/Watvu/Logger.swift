import Foundation

/// Tiny in-memory ring-buffer logger for the debug viewer (Settings → About).
final class Logger {
    static let shared = Logger()
    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let level: String
        let message: String
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity = 500

    private init() {}

    func log(_ level: String, _ message: String) {
        lock.lock()
        entries.append(Entry(level: level, message: message))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        lock.unlock()
    }

    var all: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    var text: String {
        all.map { "\($0.date.formatted(date: .omitted, time: .standard)) [\($0.level)] \($0.message)" }.joined(separator: "\n")
    }
}
