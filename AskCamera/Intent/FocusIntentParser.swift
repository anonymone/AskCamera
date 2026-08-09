import Foundation

/// 对焦指令意图。
struct FocusIntent: Equatable {
    /// 对焦目标描述（如 "苹果"、"左边的水杯"）。nil 表示未指定目标（对焦显著物体/画面中心）。
    let target: String?
}

/// 规则式意图解析（快路径）。
/// 覆盖常见句式；复杂指代表达式后续接入 Foundation Models 慢路径。
enum FocusIntentParser {

    /// 中英文对焦句式。捕获组 1 为目标词。
    private static let patterns: [NSRegularExpression] = {
        let sources = [
            // 中文："对焦到苹果上" / "对焦在那只猫" / "对准苹果" / "焦点切到左边的水杯"
            "(?:把?焦点|对焦|对准|聚焦)(?:切|移|对)?(?:到|在|至|向|准)?(.+?)(?:上面?|那里|这里)?$",
            // 英文："focus on the apple" / "focus to the cat"
            "(?i)focus\\s+(?:on|to|at)?\\s*(?:the\\s+)?(.+?)\\s*$",
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// 触发词：句子里不含这些词就不当作对焦指令。
    private static let triggerKeywords = ["对焦", "对准", "聚焦", "焦点", "focus"]

    /// 目标词里需要剔除的冗余修饰。
    private static let noiseWords = ["那个", "这个", "那只", "这只", "那本", "这本", "一下", "上的", "请", "帮我"]

    static func parse(_ rawText: String) -> FocusIntent? {
        let text = rawText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。，！？.,!?"))
        guard !text.isEmpty else { return nil }

        let lowered = text.lowercased()
        guard triggerKeywords.contains(where: { lowered.contains($0) }) else { return nil }

        for pattern in patterns {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let targetRange = Range(match.range(at: 1), in: text) else { continue }

            var target = String(text[targetRange]).trimmingCharacters(in: .whitespaces)
            for noise in noiseWords {
                target = target.replacingOccurrences(of: noise, with: "")
            }
            target = target.trimmingCharacters(in: .whitespaces)

            return FocusIntent(target: target.isEmpty ? nil : target)
        }

        // 只有触发词没有目标（如 "对焦"）：对焦显著物体。
        return FocusIntent(target: nil)
    }
}
