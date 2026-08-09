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
    private var _bufferSize: CGSize = .zero

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

    // MARK: - 坐标转换

    /// Vision 归一化框（左下原点，相对旋转后的输出帧）→ 预览层坐标。
    ///
    /// VideoDataOutput 与 PreviewLayer 都固定为竖屏 90°，帧方向与预览一致，
    /// 不必再绕元数据/传感器坐标系。按 videoGravity = resizeAspectFill
    /// 做等比铺满 + 裁切即可。
    func layerRect(fromVisionRect box: CGRect) -> CGRect? {
        guard let layer = previewLayer else { return nil }
        frameLock.lock()
        let bufferSize = _bufferSize
        frameLock.unlock()
        let layerSize = layer.bounds.size
        guard bufferSize.width > 0, bufferSize.height > 0,
              layerSize.width > 0, layerSize.height > 0 else { return nil }

        // Vision 左下 → 图像左上
        let imageRect = CGRect(x: box.origin.x,
                               y: 1 - box.origin.y - box.height,
                               width: box.width,
                               height: box.height)

        let imageAspect = bufferSize.width / bufferSize.height
        let layerAspect = layerSize.width / layerSize.height
        let scale: CGFloat
        let xOffset: CGFloat
        let yOffset: CGFloat
        if imageAspect > layerAspect {
            scale = layerSize.height / bufferSize.height
            xOffset = (layerSize.width - bufferSize.width * scale) / 2
            yOffset = 0
        } else {
            scale = layerSize.width / bufferSize.width
            xOffset = 0
            yOffset = (layerSize.height - bufferSize.height * scale) / 2
        }

        return CGRect(x: imageRect.origin.x * bufferSize.width * scale + xOffset,
                      y: imageRect.origin.y * bufferSize.height * scale + yOffset,
                      width: imageRect.width * bufferSize.width * scale,
                      height: imageRect.height * bufferSize.height * scale)
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
        _bufferSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                             height: CVPixelBufferGetHeight(pixelBuffer))
        frameLock.unlock()
        frameHandler?(pixelBuffer)
    }
}
