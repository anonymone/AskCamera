import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 查询理解：用户话语 → `DetectionQuery`（YOLO prompts + 选择条件）。
///
/// 路由：
/// 1. 规则快筛（分句 / 触发词 / 取消）
/// 2. 词典命中的简单目标 → 跳过端模型
/// 3. 复杂指代或词典未命中 → Foundation Models `@Generable`（可选）
/// 4. 端模型不可用 → 规则 + 词典/拼音/字符串翻译回退
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
            return await resolveFocus(intent, allowLanguageModel: allowLanguageModel)
        }
    }

    // MARK: - Focus

    private static func resolveFocus(_ intent: FocusIntent,
                                     allowLanguageModel: Bool) async -> DetectionQuery {
        guard let rawTarget = intent.target?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTarget.isEmpty else {
            log("saliency", detail: "无目标词")
            return .saliency()
        }

        // 带修饰的短语（白色的鼠标）即使包含词典名词，也走端模型拆 prompt
        if !TargetTranslator.isAttributedPhrase(rawTarget),
           let english = TargetTranslator.lookup(rawTarget) {
            log("dictionary", detail: "\(rawTarget) → \(english) spatial=\(intent.spatialHint?.rawValue ?? "none")")
            return .focus(prompts: [english],
                          displayName: rawTarget,
                          spatialHint: intent.spatialHint)
        }

        // 复杂路径：端侧结构化理解
        if allowLanguageModel,
           let generated = await generateWithFoundationModel(rawTarget: rawTarget,
                                                             spatialHint: intent.spatialHint) {
            log("foundation-models",
                detail: "target=\(rawTarget) prompts=\(generated.yoloPrompts) spatial=\(generated.spatialHint?.rawValue ?? "none") display=\(generated.displayName)")
            return generated
        }

        if let fallback = TargetTranslator.attributedFallback(from: rawTarget) {
            log("attributed-fallback",
                detail: "\(rawTarget) prompts=\(fallback.prompts)")
            return .focus(prompts: fallback.prompts,
                          displayName: fallback.displayName,
                          spatialHint: intent.spatialHint)
        }

        // 回退：异步翻译（可能仍走端模型字符串翻译）+ 规则方位
        let english = await TargetTranslator.translate(rawTarget)
        let reason = allowLanguageModel ? "FM未命中/不可用" : "volatile禁用端模型"
        log("translate-fallback", detail: "\(reason) \(rawTarget) → \(english)")
        return .focus(prompts: [english],
                      displayName: rawTarget,
                      spatialHint: intent.spatialHint)
    }

    private static func log(_ route: String, detail: String) {
        print("[QueryUnderstanding] route=\(route) \(detail)")
    }

    // MARK: - Foundation Models

    private static func generateWithFoundationModel(rawTarget: String,
                                                    spatialHint: SpatialHint?) async -> DetectionQuery? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        return await FoundationQueryModel.generate(rawTarget: rawTarget, spatialHint: spatialHint)
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

        @Guide(description: "1 to 4 short English noun phrases for YOLO-World, e.g. apple, blue book, coffee cup. No full sentences. Do not encode left/right/top/bottom here.")
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
            You convert a Chinese (or English) camera-focus target phrase into a structured detection query.
            The vision model is YOLO-World: it needs short English noun phrases, not captions.
            Rules:
            - yoloPrompts: 1-4 concise English noun phrases (category-like). Include useful synonyms or color/size if present (e.g. "blue book", "mug").
            - Never put left/right/top/bottom/上/下/左/右 into yoloPrompts; put that into spatial instead.
            - displayName: brief Chinese for speaking back to the user.
            - action is almost always "focus" for a target phrase. Use "none" only if the text is not an object focus request.
            - useSaliency=true only when there is no concrete object noun.
            - Output must follow the schema; do not explain.
            """)
        sharedSession = created
        return created
    }

    static func generate(rawTarget: String, spatialHint: SpatialHint?) async -> DetectionQuery? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }

        do {
            let spatialNote = spatialHint?.rawValue ?? "none"
            let prompt = """
            Target phrase: \(rawTarget)
            Rule parser spatial hint (may be none): \(spatialNote)
            Resolve into detection query.
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
            _ = try? await session().respond(to: "苹果", generating: GenerableQuery.self)
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
            .filter { !$0.isEmpty }
        guard !prompts.isEmpty else {
            return .saliency(displayName: value.displayName.isEmpty ? fallbackDisplay : value.displayName)
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
