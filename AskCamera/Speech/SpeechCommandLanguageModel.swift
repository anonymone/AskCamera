import Foundation
import Speech

/// 只训练命令句式，不把物体名写进语言模型。
/// 编译需要数秒：已有缓存立刻用，否则后台准备、下次会话再生效。
enum SpeechCommandLanguageModel {

    static let identifier = "com.severuspeng.AskCamera.commands"
    static let version = "2"

    private static let cacheLock = NSLock()
    private static var cachedConfiguration: SFSpeechLanguageModel.Configuration?

    static func readyConfiguration(locale: Locale) -> SFSpeechLanguageModel.Configuration? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedConfiguration { return cachedConfiguration }
        let urls = cacheURLs()
        guard FileManager.default.fileExists(atPath: urls.model.path) else { return nil }
        let configuration = SFSpeechLanguageModel.Configuration(languageModel: urls.model)
        cachedConfiguration = configuration
        return configuration
    }

    static func prepareInBackground(locale: Locale) {
        if readyConfiguration(locale: locale) != nil { return }
        Task.detached(priority: .utility) {
            do {
                try await compile(locale: locale)
                print("[SpeechCommandLanguageModel] 自定义语言模型已就绪 version=\(version)")
            } catch {
                print("[SpeechCommandLanguageModel] 准备失败: \(error)")
            }
        }
    }

    private static func compile(locale: Locale) async throws {
        let urls = cacheURLs()
        try FileManager.default.createDirectory(at: urls.directory, withIntermediateDirectories: true)

        let data = makeTrainingData(locale: locale)
        try await data.export(to: urls.training)
        let configuration = SFSpeechLanguageModel.Configuration(languageModel: urls.model)
        try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: urls.training, configuration: configuration)

        cacheLock.lock()
        cachedConfiguration = configuration
        cacheLock.unlock()
    }

    private static func makeTrainingData(locale: Locale) -> SFCustomLanguageModelData {
        let data = SFCustomLanguageModelData(locale: locale, identifier: identifier, version: version)
        let weightedPhrases: [(String, Int)] = [
            ("对焦", 400), ("对焦到", 500), ("对准", 200), ("聚焦", 200),
            ("拍照", 400), ("拍一张", 200), ("照相", 150),
            ("录像", 400), ("开始录像", 250), ("停止录像", 250),
            ("取消对焦", 150), ("取消倒计时", 100), ("取消", 100),
            ("对焦到左边的", 80), ("对焦到右边的", 80),
        ]
        for (phrase, count) in weightedPhrases {
            data.insert(phraseCount: SFCustomLanguageModelData.PhraseCount(phrase: phrase, count: count))
        }

        let templates = SFCustomLanguageModelData.PhraseCountsFromTemplates(classes: [
            "seconds": ["3", "5", "10", "15"],
            "spatial": ["左边的", "右边的", "上面的", "下面的"],
        ]) {
            SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("<seconds>秒后拍照", count: 80)
            SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("录<seconds>秒", count: 80)
            SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("<seconds>秒后开始录像", count: 50)
            SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("对焦到<spatial>", count: 40)
        }
        templates.insert(data: data)
        return data
    }

    private static func cacheURLs() -> (directory: URL, training: URL, model: URL) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AskCamera/SpeechLM/\(version)", isDirectory: true)
        return (
            directory,
            directory.appendingPathComponent("CustomLMData.bin"),
            directory.appendingPathComponent("CustomLM")
        )
    }
}
