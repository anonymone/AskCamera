import CoreVideo
import Foundation

/// 检测结果。boundingBox 为 Vision 归一化坐标（左下原点，0~1）。
struct DetectionResult {
    let boundingBox: CGRect
    let label: String
    let confidence: Float
}

/// 视觉检测抽象。
/// 当前实现为 Vision 显著性检测（忽略 target 文本）；
/// 下一阶段接入 YOLO-World（开放词汇，按 target 文本匹配任意物体）。
protocol ObjectDetecting {
    /// 在给定帧中查找目标。target 为 nil 时返回画面中最显著的物体。
    func detect(target: String?, in pixelBuffer: CVPixelBuffer) async throws -> DetectionResult?
}
