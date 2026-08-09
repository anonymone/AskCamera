import Foundation

/// 倒计时与定时停止调度（App 层，与 AVFoundation 解耦）。
/// 「取消」只清未触发的倒计时，不停止已在进行的录像。
@MainActor
final class CaptureScheduler: ObservableObject {

    /// 倒计时剩余秒数；nil 表示无待执行倒计时。
    @Published private(set) var countdownRemaining: Int?
    /// 录像已进行秒数（仅 UI）；是否在录由 CameraManager 为准时可同步写入。
    @Published private(set) var recordingElapsedSeconds: Int = 0
    @Published private(set) var isCountingDown = false

    private var pendingTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    var hasPendingCountdown: Bool { isCountingDown }

    /// 安排拍照：delay 秒倒计时后调用 `fire`。
    func schedulePhoto(delaySeconds: Int, fire: @escaping @MainActor () async -> Void) {
        beginCountdown(delaySeconds: delaySeconds) {
            await fire()
        }
    }

    /// 安排录像：delay 秒后 `start`，再过 duration 秒自动 `stop`（可被手动 stop 取消定时）。
    func scheduleVideo(delaySeconds: Int,
                       durationSeconds: Int,
                       start: @escaping @MainActor () async -> Void,
                       stop: @escaping @MainActor () async -> Void) {
        beginCountdown(delaySeconds: delaySeconds) { [weak self] in
            guard let self else { return }
            await start()
            self.armDuration(seconds: durationSeconds, stop: stop)
        }
    }

    /// 仅取消倒计时，不动录像。
    func cancelPending() {
        generation += 1
        pendingTask?.cancel()
        pendingTask = nil
        countdownRemaining = nil
        isCountingDown = false
    }

    /// 停止录像侧的定时器与计时 UI（在真正 stopRecording 前后由上层调用）。
    func clearRecordingTimers() {
        durationTask?.cancel()
        durationTask = nil
        elapsedTask?.cancel()
        elapsedTask = nil
        recordingElapsedSeconds = 0
    }

    func markRecordingStarted() {
        recordingElapsedSeconds = 0
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.recordingElapsedSeconds += 1
            }
        }
    }

    // MARK: - Private

    private func beginCountdown(delaySeconds: Int, fire: @escaping @MainActor () async -> Void) {
        cancelPending()
        generation += 1
        let gen = generation

        let delay = max(0, delaySeconds)
        if delay == 0 {
            pendingTask = Task { await fire() }
            return
        }

        isCountingDown = true
        countdownRemaining = delay
        pendingTask = Task { [weak self] in
            guard let self else { return }
            var left = delay
            while left > 0 {
                self.countdownRemaining = left
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, gen == self.generation else { return }
                left -= 1
            }
            self.countdownRemaining = nil
            self.isCountingDown = false
            guard gen == self.generation else { return }
            await fire()
        }
    }

    private func armDuration(seconds: Int, stop: @escaping @MainActor () async -> Void) {
        durationTask?.cancel()
        let seconds = max(1, seconds)
        durationTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await stop()
        }
    }
}
