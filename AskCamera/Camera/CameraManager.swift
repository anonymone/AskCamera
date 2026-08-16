import AVFoundation
import CoreVideo
import Photos
import UIKit

enum CaptureError: LocalizedError {
    case notReady
    case photoFailed(String)
    case recordingFailed(String)
    case alreadyRecording
    case notRecording
    case libraryDenied

    var errorDescription: String? {
        switch self {
        case .notReady: return "相机尚未就绪"
        case .photoFailed(let m): return "拍照失败：\(m)"
        case .recordingFailed(let m): return "录像失败：\(m)"
        case .alreadyRecording: return "已在录像中"
        case .notRecording: return "当前没有在录像"
        case .libraryDenied: return "没有相册写入权限"
        }
    }
}

/// 管理相机采集会话、对焦控制，以及拍照 / 录像。
/// 视频帧同时供预览显示与视觉检测使用。
final class CameraManager: NSObject, ObservableObject {

    let session = AVCaptureSession()

    /// 由 CameraPreviewView 注入，用于视图坐标 <-> 设备坐标转换。
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    @Published private(set) var isRunning = false
    @Published private(set) var authorizationDenied = false
    @Published private(set) var isRecording = false

    private let sessionQueue = DispatchQueue(label: "com.askcamera.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoOutputQueue = DispatchQueue(label: "com.askcamera.videooutput")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private(set) var device: AVCaptureDevice?

    private let frameLock = NSLock()
    private var _latestFrame: CVPixelBuffer?
    private var _bufferSize: CGSize = .zero

    /// 每帧回调（在相机输出队列执行，勿做耗时 UI 操作）。用于焦点跟踪。
    var frameHandler: ((CVPixelBuffer) -> Void)?

    private var photoContinuation: CheckedContinuation<Void, Error>?
    private var recordingContinuation: CheckedContinuation<URL, Error>?
    private var currentMovieURL: URL?

    // MARK: - 生命周期

    func start() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else {
            await MainActor.run { authorizationDenied = true }
            return
        }
        // 麦克风用于录像音轨；拒绝时仍可录像（无声）+ 语音听写可再申请
        _ = await AVCaptureDevice.requestAccess(for: .audio)

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
            if movieOutput.isRecording {
                movieOutput.stopRecording()
            }
            if session.isRunning {
                session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = false
                self.isRecording = false
            }
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

        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
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
    func layerRect(fromVisionRect box: CGRect) -> CGRect? {
        guard let layer = previewLayer else { return nil }
        frameLock.lock()
        let bufferSize = _bufferSize
        frameLock.unlock()
        let layerSize = layer.bounds.size
        guard bufferSize.width > 0, bufferSize.height > 0,
              layerSize.width > 0, layerSize.height > 0 else { return nil }

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

    func focus(atDevicePoint point: CGPoint) {
        sessionQueue.async { [self] in
            guard let device else { return }
            do {
                let torchWasOn = device.hasTorch && device.torchMode == .on
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = device.isFocusModeSupported(.continuousAutoFocus) ? .continuousAutoFocus : .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    device.exposureMode = device.isExposureModeSupported(.continuousAutoExposure) ? .continuousAutoExposure : .autoExpose
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                // 对焦会重配曝光，可能把手电筒打灭；倒计时闪烁期间需要保持灯态
                if torchWasOn, device.isTorchAvailable, device.isTorchModeSupported(.on) {
                    try device.setTorchModeOn(level: min(AVCaptureDevice.maxAvailableTorchLevel, 1.0))
                }
                device.unlockForConfiguration()
            } catch {
                print("[CameraManager] 对焦配置失败: \(error)")
            }
        }
    }

    func resetFocusToCenter() {
        focus(atDevicePoint: CGPoint(x: 0.5, y: 0.5))
    }

    // MARK: - 倒计时手电筒

    /// 开关后置手电筒。倒计时结束后、取消时必须关掉，以免影响拍照曝光。
    func setTorchEnabled(_ on: Bool) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [self] in
                defer { cont.resume() }
                applyTorch(on)
            }
        }
    }

    /// 在 session 队列上改手电筒，供对焦配置时保持当前灯态。
    private func applyTorch(_ on: Bool) {
        guard let device, device.hasTorch else { return }
        guard device.isTorchModeSupported(on ? .on : .off) else { return }
        if on, !device.isTorchAvailable {
            print("[CameraManager] 手电筒暂不可用（过热或被占用）")
            return
        }
        do {
            try device.lockForConfiguration()
            if on {
                try device.setTorchModeOn(level: min(AVCaptureDevice.maxAvailableTorchLevel, 1.0))
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
        } catch {
            print("[CameraManager] 手电筒切换失败: \(error)")
        }
    }

    // MARK: - 拍照

    /// 拍照并保存到系统相册。
    func capturePhoto() async throws {
        try await ensurePhotoLibraryAddAccess()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                guard session.isRunning else {
                    cont.resume(throwing: CaptureError.notReady)
                    return
                }
                if photoContinuation != nil {
                    cont.resume(throwing: CaptureError.photoFailed("已有拍照进行中"))
                    return
                }
                photoContinuation = cont
                let settings = AVCapturePhotoSettings()
                if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                    // 默认 settings 即可；显式保持高质量
                }
                photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    // MARK: - 录像

    /// 开始录像到临时文件；停止后写入相册。
    func startRecording() async throws {
        try await ensurePhotoLibraryAddAccess()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                guard session.isRunning else {
                    cont.resume(throwing: CaptureError.notReady)
                    return
                }
                guard !movieOutput.isRecording else {
                    cont.resume(throwing: CaptureError.alreadyRecording)
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AskCamera-\(UUID().uuidString).mov")
                currentMovieURL = url
                movieOutput.startRecording(to: url, recordingDelegate: self)
                DispatchQueue.main.async { self.isRecording = true }
                cont.resume()
            }
        }
    }

    /// 停止录像并保存到相册。
    func stopRecording() async throws {
        let fileURL: URL = try await withCheckedThrowingContinuation { cont in
            sessionQueue.async { [self] in
                guard movieOutput.isRecording else {
                    cont.resume(throwing: CaptureError.notRecording)
                    return
                }
                if recordingContinuation != nil {
                    cont.resume(throwing: CaptureError.recordingFailed("停止请求重叠"))
                    return
                }
                recordingContinuation = cont
                movieOutput.stopRecording()
            }
        }
        try await saveVideoToLibrary(fileURL: fileURL)
        try? FileManager.default.removeItem(at: fileURL)
        await MainActor.run { self.isRecording = false }
    }

    // MARK: - 相册

    private func ensurePhotoLibraryAddAccess() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard newStatus == .authorized || newStatus == .limited else {
                throw CaptureError.libraryDenied
            }
        default:
            throw CaptureError.libraryDenied
        }
    }

    private func savePhotoToLibrary(data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }

    private func saveVideoToLibrary(fileURL: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        }
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

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let cont = photoContinuation
        photoContinuation = nil
        if let error {
            cont?.resume(throwing: CaptureError.photoFailed(error.localizedDescription))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            cont?.resume(throwing: CaptureError.photoFailed("无法编码照片"))
            return
        }
        Task {
            do {
                try await savePhotoToLibrary(data: data)
                cont?.resume()
            } catch {
                cont?.resume(throwing: error)
            }
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        let cont = recordingContinuation
        recordingContinuation = nil
        DispatchQueue.main.async { self.isRecording = false }
        if let error {
            cont?.resume(throwing: CaptureError.recordingFailed(error.localizedDescription))
            return
        }
        cont?.resume(returning: outputFileURL)
    }
}
