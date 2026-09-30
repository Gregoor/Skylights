import Foundation
import OSLog

final class DiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private let osLogger = Logger(subsystem: "com.tinycast.tmdbspotlight", category: "indexing")
    private let fileURL: URL
    private var lines: [String] = []

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = dir.appendingPathComponent("tmdb-spotlight.log")
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = Array(existing.split(separator: "\n").suffix(250)).map(String.init)
        }
        write("INFO", "Logger ready. Device log: \(fileURL.path)")
    }

    var tail: String { lock.lock(); defer { lock.unlock() }; return lines.suffix(80).joined(separator: "\n") }

    func write(_ level: String, _ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > 250 { lines.removeFirst(lines.count - 250) }
        try? (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        lock.unlock()
        osLogger.log("\(line, privacy: .public)")
    }
}
