import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 规则快路径覆盖常见说法；定稿时端模型理解动作 + 抽出主体英文。
///
/// 1. 规则：拍照/录像、对焦触发词（光杆「鼠标」不是指令）
/// 2. 定稿：Foundation Models 理解非正式表述，并提取主体 → YOLO 英文 prompt
/// 3. 端模型不可用：整词词典/名词表（不截断复合词）
/// 4. 仍无英文 → unresolved，不把中文丢给 CLIP
enum QueryUnderstanding {

    /// 采集 + 对焦的统一入口。volatile 应传 `allowLanguageModel: false`。
    static func understand(_ rawText: String, allowLanguageModel: Bool = true) async -> SpokenIntent? {
        if let capture = CaptureCommandParser.parse(rawText) {
            log("capture-rules", detail: rawText)
            return .capture(capture)
        }

        if let query = await resolve(rawText, allowLanguageModel: allowLanguageModel) {
            if query.action == .none { return nil }
            return .query(query)
        }

        guard allowLanguageModel else { return nil }
        if let open = await interpretOpenCommand(rawText) {
            log("foundation-models-open", detail: rawText)
            return open
        }
        return nil
    }

    /// - Parameter allowLanguageModel: volatile 快路径应传 false，避免端模型延迟与半句误触发。
    static func resolve(_ rawText: String, allowLanguageModel: Bool = true) async -> DetectionQuery? {
        // 规则快筛：无对焦/取消触发则交给 understand 的端模型开放路径。
        guard let command = FocusIntentParser.parseCommand(rawText) else {
            return nil
        }

        switch command {
        case .reset:
            log("reset", detail: rawText)
            return .reset
        case .focus(let intent):
            return await resolveFocus(intent, utterance: rawText, allowLanguageModel: allowLanguageModel)
        }
    }

    // MARK: - Focus

    private static func resolveFocus(_ intent: FocusIntent,
                                     utterance: String,
                                     allowLanguageModel: Bool) async -> DetectionQuery {
        guard let rawTarget = intent.target?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTarget.isEmpty else {
            log("saliency", detail: "无目标词")
            return .saliency()
        }

        // 定稿：端模型从整句提取主体英文。不要先查词典，否则「自行车」会被截成「车」。
        if allowLanguageModel,
           let generated = await generateWithFoundationModel(utterance: utterance,
                                                             rawTarget: rawTarget,
                                                             spatialHint: intent.spatialHint) {
            log("foundation-models",
                detail: "utterance=\(utterance) prompts=\(generated.yoloPrompts) spatial=\(generated.spatialHint?.rawValue ?? "none") display=\(generated.displayName)")
            return generated
        }

        // 无端模型 / 未定稿：整词翻译，不改写用户的词
        if !TargetTranslator.isAttributedPhrase(rawTarget),
           let english = TargetTranslator.lookup(rawTarget) {
            let display = TargetTranslator.canonicalChinese(for: rawTarget) ?? rawTarget
            log("dictionary", detail: "\(rawTarget) → \(english) spatial=\(intent.spatialHint?.rawValue ?? "none")")
            return .focus(prompts: [english],
                          displayName: display,
                          spatialHint: intent.spatialHint)
        }

        if let fallback = TargetTranslator.attributedFallback(from: rawTarget) {
            log("attributed-fallback",
                detail: "\(rawTarget) prompts=\(fallback.prompts)")
            return .focus(prompts: fallback.prompts,
                          displayName: fallback.displayName,
                          spatialHint: intent.spatialHint)
        }

        log("unresolved", detail: rawTarget)
        return .unresolved(displayName: rawTarget, spatialHint: intent.spatialHint)
    }

    private static func log(_ route: String, detail: String) {
        print("[QueryUnderstanding] route=\(route) \(detail)")
    }

    // MARK: - Foundation Models

    private static func generateWithFoundationModel(utterance: String,
                                                    rawTarget: String,
                                                    spatialHint: SpatialHint?) async -> DetectionQuery? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        return await FoundationQueryModel.generate(utterance: utterance,
                                                   rawTarget: rawTarget,
                                                   spatialHint: spatialHint)
        #else
        return nil
        #endif
    }

    private static func interpretOpenCommand(_ utterance: String) async -> SpokenIntent? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        return await FoundationQueryModel.interpret(utterance: utterance)
        #else
        return nil
        #endif
    }

    /// 启动时可选预热端模型 session（不阻塞 UI）。
    static func warmUp() {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return }
        FoundationQueryModel.warmUp()
        #endif
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum FoundationQueryModel {

    @Generable(description: "On-device camera command: action plus optional object for YOLO-World")
    struct GenerableQuery {
        @Guide(description: "One of: focus, reset, photo, video, stop_video, cancel, none")
        var action: String

        @Guide(description: "English word(s) for the main subject object when action is focus, 1 to 4 short noun phrases, e.g. bicycle, apple, blue book. Empty if not focusing. No full sentences. Do not encode left/right/top/bottom here.")
        var yoloPrompts: [String]

        @Guide(description: "Short Chinese label for UI feedback, e.g. 蓝色的书")
        var displayName: String

        @Guide(description: "One of: left, right, top, bottom, none")
        var spatial: String

        @Guide(description: "True only when the user wants focus but named no specific object")
        var useSaliency: Bool

        @Guide(description: "Countdown seconds before photo or video. 0 if immediate or not a capture command.")
        var delaySeconds: Int

        @Guide(description: "Video length in seconds. 15 if the user did not say a length. 0 if not a video command.")
        var durationSeconds: Int
    }

    private static let lock = NSLock()
    private static var sharedSession: LanguageModelSession?

    private static func session() -> LanguageModelSession {
        lock.lock()
        defer { lock.unlock() }
        if let sharedSession {
            return sharedSession
        }
        let created = LanguageModelSession(instructions: """
            You interpret a spoken camera command on device.
            Decide the ACTION, and if focusing, the MAIN subject object's English word(s) for YOLO-World.
            Actions:
            - focus: user wants the camera to focus / aim / track an object (对焦, 对准, 镜头对着, 看向, 焦点放到…)
            - reset: cancel focus / stop tracking
            - photo: take a still photo (拍照, 来一张, 拍一下, 咔嚓…)
            - video: start recording (录像, 录一下, 开始录…)
            - stop_video: stop recording
            - cancel: cancel a countdown only
            - none: not a camera command (naming an object with no request, chat, filler)
            Rules:
            - Informal wording still counts if the user is commanding the camera.
            - A bare object name (鼠标, 杯子, 自行车) with no camera request is none.
            - Keep the specific object: 自行车 → bicycle (not car); 火车 → train (not car).
            - Never replace a specific object with a shorter substring or a more common category.
            - yoloPrompts: English noun phrases only, and only when action is focus. No sentences.
            - Never put left/right/top/bottom/上/下/左/右 into yoloPrompts; put that into spatial.
            - displayName: brief Chinese to speak back.
            - useSaliency=true only for focus with no concrete object noun.
            - delaySeconds / durationSeconds: integers; 0 if unused; default video length 15.
            - Output must follow the schema; do not explain.
            """)
        sharedSession = created
        return created
    }

    static func generate(utterance: String,
                         rawTarget: String,
                         spatialHint: SpatialHint?) async -> DetectionQuery? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }

        do {
            let spatialNote = spatialHint?.rawValue ?? "none"
            let prompt = """
            Spoken command: \(utterance)
            Object span from the rule parser (hint only, may be a substring): \(rawTarget)
            Rule parser spatial hint (may be none): \(spatialNote)
            Extract the main subject object's English word(s) for YOLO-World.
            Action is focus unless the user is clearly canceling.
            """
            let response = try await session().respond(to: prompt, generating: GenerableQuery.self)
            switch mapSpoken(response.content, fallbackSpatial: spatialHint, fallbackDisplay: rawTarget) {
            case .query(let query):
                return query
            default:
                return nil
            }
        } catch {
            print("[QueryUnderstanding] Foundation Models 结构化解析失败: \(error)")
            return nil
        }
    }

    static func interpret(utterance: String) async -> SpokenIntent? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }

        do {
            let prompt = """
            Spoken command: \(utterance)
            No rule parser matched a canned phrase. Interpret informal camera commands.
            If this is not a camera request, action=none.
            """
            let response = try await session().respond(to: prompt, generating: GenerableQuery.self)
            return mapSpoken(response.content, fallbackSpatial: nil, fallbackDisplay: utterance)
        } catch {
            print("[QueryUnderstanding] Foundation Models 开放指令解析失败: \(error)")
            return nil
        }
    }

    static func warmUp() {
        guard case .available = SystemLanguageModel.default.availability else { return }
        Task.detached(priority: .utility) {
            _ = session()
            _ = try? await session().respond(to: "镜头对着自行车", generating: GenerableQuery.self)
        }
    }

    private static func mapSpoken(_ value: GenerableQuery,
                                  fallbackSpatial: SpatialHint?,
                                  fallbackDisplay: String) -> SpokenIntent? {
        let action = value.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch action {
        case "none":
            return nil
        case "reset":
            return .query(.reset)
        case "photo":
            return .capture(.photo(delaySeconds: max(0, value.delaySeconds)))
        case "video":
            let duration = value.durationSeconds > 0
                ? value.durationSeconds
                : CaptureCommand.defaultVideoDurationSeconds
            return .capture(.startVideo(delaySeconds: max(0, value.delaySeconds),
                                        durationSeconds: max(1, duration)))
        case "stop_video", "stopvideo", "stop-video":
            return .capture(.stopVideo)
        case "cancel":
            return .capture(.cancelPending)
        default:
            break
        }

        if value.useSaliency {
            let name = value.displayName.isEmpty ? "显著物体" : value.displayName
            return .query(.saliency(displayName: name))
        }

        let prompts = value.yoloPrompts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0.allSatisfy(\.isASCII) }
        guard !prompts.isEmpty else {
            return nil
        }

        let spatial = parseSpatial(value.spatial) ?? fallbackSpatial
        let display = value.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return .query(.focus(prompts: Array(prompts.prefix(4)),
                             displayName: display.isEmpty ? fallbackDisplay : display,
                             spatialHint: spatial))
    }

    private static func parseSpatial(_ raw: String) -> SpatialHint? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "left": return .left
        case "right": return .right
        case "top": return .top
        case "bottom": return .bottom
        default: return nil
        }
    }
}
#endif
