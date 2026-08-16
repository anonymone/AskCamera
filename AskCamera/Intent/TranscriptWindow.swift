import Foundation

/// 从 SpeechAnalyzer 的累积转写里切出尚未消费的新句子。
/// 识别会话重置后 `consumed` 为空，整段都是新句。
enum TranscriptWindow {

    static let trimCharacters: CharacterSet = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(CharacterSet(charactersIn: "。！？、，,.!?"))

    static func leftover(from full: String, consumed: String, lastCommand: String) -> String {
        let fullText = full.trimmingCharacters(in: .whitespacesAndNewlines)
        let consumedText = consumed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !consumedText.isEmpty else { return fullText }

        if fullText.hasPrefix(consumedText) {
            return String(fullText.dropFirst(consumedText.count))
                .trimmingCharacters(in: trimCharacters)
        }
        if let range = fullText.range(of: consumedText, options: .backwards) {
            let tail = String(fullText[range.upperBound...])
                .trimmingCharacters(in: trimCharacters)
            if !tail.isEmpty { return tail }
        }

        // ASR 改写前文时，只能按「上次整句指令」切开，不能按 displayName（「鼠标」）。
        let command = lastCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.count >= 4, let range = fullText.range(of: command, options: .backwards) {
            let tail = String(fullText[range.upperBound...])
                .trimmingCharacters(in: trimCharacters)
            if containsCommandTrigger(tail) || CommandCandidateRanker.looksLikeOpenCommand(tail) {
                return tail
            }
        }
        return fullText
    }

    static func containsCommandTrigger(_ text: String) -> Bool {
        let lowered = TranscriptNormalizer.normalize(text).lowercased()
        let triggers = [
            "对焦", "对准", "聚焦", "焦点", "focus",
            "拍照", "照相", "拍摄", "录像", "录制", "record",
        ]
        return triggers.contains { lowered.contains($0) }
    }
}
