// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CameraCull",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CameraCull", targets: ["CameraCull"])
    ],
    targets: [
        .executableTarget(
            name: "CameraCull",
            path: "Sources/CameraCull",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CameraCullTests",
            dependencies: ["CameraCull"],
            path: "Tests/CameraCullTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
