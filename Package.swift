// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Pointwise",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "Pointwise",
            path: "Sources/Pointwise"
        ),
        .testTarget(
            name: "PointwiseTests",
            dependencies: ["Pointwise"],
            path: "Tests/PointwiseTests"
        ),
    ]
)
