import AVFoundation
import Combine
import SwiftUI

/// 感知-决策-执行流水线的协调者：
/// 语音(SpeechAnalyzer) → 意图(FocusIntentParser) → 翻译(TargetTranslator)
/// → 检测(YOLO-World / 显著性兜底) → 对焦(CameraManager)。
@MainActor
final class AskCameraViewModel: ObservableObject {

    let camera = CameraManager()
    private let speech = SpeechCommandListener()
    private let salientDetector = SalientObjectDetector()
    private var yoloDetector: YOLOWorldDetector?
    private let tracker = FocusTracker()
    private let feedbackSynthesizer = AVSpeechSynthesizer()

    // MARK: - UI 状态

    @Published var volatileTranscript = ""
    @Published var statusText = "点击画面对焦，或开启麦克风说\u{201C}对焦到……\u{201D}"
    @Published var isListening = false
    @Published var focusHighlight: FocusHighlight?
    @Published var voiceFeedbackEnabled = false
    @Published private(set) var openVocabularyReady = false

    /// 调试模式：显示所有候选框、分数与各环节耗时。
    @Published var debugMode = false
    @Published var debugBoxes: [DebugBox] = []

    struct DebugBox: Identifiable {
        let id = UUID()
        /// 视图坐标系下的候选框。
        let rect: CGRect
        let caption: String
    }

    struct FocusHighlight: Identifiable, Equatable {
        let id = UUID()
        /// 视图坐标系下的高亮区域。
        let rect: CGRect
        let label: String
    }

    /// 实时字幕：尚未被指令消费的定稿行。
    @Published var captionHistory: [CaptionLine] = []

    struct CaptionLine: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    /// 已执行指令对应的转写原文。后续字幕只显示这段之后的新内容，
    /// 避免 SpeechAnalyzer 连续会话把上一句拼进下一句。
    private var consumedTranscript = ""

    private var listeningTask: Task<Void, Never>?
    private var highlightDismissTask: Task<Void, Never>?

    /// volatile 快路径状态：未定稿文本解析出完整指令并稳定 400ms 即执行，final 到达时去重。
    private var volatileCommandTask: Task<Void, Never>?
    private var lastExecutedCommand: FocusCommand?
    private var lastExecutedAt: TimeInterval = 0

    /// 跟踪节流状态。
    private var trackedLabel = ""
    private var lastRefocusCenter: CGPoint = .zero
    private var lastRefocusTime: TimeInterval = 0
    private var lastHighlightTime: TimeInterval = 0
    /// 与 FocusTracker.start 返回的世代号对齐，丢弃过期的跟踪回调。
    private var trackingGeneration: UInt64 = 0

    // MARK: - 生命周期

    func onAppear() {
        Task { await camera.start() }
        // 相机输出队列上逐帧驱动跟踪器
        camera.frameHandler = { [weak self] pixelBuffer in
            guard let self, let update = self.tracker.process(pixelBuffer) else { return }
            Task { @MainActor in
                self.handleTrackingUpdate(update)
            }
        }
        // 模型加载 + 预热放后台，避免阻塞首帧；预热触发 ANE 图编译，消除首次对焦的冷启动
        Task.detached(priority: .userInitiated) { [weak self] in
            let detector = YOLOWorldDetector.loadFromBundle()
            await detector?.warmUp()
            await MainActor.run {
                self?.yoloDetector = detector
                self?.openVocabularyReady = detector != nil
                if detector == nil {
                    print("[ViewModel] YOLO-World 模型未随包分发，语音对焦将使用显著性兜底")
                }
            }
        }
    }

    // MARK: - 语音控制

    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    private func startListening() {
        listeningTask = Task { [weak self] in
            guard let self else { return }
            do {
                statusText = "正在准备语音模型……"
                let events = try await speech.start()
                isListening = true
                consumedTranscript = ""
                captionHistory = []
                volatileTranscript = ""
                statusText = "正在聆听，说\u{201C}对焦到……\u{201D}"
                for await event in events {
                    switch event {
                    case .volatile(let text):
                        volatileTranscript = leftoverTranscript(from: text)
                        scheduleVolatileCommand(from: text)
                    case .final(let text):
                        volatileTranscript = ""
                        volatileCommandTask?.cancel()
                        let leftover = leftoverTranscript(from: text)
                        if !leftover.isEmpty {
                            appendCaption(leftover)
                        }
                        await handleTranscript(text, isFinal: true)
                    }
                }
            } catch {
                statusText = "语音识别启动失败：\(error.localizedDescription)"
            }
            isListening = false
        }
    }

    private func stopListening() {
        listeningTask?.cancel()
        listeningTask = nil
        Task { await speech.stop() }
        isListening = false
        volatileTranscript = ""
        captionHistory = []
        consumedTranscript = ""
        statusText = "已停止聆听"
    }

    // MARK: - 指令处理

    private static let captionTrimCharacters = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(CharacterSet(charactersIn: "。！？、，,.!?"))

    /// 定稿字幕，保留最近 3 行；指令执行后会整表清空。
    private func appendCaption(_ text: String) {
        let trimmed = text.trimmingCharacters(in: Self.captionTrimCharacters)
        guard !trimmed.isEmpty else { return }
        captionHistory.append(CaptionLine(text: trimmed))
        if captionHistory.count > 3 {
            captionHistory.removeFirst(captionHistory.count - 3)
        }
    }

    /// 去掉已执行指令对应的前缀，只留下尚未消费的新句子。
    private func leftoverTranscript(from full: String) -> String {
        let consumed = consumedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !consumed.isEmpty else {
            return full.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if full.hasPrefix(consumed) {
            return String(full.dropFirst(consumed.count))
                .trimmingCharacters(in: Self.captionTrimCharacters)
        }
        if let range = full.range(of: consumed) {
            return String(full[range.upperBound...])
                .trimmingCharacters(in: Self.captionTrimCharacters)
        }
        return full.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 指令已执行：记下已消费原文并清空字幕，下一句从空白开始。
    private func consumeTranscript(_ text: String) {
        consumedTranscript = text
        captionHistory = []
        volatileTranscript = ""
    }

    /// volatile 快路径：未定稿文本已解析出完整指令时，稳定 400ms 后立即执行，
    /// 不等定稿（定稿往往滞后 1~2 秒）。文本再变化会重置计时。
    private func scheduleVolatileCommand(from text: String) {
        guard let command = FocusIntentParser.parseCommand(text) else { return }
        // 无目标的裸"对焦"只在定稿时执行：说到一半的"对焦到……"会被暂时解析成
        // 无目标指令，快路径执行会误触发显著性对焦
        if case .focus(let intent) = command, intent.target == nil {
            return
        }
        volatileCommandTask?.cancel()
        volatileCommandTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.handleTranscript(text, isFinal: false)
        }
    }

    private func handleTranscript(_ text: String, isFinal: Bool) async {
        guard let command = FocusIntentParser.parseCommand(text) else {
            if isFinal {
                statusText = "\u{201C}\(text)\u{201D}（未识别为对焦指令）"
            }
            return
        }

        // volatile 与 final 去重：相同指令 3 秒内只执行一次
        let now = CACurrentMediaTime()
        if command == lastExecutedCommand, now - lastExecutedAt < 3 {
            return
        }
        lastExecutedCommand = command
        lastExecutedAt = now

        await execute(command)
        consumeTranscript(text)
    }

    private func execute(_ command: FocusCommand) async {
        // 新指令先停掉旧跟踪，避免检测耗时期间旧框继续写 highlight。
        tracker.stop()
        trackingGeneration = 0

        let intent: FocusIntent
        switch command {
        case .reset:
            focusHighlight = nil
            camera.resetFocusToCenter()
            statusText = "已恢复自动对焦"
            speakFeedback("已恢复自动对焦")
            return
        case .focus(let focusIntent):
            intent = focusIntent
        }

        let displayName = intent.target ?? "显著物体"
        statusText = "正在寻找：\(displayName)"

        guard let frame = camera.latestFrame() else {
            statusText = "相机尚未就绪"
            return
        }

        do {
            let start = CACurrentMediaTime()
            let candidates = try await findCandidates(for: intent, in: frame)
            let elapsedMs = (CACurrentMediaTime() - start) * 1000

            if debugMode {
                updateDebugBoxes(with: candidates)
            }

            guard let chosen = choose(from: candidates, hint: intent.spatialHint) else {
                statusText = debugMode
                    ? "画面中未找到\u{201C}\(displayName)\u{201D}（检测 \(Int(elapsedMs))ms）"
                    : "画面中未找到\u{201C}\(displayName)\u{201D}"
                return
            }
            focusOnDetection(chosen, displayName: displayName,
                             detectionMs: debugMode ? elapsedMs : nil)
        } catch {
            statusText = "检测失败：\(error.localizedDescription)"
        }
    }

    /// 调试模式：把本次所有候选框画到预览上（5 秒后自动清除）。
    private func updateDebugBoxes(with candidates: [DetectionResult]) {
        debugBoxes = candidates.compactMap { result in
            guard let layerRect = camera.layerRect(fromVisionRect: result.boundingBox) else { return nil }
            return DebugBox(rect: layerRect,
                            caption: "\(result.label) \(Int(result.confidence * 100))%")
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.debugBoxes = []
        }
    }

    /// 有目标词且 YOLO-World 可用走开放词汇检测，否则显著性兜底。
    private func findCandidates(for intent: FocusIntent,
                                in frame: CVPixelBuffer) async throws -> [DetectionResult] {
        if let target = intent.target, let yolo = yoloDetector {
            let englishTarget = await TargetTranslator.translate(target)
            let results = try await yolo.detect(target: englishTarget, in: frame)
            if !results.isEmpty {
                return results
            }
            // 开放词汇没找到时不静默降级——用户点名的目标不在画面里就该如实报告
            return []
        }
        return try await salientDetector.detect(target: intent.target, in: frame)
    }

    /// 按方位修饰从候选中选择；无修饰时取置信度最高者。
    /// 候选框为 Vision 坐标（左下原点）：top 对应 y 大，bottom 对应 y 小。
    private func choose(from candidates: [DetectionResult], hint: SpatialHint?) -> DetectionResult? {
        guard !candidates.isEmpty else { return nil }
        guard let hint, candidates.count > 1 else { return candidates.first }

        switch hint {
        case .left:
            return candidates.min { $0.boundingBox.midX < $1.boundingBox.midX }
        case .right:
            return candidates.max { $0.boundingBox.midX < $1.boundingBox.midX }
        case .top:
            return candidates.max { $0.boundingBox.midY < $1.boundingBox.midY }
        case .bottom:
            return candidates.min { $0.boundingBox.midY < $1.boundingBox.midY }
        }
    }

    /// 将 Vision 归一化框（左下原点）转换为设备对焦点并执行对焦，随后启动焦点跟随。
    private func focusOnDetection(_ result: DetectionResult, displayName: String,
                                  detectionMs: Double? = nil) {
        guard let layerRect = focusCamera(onVisionRect: result.boundingBox) else { return }

        trackedLabel = displayName
        trackingGeneration = tracker.start(with: result.boundingBox)

        showHighlight(rect: layerRect, label: displayName, autoDismiss: false)
        var status = "已对焦并跟踪：\(displayName)（置信度 \(String(format: "%.0f%%", result.confidence * 100))）"
        if let detectionMs {
            status += "（检测 \(Int(detectionMs))ms）"
        }
        statusText = status
        speakFeedback("已对焦到\(displayName)")
    }

    /// Vision 框 → 预览层坐标 + 设备坐标，执行对焦。返回预览层中的框（供高亮显示）。
    @discardableResult
    private func focusCamera(onVisionRect box: CGRect) -> CGRect? {
        guard let layer = camera.previewLayer,
              let layerRect = camera.layerRect(fromVisionRect: box) else { return nil }

        let center = CGPoint(x: layerRect.midX, y: layerRect.midY)
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: center)

        camera.focus(atDevicePoint: devicePoint)
        lastRefocusCenter = CGPoint(x: box.midX, y: box.midY)
        lastRefocusTime = CACurrentMediaTime()
        return layerRect
    }

    // MARK: - 焦点跟随

    private func handleTrackingUpdate(_ update: FocusTracker.Update) {
        switch update {
        case .lost(let generation):
            guard generation == trackingGeneration else { return }
            focusHighlight = nil
            statusText = "\u{201C}\(trackedLabel)\u{201D}已离开画面，恢复自动对焦"
            camera.resetFocusToCenter()

        case .tracking(let box, let generation):
            guard generation == trackingGeneration else { return }
            let now = CACurrentMediaTime()
            let center = CGPoint(x: box.midX, y: box.midY)
            let moved = hypot(center.x - lastRefocusCenter.x, center.y - lastRefocusCenter.y)

            // 节流：目标移动超过 3% 画幅且距上次对焦超过 0.3s 才重新对焦
            if moved > 0.03, now - lastRefocusTime > 0.3 {
                focusCamera(onVisionRect: box)
            }

            // 高亮框以约 10fps 刷新
            if now - lastHighlightTime > 0.1,
               let layerRect = camera.layerRect(fromVisionRect: box) {
                lastHighlightTime = now
                showHighlight(rect: layerRect, label: trackedLabel, autoDismiss: false)
            }
        }
    }

    // MARK: - 点击对焦

    func handleTap(at viewPoint: CGPoint) {
        guard let layer = camera.previewLayer else { return }
        // 手动点击打断跟踪
        tracker.stop()
        trackingGeneration = 0
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: viewPoint)
        camera.focus(atDevicePoint: devicePoint)

        let side: CGFloat = 80
        showHighlight(rect: CGRect(x: viewPoint.x - side / 2,
                                   y: viewPoint.y - side / 2,
                                   width: side,
                                   height: side),
                      label: "手动对焦")
        statusText = "手动对焦"
    }

    // MARK: - 反馈

    private func showHighlight(rect: CGRect, label: String, autoDismiss: Bool = true) {
        focusHighlight = FocusHighlight(rect: rect, label: label)
        highlightDismissTask?.cancel()
        guard autoDismiss else { return }
        highlightDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.focusHighlight = nil
        }
    }

    private func speakFeedback(_ text: String) {
        guard voiceFeedbackEnabled else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        feedbackSynthesizer.speak(utterance)
    }
}
