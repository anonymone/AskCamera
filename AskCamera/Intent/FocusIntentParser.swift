import Foundation

/// 方位修饰，用于同类多实例时的候选选择（"左边的杯子"）。
enum SpatialHint: String {
    case left, right, top, bottom
}

/// 对焦指令意图。
struct FocusIntent: Equatable {
    /// 对焦目标描述（如 "苹果"）。nil 表示未指定目标（对焦显著物体）。
    let target: String?
    /// 方位修饰。nil 表示未指定。
    let spatialHint: SpatialHint?

    init(target: String?, spatialHint: SpatialHint? = nil) {
        self.target = target
        self.spatialHint = spatialHint
    }
}

/// 语音指令。
enum FocusCommand: Equatable {
    case focus(FocusIntent)
    /// 取消对焦/停止跟踪，恢复画面中心连续自动对焦。
    case reset
}

/// 规则式意图解析（快路径）。
/// 覆盖常见句式；复杂指代表达式后续接入 Foundation Models 慢路径。
enum FocusIntentParser {

    /// 取消指令关键词。
    private static let resetKeywords = [
        "取消对焦", "取消跟踪", "停止对焦", "停止跟踪", "取消聚焦",
        "复位", "回到中心", "reset focus", "stop tracking", "cancel focus",
    ]

    /// 触发词常见同音误识别 → 规范形式。
    /// 短指令缺上下文，ASR 极易把"对焦"转成"对角/对交"等，先归一化再匹配。
    private static let homophoneCorrections: [(String, String)] = [
        ("对交", "对焦"), ("对角", "对焦"), ("对教", "对焦"), ("对叫", "对焦"),
        ("对娇", "对焦"), ("兑焦", "对焦"), ("队焦", "对焦"), ("对搅", "对焦"),
        ("巨焦", "聚焦"), ("据焦", "聚焦"), ("剧焦", "聚焦"), ("橘焦", "聚焦"), ("菊焦", "聚焦"),
        ("交点", "焦点"), ("教点", "焦点"), ("胶点", "焦点"),
        ("对住", "对准"), ("对撞", "对准"),
    ]

    /// 同音误识别归一化。
    static func normalize(_ text: String) -> String {
        var normalized = text
        for (wrong, right) in homophoneCorrections {
            normalized = normalized.replacingOccurrences(of: wrong, with: right)
        }
        return normalized
    }

    /// 解析语音指令（对焦 / 取消）。非指令返回 nil。
    static func parseCommand(_ rawText: String) -> FocusCommand? {
        let text = normalize(rawText)
        let lowered = text.lowercased()
        if resetKeywords.contains(where: { lowered.contains($0) }) {
            return .reset
        }
        if let intent = parse(text) {
            return .focus(intent)
        }
        return nil
    }

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

    /// 方位修饰前缀 → SpatialHint。
    private static let spatialPrefixes: [(String, SpatialHint)] = [
        ("左边的", .left), ("左侧的", .left), ("左面的", .left), ("左边", .left),
        ("右边的", .right), ("右侧的", .right), ("右面的", .right), ("右边", .right),
        ("上面的", .top), ("上方的", .top),
        ("下面的", .bottom), ("下方的", .bottom),
        ("left ", .left), ("right ", .right), ("top ", .top), ("bottom ", .bottom),
    ]

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

            // 提取方位修饰前缀
            var hint: SpatialHint?
            for (prefix, spatialHint) in spatialPrefixes {
                if target.lowercased().hasPrefix(prefix) {
                    hint = spatialHint
                    target = String(target.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    break
                }
            }

            return FocusIntent(target: target.isEmpty ? nil : target, spatialHint: hint)
        }

        // 只有触发词没有目标（如 "对焦"）：对焦显著物体。
        return FocusIntent(target: nil)
    }
}
