import Foundation
import Speech

/// 用命令模板训练的自定义语言模型，偏置 DictationTranscriber 输出「对焦到苹果」而不是同音错字。
///
/// 编译需要数秒，不能挡住首次听写：已有缓存则立刻用，否则后台准备、下次会话再生效。
enum SpeechCommandLanguageModel {

    static let identifier = "com.severuspeng.AskCamera.commands"
    static let version = "1"

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
        let objects = TargetTranslator.chineseVocabulary
        let colors = TargetTranslator.chineseColorWords
        return SFCustomLanguageModelData(
            locale: locale,
            identifier: identifier,
            version: version
        ) {
            SFCustomLanguageModelData.PhraseCount(phrase: "对焦", count: 400)
            SFCustomLanguageModelData.PhraseCount(phrase: "对焦到", count: 400)
            SFCustomLanguageModelData.PhraseCount(phrase: "对准", count: 200)
            SFCustomLanguageModelData.PhraseCount(phrase: "聚焦", count: 200)
            SFCustomLanguageModelData.PhraseCount(phrase: "拍照", count: 400)
            SFCustomLanguageModelData.PhraseCount(phrase: "拍一张", count: 200)
            SFCustomLanguageModelData.PhraseCount(phrase: "照相", count: 150)
            SFCustomLanguageModelData.PhraseCount(phrase: "录像", count: 400)
            SFCustomLanguageModelData.PhraseCount(phrase: "开始录像", count: 250)
            SFCustomLanguageModelData.PhraseCount(phrase: "停止录像", count: 250)
            SFCustomLanguageModelData.PhraseCount(phrase: "取消对焦", count: 150)
            SFCustomLanguageModelData.PhraseCount(phrase: "取消倒计时", count: 100)
            SFCustomLanguageModelData.PhraseCount(phrase: "取消", count: 100)

            SFCustomLanguageModelData.PhraseCountsFromTemplates(classes: [
                "object": objects,
                "color": colors,
                "spatial": ["左边的", "右边的", "上面的", "下面的", "左侧的", "右侧的"],
                "seconds": ["3", "5", "10", "15"],
            ]) {
                SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("对焦到<object>", count: 80)
                SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("对焦到<spatial><object>", count: 40)
                SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("对焦到<color>的<object>", count: 40)
                SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("对准<object>", count: 30)
                SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("<seconds>秒后拍照", count: 60)
                SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("录<seconds>秒", count: 60)
                SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("<seconds>秒后开始录像", count: 40)
            }
        }
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
