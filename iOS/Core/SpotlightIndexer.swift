import CoreSpotlight
import CoreImage
import CryptoKit
import Foundation
import Combine
#if os(macOS)
import AppIntents
#endif
#if canImport(UIKit)
import UIKit
typealias SpotlightPlatformImage = UIImage
#else
import AppKit
typealias SpotlightPlatformImage = NSImage
#endif

private struct IndexManifest: Decodable {
    struct Asset: Decodable { let name: String; let bytes: UInt64; let sha256: String }
    let version: Int
    let generatedAt: String?
    let base: Asset?
    let deltas: [Asset]?
    let spotlightBase: Asset?
    let spotlightDeltas: [Asset]?
}

private struct SpotlightStreamEnvelope: Decodable {
    struct Operation: Decodable { let id: String; let row: MovieRow? }
    let sequence: Int
    let operations: [Operation]
}

private struct SpotlightStreamState: Codable {
    var baseSHA = ""
    var baseComplete = false
    var contentVersion: Int?
    var rankingVersion: Int?
    var appliedDeltas: Set<String> = []
    var pendingSHA: String?
    var nextSequence = 0
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
    let seasonCount: UInt16
    var stableKey: UInt64 { UInt64(id) * 2 + (mediaType == 1 ? 1 : 0) }
}

struct SyncResult { let indexed: Int; let movies: Int; let series: Int; let skippedByLimit: Int; let incremental: Bool }

enum PosterThumbnailService {
    enum Size: String { case square, portrait }
    private static let endpoint = URL(string: "https://skylights-posters.watware.workers.dev/v1/poster")!

    static func url(posterPath: String, size: Size) -> URL? {
        guard !posterPath.isEmpty,
              let source = URL(string: "https://image.tmdb.org/t/p/w185\(posterPath)"),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "url", value: source.absoluteString),
            URLQueryItem(name: "size", value: size.rawValue),
        ]
        return components.url
    }

    static func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 45)
        request.setValue("image/jpeg", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"])
        }
        return (data, http)
    }
}

/// Shares already-decoded full posters between search rows and the detail page.
enum PosterImageMemoryCache {
    private static let images = NSCache<NSURL, SpotlightPlatformImage>()

    static func image(for url: URL) -> SpotlightPlatformImage? {
        if let image = images.object(forKey: url as NSURL) { return image }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataDontLoad)
        request.setValue("image/jpeg", forHTTPHeaderField: "Accept")
        guard let data = URLCache.shared.cachedResponse(for: request)?.data,
              let image = SpotlightPlatformImage(data: data) else { return nil }
        insert(image, for: url)
        return image
    }

    static func insert(_ image: SpotlightPlatformImage, for url: URL) {
        images.setObject(image, forKey: url as NSURL)
    }
}

#if os(macOS)
/// App Intents entity companion for Core Spotlight entries. macOS 27 currently fails to surface
/// some CSSearchableItems in global Spotlight unless they carry App Intents entity metadata.
struct SkylightsTitleEntity: IndexedEntity, Codable, Hashable {
    typealias ID = String

    private enum CodingKeys: String, CodingKey {
        case id, tmdbID, mediaType, title, year, rottenTomatoesScore, seasonCount
    }

    let id: String
    let tmdbID: Int
    let mediaType: Int
    let title: String
    let year: Int
    let rottenTomatoesScore: Int?
    let seasonCount: Int

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        tmdbID = try values.decode(Int.self, forKey: .tmdbID)
        mediaType = try values.decode(Int.self, forKey: .mediaType)
        title = try values.decode(String.self, forKey: .title)
        year = try values.decode(Int.self, forKey: .year)
        rottenTomatoesScore = try values.decodeIfPresent(Int.self, forKey: .rottenTomatoesScore)
        seasonCount = try values.decodeIfPresent(Int.self, forKey: .seasonCount) ?? 0
    }

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Film or TV series")
    static var defaultQuery = SkylightsTitleEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        let kind = mediaType == 0 ? "Film" : "TV series"
        let yearText = year > 0 ? String(year) : nil
        let seasonsText = mediaType == 1 && seasonCount > 0 ? "\(seasonCount) seasons" : nil
        let scoreText = rottenTomatoesScore.map { "\($0 >= 60 ? "🍅" : "💥") \($0)%" }
        let subtitle = [kind, yearText, seasonsText, scoreText].compactMap { $0 }.joined(separator: " · ")
        return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let kind = mediaType == 0 ? "Movie" : "TV series"
        let seasonsText = mediaType == 1 && seasonCount > 0 ? "\(seasonCount) seasons" : nil
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = title
        attributes.displayName = title
        attributes.contentType = mediaType == 0 ? "public.movie" : "public.tv-show"
        attributes.contentDescription = [kind, year > 0 ? String(year) : nil, seasonsText, rottenTomatoesScore.map { "\($0 >= 60 ? "🍅" : "💥") \($0)%" }].compactMap { $0 }.joined(separator: " · ")
        attributes.keywords = [kind, "TMDB", seasonsText].compactMap { $0 }
        return attributes
    }

    fileprivate init(row: MovieRow) {
        id = "\(row.mediaType == 0 ? "movie" : "tv")-\(row.id)"
        tmdbID = Int(row.id)
        mediaType = Int(row.mediaType)
        title = row.title
        year = Int(row.year)
        rottenTomatoesScore = row.rt == 255 ? nil : Int(row.rt)
        seasonCount = Int(row.seasonCount)
    }

    init(title: SpotlightTitle) {
        id = title.id
        tmdbID = Int(title.tmdbID)
        mediaType = Int(title.mediaType)
        self.title = title.title
        year = Int(title.year)
        rottenTomatoesScore = title.rottenTomatoesScore.map(Int.init)
        seasonCount = Int(title.seasonCount)
    }
}

struct SkylightsTitleEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SkylightsTitleEntity] {
        let logger = DiagnosticLog()
        var entities: [SkylightsTitleEntity] = []
        entities.reserveCapacity(identifiers.count)
        for identifier in identifiers {
            let pieces = identifier.split(separator: "-", omittingEmptySubsequences: false)
            guard pieces.count == 2,
                  let tmdbID = UInt32(pieces[1]) else { continue }
            let mediaType: UInt8
            switch pieces[0] {
            case "movie": mediaType = 0
            case "tv": mediaType = 1
            default: continue
            }
            if let title = await SpotlightIndexer.indexedTitle(identifier: identifier, query: "TMDB \(tmdbID)", logger: logger) {
                entities.append(SkylightsTitleEntity(title: title))
            }
        }
        return entities
    }
}

struct OpenSkylightsTitleIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Film or TV Series"

    @Parameter(title: "Title")
    var target: SkylightsTitleEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let logger = DiagnosticLog()
        logger.write("INFO", "Core Spotlight OpenIntent performed: id=\(target.id)")
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            logger.write("ERROR", "Open intent ran without the Skylights AppDelegate; id=\(target.id)")
            return .result()
        }
        appDelegate.handleSearchIntent(self)
        return .result()
    }
}
#endif

struct SpotlightTitle: Identifiable, Hashable {
    let mediaType: UInt8
    let tmdbID: UInt32
    let title: String
    let year: UInt16
    let posterPath: String
    var rottenTomatoesScore: UInt8? = nil
    var voteCount: UInt32 = 0
    var blurredPosterData: Data? = nil
    var spotlightQuery: String? = nil
    var seasonCount: UInt16 = 0
    var posterURLOverride: URL? = nil
    var id: String { "\(mediaType == 0 ? "movie" : "tv")-\(tmdbID)" }
    var isMovie: Bool { mediaType == 0 }
    var posterURL: URL? {
        if let posterURLOverride { return posterURLOverride }
        guard !posterPath.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(posterPath)")
    }
    var miniPosterURL: URL? {
        if let posterURLOverride, posterURLOverride.host != "image.tmdb.org" { return posterURLOverride }
        guard !posterPath.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w185\(posterPath)")
    }
    private var supportsTMDBPosterThumbnail: Bool {
        guard let posterURLOverride else { return true }
        return posterURLOverride.host == "image.tmdb.org" && posterURLOverride.path.contains("/t/p/")
    }
    var blurredPosterURL: URL? { supportsTMDBPosterThumbnail ? PosterThumbnailService.url(posterPath: posterPath, size: .square) : nil }
    var detailBlurredPosterURL: URL? { supportsTMDBPosterThumbnail ? PosterThumbnailService.url(posterPath: posterPath, size: .portrait) : nil }
}

/// Converts Core Spotlight's platform-delivered activity into the same detail route on iOS and
/// macOS. Each app delegate owns one router so duplicate delivery through both lifecycle hooks is
/// collapsed while parsing and metadata extraction stay identical across platforms.
@MainActor
final class SpotlightActivityRouter {
    private let logger: DiagnosticLog
    private var lastIdentifier: String?
    private var lastDelivery = Date.distantPast

    init(logger: DiagnosticLog) {
        self.logger = logger
    }

    func title(from activity: NSUserActivity) -> SpotlightTitle? {
        logger.write("INFO", "Received Core Spotlight activity: type=\(activity.activityType), info=\(String(describing: activity.userInfo))")
        guard activity.activityType == CSSearchableItemActionType else { return nil }
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let separator = identifier.firstIndex(of: "-"),
              separator > identifier.startIndex,
              let tmdbID = UInt32(identifier[identifier.index(after: separator)...]) else {
            logger.write("ERROR", "Core Spotlight activity is missing a valid indexed item identifier")
            return nil
        }

        guard lastIdentifier != identifier || Date().timeIntervalSince(lastDelivery) >= 2 else {
            logger.write("INFO", "Ignoring duplicate Core Spotlight activity: id=\(identifier)")
            return nil
        }

        let kind = String(identifier[..<separator])
        guard kind == "movie" || kind == "tv" else {
            logger.write("ERROR", "Unsupported Core Spotlight identifier: \(identifier)")
            return nil
        }

        let attributes = activity.contentAttributeSet
        let title = attributes?.title ?? ""
        let parts = attributes?.contentDescription?.components(separatedBy: " · ") ?? []
        let year = parts.compactMap(UInt16.init).first ?? 0
        let seasonCount = parts.first(where: { $0.hasSuffix(" seasons") })
            .flatMap { UInt16($0.dropLast(" seasons".count)) } ?? 0
        let thumbnail = attributes?.thumbnailData
        let searchQuery = activity.userInfo?["kCSSearchQueryString"] as? String
        lastIdentifier = identifier
        lastDelivery = Date()
        logger.write("INFO", "Routing Core Spotlight item to detail: id=\(identifier), titleAvailable=\(!title.isEmpty), year=\(year), thumbnailBytes=\(thumbnail?.count ?? 0)")
        return SpotlightTitle(
            mediaType: kind == "movie" ? 0 : 1,
            tmdbID: tmdbID,
            title: title,
            year: year,
            posterPath: "",
            blurredPosterData: thumbnail,
            spotlightQuery: searchQuery,
            seasonCount: seasonCount
        )
    }
}

/// Shared app state and routing used by both UIApplicationDelegate and NSApplicationDelegate.
/// The concrete delegates only bridge operating-system callbacks and background-task APIs.
@MainActor
class SkylightsAppController: NSObject, ObservableObject {
    let logger = DiagnosticLog()
    @Published var selectedTitle: SpotlightTitle?
    private lazy var spotlightActivityRouter = SpotlightActivityRouter(logger: logger)

    func handleSearchActivity(_ activity: NSUserActivity) {
        guard let title = spotlightActivityRouter.title(from: activity) else { return }
        openTitle(title, source: "Core Spotlight")
    }

    func openTitle(_ title: SpotlightTitle, source: String) {
        logger.write("INFO", "Opening detail from \(source): id=\(title.id), titleAvailable=\(!title.title.isEmpty)")
        selectedTitle = title
    }
}

final class SpotlightIndexer {
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let logger: DiagnosticLog
    private let session: URLSession
    private let manifestURL = URL(string: "https://github.com/Gregoor/tinycast-tmdb/releases/download/latest/manifest.json")!
    private let batchSize = 250
    private let domain = "com.tinycast.tmdbspotlight.tmdb"
    private let checkpointKey = "spotlight.sync.checkpoint"
    private let streamStateKey = "spotlight.stream.state"
    private var loggedCategoryIcons: Set<UInt8> = []
    private var cachedMacSpotlightIcon: Data?
    private static let spotlightURLVersion = 3
    private static let spotlightContentVersion = 7
#if os(macOS)
    private static let spotlightRankingVersion = 12 // Refreshes inline bundle icons and Spotlight-window activation.
#else
    private static let spotlightRankingVersion = 5
#endif
    private struct Checkpoint: Codable { let dataset: String; let nextIndex: Int }


    init(logger: DiagnosticLog) {
        self.logger = logger
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 900
        session = URLSession(configuration: config)
    }

    static func title(mediaType: UInt8, tmdbID: UInt32, logger: DiagnosticLog) async -> SpotlightTitle? {
        let kind = mediaType == 0 ? "movie" : "tv"
        return await indexedTitle(identifier: "\(kind)-\(tmdbID)", query: "TMDB \(tmdbID)", logger: logger)
    }

    /// Looks up the tapped result in Core Spotlight itself. Native Spotlight activities provide
    /// only an identifier and the original query, so this gets visible metadata without waiting
    /// for the much larger local catalog snapshot to decode.
    static func indexedTitle(identifier: String, query: String, logger: DiagnosticLog) async -> SpotlightTitle? {
        let started = Date()
        let context = CSUserQueryContext()
        context.fetchAttributes = ["title", "contentDescription", "contentType", "rating", "thumbnailData", "keywords"]
        context.maxResultCount = 100
        context.maxSuggestionCount = 0
        context.enableRankedResults = true
        let userQuery = CSUserQuery(userQueryString: query, userQueryContext: context)
        var hits = 0
        do {
            for try await response in userQuery.responses {
                guard !Task.isCancelled else { break }
                guard case .item(let item) = response else { continue }
                hits += 1
                let searchableItem = item.item
                guard searchableItem.uniqueIdentifier == identifier,
                      let title = searchableItem.attributeSet.title else { continue }
                let parts = searchableItem.attributeSet.contentDescription?.components(separatedBy: " · ") ?? []
                let year = parts.compactMap(UInt16.init).first ?? 0
                let mediaType: UInt8 = identifier.hasPrefix("movie-") ? 0 : 1
                let rating = searchableItem.attributeSet.rating.map { UInt8(max(0, min(100, ($0.doubleValue * 10).rounded()))) }
                let descriptionScore = parts.first(where: { $0.contains("%") }).flatMap { part -> UInt8? in
                    let digits = String(part.filter(\.isNumber))
                    return UInt8(digits)
                }
                let score = rating ?? descriptionScore
                guard let recordID = identifier.split(separator: "-").last,
                      let tmdbID = UInt32(recordID) else { continue }
                logger.write("INFO", "Resolved metadata from Core Spotlight: id=\(identifier), title=\(title), year=\(year), rating=\(score.map(String.init) ?? "—"), thumbnailBytes=\(searchableItem.attributeSet.thumbnailData?.count ?? 0), elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")
                let thumbnail = searchableItem.attributeSet.thumbnailData
                let keywords = searchableItem.attributeSet.keywords ?? []
                return SpotlightTitle(mediaType: mediaType, tmdbID: tmdbID, title: title, year: year, posterPath: Self.keywordValue("poster", in: keywords) ?? "", rottenTomatoesScore: score, voteCount: UInt32(Self.keywordValue("votes", in: keywords) ?? "0") ?? 0, blurredPosterData: thumbnail, seasonCount: UInt16(Self.keywordValue("seasons", in: keywords) ?? "0") ?? 0)
            }
        } catch is CancellationError {
            userQuery.cancel()
        } catch {
            logger.write("ERROR", "Core Spotlight detail query failed: id=\(identifier), queryLength=\(query.count), error=\(String(reflecting: error))")
        }
        userQuery.cancel()
        logger.write("WARN", "Core Spotlight detail metadata not found: id=\(identifier), queryLength=\(query.count), hits=\(hits), elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")
        return nil
    }

    /// Creates a static, full-poster blur so the UI only animates opacity, not a live blur filter.
    static func preblurredPoster(from data: Data) -> Data? {
        guard let input = CIImage(data: data),
              let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(90, forKey: kCIInputRadiusKey)
        guard let blurred = filter.outputImage?.cropped(to: input.extent),
              let image = imageContext.createCGImage(blurred, from: input.extent) else { return nil }
        #if canImport(UIKit)
        return SpotlightPlatformImage(cgImage: image).jpegData(compressionQuality: 0.82)
        #else
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        #endif
    }

    /// Applies manifest row streams to the app's Core Spotlight domain.
    func sync(limit: Int?, incrementalOnly: Bool = false, progress: @escaping @Sendable (Int, Int, String) -> Void) async throws -> SyncResult {
        logger.write("INFO", "Sync requested; rowLimit=\(limit.map(String.init) ?? "all"), incrementalOnly=\(incrementalOnly), batchSize=\(batchSize), OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        guard CSSearchableIndex.isIndexingAvailable() else { throw IndexerError.spotlightUnavailable }
        progress(0, 1_000_000, "Checking TMDB release…")
        let (manifestData, response) = try await session.data(from: manifestURL)
        try checkHTTP(response, label: "manifest")
        let manifest = try JSONDecoder().decode(IndexManifest.self, from: manifestData)
        guard let base = manifest.base else { throw IndexerError.missingBase }
        guard let streamBase = manifest.spotlightBase else {
            return try await syncMonolithicBase(base, incrementalOnly: incrementalOnly, progress: progress)
        }
        return try await syncSpotlightStream(manifest: manifest, base: base, streamBase: streamBase, incrementalOnly: incrementalOnly, progress: progress)
    }

    /// Older release manifests publish the v5 TMDB index without a Spotlight operation stream.
    /// Index those rows directly; `makeItem` carries the poster path in Spotlight keywords so
    /// result rows can fetch their artwork on demand.
    private func syncMonolithicBase(_ base: IndexManifest.Asset, incrementalOnly: Bool, progress: @escaping @Sendable (Int, Int, String) -> Void) async throws -> SyncResult {
        var state = UserDefaults.standard.data(forKey: streamStateKey).flatMap { try? PropertyListDecoder().decode(SpotlightStreamState.self, from: $0) } ?? SpotlightStreamState()
        if state.baseSHA == base.sha256,
           state.contentVersion == Self.spotlightContentVersion,
           state.rankingVersion == Self.spotlightRankingVersion,
           state.baseComplete {
            progress(1, 1, "Spotlight is already current.")
            return SyncResult(indexed: 0, movies: 0, series: 0, skippedByLimit: 0, incremental: true)
        }
        guard !incrementalOnly else { throw IndexerError.fullRebuildRequired }

        let resuming = state.baseSHA == base.sha256
            && state.contentVersion == Self.spotlightContentVersion
            && state.rankingVersion == Self.spotlightRankingVersion
            && state.pendingSHA == base.sha256
        let index = CSSearchableIndex.default()
        if !resuming {
            try await index.deleteSearchableItems(withDomainIdentifiers: [domain])
            state = SpotlightStreamState()
            state.baseSHA = base.sha256
            state.contentVersion = Self.spotlightContentVersion
            state.rankingVersion = Self.spotlightRankingVersion
            state.pendingSHA = base.sha256
            saveStreamState(state)
        }

        progress(0, 1, "Downloading TMDB base index…")
        let url = URL(string: base.name + ".gz", relativeTo: manifestURL.deletingLastPathComponent())!
        let (packedURL, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: packedURL) }
        try checkHTTP(response, label: base.name + ".gz")
        let expandedURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".index")
        defer { try? FileManager.default.removeItem(at: expandedURL) }
        var errorBuffer = [CChar](repeating: 0, count: 256)
        let inflateCode = packedURL.path.withCString { source in
            expandedURL.path.withCString { target in tmdb_gzip_file(source, target, &errorBuffer, errorBuffer.count) }
        }
        guard inflateCode == 0 else { throw IndexerError.gzip(String(cString: errorBuffer)) }
        let expandedBytes = (try? FileManager.default.attributesOfItem(atPath: expandedURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard expandedBytes == base.bytes else { throw IndexerError.byteCount(expected: base.bytes, actual: expandedBytes) }
        let data = try Data(contentsOf: expandedURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == base.sha256.lowercased() else { throw IndexerError.hashMismatch(base.name) }
        let rows = try decodeBase(data)
        logger.write("INFO", "Verified monolithic base index: rows=\(rows.count), bytes=\(expandedBytes), sha256=ok")

        let start = min(state.nextSequence, rows.count)
        var movies = 0
        var series = 0
        for lower in stride(from: start, to: rows.count, by: batchSize) {
            try Task.checkCancellation()
            let upper = min(rows.count, lower + batchSize)
            let batch = Array(rows[lower..<upper])
            try await index.indexSearchableItems(batch.map { makeItem($0) })
            movies += batch.filter { $0.mediaType == 0 }.count
            series += batch.filter { $0.mediaType == 1 }.count
            state.nextSequence = upper
            saveStreamState(state)
            progress(upper, rows.count, "Indexing \(upper.formatted()) of \(rows.count.formatted()) titles…")
        }
        state.baseComplete = true
        state.pendingSHA = nil
        state.nextSequence = 0
        saveStreamState(state)
        logger.write("INFO", "Monolithic base sync complete: indexed=\(rows.count), movies=\(movies), series=\(series)")
        return SyncResult(indexed: rows.count, movies: movies, series: series, skippedByLimit: 0, incremental: false)
    }

    private func decodeBase(_ data: Data) throws -> [MovieRow] {
        guard data.count >= 128, String(data: data.prefix(8), encoding: .ascii) == "TCIDX001" else {
            throw IndexerError.invalidIndex("bad header/magic")
        }
        let version = data.u32(8)
        let rowRecordBytes: Int
        switch version {
        case 5: rowRecordBytes = 40
        case 7: rowRecordBytes = 42
        default: throw IndexerError.invalidIndex("unsupported format version \(version)")
        }
        let rowCount = Int(data.u32(12))
        let rowOffset = Int(data.u64(36))
        let titleOffset = Int(data.u64(80))
        let originalOffset = Int(data.u64(88))
        let posterOffset = Int(data.u64(96))
        guard rowOffset >= 128, rowOffset + rowCount * rowRecordBytes <= data.count,
              titleOffset <= data.count, originalOffset <= data.count, posterOffset <= data.count else {
            throw IndexerError.invalidIndex("section offset outside file")
        }
        func string(_ offset: Int, _ length: Int) throws -> String {
            guard offset >= 0, length >= 0, offset + length <= data.count,
                  let value = String(data: data[offset..<(offset + length)], encoding: .utf8) else {
                throw IndexerError.invalidIndex("invalid UTF-8 pool reference")
            }
            return value
        }
        var rows: [MovieRow] = []
        rows.reserveCapacity(rowCount)
        for rowIndex in 0..<rowCount {
            let offset = rowOffset + rowIndex * rowRecordBytes
            let mediaType = data[offset + 36]
            guard mediaType <= 1 else { continue }
            let posterStart = posterOffset + Int(data.u32(offset + 30))
            let posterLength = Int(data.u16(offset + 34))
            rows.append(MovieRow(
                id: data.u32(offset),
                title: try string(titleOffset + Int(data.u32(offset + 4)), Int(data.u16(offset + 8))),
                original: try string(originalOffset + Int(data.u32(offset + 10)), Int(data.u16(offset + 14))),
                year: data.u16(offset + 16),
                imdbNum: data.u32(offset + 18),
                popularity: data.f32(offset + 22),
                votes: data.u32(offset + 26),
                mediaType: mediaType,
                rt: data[offset + 37],
                metacritic: data[offset + 38],
                imdb: data[offset + 39],
                posterPath: try string(posterStart, posterLength),
                seasonCount: version >= 7 ? data.u16(offset + 40) : 0
            ))
        }
        return rows
    }

    private func syncSpotlightStream(manifest: IndexManifest, base: IndexManifest.Asset, streamBase: IndexManifest.Asset, incrementalOnly: Bool, progress: @escaping @Sendable (Int, Int, String) -> Void) async throws -> SyncResult {
        let total = 1_000_000
        var state = UserDefaults.standard.data(forKey: streamStateKey).flatMap { try? PropertyListDecoder().decode(SpotlightStreamState.self, from: $0) } ?? SpotlightStreamState()
        let index = CSSearchableIndex.default()
        let isNewBase = state.baseSHA != base.sha256
        let needsContentRefresh = state.contentVersion != Self.spotlightContentVersion
        let needsRankingRefresh = state.rankingVersion != Self.spotlightRankingVersion
        if isNewBase || needsContentRefresh || needsRankingRefresh {
            guard !incrementalOnly else { throw IndexerError.fullRebuildRequired }
            try await index.deleteSearchableItems(withDomainIdentifiers: [domain])
            state = SpotlightStreamState()
            state.baseSHA = base.sha256
            state.contentVersion = Self.spotlightContentVersion
            state.rankingVersion = Self.spotlightRankingVersion
            saveStreamState(state)
            if needsContentRefresh && !isNewBase {
                logger.write("INFO", "Rebuilding Spotlight items for content metadata version \(Self.spotlightContentVersion)")
            }
            if needsRankingRefresh && !isNewBase {
                logger.write("INFO", "Rebuilding Spotlight items for ranking metadata version \(Self.spotlightRankingVersion)")
            }
        }
        let needsBase = !state.baseComplete
        let assets = (needsBase ? [streamBase] : []) + (manifest.spotlightDeltas ?? []).filter { !state.appliedDeltas.contains(Self.assetKey($0)) }
        let work = max(1, assets.count)
        var submitted = 0
        var movies = 0
        var series = 0
        for (assetIndex, asset) in assets.enumerated() {
            try Task.checkCancellation()
            if state.pendingSHA != asset.sha256 {
                state.pendingSHA = asset.sha256
                state.nextSequence = 0
                saveStreamState(state)
            }
            progress(50_000 + assetIndex * 900_000 / work, total, "Streaming \(asset.name)…")
            let applied = try await applySpotlightStream(asset, state: state)
            state = applied.state
            submitted += applied.count
            movies += applied.movies
            series += applied.series
            if asset.sha256 == streamBase.sha256 { state.baseComplete = true }
            else { state.appliedDeltas.insert(Self.assetKey(asset)) }
            state.pendingSHA = nil
            state.nextSequence = 0
            saveStreamState(state)
        }
        progress(total, total, assets.isEmpty ? "Spotlight is already current." : "Spotlight updates submitted.")
        logger.write("INFO", "Stream sync finished: submitted=\(submitted), deltas=\(state.appliedDeltas.count)")
        return SyncResult(indexed: submitted, movies: movies, series: series, skippedByLimit: 0, incremental: !needsBase)
    }

    private func applySpotlightStream(_ asset: IndexManifest.Asset, state initialState: SpotlightStreamState) async throws -> (count: Int, movies: Int, series: Int, state: SpotlightStreamState) {
        var state = initialState
        let url = URL(string: asset.name, relativeTo: manifestURL.deletingLastPathComponent())!
        let (bytes, response) = try await session.bytes(from: url)
        try checkHTTP(response, label: asset.name)
        var fileHash = SHA256()
        var fileBytes: UInt64 = 0
        var line = [UInt8]()
        var count = 0
        var movies = 0
        var series = 0
        func consume(_ raw: [UInt8]) async throws {
            guard let tab = raw.firstIndex(of: 9) else { throw IndexerError.invalidIndex("stream frame lacks checksum separator") }
            let expected = String(decoding: raw[..<tab], as: UTF8.self)
            let body = Data(raw[(tab + 1)...])
            let actual = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw IndexerError.hashMismatch(asset.name) }
            let frame = try JSONDecoder().decode(SpotlightStreamEnvelope.self, from: body)
            guard frame.sequence >= 0 else { throw IndexerError.invalidIndex("negative stream sequence") }
            guard frame.sequence >= state.nextSequence else { return }
            let removed = frame.operations.filter { $0.row == nil }.map(\.id)
            if !removed.isEmpty { try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: removed) }
            let rows = frame.operations.compactMap(\.row)
            if !rows.isEmpty { try await CSSearchableIndex.default().indexSearchableItems(rows.map { makeItem($0) }) }
            count += rows.count
            movies += rows.filter { $0.mediaType == 0 }.count
            series += rows.filter { $0.mediaType == 1 }.count
            state.nextSequence = frame.sequence + 1
            saveStreamState(state)
        }
        for try await byte in bytes {
            fileHash.update(data: Data([byte]))
            fileBytes += 1
            if byte == 10 {
                if !line.isEmpty { try await consume(line) }
                line.removeAll(keepingCapacity: true)
            } else {
                guard line.count < 4_000_000 else { throw IndexerError.invalidIndex("stream frame exceeds size limit") }
                line.append(byte)
            }
        }
        if !line.isEmpty { try await consume(line) }
        let digest = fileHash.finalize().map { String(format: "%02x", $0) }.joined()
        guard fileBytes == asset.bytes else { throw IndexerError.byteCount(expected: asset.bytes, actual: fileBytes) }
        guard digest == asset.sha256.lowercased() else { throw IndexerError.hashMismatch(asset.name) }
        return (count, movies, series, state)
    }

    private func saveStreamState(_ state: SpotlightStreamState) {
        if let data = try? PropertyListEncoder().encode(state) { UserDefaults.standard.set(data, forKey: streamStateKey) }
    }

    private func makeItem(_ row: MovieRow, thumbnailData: Data? = nil) -> CSSearchableItem {
        let kind = row.mediaType == 0 ? "Movie" : "TV series"
        let content = CSSearchableItemAttributeSet(contentType: .item)
        content.title = row.title; content.displayName = row.title
        content.creator = "Skylights"
        let rottenTomatoes = row.rt == 255 ? nil : "\(row.rt >= 60 ? "🍅" : "💥") \(row.rt)%"
        content.contentDescription = [kind, row.year > 0 ? String(row.year) : nil, row.mediaType == 1 && row.seasonCount > 0 ? "\(row.seasonCount) seasons" : nil, row.original.isEmpty || row.original == row.title ? nil : "Original title: \(row.original)", rottenTomatoes].compactMap { $0 }.joined(separator: " · ")
        content.keywords = [kind, "TMDB", String(row.id), row.original, "poster:\(row.posterPath)", "votes:\(row.votes)", "seasons:\(row.seasonCount)"].filter { !$0.isEmpty }
        content.identifier = "tmdb:\(row.mediaType == 0 ? "movie" : "tv"): \(row.id)"
#if os(iOS)
        content.url = URL(string: row.mediaType == 0 ? "https://popfeed.social/movie/\(row.id)" : "https://popfeed.social/tv_show/\(row.id)")
#else
        content.url = Self.spotlightOpenURL(for: row)
#endif
        if row.imdbNum > 0 { content.relatedUniqueIdentifier = "tt\(row.imdbNum)" }
        if row.rt != 255 { content.rating = NSNumber(value: Double(row.rt) / 10.0) }
        content.contentType = row.mediaType == 0 ? "public.movie" : "public.tv-show"
        content.rankingHint = NSNumber(value: Self.rankingHint(for: row))
        if let thumbnailData {
            content.thumbnailURL = nil
            content.thumbnailData = thumbnailData
        } else {
#if os(macOS)
            if let iconData = categoryIconData(for: row.mediaType) {
                content.thumbnailURL = nil
                content.thumbnailData = iconData
            }
#else
            if let thumbnail = categoryIconURL(for: row.mediaType) {
                content.thumbnailURL = thumbnail
            }
#endif
        }
        return CSSearchableItem(uniqueIdentifier: Self.identifier(for: row.stableKey), domainIdentifier: domain, attributeSet: content)
    }

    private static func spotlightOpenURL(for row: MovieRow) -> URL? {
        var components = URLComponents()
        components.scheme = "skylights"
        components.host = "spotlight"
        components.path = "/\(row.mediaType == 0 ? "movie" : "tv")/\(row.id)"
        components.queryItems = [
            URLQueryItem(name: "title", value: row.title),
            URLQueryItem(name: "year", value: String(row.year)),
            URLQueryItem(name: "score", value: row.rt == 255 ? nil : String(row.rt)),
            URLQueryItem(name: "seasons", value: row.seasonCount > 0 ? String(row.seasonCount) : nil),
            URLQueryItem(name: "poster", value: row.posterPath.isEmpty ? nil : row.posterPath),
            URLQueryItem(name: "votes", value: String(row.votes)),
        ]
        return components.url
    }

    private func categoryIconURL(for mediaType: UInt8) -> URL? {
#if os(macOS)
        let name = "MacAppIcon"
        let fileName = "skylights-app-icon.jpg"
#else
        let name = mediaType == 0 ? "MovieCategory" : "TVCategory"
        let fileName = mediaType == 0 ? "movie-category.jpg" : "tv-category.jpg"
#endif
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TMDBSpotlightCategoryIcons-v182", isDirectory: true)
        let url = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            if loggedCategoryIcons.insert(mediaType).inserted {
                let bytes = (try? Data(contentsOf: url).count) ?? 0
            logger.write("INFO", "Using Spotlight item thumbnail file: type=\(name), file=\(fileName), readableBytes=\(bytes), exists=\(bytes > 0)")
            }
            return url
        }
        #if canImport(UIKit)
        guard let source = SpotlightPlatformImage(named: name) else {
            logger.write("WARN", "Could not load Spotlight thumbnail asset: \(name)")
            return nil
        }
        let size = CGSize(width: 180, height: 180)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { context in
            context.cgContext.interpolationQuality = .high
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        let data = rendered.jpegData(compressionQuality: 0.78)
        #else
        let data: Data?
        if let source = NSApplication.shared.applicationIconImage ?? NSImage(named: name) {
            let iconSize = NSSize(width: 64, height: 64)
            let smallIcon = NSImage(size: iconSize)
            smallIcon.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: NSRect(origin: .zero, size: iconSize), from: .zero, operation: .copy, fraction: 1)
            smallIcon.unlockFocus()
            if let cgImage = smallIcon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let rep = NSBitmapImageRep(cgImage: cgImage)
                data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.45])
            } else {
                data = nil
            }
        } else {
            data = nil
        }
        #endif
        guard let data else {
            logger.write("WARN", "Could not encode Spotlight thumbnail: \(name)")
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            logger.write("INFO", "Prepared Spotlight item thumbnail: type=\(name), bytes=\(data.count)")
            loggedCategoryIcons.insert(mediaType)
            return url
        } catch {
            logger.write("WARN", "Could not prepare Spotlight category icon \(name): \(Self.errorDetails(error))")
            return nil
        }
    }

#if os(macOS)
    private func categoryIconData(for mediaType: UInt8) -> Data? {
        if let cachedMacSpotlightIcon { return cachedMacSpotlightIcon }
        guard let url = categoryIconURL(for: mediaType),
              let data = try? Data(contentsOf: url) else {
            logger.write("WARN", "Could not read inline Spotlight app icon for type=\(mediaType)")
            return nil
        }
        cachedMacSpotlightIcon = data
        logger.write("INFO", "Prepared inline Spotlight app icon: bytes=\(data.count)")
        return data
    }
#endif

    private func checkHTTP(_ response: URLResponse, label: String) throws {
        guard let http = response as? HTTPURLResponse else { throw IndexerError.http(label, -1) }
        logger.write("INFO", "HTTP \(label): status=\(http.statusCode), bytes=\(http.expectedContentLength)")
        guard (200..<300).contains(http.statusCode) else { throw IndexerError.http(label, http.statusCode) }
    }

    static func keywordValue(_ name: String, in keywords: [String]) -> String? {
        keywords.first(where: { $0.hasPrefix("\(name):") }).map { String($0.dropFirst(name.count + 1)) }
    }

    private static func identifier(for row: MovieRow) -> String { "\(row.mediaType == 0 ? "movie" : "tv")-\(row.id)" }
    private static func identifier(for key: UInt64) -> String { "\(key % 2 == 0 ? "movie" : "tv")-\(key / 2)" }
    private static func assetKey(_ asset: IndexManifest.Asset) -> String { "\(asset.name):\(asset.sha256.lowercased())" }
    private static func datasetFingerprint(manifest: IndexManifest, limit: Int?) -> String {
        let assets = ([manifest.base].compactMap { $0 } + (manifest.deltas ?? [])).map { "\($0.name):\($0.sha256)" }.joined(separator: "|")
        return "v\(manifest.version)|\(assets)|limit=\(limit.map(String.init) ?? "all")|spotlightURL=\(spotlightURLVersion)|spotlightRanking=\(Self.spotlightRankingVersion)|spotlightContent=\(spotlightContentVersion)"
    }
    private static func rankedBefore(_ a: MovieRow, _ b: MovieRow) -> Bool {
        if a.votes != b.votes { return a.votes > b.votes }
        if a.popularity != b.popularity { return a.popularity > b.popularity }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
    private static func rankingHint(for row: MovieRow) -> Double {
        SpotlightRanking.hint(
            year: Int(row.year),
            voteCount: Int(row.votes),
            rottenTomatoesScore: row.rt == 255 ? nil : Int(row.rt)
        )
    }
    private static func errorDetails(_ error: Error) -> String {
        let value = error as NSError
        return "domain=\(value.domain), code=\(value.code), description=\(value.localizedDescription), userInfo=\(value.userInfo)"
    }
}

enum IndexerError: LocalizedError {
    case missingBase, missingSpotlightStream, spotlightUnavailable, fullRebuildRequired, gzip(String), byteCount(expected: UInt64, actual: UInt64), hashMismatch(String), invalidIndex(String), http(String, Int)
    var errorDescription: String? {
        switch self {
        case .missingBase: return "The release manifest has no base TMDB index."
        case .missingSpotlightStream: return "The release manifest has no Spotlight stream."
        case .spotlightUnavailable: return "Core Spotlight indexing is unavailable on this device right now."
        case .fullRebuildRequired: return "A foreground full sync is required to initialize or rebuild the Spotlight index."
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
