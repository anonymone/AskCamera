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
                .id(highlight.id)
                .animation(.spring(duration: 0.3), value: viewModel.focusHighlight)
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
            if !viewModel.volatileTranscript.isEmpty {
                Text(viewModel.volatileTranscript)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.4), in: Capsule())
            }

            HStack(spacing: 28) {
                Toggle(isOn: $viewModel.voiceFeedbackEnabled) {
                    Image(systemName: "speaker.wave.2")
                }
                .toggleStyle(.button)
                .tint(.yellow)
                .foregroundStyle(.white)

                micButton

                // 占位保持麦克风居中
                Image(systemName: "speaker.wave.2")
                    .opacity(0)
            }
        }
        .padding(.bottom, 30)
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
