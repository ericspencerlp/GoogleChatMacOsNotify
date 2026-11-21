// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GoogleChatNotifier",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GoogleChatNotifier",
            path: "Sources/GoogleChatNotifier"
        )
    ]
)
