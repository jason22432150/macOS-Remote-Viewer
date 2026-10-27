// swift-tools-version: 6.0
import PackageDescription

/// 純 Swift Core：Parser、設定模型、剪貼簿政策與 session 狀態。
/// App／CocoaSpice 整合由 Xcode target 負責，避免 `swift test` 依賴本機 C 程式庫路徑。
let package = Package(
    name: "MacRemoteViewer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacRemoteViewerCore", targets: ["MacRemoteViewerCore"])
    ],
    targets: [
        .target(
            name: "MacRemoteViewerCore",
            path: "MacRemoteViewer",
            exclude: [
                "App",
                "Engine",
                "Platform"
            ]
        ),
        .testTarget(
            name: "MacRemoteViewerCoreTests",
            dependencies: ["MacRemoteViewerCore"],
            path: "Tests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
