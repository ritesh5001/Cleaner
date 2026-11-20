// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Cleaner",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Cleaner",
            path: "Sources/Cleaner"
        )
    ]
)
