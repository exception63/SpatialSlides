import AVFoundation
import Foundation
import Observation
import Photos
import ReplayKit
#if !targetEnvironment(simulator)
import ScreenCaptureKit
#endif

@MainActor
@Observable
final class SpatialRecordingController {
    var microphoneEnabled = true
    private(set) var isPreparing = false
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var errorMessage: String?

    private var timer: Timer?
    private var startedAt: Date?
    private var outputURL: URL?
    #if !targetEnvironment(simulator)
    private var screenCaptureRecorder: AnyObject?
    #endif

    var elapsedLabel: String {
        let seconds = max(Int(elapsed), 0)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func start() async {
        guard !isRecording, !isPreparing else { return }
        isPreparing = true
        errorMessage = nil
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpatialCamera-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        #if !targetEnvironment(simulator)
        if #available(iOS 27.0, *) {
            do {
                let recorder = ScreenCaptureRecorder()
                try await recorder.start(
                    outputURL: outputURL,
                    showsMicrophoneControl: microphoneEnabled
                )
                screenCaptureRecorder = recorder
                self.outputURL = outputURL
                isPreparing = false
                beginTimer()
                return
            } catch {
                screenCaptureRecorder = nil
                if case RecordingError.captureCancelled = error {
                    isPreparing = false
                    errorMessage = error.localizedDescription
                    return
                }
            }
        }
        #endif

        try? FileManager.default.removeItem(at: outputURL)
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            isPreparing = false
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
            isPreparing = false
            errorMessage = startError.localizedDescription
        } else {
            self.outputURL = outputURL
            isPreparing = false
            beginTimer()
        }
    }

    func stop() async {
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil
        guard let outputURL else {
            finishState()
            errorMessage = "找不到录制输出文件"
            return
        }
        do {
            #if !targetEnvironment(simulator)
            if #available(iOS 27.0, *),
               let screenCaptureRecorder = screenCaptureRecorder as? ScreenCaptureRecorder {
                try await screenCaptureRecorder.stop()
                self.screenCaptureRecorder = nil
            } else {
                try await RPScreenRecorder.shared().stopRecording(withOutput: outputURL)
            }
            #else
            try await RPScreenRecorder.shared().stopRecording(withOutput: outputURL)
            #endif
            try await validateRecording(outputURL)
            finishState()
            try await saveToPhotos(outputURL)
            try? FileManager.default.removeItem(at: outputURL)
        } catch {
            finishState()
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func beginTimer() {
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

    private func finishState() {
        isPreparing = false
        isRecording = false
        startedAt = nil
        outputURL = nil
    }

    private func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw RecordingError.photoAccessDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: .video, fileURL: url, options: options)
        }
    }

    private func validateRecording(_ url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RecordingError.invalidRecording("系统没有生成视频文件")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 1_024 else {
            throw RecordingError.invalidRecording("视频文件为空或尚未写完")
        }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isValid,
              !duration.isIndefinite,
              duration.seconds > 0.05,
              !videoTracks.isEmpty else {
            throw RecordingError.invalidRecording("视频封装不完整，请重新录制")
        }
    }
}

private enum RecordingError: LocalizedError {
    case photoAccessDenied
    case captureCancelled
    case captureDidNotStart
    case finalizationTimedOut
    case invalidRecording(String)

    var errorDescription: String? {
        switch self {
        case .photoAccessDenied:
            return "没有保存到照片的权限"
        case .captureCancelled:
            return "已取消录制授权"
        case .captureDidNotStart:
            return "系统没有启动录制"
        case .finalizationTimedOut:
            return "视频完成写入超时，请稍后重试"
        case .invalidRecording(let reason):
            return "录制文件无效：\(reason)"
        }
    }
}

#if !targetEnvironment(simulator)
@available(iOS 27.0, *)
private final class ScreenCaptureRecorder: NSObject, @unchecked Sendable {
    private var pickerContinuation: CheckedContinuation<SCContentFilter, Error>?
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private let finishLock = NSLock()
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var finishTimeoutTask: Task<Void, Never>?
    private var terminalError: Error?

    func start(outputURL: URL, showsMicrophoneControl: Bool) async throws {
        finishLock.withLock {
            terminalError = nil
        }
        let filter = try await chooseCurrentApplication(
            showsMicrophoneControl: showsMicrophoneControl
        )
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.capturesAudio = true
        streamConfiguration.excludesCurrentProcessAudio = false

        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = outputURL
        outputConfiguration.outputFileType = .mp4
        outputConfiguration.videoCodecType = .h264
        outputConfiguration.mixesAudioWithMicrophone = true

        let recordingOutput = SCRecordingOutput(
            configuration: outputConfiguration,
            delegate: self
        )
        let stream = SCStream(
            filter: filter,
            configuration: streamConfiguration,
            delegate: self
        )
        try stream.addRecordingOutput(recordingOutput)
        self.recordingOutput = recordingOutput
        self.stream = stream
        try await stream.startCapture()
        let terminalError = finishLock.withLock { terminalError }
        if let terminalError { throw terminalError }
    }

    func stop() async throws {
        guard let stream else { throw RecordingError.captureDidNotStart }
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    self?.resolveFinish(.failure(RecordingError.finalizationTimedOut))
                }
                let existingError = finishLock.withLock { () -> Error? in
                    guard terminalError == nil else { return terminalError }
                    finishContinuation = continuation
                    finishTimeoutTask = timeoutTask
                    return nil
                }
                if let existingError {
                    timeoutTask.cancel()
                    continuation.resume(throwing: existingError)
                    return
                }

                Task { [weak self] in
                    do {
                        try await stream.stopCapture()
                    } catch {
                        self?.resolveFinish(.failure(error))
                    }
                }
            }
            self.stream = nil
            recordingOutput = nil
        } catch {
            self.stream = nil
            recordingOutput = nil
            throw error
        }
    }

    private func resolveFinish(_ result: Result<Void, Error>) {
        let state = finishLock.withLock {
            if case .failure(let error) = result {
                terminalError = error
            }
            let continuation = finishContinuation
            finishContinuation = nil
            let timeoutTask = finishTimeoutTask
            finishTimeoutTask = nil
            return (continuation, timeoutTask)
        }

        state.1?.cancel()
        state.0?.resume(with: result)
    }

    private func chooseCurrentApplication(
        showsMicrophoneControl: Bool
    ) async throws -> SCContentFilter {
        try await withCheckedThrowingContinuation { continuation in
            pickerContinuation = continuation
            let picker = SCContentSharingPicker.shared
            var configuration = SCContentSharingPickerConfiguration()
            configuration.showsMicrophoneControl = showsMicrophoneControl
            picker.defaultConfiguration = configuration
            picker.add(self)
            picker.isActive = true
            picker.presentForCurrentApplication()
        }
    }
}

@available(iOS 27.0, *)
extension ScreenCaptureRecorder: SCContentSharingPickerObserver {
    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        picker.remove(self)
        pickerContinuation?.resume(throwing: RecordingError.captureCancelled)
        pickerContinuation = nil
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        picker.remove(self)
        pickerContinuation?.resume(returning: filter)
        pickerContinuation = nil
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        SCContentSharingPicker.shared.remove(self)
        pickerContinuation?.resume(throwing: error)
        pickerContinuation = nil
    }
}

@available(iOS 27.0, *)
extension ScreenCaptureRecorder: SCRecordingOutputDelegate {
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        resolveFinish(.failure(error))
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        resolveFinish(.success(()))
    }
}

@available(iOS 27.0, *)
extension ScreenCaptureRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        resolveFinish(.failure(error))
    }
}
#endif
