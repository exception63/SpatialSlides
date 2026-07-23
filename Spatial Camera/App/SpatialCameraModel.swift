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
    private var assetAssemblies: [String: BridgeAssetAssembler] = [:]
    private var assetProgress: [String: Double] = [:]
    private var assetRequestQueue: [String] = []
    private var activeAssetRequests: Set<String> = []
    private var modelPrefetchPaths: [String] = []
    private let maxConcurrentAssetRequests = 2
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
        if alignmentFrame != nil,
           let origin = calibrationOrigin,
           let forward = calibrationForward {
            let centimeters = Int((simd_distance(origin, forward) * 100).rounded())
            return centimeters < 20
                ? "已对齐 · \(centimeters) cm · 精度一般"
                : "空间已对齐 · \(centimeters) cm"
        }
        if calibrationOrigin == nil { return "点按共享箭头的起点" }
        return "点按箭头朝向上的第二点"
    }

    var calibrationNeedsImprovement: Bool {
        guard let origin = calibrationOrigin,
              let forward = calibrationForward else { return false }
        return simd_distance(origin, forward) < 0.2
    }

    var assetStatusLabel: String? {
        guard let snapshot else { return nil }
        let paths = Set(
            [snapshot.slideAssetPath].compactMap { $0 }
                + snapshot.elements.compactMap(\.assetPath)
        )
        guard !paths.isEmpty else { return nil }
        let readyCount = paths.filter { assetURLs[$0] != nil }.count
        guard readyCount < paths.count else { return nil }
        if let progress = paths.compactMap({ assetProgress[$0] }).max() {
            return "正在加载空间素材 · \(Int(progress * 100))%"
        }
        return "正在准备空间素材 · \(readyCount)/\(paths.count)"
    }

    var availableModelAssetURLs: [URL] {
        modelPrefetchPaths.compactMap { assetURLs[$0] }
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

    func reportRenderIssue(_ message: String) {
        lastError = message
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
            assetAssemblies.removeAll()
            assetProgress.removeAll()
            assetRequestQueue.removeAll()
            activeAssetRequests.removeAll()
        }
    }

    private func receive(_ envelope: SpatialBridgeEnvelope) {
        guard envelope.protocolVersion == SpatialBridgeEnvelope.currentProtocolVersion else {
            lastError = "协议版本不兼容"
            return
        }
        switch envelope.payload {
        case .manifest(let manifest):
            if self.manifest?.showID != manifest.showID {
                assetURLs.removeAll()
                requestedAssets.removeAll()
                assetAssemblies.removeAll()
                assetProgress.removeAll()
                assetRequestQueue.removeAll()
                activeAssetRequests.removeAll()
            }
            self.manifest = manifest
            restoreCachedAssets(from: manifest)
            var prefetchBytes = 0
            modelPrefetchPaths = manifest.assets.reduce(into: [String]()) { paths, descriptor in
                guard paths.count < 6,
                      prefetchBytes + descriptor.byteCount <= 96 * 1_024 * 1_024,
                      (descriptor.path as NSString).pathExtension.lowercased() == "usdz"
                else { return }
                paths.append(descriptor.path)
                prefetchBytes += descriptor.byteCount
            }
            if let snapshot {
                requestMissingAssets(for: snapshot)
                enqueueAssets(modelPrefetchPaths, priority: false)
            }
        case .slidesSnapshot(let snapshot):
            if self.snapshot != snapshot {
                self.snapshot = snapshot
                sceneRevision += 1
            }
            requestMissingAssets(for: snapshot)
            enqueueAssets(modelPrefetchPaths, priority: false)
        case .deckTransform(let update):
            guard var snapshot = self.snapshot, snapshot.showID == update.showID else { break }
            if snapshot.deckTransform != update.transform {
                snapshot.deckTransform = update.transform
                self.snapshot = snapshot
                sceneRevision += 1
            }
        case .asset(let asset):
            store(asset)
        case .assetChunk(let chunk):
            accept(chunk)
        case .hello, .requestSnapshot, .requestAsset:
            break
        }
    }

    private func requestMissingAssets(for snapshot: BridgeSlidesSnapshot) {
        let modelPaths = snapshot.elements
            .filter { $0.kind == "model" }
            .compactMap(\.assetPath)
        let paths = modelPaths
            + [snapshot.slideAssetPath].compactMap { $0 }
            + snapshot.elements.filter { $0.kind != "model" }.compactMap(\.assetPath)
        enqueueAssets(paths, priority: true)
    }

    private func enqueueAssets(_ paths: [String], priority: Bool) {
        let uniquePaths = paths.reduce(into: [String]()) { result, path in
            if !result.contains(path) { result.append(path) }
        }
        let orderedPaths = priority ? Array(uniquePaths.reversed()) : uniquePaths
        for path in orderedPaths {
            guard assetURLs[path] == nil, !activeAssetRequests.contains(path) else { continue }
            if requestedAssets.contains(path) {
                if priority, let index = assetRequestQueue.firstIndex(of: path) {
                    assetRequestQueue.remove(at: index)
                    assetRequestQueue.insert(path, at: 0)
                }
                continue
            }
            requestedAssets.insert(path)
            assetProgress[path] = 0
            if priority {
                assetRequestQueue.insert(path, at: 0)
            } else {
                assetRequestQueue.append(path)
            }
        }
        startQueuedAssetRequests()
    }

    private func startQueuedAssetRequests() {
        while activeAssetRequests.count < maxConcurrentAssetRequests,
              !assetRequestQueue.isEmpty {
            let path = assetRequestQueue.removeFirst()
            guard assetURLs[path] == nil else {
                requestedAssets.remove(path)
                continue
            }
            activeAssetRequests.insert(path)
            send(.requestAsset(path))
        }
    }

    private func accept(_ chunk: BridgeAssetChunk) {
        do {
            var assembly: BridgeAssetAssembler
            if chunk.offset == 0 {
                assembly = try BridgeAssetAssembler(
                    path: chunk.path,
                    contentHash: chunk.contentHash,
                    totalByteCount: chunk.totalByteCount
                )
            } else if let existing = assetAssemblies[chunk.path] {
                assembly = existing
            } else {
                throw BridgeAssetAssemblyError.unexpectedOffset(
                    expected: 0,
                    received: chunk.offset
                )
            }

            let completedData = try assembly.append(chunk)
            assetProgress[chunk.path] = min(max(assembly.progress, 0), 1)
            if let completedData {
                assetAssemblies.removeValue(forKey: chunk.path)
                store(BridgeAssetData(
                    path: chunk.path,
                    contentHash: chunk.contentHash,
                    data: completedData
                ))
                return
            }
            assetAssemblies[chunk.path] = assembly
        } catch {
            failAsset(chunk.path, message: "\(error.localizedDescription)：\(chunk.path)")
        }
    }

    private func store(_ asset: BridgeAssetData) {
        guard BridgeHash.sha256(asset.data) == asset.contentHash else {
            requestedAssets.remove(asset.path)
            assetProgress.removeValue(forKey: asset.path)
            lastError = "素材校验失败：\(asset.path)"
            return
        }
        do {
            let directory = try cacheDirectory()
            let url = cachedAssetURL(
                path: asset.path,
                contentHash: asset.contentHash,
                directory: directory
            )
            try asset.data.write(to: url, options: .atomic)
            assetURLs[asset.path] = url
            requestedAssets.remove(asset.path)
            activeAssetRequests.remove(asset.path)
            assetRequestQueue.removeAll { $0 == asset.path }
            assetProgress.removeValue(forKey: asset.path)
            if currentSnapshotUsesAsset(asset.path) {
                sceneRevision += 1
            }
            startQueuedAssetRequests()
        } catch {
            requestedAssets.remove(asset.path)
            activeAssetRequests.remove(asset.path)
            assetProgress.removeValue(forKey: asset.path)
            lastError = error.localizedDescription
            startQueuedAssetRequests()
        }
    }

    private func restoreCachedAssets(from manifest: BridgeDeckManifest) {
        guard let directory = try? cacheDirectory() else { return }
        var restoredCurrentAsset = false
        for descriptor in manifest.assets {
            let url = cachedAssetURL(
                path: descriptor.path,
                contentHash: descriptor.contentHash,
                directory: directory
            )
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  values.fileSize == descriptor.byteCount else { continue }
            assetURLs[descriptor.path] = url
            requestedAssets.remove(descriptor.path)
            activeAssetRequests.remove(descriptor.path)
            assetRequestQueue.removeAll { $0 == descriptor.path }
            assetProgress.removeValue(forKey: descriptor.path)
            restoredCurrentAsset = restoredCurrentAsset || currentSnapshotUsesAsset(descriptor.path)
        }
        if restoredCurrentAsset { sceneRevision += 1 }
        startQueuedAssetRequests()
    }

    private func cachedAssetURL(path: String, contentHash: String, directory: URL) -> URL {
        let ext = (path as NSString).pathExtension
        let filename = ext.isEmpty ? contentHash : "\(contentHash).\(ext)"
        return directory.appendingPathComponent(filename)
    }

    private func failAsset(_ path: String, message: String) {
        assetAssemblies.removeValue(forKey: path)
        assetProgress.removeValue(forKey: path)
        requestedAssets.remove(path)
        activeAssetRequests.remove(path)
        assetRequestQueue.removeAll { $0 == path }
        lastError = message
        startQueuedAssetRequests()
    }

    private func currentSnapshotUsesAsset(_ path: String) -> Bool {
        guard let snapshot else { return false }
        return snapshot.slideAssetPath == path
            || snapshot.elements.contains(where: { $0.assetPath == path })
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
