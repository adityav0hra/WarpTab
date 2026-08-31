// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WarpTab",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WarpTab", targets: ["WarpTab"])
    ],
    targets: [
        .executableTarget(
            name: "WarpTab",
            path: "Sources/WarpTab",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
