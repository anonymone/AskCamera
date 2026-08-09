import AVFoundation
import CoreVideo
import UIKit

/// 管理相机采集会话与对焦控制。
/// 视频帧同时供预览显示与视觉检测使用。
final class CameraManager: NSObject, ObservableObject {

    let session = AVCaptureSession()

    /// 由 CameraPreviewView 注入，用于视图坐标 <-> 设备坐标转换。
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    @Published private(set) var isRunning = false
    @Published private(set) var authorizationDenied = false

    private let sessionQueue = DispatchQueue(label: "com.askcamera.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoOutputQueue = DispatchQueue(label: "com.askcamera.videooutput")
    private(set) var device: AVCaptureDevice?

    private let frameLock = NSLock()
    private var _latestFrame: CVPixelBuffer?

    /// 每帧回调（在相机输出队列执行，勿做耗时 UI 操作）。用于焦点跟踪。
    var frameHandler: ((CVPixelBuffer) -> Void)?

    // MARK: - 生命周期

    func start() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else {
            await MainActor.run { authorizationDenied = true }
            return
        }
        sessionQueue.async { [self] in
            configureSessionIfNeeded()
            if !session.isRunning {
                session.startRunning()
            }
            DispatchQueue.main.async { self.isRunning = self.session.isRunning }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private var isConfigured = false

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        device = camera

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        // 竖屏方向，使帧缓冲与预览方向一致，简化 Vision 坐标转换。
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        session.commitConfiguration()
        isConfigured = true
    }

    // MARK: - 帧访问

    /// 最近一帧画面，供检测器使用。
    func latestFrame() -> CVPixelBuffer? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return _latestFrame
    }

    // MARK: - 对焦控制

    /// 对焦到设备坐标点（{0,0} 左上 ~ {1,1} 右下，相对横屏 home 键在右方向）。
    /// 由 previewLayer 的转换方法生成，勿手动构造视图坐标。
    func focus(atDevicePoint point: CGPoint) {
        sessionQueue.async { [self] in
            guard let device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = device.isFocusModeSupported(.continuousAutoFocus) ? .continuousAutoFocus : .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    device.exposureMode = device.isExposureModeSupported(.continuousAutoExposure) ? .continuousAutoExposure : .autoExpose
                }
                // 场景大幅变化时系统发出通知，便于上层决定是否恢复全局对焦。
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {
                print("[CameraManager] 对焦配置失败: \(error)")
            }
        }
    }

    /// 恢复画面中心的连续自动对焦（默认状态）。
    func resetFocusToCenter() {
        focus(atDevicePoint: CGPoint(x: 0.5, y: 0.5))
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameLock.lock()
        _latestFrame = pixelBuffer
        frameLock.unlock()
        frameHandler?(pixelBuffer)
    }
}
