// swift-tools-version: 6.0
import PackageDescription

// 刻意不使用 XCTest / swift-testing：两者都只随完整 Xcode 分发，
// 只装了 Command Line Tools 的机器跑不了。测试改成一个普通可执行目标，
// `swift run HoverTranslateCoreTests` 即可，任何装了 Swift 的 Mac 都能跑。
let package = Package(
    name: "HoverTranslate",
    platforms: [.macOS("15.2")],
    targets: [
        // 纯逻辑，不碰屏幕、权限和系统框架。
        .target(
            name: "HoverTranslateCore",
            path: "Sources/HoverTranslateCore"
        ),
        .executableTarget(
            name: "HoverTranslateCoreTests",
            dependencies: ["HoverTranslateCore"],
            path: "Sources/HoverTranslateCoreTests"
        ),
        // 暂留 Swift 5 语言模式：Apple 的 TranslationSession 不是 Sendable，
        // 现有的翻译队列在 Swift 6 严格并发下过不了。等引擎那一层重写时一并解决，
        // 不在取词这一轮里顺手改动翻译路径。Core 保持 Swift 6 模式。
        // 排障工具：离线跑一遍 OCR→拼接→语言闸 的完整管线。
        .executableTarget(
            name: "OCRProbe",
            dependencies: ["HoverTranslateCore"],
            path: "Sources/OCRProbe"
        ),
        .executableTarget(
            name: "HoverTranslate",
            dependencies: ["HoverTranslateCore"],
            path: "Sources/HoverTranslate",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
