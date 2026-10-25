// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Swoosh",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Swoosh", targets: ["Swoosh"])],
    targets: [
        .target(name: "SwooshCore"),
        .executableTarget(name: "Swoosh", dependencies: ["SwooshCore"]),
        .testTarget(name: "SwooshCoreTests", dependencies: ["SwooshCore"])
    ]
)
