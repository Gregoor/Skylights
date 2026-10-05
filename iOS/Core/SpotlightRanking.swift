import Foundation

public struct SpotlightRankingItem: Equatable {
    public let id: String
    public let title: String
    public let year: Int
    public let voteCount: Int
    public let rottenTomatoesScore: Int?

    public init(id: String, title: String, year: Int, voteCount: Int, rottenTomatoesScore: Int? = nil) {
        self.id = id
        self.title = title
        self.year = year
        self.voteCount = voteCount
        self.rottenTomatoesScore = rottenTomatoesScore
    }
}

public enum SpotlightRanking {
    /// Recency is a small tie-breaker. Popularity remains the stronger signal for established titles.
    private static let maximumRecencyBonus = 600.0
    private static let maximumPopularityBonus = 2_500.0
    private static let maximumHint = 3_071.0

    public static func hint(
        year: Int,
        voteCount: Int,
        rottenTomatoesScore: Int?,
        currentYear: Int = Calendar(identifier: .gregorian).component(.year, from: Date())
    ) -> Double {
        let yearsAgo = year > 0 ? max(0, currentYear - year) : Int.max
        let recency = yearsAgo <= 5
            ? maximumRecencyBonus * (1 - Double(yearsAgo) / 5)
            : 0
        let voteBonus = voteCount > 0
            ? min(maximumPopularityBonus, log1p(Double(voteCount)) * 260)
            : 0
        let tomatoBonus = voteCount < 10
            ? Double(rottenTomatoesScore ?? 0) / 100 * maximumPopularityBonus
            : 0
        return min(maximumHint, recency + max(voteBonus, tomatoBonus)) / maximumHint * 100
    }

    /// Ranks strong title matches first, then uses the shared relevance hint. Original order breaks ties.
    public static func orderedIDs(
        _ items: [SpotlightRankingItem],
        for query: String,
        currentYear: Int = Calendar(identifier: .gregorian).component(.year, from: Date())
    ) -> [String] {
        let foldedQuery = normalizedSearchText(query)
        guard !foldedQuery.isEmpty else { return items.map(\.id) }
        return items.enumerated().sorted { left, right in
            let leftTier = matchTier(title: left.element.title, query: foldedQuery)
            let rightTier = matchTier(title: right.element.title, query: foldedQuery)
            if leftTier != rightTier { return leftTier > rightTier }
            let leftHint = hint(
                year: left.element.year,
                voteCount: left.element.voteCount,
                rottenTomatoesScore: left.element.rottenTomatoesScore,
                currentYear: currentYear
            )
            let rightHint = hint(
                year: right.element.year,
                voteCount: right.element.voteCount,
                rottenTomatoesScore: right.element.rottenTomatoesScore,
                currentYear: currentYear
            )
            if leftHint != rightHint { return leftHint > rightHint }
            return left.offset < right.offset
        }.map(\.element.id)
    }

    private static func matchTier(title: String, query: String) -> Int {
        let foldedTitle = normalizedSearchText(title)
        if foldedTitle == query { return 5 }
        if foldedTitle.hasPrefix(query + " ") { return 4 }
        if foldedTitle.contains(query) { return 3 }
        let queryTerms = query.split(separator: " ").map(String.init)
        let titleTerms = foldedTitle.split(separator: " ").map(String.init)
        if queryTerms.allSatisfy({ queryTerm in titleTerms.contains(where: { $0.hasPrefix(queryTerm) }) }) { return 2 }
        if queryTerms.allSatisfy({ foldedTitle.contains($0) }) { return 1 }
        return 0
    }

    private static func normalizedSearchText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }
}
