import Combine
import Foundation

@MainActor
final class PopfeedLiveSync: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var message = "Popfeed live sync is stopped."
    @Published private(set) var recordCount = 0
    @Published private(set) var lastCursor: Int64

    private let logger: DiagnosticLog
    private let store = PopfeedRecordStore()
    private let credentials = JetstreamCredentialStore()
    private lazy var archiveReplay = PopfeedArchiveReplay(logger: logger)
    private let defaults = UserDefaults.standard
    private var worker: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?

    init(logger: DiagnosticLog) {
        self.logger = logger
        lastCursor = 0
        Task { [weak self] in
            guard let self else { return }
            recordCount = await store.count
        }
    }

    func start(did rawDID: String) {
        let did = rawDID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard did.hasPrefix("did:") else {
            message = "Enter a valid account DID first."
            return
        }
        guard !isRunning else { return }
        lastCursor = Int64(defaults.string(forKey: cursorKey(for: did)) ?? "") ?? 0
        isRunning = true
        message = "Connecting to Jetstream…"
        worker = Task { [weak self] in
            await self?.run(did: did)
        }
    }

    func stop() {
        worker?.cancel()
        worker = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isRunning = false
        message = "Popfeed live sync is stopped."
        logger.write("INFO", "Popfeed Jetstream live sync stopped")
    }

    func restart(did: String) {
        if isRunning { stop() }
        start(did: did)
    }

    private func run(did: String) async {
        var retryDelay: UInt64 = 1
        var terminalMessage: String?
        logger.write("INFO", "Popfeed Jetstream sync starting; filter=social.popfeed.*, cursor=\(lastCursor)")
        let apiKey = credentials.read()?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let apiKey, !apiKey.isEmpty {
            do {
                try await replayArchive(did: did, apiKey: apiKey)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                message = "Archive catch-up failed: \(error.localizedDescription)"
                logger.write("ERROR", "Popfeed archive catch-up failed; cursor=\(lastCursor), error=\(String(reflecting: error))")
                // Keep live delivery available when archive access fails. The saved
                // cursor remains unchanged, so the next foreground attempt retries.
            }
        } else {
            message = lastCursor == 0
                ? "No Jetstream API key saved; listening for new Popfeed updates only."
                : "No Jetstream API key saved; reconnecting from the last live cursor."
            logger.write("WARN", "Popfeed archive catch-up skipped; API key is not saved; cursor=\(lastCursor)")
        }
        while !Task.isCancelled {
            var attemptedTask: URLSessionWebSocketTask?
            do {
                var components = URLComponents()
                components.scheme = "wss"
                components.host = "jetstream.us-east.bsky.network"
                components.path = "/xrpc/network.bsky.jetstream.subscribeEvents"
                var query = [
                    URLQueryItem(name: "dids", value: did),
                    URLQueryItem(name: "collections", value: "social.popfeed.*")
                ]
                if lastCursor > 0 { query.append(URLQueryItem(name: "cursor", value: String(lastCursor))) }
                components.queryItems = query
                guard let url = components.url else { throw SyncError.invalidEndpoint }

                let task = URLSession.shared.webSocketTask(with: url, protocols: ["xrpc.v1.json"])
                attemptedTask = task
                socket = task
                task.resume()
                message = apiKey?.isEmpty == false ? "Listening for Popfeed updates…" : message
                logger.write("INFO", "Popfeed Jetstream WebSocket connected; resumeCursor=\(lastCursor)")

                while !Task.isCancelled {
                    let incoming = try await task.receive()
                    let data: Data
                    switch incoming {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    try await consume(data)
                    retryDelay = 1
                }
            } catch is CancellationError {
                break
            } catch {
                guard !Task.isCancelled else { break }
                if let response = attemptedTask?.response as? HTTPURLResponse,
                   response.statusCode == 400, lastCursor > 0 {
                    if let apiKey, !apiKey.isEmpty {
                        logger.write("WARN", "Popfeed Jetstream rejected live cursor; attempting archive replay; cursor=\(lastCursor)")
                        do {
                            try await replayArchive(did: did, apiKey: apiKey)
                            retryDelay = 1
                            continue
                        } catch {
                            terminalMessage = "Archive catch-up failed: \(error.localizedDescription)"
                            message = terminalMessage ?? "Archive catch-up failed."
                            logger.write("ERROR", "Popfeed stale-cursor archive replay failed; error=\(String(reflecting: error))")
                            break
                        }
                    } else {
                        terminalMessage = "Saved cursor is outside Jetstream’s live replay window. Add an API key for archive catch-up."
                        message = terminalMessage ?? "Archive catch-up is needed."
                        logger.write("ERROR", "Popfeed Jetstream rejected stale cursor with HTTP 400; archive key missing; cursor=\(lastCursor)")
                        break
                    }
                }
                message = "Jetstream disconnected; retrying in \(retryDelay)s."
                logger.write("WARN", "Popfeed Jetstream connection failed; retryInSeconds=\(retryDelay), error=\(String(reflecting: error))")
                socket?.cancel(with: .goingAway, reason: nil)
                socket = nil
                do { try await Task.sleep(nanoseconds: retryDelay * 1_000_000_000) }
                catch { break }
                retryDelay = min(retryDelay * 2, 60)
            }
        }
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isRunning = false
        if !Task.isCancelled { message = terminalMessage ?? "Popfeed live sync stopped." }
    }

    private func replayArchive(did: String, apiKey: String) async throws {
        let start = UInt64(max(0, lastCursor))
        message = start == 0 ? "Importing Popfeed history from Jetstream archive…" : "Catching up Popfeed history…"
        logger.write("INFO", "Popfeed archive catch-up starting; afterSeq=\(start)")
        let finalCursor = try await archiveReplay.catchUp(
            did: did,
            apiKey: apiKey,
            after: start,
            onEvents: { [weak self] events in
                guard let self else { return }
                let changes = events.compactMap { self.archiveChange(for: $0, accountDID: did) }
                if !changes.isEmpty { self.recordCount = try await self.store.apply(changes) }
            },
            onCursor: { [weak self] cursor in
                guard let self, cursor <= UInt64(Int64.max) else { return }
                self.lastCursor = max(self.lastCursor, Int64(cursor))
                self.defaults.set(String(self.lastCursor), forKey: self.cursorKey(for: did))
            },
            onProgress: { [weak self] _, text in self?.message = text }
        )
        if finalCursor <= UInt64(Int64.max) {
            lastCursor = max(lastCursor, Int64(finalCursor))
            defaults.set(String(lastCursor), forKey: cursorKey(for: did))
        }
        recordCount = await store.count
        message = "Archive catch-up complete: \(recordCount.formatted()) Popfeed records."
        logger.write("INFO", "Popfeed archive catch-up complete; records=\(recordCount), cursor=\(lastCursor)")
    }

    private func archiveChange(for event: PopfeedArchiveEvent, accountDID: String) -> PopfeedRecordChange? {
        guard event.did == accountDID else { return nil }
        let uri = "at://\(event.did)/\(event.collection)/\(event.rkey)"
        switch event.kind {
        case 1, 2: // create / update
            guard event.collection.hasPrefix("social.popfeed.") else { return nil }
            return .upsert(uri: uri, record: event.recordCBOR)
        case 3: // delete
            guard event.collection.hasPrefix("social.popfeed.") else { return nil }
            return .remove(uri: uri)
        case 5: // account state
            if Self.accountIsInactive(event.recordCBOR) {
                logger.write("WARN", "Popfeed archive account inactive; local records cleared")
                return .removeAll(did: accountDID)
            }
            return nil
        case 6: // sync marker means the repo was reset; following commits rebuild it
            logger.write("WARN", "Popfeed archive sync marker; local account records cleared pending replacement commits")
            return .removeAll(did: accountDID)
        default:
            return nil
        }
    }

    /// Reads the small CBOR map used by Jetstream account events to find `active: false`.
    private static func accountIsInactive(_ data: Data) -> Bool {
        var bytes = Array(data)
        guard let first = bytes.first, first >> 5 == 5 else { return false }
        bytes.removeFirst()
        guard let pairCount = cborLength(additional: first & 0x1f, bytes: &bytes) else { return false }
        for _ in 0..<pairCount {
            guard let key = Self.readCBORText(&bytes), let value = bytes.first else { return false }
            bytes.removeFirst()
            if key == "active", value == 0xf4 { return true }
            guard Self.skipCBORValue(initial: value, bytes: &bytes) else { return false }
        }
        return false
    }

    private static func readCBORText(_ bytes: inout [UInt8]) -> String? {
        guard let initial = bytes.first, initial >> 5 == 3 else { return nil }
        bytes.removeFirst()
        guard let length = cborLength(additional: initial & 0x1f, bytes: &bytes), length <= bytes.count else { return nil }
        let textBytes = bytes.prefix(length)
        bytes.removeFirst(length)
        return String(bytes: textBytes, encoding: .utf8)
    }

    private static func skipCBORValue(initial: UInt8, bytes: inout [UInt8]) -> Bool {
        let major = initial >> 5
        let additional = initial & 0x1f
        if major == 7 { return true }
        if major == 0 || major == 1 {
            switch additional {
            case 0...23: return true
            case 24: return consumeCBORBytes(1, from: &bytes)
            case 25: return consumeCBORBytes(2, from: &bytes)
            case 26: return consumeCBORBytes(4, from: &bytes)
            case 27: return consumeCBORBytes(8, from: &bytes)
            default: return false
            }
        }
        guard let length = cborLength(additional: additional, bytes: &bytes) else { return false }
        switch major {
        case 2, 3:
            guard length <= bytes.count else { return false }
            bytes.removeFirst(length)
        case 4:
            for _ in 0..<length {
                guard skipNextCBORValue(&bytes) else { return false }
            }
        case 5:
            for _ in 0..<length {
                guard skipNextCBORValue(&bytes), skipNextCBORValue(&bytes) else { return false }
            }
        case 6:
            guard skipNextCBORValue(&bytes) else { return false }
        default:
            break
        }
        return true
    }

    private static func consumeCBORBytes(_ count: Int, from bytes: inout [UInt8]) -> Bool {
        guard count <= bytes.count else { return false }
        bytes.removeFirst(count)
        return true
    }

    private static func skipNextCBORValue(_ bytes: inout [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return false }
        return skipCBORValue(initial: bytes.removeFirst(), bytes: &bytes)
    }

    private static func cborLength(additional: UInt8, bytes: inout [UInt8]) -> Int? {
        switch additional {
        case 0...23: return Int(additional)
        case 24:
            guard !bytes.isEmpty else { return nil }
            return Int(bytes.removeFirst())
        case 25:
            guard bytes.count >= 2 else { return nil }
            return Int(bytes.removeFirst()) << 8 | Int(bytes.removeFirst())
        case 26:
            guard bytes.count >= 4 else { return nil }
            var value = 0
            for _ in 0..<4 { value = (value << 8) | Int(bytes.removeFirst()) }
            return value
        case 27:
            guard bytes.count >= 8 else { return nil }
            var value: UInt64 = 0
            for _ in 0..<8 { value = (value << 8) | UInt64(bytes.removeFirst()) }
            guard value <= UInt64(Int.max) else { return nil }
            return Int(value)
        default: return nil
        }
    }

    private func consume(_ data: Data) async throws {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let payload = (root?["payload"] as? [String: Any]) ?? root else { return }
        let eventType = (payload["$type"] as? String)?.components(separatedBy: "#").last ?? ""
        let seq = (payload["seq"] as? NSNumber)?.int64Value ?? 0
        guard seq > 0 else { return }

        if eventType == "commit" {
            guard let did = payload["did"] as? String,
                  let collection = payload["collection"] as? String,
                  collection.hasPrefix("social.popfeed."),
                  let rkey = payload["rkey"] as? String,
                  let operation = payload["operation"] as? String else { return }
            let uri = "at://\(did)/\(collection)/\(rkey)"
            if operation == "delete" {
                recordCount = try await store.remove(uri: uri)
            } else if operation == "create" || operation == "update",
                      let record = payload["record"], JSONSerialization.isValidJSONObject(record) {
                let recordData = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                recordCount = try await store.upsert(uri: uri, record: recordData)
            }
        } else if eventType == "account", (payload["active"] as? Bool) == false {
            recordCount = try await store.removeAll(forDID: payload["did"] as? String ?? "")
            logger.write("WARN", "Popfeed account inactive; local Popfeed record cache cleared")
        } else if eventType == "sync" {
            recordCount = try await store.removeAll(forDID: payload["did"] as? String ?? "")
            logger.write("WARN", "Popfeed repository sync marker received; local records cleared pending replacement commits")
        }

        // Persist only after the event's local effect succeeds. Cursor replay is inclusive,
        // so duplicate delivery is expected and upsert/delete operations remain idempotent.
        lastCursor = max(lastCursor, seq)
        if let did = payload["did"] as? String {
            defaults.set(String(lastCursor), forKey: cursorKey(for: did))
        }
    }

    private func cursorKey(for did: String) -> String {
        "popfeed.jetstream.v2.cursor.\(did)"
    }

    private enum SyncError: Error { case invalidEndpoint, invalidCommit }
}

private actor PopfeedRecordStore {
    private struct Snapshot: Codable {
        var records: [String: Data] = [:]
    }

    private let fileURL: URL
    private var records: [String: Data]

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PopfeedSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("records.json")
        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            records = snapshot.records
        } else {
            records = [:]
        }
    }

    var count: Int { records.count }

    func upsert(uri: String, record: Data) throws -> Int {
        records[uri] = record
        try persist()
        return records.count
    }

    func remove(uri: String) throws -> Int {
        records.removeValue(forKey: uri)
        try persist()
        return records.count
    }

    func removeAll() throws -> Int {
        records.removeAll(keepingCapacity: false)
        try persist()
        return 0
    }

    func removeAll(forDID did: String) throws -> Int {
        let prefix = "at://\(did)/"
        records = records.filter { !$0.key.hasPrefix(prefix) }
        try persist()
        return records.count
    }

    func apply(_ changes: [PopfeedRecordChange]) throws -> Int {
        for change in changes {
            switch change {
            case .upsert(let uri, let record): records[uri] = record
            case .remove(let uri): records.removeValue(forKey: uri)
            case .removeAll(let did):
                let prefix = "at://\(did)/"
                records = records.filter { !$0.key.hasPrefix(prefix) }
            }
        }
        try persist()
        return records.count
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(Snapshot(records: records))
        try data.write(to: fileURL, options: .atomic)
    }
}

private enum PopfeedRecordChange {
    case upsert(uri: String, record: Data)
    case remove(uri: String)
    case removeAll(did: String)
}
