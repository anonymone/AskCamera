import Foundation

/// 规则式拍照 / 录像指令解析（快路径，不依赖端模型）。
enum CaptureCommandParser {

    private static let stopVideoKeywords = [
        "停止录像", "停止录制", "结束录像", "结束录制", "停止视频",
        "stop recording", "stop video", "end recording",
    ]

    private static let cancelPendingKeywords = [
        "取消倒计时", "取消拍照", "取消拍摄", "别拍了", "不要拍了", "别录了",
        "cancel countdown", "cancel photo",
    ]

    /// 对焦触发词：连续转写里若最后一条指令是对焦，就不要再执行前文的拍照/录像。
    private static let focusTriggerKeywords = [
        "取消对焦", "取消跟踪", "停止对焦", "停止跟踪", "取消聚焦",
        "复位", "回到中心", "reset focus", "stop tracking", "cancel focus",
        "对焦", "对准", "聚焦", "焦点", "focus",
    ]

    /// 采集触发词（较长者优先，避免「录像」盖过「停止录像」时的位置比较）。
    private static let captureTriggerKeywords = [
        "cancel countdown", "cancel photo",
        "stop recording", "stop video", "end recording",
        "start recording", "record video", "start video",
        "take a photo", "take photo", "capture photo",
        "取消倒计时", "取消拍照", "取消拍摄",
        "停止录像", "停止录制", "结束录像", "结束录制", "停止视频",
        "开始录像", "开始录制", "开始录视频", "录制视频",
        "拍一张", "拍照", "照相", "拍摄",
        "别拍了", "不要拍了", "别录了",
        "录像", "录制", "record",
    ]

    /// 解析采集指令。非采集指令返回 nil（由对焦链路继续处理）。
    static func parse(_ rawText: String) -> CaptureCommand? {
        let text = FocusIntentParser.normalize(rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let loweredFull = text.lowercased()
        // 裸「取消」：只取消倒计时；含对焦词的由 last-command 判断交给对焦链路
        if loweredFull == "取消" || loweredFull == "cancel" {
            return .cancelPending
        }

        // SpeechAnalyzer 会把多句拼在同一段里（「对焦到鼠标拍照对焦到杯子」）。
        // 只解析最后一条采集指令；若最后是对焦，返回 nil 交给 FocusIntentParser。
        guard let segment = latestCaptureSegment(in: text) else { return nil }
        let lowered = segment.lowercased()

        if stopVideoKeywords.contains(where: { lowered.contains($0) }) {
            return .stopVideo
        }

        if cancelPendingKeywords.contains(where: { lowered.contains($0) }) {
            return .cancelPending
        }

        if let video = parseVideo(segment, lowered: lowered) {
            return video
        }
        if let photo = parsePhoto(segment, lowered: lowered) {
            return photo
        }
        return nil
    }

    // MARK: - Latest command

    private enum CommandKind {
        case focus, capture
    }

    private struct CommandHit {
        let kind: CommandKind
        let range: Range<String.Index>
    }

    /// 从上一指令之后切出最后一条采集子句；最后一条是对焦时返回 nil。
    private static func latestCaptureSegment(in text: String) -> String? {
        let hits = commandHits(in: text)
        guard let last = hits.last, last.kind == .capture else { return nil }
        let start = hits.dropLast().last.map(\.range.upperBound) ?? text.startIndex
        return String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func commandHits(in text: String) -> [CommandHit] {
        var hits: [CommandHit] = []

        func consider(_ keywords: [String], kind: CommandKind) {
            for keyword in keywords {
                var searchFrom = text.startIndex
                while let range = text.range(of: keyword, options: .caseInsensitive, range: searchFrom..<text.endIndex) {
                    hits.append(CommandHit(kind: kind, range: range))
                    searchFrom = range.upperBound
                }
            }
        }

        consider(focusTriggerKeywords, kind: .focus)
        consider(captureTriggerKeywords, kind: .capture)

        // 「停止录像」内的「录像」等被更长词包含的命中丢掉，避免把一条指令切成两段
        let allHits = hits
        hits = allHits.filter { hit in
            !allHits.contains { other in
                other.range != hit.range
                    && other.range.lowerBound <= hit.range.lowerBound
                    && other.range.upperBound >= hit.range.upperBound
            }
        }
        hits.sort { $0.range.lowerBound < $1.range.lowerBound }
        return hits
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
