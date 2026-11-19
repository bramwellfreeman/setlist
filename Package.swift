// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Setlist",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Setlist",
            path: "Sources/Setlist",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
