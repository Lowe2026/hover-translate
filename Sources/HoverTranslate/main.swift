import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import HoverTranslateCore
import ScreenCaptureKit
import SwiftUI
import Translation
import Vision

private enum AppConstants {
    static let appName = "悬停翻译"
    static let targetLanguage = Locale.Language(identifier: "zh-Hans")
    static let sourceLanguage = Locale.Language(identifier: "en")
    static let hoverDelay: TimeInterval = 0.9
    static let maximumTextLength = 1_200
    static let requiresOptionPreference = "requiresOptionToHover"
}

/// 排障日志。默认关闭，从菜单栏打开。只记录取词各阶段的判断，正文最多截 120 字。
enum Diagnostics {
    /// 默认关闭：日志会把悬停到的正文写进磁盘（最多 120 字），
    /// 不该在用户不知情的时候开着。排障时从菜单栏打开，或者
    /// defaults write local.hovertranslate diagnosticsEnabled -bool true
    nonisolated(unsafe) static var enabled: Bool = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "diagnosticsEnabled") != nil else { return false }
        return defaults.bool(forKey: "diagnosticsEnabled")
    }()
    private static let lock = NSLock()

    static let logURL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/悬停翻译-诊断.log")

    static func log(_ message: String) {
        guard enabled else { return }
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        guard let data = "[\(stamp)] \(message)\n".data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: logURL)
        }
    }

    static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count <= 120 ? flat : String(flat.prefix(120)) + "…(共 \(flat.count) 字)"
    }
}

private enum TranslationOperation: Sendable {
    case translate(String)
    case prepareLanguages
}

private struct TranslationJob: Sendable {
    let id: UUID
    let operation: TranslationOperation
    let completion: @MainActor @Sendable (Result<String, Error>) -> Void
}

private actor TranslationQueue {
    private let stream: AsyncStream<TranslationJob>
    private let continuation: AsyncStream<TranslationJob>.Continuation

    init() {
        var captured: AsyncStream<TranslationJob>.Continuation?
        self.stream = AsyncStream { continuation in
            captured = continuation
        }
        self.continuation = captured!
    }

    func enqueue(_ job: TranslationJob) {
        continuation.yield(job)
    }

    func jobs() -> AsyncStream<TranslationJob> {
        stream
    }
}

private struct TranslationEngineView: View {
    let queue: TranslationQueue

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(
                source: AppConstants.sourceLanguage,
                target: AppConstants.targetLanguage
            ) { session in
                let jobs = await queue.jobs()
                for await job in jobs {
                    do {
                        switch job.operation {
                        case .translate(let source):
                            let response = try await session.translate(source)
                            job.completion(.success(response.targetText))
                        case .prepareLanguages:
                            try await session.prepareTranslation()
                            job.completion(.success("英语和简体中文语言包已经准备好"))
                        }
                    } catch {
                        job.completion(.failure(error))
                    }
                }
            }
    }
}

@MainActor
private final class TranslationOverlay {
    private let panel: NSPanel
    private let sourceLabel = NSTextField(wrappingLabelWithString: "")
    private let translationLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var hideTask: Task<Void, Never>?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        sourceLabel.font = .systemFont(ofSize: 12)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.maximumNumberOfLines = 3
        sourceLabel.lineBreakMode = .byTruncatingTail

        translationLabel.font = .systemFont(ofSize: 16, weight: .medium)
        translationLabel.textColor = .labelColor
        translationLabel.maximumNumberOfLines = 10
        translationLabel.lineBreakMode = .byWordWrapping

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.stringValue = "本机翻译 · 英语 → 简体中文"

        let stack = NSStackView(views: [sourceLabel, translationLabel, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12),
            sourceLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            translationLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])

        panel.contentView = effect
    }

    func showLoading(source: String, at mouseLocation: NSPoint) {
        sourceLabel.stringValue = source
        translationLabel.stringValue = "正在翻译…"
        statusLabel.stringValue = "本机翻译 · 英语 → 简体中文"
        present(at: mouseLocation)
    }

    func show(source: String, translation: String, at mouseLocation: NSPoint, method: String) {
        sourceLabel.stringValue = source
        translationLabel.stringValue = translation
        statusLabel.stringValue = method
        present(at: mouseLocation)
        scheduleHide(after: 10)
    }

    func showMessage(_ message: String, detail: String? = nil, at mouseLocation: NSPoint) {
        sourceLabel.stringValue = detail ?? ""
        translationLabel.stringValue = message
        statusLabel.stringValue = AppConstants.appName
        present(at: mouseLocation)
        scheduleHide(after: 8)
    }

    func hide() {
        hideTask?.cancel()
        panel.orderOut(nil)
    }

    private func present(at mouseLocation: NSPoint) {
        hideTask?.cancel()
        let fittingSize = panel.contentView?.fittingSize ?? NSSize(width: 420, height: 120)
        let width = min(max(fittingSize.width, 280), 460)
        let height = min(max(fittingSize.height, 90), 340)
        panel.setContentSize(NSSize(width: width, height: height))

        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        var origin = NSPoint(x: mouseLocation.x + 18, y: mouseLocation.y - height - 18)
        if origin.x + width > visible.maxX { origin.x = mouseLocation.x - width - 18 }
        if origin.y < visible.minY { origin.y = mouseLocation.y + 22 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - height - 8)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    private func scheduleHide(after seconds: UInt64) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }
}

private enum AccessibilityReader {
    struct Result {
        let text: String
        let method: String
    }

    /// 取词结果。
    ///
    /// `.frameOnly` 是这套东西里最别扭、也最有用的一种情况：**文字用不了，
    /// 但边框是准的**——应用总归知道自己把这块东西画在了哪里。
    ///
    /// 两种情形都归到这里：
    /// 1. 节点装着远超一段的内容。AX 不告诉我们光标落在其中第几个字，取前
    ///    600 字只能从头取，跟用户指的地方无关。
    /// 2. 一个字都读不出来（Electron 的常态）。
    ///
    /// 这两种情况下文字都该丢掉，但**框不能一起丢**——把它交给 OCR，采样
    /// 范围就能贴着这块文字走，而不是以光标为中心盲开一个固定大小的框。
    enum Outcome {
        case text(Result)
        case frameOnly(CGRect)
        case nothing
    }

    /// 文字不可用时的统一出口：有框就把框带出去。
    private static func fallback(to element: AXUIElement) -> Outcome {
        guard let box = frame(of: element), box.width > 40, box.height > 10 else { return .nothing }
        return .frameOnly(box)
    }

    static func requestPermission(prompt: Bool) -> Bool {
        // 直接用字面量：kAXTrustedCheckOptionPrompt 是全局 var，
        // Swift 6 严格并发下不能跨隔离域引用。
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    static func outcome(at quartzPoint: CGPoint) -> Outcome {
        let system = AXUIElementCreateSystemWide()
        var hoveredRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(quartzPoint.x), Float(quartzPoint.y), &hoveredRef) == .success,
              let hovered = hoveredRef else { return .nothing }

        var hoveredPID: pid_t = 0
        AXUIElementGetPid(hovered, &hoveredPID)
        guard hoveredPID != ProcessInfo.processInfo.processIdentifier else { return .nothing }

        if let selected = selectedText(from: system, matchingPID: hoveredPID, point: quartzPoint),
           let cleaned = TextNormalizer.clean(selected) {
            return .text(Result(text: cleaned, method: "已选中的整段文字"))
        }

        // 先拿到鼠标正下方那个元素的文字，再向上找更完整的一段。
        // 只有当父级文本"包含"子级文本、且没有膨胀太多倍时才采纳——
        // 这样能把被拆成多个 AXStaticText 的一句话接回来，
        // 又不会一路捞到整个窗口的内容。
        // 关键前提：辅助功能只给一坨文字和一个框，**不告诉我们光标落在这坨
        // 文字的第几个字**。所以一旦拿到的内容明显超过一段，从中取 600 字就
        // 只能从头取，跟用户指的位置毫无关系——Electron（Claude 桌面版、
        // Slack 等）把整块内容塞进一个节点时，正是这种情况。
        // 这时候宁可判定 AX 不可信，返回 nil 交给 OCR：OCR 是按光标坐标就近
        // 拼行的，位置是准的。
        var best: String?
        var current: AXUIElement? = hovered
        for _ in 0..<5 {
            guard let element = current else { break }
            if let candidate = bestText(from: element),
               let full = TextNormalizer.tidy(candidate, maximumLength: .max) {
                if let existing = best {
                    guard full.contains(existing), full.count <= existing.count * 6 else { break }
                    // 扩展后超出一段的体量，停在子级即可，不必整个放弃。
                    guard full.count <= 600 else { break }
                } else {
                    // 锚点元素自己就装不下：文字没有位置信息可言，交给 OCR。
                    // 但把它的边框带出去——那是这块文字真实的位置和大小。
                    if full.count > 600 { return fallback(to: element) }
                }
                best = full
            }
            current = parent(of: element)
        }
        // 读不出文字是 Electron 的常态。别把边框一起扔掉——那是这一轮唯一
        // 还站得住的信息，OCR 拿它开窗比盲开一个固定框准得多。
        guard let best, let cleaned = TextNormalizer.clean(best, maximumLength: 600) else {
            return fallback(to: hovered)
        }
        return .text(Result(text: cleaned, method: "鼠标悬停文字"))
    }

    private static func selectedText(from system: AXUIElement, matchingPID pid: pid_t, point: CGPoint) -> String? {
        guard let focusedValue = attribute(kAXFocusedUIElementAttribute as CFString, from: system) else { return nil }
        let focused = focusedValue as! AXUIElement
        var focusedPID: pid_t = 0
        AXUIElementGetPid(focused, &focusedPID)
        guard focusedPID == pid else { return nil }
        if let frame = frame(of: focused), !frame.insetBy(dx: -16, dy: -16).contains(point) { return nil }
        return stringAttribute(kAXSelectedTextAttribute as CFString, from: focused)
    }

    private static func bestText(from element: AXUIElement) -> String? {
        let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
        let readableRoles = [
            kAXStaticTextRole, kAXButtonRole, kAXMenuItemRole, "AXLink",
            kAXTextFieldRole, kAXTextAreaRole, kAXCheckBoxRole, kAXRadioButtonRole,
            kAXPopUpButtonRole
        ]
        guard readableRoles.contains(role) else { return nil }
        let orderedAttributes: [CFString]
        switch role {
        case kAXStaticTextRole, kAXTextFieldRole, kAXTextAreaRole:
            orderedAttributes = [kAXValueAttribute as CFString, kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString, kAXHelpAttribute as CFString]
        default:
            orderedAttributes = [kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString, kAXValueAttribute as CFString, kAXHelpAttribute as CFString]
        }

        for name in orderedAttributes {
            if let value = stringAttribute(name, from: element), value.count <= 2_000 {
                return value
            }
        }
        return nil
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(kAXParentAttribute as CFString, from: element) else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue = attribute(kAXPositionAttribute as CFString, from: element),
            let sizeValue = attribute(kAXSizeAttribute as CFString, from: element)
        else { return nil }

        let axPosition = positionValue as! AXValue
        let axSize = sizeValue as! AXValue
        guard AXValueGetType(axPosition) == .cgPoint, AXValueGetType(axSize) == .cgSize else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(axPosition, .cgPoint, &position),
            AXValueGetValue(axSize, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func stringAttribute(_ name: CFString, from element: AXUIElement) -> String? {
        attribute(name, from: element) as? String
    }

    private static func attribute(_ name: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }
}

private enum OCRReader {
    struct Result: Sendable {
        let text: String
        let method: String
    }

    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// - Parameter hint: 辅助功能给出的那块文字的边框。文字本身不可信（见
    ///   `AccessibilityReader.Outcome.oversized`），但边框是准的。有它就贴着
    ///   文字采样，没有就退回以光标为中心的固定框。
    nonisolated static func text(near quartzPoint: CGPoint, within hint: CGRect?) async -> Result? {
        guard hasPermission() else { return nil }

        // 上限而非定值。尺寸不能一味放大——实测 Vision 在 1920×1080 点
        // （8.3 百万像素）上直接返回 0 行，识别整个失效。1400×520 约
        // 2.9 百万像素、OCR 约 930 ms，是目前找到的可用区间上沿。
        let maxWidth: CGFloat = 1400
        let maxHeight: CGFloat = 520

        var rect: CGRect
        if let hint, hint.width > 40, hint.height > 10 {
            // 横向：贴着这块文字自己的宽度走，句子不会被腰斩。
            // 真比上限还宽时，退回以光标为中心截取上限那一段。
            let width = min(hint.width + 16, maxWidth)
            let x = hint.width + 16 <= maxWidth ? hint.minX - 8 : quartzPoint.x - width / 2
            // 纵向：仍要限高（OCR 成本按像素算），但预算**偏上给**，不再以
            // 光标为中心平分。理由是文字从上往下读：指在段落中间时，用户
            // 要的是"从这段开头到这儿"，不是"这儿往下"。段落装得下就整段
            // 拿——所以短段落的框反而更小，OCR 比固定框快。
            let headroom = maxHeight - 120
            let top = max(hint.minY - 4, quartzPoint.y - headroom)
            let bottom = min(hint.maxY + 4, top + maxHeight)
            rect = CGRect(x: x, y: top, width: width, height: max(bottom - top, 0))
        } else {
            rect = CGRect(
                x: quartzPoint.x - maxWidth / 2,
                y: quartzPoint.y - maxHeight / 2,
                width: maxWidth,
                height: maxHeight
            )
        }
        // 必须用 CGDisplayBounds：它和 quartzPoint 一样是原点左上的全局显示坐标。
        // 旧实现用的 NSScreen.frame 是原点左下的 AppKit 坐标，单屏时数字碰巧一样，
        // 接第二块显示器就会把采样框裁到错误的位置。
        rect = rect.intersection(activeDisplayBounds())
        Diagnostics.log("采样框 \(Int(rect.width))×\(Int(rect.height)) 点 = \(String(format: "%.1f", rect.width * rect.height * 4 / 1_000_000)) 百万像素 · \(hint == nil ? "固定框" : "跟随边框")")
        guard rect.width > 10, rect.height > 10,
              let image = await captureImage(in: rect) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // 同时认中文。只给 en-US 时，Vision 没有"这不是英文"这个选项，
        // 只能把汉字硬套成最像的拉丁字母（便宜→BilE、随便→IF E），
        // 再被 usesLanguageCorrection 纠正成看起来像正经单词的东西。
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        // Vision 的 boundingBox 是归一化的、原点左下；换算成采样框内的点坐标，原点左上。
        let lines: [RecognizedLine] = (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string,
                  let tidied = TextNormalizer.tidy(text, maximumLength: 500) else { return nil }
            let box = observation.boundingBox
            let frame = CGRect(
                x: box.minX * rect.width,
                y: (1 - box.maxY) * rect.height,
                width: box.width * rect.width,
                height: box.height * rect.height
            )
            return RecognizedLine(text: tidied, frame: frame)
        }

        let cursorInCapture = CGPoint(x: quartzPoint.x - rect.minX, y: quartzPoint.y - rect.minY)
        guard let assembled = TextBlockAssembler.assemble(lines: lines, around: cursorInCapture),
              let cleaned = TextNormalizer.clean(assembled) else { return nil }
        return Result(text: cleaned, method: "鼠标附近 OCR")
    }

    private nonisolated static func activeDisplayBounds() -> CGRect {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return .null }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return .null }
        return ids.reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }

    private nonisolated static func captureImage(in rect: CGRect) async -> CGImage? {
        await withCheckedContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

@MainActor
private final class HoverController {
    private let translationQueue: TranslationQueue
    private let overlay: TranslationOverlay
    private var timer: Timer?
    private var anchorPoint = NSEvent.mouseLocation
    private var stableSince = Date()
    /// 当前停留点是否已经取过一次词。鼠标移动或松开 ⌥ 时复位。
    private var hasTriedAtAnchor = false
    private var lastTranslatedText = ""
    private var lastTranslationDate = Date.distantPast
    private var requestID: UUID?
    private var manualRequestID: UUID?

    var enabled = true
    var ocrFallbackEnabled = true
    var requiresOption: Bool = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: AppConstants.requiresOptionPreference) != nil else { return true }
        return defaults.bool(forKey: AppConstants.requiresOptionPreference)
    }() {
        didSet {
            UserDefaults.standard.set(requiresOption, forKey: AppConstants.requiresOptionPreference)
            if requiresOption {
                requestID = nil
                overlay.hide()
            }
        }
    }

    init(queue: TranslationQueue, overlay: TranslationOverlay) {
        self.translationQueue = queue
        self.overlay = overlay
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        overlay.hide()
    }

    func translateSample() {
        submit(
            source: "Hover over an English label, button, or sentence to translate it.",
            method: "测试文本",
            at: NSEvent.mouseLocation,
            manual: true
        )
    }

    func prepareLanguages() {
        let id = UUID()
        requestID = id
        manualRequestID = id
        let point = NSEvent.mouseLocation
        overlay.showMessage("正在检查语言包…", at: point)
        let job = TranslationJob(id: id, operation: .prepareLanguages) { [weak self] result in
            guard let self, self.requestID == id else { return }
            switch result {
            case .success(let message):
                self.overlay.showMessage(message, at: point)
            case .failure(let error):
                self.overlay.showMessage("语言包尚未准备好", detail: error.localizedDescription, at: point)
            }
            self.clearManualRequest(id, after: 9)
        }
        Task { await translationQueue.enqueue(job) }
    }

    private func tick() {
        guard enabled else { return }
        let appKitPoint = NSEvent.mouseLocation

        if manualRequestID != nil {
            resetAnchor(to: appKitPoint)
            return
        }

        let globalFlags = CGEventSource.flagsState(.combinedSessionState)
        if requiresOption && !globalFlags.contains(.maskAlternate) {
            requestID = nil
            overlay.hide()
            resetAnchor(to: appKitPoint)
            return
        }

        let distance = hypot(appKitPoint.x - anchorPoint.x, appKitPoint.y - anchorPoint.y)
        if distance > 5 {
            overlay.hide()
            resetAnchor(to: appKitPoint)
            requestID = nil
            return
        }
        guard Date().timeIntervalSince(stableSince) >= AppConstants.hoverDelay else { return }

        // 旧实现在这里把 stableSince 推到 60 秒之后来防止重复触发，代价是
        // 一次失败就得干等一分钟。改用"当前停留点是否已经试过"的标记：
        // 鼠标一动或松开 ⌥ 就复位，原地重试的等待时间等于 hoverDelay 本身。
        guard !hasTriedAtAnchor else { return }
        hasTriedAtAnchor = true
        Diagnostics.log("▶ 开始取词 @(\(Int(appKitPoint.x)), \(Int(appKitPoint.y)))  OCR兜底=\(ocrFallbackEnabled)  辅助功能=\(AccessibilityReader.requestPermission(prompt: false))  屏幕录制=\(OCRReader.hasPermission())")

        guard AccessibilityReader.requestPermission(prompt: false) else {
            Diagnostics.log("放弃：没有辅助功能权限")
            overlay.showMessage("需要辅助功能权限", detail: "菜单栏 → 请求辅助功能权限", at: appKitPoint)
            return
        }

        let quartzPoint = CGEvent(source: nil)?.location ?? CGPoint(x: appKitPoint.x, y: appKitPoint.y)
        var ocrHint: CGRect?
        switch AccessibilityReader.outcome(at: quartzPoint) {
        case .text(let result):
            Diagnostics.log("辅助功能命中：\(Diagnostics.preview(result.text))")
            submit(source: result.text, method: result.method, at: appKitPoint)
            return
        case .frameOnly(let box):
            // 文字不要，边框要。
            ocrHint = box
            Diagnostics.log("辅助功能文字不可用，改用它的边框采样：\(Int(box.width))×\(Int(box.height)) @(\(Int(box.minX)), \(Int(box.minY)))")
        case .nothing:
            Diagnostics.log("辅助功能没读到文字，转 OCR")
        }

        guard ocrFallbackEnabled else {
            Diagnostics.log("放弃：OCR 兜底被手动关闭")
            overlay.showMessage("这里读不到文字", detail: "OCR 兜底当前是关闭的，可在菜单栏打开", at: appKitPoint)
            return
        }
        guard OCRReader.hasPermission() else {
            Diagnostics.log("放弃：没有屏幕录制权限")
            overlay.showMessage("需要屏幕录制权限", detail: "菜单栏 → 请求屏幕录制权限。这类应用（Electron 等）读不到文字，只能靠截图识别。", at: appKitPoint)
            return
        }

        Task { [weak self] in
            let result = await OCRReader.text(near: quartzPoint, within: ocrHint)
            guard let self else { return }
            guard let result else {
                Diagnostics.log("放弃：OCR 没在光标附近找到可翻译的文字")
                self.overlay.showMessage("这里没找到可翻译的英文", at: appKitPoint)
                return
            }
            Diagnostics.log("OCR 命中：\(Diagnostics.preview(result.text))")
            self.submit(source: result.text, method: result.method, at: appKitPoint)
        }
    }

    private func resetAnchor(to point: NSPoint) {
        anchorPoint = point
        stableSince = Date()
        hasTriedAtAnchor = false
    }

    private func submit(source: String, method: String, at point: NSPoint, manual: Bool = false) {
        let now = Date()
        // 只用来吃掉极短时间内的重复请求。原本是 12 秒，导致同一句话
        // 一分钟内看第二遍就没反应，和 hasTriedAtAnchor 的职责也重复了。
        if source == lastTranslatedText, now.timeIntervalSince(lastTranslationDate) < 1.5 { return }
        lastTranslatedText = source
        lastTranslationDate = now

        let id = UUID()
        requestID = id
        if manual { manualRequestID = id }
        overlay.showLoading(source: source, at: point)

        let job = TranslationJob(id: id, operation: .translate(source)) { [weak self] result in
            guard let self, self.requestID == id else { return }
            switch result {
            case .success(let translated):
                self.overlay.show(source: source, translation: translated, at: point, method: method)
            case .failure(let error):
                let message: String
                if error.localizedDescription.localizedCaseInsensitiveContains("install") ||
                    error.localizedDescription.contains("下载") {
                    message = "首次使用需要下载英语和中文翻译语言包"
                } else {
                    message = "翻译暂时不可用"
                }
                self.overlay.showMessage(message, detail: error.localizedDescription, at: point)
            }
            if manual { self.clearManualRequest(id, after: 11) }
        }
        Task { await translationQueue.enqueue(job) }
    }

    private func clearManualRequest(_ id: UUID, after seconds: UInt64) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.manualRequestID == id else { return }
            self.manualRequestID = nil
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let translationQueue = TranslationQueue()
    private let overlay = TranslationOverlay()
    private var hoverController: HoverController!
    private var statusItem: NSStatusItem!
    private var engineWindow: NSWindow!
    private var enabledItem: NSMenuItem!
    private var ocrItem: NSMenuItem!
    private var triggerItem: NSMenuItem!
    private var diagnosticsItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Diagnostics.log("═══ 启动 悬停翻译 0.4.0 ═══")
        installTranslationEngine()
        hoverController = HoverController(queue: translationQueue, overlay: overlay)
        installStatusMenu()
        hoverController.start()

        _ = AccessibilityReader.requestPermission(prompt: true)
    }

    private func installTranslationEngine() {
        let host = NSHostingView(rootView: TranslationEngineView(queue: translationQueue))
        engineWindow = NSWindow(
            contentRect: NSRect(x: -100, y: -100, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        engineWindow.contentView = host
        engineWindow.alphaValue = 0.01
        engineWindow.ignoresMouseEvents = true
        engineWindow.orderFrontRegardless()
    }

    private func installStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: AppConstants.appName)
        statusItem.button?.toolTip = "悬停翻译 0.4.0"

        let menu = NSMenu()
        let heading = NSMenuItem(title: "悬停翻译 0.4.0 · 英语 → 简体中文", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())

        enabledItem = NSMenuItem(title: "悬停翻译：开启", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = .on
        menu.addItem(enabledItem)

        triggerItem = NSMenuItem(title: "", action: #selector(toggleTriggerMode), keyEquivalent: "")
        triggerItem.target = self
        menu.addItem(triggerItem)
        refreshTriggerItem()

        ocrItem = NSMenuItem(title: "精准 OCR 兜底：开启", action: #selector(toggleOCR), keyEquivalent: "")
        ocrItem.target = self
        ocrItem.state = .on
        menu.addItem(ocrItem)

        let sample = NSMenuItem(title: "测试长句翻译", action: #selector(testTranslation), keyEquivalent: "")
        sample.target = self
        menu.addItem(sample)

        let prepare = NSMenuItem(title: "准备/检查翻译语言包…", action: #selector(prepareLanguages), keyEquivalent: "")
        prepare.target = self
        menu.addItem(prepare)

        menu.addItem(.separator())

        let accessibility = NSMenuItem(title: "请求辅助功能权限", action: #selector(requestAccessibility), keyEquivalent: "")
        accessibility.target = self
        menu.addItem(accessibility)

        let screen = NSMenuItem(title: "请求屏幕录制权限", action: #selector(requestScreenRecording), keyEquivalent: "")
        screen.target = self
        menu.addItem(screen)

        menu.addItem(.separator())

        diagnosticsItem = NSMenuItem(title: Diagnostics.enabled ? "排障日志：开启" : "排障日志：关闭", action: #selector(toggleDiagnostics), keyEquivalent: "")
        diagnosticsItem.target = self
        diagnosticsItem.state = Diagnostics.enabled ? .on : .off
        menu.addItem(diagnosticsItem)

        let revealLog = NSMenuItem(title: "打开排障日志", action: #selector(revealDiagnosticsLog), keyEquivalent: "")
        revealLog.target = self
        menu.addItem(revealLog)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出悬停翻译", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        hoverController.enabled.toggle()
        enabledItem.state = hoverController.enabled ? .on : .off
        enabledItem.title = hoverController.enabled ? "悬停翻译：开启" : "悬停翻译：暂停"
        if !hoverController.enabled { overlay.hide() }
    }

    @objc private func toggleOCR() {
        hoverController.ocrFallbackEnabled.toggle()
        ocrItem.state = hoverController.ocrFallbackEnabled ? .on : .off
        ocrItem.title = hoverController.ocrFallbackEnabled ? "精准 OCR 兜底：开启" : "精准 OCR 兜底：关闭"
    }

    @objc private func toggleTriggerMode() {
        hoverController.requiresOption.toggle()
        refreshTriggerItem()
    }

    private func refreshTriggerItem() {
        let requiresOption = hoverController?.requiresOption ?? true
        triggerItem.state = requiresOption ? .on : .off
        triggerItem.title = requiresOption
            ? "触发保护：按住 ⌥ 才翻译"
            : "触发保护：关闭（始终悬停）"
    }

    @objc private func toggleDiagnostics() {
        Diagnostics.enabled.toggle()
        diagnosticsItem.state = Diagnostics.enabled ? .on : .off
        diagnosticsItem.title = Diagnostics.enabled ? "排障日志：开启" : "排障日志：关闭"
        Diagnostics.log("——— 排障日志开启 ———")
    }

    @objc private func revealDiagnosticsLog() {
        if !FileManager.default.fileExists(atPath: Diagnostics.logURL.path) {
            let wasEnabled = Diagnostics.enabled
            Diagnostics.enabled = true
            Diagnostics.log("——— 日志文件创建 ———")
            Diagnostics.enabled = wasEnabled
        }
        NSWorkspace.shared.selectFile(Diagnostics.logURL.path, inFileViewerRootedAtPath: "")
    }

    @objc private func testTranslation() {
        hoverController.translateSample()
    }

    @objc private func prepareLanguages() {
        hoverController.prepareLanguages()
    }

    @objc private func requestAccessibility() {
        _ = AccessibilityReader.requestPermission(prompt: true)
    }

    @objc private func requestScreenRecording() {
        _ = OCRReader.requestPermission()
    }
}

@main
private enum HoverTranslateMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private static func runSelfTest() {
        let longSentence = "This tool translates a full selected paragraph, including multiple sentences, instead of limiting the result to a single word. It keeps the context needed for a natural Chinese translation."
        precondition(TextNormalizer.clean(longSentence) == longSentence)
        precondition(TextNormalizer.clean("纯中文界面") == nil)
        let oversized = String(repeating: "English sentence. ", count: 200)
        precondition(TextNormalizer.clean(oversized)?.count == AppConstants.maximumTextLength)
        print("SELF_TEST_OK: long sentences, language filtering, and length limit passed")
    }
}
