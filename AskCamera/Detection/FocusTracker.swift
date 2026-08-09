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
    /// 每次 start/stop 递增，用来丢弃检测期间仍在飞行的旧帧结果。
    private var generation: UInt64 = 0

    var isTracking: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastObservation != nil
    }

    /// 开始跟踪目标框（Vision 归一化坐标，左下原点）。返回本次跟踪世代号。
    @discardableResult
    func start(with boundingBox: CGRect) -> UInt64 {
        // 近零尺寸的框会让 Vision 内部报错
        guard boundingBox.width > 0.01, boundingBox.height > 0.01 else { return 0 }
        lock.lock()
        generation += 1
        let started = generation
        sequenceHandler = VNSequenceRequestHandler()
        lastObservation = VNDetectedObjectObservation(boundingBox: boundingBox)
        lock.unlock()
        return started
    }

    func stop() {
        lock.lock()
        generation += 1
        lastObservation = nil
        lock.unlock()
    }

    enum Update {
        /// 目标仍在跟踪中，返回最新框（Vision 坐标）与世代号。
        case tracking(CGRect, generation: UInt64)
        /// 目标跟丢。
        case lost(generation: UInt64)
    }

    /// 处理一帧。未在跟踪时返回 nil。
    func process(_ pixelBuffer: CVPixelBuffer) -> Update? {
        lock.lock()
        guard let observation = lastObservation else {
            lock.unlock()
            return nil
        }
        let gen = generation
        let handler = sequenceHandler
        lock.unlock()

        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .accurate

        do {
            try handler.perform([request], on: pixelBuffer)
        } catch {
            return finishIfCurrent(gen, observation: nil, lost: true)
        }

        guard let newObservation = request.results?.first as? VNDetectedObjectObservation,
              newObservation.confidence >= lostThreshold else {
            return finishIfCurrent(gen, observation: nil, lost: true)
        }

        return finishIfCurrent(gen, observation: newObservation, lost: false)
    }

    /// 仅当 start/stop 未在 perform 期间发生时才写回，避免旧跟踪覆盖新检测。
    private func finishIfCurrent(_ gen: UInt64,
                                 observation: VNDetectedObjectObservation?,
                                 lost: Bool) -> Update? {
        lock.lock()
        defer { lock.unlock() }
        guard gen == generation else { return nil }
        lastObservation = observation
        if lost {
            return .lost(generation: gen)
        }
        guard let observation else { return nil }
        return .tracking(observation.boundingBox, generation: gen)
    }
}
