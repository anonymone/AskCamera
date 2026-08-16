import Foundation
import Speech

/// 端侧听写只偏置**命令框**（对焦/拍照/录像/方位），不塞物体名。
/// 物体槽保持开放，避免「订书机」被听成词典里的常见词。
enum SpeechVocabulary {

    static let commandPhrases: [String] = [
        "对焦", "对焦到", "对准", "聚焦", "焦点",
        "取消对焦", "停止跟踪", "停止对焦", "取消聚焦",
        "拍照", "拍一张", "照相", "拍摄",
        "录像", "开始录像", "停止录像", "停止录制", "录制视频",
        "取消倒计时", "取消拍照", "取消",
        "左边的", "右边的", "上面的", "下面的",
        "左侧的", "右侧的",
        "focus on", "take a photo", "start recording", "stop recording",
    ]

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
        return phrases
    }

    static func analysisContext() -> AnalysisContext {
        let context = AnalysisContext()
        context.contextualStrings = [.general: contextualPhrases()]
        return context
    }
}
