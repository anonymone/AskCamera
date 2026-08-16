import AVFoundation
import CoreMedia
import Foundation
import Speech

/// 语音识别事件：volatile 为实时未定稿文本，final 为定稿文本。
/// `generation` 在每次 `beginNewUtterance()` 后递增，用于丢掉上一句残留结果。
enum TranscriptEvent {
    case volatile(String, alternatives: [String], generation: UInt64)
    case final(String, alternatives: [String], generation: UInt64)
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
    private let stateLock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var module: Module?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<TranscriptEvent>.Continuation?
    private var dropResults = false
    private var sessionLocale = Locale(identifier: "zh-CN")
    private var analyzerFormat: AVAudioFormat?

    private(set) var isListening = false
    /// 当前模块名（供日志/调试）。
    private(set) var activeModuleName = ""
    /// 每次新开识别输入后递增；ViewModel 用它忽略上一句的残留事件。
    private(set) var inputGeneration: UInt64 = 0

    /// 启动监听，返回识别事件流。
    func start(locale: Locale = Locale(identifier: "zh-CN")) async throws -> AsyncStream<TranscriptEvent> {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw SpeechListenerError.microphoneDenied
        }

        sessionLocale = locale
        inputGeneration = 0
        dropResults = false

        let module = try await makeModule(locale: locale)
        self.module = module

        let analyzer = SpeechAnalyzer(modules: [module.speechModule])
        self.analyzer = analyzer
        try? await analyzer.setContext(SpeechVocabulary.analysisContext())

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.speechModule]) else {
            throw SpeechListenerError.localeNotSupported(locale)
        }
        self.analyzerFormat = analyzerFormat

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        setInputBuilder(inputBuilder)

        try configureAudioSession()
        try startAudioEngine(convertingTo: analyzerFormat)
        try await analyzer.start(inputSequence: inputSequence)
        isListening = true

        let (eventStream, eventContinuation) = AsyncStream<TranscriptEvent>.makeStream()
        self.eventContinuation = eventContinuation
        startResultsTask(module: module, continuation: eventContinuation)
        return eventStream
    }

    /// 一条指令（或一句失败定稿）结束后：finalize 当前输入，再 `start` 新序列。
    /// 麦克风 tap 不停；不调用 finish 系 API，以免关掉整个 analyzer。
    func beginNewUtterance() async {
        guard isListening, analyzer != nil else { return }

        stateLock.lock()
        inputGeneration += 1
        dropResults = true
        let oldBuilder = inputBuilder
        inputBuilder = nil
        stateLock.unlock()

        oldBuilder?.finish()

        do {
            try await analyzer?.finalize(through: nil)
        } catch {
            print("[SpeechCommandListener] finalize 当前输入失败: \(error)")
        }

        let (inputSequence, newBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        setInputBuilder(newBuilder)

        do {
            try await analyzer?.start(inputSequence: inputSequence)
            stateLock.lock()
            dropResults = false
            stateLock.unlock()
            print("[SpeechCommandListener] 已开始新的识别输入 generation=\(inputGeneration)")
        } catch {
            print("[SpeechCommandListener] 复用 analyzer 失败，重建会话: \(error)")
            await rebuildSession()
        }
    }

    func stop() async {
        guard isListening else { return }
        isListening = false

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        setInputBuilder(nil)
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        analyzer = nil
        module = nil
        analyzerFormat = nil
        dropResults = false
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

    private func rebuildSession() async {
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        module = nil

        do {
            let module = try await makeModule(locale: sessionLocale)
            self.module = module
            let analyzer = SpeechAnalyzer(modules: [module.speechModule])
            self.analyzer = analyzer
            try? await analyzer.setContext(SpeechVocabulary.analysisContext())

            let (inputSequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
            setInputBuilder(builder)
            try await analyzer.start(inputSequence: inputSequence)

            if let continuation = eventContinuation {
                startResultsTask(module: module, continuation: continuation)
            }
            stateLock.lock()
            dropResults = false
            stateLock.unlock()
            print("[SpeechCommandListener] 已重建识别会话 generation=\(inputGeneration)")
        } catch {
            print("[SpeechCommandListener] 重建识别会话失败: \(error)")
            stateLock.lock()
            dropResults = false
            stateLock.unlock()
        }
    }

    private func startResultsTask(module: Module, continuation: AsyncStream<TranscriptEvent>.Continuation) {
        resultsTask = Task { [weak self] in
            do {
                switch module {
                case .dictation(let transcriber):
                    for try await result in transcriber.results {
                        self?.yieldTranscript(result.text, alternatives: result.alternatives,
                                              isFinal: result.isFinal, to: continuation)
                    }
                case .transcription(let transcriber):
                    for try await result in transcriber.results {
                        self?.yieldTranscript(result.text, alternatives: result.alternatives,
                                              isFinal: result.isFinal, to: continuation)
                    }
                }
            } catch {
                print("[SpeechCommandListener] 识别流中断: \(error)")
            }
        }
    }

    private func yieldTranscript(_ best: AttributedString,
                                 alternatives: [AttributedString],
                                 isFinal: Bool,
                                 to continuation: AsyncStream<TranscriptEvent>.Continuation) {
        stateLock.lock()
        let drop = dropResults
        let generation = inputGeneration
        stateLock.unlock()
        guard !drop else { return }

        let text = String(best.characters)
        guard !text.isEmpty else { return }
        let alts = alternatives.map { String($0.characters) }.filter { !$0.isEmpty && $0 != text }
        continuation.yield(isFinal
            ? .final(text, alternatives: alts, generation: generation)
            : .volatile(text, alternatives: alts, generation: generation))
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

    private func setInputBuilder(_ builder: AsyncStream<AnalyzerInput>.Continuation?) {
        stateLock.lock()
        inputBuilder = builder
        stateLock.unlock()
    }

    private func currentInputBuilder() -> AsyncStream<AnalyzerInput>.Continuation? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return inputBuilder
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        // .default 模式保留系统 AGC/降噪处理链（.measurement 会关闭，嘈杂环境准确率下降）
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startAudioEngine(convertingTo analyzerFormat: AVAudioFormat) throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let builder = self.currentInputBuilder() else { return }
            guard let converter else {
                builder.yield(AnalyzerInput(buffer: buffer))
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
                builder.yield(AnalyzerInput(buffer: converted))
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }
}
