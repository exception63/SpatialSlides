import SpatialBridgeKit
import SwiftUI

struct SpatialCameraView: View {
    @Environment(SpatialCameraModel.self) private var model
    @Environment(SpatialRecordingController.self) private var recorder
    @State private var recordingChromeVisible = true

    var body: some View {
        ZStack {
            SpatialARView()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if !recorder.isRecording && !recorder.isPreparing {
                    statusBar
                }
                Spacer()
                if !recorder.isPreparing && (!recorder.isRecording || recordingChromeVisible) {
                    controls
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if recorder.isRecording && !recordingChromeVisible {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.16)) {
                            recordingChromeVisible = true
                        }
                    }
            }
        }
        .background(.black)
        .alert("Spatial Camera", isPresented: errorPresented) {
            Button("好", role: .cancel) {
                recorder.clearError()
            }
        } message: {
            Text(recorder.errorMessage ?? model.lastError ?? "")
        }
    }

    private var statusBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 9, height: 9)
                Text(model.connectionLabel)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(model.calibrationLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(
                        model.alignmentFrame == nil || model.calibrationNeedsImprovement
                            ? .yellow
                            : .green
                    )
                    .lineLimit(1)
            }
            if let assetStatusLabel = model.assetStatusLabel {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                    Text(assetStatusLabel)
                        .font(.caption2.weight(.medium))
                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.82))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.62), in: .rect(cornerRadius: 8))
    }

    private var controls: some View {
        HStack(spacing: 18) {
            Button {
                model.resetCalibration()
            } label: {
                Image(systemName: "scope")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(CameraToolButtonStyle())
            .accessibilityLabel("重新标定")

            Spacer()

            Button {
                Task {
                    if recorder.isRecording {
                        await recorder.stop()
                        recordingChromeVisible = true
                    } else {
                        await recorder.start()
                        if recorder.isRecording {
                            try? await Task.sleep(for: .milliseconds(350))
                            withAnimation(.easeOut(duration: 0.18)) {
                                recordingChromeVisible = false
                            }
                        }
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 68, height: 68)
                    if recorder.isRecording {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.red)
                            .frame(width: 28, height: 28)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 54, height: 54)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.isRecording ? "停止录制" : "开始录制")

            Spacer()

            Button {
                recorder.microphoneEnabled.toggle()
            } label: {
                Image(systemName: recorder.microphoneEnabled ? "mic.fill" : "mic.slash.fill")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(CameraToolButtonStyle())
            .disabled(recorder.isRecording)
            .accessibilityLabel("麦克风")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(height: 88)
        .background(.black.opacity(0.62), in: .rect(cornerRadius: 8))
        .overlay(alignment: .top) {
            if recorder.isRecording {
                Text(recorder.elapsedLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.red, in: Capsule())
                    .offset(y: -15)
            }
        }
    }

    private var connectionColor: Color {
        if case .connected = model.connectionState { return .green }
        if case .failed = model.connectionState { return .red }
        return .yellow
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { recorder.errorMessage != nil || model.lastError != nil },
            set: {
                if !$0 {
                    recorder.clearError()
                    model.clearError()
                }
            }
        )
    }
}

private struct CameraToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 22, weight: .semibold))
            .background(.white.opacity(configuration.isPressed ? 0.24 : 0.12), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}
