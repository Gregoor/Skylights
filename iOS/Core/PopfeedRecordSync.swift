import Combine
import Foundation

struct PopfeedCachedRecord: Codable, Identifiable {
    let uri: String
    var cid: String?
    var record: Data
    var id: String { uri }
    var collection: String { String(uri.split(separator: "/").dropLast().last ?? "") }
    var rkey: String { String(uri.split(separator: "/").last ?? "") }
}

struct PopfeedReview: Identifiable {
    let id: String
    let title: SpotlightTitle
    let seriesTMDBID: UInt32?
    let seasonNumber: UInt16?
    let rating: Int?
    let text: String
    let createdAt: Date
}

struct PopfeedPendingMutation: Codable, Identifiable {
    enum Operation: String, Codable { case put, delete }
    var id: UUID = UUID()
    var uri: String
    var operation: Operation
    var baseCID: String?
    var record: Data?
    var createdAt: Date = Date()
}

struct PopfeedWriteConflict: Codable, Identifiable {
    var id: UUID = UUID()
    var uri: String
    var baseCID: String?
    var remoteCID: String?
    var localRecord: Data?
    var remoteRecord: Data?
    var detectedAt: Date = Date()
}

@MainActor
final class PopfeedRecordSync: ObservableObject {
    @Published private(set) var status = "Popfeed is not connected."
    @Published private(set) var records: [PopfeedCachedRecord] = []
    @Published private(set) var pending: [PopfeedPendingMutation] = []
    @Published private(set) var conflicts: [PopfeedWriteConflict] = []
    @Published private(set) var isSyncing = false

    private let logger: DiagnosticLog
    private let store = PopfeedOfflineStore()
    private let oauth = PopfeedOAuthClient()
    private var pdsURL: URL?
    private var did = ""
    private var syncRequestedWhileRunning = false

    init(logger: DiagnosticLog) {
        self.logger = logger
        did = oauth.connectedDID ?? UserDefaults.standard.string(forKey: "popfeed.sync.did") ?? ""
        Task { await loadLocalState() }
    }

    var connected: Bool { oauth.connectedDID != nil }

    func restoreIfPossible(did requestedDID: String) async {
        await loadLocalState()
        guard let account = oauth.connectedDID else { return }
        did = account
        UserDefaults.standard.set(account, forKey: "popfeed.sync.did")
        do {
            pdsURL = try await oauth.personalDataServer()
            status = "Connected to Popfeed as \(account)."
            await synchronize()
        } catch {
            status = "Could not restore Popfeed session: \(error.localizedDescription)"
            logger.write("ERROR", "Popfeed OAuth restore failed; did=\(account), error=\(String(reflecting: error))")
        }
    }

    func beginLogin(did rawDID: String) async throws -> URL {
        let accountDID = rawDID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accountDID.hasPrefix("did:") else { throw RecordSyncError.invalidResponse("Enter a valid account DID first.") }
        status = "Opening secure Popfeed sign in…"
        logger.write("INFO", "Starting AT Protocol OAuth; did=\(accountDID)")
        return try await oauth.begin(did: accountDID)
    }

    func completeLogin(callback: URL) async {
        guard !isSyncing else { return }
        isSyncing = true
        var connectedSuccessfully = false
        do {
            did = try await oauth.complete(callback: callback)
            UserDefaults.standard.set(did, forKey: "popfeed.sync.did")
            pdsURL = try await oauth.personalDataServer()
            status = "Connected as \(did)."
            logger.write("INFO", "Popfeed OAuth connected; did=\(did)")
            connectedSuccessfully = true
        } catch {
            status = "Popfeed sign in failed: \(error.localizedDescription)"
            logger.write("ERROR", "Popfeed OAuth callback failed: \(String(reflecting: error))")
        }
        isSyncing = false
        if connectedSuccessfully { await synchronize() }
    }

    func disconnect() {
        oauth.disconnect()
        pdsURL = nil
        status = "Popfeed is disconnected. Local records and queued changes are kept on this device."
        logger.write("INFO", "Popfeed OAuth disconnected; offline mutations retained")
    }

    func synchronize() async {
        guard !isSyncing else {
            syncRequestedWhileRunning = true
            return
        }
        guard connected else { status = "Connect Popfeed to sync queued changes."; return }
        isSyncing = true
        repeat {
            syncRequestedWhileRunning = false
            do {
                if pdsURL == nil { pdsURL = try await oauth.personalDataServer() }
                status = "Refreshing Popfeed records…"
                try await refreshCollections()
                try await flushPending()
                await loadLocalState()
                status = conflicts.isEmpty
                    ? "Popfeed is current. \(pending.count) pending changes."
                    : "\(conflicts.count) Popfeed conflict(s) need your choice."
                logger.write("INFO", "Popfeed account refresh complete; records=\(records.count), queued=\(pending.count), conflicts=\(conflicts.count)")
            } catch {
                status = "Popfeed sync paused; changes are saved locally: \(error.localizedDescription)"
                logger.write("ERROR", "Popfeed account sync failed; queued=\(pending.count), error=\(String(reflecting: error))")
            }
        } while syncRequestedWhileRunning && connected
        isSyncing = false
    }

    func saveReview(for title: SpotlightTitle, rating: Int?, text: String) async {
        guard let record = reviewRecord(for: title, rating: rating, text: text) else { return }
        let existing = records.first { candidate in
            candidate.collection == "social.popfeed.feed.review" && Self.tmdbID(in: candidate.record) == String(title.tmdbID)
        }
        let uri = existing?.uri ?? "at://\(did.isEmpty ? UserDefaults.standard.string(forKey: "popfeed.sync.did") ?? "unknown" : did)/social.popfeed.feed.review/\(Self.newTID())"
        await enqueue(.init(uri: uri, operation: .put, baseCID: existing?.cid, record: record))
    }

    func createList(name: String, description: String) async {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { status = "A list needs a name."; return }
        let record: [String: Any] = [
            "$type": "social.popfeed.feed.list",
            "createdAt": Self.isoDate(Date()),
            "description": description,
            "itemOrder": [String](),
            "listType": "default",
            "name": cleanName,
            "ordered": true,
            "tags": [String]()
        ]
        await createRecord(collection: "social.popfeed.feed.list", record: record)
    }

    func updateList(_ list: PopfeedCachedRecord, name: String, description: String) async {
        guard var record = Self.dictionary(list.record) else { return }
        record["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        record["description"] = description
        await enqueue(.init(uri: list.uri, operation: .put, baseCID: list.cid, record: Self.json(record)))
    }

    func deleteList(_ list: PopfeedCachedRecord) async {
        let items = records.filter {
            $0.collection == "social.popfeed.feed.listItem" && Self.string(Self.dictionary($0.record)?["listUri"]) == list.uri
        }
        for item in items { await enqueue(.init(uri: item.uri, operation: .delete, baseCID: item.cid, record: nil)) }
        await enqueue(.init(uri: list.uri, operation: .delete, baseCID: list.cid, record: nil))
    }

    func add(_ title: SpotlightTitle, to list: PopfeedCachedRecord) async {
        let existing = records.first {
            $0.collection == "social.popfeed.feed.listItem" &&
            Self.string(Self.dictionary($0.record)?["listUri"]) == list.uri &&
            Self.tmdbID(in: $0.record) == String(title.tmdbID)
        }
        guard existing == nil else { status = "Already in this list."; return }
        let record: [String: Any] = [
            "$type": "social.popfeed.feed.listItem",
            "addedAt": Self.isoDate(Date()),
            "creativeWorkType": title.isMovie ? "movie" : "tv_show",
            "identifiers": title.isMovie ? ["tmdbId": String(title.tmdbID)] : ["tmdbId": String(title.tmdbID), "tmdbTvSeriesId": String(title.tmdbID)],
            "listType": "default",
            "listUri": list.uri,
            "title": title.title
        ]
        let itemURI = "at://\(did)/social.popfeed.feed.listItem/\(Self.newTID())"
        var mutableList = Self.dictionary(list.record) ?? [:]
        var order = mutableList["itemOrder"] as? [String] ?? []
        order.append(itemURI)
        mutableList["itemOrder"] = order
        await enqueue(.init(uri: itemURI, operation: .put, baseCID: nil, record: Self.json(record)))
        await enqueue(.init(uri: list.uri, operation: .put, baseCID: list.cid, record: Self.json(mutableList)))
    }

    func remove(_ item: PopfeedCachedRecord) async {
        await enqueue(.init(uri: item.uri, operation: .delete, baseCID: item.cid, record: nil))
    }

    func resolveConflict(_ conflict: PopfeedWriteConflict, useLocal: Bool) async {
        await store.resolve(conflictURI: conflict.uri, useLocal: useLocal)
        await loadLocalState()
        if useLocal { await synchronize() }
    }

    var lists: [PopfeedCachedRecord] {
        records.filter { $0.collection == "social.popfeed.feed.list" }.sorted {
            (Self.string(Self.dictionary($0.record)?["name"]) ?? "") < (Self.string(Self.dictionary($1.record)?["name"]) ?? "")
        }
    }

    var reviews: [PopfeedReview] {
        var latestByTitle: [String: PopfeedReview] = [:]
        for record in records where record.collection == "social.popfeed.feed.review" {
            guard
                let value = Self.dictionary(record.record),
                let tmdbID = Self.tmdbID(in: record.record).flatMap(UInt32.init),
                let titleName = Self.string(value["title"]),
                !titleName.isEmpty
            else { continue }

            let creativeWorkType = Self.string(value["creativeWorkType"])
            let isMovie = creativeWorkType == "movie"
            let seriesTMDBID = Self.string((value["identifiers"] as? [String: Any])?["tmdbTvSeriesId"]).flatMap(UInt32.init)
            let seasonNumber = (value["seasonNumber"] as? NSNumber)?.uint16Value
            let posterURL = Self.string(value["posterUrl"]).flatMap(URL.init(string:))
            let posterPath = posterURL.map { "/\($0.lastPathComponent)" } ?? ""
            let releaseDate = Self.string(value["releaseDate"]) ?? ""
            let year = UInt16(String(releaseDate.prefix(4))) ?? 0
            let title = SpotlightTitle(
                mediaType: isMovie ? 0 : 1,
                tmdbID: tmdbID,
                title: titleName,
                year: year,
                posterPath: posterPath,
                posterURLOverride: posterURL
            )
            let createdAt = Self.date(Self.createdAt(record.record))
            let review = PopfeedReview(
                id: record.uri,
                title: title,
                seriesTMDBID: seriesTMDBID,
                seasonNumber: creativeWorkType == "tv_season" ? seasonNumber : nil,
                rating: (value["rating"] as? NSNumber)?.intValue,
                text: Self.string(value["text"]) ?? "",
                createdAt: createdAt
            )
            if let existing = latestByTitle[title.id], existing.createdAt >= createdAt { continue }
            latestByTitle[title.id] = review
        }
        return latestByTitle.values.sorted { $0.createdAt > $1.createdAt }
    }

    func items(in list: PopfeedCachedRecord) -> [PopfeedCachedRecord] {
        let order = Self.dictionary(list.record)?["itemOrder"] as? [String] ?? []
        let items = records.filter { $0.collection == "social.popfeed.feed.listItem" && Self.string(Self.dictionary($0.record)?["listUri"]) == list.uri }
        let byURI = Dictionary(uniqueKeysWithValues: items.map { ($0.uri, $0) })
        let ordered = order.compactMap { byURI[$0] }
        return ordered + items.filter { item in !order.contains(item.uri) }.sorted { $0.uri < $1.uri }
    }

    func localReview(for title: SpotlightTitle) -> (rating: Int?, text: String)? {
        guard let record = records
            .filter({ $0.collection == "social.popfeed.feed.review" && Self.tmdbID(in: $0.record) == String(title.tmdbID) })
            .max(by: { Self.createdAt($0.record) < Self.createdAt($1.record) }),
              let value = Self.dictionary(record.record) else { return nil }
        return ((value["rating"] as? NSNumber)?.intValue, Self.string(value["text"]) ?? "")
    }

    private func enqueue(_ mutation: PopfeedPendingMutation) async {
        guard !did.isEmpty || UserDefaults.standard.string(forKey: "popfeed.sync.did")?.hasPrefix("did:") == true else {
            status = "Set your Popfeed account DID in Sync & Diagnostics first."
            return
        }
        await store.enqueue(mutation)
        await loadLocalState()
        status = connected ? "Saved locally; publishing…" : "Saved on this device. Connect Popfeed to publish when online."
        logger.write("INFO", "Popfeed change queued; operation=\(mutation.operation.rawValue), collection=\(Self.collection(from: mutation.uri)), baseCID=\(mutation.baseCID ?? "absent")")
        if connected { await synchronize() }
    }

    private func createRecord(collection: String, record: [String: Any]) async {
        let account = did.isEmpty ? (UserDefaults.standard.string(forKey: "popfeed.sync.did") ?? "unknown") : did
        guard account.hasPrefix("did:") else { status = "Set a valid account DID in Sync & Diagnostics first."; return }
        await enqueue(.init(uri: "at://\(account)/\(collection)/\(Self.newTID())", operation: .put, baseCID: nil, record: Self.json(record)))
    }

    private func reviewRecord(for title: SpotlightTitle, rating: Int?, text: String) -> Data? {
        var record: [String: Any] = [
            "$type": "social.popfeed.feed.review",
            "containsSpoilers": false,
            "createdAt": Self.isoDate(Date()),
            "creativeWorkType": title.isMovie ? "movie" : "tv_show",
            "facets": [Any](),
            "genres": [String](),
            "identifiers": title.isMovie ? ["tmdbId": String(title.tmdbID)] : ["tmdbId": String(title.tmdbID), "tmdbTvSeriesId": String(title.tmdbID)],
            "isRevisit": false,
            "posterUrl": title.posterURL?.absoluteString ?? "https://image.tmdb.org/t/p/w500\(title.posterPath)",
            "tags": [String](),
            "text": text,
            "title": title.title
        ]
        if title.year > 0 { record["releaseDate"] = String(format: "%04d-01-01T00:00:00.000Z", title.year) }
        if let rating { record["rating"] = rating }
        return Self.json(record)
    }

    private func refreshCollections() async throws {
        guard let pdsURL else { throw RecordSyncError.notConnected }
        for collection in ["social.popfeed.feed.review", "social.popfeed.feed.list", "social.popfeed.feed.listItem"] {
            var cursor: String?
            var fetched: [PopfeedCachedRecord] = []
            repeat {
                var components = URLComponents(url: pdsURL.appendingPathComponent("xrpc/com.atproto.repo.listRecords"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "repo", value: did), URLQueryItem(name: "collection", value: collection), URLQueryItem(name: "limit", value: "100")]
                if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
                // Repo reads are public on AT Protocol PDSes. Keep these requests
                // unauthenticated: some PDSes return public records with HTTP 200
                // while ignoring DPoP headers, which cannot satisfy OAuth's nonce rules.
                let data = try await publicRequest(URLRequest(url: components.url!))
                guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawRecords = response["records"] as? [[String: Any]] else {
                    throw RecordSyncError.invalidResponse("listRecords response was missing records")
                }
                for raw in rawRecords {
                    guard let uri = raw["uri"] as? String, let value = raw["value"], JSONSerialization.isValidJSONObject(value) else { continue }
                    fetched.append(PopfeedCachedRecord(uri: uri, cid: raw["cid"] as? String, record: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])))
                }
                cursor = response["cursor"] as? String
            } while cursor != nil
            await store.replace(collection: collection, records: fetched)
            logger.write("INFO", "Popfeed records refreshed from PDS; collection=\(collection), count=\(fetched.count)")
        }
        await loadLocalState()
    }

    private func flushPending() async throws {
        for mutation in pending.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard pdsURL != nil, connected else { throw RecordSyncError.notConnected }
            let path = mutation.uri.split(separator: "/")
            guard path.count == 4, path[0] == "at:", !path[1].isEmpty, !path[2].isEmpty, !path[3].isEmpty else {
                throw RecordSyncError.invalidResponse("invalid record URI")
            }
            let collection = String(path[2])
            let rkey = String(path[3])
            var body: [String: Any] = ["repo": did, "collection": collection, "rkey": rkey]
            let endpoint: String
            switch mutation.operation {
            case .put:
                guard let recordData = mutation.record, let record = try JSONSerialization.jsonObject(with: recordData) as? [String: Any] else {
                    throw RecordSyncError.invalidResponse("queued record was malformed")
                }
                body["record"] = record
                body["swapRecord"] = mutation.baseCID.map { $0 as Any } ?? NSNull()
                endpoint = "com.atproto.repo.putRecord"
            case .delete:
                guard let baseCID = mutation.baseCID else { await store.removePending(mutation.id); continue }
                body["swapRecord"] = baseCID
                endpoint = "com.atproto.repo.deleteRecord"
            }
            do {
                let data = try await xrpc(endpoint, method: "POST", body: body, authenticated: true)
                if mutation.operation == .put,
                   let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let cid = response["cid"] as? String,
                   let record = mutation.record {
                    await store.accept(uri: mutation.uri, cid: cid, record: record)
                } else if mutation.operation == .delete {
                    await store.delete(uri: mutation.uri)
                }
                await store.removePending(mutation.id)
                logger.write("INFO", "Popfeed record write accepted; operation=\(mutation.operation.rawValue), collection=\(collection), rkey=\(rkey)")
            } catch RecordSyncError.http(let code, let detail) where code == 400 || code == 409 {
                if detail.localizedCaseInsensitiveContains("InvalidSwap") || detail.localizedCaseInsensitiveContains("swap") {
                    let remote = try? await fetchRecord(collection: collection, rkey: rkey)
                    await store.addConflict(.init(uri: mutation.uri, baseCID: mutation.baseCID, remoteCID: remote?.cid, localRecord: mutation.record, remoteRecord: remote?.record))
                    await store.removePending(mutation.id)
                    logger.write("WARN", "Popfeed write conflict; collection=\(collection), rkey=\(rkey), baseCID=\(mutation.baseCID ?? "absent"), remoteCID=\(remote?.cid ?? "missing")")
                    break
                }
                throw RecordSyncError.http(code, detail)
            }
        }
    }

    private func fetchRecord(collection: String, rkey: String) async throws -> PopfeedCachedRecord? {
        guard let pdsURL else { throw RecordSyncError.notConnected }
        var components = URLComponents(url: pdsURL.appendingPathComponent("xrpc/com.atproto.repo.getRecord"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "repo", value: did), URLQueryItem(name: "collection", value: collection), URLQueryItem(name: "rkey", value: rkey)]
        let data = try await publicRequest(URLRequest(url: components.url!))
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let record = value["value"], JSONSerialization.isValidJSONObject(record) else { return nil }
        return PopfeedCachedRecord(uri: value["uri"] as? String ?? "at://\(did)/\(collection)/\(rkey)", cid: value["cid"] as? String, record: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
    }

    private func authenticatedRequest(_ request: URLRequest) async throws -> Data {
        do { return try await oauth.request(request) }
        catch let error as PopfeedOAuthClient.OAuthError { throw RecordSyncError.http(401, error.localizedDescription) }
    }

    private func publicRequest(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RecordSyncError.invalidResponse("missing PDS response") }
        guard (200..<300).contains(http.statusCode) else {
            throw RecordSyncError.http(http.statusCode, String(data: data.prefix(700), encoding: .utf8) ?? "")
        }
        return data
    }

    private func xrpc(_ methodName: String, method: String = "GET", body: [String: Any]? = nil, authenticated: Bool, tokenOverride: String? = nil) async throws -> Data {
        guard let pdsURL else { throw RecordSyncError.notConnected }
        var request = URLRequest(url: pdsURL.appendingPathComponent("xrpc/\(methodName)"))
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated { return try await authenticatedRequest(request) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RecordSyncError.invalidResponse("missing HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw RecordSyncError.http(http.statusCode, String(data: data.prefix(700), encoding: .utf8) ?? "")
        }
        return data
    }

    private func loadLocalState() async {
        records = await store.allRecords()
        pending = await store.allPending()
        conflicts = await store.allConflicts()
    }

    private static func tmdbID(in data: Data) -> String? {
        guard let record = dictionary(data), let identifiers = record["identifiers"] as? [String: Any] else { return nil }
        return string(identifiers["tmdbId"]) ?? string(identifiers["tmdbTvSeriesId"])
    }
    private static func createdAt(_ data: Data) -> String { string(dictionary(data)?["createdAt"]) ?? "" }
    private static func date(_ value: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) ?? .distantPast
    }
    private static func dictionary(_ data: Data) -> [String: Any]? { try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
    private static func json(_ value: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private static func string(_ value: Any?) -> String? { value as? String ?? (value as? NSNumber)?.stringValue }
    private static func collection(from uri: String) -> String { String(uri.split(separator: "/").dropLast().last ?? "") }
    private static func isoDate(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private static func newTID() -> String {
        let alphabet = Array("234567abcdefghijklmnopqrstuvwxyz")
        let secondsSince2000 = max(0, Date().timeIntervalSince1970 - 946_684_800)
        var value = (UInt64(secondsSince2000 * 10_000) << 10) | UInt64.random(in: 0..<1024)
        var chars = Array(repeating: Character("2"), count: 13)
        for index in stride(from: 12, through: 0, by: -1) { chars[index] = alphabet[Int(value & 31)]; value >>= 5 }
        return String(chars)
    }

    enum RecordSyncError: LocalizedError {
        case notConnected
        case invalidResponse(String)
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .notConnected: return "Sign in to your Popfeed account to publish queued changes."
            case .invalidResponse(let text): return text
            case .http(let status, let detail): return "PDS returned HTTP \(status): \(detail)"
            }
        }
    }
}

private actor PopfeedOfflineStore {
    private struct Snapshot: Codable {
        var records: [String: PopfeedCachedRecord] = [:]
        var pending: [PopfeedPendingMutation] = []
        var conflicts: [PopfeedWriteConflict] = []
    }
    private let fileURL: URL
    private var snapshot: Snapshot

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PopfeedSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("offline-records.json")
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) { snapshot = decoded }
        else { snapshot = Snapshot() }
    }

    func allRecords() -> [PopfeedCachedRecord] { Array(snapshot.records.values) }
    func allPending() -> [PopfeedPendingMutation] { snapshot.pending }
    func allConflicts() -> [PopfeedWriteConflict] { snapshot.conflicts }

    func replace(collection: String, records: [PopfeedCachedRecord]) {
        let pendingForCollection = snapshot.pending.filter { Self.collection($0.uri) == collection }
        snapshot.records = snapshot.records.filter { $0.value.collection != collection }
        for record in records { snapshot.records[record.uri] = record }
        for mutation in pendingForCollection.sorted(by: { $0.createdAt < $1.createdAt }) {
            if mutation.operation == .put, let value = mutation.record {
                snapshot.records[mutation.uri] = PopfeedCachedRecord(uri: mutation.uri, cid: mutation.baseCID, record: value)
            } else if mutation.operation == .delete {
                snapshot.records.removeValue(forKey: mutation.uri)
            }
        }
        persist()
    }

    func enqueue(_ mutation: PopfeedPendingMutation) {
        if let index = snapshot.pending.firstIndex(where: { $0.uri == mutation.uri }) {
            var replacement = mutation
            replacement.baseCID = snapshot.pending[index].baseCID
            replacement.createdAt = snapshot.pending[index].createdAt
            snapshot.pending[index] = replacement
        } else {
            snapshot.pending.append(mutation)
        }
        if mutation.operation == .put, let record = mutation.record {
            snapshot.records[mutation.uri] = PopfeedCachedRecord(uri: mutation.uri, cid: mutation.baseCID, record: record)
        } else if mutation.operation == .delete {
            snapshot.records.removeValue(forKey: mutation.uri)
        }
        persist()
    }

    func accept(uri: String, cid: String, record: Data) {
        snapshot.records[uri] = PopfeedCachedRecord(uri: uri, cid: cid, record: record)
        persist()
    }
    func delete(uri: String) { snapshot.records.removeValue(forKey: uri); persist() }
    func removePending(_ id: UUID) { snapshot.pending.removeAll { $0.id == id }; persist() }
    func addConflict(_ conflict: PopfeedWriteConflict) { snapshot.conflicts.removeAll { $0.uri == conflict.uri }; snapshot.conflicts.append(conflict); persist() }

    func resolve(conflictURI: String, useLocal: Bool) {
        guard let conflict = snapshot.conflicts.first(where: { $0.uri == conflictURI }) else { return }
        snapshot.conflicts.removeAll { $0.uri == conflictURI }
        if useLocal, let local = conflict.localRecord {
            snapshot.pending.append(.init(uri: conflict.uri, operation: .put, baseCID: conflict.remoteCID, record: local))
            snapshot.records[conflict.uri] = PopfeedCachedRecord(uri: conflict.uri, cid: conflict.remoteCID, record: local)
        } else if !useLocal, let remoteCID = conflict.remoteCID, let remote = conflict.remoteRecord {
            snapshot.records[conflict.uri] = PopfeedCachedRecord(uri: conflict.uri, cid: remoteCID, record: remote)
        } else if !useLocal {
            snapshot.records.removeValue(forKey: conflict.uri)
        }
        persist()
    }

    private static func collection(_ uri: String) -> String { String(uri.split(separator: "/").dropLast().last ?? "") }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
