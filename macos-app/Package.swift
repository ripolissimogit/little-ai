// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LittleAI",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LittleAI", targets: ["LittleAI"])
    ],
    targets: [
        .executableTarget(
            name: "LittleAI",
            path: "Sources/LittleAI"
        )
    ]
)
