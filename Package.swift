// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GliaSDK",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "GliaSDK",
            targets: ["GliaSDK"]
        ),
        .library(
            name: "GliaUI",
            targets: ["GliaUI"]
        )
    ],
    targets: [
        .target(
            name: "GliaSDK",
            dependencies: [],
            path: "Sources/GliaSDK"
        ),
        .target(
            name: "GliaUI",
            dependencies: ["GliaSDK"],
            path: "Sources/GliaUI"
        ),
        .testTarget(
            name: "GliaSDKTests",
            dependencies: ["GliaSDK"],
            path: "Tests/GliaSDKTests"
        )
    ]
)
