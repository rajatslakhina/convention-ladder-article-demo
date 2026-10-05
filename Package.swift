// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ConventionLadder",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ConventionLadder", targets: ["ConventionLadder"])
    ],
    targets: [
        .target(name: "ConventionLadder"),
        .testTarget(name: "ConventionLadderTests", dependencies: ["ConventionLadder"])
    ]
)
