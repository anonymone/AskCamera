import AVFoundation
import Foundation
import Speech

/// 语音识别事件：volatile 为实时未定稿文本，final 为定稿文本。
/// `alternatives` 为同段音频的次优转写，解析失败时按序再试。
enum TranscriptEvent {
    case volatile(String, alternatives: [String])
    case final(String, alternatives: [String])
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
///
/// 模块选择：优先 DictationTranscriber（短语句/指令场景，定稿更快），
/// 该语言不支持时回退到 SpeechTranscriber（长文本模块）。
final class SpeechCommandListener {

    /// 当前使用的转写模块。
    private enum Module {
        case dictation(DictationTranscriber)
        case transcription(SpeechTranscriber)

        var speechModule: any SpeechModule {
            switch self {
            case .dictation(let m): return m
            case .transcription(let m): return m
            }
        }
    }

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var module: Module?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    private(set) var isListening = false
    /// 当前模块名（供日志/调试）。
    private(set) var activeModuleName = ""

    /// 启动监听，返回识别事件流。
    func start(locale: Locale = Locale(identifier: "zh-CN")) async throws -> AsyncStream<TranscriptEvent> {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw SpeechListenerError.microphoneDenied
        }

        let module = try await makeModule(locale: locale)
        self.module = module

        let analyzer = SpeechAnalyzer(modules: [module.speechModule])
        self.analyzer = analyzer
        try? await analyzer.setContext(SpeechVocabulary.analysisContext())

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.speechModule]) else {
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
                switch module {
                case .dictation(let transcriber):
                    for try await result in transcriber.results {
                        yieldTranscript(result.text, alternatives: result.alternatives,
                                        isFinal: result.isFinal, to: eventContinuation)
                    }
                case .transcription(let transcriber):
                    for try await result in transcriber.results {
                        yieldTranscript(result.text, alternatives: result.alternatives,
                                        isFinal: result.isFinal, to: eventContinuation)
                    }
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
        module = nil
        inputBuilder = nil
    }

    // MARK: - 模块创建与资产

    private func makeModule(locale: Locale) async throws -> Module {
        // 短指令场景优先 DictationTranscriber：定稿延迟更低。
        // 配置对齐 Preset.progressiveShortDictation 的 shortForm + volatile，
        // 但关掉标点（命令解析更稳），并打开 n-best 以便错字时换候选。
        let dictationLocales = await DictationTranscriber.supportedLocales
        if dictationLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            var contentHints: Set<DictationTranscriber.ContentHint> = [.shortForm]
            if let lm = SpeechCommandLanguageModel.readyConfiguration(locale: locale) {
                contentHints.insert(.customizedLanguage(modelConfiguration: lm))
                print("[SpeechCommandListener] 已加载自定义命令语言模型")
            } else {
                SpeechCommandLanguageModel.prepareInBackground(locale: locale)
            }
            let transcriber = DictationTranscriber(
                locale: locale,
                contentHints: contentHints,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .alternativeTranscriptions],
                attributeOptions: []
            )
            try await ensureAssets(for: transcriber, locale: locale,
                                   installed: await Set(DictationTranscriber.installedLocales.map { $0.identifier(.bcp47) }))
            activeModuleName = "DictationTranscriber"
            print("[SpeechCommandListener] 使用 DictationTranscriber（短指令模块）")
            return .dictation(transcriber)
        }

        let transcriptionLocales = await SpeechTranscriber.supportedLocales
        guard transcriptionLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw SpeechListenerError.localeNotSupported(locale)
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .alternativeTranscriptions],
            attributeOptions: []
        )
        try await ensureAssets(for: transcriber, locale: locale,
                               installed: await Set(SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }))
        activeModuleName = "SpeechTranscriber"
        print("[SpeechCommandListener] 使用 SpeechTranscriber（长文本模块回退）")
        return .transcription(transcriber)
    }

    private func yieldTranscript(_ best: AttributedString,
                                 alternatives: [AttributedString],
                                 isFinal: Bool,
                                 to continuation: AsyncStream<TranscriptEvent>.Continuation) {
        let text = String(best.characters)
        guard !text.isEmpty else { return }
        let alts = alternatives.map { String($0.characters) }.filter { !$0.isEmpty && $0 != text }
        continuation.yield(isFinal ? .final(text, alternatives: alts) : .volatile(text, alternatives: alts))
    }

    /// 确认端侧模型已安装，必要时触发系统下载。
    private func ensureAssets(for module: any SpeechModule, locale: Locale, installed: Set<String>) async throws {
        if installed.contains(locale.identifier(.bcp47)) {
            return
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    // MARK: - 音频采集

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        // .default 模式保留系统 AGC/降噪处理链（.measurement 会关闭，嘈杂环境准确率下降）
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
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
