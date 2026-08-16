import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AskCameraViewModel()

    var body: some View {
        ZStack {
            // 预览与对焦框必须共用同一全屏坐标系，否则 layerRect 相对预览层、
            // SwiftUI overlay 却从安全区顶边起算，框会整体下移。
            ZStack {
                CameraPreviewView(camera: viewModel.camera) { point in
                    viewModel.handleTap(at: point)
                }

                if viewModel.debugMode {
                    debugBoxesOverlay
                }

                focusHighlightOverlay
                countdownOverlay
                recordingBadge
            }
            .ignoresSafeArea()

            if viewModel.camera.authorizationDenied {
                permissionDeniedOverlay
            }

            VStack {
                statusBar
                Spacer()
                bottomControls
            }
        }
        .onAppear { viewModel.onAppear() }
    }

    // MARK: - 对焦高亮

    @ViewBuilder
    private var focusHighlightOverlay: some View {
        ZStack {
            if let highlight = viewModel.focusHighlight {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.yellow, lineWidth: 2)
                    .frame(width: highlight.rect.width, height: highlight.rect.height)
                    .position(x: highlight.rect.midX, y: highlight.rect.midY)
                    .transition(.scale(scale: 1.3).combined(with: .opacity))
                    .animation(.spring(duration: 0.25), value: viewModel.focusHighlight)

                Text(highlight.label)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.yellow, in: Capsule())
                    .foregroundStyle(.black)
                    .position(x: highlight.rect.midX, y: highlight.rect.minY - 16)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 倒计时 / 录像指示

    @ViewBuilder
    private var countdownOverlay: some View {
        ZStack {
            if viewModel.countdownFlashOn {
                Color.white.opacity(0.72)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            if let remaining = viewModel.captureScheduler.countdownRemaining {
                Text("\(remaining)")
                    .font(.system(size: 96, weight: .thin, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
                    .transition(.scale.combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.2), value: remaining)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var recordingBadge: some View {
        if viewModel.camera.isRecording {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                Text(timeString(viewModel.captureScheduler.recordingElapsedSeconds))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 56)
            .padding(.trailing, 16)
            .allowsHitTesting(false)
        }
    }

    private func timeString(_ total: Int) -> String {
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - 调试候选框

    private var debugBoxesOverlay: some View {
        ZStack {
            ForEach(viewModel.debugBoxes) { box in
                Rectangle()
                    .stroke(Color.green.opacity(0.8), lineWidth: 1)
                    .frame(width: box.rect.width, height: box.rect.height)
                    .position(x: box.rect.midX, y: box.rect.midY)

                Text(box.caption)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.green.opacity(0.8))
                    .foregroundStyle(.black)
                    .position(x: box.rect.minX + 40, y: box.rect.minY - 8)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 顶部状态

    private var statusBar: some View {
        Text(viewModel.statusText)
            .font(.footnote)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.top, 8)
    }

    // MARK: - 底部控制

    private var bottomControls: some View {
        VStack(spacing: 12) {
            captionPanel

            if viewModel.captureScheduler.isCountingDown {
                Button("取消倒计时") {
                    viewModel.cancelCountdownTapped()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.black.opacity(0.55), in: Capsule())
            }

            HStack(spacing: 16) {
                Toggle(isOn: $viewModel.voiceFeedbackEnabled) {
                    Image(systemName: "speaker.wave.2")
                }
                .toggleStyle(.button)
                .tint(.yellow)
                .foregroundStyle(.white)
                .accessibilityLabel("语音反馈")

                Toggle(isOn: $viewModel.countdownTorchEnabled) {
                    Image(systemName: viewModel.countdownTorchEnabled
                          ? "flashlight.on.fill"
                          : "flashlight.off.fill")
                }
                .toggleStyle(.button)
                .tint(.orange)
                .foregroundStyle(.white)
                .accessibilityLabel("倒计时闪光灯")

                recordButton
                shutterButton
                micButton

                Toggle(isOn: $viewModel.debugMode) {
                    Image(systemName: "ladybug")
                }
                .toggleStyle(.button)
                .tint(.green)
                .foregroundStyle(.white)
            }
        }
        .padding(.bottom, 30)
    }

    /// 实时字幕：定稿历史（白色实字）+ 未定稿文本（灰色）即时显示。
    @ViewBuilder
    private var captionPanel: some View {
        let hasContent = !viewModel.captionHistory.isEmpty || !viewModel.volatileTranscript.isEmpty
        if viewModel.isListening || hasContent {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(viewModel.captionHistory) { line in
                    Text(line.text)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
                if !viewModel.volatileTranscript.isEmpty {
                    Text(viewModel.volatileTranscript)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                } else if viewModel.captionHistory.isEmpty, viewModel.isListening {
                    Text("……")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .animation(.easeOut(duration: 0.15), value: viewModel.captionHistory)
        }
    }

    private var shutterButton: some View {
        Button {
            viewModel.shutterTapped()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(.white)
                    .frame(width: 58, height: 58)
            }
        }
        .disabled(viewModel.camera.isRecording || viewModel.captureScheduler.isCountingDown)
        .opacity(viewModel.camera.isRecording || viewModel.captureScheduler.isCountingDown ? 0.4 : 1)
        .accessibilityLabel("拍照")
    }

    private var recordButton: some View {
        Button {
            viewModel.recordTapped()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .frame(width: 56, height: 56)
                if viewModel.camera.isRecording {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.red)
                        .frame(width: 22, height: 22)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 28, height: 28)
                }
            }
        }
        .disabled(viewModel.captureScheduler.isCountingDown)
        .opacity(viewModel.captureScheduler.isCountingDown ? 0.4 : 1)
        .accessibilityLabel(viewModel.camera.isRecording ? "停止录像" : "开始录像")
    }

    private var micButton: some View {
        Button {
            viewModel.toggleListening()
        } label: {
            Image(systemName: viewModel.isListening ? "mic.fill" : "mic.slash.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(viewModel.isListening ? Color.red : Color.black.opacity(0.55), in: Circle())
                .overlay {
                    if viewModel.isListening {
                        Circle()
                            .stroke(Color.red.opacity(0.4), lineWidth: 5)
                            .scaleEffect(1.15)
                    }
                }
        }
        .disabled(viewModel.camera.isRecording)
        .opacity(viewModel.camera.isRecording ? 0.35 : 1)
        .accessibilityLabel("语音控制")
    }

    // MARK: - 权限提示

    private var permissionDeniedOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.largeTitle)
            Text("需要相机权限")
                .font(.headline)
            Text("请在 设置 > 隐私与安全性 > 相机 中允许 AskCamera 访问相机。")
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
        .padding(40)
    }
}

#Preview {
    ContentView()
}
