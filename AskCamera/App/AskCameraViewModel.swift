import AVFoundation
import Combine
import SwiftUI

/// 感知-决策-执行流水线的协调者：
/// 语音(SpeechAnalyzer) → 采集指令(CaptureCommand) / 查询理解(QueryUnderstanding → DetectionQuery)
/// → 检测(YOLO-World / 显著性兜底) → 对焦 / 拍照 / 录像(CameraManager)。
@MainActor
final class AskCameraViewModel: ObservableObject {

    let camera = CameraManager()
    let captureScheduler = CaptureScheduler()
    private let speech = SpeechCommandListener()
    private let salientDetector = SalientObjectDetector()
    private var yoloDetector: YOLOWorldDetector?
    private let tracker = FocusTracker()
    private let feedbackSynthesizer = AVSpeechSynthesizer()
    private let countdownBeeper = CountdownBeeper()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - UI 状态

    @Published var volatileTranscript = ""
    @Published var statusText = "点击画面对焦，或说\u{201C}对焦到……\u{201D}/\u{201C}拍照\u{201D}/\u{201C}录像\u{201D}"
    @Published var isListening = false
    @Published var focusHighlight: FocusHighlight?
    @Published var voiceFeedbackEnabled = false
    /// 倒计时用后置手电筒 + 屏幕闪白，模拟相机自拍灯。
    @Published var countdownTorchEnabled = false
    /// 倒计时滴声同步的屏幕闪白。
    @Published private(set) var countdownFlashOn = false
    @Published private(set) var openVocabularyReady = false
    /// 倒计时 / 录像结束后是否恢复听写。
    private var resumeListeningAfterIdle = false

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

    /// 已执行指令对应的转写原文。后续字幕只显示这段之后的新内容；
    /// 定稿后会重置识别输入，此字段主要作重置失败时的字符串回退。
    private var consumedTranscript = ""

    /// 与 SpeechCommandListener.inputGeneration 对齐，丢掉上一句残留事件。
    private var speechGeneration: UInt64 = 0

    private var listeningTask: Task<Void, Never>?
    private var highlightDismissTask: Task<Void, Never>?

    /// volatile 快路径状态：未定稿文本解析出完整指令并稳定 400ms 即执行，final 到达时去重。
    private var volatileCommandTask: Task<Void, Never>?
    private var lastExecutedQuery: DetectionQuery?
    private var lastExecutedCaptureCommand: CaptureCommand?
    private var lastExecutedAt: TimeInterval = 0
    /// 上次已执行的目标短语，ASR 改写前文时用它从累积转写里切开。
    private var lastConsumedTarget = ""
    private var countdownCueTask: Task<Void, Never>?

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
        // 嵌套 ObservableObject：转发 scheduler 变更以刷新倒计时 UI
        captureScheduler.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        camera.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

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
        // 查询理解端模型预热（无 Apple Intelligence 时内部直接返回）
        QueryUnderstanding.warmUp()
    }

    // MARK: - 手动拍照 / 录像

    func shutterTapped() {
        Task { await executeCapture(.photo(delaySeconds: 0)) }
    }

    func recordTapped() {
        Task {
            if camera.isRecording {
                await executeCapture(.stopVideo)
            } else {
                await executeCapture(.startVideo(
                    delaySeconds: 0,
                    durationSeconds: CaptureCommand.defaultVideoDurationSeconds
                ))
            }
        }
    }

    func cancelCountdownTapped() {
        Task { await executeCapture(.cancelPending) }
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
                speechGeneration = speech.inputGeneration
                consumedTranscript = ""
                lastConsumedTarget = ""
                captionHistory = []
                volatileTranscript = ""
                statusText = "正在聆听：对焦 / 拍照 / 录像"
                for await event in events {
                    switch event {
                    case .volatile(let text, let alternatives, let generation):
                        guard generation == speechGeneration else { continue }
                        let leftover = leftoverTranscript(from: text)
                        volatileTranscript = leftover
                        scheduleVolatileCommand(sourceText: text, alternatives: alternatives)
                    case .final(let text, let alternatives, let generation):
                        guard generation == speechGeneration else { continue }
                        volatileTranscript = ""
                        volatileCommandTask?.cancel()
                        let leftover = leftoverTranscript(from: text)
                        if !leftover.isEmpty {
                            appendCaption(leftover)
                        }
                        await handleTranscriptCandidates(best: text, alternatives: alternatives, isFinal: true)
                        await resetRecognizerAfterUtterance()
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
        lastConsumedTarget = ""
        statusText = "已停止聆听"
    }

    // MARK: - 指令处理

    private static let captionTrimCharacters = TranscriptWindow.trimCharacters

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
        TranscriptWindow.leftover(from: full, consumed: consumedTranscript, lastCommand: lastConsumedTarget)
    }

    /// 指令已执行：记下已消费原文并清空字幕，下一句从空白开始。
    private func consumeTranscript(_ text: String) {
        consumedTranscript = text
        captionHistory = []
        volatileTranscript = ""
    }

    /// 定稿处理完后重置识别输入，避免下一句粘在旧转写上。
    private func resetRecognizerAfterUtterance() async {
        guard isListening else { return }
        await speech.beginNewUtterance()
        speechGeneration = speech.inputGeneration
        consumedTranscript = ""
        lastConsumedTarget = ""
        captionHistory = []
        volatileTranscript = ""
    }

    /// volatile 快路径：未定稿文本已解析出完整指令时，稳定 400ms 后立即执行，
    /// 不等定稿（定稿往往滞后 1~2 秒）。文本再变化会重置计时。
    /// 仅走规则+词典，不调用端模型（半句/延迟敏感）。
    /// 最优转写解析失败时，再试 n-best 候选。
    private func scheduleVolatileCommand(sourceText: String, alternatives: [String] = []) {
        volatileCommandTask?.cancel()
        let candidates = transcriptCandidates(best: sourceText, alternatives: alternatives)
        guard let chosen = CommandCandidateRanker.pick(
            best: candidates.first ?? sourceText,
            alternatives: Array(candidates.dropFirst()),
            leftover: leftoverTranscript
        ), canScheduleVolatile(leftoverTranscript(from: chosen)) else {
            return
        }
        let chosenLeftover = leftoverTranscript(from: chosen)
        let isAttributed: Bool = {
            guard let command = FocusIntentParser.parseCommand(chosenLeftover),
                  case .focus(let intent) = command,
                  let target = intent.target else { return false }
            return TargetTranslator.isAttributedPhrase(target)
        }()
        volatileCommandTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.handleTranscript(chosenLeftover, sourceText: chosen, isFinal: isAttributed)
        }
    }

    private func canScheduleVolatile(_ leftover: String) -> Bool {
        CommandCandidateRanker.score(leftover) >= 70
    }

    private func transcriptCandidates(best: String, alternatives: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for text in [best] + alternatives {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    private func handleTranscriptCandidates(best: String, alternatives: [String], isFinal: Bool) async {
        let candidates = transcriptCandidates(best: best, alternatives: alternatives)
        if let chosen = CommandCandidateRanker.pick(
            best: candidates.first ?? best,
            alternatives: Array(candidates.dropFirst()),
            leftover: leftoverTranscript,
            allowOpenPrimary: isFinal
        ) {
            let leftover = leftoverTranscript(from: chosen)
            if await handleTranscript(leftover, sourceText: chosen, isFinal: isFinal) {
                return
            }
        }
        if isFinal {
            let leftover = leftoverTranscript(from: best)
            if !leftover.isEmpty {
                statusText = "\u{201C}\(leftover)\u{201D}（未识别为指令）"
            }
            // 解析失败也消费：若识别输入还没重置成功，下一句 leftover 只剩后缀
            consumeTranscript(best)
        }
    }

    @discardableResult
    private func handleTranscript(_ leftover: String, sourceText: String, isFinal: Bool) async -> Bool {
        guard !leftover.isEmpty else { return false }
        let now = CACurrentMediaTime()

        // volatile：只用规则；final：规则未命中时由端模型理解非正式动作/主体
        guard let intent = await QueryUnderstanding.understand(leftover, allowLanguageModel: isFinal) else {
            return false
        }

        switch intent {
        case .capture(let capture):
            if capture == lastExecutedCaptureCommand, now - lastExecutedAt < 3 {
                return true
            }
            lastExecutedCaptureCommand = capture
            lastExecutedAt = now
            print("[ViewModel] route=capture isFinal=\(isFinal) leftover=\(leftover) command=\(capture)")
            await executeCapture(capture)
            lastConsumedTarget = leftover
            consumeTranscript(sourceText)
            return true

        case .query(let query):
            if query.action == .none { return false }
            if query.objectUnresolved {
                if isFinal {
                    statusText = "还不能把\u{201C}\(query.displayName)\u{201D}当成检测目标"
                    consumeTranscript(sourceText)
                }
                return isFinal
            }

            if query.action == lastExecutedQuery?.action,
               query.yoloPrompts == lastExecutedQuery?.yoloPrompts,
               query.spatialHint == lastExecutedQuery?.spatialHint,
               now - lastExecutedAt < 3 {
                return true
            }
            lastExecutedQuery = query
            lastExecutedAt = now

            print("[ViewModel] route=focus isFinal=\(isFinal) leftover=\(leftover) action=\(query.action) prompts=\(query.yoloPrompts) saliency=\(query.useSaliency)")
            await execute(query)
            lastConsumedTarget = leftover
            consumeTranscript(sourceText)
            return true
        }
    }

    // MARK: - 采集执行

    private func executeCapture(_ command: CaptureCommand) async {
        switch command {
        case .cancelPending:
            guard captureScheduler.hasPendingCountdown else {
                statusText = "当前没有倒计时"
                return
            }
            captureScheduler.cancelPending()
            await stopCountdownCues()
            statusText = "已取消倒计时"
            speakFeedback("已取消倒计时")
            resumeListeningIfNeeded()

        case .stopVideo:
            await stopRecordingAndMaybeResumeListening()

        case .photo(let delay):
            if delay > 0 {
                statusText = "\(delay) 秒后拍照"
                pauseListeningIfNeeded()
            }
            captureScheduler.schedulePhoto(
                delaySeconds: delay,
                tick: { [weak self] remaining in await self?.playCountdownCue(remaining: remaining) }
            ) { [weak self] in
                await self?.stopCountdownCues()
                await self?.performPhoto()
                self?.resumeListeningIfNeeded()
            }

        case .startVideo(let delay, let duration):
            if camera.isRecording {
                statusText = "已在录像中"
                speakFeedback("已在录像中")
                return
            }
            if delay > 0 {
                statusText = "\(delay) 秒后开始录 \(duration) 秒"
                pauseListeningIfNeeded()
            } else {
                statusText = "准备录制 \(duration) 秒"
            }
            captureScheduler.scheduleVideo(
                delaySeconds: delay,
                durationSeconds: duration,
                tick: { [weak self] remaining in await self?.playCountdownCue(remaining: remaining) },
                start: { [weak self] in
                    await self?.stopCountdownCues()
                    await self?.performStartRecording(durationSeconds: duration)
                },
                stop: { [weak self] in await self?.stopRecordingAndMaybeResumeListening() }
            )
        }
    }

    private func performPhoto() async {
        do {
            statusText = "正在拍照……"
            try await camera.capturePhoto()
            statusText = "照片已保存到相册"
            speakFeedback("已拍照")
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func performStartRecording(durationSeconds: Int) async {
        // 策略 A：录像时暂停 ASR，麦克风留给影片音轨
        pauseListeningIfNeeded()

        do {
            try await camera.startRecording()
            captureScheduler.markRecordingStarted()
            statusText = "正在录像（\(durationSeconds) 秒）"
            speakFeedback("开始录像")
        } catch {
            captureScheduler.clearRecordingTimers()
            statusText = error.localizedDescription
            resumeListeningIfNeeded()
        }
    }

    private func stopRecordingAndMaybeResumeListening() async {
        captureScheduler.clearRecordingTimers()
        guard camera.isRecording else {
            statusText = "当前没有在录像"
            return
        }
        do {
            statusText = "正在保存视频……"
            try await camera.stopRecording()
            statusText = "视频已保存到相册"
            speakFeedback("录像完成")
        } catch {
            statusText = error.localizedDescription
        }
        resumeListeningIfNeeded()
    }

    /// 为录像 / 倒计时让出麦克风：停止听写，结束后按标记恢复。
    private func pauseListeningIfNeeded() {
        guard isListening else { return }
        resumeListeningAfterIdle = true
        pauseListeningForCapture()
    }

    private func resumeListeningIfNeeded() {
        guard resumeListeningAfterIdle else { return }
        guard !camera.isRecording, !captureScheduler.isCountingDown else { return }
        resumeListeningAfterIdle = false
        startListening()
    }

    private func pauseListeningForCapture() {
        listeningTask?.cancel()
        listeningTask = nil
        volatileCommandTask?.cancel()
        Task { await speech.stop() }
        isListening = false
        volatileTranscript = ""
    }

    private func execute(_ query: DetectionQuery) async {
        // 新指令先停掉旧跟踪，避免检测耗时期间旧框继续写 highlight。
        tracker.stop()
        trackingGeneration = 0

        switch query.action {
        case .none:
            return
        case .reset:
            focusHighlight = nil
            camera.resetFocusToCenter()
            statusText = "已恢复自动对焦"
            speakFeedback("已恢复自动对焦")
            return
        case .focus:
            break
        }

        if query.objectUnresolved {
            statusText = "还不能把\u{201C}\(query.displayName)\u{201D}当成检测目标"
            return
        }

        let displayName = query.displayName.isEmpty ? "显著物体" : query.displayName
        statusText = "正在寻找：\(displayName)"

        guard let frame = camera.latestFrame() else {
            statusText = "相机尚未就绪"
            return
        }

        do {
            let start = CACurrentMediaTime()
            let candidates = try await findCandidates(for: query, in: frame)
            let elapsedMs = (CACurrentMediaTime() - start) * 1000

            if debugMode {
                updateDebugBoxes(with: candidates)
            }

            guard let chosen = choose(from: candidates, hint: query.spatialHint) else {
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

    /// 有 YOLO prompts 且模型可用走开放词汇检测，否则显著性兜底。
    private func findCandidates(for query: DetectionQuery,
                                in frame: CVPixelBuffer) async throws -> [DetectionResult] {
        if !query.useSaliency, !query.yoloPrompts.isEmpty, let yolo = yoloDetector {
            let label = query.yoloPrompts.first ?? query.displayName
            print("[ViewModel] detect=yolo-world prompts=\(query.yoloPrompts)")
            let results = try await yolo.detect(prompts: query.yoloPrompts, label: label, in: frame)
            if !results.isEmpty {
                return results
            }
            print("[ViewModel] detect=yolo-world 未找到目标")
            return []
        }
        print("[ViewModel] detect=saliency display=\(query.displayName)")
        return try await salientDetector.detect(target: query.displayName, in: frame)
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
        // 倒计时闪灯期间不要重配对焦/曝光，避免把手电筒冲掉
        if captureScheduler.isCountingDown { return }
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

    /// 每秒按单反节奏滴一声或连滴；闪光灯开启时手电筒与屏幕同步闪。
    private func playCountdownCue(remaining: Int) async {
        countdownCueTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runCountdownCue(remaining: remaining)
        }
        countdownCueTask = task
        await task.value
    }

    private func runCountdownCue(remaining: Int) async {
        let beeps = CountdownBeeper.beepCount(remaining: remaining)
        let windowNs: UInt64 = 900_000_000
        let onMs: UInt64 = remaining <= 2 ? 45 : 60
        let intervalNs = windowNs / UInt64(max(beeps, 1))

        for i in 0..<beeps {
            guard !Task.isCancelled else { return }
            countdownBeeper.play()
            if countdownTorchEnabled {
                countdownFlashOn = true
                Task { await self.camera.setTorchEnabled(true) }
            }
            try? await Task.sleep(for: .milliseconds(onMs))
            if countdownTorchEnabled {
                countdownFlashOn = false
                Task { await self.camera.setTorchEnabled(false) }
            }
            if i < beeps - 1 {
                let elapsedOnNs = onMs * 1_000_000
                let gapNs = intervalNs > elapsedOnNs ? intervalNs - elapsedOnNs : 20_000_000
                try? await Task.sleep(nanoseconds: gapNs)
            }
        }
    }

    private func stopCountdownCues() async {
        countdownCueTask?.cancel()
        countdownCueTask = nil
        countdownBeeper.stop()
        countdownFlashOn = false
        await camera.setTorchEnabled(false)
    }
}
