import AppKit
import CoreGraphics
import Foundation
import HoverTranslateCore
import Vision

// 造一张接近真实界面的图：左边一个窄的侧栏项，右边一段多行英文正文。
let scale: CGFloat = 2
let size = CGSize(width: 720, height: 360)
let image = NSImage(size: size)
image.lockFocus()
NSColor.white.setFill()
NSRect(origin: .zero, size: size).fill()

func draw(_ text: String, at point: CGPoint, fontSize: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize),
        .foregroundColor: NSColor.black
    ]
    // NSImage 的坐标原点在左下，这里传入的是"从顶部量"的 y，先翻过来。
    (text as NSString).draw(at: CGPoint(x: point.x, y: size.height - point.y - fontSize * 1.3), withAttributes: attrs)
}

draw("Accept edits", at: CGPoint(x: 20, y: 180), fontSize: 13)
let body = [
    "She's playing with the idea that a study isn't meant",
    "for lounging, but then turning it around - who says a",
    "study can't have a sofa? There's something wry and",
    "honest about acknowledging what that space means."
]
for (i, l) in body.enumerated() {
    draw(l, at: CGPoint(x: 260, y: 150 + CGFloat(i) * 22), fontSize: 13)
}
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let cgImage = bitmap.cgImage else {
    print("造图失败"); exit(1)
}

func recognise(languages: [String]) -> [RecognizedLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = languages
    request.usesLanguageCorrection = true
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do { try handler.perform([request]) } catch {
        print("  ⚠️ Vision 报错: \(error)"); return []
    }
    return (request.results ?? []).compactMap { obs in
        guard let text = obs.topCandidates(1).first?.string,
              let tidied = TextNormalizer.tidy(text, maximumLength: 500) else { return nil }
        let b = obs.boundingBox
        return RecognizedLine(
            text: tidied,
            frame: CGRect(x: b.minX * size.width,
                          y: (1 - b.maxY) * size.height,
                          width: b.width * size.width,
                          height: b.height * size.height)
        )
    }
}

// 光标停在正文第二行中间
let cursor = CGPoint(x: 400, y: 178)

for langs in [["en-US"], ["en-US", "zh-Hans"]] {
    print("\n═══ recognitionLanguages = \(langs) ═══")
    let lines = recognise(languages: langs)
    print("识别到 \(lines.count) 行：")
    for l in lines {
        let f = l.frame
        print(String(format: "  y=%6.1f h=%5.1f x=%6.1f w=%6.1f  距光标 %5.1f  %@",
                     f.minY, f.height, f.minX, f.width,
                     TextBlockAssembler.distance(from: cursor, to: f), l.text))
    }
    let assembled = TextBlockAssembler.assemble(lines: lines, around: cursor)
    print("拼接结果: \(assembled.map { "\"\($0)\"" } ?? "nil ← 这里就是失灵")")
    if let a = assembled {
        print("过语言闸后: \(TextNormalizer.clean(a).map { "\"\($0)\"" } ?? "nil ← 被语言闸拦下")")
    }
}
