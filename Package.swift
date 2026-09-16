// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScorecardKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "ScorecardKit", targets: ["ScorecardKit"])
    ],
    targets: [
        .target(
            name: "ScorecardKit",
            path: "Sources/ScorecardKit"
        ),
        .testTarget(
            name: "ScorecardKitTests",
            dependencies: ["ScorecardKit"],
            path: "Tests/ScorecardKitTests"
        )
    ]
)
