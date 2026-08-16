import Foundation

/// 在 n-best 转写里给「能执行的命令」打分。
/// 规则命中的短语可立即执行；非正式表述（「镜头对着自行车」）留给定稿端模型，不要被次优「拍照」抢走。
enum CommandCandidateRanker {

    private static let fillers: Set<String> = [
        "嗯", "啊", "呃", "哦", "唔", "哈", "那个", "这个", "嗯嗯", "啊啊", "然后",
    ]

    /// 分数越高越优先执行。0 表示规则层不应执行（仍可能是非正式指令）。
    static func score(_ leftover: String) -> Int {
        let text = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return 0 }

        if CaptureCommandParser.parse(text) != nil {
            return 100
        }
        guard let command = FocusIntentParser.parseCommand(text) else {
            return 0
        }
        switch command {
        case .reset:
            return 90
        case .focus(let intent):
            guard let target = intent.target else {
                return 35
            }
            if FocusIntentParser.isIncompleteTarget(target) {
                return 0
            }
            if TargetTranslator.lookup(target) != nil {
                return 80
            }
            if TargetTranslator.isAttributedPhrase(target) {
                return 70
            }
            if target.allSatisfy(\.isASCII) {
                return 75
            }
            // 开放物体：有对焦框、名字不在词表，留给定稿/端模型，不要改写成常见物
            return 55
        }
    }

    /// 规则打分为 0，但定稿时值得交给端模型（不是光杆名词、也不是语气词）。
    static func looksLikeOpenCommand(_ leftover: String) -> Bool {
        let text = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { return false }
        if fillers.contains(text) { return false }
        if score(text) > 0 { return false }
        if TargetTranslator.lookup(text) != nil { return false }
        return true
    }

    /// - Parameter allowOpenPrimary: 定稿为 true：主结果虽不是规则指令，只要像一句完整话就保留给端模型。
    static func pick(best: String,
                     alternatives: [String],
                     leftover: (String) -> String,
                     allowOpenPrimary: Bool = false) -> String? {
        let primaryLeftover = leftover(best)
        if score(primaryLeftover) > 0 {
            return best
        }
        if allowOpenPrimary, looksLikeOpenCommand(primaryLeftover) {
            return best
        }
        return bestCandidate(in: alternatives, leftover: leftover)
    }

    static func bestCandidate(in texts: [String], leftover: (String) -> String) -> String? {
        var winner: (text: String, score: Int)?
        for text in texts {
            let value = score(leftover(text))
            if value > (winner?.score ?? 0) {
                winner = (text, value)
            }
        }
        guard let winner, winner.score > 0 else { return nil }
        return winner.text
    }
}
