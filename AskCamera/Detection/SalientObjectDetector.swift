import CoreVideo
import Foundation
import Vision

/// 基于 Vision 物体显著性的检测器（兜底实现）。
/// 返回画面中"最像物体"的区域，不理解 target 文本。
/// 用于未指定目标词、或 YOLO-World 模型不可用的场景。
struct SalientObjectDetector: ObjectDetecting {

    func detect(target: String?, in pixelBuffer: CVPixelBuffer) async throws -> [DetectionResult] {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try handler.perform([request])

        let observation = request.results?.first as? VNSaliencyImageObservation
        guard let objects = observation?.salientObjects, !objects.isEmpty else {
            return []
        }
        return objects
            .sorted { $0.confidence > $1.confidence }
            .map { DetectionResult(boundingBox: $0.boundingBox,
                                   label: target ?? "显著物体",
                                   confidence: $0.confidence) }
    }
}
