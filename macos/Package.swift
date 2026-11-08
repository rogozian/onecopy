// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OneCopy",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OneCopyCore", targets: ["OneCopyCore"]),
        .executable(name: "OneCopy", targets: ["OneCopy"])
    ],
    targets: [
        .target(name: "OneCopyPlatform", publicHeadersPath: "include"),
        .target(name: "OneCopyCore", dependencies: ["OneCopyPlatform"]),
        .executableTarget(name: "OneCopy", dependencies: ["OneCopyCore"]),
        .testTarget(name: "OneCopyCoreTests", dependencies: ["OneCopyCore"])
    ]
)
