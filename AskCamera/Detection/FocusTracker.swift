import CoreVideo
import Foundation
import Vision

/// 基于 VNTrackObjectRequest 的目标跟踪。
/// 语音对焦成功后启动，逐帧跟踪目标框，避免每帧重跑开放词汇检测（省电）。
/// 线程模型：process(_:) 在相机输出队列调用，start/stop 可从任意线程调用（内部加锁）。
final class FocusTracker {

    /// 置信度低于此阈值视为跟丢。
    private let lostThreshold: Float = 0.3

    private let lock = NSLock()
    private var sequenceHandler = VNSequenceRequestHandler()
    private var lastObservation: VNDetectedObjectObservation?

    var isTracking: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastObservation != nil
    }

    /// 开始跟踪目标框（Vision 归一化坐标，左下原点）。
    func start(with boundingBox: CGRect) {
        // 近零尺寸的框会让 Vision 内部报错
        guard boundingBox.width > 0.01, boundingBox.height > 0.01 else { return }
        lock.lock()
        sequenceHandler = VNSequenceRequestHandler()
        lastObservation = VNDetectedObjectObservation(boundingBox: boundingBox)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        lastObservation = nil
        lock.unlock()
    }

    enum Update {
        /// 目标仍在跟踪中，返回最新框（Vision 坐标）。
        case tracking(CGRect)
        /// 目标跟丢。
        case lost
    }

    /// 处理一帧。未在跟踪时返回 nil。
    func process(_ pixelBuffer: CVPixelBuffer) -> Update? {
        lock.lock()
        guard let observation = lastObservation else {
            lock.unlock()
            return nil
        }
        let handler = sequenceHandler
        lock.unlock()

        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .accurate

        do {
            try handler.perform([request], on: pixelBuffer)
        } catch {
            stop()
            return .lost
        }

        guard let newObservation = request.results?.first as? VNDetectedObjectObservation,
              newObservation.confidence >= lostThreshold else {
            stop()
            return .lost
        }

        lock.lock()
        lastObservation = newObservation
        lock.unlock()
        return .tracking(newObservation.boundingBox)
    }
}
