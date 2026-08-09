import CoreVideo
import Foundation

/// 检测结果。boundingBox 为 Vision 归一化坐标（左下原点，0~1）。
struct DetectionResult {
    let boundingBox: CGRect
    let label: String
    let confidence: Float
}

/// 视觉检测抽象。
/// - YOLOWorldDetector：开放词汇，按 target 英文文本匹配任意物体
/// - SalientObjectDetector：显著性兜底，忽略 target
protocol ObjectDetecting {
    /// 在给定帧中查找目标，返回按置信度降序的候选列表。
    /// target 为 nil 时的行为由实现决定（显著性检测返回所有显著物体）。
    func detect(target: String?, in pixelBuffer: CVPixelBuffer) async throws -> [DetectionResult]
}
