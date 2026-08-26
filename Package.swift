// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenSwap",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ScreenSwap", targets: ["ScreenSwap"])
    ],
    targets: [
        .executableTarget(
            name: "ScreenSwap",
            path: "Sources/ScreenSwap"
        )
    ]
)
