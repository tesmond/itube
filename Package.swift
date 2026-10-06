// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ITubeCore",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "ITubeCore", targets: ["ITubeCore"]),
    ],
    targets: [
        .target(name: "ITubeCore"),
        .testTarget(
            name: "ITubeCoreTests",
            dependencies: ["ITubeCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
