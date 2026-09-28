import CoreGraphics
import Foundation
import HoverTranslateCore

// 极简断言harness。故意不依赖 XCTest —— 那个只随完整 Xcode 分发。
private var failures: [String] = []
private var passed = 0

@MainActor private func check(_ name: String, _ actual: String?, _ expected: String?) {
    if actual == expected {
        passed += 1
    } else {
        failures.append("""
        ✗ \(name)
            期望: \(expected.map { "\"\($0)\"" } ?? "nil")
            实际: \(actual.map { "\"\($0)\"" } ?? "nil")
        """)
    }
}

@MainActor private func check(_ name: String, _ condition: Bool) {
    if condition {
        passed += 1
    } else {
        failures.append("✗ \(name)")
    }
}

// 行高统一按 18 点，行距 4 点——接近正文排版。
private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 18) -> RecognizedLine {
    RecognizedLine(text: text, frame: CGRect(x: x, y: y, width: width, height: height))
}

// MARK: - 段落拼接

check(
    "同一段的连续行会被拼成一句",
    TextBlockAssembler.assemble(
        lines: [
            line("She's playing with the idea that a study", x: 100, y: 200, width: 300),
            line("isn't meant for lounging, but then turning", x: 100, y: 222, width: 300),
            line("it around.", x: 100, y: 244, width: 90)
        ],
        around: CGPoint(x: 200, y: 230)
    ),
    "She's playing with the idea that a study isn't meant for lounging, but then turning it around."
)

// 回归：侧边栏／并排控件曾被当成同一句翻译。
check(
    "水平不重叠的邻栏不会被拼进来",
    TextBlockAssembler.assemble(
        lines: [
            line("Accept edits", x: 20, y: 222, width: 90),
            line("isn't meant for lounging, but then turning", x: 300, y: 222, width: 300)
        ],
        around: CGPoint(x: 400, y: 230)
    ),
    "isn't meant for lounging, but then turning"
)

check(
    "隔得太远的行不会跨空白被捞进来",
    TextBlockAssembler.assemble(
        lines: [
            line("the sentence you are pointing at", x: 100, y: 200, width: 300),
            line("a totally unrelated paragraph", x: 100, y: 340, width: 300)
        ],
        around: CGPoint(x: 200, y: 208)
    ),
    "the sentence you are pointing at"
)

check(
    "字号不同的标题不会被并进正文",
    TextBlockAssembler.assemble(
        lines: [
            line("Settings", x: 100, y: 176, width: 120, height: 30),
            line("Choose how the overlay behaves", x: 100, y: 210, width: 280)
        ],
        around: CGPoint(x: 200, y: 218)
    ),
    "Choose how the overlay behaves"
)

check(
    "光标没指着任何文字时不返回内容",
    TextBlockAssembler.assemble(
        lines: [line("some text", x: 100, y: 200, width: 200)],
        around: CGPoint(x: 600, y: 600)
    ),
    nil
)

check(
    "断词连字符会被接回完整单词",
    TextBlockAssembler.assemble(
        lines: [
            line("this tool performs local trans-", x: 100, y: 200, width: 300),
            line("lation without a network call", x: 100, y: 222, width: 300)
        ],
        around: CGPoint(x: 200, y: 208)
    ),
    "this tool performs local translation without a network call"
)

check(
    "中文之间不插空格",
    TextBlockAssembler.join(["书房就书房吧，", "反正这里是终端"], limit: 600),
    "书房就书房吧，反正这里是终端"
)

check(
    "点落在框内距离为零",
    TextBlockAssembler.distance(from: CGPoint(x: 50, y: 10), to: CGRect(x: 0, y: 0, width: 100, height: 20)) == 0
)

// MARK: - 语言闸门

// 回归：屏幕上本来就是中文，却被硬翻一道。
check("已经是中文的不送去翻译", TextNormalizer.clean("这一句本来就是中文，不该送去翻译"), nil)
check("中文被正确识别", TextNormalizer.guessLanguage("书房就书房吧") == .chinese)
check("中英混排以英文为主时翻译", TextNormalizer.clean("She mixed up 随便 with 便宜, joking about it") != nil)
check("中英混排以中文为主时跳过", TextNormalizer.clean("她把 callback 翻成了回电，这个词没有上下文就选不对"), nil)
check("折叠空白并保留原句", TextNormalizer.tidy("  hello \n\n  world  "), "hello world")
check(
    "超长文本被裁到上限",
    TextNormalizer.clean(String(repeating: "English sentence. ", count: 200))?.count == TextNormalizer.defaultMaximumLength
)

// MARK: - 汇总

if failures.isEmpty {
    print("✅ \(passed) 项全部通过")
} else {
    print("❌ \(failures.count) 项失败，\(passed) 项通过\n")
    failures.forEach { print($0) }
    exit(1)
}
