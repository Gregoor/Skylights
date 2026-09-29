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

private struct MovieRow {
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
    var stableKey: UInt64 { UInt64(id) * 2 + (mediaType == 1 ? 1 : 0) }
}

struct SyncResult { let indexed: Int; let movies: Int; let series: Int; let skippedByLimit: Int }

final class SpotlightIndexer {
    private let logger: DiagnosticLog
    private let session: URLSession
    private let manifestURL = URL(string: "https://github.com/Gregoor/tinycast-tmdb/releases/download/latest/manifest.json")!
    private let batchSize = 250
    private let domain = "com.tinycast.tmdbspotlight.tmdb"

    init(logger: DiagnosticLog) {
        self.logger = logger
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 900
        session = URLSession(configuration: config)
    }

    func sync(limit: Int, progress: @escaping @Sendable (Int, Int, String) -> Void) async throws -> SyncResult {
        logger.write("INFO", "Sync requested; rowLimit=\(limit), batchSize=\(batchSize), iOS=\(UIDevice.current.systemVersion)")
        let spotlightAvailable = CSSearchableIndex.isIndexingAvailable()
        logger.write("INFO", "Core Spotlight indexing available=\(spotlightAvailable)")
        guard spotlightAvailable else { throw IndexerError.spotlightUnavailable }
        progress(0, 1, "Downloading manifest…")
        let (manifestData, response) = try await session.data(from: manifestURL)
        try checkHTTP(response, label: "manifest")
        let manifest = try JSONDecoder().decode(IndexManifest.self, from: manifestData)
        logger.write("INFO", "Manifest v\(manifest.version), generatedAt=\(manifest.generatedAt ?? "unknown"), base=\(manifest.base?.name ?? "nil"), deltas=\(manifest.deltas?.count ?? 0)")
        guard let base = manifest.base else { throw IndexerError.missingBase }
        var rows = Dictionary<UInt64, MovieRow>()
        let baseRows = try await load(asset: base)
        for row in baseRows.rows { rows[row.stableKey] = row }
        logger.write("INFO", "Base loaded: rows=\(baseRows.rows.count), superseded=\(baseRows.superseded.count)")

        for asset in manifest.deltas ?? [] {
            do {
                let delta = try await load(asset: asset)
                let superseded = Set(delta.superseded)
                for key in superseded { rows.removeValue(forKey: key) }
                for row in delta.rows { rows[row.stableKey] = row }
                logger.write("INFO", "Applied \(asset.name): rows=\(delta.rows.count), superseded=\(superseded.count), current=\(rows.count)")
            } catch {
                // Match the existing provider's behavior: a half-published delta must not block usable data.
                logger.write("WARN", "Skipping unavailable delta \(asset.name): \(String(reflecting: error))")
            }
        }

        let ordered = rows.values.sorted { a, b in
            if a.votes != b.votes { return a.votes > b.votes }
            if a.popularity != b.popularity { return a.popularity > b.popularity }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        let selected = Array(ordered.prefix(limit))
        logger.write("INFO", "Prepared Spotlight set: available=\(ordered.count), selected=\(selected.count), omittedByLimit=\(max(0, ordered.count - selected.count))")
        progress(0, selected.count, "Preparing \(selected.count.formatted()) titles…")

        let index = CSSearchableIndex.default()
        do { try await index.deleteSearchableItems(withDomainIdentifiers: [domain]); logger.write("INFO", "Cleared previous app-owned Spotlight domain \(domain)") }
        catch { logger.write("WARN", "Could not clear previous Spotlight domain: \(String(reflecting: error)); continuing with upsert") }

        var submitted = 0
        var indexedMovies = 0
        var indexedSeries = 0
        for start in stride(from: 0, to: selected.count, by: batchSize) {
            try Task.checkCancellation()
            let end = min(start + batchSize, selected.count)
            let items = selected[start..<end].map(makeItem)
            let began = Date()
            do {
                try await index.indexSearchableItems(items)
                submitted += items.count
                indexedMovies += selected[start..<end].filter { $0.mediaType == 0 }.count
                indexedSeries += selected[start..<end].filter { $0.mediaType == 1 }.count
                let elapsed = Int(Date().timeIntervalSince(began) * 1000)
                logger.write("INFO", "Spotlight batch accepted: \(start + 1)-\(end)/\(selected.count), elapsedMs=\(elapsed)")
            } catch {
                logger.write("ERROR", "Spotlight batch rejected: range=\(start + 1)-\(end), submittedBefore=\(submitted), error=\(Self.errorDetails(error))")
                throw error
            }
            progress(end, selected.count, "Submitted \(end.formatted()) of \(selected.count.formatted()) titles…")
        }
        logger.write("INFO", "Spotlight sync finished: submitted=\(submitted), movies=\(indexedMovies), series=\(indexedSeries)")
        return SyncResult(indexed: submitted, movies: indexedMovies, series: indexedSeries, skippedByLimit: max(0, ordered.count - selected.count))
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
        let inflateCode = packedURL.path.withCString { source in
            expandedURL.path.withCString { target in
                tmdb_gzip_file(source, target, &errorBuffer, errorBuffer.count)
            }
        }
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
        let rowCount = Int(data.u32(12))
        let supCount = Int(data.u32(104))
        let rowOffset = Int(data.u64(36))
        let titleOffset = Int(data.u64(80))
        let originalOffset = Int(data.u64(88))
        let posterOffset = Int(data.u64(96))
        let supOffset = Int(data.u64(108))
        guard rowOffset >= 128, rowOffset + rowCount * 40 <= data.count,
              titleOffset <= data.count, originalOffset <= data.count, posterOffset <= data.count,
              supOffset + supCount * 4 <= data.count else { throw IndexerError.invalidIndex("section offset outside file") }
        func string(_ offset: Int, _ length: Int) throws -> String {
            guard offset >= 0, length >= 0, offset + length <= data.count,
                  let value = String(data: data[offset..<(offset + length)], encoding: .utf8) else { throw IndexerError.invalidIndex("invalid UTF-8 pool reference") }
            return value
        }
        var rows: [MovieRow] = []
        rows.reserveCapacity(rowCount)
        for i in 0..<rowCount {
            let at = rowOffset + i * 40
            let titleStart = titleOffset + Int(data.u32(at + 4))
            let titleLen = Int(data.u16(at + 8))
            let origStart = originalOffset + Int(data.u32(at + 10))
            let origLen = Int(data.u16(at + 14))
            let media = data[at + 36]
            guard media <= 1 else { continue }
            rows.append(MovieRow(id: data.u32(at), title: try string(titleStart, titleLen), original: try string(origStart, origLen), year: data.u16(at + 16), imdbNum: data.u32(at + 18), popularity: data.f32(at + 22), votes: data.u32(at + 26), mediaType: media, rt: data[at + 37], metacritic: data[at + 38], imdb: data[at + 39]))
        }
        var superseded: [UInt64] = []
        superseded.reserveCapacity(supCount)
        for i in 0..<supCount { superseded.append(UInt64(data.u32(supOffset + i * 4))) }
        logger.write("INFO", "Decoded index: format=\(version), rows=\(rows.count), superseded=\(superseded.count)")
        return (rows, superseded)
    }

    private func makeItem(_ row: MovieRow) -> CSSearchableItem {
        let kind = row.mediaType == 0 ? "Movie" : "TV series"
        let content = CSSearchableItemAttributeSet(contentType: .item)
        content.title = row.title
        content.displayName = row.title
        content.contentDescription = [kind, row.year > 0 ? String(row.year) : nil, row.original.isEmpty || row.original == row.title ? nil : "Original title: \(row.original)"].compactMap { $0 }.joined(separator: " · ")
        content.keywords = [kind, "TMDB", row.original].filter { !$0.isEmpty }
        content.identifier = "tmdb:\(row.mediaType == 0 ? "movie" : "tv"): \(row.id)"
        content.url = URL(string: row.mediaType == 0 ? "https://www.themoviedb.org/movie/\(row.id)" : "https://www.themoviedb.org/tv/\(row.id)")
        if row.imdbNum > 0 { content.relatedUniqueIdentifier = "tt\(row.imdbNum)" }
        if row.rt != 255 { content.rating = NSNumber(value: Double(row.rt) / 10.0) }
        content.contentType = row.mediaType == 0 ? "public.movie" : "public.tv-show"
        let unique = "\(row.mediaType == 0 ? "movie" : "tv")-\(row.id)"
        return CSSearchableItem(uniqueIdentifier: unique, domainIdentifier: domain, attributeSet: content)
    }

    private func checkHTTP(_ response: URLResponse, label: String) throws {
        guard let http = response as? HTTPURLResponse else { throw IndexerError.http(label, -1) }
        logger.write("INFO", "HTTP \(label): status=\(http.statusCode), bytes=\(http.expectedContentLength)")
        guard (200..<300).contains(http.statusCode) else { throw IndexerError.http(label, http.statusCode) }
    }

    private static func errorDetails(_ error: Error) -> String {
        let value = error as NSError
        return "domain=\(value.domain), code=\(value.code), description=\(value.localizedDescription), userInfo=\(value.userInfo)"
    }
}

private enum IndexerError: LocalizedError {
    case missingBase, spotlightUnavailable, gzip(String), byteCount(expected: UInt64, actual: UInt64), hashMismatch(String), invalidIndex(String), http(String, Int)
    var errorDescription: String? {
        switch self {
        case .missingBase: return "The release manifest has no base TMDB index."
        case .spotlightUnavailable: return "Core Spotlight indexing is unavailable on this device right now."
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
    func u64(_ offset: Int) -> UInt64 { UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32 }
    func f32(_ offset: Int) -> Float { Float(bitPattern: u32(offset)) }
}
