import Foundation

/// 查询理解层的统一输出：给 YOLO 的英文 prompt + 给 App 的选择/展示信息。
/// 空间关系不进 YOLO prompt（模型不懂左右），由选择层消费。
struct DetectionQuery: Equatable {
    enum Action: Equatable {
        case focus
        case reset
        /// 非对焦指令（闲聊等），上层应忽略。
        case none
    }

    let action: Action
    /// 1~N 个短英文名词短语，写入 YOLO-World 类别槽位。
    let yoloPrompts: [String]
    /// UI / 语音反馈用的显示名（通常为中文）。
    let displayName: String
    /// 同类多实例时的方位选择；不传给 YOLO。
    let spatialHint: SpatialHint?
    /// true：无明确物体，走显著性检测。
    let useSaliency: Bool

    static let reset = DetectionQuery(
        action: .reset,
        yoloPrompts: [],
        displayName: "",
        spatialHint: nil,
        useSaliency: false
    )

    static let none = DetectionQuery(
        action: .none,
        yoloPrompts: [],
        displayName: "",
        spatialHint: nil,
        useSaliency: false
    )

    static func saliency(displayName: String = "显著物体") -> DetectionQuery {
        DetectionQuery(
            action: .focus,
            yoloPrompts: [],
            displayName: displayName,
            spatialHint: nil,
            useSaliency: true
        )
    }

    static func focus(prompts: [String],
                      displayName: String,
                      spatialHint: SpatialHint? = nil) -> DetectionQuery {
        let cleaned = prompts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return DetectionQuery(
            action: .focus,
            yoloPrompts: cleaned,
            displayName: displayName,
            spatialHint: spatialHint,
            useSaliency: cleaned.isEmpty
        )
    }
}
