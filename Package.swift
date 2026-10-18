// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Jesus",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Jesus", path: "Sources/Jesus")
    ],
    swiftLanguageModes: [.v5]
)
