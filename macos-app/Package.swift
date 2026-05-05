// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Scarabot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Scarabot", targets: ["Scarabot"])
    ],
    targets: [
        .executableTarget(
            name: "Scarabot",
            path: "Sources/Scarabot"
        ),
        .testTarget(
            name: "ScarabotTests",
            dependencies: ["Scarabot"],
            path: "Tests/ScarabotTests"
        ),
    ]
)
