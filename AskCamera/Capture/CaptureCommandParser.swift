import Foundation

/// 规则式拍照 / 录像指令解析（快路径，不依赖端模型）。
enum CaptureCommandParser {

    /// 对焦复位关键词：交给对焦链路，避免被「取消」误吞。
    private static let focusResetKeywords = [
        "取消对焦", "取消跟踪", "停止对焦", "停止跟踪", "取消聚焦",
        "复位", "回到中心", "reset focus", "stop tracking", "cancel focus",
    ]

    private static let stopVideoKeywords = [
        "停止录像", "停止录制", "结束录像", "结束录制", "停止视频",
        "stop recording", "stop video", "end recording",
    ]

    private static let cancelPendingKeywords = [
        "取消倒计时", "取消拍照", "取消拍摄", "别拍了", "不要拍了", "别录了",
        "cancel countdown", "cancel photo",
    ]

    /// 解析采集指令。非采集指令返回 nil（由对焦链路继续处理）。
    static func parse(_ rawText: String) -> CaptureCommand? {
        let text = FocusIntentParser.normalize(rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let lowered = text.lowercased()

        // 对焦取消留给 FocusIntentParser
        if focusResetKeywords.contains(where: { lowered.contains($0) }) {
            return nil
        }

        if stopVideoKeywords.contains(where: { lowered.contains($0) }) {
            return .stopVideo
        }

        if cancelPendingKeywords.contains(where: { lowered.contains($0) }) {
            return .cancelPending
        }
        // 裸「取消」：只取消倒计时（已对齐）；含对焦词的已在上方排除
        if lowered == "取消" || lowered == "cancel" {
            return .cancelPending
        }

        if let video = parseVideo(text, lowered: lowered) {
            return video
        }
        if let photo = parsePhoto(text, lowered: lowered) {
            return photo
        }
        return nil
    }

    // MARK: - Photo

    private static func parsePhoto(_ text: String, lowered: String) -> CaptureCommand? {
        // 「5秒后拍照」「5 秒后开始拍照」「倒计时3秒拍照」
        let delayPatterns = [
            #"(\d+)\s*秒后(?:开始)?(?:拍照|拍一张|照相|拍摄)"#,
            #"倒计时\s*(\d+)\s*秒(?:后)?(?:拍照|拍一张|照相|拍摄)?"#,
            #"(?:拍照|拍一张|照相|拍摄)\s*(?:倒计时)?\s*(\d+)\s*秒"#,
            #"(?i)(?:take\s+(?:a\s+)?photo|capture)\s+in\s+(\d+)\s*s(?:ec(?:ond)?s?)?"#,
            #"(?i)(?:in\s+)?(\d+)\s*s(?:ec(?:ond)?s?)?\s*(?:later\s+)?(?:take\s+(?:a\s+)?photo|capture)"#,
        ]
        for source in delayPatterns {
            if let n = firstInt(in: text, pattern: source) {
                return .photo(delaySeconds: max(0, n))
            }
        }

        let immediate = ["拍照", "拍一张", "照相", "拍摄", "take a photo", "take photo", "capture photo"]
        if immediate.contains(where: { lowered.contains($0) }) {
            return .photo(delaySeconds: 0)
        }
        return nil
    }

    // MARK: - Video

    private static func parseVideo(_ text: String, lowered: String) -> CaptureCommand? {
        // 「3秒后开始录15秒视频」「3秒后录制一段15秒的视频」
        let delayAndDuration = [
            #"(\d+)\s*秒后(?:开始)?(?:录制|录像|录)\s*(?:一段)?\s*(\d+)\s*秒"#,
            #"(?i)(?:in\s+)?(\d+)\s*s(?:ec(?:ond)?s?)?\s*(?:later\s+)?(?:start\s+)?record(?:ing)?\s+(?:for\s+)?(\d+)\s*s"#,
        ]
        for source in delayAndDuration {
            if let pair = firstTwoInts(in: text, pattern: source) {
                return .startVideo(delaySeconds: max(0, pair.0),
                                   durationSeconds: max(1, pair.1))
            }
        }

        // 「录15秒」「录制15秒视频」
        let durationOnly = [
            #"(?:开始)?(?:录制|录像|录)\s*(?:一段)?\s*(\d+)\s*秒"#,
            #"(?i)record(?:ing)?\s+(?:for\s+)?(\d+)\s*s(?:ec(?:ond)?s?)?"#,
        ]
        for source in durationOnly {
            if let n = firstInt(in: text, pattern: source),
               lowered.contains("录") || lowered.contains("record") {
                return .startVideo(delaySeconds: 0, durationSeconds: max(1, n))
            }
        }

        // 「3秒后开始录像」（时长默认 15）
        let delayOnly = [
            #"(\d+)\s*秒后(?:开始)?(?:录像|录制|录视频)"#,
            #"(?i)(?:in\s+)?(\d+)\s*s(?:ec(?:ond)?s?)?\s*(?:later\s+)?(?:start\s+)?record(?:ing)?"#,
        ]
        for source in delayOnly {
            if let n = firstInt(in: text, pattern: source) {
                return .startVideo(delaySeconds: max(0, n),
                                   durationSeconds: CaptureCommand.defaultVideoDurationSeconds)
            }
        }

        let immediate = ["开始录像", "开始录制", "开始录视频", "录像", "录制视频",
                         "start recording", "record video", "start video"]
        // 「录像」单独命中；避免「录像机」等误触发可后续收紧
        if immediate.contains(where: { lowered.contains($0) }) {
            return .startVideo(delaySeconds: 0,
                               durationSeconds: CaptureCommand.defaultVideoDurationSeconds)
        }
        return nil
    }

    // MARK: - Regex helpers

    private static func firstInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }

    private static func firstTwoInts(in text: String, pattern: String) -> (Int, Int)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 2,
              let r1 = Range(match.range(at: 1), in: text),
              let r2 = Range(match.range(at: 2), in: text),
              let a = Int(text[r1]), let b = Int(text[r2]) else { return nil }
        return (a, b)
    }
}
