import Foundation

/// 在 n-best 转写里给「能执行的命令」打分。
/// 光杆名词（「鼠标」）不是指令；物体槽未进词典也可以，只要对焦触发词完整。
enum CommandCandidateRanker {

    /// 分数越高越优先执行。0 表示不应执行。
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

    static func pick(best: String, alternatives: [String], leftover: (String) -> String) -> String? {
        if score(leftover(best)) > 0 {
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
