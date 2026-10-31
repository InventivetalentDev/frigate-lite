// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FrigateLite",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FrigateLite",
            path: "Sources/FrigateLite"
        )
    ],
    swiftLanguageModes: [.v5]
)
