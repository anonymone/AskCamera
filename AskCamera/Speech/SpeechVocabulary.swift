import Foundation
import Speech

/// 端侧听写的领域词表：命令短句 + 常见物体。
/// `AnalysisContext.contextualStrings` 大约 100 条上限，优先命令词再补物体名。
enum SpeechVocabulary {

    static let commandPhrases: [String] = [
        "对焦", "对焦到", "对准", "聚焦", "焦点",
        "取消对焦", "停止跟踪", "停止对焦", "取消聚焦",
        "拍照", "拍一张", "照相", "拍摄",
        "录像", "开始录像", "停止录像", "停止录制", "录制视频",
        "取消倒计时", "取消拍照", "取消",
        "左边的", "右边的", "上面的", "下面的",
        "focus on", "take a photo", "start recording", "stop recording",
    ]

    /// 传给 DictationTranscriber 的上下文短语（去重、截断到 100）。
    static func contextualPhrases() -> [String] {
        var seen = Set<String>()
        var phrases: [String] = []
        func append(_ items: [String]) {
            for item in items where seen.insert(item).inserted {
                phrases.append(item)
            }
        }
        append(commandPhrases)
        append(TargetTranslator.chineseColorWords)
        append(TargetTranslator.chineseVocabulary.sorted { $0.count > $1.count })
        return Array(phrases.prefix(100))
    }

    static func analysisContext() -> AnalysisContext {
        let context = AnalysisContext()
        context.contextualStrings = [.general: contextualPhrases()]
        return context
    }
}
