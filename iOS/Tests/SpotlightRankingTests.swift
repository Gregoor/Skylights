import XCTest
@testable import SpotlightRanking

final class SpotlightRankingTests: XCTestCase {
    private let currentYear = 2026

    func testHowIMetYourMotherLeadsTheObservedHowIMetResults() {
        let results = [
            SpotlightRankingItem(id: "tv-124010", title: "How I Met Your Father", year: 2022, voteCount: 296),
            SpotlightRankingItem(id: "movie-1554554", title: "How I Met Your Masi", year: 2025, voteCount: 2),
            SpotlightRankingItem(id: "movie-316866", title: "How I Met Your Father", year: 2008, voteCount: 23),
            SpotlightRankingItem(id: "movie-1617937", title: "How I Met Your Mattress", year: 2025, voteCount: 0),
            SpotlightRankingItem(id: "tv-1100", title: "How I Met Your Mother", year: 2005, voteCount: 5_962),
            SpotlightRankingItem(id: "movie-1562702", title: "How I Met My New Best Friend", year: 2025, voteCount: 1)
        ]

        XCTAssertEqual(
            SpotlightRanking.orderedIDs(results, for: "how i met", currentYear: currentYear),
            ["tv-1100", "tv-124010", "movie-316866", "movie-1554554", "movie-1562702", "movie-1617937"]
        )
    }

    func testRecencyAloneIsCappedSoANewUnknownCannotOutrankEstablishedHIMYM() {
        let establishedSeries = SpotlightRanking.hint(year: 2005, voteCount: 5_962, rottenTomatoesScore: nil, currentYear: currentYear)
        let recentUnknown = SpotlightRanking.hint(year: 2025, voteCount: 0, rottenTomatoesScore: nil, currentYear: currentYear)

        XCTAssertEqual(recentUnknown, 480 / 3_071 * 100, accuracy: 0.001)
        XCTAssertGreaterThan(establishedSeries, recentUnknown)
    }

    func testRecentTitleCanStillWinWithStrongPopularity() {
        let items = [
            SpotlightRankingItem(id: "himym", title: "How I Met Your Mother", year: 2005, voteCount: 5_962),
            SpotlightRankingItem(id: "recent-hit", title: "How I Met a Blockbuster", year: 2025, voteCount: 50_000)
        ]

        XCTAssertEqual(SpotlightRanking.orderedIDs(items, for: "how i met", currentYear: currentYear).first, "recent-hit")
    }

    func testStrongTitleMatchTakesPriorityOverPopularity() {
        let items = [
            SpotlightRankingItem(id: "popular-loose-match", title: "The Story of How I Met You", year: 2025, voteCount: 50_000),
            SpotlightRankingItem(id: "exact", title: "How I Met", year: 1990, voteCount: 0)
        ]

        XCTAssertEqual(SpotlightRanking.orderedIDs(items, for: "how i met", currentYear: currentYear).first, "exact")
    }

    func testRottenTomatoesOnlyReplacesWeakVoteSignal() {
        let withScore = SpotlightRanking.hint(year: 2010, voteCount: 100, rottenTomatoesScore: 98, currentYear: currentYear)
        let withoutScore = SpotlightRanking.hint(year: 2010, voteCount: 100, rottenTomatoesScore: nil, currentYear: currentYear)

        XCTAssertEqual(withScore, withoutScore, accuracy: 0.001)
    }
}
