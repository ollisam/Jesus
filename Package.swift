// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Recast",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Recast", path: "Sources/Recast")
    ],
    swiftLanguageModes: [.v5]
)
