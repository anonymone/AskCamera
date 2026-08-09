import AVFoundation
import Foundation
import Speech

/// 语音识别事件：volatile 为实时未定稿文本，final 为定稿文本（触发指令解析）。
enum TranscriptEvent {
    case volatile(String)
    case final(String)
}

enum SpeechListenerError: LocalizedError {
    case microphoneDenied
    case localeNotSupported(Locale)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "麦克风权限被拒绝"
        case .localeNotSupported(let locale):
            return "设备端语音模型不支持语言：\(locale.identifier)"
        }
    }
}

/// 基于 iOS 26 SpeechAnalyzer 的端侧流式语音识别。
/// 音频不出设备；语言模型由系统 AssetInventory 管理（首次使用自动下载）。
final class SpeechCommandListener {

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    private(set) var isListening = false

    /// 启动监听，返回识别事件流。
    func start(locale: Locale = Locale(identifier: "zh-CN")) async throws -> AsyncStream<TranscriptEvent> {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw SpeechListenerError.microphoneDenied
        }

        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        try await ensureModel(for: transcriber, locale: locale)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.transcriber = transcriber
        self.analyzer = analyzer

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechListenerError.localeNotSupported(locale)
        }

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = inputBuilder

        try configureAudioSession()
        try startAudioEngine(convertingTo: analyzerFormat, into: inputBuilder)
        try await analyzer.start(inputSequence: inputSequence)
        isListening = true

        let (eventStream, eventContinuation) = AsyncStream<TranscriptEvent>.makeStream()
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    eventContinuation.yield(result.isFinal ? .final(text) : .volatile(text))
                }
            } catch {
                print("[SpeechCommandListener] 识别流中断: \(error)")
            }
            eventContinuation.finish()
        }
        return eventStream
    }

    func stop() async {
        guard isListening else { return }
        isListening = false

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputBuilder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        inputBuilder = nil
    }

    // MARK: - 模型资产

    /// 确认目标语言的端侧模型可用，必要时触发系统下载。
    private func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw SpeechListenerError.localeNotSupported(locale)
        }

        let installed = await Set(SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        if installed.contains(locale.identifier(.bcp47)) {
            return
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    // MARK: - 音频采集

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startAudioEngine(convertingTo analyzerFormat: AVAudioFormat,
                                  into inputBuilder: AsyncStream<AnalyzerInput>.Continuation) throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let converter else {
                inputBuilder.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let ratio = analyzerFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }

            var error: NSError?
            var consumed = false
            converter.convert(to: converted, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if error == nil, converted.frameLength > 0 {
                inputBuilder.yield(AnalyzerInput(buffer: converted))
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }
}
