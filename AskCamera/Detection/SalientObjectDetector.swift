import CoreVideo
import Foundation
import Vision

/// 基于 Vision 物体显著性的检测器（阶段一兜底实现）。
/// 找到画面中"最像一个物体"的区域，暂不支持按文本匹配目标——
/// 说"对焦到苹果"时会对焦到最显著的物体，开放词汇匹配待 YOLO-World 接入。
struct SalientObjectDetector: ObjectDetecting {

    func detect(target: String?, in pixelBuffer: CVPixelBuffer) async throws -> DetectionResult? {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try handler.perform([request])

        let observation = request.results?.first as? VNSaliencyImageObservation
        guard let best = observation?.salientObjects?.max(by: { $0.confidence < $1.confidence }) else {
            return nil
        }
        return DetectionResult(boundingBox: best.boundingBox,
                               label: target ?? "显著物体",
                               confidence: best.confidence)
    }
}
