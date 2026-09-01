// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppTransfer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AppTransfer", targets: ["AppTransfer"])
    ],
    targets: [
        .executableTarget(
            name: "AppTransfer",
            path: "Sources/AppTransfer"
        )
    ]
)
