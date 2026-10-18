// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Whereabouts",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Whereabouts",
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]
        )
    ],
    swiftLanguageModes: [.v5]
)
