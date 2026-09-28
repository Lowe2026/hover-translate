import Foundation

/// 对一段文字的语言判断。只区分到"要不要翻"这个粒度，不做精确语种识别。
public enum SourceLanguageGuess: Sendable, Equatable {
    case english
    case chinese
    case indeterminate
}

public enum TextNormalizer {
    public static let defaultMaximumLength = 1_200

    /// 折叠空白、裁长度。不做任何语言判断。
    public static func tidy(_ raw: String, maximumLength: Int = defaultMaximumLength) -> String? {
        // 不用正则：ICU 不认 Swift 的 \u{...} 字面量语法，写在字符类里会整条失效。
        // .whitespacesAndNewlines 已经覆盖不换行空格等各种变体。
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count >= 2 else { return nil }
        return String(collapsed.prefix(maximumLength))
    }

    public static func guessLanguage(_ text: String) -> SourceLanguageGuess {
        var latin = 0
        var han = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A:
                latin += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                han += 1
            default:
                break
            }
        }
        if han > latin { return .chinese }
        if latin >= 2 { return .english }
        return .indeterminate
    }

    /// 送去翻译前的最后一道闸。已经是中文的直接放弃——用户要的是看懂英文界面，
    /// 把中文再翻一道只会产出乱码。
    public static func clean(_ raw: String, maximumLength: Int = defaultMaximumLength) -> String? {
        guard let tidied = tidy(raw, maximumLength: maximumLength) else { return nil }
        guard guessLanguage(tidied) == .english else { return nil }
        return tidied
    }
}
