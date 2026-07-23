import Foundation
import Observation
import Photos
import ReplayKit

@MainActor
@Observable
final class SpatialRecordingController {
    var microphoneEnabled = true
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var errorMessage: String?

    private var timer: Timer?
    private var startedAt: Date?

    var elapsedLabel: String {
        let seconds = max(Int(elapsed), 0)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func start() async {
        guard !isRecording else { return }
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            errorMessage = "当前设备暂时不能录制屏幕"
            return
        }
        recorder.isMicrophoneEnabled = microphoneEnabled
        let startError: Error? = await withCheckedContinuation { continuation in
            recorder.startRecording { error in
                continuation.resume(returning: error)
            }
        }
        if let startError {
            errorMessage = startError.localizedDescription
        } else {
            isRecording = true
            startedAt = Date()
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let startedAt = self.startedAt else { return }
                    self.elapsed = Date().timeIntervalSince(startedAt)
                }
            }
        }
    }

    func stop() async {
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpatialCamera-\(UUID().uuidString).mp4")
        do {
            try await RPScreenRecorder.shared().stopRecording(withOutput: outputURL)
            isRecording = false
            startedAt = nil
            try await saveToPhotos(outputURL)
            try? FileManager.default.removeItem(at: outputURL)
        } catch {
            isRecording = false
            startedAt = nil
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw RecordingError.photoAccessDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}

private enum RecordingError: LocalizedError {
    case photoAccessDenied

    var errorDescription: String? {
        "没有保存到照片的权限"
    }
}
