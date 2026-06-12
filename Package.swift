// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoKeyboard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AutoKeyboard",
            path: "Sources/AutoKeyboard"
        )
    ]
)
