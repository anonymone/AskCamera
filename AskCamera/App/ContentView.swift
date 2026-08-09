import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AskCameraViewModel()

    var body: some View {
        ZStack {
            CameraPreviewView(camera: viewModel.camera) { point in
                viewModel.handleTap(at: point)
            }
            .ignoresSafeArea()

            if viewModel.camera.authorizationDenied {
                permissionDeniedOverlay
            }

            if viewModel.debugMode {
                debugBoxesOverlay
            }

            focusHighlightOverlay

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
        if let highlight = viewModel.focusHighlight {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.yellow, lineWidth: 2)
                .frame(width: highlight.rect.width, height: highlight.rect.height)
                .position(x: highlight.rect.midX, y: highlight.rect.midY)
                .overlay(alignment: .top) {
                    Text(highlight.label)
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.yellow, in: Capsule())
                        .foregroundStyle(.black)
                        .position(x: highlight.rect.midX, y: highlight.rect.minY - 16)
                }
                .transition(.scale(scale: 1.3).combined(with: .opacity))
                .animation(.spring(duration: 0.25), value: viewModel.focusHighlight)
        }
    }

    // MARK: - 调试候选框

    private var debugBoxesOverlay: some View {
        ForEach(viewModel.debugBoxes) { box in
            Rectangle()
                .stroke(Color.green.opacity(0.8), lineWidth: 1)
                .frame(width: box.rect.width, height: box.rect.height)
                .position(x: box.rect.midX, y: box.rect.midY)
                .overlay(alignment: .topLeading) {
                    Text(box.caption)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.green.opacity(0.8))
                        .foregroundStyle(.black)
                        .position(x: box.rect.minX + 40, y: box.rect.minY - 8)
                }
        }
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

            HStack(spacing: 28) {
                Toggle(isOn: $viewModel.voiceFeedbackEnabled) {
                    Image(systemName: "speaker.wave.2")
                }
                .toggleStyle(.button)
                .tint(.yellow)
                .foregroundStyle(.white)

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

    private var micButton: some View {
        Button {
            viewModel.toggleListening()
        } label: {
            Image(systemName: viewModel.isListening ? "mic.fill" : "mic.slash.fill")
                .font(.title)
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(viewModel.isListening ? Color.red : Color.black.opacity(0.55), in: Circle())
                .overlay {
                    if viewModel.isListening {
                        Circle()
                            .stroke(Color.red.opacity(0.4), lineWidth: 6)
                            .scaleEffect(1.2)
                    }
                }
        }
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
