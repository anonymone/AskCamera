import Foundation

/// 拍照 / 录像相关语音与按钮指令（与对焦链路解耦）。
enum CaptureCommand: Equatable {
    /// 拍照；delaySeconds 为开始前倒计时（0 = 立即）。
    case photo(delaySeconds: Int)
    /// 开始录像；未指定时长时默认 15 秒后自动停止。
    case startVideo(delaySeconds: Int, durationSeconds: Int)
    /// 停止录像（不影响倒计时以外的对焦状态）。
    case stopVideo
    /// 仅取消未触发的倒计时，不停止已在进行的录像。
    case cancelPending

    static let defaultVideoDurationSeconds = 15
}
