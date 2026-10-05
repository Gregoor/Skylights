// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SkylightsRanking",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [],
    targets: [
        .target(
            name: "SpotlightRanking",
            path: "Core",
            exclude: [
                "DiagnosticLog.swift",
                "Gzip.c",
                "KeychainCredentialStore.swift",
                "PopfeedArchiveReplay.swift",
                "PopfeedLiveSync.swift",
                "PopfeedOAuthClient.swift",
                "PopfeedRecordSync.swift",
                "SpotlightIndexer.swift"
            ],
            sources: ["SpotlightRanking.swift"]
        ),
        .testTarget(
            name: "SpotlightRankingTests",
            dependencies: ["SpotlightRanking"],
            path: "Tests"
        )
    ]
)
