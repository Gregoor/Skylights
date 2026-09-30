import CoreSpotlight
import CryptoKit
import Foundation
import UIKit

private struct IndexManifest: Decodable {
    struct Asset: Decodable { let name: String; let bytes: UInt64; let sha256: String }
    let version: Int
    let generatedAt: String?
    let base: Asset?
    let deltas: [Asset]?
}

private struct MovieRow: Codable {
    let id: UInt32
    let title: String
    let original: String
    let year: UInt16
    let imdbNum: UInt32
    let popularity: Float
    let votes: UInt32
    let mediaType: UInt8
    let rt: UInt8
    let metacritic: UInt8
    let imdb: UInt8
    let posterPath: String
    var stableKey: UInt64 { UInt64(id) * 2 + (mediaType == 1 ? 1 : 0) }
}

private struct IndexSnapshot: Codable {
    var baseSHA: String
    var appliedDeltas: Set<String>
    var rows: [MovieRow]
    var indexedKeys: Set<UInt64>
    var indexedLimit: Int?
    var buildComplete: Bool
    var spotlightURLVersion: Int
}

struct SyncResult { let indexed: Int; let movies: Int; let series: Int; let skippedByLimit: Int; let incremental: Bool }

final class SpotlightIndexer {
    private let logger: DiagnosticLog
    private let session: URLSession
    private let manifestURL = URL(string: "https://github.com/Gregoor/tinycast-tmdb/releases/download/latest/manifest.json")!
    private let batchSize = 250
    private let domain = "com.tinycast.tmdbspotlight.tmdb"
    private let snapshotURL: URL
    private let posterDirectory: URL
    private let checkpointKey = "spotlight.sync.checkpoint"
    private static let spotlightURLVersion = 1
    private struct Checkpoint: Codable { let dataset: String; let nextIndex: Int }


    init(logger: DiagnosticLog) {
        self.logger = logger
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 900
        session = URLSession(configuration: config)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TMDBSpotlight", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        snapshotURL = support.appendingPathComponent("index-snapshot.plist")
        posterDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TMDBSpotlightPosters", isDirectory: true)
        try? FileManager.default.createDirectory(at: posterDirectory, withIntermediateDirectories: true)
    }

    /// Reuses the on-device merged index and fetches only GitHub deltas not already applied.
    /// If the base was replaced (or no snapshot exists), it rebuilds from the published base.
    func sync(limit: Int?, incrementalOnly: Bool = false, progress: @escaping @Sendable (Int, Int, String) -> Void) async throws -> SyncResult {
        logger.write("INFO", "Sync requested; rowLimit=\(limit.map(String.init) ?? "all"), incrementalOnly=\(incrementalOnly), batchSize=\(batchSize), OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        let spotlightAvailable = CSSearchableIndex.isIndexingAvailable()
        logger.write("INFO", "Core Spotlight indexing available=\(spotlightAvailable)")
        guard spotlightAvailable else { throw IndexerError.spotlightUnavailable }
        progress(0, 1, "Checking TMDB release…")
        let (manifestData, response) = try await session.data(from: manifestURL)
        try checkHTTP(response, label: "manifest")
        let manifest = try JSONDecoder().decode(IndexManifest.self, from: manifestData)
        logger.write("INFO", "Manifest v\(manifest.version), generatedAt=\(manifest.generatedAt ?? "unknown"), base=\(manifest.base?.name ?? "nil"), deltas=\(manifest.deltas?.count ?? 0)")
        guard let base = manifest.base else { throw IndexerError.missingBase }

        let savedSnapshot = loadSnapshot()
        let canIncrement = savedSnapshot?.baseSHA == base.sha256
        if incrementalOnly && savedSnapshot != nil && !canIncrement {
            logger.write("WARN", "Background refresh cannot apply: the published base changed; a foreground rebuild is required")
            throw IndexerError.fullRebuildRequired
        }

        var snapshot: IndexSnapshot
        var changedKeys = Set<UInt64>()
        var removedKeys = Set<UInt64>()
        let urlNeedsMigration = savedSnapshot?.spotlightURLVersion != Self.spotlightURLVersion
        var needsFullRebuild = !canIncrement || savedSnapshot?.buildComplete == false || urlNeedsMigration
        if urlNeedsMigration { logger.write("INFO", "Spotlight result URL schema changed; all selected items must be reindexed") }
        if canIncrement, let savedSnapshot {
            snapshot = savedSnapshot
            var rows = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.stableKey, $0) })
            let knownDeltas = Set(snapshot.appliedDeltas)
            let pending = (manifest.deltas ?? []).filter { !knownDeltas.contains(Self.assetKey($0)) }
            if pending.isEmpty {
                logger.write("INFO", "Snapshot is current: rows=\(rows.count), appliedDeltas=\(snapshot.appliedDeltas.count)")
            }
            for asset in pending {
                try Task.checkCancellation()
                let delta = try await load(asset: asset)
                for key in delta.superseded {
                    if rows.removeValue(forKey: key) != nil { removedKeys.insert(key) }
                    changedKeys.insert(key)
                }
                for row in delta.rows {
                    rows[row.stableKey] = row
                    changedKeys.insert(row.stableKey)
                    removedKeys.remove(row.stableKey)
                }
                snapshot.appliedDeltas.insert(Self.assetKey(asset))
                logger.write("INFO", "Incrementally applied \(asset.name): changedRows=\(delta.rows.count), superseded=\(delta.superseded.count), current=\(rows.count)")
            }
            snapshot.rows = Array(rows.values)
        } else {
            needsFullRebuild = true
            let baseRows = try await load(asset: base)
            var rows = Dictionary<UInt64, MovieRow>(minimumCapacity: baseRows.rows.count)
            for row in baseRows.rows { rows[row.stableKey] = row }
            logger.write("INFO", "Base loaded: rows=\(baseRows.rows.count), superseded=\(baseRows.superseded.count)")
            var applied = Set<String>()
            for asset in manifest.deltas ?? [] {
                try Task.checkCancellation()
                let delta = try await load(asset: asset)
                for key in delta.superseded { rows.removeValue(forKey: key) }
                for row in delta.rows { rows[row.stableKey] = row }
                applied.insert(Self.assetKey(asset))
                logger.write("INFO", "Applied \(asset.name): rows=\(delta.rows.count), superseded=\(delta.superseded.count), current=\(rows.count)")
            }
            snapshot = IndexSnapshot(baseSHA: base.sha256, appliedDeltas: applied, rows: Array(rows.values), indexedKeys: [], indexedLimit: limit, buildComplete: false, spotlightURLVersion: Self.spotlightURLVersion)
            changedKeys = Set(rows.keys)
        }

        let activeLimit = incrementalOnly ? savedSnapshot?.indexedLimit : limit
        let ordered = snapshot.rows.sorted(by: Self.rankedBefore)
        let selected = activeLimit.map { Array(ordered.prefix($0)) } ?? ordered
        let desiredKeys = Set(selected.map(\.stableKey))
        let priorKeys = snapshot.indexedKeys
        let toDelete = (priorKeys.subtracting(desiredKeys)).union(removedKeys.intersection(priorKeys))
        let toIndex: [MovieRow]
        if needsFullRebuild || snapshot.indexedLimit != activeLimit {
            toIndex = selected
        } else {
            toIndex = selected.filter { changedKeys.contains($0.stableKey) || !priorKeys.contains($0.stableKey) }
        }
        logger.write("INFO", "Spotlight update plan: available=\(ordered.count), selected=\(selected.count), delete=\(toDelete.count), upsert=\(toIndex.count), omittedByLimit=\(max(0, ordered.count - selected.count)), covers=all-poster-paths, fullRebuild=\(needsFullRebuild)")
        progress(0, max(1, toIndex.count), needsFullRebuild ? "Preparing \(selected.count.formatted()) titles…" : "Applying \(toIndex.count.formatted()) changed titles…")

        let index = CSSearchableIndex.default()
        let dataset = Self.datasetFingerprint(manifest: manifest, limit: activeLimit)
        let savedCheckpoint = UserDefaults.standard.data(forKey: checkpointKey).flatMap { try? JSONDecoder().decode(Checkpoint.self, from: $0) }
        let resumeAt = needsFullRebuild && savedCheckpoint?.dataset == dataset ? min(savedCheckpoint!.nextIndex, selected.count) : 0
        if resumeAt > 0 { logger.write("INFO", "Resuming full Spotlight rebuild at row \(resumeAt)/\(selected.count)") }
        if needsFullRebuild {
            snapshot.indexedLimit = activeLimit
            snapshot.buildComplete = false
            snapshot.spotlightURLVersion = Self.spotlightURLVersion
            try saveSnapshot(snapshot)
        }
        if needsFullRebuild && resumeAt == 0 {
            do { try await index.deleteSearchableItems(withDomainIdentifiers: [domain]); logger.write("INFO", "Cleared app-owned Spotlight domain \(domain) for base rebuild") }
            catch { logger.write("WARN", "Could not clear previous Spotlight domain: \(String(reflecting: error)); continuing with upsert") }
        } else if !toDelete.isEmpty {
            let identifiers = toDelete.map(Self.identifier(for:))
            try await index.deleteSearchableItems(withIdentifiers: identifiers)
            logger.write("INFO", "Removed \(identifiers.count) deselected/superseded Spotlight items")
        }

        var submitted = 0
        var indexedMovies = 0
        var indexedSeries = 0
        for start in stride(from: resumeAt, to: toIndex.count, by: batchSize) {
            try Task.checkCancellation()
            let end = min(start + batchSize, toIndex.count)
            let batch = Array(toIndex[start..<end])
            let thumbnails = await prepareThumbnails(batch)
            let items = batch.map { makeItem($0, thumbnail: thumbnails[$0.stableKey]) }
            let began = Date()
            do {
                try await index.indexSearchableItems(items)
                submitted += items.count
                indexedMovies += batch.filter { $0.mediaType == 0 }.count
                indexedSeries += batch.filter { $0.mediaType == 1 }.count
                let elapsed = Int(Date().timeIntervalSince(began) * 1000)
                logger.write("INFO", "Spotlight batch accepted: changedRange=\(start + 1)-\(end)/\(toIndex.count), elapsedMs=\(elapsed), submittedTotal=\(submitted), movies=\(indexedMovies), series=\(indexedSeries)")
            } catch {
                logger.write("ERROR", "Spotlight batch rejected: range=\(start + 1)-\(end), submittedBefore=\(submitted), error=\(Self.errorDetails(error))")
                throw error
            }
            progress(end, max(1, toIndex.count), "Updated \(end.formatted()) of \(toIndex.count.formatted()) changed titles…")
            if needsFullRebuild {
                let checkpoint = Checkpoint(dataset: dataset, nextIndex: end)
                if let encoded = try? JSONEncoder().encode(checkpoint) { UserDefaults.standard.set(encoded, forKey: checkpointKey) }
                else { logger.write("WARN", "Could not encode Spotlight resume checkpoint at row \(end)") }
            }
        }
        UserDefaults.standard.removeObject(forKey: checkpointKey)
        snapshot.indexedKeys = desiredKeys
        snapshot.indexedLimit = activeLimit
        snapshot.buildComplete = true
        try saveSnapshot(snapshot)
        logger.write("INFO", "Sync finished: submitted=\(submitted), removed=\(toDelete.count), cachedRows=\(snapshot.rows.count), incremental=\(!needsFullRebuild), movies=\(indexedMovies), series=\(indexedSeries)")
        return SyncResult(indexed: submitted, movies: indexedMovies, series: indexedSeries, skippedByLimit: max(0, ordered.count - selected.count), incremental: !needsFullRebuild)
    }

    private func loadSnapshot() -> IndexSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL), let value = try? PropertyListDecoder().decode(IndexSnapshot.self, from: data) else { return nil }
        logger.write("INFO", "Loaded local index snapshot: rows=\(value.rows.count), appliedDeltas=\(value.appliedDeltas.count), indexedKeys=\(value.indexedKeys.count)")
        return value
    }

    private func saveSnapshot(_ value: IndexSnapshot) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(value)
        try data.write(to: snapshotURL, options: .atomic)
        logger.write("INFO", "Saved local index snapshot: rows=\(value.rows.count), bytes=\(data.count), appliedDeltas=\(value.appliedDeltas.count)")
    }

    private func prepareThumbnails(_ rows: [MovieRow]) async -> [UInt64: URL] {
        var result: [UInt64: URL] = [:]
        let pending = rows.filter { !$0.posterPath.isEmpty && !FileManager.default.fileExists(atPath: posterURL(for: $0).path) }
        for row in rows where !row.posterPath.isEmpty && FileManager.default.fileExists(atPath: posterURL(for: row).path) {
            result[row.stableKey] = posterURL(for: row)
        }
        guard !pending.isEmpty else { return result }
        var cursor = 0
        let maxConcurrent = 6
        await withTaskGroup(of: (UInt64, URL?).self) { group in
            for _ in 0..<min(maxConcurrent, pending.count) {
                let row = pending[cursor]; cursor += 1
                group.addTask { [weak self] in guard let self else { return (row.stableKey, nil) }; return (row.stableKey, await self.downloadPoster(for: row)) }
            }
            while let (key, url) = await group.next() {
                if let url { result[key] = url }
                if cursor < pending.count {
                    let row = pending[cursor]; cursor += 1
                    group.addTask { [weak self] in guard let self else { return (row.stableKey, nil) }; return (row.stableKey, await self.downloadPoster(for: row)) }
                }
            }
        }
        let misses = pending.count - result.count
        if pending.count > 0 { logger.write("INFO", "Poster preparation: requested=\(pending.count), cachedOrDownloaded=\(pending.count - misses), unavailable=\(misses)") }
        return result
    }

    private func downloadPoster(for row: MovieRow) async -> URL? {
        let target = posterURL(for: row)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let path = row.posterPath.hasPrefix("/") ? row.posterPath : "/\(row.posterPath)"
        guard let url = URL(string: "https://image.tmdb.org/t/p/w185\(path)") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), UIImage(data: data) != nil else {
                logger.write("WARN", "Poster unavailable: key=\(row.stableKey), status=\((response as? HTTPURLResponse)?.statusCode ?? -1), bytes=\(data.count)")
                return nil
            }
            try data.write(to: target, options: .atomic)
            return target
        } catch {
            logger.write("WARN", "Poster request failed: key=\(row.stableKey), \(Self.errorDetails(error))")
            return nil
        }
    }

    private func posterURL(for row: MovieRow) -> URL {
        posterDirectory.appendingPathComponent("\(row.mediaType == 0 ? "movie" : "tv")-\(row.id).jpg")
    }

    private func load(asset: IndexManifest.Asset) async throws -> (rows: [MovieRow], superseded: [UInt64]) {
        let url = URL(string: asset.name + ".gz", relativeTo: manifestURL.deletingLastPathComponent())!
        logger.write("INFO", "Downloading \(asset.name).gz; expected expandedBytes=\(asset.bytes), sha256=\(asset.sha256)")
        let (packedURL, response) = try await session.download(from: url)
        try checkHTTP(response, label: asset.name)
        let packedBytes = (try? FileManager.default.attributesOfItem(atPath: packedURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let expandedURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".index")
        defer { try? FileManager.default.removeItem(at: packedURL); try? FileManager.default.removeItem(at: expandedURL) }
        var errorBuffer = [CChar](repeating: 0, count: 256)
        let inflateCode = packedURL.path.withCString { source in expandedURL.path.withCString { target in tmdb_gzip_file(source, target, &errorBuffer, errorBuffer.count) } }
        guard inflateCode == 0 else { throw IndexerError.gzip(String(cString: errorBuffer)) }
        let expandedBytes = (try FileManager.default.attributesOfItem(atPath: expandedURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard expandedBytes == asset.bytes else { throw IndexerError.byteCount(expected: asset.bytes, actual: expandedBytes) }
        let data = try Data(contentsOf: expandedURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == asset.sha256.lowercased() else { throw IndexerError.hashMismatch(asset.name) }
        logger.write("INFO", "Verified \(asset.name): compressedBytes=\(packedBytes), expandedBytes=\(expandedBytes), sha256=ok")
        return try decode(data)
    }

    private func decode(_ data: Data) throws -> (rows: [MovieRow], superseded: [UInt64]) {
        guard data.count >= 128, String(data: data.prefix(8), encoding: .ascii) == "TCIDX001" else { throw IndexerError.invalidIndex("bad header/magic") }
        let version = data.u32(8)
        guard version == 5 else { throw IndexerError.invalidIndex("unsupported format version \(version)") }
        let rowCount = Int(data.u32(12)), supCount = Int(data.u32(104))
        let rowOffset = Int(data.u64(36)), titleOffset = Int(data.u64(80)), originalOffset = Int(data.u64(88))
        let posterOffset = Int(data.u64(96)), supOffset = Int(data.u64(108))
        guard rowOffset >= 128, rowOffset + rowCount * 40 <= data.count,
              titleOffset <= data.count, originalOffset <= data.count, posterOffset <= data.count,
              supOffset + supCount * 4 <= data.count else { throw IndexerError.invalidIndex("section offset outside file") }
        func string(_ offset: Int, _ length: Int) throws -> String {
            guard offset >= 0, length >= 0, offset + length <= data.count,
                  let value = String(data: data[offset..<(offset + length)], encoding: .utf8) else { throw IndexerError.invalidIndex("invalid UTF-8 pool reference") }
            return value
        }
        var rows: [MovieRow] = []; rows.reserveCapacity(rowCount)
        for i in 0..<rowCount {
            let at = rowOffset + i * 40, media = data[at + 36]
            guard media <= 1 else { continue }
            let posterStart = posterOffset + Int(data.u32(at + 30)), posterLen = Int(data.u16(at + 34))
            rows.append(MovieRow(id: data.u32(at), title: try string(titleOffset + Int(data.u32(at + 4)), Int(data.u16(at + 8))), original: try string(originalOffset + Int(data.u32(at + 10)), Int(data.u16(at + 14))), year: data.u16(at + 16), imdbNum: data.u32(at + 18), popularity: data.f32(at + 22), votes: data.u32(at + 26), mediaType: media, rt: data[at + 37], metacritic: data[at + 38], imdb: data[at + 39], posterPath: try string(posterStart, posterLen)))
        }
        var superseded: [UInt64] = []; superseded.reserveCapacity(supCount)
        for i in 0..<supCount { superseded.append(UInt64(data.u32(supOffset + i * 4))) }
        logger.write("INFO", "Decoded index: format=\(version), rows=\(rows.count), superseded=\(superseded.count)")
        return (rows, superseded)
    }

    private func makeItem(_ row: MovieRow, thumbnail: URL?) -> CSSearchableItem {
        let kind = row.mediaType == 0 ? "Movie" : "TV series"
        let content = CSSearchableItemAttributeSet(contentType: .item)
        content.title = row.title; content.displayName = row.title
        let rottenTomatoes = row.rt == 255 ? nil : "\(row.rt >= 60 ? "🍅" : "💥") \(row.rt)% Rotten Tomatoes"
        content.contentDescription = [kind, row.year > 0 ? String(row.year) : nil, row.original.isEmpty || row.original == row.title ? nil : "Original title: \(row.original)", rottenTomatoes].compactMap { $0 }.joined(separator: " · ")
        content.keywords = [kind, "TMDB", row.original].filter { !$0.isEmpty }
        content.identifier = "tmdb:\(row.mediaType == 0 ? "movie" : "tv"): \(row.id)"
        // Match the Tinycast extension activation target. iOS follows Popfeed's Universal Link into
        // the app when installed and falls back to the website otherwise.
        content.url = URL(string: row.mediaType == 0 ? "https://popfeed.social/movie/\(row.id)" : "https://popfeed.social/tv_show/\(row.id)")
        if row.imdbNum > 0 { content.relatedUniqueIdentifier = "tt\(row.imdbNum)" }
        if row.rt != 255 { content.rating = NSNumber(value: Double(row.rt) / 10.0) }
        content.contentType = row.mediaType == 0 ? "public.movie" : "public.tv-show"
        if let thumbnail { content.thumbnailURL = thumbnail }
        return CSSearchableItem(uniqueIdentifier: Self.identifier(for: row.stableKey), domainIdentifier: domain, attributeSet: content)
    }

    private func checkHTTP(_ response: URLResponse, label: String) throws {
        guard let http = response as? HTTPURLResponse else { throw IndexerError.http(label, -1) }
        logger.write("INFO", "HTTP \(label): status=\(http.statusCode), bytes=\(http.expectedContentLength)")
        guard (200..<300).contains(http.statusCode) else { throw IndexerError.http(label, http.statusCode) }
    }

    private static func identifier(for row: MovieRow) -> String { "\(row.mediaType == 0 ? "movie" : "tv")-\(row.id)" }
    private static func identifier(for key: UInt64) -> String { "\(key % 2 == 0 ? "movie" : "tv")-\(key / 2)" }
    private static func assetKey(_ asset: IndexManifest.Asset) -> String { "\(asset.name):\(asset.sha256.lowercased())" }
    private static func datasetFingerprint(manifest: IndexManifest, limit: Int?) -> String {
        let assets = ([manifest.base].compactMap { $0 } + (manifest.deltas ?? [])).map { "\($0.name):\($0.sha256)" }.joined(separator: "|")
        return "v\(manifest.version)|\(assets)|limit=\(limit.map(String.init) ?? "all")|spotlightURL=\(spotlightURLVersion)"
    }
    private static func rankedBefore(_ a: MovieRow, _ b: MovieRow) -> Bool {
        if a.votes != b.votes { return a.votes > b.votes }
        if a.popularity != b.popularity { return a.popularity > b.popularity }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
    private static func errorDetails(_ error: Error) -> String {
        let value = error as NSError
        return "domain=\(value.domain), code=\(value.code), description=\(value.localizedDescription), userInfo=\(value.userInfo)"
    }
}

private enum IndexerError: LocalizedError {
    case missingBase, spotlightUnavailable, fullRebuildRequired, gzip(String), byteCount(expected: UInt64, actual: UInt64), hashMismatch(String), invalidIndex(String), http(String, Int)
    var errorDescription: String? {
        switch self {
        case .missingBase: return "The release manifest has no base TMDB index."
        case .spotlightUnavailable: return "Core Spotlight indexing is unavailable on this device right now."
        case .fullRebuildRequired: return "The TMDB base index changed. Open the app and run a foreground sync to rebuild it."
        case .gzip(let reason): return "Could not expand gzip index: \(reason)"
        case .byteCount(let expected, let actual): return "Index size mismatch (expected \(expected), got \(actual))."
        case .hashMismatch(let name): return "SHA-256 check failed for \(name)."
        case .invalidIndex(let reason): return "Invalid TMDB index: \(reason)."
        case .http(let name, let status): return "HTTP request for \(name) failed with status \(status)."
        }
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24 }
    // Match the published v5 reader ABI: effective section offsets are 32-bit.
    func u64(_ offset: Int) -> UInt64 { UInt64(u32(offset)) }
    func f32(_ offset: Int) -> Float { Float(bitPattern: u32(offset)) }
}
