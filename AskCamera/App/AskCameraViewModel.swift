import AVFoundation
import Combine
import SwiftUI

/// 感知-决策-执行流水线的协调者：
/// 语音(SpeechAnalyzer) → 意图(FocusIntentParser) → 检测(ObjectDetecting) → 对焦(CameraManager)。
@MainActor
final class AskCameraViewModel: ObservableObject {

    let camera = CameraManager()
    private let speech = SpeechCommandListener()
    private let detector: ObjectDetecting = SalientObjectDetector()
    private let feedbackSynthesizer = AVSpeechSynthesizer()

    // MARK: - UI 状态

    @Published var volatileTranscript = ""
    @Published var statusText = "点击画面对焦，或开启麦克风说\u{201C}对焦到……\u{201D}"
    @Published var isListening = false
    @Published var focusHighlight: FocusHighlight?
    @Published var voiceFeedbackEnabled = false

    struct FocusHighlight: Identifiable, Equatable {
        let id = UUID()
        /// 视图坐标系下的高亮区域。
        let rect: CGRect
        let label: String
    }

    private var listeningTask: Task<Void, Never>?
    private var highlightDismissTask: Task<Void, Never>?

    // MARK: - 生命周期

    func onAppear() {
        Task { await camera.start() }
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
                statusText = "正在聆听，说\u{201C}对焦到……\u{201D}"
                for await event in events {
                    switch event {
                    case .volatile(let text):
                        volatileTranscript = text
                    case .final(let text):
                        volatileTranscript = ""
                        await handleFinalTranscript(text)
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
        statusText = "已停止聆听"
    }

    // MARK: - 指令处理

    private func handleFinalTranscript(_ text: String) async {
        guard let intent = FocusIntentParser.parse(text) else {
            statusText = "\u{201C}\(text)\u{201D}（未识别为对焦指令）"
            return
        }

        let targetName = intent.target ?? "显著物体"
        statusText = "正在寻找：\(targetName)"

        guard let frame = camera.latestFrame() else {
            statusText = "相机尚未就绪"
            return
        }

        do {
            guard let result = try await detector.detect(target: intent.target, in: frame) else {
                statusText = "画面中未找到\u{201C}\(targetName)\u{201D}"
                return
            }
            focusOnDetection(result)
        } catch {
            statusText = "检测失败：\(error.localizedDescription)"
        }
    }

    /// 将 Vision 归一化框（左下原点）转换为设备对焦点并执行对焦。
    private func focusOnDetection(_ result: DetectionResult) {
        guard let layer = camera.previewLayer else { return }

        let box = result.boundingBox
        // Vision（左下原点）→ 元数据输出坐标（左上原点）
        let metadataRect = CGRect(x: box.origin.x,
                                  y: 1 - box.origin.y - box.height,
                                  width: box.width,
                                  height: box.height)
        let layerRect = layer.layerRectConverted(fromMetadataOutputRect: metadataRect)
        let center = CGPoint(x: layerRect.midX, y: layerRect.midY)
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: center)

        camera.focus(atDevicePoint: devicePoint)
        showHighlight(rect: layerRect, label: result.label)
        statusText = "已对焦：\(result.label)（置信度 \(String(format: "%.0f%%", result.confidence * 100))）"
        speakFeedback("已对焦到\(result.label)")
    }

    // MARK: - 点击对焦

    func handleTap(at viewPoint: CGPoint) {
        guard let layer = camera.previewLayer else { return }
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

    private func showHighlight(rect: CGRect, label: String) {
        focusHighlight = FocusHighlight(rect: rect, label: label)
        highlightDismissTask?.cancel()
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
