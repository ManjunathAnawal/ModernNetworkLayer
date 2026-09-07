// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NetworkLayer",
    platforms: [
        .iOS(.v17),   // Required for @Observable
        .macOS(.v14)  // Lets `swift test` run on CI/dev machines without a simulator
    ],
    products: [
        .library(name: "NetworkLayer", targets: ["NetworkLayer"])
    ],
    targets: [
        .target(
            name: "NetworkLayer",
            path: "Sources"
        ),
        .testTarget(
            name: "NetworkLayerTests",
            dependencies: ["NetworkLayer"],
            path: "Tests"
        )
    ]
)
