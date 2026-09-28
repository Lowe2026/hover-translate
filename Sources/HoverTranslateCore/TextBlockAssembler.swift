import CoreGraphics
import Foundation

/// OCR 认出的一行文字。frame 用屏幕点坐标，原点左上、y 向下。
public struct RecognizedLine: Sendable, Equatable {
    public let text: String
    public let frame: CGRect

    public init(text: String, frame: CGRect) {
        self.text = text
        self.frame = frame
    }
}

/// 把散落的 OCR 行拼回"鼠标指着的那一段"。
///
/// 旧实现的做法是：取离光标最近的一行当锚点，再把归一化距离 0.18 以内最多 5 行
/// 一律用空格拼起来。两个后果——
///
/// 1. 距离在归一化坐标里算，x 除以采样框宽、y 除以采样框高。采样框是 760×300，
///    于是同样的"距离"横向覆盖 76 点、纵向只覆盖 30 点，左右无关的控件被拉进来的
///    概率是上下的两倍半。
/// 2. 完全不判断这些行是不是同一段文字，导致侧边栏菜单项和正文句子被拼成一句。
///
/// 这里改成：先在真实点坐标里找锚点行，再从锚点**逐行向上下生长**，每次只接纳
/// 满足同段条件的相邻行——水平投影要重叠、行间空隙不能超过行高、字号要接近。
/// 任一条不满足就停止那个方向，不再继续跳着捞。
public enum TextBlockAssembler {
    public struct Tuning: Sendable {
        /// 光标到锚点行的最大距离（点）。超过就认为用户没有指着任何文字。
        public var anchorMaximumDistance: CGFloat = 44
        /// 相邻两行的垂直空隙上限，按行高的倍数算。正文行距通常远小于 1 倍行高。
        public var verticalGapRatio: CGFloat = 0.9
        /// 与当前段落水平投影的最小重叠比例。分栏、侧边栏因此被排除。
        public var minimumHorizontalOverlap: CGFloat = 0.35
        /// 字号差异容忍度。标题接正文、正文接脚注都会被这一条挡掉。
        public var heightRatioTolerance: CGFloat = 0.45
        public var maximumLines = 6
        public var maximumCharacters = 600

        public init() {}
    }

    public static func assemble(
        lines: [RecognizedLine],
        around cursor: CGPoint,
        tuning: Tuning = Tuning()
    ) -> String? {
        let candidates = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { $0.frame.width > 0 && $0.frame.height > 0 }
            .sorted { $0.frame.midY < $1.frame.midY }
        guard !candidates.isEmpty else { return nil }

        guard let anchorIndex = anchorIndex(in: candidates, cursor: cursor, tuning: tuning) else {
            return nil
        }

        var accepted = [candidates[anchorIndex]]
        var span = candidates[anchorIndex].frame

        // 向上生长
        var upper = anchorIndex - 1
        while upper >= 0, accepted.count < tuning.maximumLines {
            guard belongsToSameBlock(candidates[upper], span: span, neighbour: accepted.first!, tuning: tuning) else { break }
            accepted.insert(candidates[upper], at: 0)
            span = span.union(candidates[upper].frame)
            upper -= 1
        }

        // 向下生长
        var lower = anchorIndex + 1
        while lower < candidates.count, accepted.count < tuning.maximumLines {
            guard belongsToSameBlock(candidates[lower], span: span, neighbour: accepted.last!, tuning: tuning) else { break }
            accepted.append(candidates[lower])
            span = span.union(candidates[lower].frame)
            lower += 1
        }

        return join(accepted.map(\.text), limit: tuning.maximumCharacters)
    }

    // MARK: - 锚点

    private static func anchorIndex(
        in lines: [RecognizedLine],
        cursor: CGPoint,
        tuning: Tuning
    ) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, line) in lines.enumerated() {
            let distance = distance(from: cursor, to: line.frame)
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        guard let best, best.distance <= tuning.anchorMaximumDistance else { return nil }
        return best.index
    }

    /// 点到矩形的距离。落在矩形内为 0。
    public static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    // MARK: - 同段判断

    /// `span` 是当前已接纳段落的整体范围，`neighbour` 是紧挨着候选行的那一行。
    /// 垂直连续性对 neighbour 判断（必须逐行相接），水平对齐对 span 判断（整段的栏宽）。
    static func belongsToSameBlock(
        _ candidate: RecognizedLine,
        span: CGRect,
        neighbour: RecognizedLine,
        tuning: Tuning
    ) -> Bool {
        let referenceHeight = max(neighbour.frame.height, 1)

        // 字号
        let ratio = abs(candidate.frame.height - referenceHeight) / referenceHeight
        guard ratio <= tuning.heightRatioTolerance else { return false }

        // 垂直连续：两行之间的空隙不能超过一个行高
        let gap: CGFloat
        if candidate.frame.midY < neighbour.frame.midY {
            gap = neighbour.frame.minY - candidate.frame.maxY
        } else {
            gap = candidate.frame.minY - neighbour.frame.maxY
        }
        guard gap <= referenceHeight * tuning.verticalGapRatio else { return false }

        // 水平投影重叠：分栏、侧边栏、并排控件在这里被挡掉
        let overlap = min(candidate.frame.maxX, span.maxX) - max(candidate.frame.minX, span.minX)
        guard overlap > 0 else { return false }
        let narrower = min(candidate.frame.width, span.width)
        guard narrower > 0, overlap / narrower >= tuning.minimumHorizontalOverlap else { return false }

        return true
    }

    // MARK: - 拼接

    public static func join(_ pieces: [String], limit: Int) -> String? {
        var result = ""
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if result.isEmpty {
                result = trimmed
                continue
            }
            // 断词连字符：把 "trans-" + "lation" 接回 "translation"
            if result.hasSuffix("-"), let first = trimmed.unicodeScalars.first, isLatinLetter(first) {
                result.removeLast()
                result += trimmed
                continue
            }
            // 中文之间不加空格
            if let last = result.unicodeScalars.last, let first = trimmed.unicodeScalars.first,
               isHan(last) || isHan(first) {
                result += trimmed
                continue
            }
            result += " " + trimmed
        }
        guard result.count >= 2 else { return nil }
        return String(result.prefix(limit))
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value)
            || (0x4E00...0x9FFF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
    }
}
