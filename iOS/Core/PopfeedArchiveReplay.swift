import Foundation
import libzstd

struct PopfeedArchiveEvent {
    let sequence: UInt64
    let kind: UInt8
    let did: String
    let collection: String
    let rkey: String
    let recordCBOR: Data
}

/// Jetstream v2 snapshot/replay client. It downloads only planner-selected blocks;
/// segment-mode plans use getSegment byte ranges for the header and block index,
/// then request matching frames individually instead of downloading a whole segment.
final class PopfeedArchiveReplay {
    private let logger: DiagnosticLog
    private let host = "jetstream.us-east.bsky.network"
    private let maximumUncompressedBlock = 128 * 1024 * 1024

    init(logger: DiagnosticLog) {
        self.logger = logger
    }

    func catchUp(
        did: String,
        apiKey: String,
        after initialCursor: UInt64,
        onEvents: @MainActor ([PopfeedArchiveEvent]) async throws -> Void,
        onCursor: @MainActor (UInt64) -> Void,
        onProgress: @MainActor (Double, String) -> Void
    ) async throws -> UInt64 {
        var cursor = initialCursor
        var pinnedTip: UInt64?
        var pageNumber = 0

        repeat {
            try Task.checkCancellation()
            let plan = try await makePlan(did: did, apiKey: apiKey, after: cursor, before: pinnedTip)
            pageNumber += 1
            if pinnedTip == nil {
                pinnedTip = plan.sealedTip
                logger.write("INFO", "Popfeed archive replay planned; sealedTip=\(plan.sealedTip), afterSeq=\(cursor), segmentCount=\(plan.segments.count)")
            }
            guard let tip = pinnedTip else { throw ReplayError.invalidPlan("missing sealed archive tip") }
            let pageStart = cursor
            guard plan.plannedThrough >= pageStart else {
                throw ReplayError.invalidPlan("planner made no progress at cursor \(cursor)")
            }

            var work: [(String, Int)] = []
            for segment in plan.segments {
                let indices: [Int]
                switch segment.mode {
                case "blocks":
                    indices = try Self.expand(segment.blocks ?? [])
                case "segment":
                    indices = try await blockIndices(
                        segment: segment.name,
                        apiKey: apiKey,
                        after: cursor,
                        through: plan.plannedThrough
                    )
                default:
                    throw ReplayError.invalidPlan("unknown segment mode \(segment.mode)")
                }
                for index in indices { work.append((segment.name, index)) }
            }
            logger.write("INFO", "Popfeed archive page downloaded; page=\(pageNumber), blocks=\(work.count), range=(\(cursor),\(plan.plannedThrough)]")

            var pageEvents: [PopfeedArchiveEvent] = []
            for (segmentName, blockIndex) in work {
                try Task.checkCancellation()
                let compressed = try await getBlock(segment: segmentName, index: blockIndex, apiKey: apiKey)
                let uncompressed = try await Task.detached(priority: .utility) { [maximumUncompressedBlock] in
                    try Self.decompress(compressed, maximumSize: maximumUncompressedBlock)
                }.value
                let events = try Self.decodeBlock(uncompressed)
                pageEvents.append(contentsOf: events.filter { $0.sequence > pageStart && $0.sequence <= plan.plannedThrough })
                await onProgress(tip == 0 ? 1 : min(1, Double(pageEvents.count) / Double(max(1, work.count))), "Reading Popfeed archive… \(pageEvents.count.formatted()) events")
            }
            pageEvents.sort { $0.sequence < $1.sequence }
            let applicableEvents = pageEvents.filter { $0.sequence > cursor && $0.sequence <= tip }
            try await onEvents(applicableEvents)

            // plannedThrough includes seqs in blocks the exact filters safely excluded.
            // Advance only after the page's records have been persisted atomically.
            cursor = max(cursor, plan.plannedThrough)
            await onCursor(cursor)
            logger.write("INFO", "Popfeed archive page complete; page=\(pageNumber), cursor=\(cursor), target=\(tip)")
            await onProgress(tip == 0 || cursor >= tip ? 1 : Double(cursor) / Double(tip), "Popfeed archive replay: \(cursor.formatted()) / \(tip.formatted())")
            if plan.plannedThrough >= tip { return cursor }
            guard plan.plannedThrough > pageStart || plan.plannedThrough >= tip else {
                throw ReplayError.invalidPlan("planner continuation did not advance")
            }
            // Keep the pinned tip fixed across all pages. The next exclusive afterSeq
            // uses the page continuation reported by the planner.
            cursor = plan.plannedThrough
        } while true
    }

    private func makePlan(did: String, apiKey: String, after: UInt64, before: UInt64?) async throws -> PlanPage {
        var body: [String: Any] = [
            "dids": [did],
            "collections": ["social.popfeed.*"],
            "afterSeq": after
        ]
        if let before { body["beforeSeq"] = before }
        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: "https://\(host)/xrpc/network.bsky.jetstream.planSnapshot")!)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let responseData = try await send(request, label: "planSnapshot")
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let sealedTip = Self.uint64(json["sealedTipSeq"]),
              let plannedThrough = Self.uint64(json["plannedThroughSeq"]),
              let rawSegments = json["segments"] as? [[String: Any]] else {
            throw ReplayError.invalidPlan("Jetstream returned an invalid plan response")
        }
        let segments = try rawSegments.map { entry -> PlanSegment in
            guard let name = entry["name"] as? String,
                  let mode = entry["mode"] as? String else {
                throw ReplayError.invalidPlan("planner segment omitted name or mode")
            }
            let blocks = (entry["blocks"] as? [[String: Any]] ?? []).map { block in
                BlockRange(first: (block["first"] as? NSNumber)?.intValue ?? -1,
                           last: (block["last"] as? NSNumber)?.intValue ?? -1)
            }
            return PlanSegment(name: name, mode: mode, blocks: blocks)
        }
        return PlanPage(sealedTip: sealedTip, plannedThrough: plannedThrough, segments: segments)
    }

    private func getBlock(segment: String, index: Int, apiKey: String) async throws -> Data {
        var components = URLComponents(string: "https://\(host)/xrpc/network.bsky.jetstream.getBlock")!
        components.queryItems = [
            URLQueryItem(name: "segment", value: segment),
            URLQueryItem(name: "blockIndex", value: String(index))
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return try await send(request, label: "getBlock[\(index)]")
    }

    private func blockIndices(segment: String, apiKey: String, after: UInt64, through: UInt64) async throws -> [Int] {
        let header = try await getSegmentRange(segment: segment, range: 0...255, apiKey: apiKey)
        guard header.count == 256 else { throw ReplayError.invalidSegment("short fixed header for \(segment)") }
        guard header.prefix(4) == Data("jss0".utf8) else { throw ReplayError.invalidSegment("bad magic in \(segment)") }
        let blockCount = Int(try Self.readLE32(header, at: 14))
        let blockIndexOffset = try Self.readLE64(header, at: 90)
        guard blockCount <= 1_000_000 else { throw ReplayError.invalidSegment("block count exceeds safety limit") }
        guard blockCount == 0 else {
            let indexByteCount = blockCount.multipliedReportingOverflow(by: 52)
            guard !indexByteCount.overflow, indexByteCount.partialValue > 0 else {
                throw ReplayError.invalidSegment("invalid block index size")
            }
            let start = Int64(blockIndexOffset)
            let end = start + Int64(indexByteCount.partialValue) - 1
            let bytes = try await getSegmentRange(segment: segment, range: start...end, apiKey: apiKey)
            guard bytes.count == indexByteCount.partialValue else { throw ReplayError.invalidSegment("short block index for \(segment)") }
            var selected: [Int] = []
            for index in 0..<blockCount {
                let offset = index * 52
                let minSeq = try Self.readLE64(bytes, at: offset + 20)
                let maxSeq = try Self.readLE64(bytes, at: offset + 28)
                if maxSeq > after && minSeq <= through { selected.append(index) }
            }
            return selected
        }
        return []
    }

    private func getSegmentRange(segment: String, range: ClosedRange<Int64>, apiKey: String) async throws -> Data {
        var components = URLComponents(string: "https://\(host)/xrpc/network.bsky.jetstream.getSegment")!
        components.queryItems = [URLQueryItem(name: "name", value: segment)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        var retries = 0
        while true {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ReplayError.http("missing HTTP response") }
            if http.statusCode == 429, retries < 5 {
                retries += 1
                let wait = UInt64(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60
                logger.write("WARN", "Jetstream archive byte quota reached during getSegment range; retryAfterSeconds=\(wait)")
                try await Task.sleep(nanoseconds: min(wait, 3600) * 1_000_000_000)
                continue
            }
            guard http.statusCode == 206 else {
                throw ReplayError.http("getSegment range returned HTTP \(http.statusCode), expected 206")
            }
            return data
        }
    }

    private func send(_ request: URLRequest, label: String) async throws -> Data {
        var retries = 0
        while true {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ReplayError.http("\(label): missing HTTP response") }
            if http.statusCode == 429, retries < 5 {
                retries += 1
                let wait = UInt64(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60
                logger.write("WARN", "Jetstream archive byte quota reached; operation=\(label), retryAfterSeconds=\(wait)")
                try await Task.sleep(nanoseconds: min(wait, 3600) * 1_000_000_000)
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = String(data: data.prefix(400), encoding: .utf8) ?? ""
                throw ReplayError.http("\(label) returned HTTP \(http.statusCode): \(detail)")
            }
            return data
        }
    }

    private static func expand(_ ranges: [BlockRange]) throws -> [Int] {
        var result: [Int] = []
        for range in ranges {
            guard range.first >= 0, range.last >= range.first, range.last - range.first <= 100_000 else {
                throw ReplayError.invalidPlan("invalid block range")
            }
            result.append(contentsOf: range.first...range.last)
        }
        return result
    }

    private static func decompress(_ input: Data, maximumSize: Int) throws -> Data {
        let contentSize = input.withUnsafeBytes { bytes -> UInt64 in
            guard let base = bytes.baseAddress else { return UInt64.max }
            return ZSTD_getFrameContentSize(base, input.count)
        }
        guard contentSize != UInt64.max, contentSize != UInt64.max - 1,
              contentSize <= UInt64(maximumSize), contentSize > 0 else {
            throw ReplayError.invalidBlock("frame has unknown or unsafe decompressed size")
        }
        var output = Data(count: Int(contentSize))
        let outputSize = output.count
        let inputSize = input.count
        let result = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                ZSTD_decompress(destination.baseAddress, outputSize, source.baseAddress, inputSize)
            }
        }
        guard ZSTD_isError(result) == 0, result == outputSize else {
            throw ReplayError.invalidBlock("zstd decode failed: \(String(cString: ZSTD_getErrorName(result)))")
        }
        return output
    }

    private static func decodeBlock(_ data: Data) throws -> [PopfeedArchiveEvent] {
        var reader = BinaryReader(data: data)
        let count = Int(try reader.readUInt32())
        guard count <= 100_000 else { throw ReplayError.invalidBlock("event count exceeds safety limit") }
        let sequences = try reader.readUInt64Array(count)
        _ = try reader.readUInt64Array(count) // witnessed_at
        _ = try reader.readUInt64Array(count) // indexed_at
        let kinds = try reader.readBytes(count)
        let collectionLengths = try reader.readBytes(count).map(Int.init)
        let didLengths = try reader.readUInt16Array(count).map(Int.init)
        let rkeyLengths = try reader.readBytes(count).map(Int.init)
        let revLengths = try reader.readBytes(count).map(Int.init)
        let eventLengths = try reader.readUInt32Array(count).map(Int.init)
        let collections = try reader.readStrings(collectionLengths)
        let dids = try reader.readStrings(didLengths)
        let rkeys = try reader.readStrings(rkeyLengths)
        _ = try reader.readStrings(revLengths)
        let payloads = try reader.readDataArray(eventLengths)
        guard reader.isAtEnd else { throw ReplayError.invalidBlock("trailing bytes after block columns") }
        return (0..<count).map { index in
            PopfeedArchiveEvent(sequence: sequences[index], kind: kinds[index], did: dids[index],
                                collection: collections[index], rkey: rkeys[index], recordCBOR: payloads[index])
        }
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value
    }

    private static func readLE32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw ReplayError.invalidSegment("truncated uint32") }
        return data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
    }

    private static func readLE64(_ data: Data, at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { throw ReplayError.invalidSegment("truncated uint64") }
        return data[offset..<(offset + 8)].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
    }

    private struct PlanPage {
        let sealedTip: UInt64
        let plannedThrough: UInt64
        let segments: [PlanSegment]
    }
    private struct PlanSegment {
        let name: String
        let mode: String
        let blocks: [BlockRange]?
    }
    private struct BlockRange {
        let first: Int
        let last: Int
    }

    enum ReplayError: LocalizedError {
        case http(String)
        case invalidPlan(String)
        case invalidSegment(String)
        case invalidBlock(String)
        var errorDescription: String? {
            switch self {
            case .http(let text), .invalidPlan(let text), .invalidSegment(let text), .invalidBlock(let text): return text
            }
        }
    }
}

private struct BinaryReader {
    private let data: Data
    private var offset = 0

    init(data: Data) { self.data = data }
    var isAtEnd: Bool { offset == data.count }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        let range = try take(count)
        return Array(data[range])
    }

    mutating func readUInt16Array(_ count: Int) throws -> [UInt16] {
        try (0..<count).map { _ in
            let bytes = try readBytes(2)
            return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        }
    }

    mutating func readUInt32Array(_ count: Int) throws -> [UInt32] {
        try (0..<count).map { _ in
            let bytes = try readBytes(4)
            return bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
        }
    }

    mutating func readUInt64Array(_ count: Int) throws -> [UInt64] {
        try (0..<count).map { _ in
            let bytes = try readBytes(8)
            return bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
        }
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(4)
        return bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
    }

    mutating func readStrings(_ lengths: [Int]) throws -> [String] {
        try lengths.map { length in
            let range = try take(length)
            guard let string = String(data: data[range], encoding: .utf8) else {
                throw PopfeedArchiveReplay.ReplayError.invalidBlock("invalid UTF-8 string column")
            }
            return string
        }
    }

    mutating func readDataArray(_ lengths: [Int]) throws -> [Data] {
        try lengths.map { length in data[try take(length)] }
    }

    private mutating func take(_ count: Int) throws -> Range<Int> {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw PopfeedArchiveReplay.ReplayError.invalidBlock("truncated column data")
        }
        let range = offset..<(offset + count)
        offset += count
        return range
    }
}
