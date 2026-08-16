import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 规则只判断「这是不是对焦指令」。主体物体的英文由端模型从整句提取。
///
/// 1. 规则快筛（必须有对焦/取消触发词；光杆「鼠标」不是指令）
/// 2. 定稿：Foundation Models 从整句抽出主体 → YOLO 英文 prompt
/// 3. 端模型不可用：整词词典/名词表（不截断复合词）
/// 4. 仍无英文 → unresolved，不把中文丢给 CLIP
enum QueryUnderstanding {

    /// - Parameter allowLanguageModel: volatile 快路径应传 false，避免端模型延迟与半句误触发。
    static func resolve(_ rawText: String, allowLanguageModel: Bool = true) async -> DetectionQuery? {
        // 规则快筛：无对焦/取消触发则直接忽略（降低误触发与端模型调用）。
        // 拍照/录像由 CaptureCommandParser 在 ViewModel 里先截走，不会进到这里。
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

    @Generable(description: "Camera focus query for open-vocabulary object detection")
    struct GenerableQuery {
        @Guide(description: "One of: focus, reset, none")
        var action: String

        @Guide(description: "English word(s) for the main subject object, 1 to 4 short noun phrases for YOLO-World, e.g. bicycle, apple, blue book. No full sentences. Do not encode left/right/top/bottom here.")
        var yoloPrompts: [String]

        @Guide(description: "Short Chinese label for UI feedback, e.g. 蓝色的书")
        var displayName: String

        @Guide(description: "One of: left, right, top, bottom, none")
        var spatial: String

        @Guide(description: "True only when the user wants focus but named no specific object")
        var useSaliency: Bool
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
            You extract the MAIN subject object from a spoken camera command and output its English word(s).
            The vision model is YOLO-World: it needs short English noun phrases, not captions.
            Rules:
            - Read the full spoken command. The subject is the thing to detect, not the verb (对焦/拍照) and not location words.
            - Keep the specific object: 自行车 → bicycle (not car); 火车 → train (not car); 摩托车 → motorcycle.
            - Never replace a specific object with a shorter substring or a more common category.
            - yoloPrompts: 1-4 concise English noun phrases (e.g. bicycle, white mug). English words only. No sentences.
            - Never put left/right/top/bottom/上/下/左/右 into yoloPrompts; put that into spatial instead.
            - displayName: brief Chinese for speaking back to the user (e.g. 自行车).
            - action is almost always "focus". Use "none" only if this is not an object focus request.
            - useSaliency=true only when there is no concrete object noun.
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
            """
            let response = try await session().respond(to: prompt, generating: GenerableQuery.self)
            return mapGenerable(response.content, fallbackSpatial: spatialHint, fallbackDisplay: rawTarget)
        } catch {
            print("[QueryUnderstanding] Foundation Models 结构化解析失败: \(error)")
            return nil
        }
    }

    static func warmUp() {
        guard case .available = SystemLanguageModel.default.availability else { return }
        Task.detached(priority: .utility) {
            _ = session()
            _ = try? await session().respond(to: "对焦到自行车", generating: GenerableQuery.self)
        }
    }

    private static func mapGenerable(_ value: GenerableQuery,
                                     fallbackSpatial: SpatialHint?,
                                     fallbackDisplay: String) -> DetectionQuery? {
        let action = value.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch action {
        case "reset":
            return .reset
        case "none":
            return nil
        default:
            break
        }

        if value.useSaliency {
            let name = value.displayName.isEmpty ? "显著物体" : value.displayName
            return .saliency(displayName: name)
        }

        let prompts = value.yoloPrompts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0.allSatisfy(\.isASCII) }
        guard !prompts.isEmpty else {
            return nil
        }

        let spatial = parseSpatial(value.spatial) ?? fallbackSpatial
        let display = value.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return .focus(prompts: Array(prompts.prefix(4)),
                      displayName: display.isEmpty ? fallbackDisplay : display,
                      spatialHint: spatial)
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
