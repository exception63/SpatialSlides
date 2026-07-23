import Foundation
import Observation
import SpatialBridgeKit
import simd
import UIKit

@MainActor
@Observable
final class SpatialCameraModel: @unchecked Sendable {
    private(set) var connectionState: SpatialBridgeConnectionState = .stopped
    private(set) var manifest: BridgeDeckManifest?
    private(set) var snapshot: BridgeSlidesSnapshot?
    private(set) var sceneRevision = 0
    private(set) var alignmentRevision = 0
    private(set) var alignmentFrame: SharedAlignmentFrame?
    private(set) var calibrationOrigin: SIMD3<Float>?
    private(set) var calibrationForward: SIMD3<Float>?
    private(set) var lastError: String?

    private let client = LocalSpatialBridgeClient()
    private var sequence: UInt64 = 0
    private var assetURLs: [String: URL] = [:]
    private var requestedAssets: Set<String> = []
    private var started = false

    init() {
        client.onStateChange = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [self, state] in
                self.handleConnectionState(state)
            }
        }
        client.onEnvelope = { [weak self] envelope in
            guard let self else { return }
            Task { @MainActor [self, envelope] in
                self.receive(envelope)
            }
        }
    }

    var connectionLabel: String {
        switch connectionState {
        case .stopped:
            return "未启动"
        case .searching:
            return "正在寻找演示"
        case .connecting:
            return "正在连接"
        case .connected:
            return snapshot == nil ? "已连接 · 等待演示" : "已连接 · \(pageLabel)"
        case .failed(let message):
            return "连接失败 · \(message)"
        }
    }

    var pageLabel: String {
        guard let snapshot else { return "—" }
        return "\(snapshot.page + 1) / \(snapshot.pageCount)"
    }

    var calibrationLabel: String {
        if alignmentFrame != nil { return "空间已对齐" }
        if calibrationOrigin == nil { return "点按共享箭头的起点" }
        return "点按箭头朝向上的第二点"
    }

    func start() {
        guard !started else { return }
        started = true
        client.start()
    }

    func stop() {
        started = false
        client.stop()
    }

    func captureCalibrationPoint(_ point: SIMD3<Float>) {
        guard alignmentFrame == nil else { return }
        if calibrationOrigin == nil {
            calibrationOrigin = point
            calibrationForward = nil
            alignmentFrame = nil
            alignmentRevision += 1
        } else if let origin = calibrationOrigin,
                  let frame = SharedAlignmentFrame(origin: origin, forwardPoint: point) {
            calibrationForward = point
            alignmentFrame = frame
            alignmentRevision += 1
            sceneRevision += 1
        } else {
            calibrationOrigin = point
            calibrationForward = nil
            alignmentFrame = nil
            alignmentRevision += 1
            lastError = "两点距离至少需要 8 厘米"
        }
    }

    func resetCalibration() {
        calibrationOrigin = nil
        calibrationForward = nil
        alignmentFrame = nil
        alignmentRevision += 1
        sceneRevision += 1
    }

    func assetURL(for path: String) -> URL? {
        assetURLs[path]
    }

    func clearError() {
        lastError = nil
    }

    private func handleConnectionState(_ state: SpatialBridgeConnectionState) {
        connectionState = state
        if case .connected = state {
            send(.hello(BridgeHello(
                deviceName: UIDevice.current.name,
                experienceKind: .slides
            )))
            send(.requestSnapshot)
        } else {
            requestedAssets.removeAll()
        }
    }

    private func receive(_ envelope: SpatialBridgeEnvelope) {
        guard envelope.protocolVersion == SpatialBridgeEnvelope.currentProtocolVersion else {
            lastError = "协议版本不兼容"
            return
        }
        switch envelope.payload {
        case .manifest(let manifest):
            self.manifest = manifest
        case .slidesSnapshot(let snapshot):
            self.snapshot = snapshot
            sceneRevision += 1
            requestMissingAssets(for: snapshot)
        case .asset(let asset):
            store(asset)
        case .hello, .requestSnapshot, .requestAsset:
            break
        }
    }

    private func requestMissingAssets(for snapshot: BridgeSlidesSnapshot) {
        let paths = [snapshot.slideAssetPath].compactMap { $0 }
            + snapshot.elements.compactMap(\.assetPath)
        for path in Set(paths) where assetURLs[path] == nil && !requestedAssets.contains(path) {
            requestedAssets.insert(path)
            send(.requestAsset(path))
        }
    }

    private func store(_ asset: BridgeAssetData) {
        guard BridgeHash.sha256(asset.data) == asset.contentHash else {
            requestedAssets.remove(asset.path)
            lastError = "素材校验失败：\(asset.path)"
            return
        }
        do {
            let directory = try cacheDirectory()
            let safeName = BridgeHash.sha256(Data(asset.path.utf8))
            let ext = (asset.path as NSString).pathExtension
            let filename = ext.isEmpty ? safeName : "\(safeName).\(ext)"
            let url = directory.appendingPathComponent(filename)
            try asset.data.write(to: url, options: .atomic)
            assetURLs[asset.path] = url
            requestedAssets.remove(asset.path)
            sceneRevision += 1
        } catch {
            requestedAssets.remove(asset.path)
            lastError = error.localizedDescription
        }
    }

    private func cacheDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("SpatialCameraAssets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func send(_ payload: SpatialBridgePayload) {
        sequence += 1
        do {
            try client.send(SpatialBridgeEnvelope(sequence: sequence, payload: payload))
        } catch {
            lastError = error.localizedDescription
        }
    }
}
