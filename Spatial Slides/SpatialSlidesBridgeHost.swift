import Foundation
import Observation
import SpatialBridgeKit
import simd

@MainActor
@Observable
final class SpatialSlidesBridgeHost: @unchecked Sendable {
    static let sharedOriginInStage = SIMD3<Float>(0, 0.85, -0.9)

    private(set) var connectionState: SpatialBridgeConnectionState = .stopped
    private(set) var lastError: String?

    private let server = LocalSpatialBridgeServer()
    private var sequence: UInt64 = 0
    private var started = false
    private var latestSnapshot: BridgeSlidesSnapshot?
    private var latestManifest: BridgeDeckManifest?
    private var latestManifestVersion: Int?
    private var assetTransferIDs: [String: UUID] = [:]
    private var runtimeDeckTransformInStage: simd_float4x4?
    private var lastSentDeckTransformInStage: simd_float4x4?
    private var lastDeckTransformSentAt: TimeInterval = 0
    private let deckTransformSendInterval: TimeInterval = 1.0 / 20.0
    private var stageFromShared = simd_float4x4(
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(sharedOriginInStage, 1)
    )

    init() {
        server.onStateChange = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [self, state] in
                self.connectionState = state
            }
        }
        server.onEnvelope = { [weak self] envelope in
            guard let self else { return }
            Task { @MainActor [self, envelope] in
                self.receive(envelope)
            }
        }
    }

    var hasViewer: Bool {
        if case .connected(let peerCount) = connectionState {
            return peerCount > 0
        }
        return false
    }

    var statusLabel: String {
        switch connectionState {
        case .stopped:
            return "第三视角未启动"
        case .searching:
            return "等待 Spatial Camera"
        case .connecting:
            return "正在连接 Spatial Camera"
        case .connected(let peerCount):
            return "Spatial Camera 已连接 · \(peerCount) · 可抓住青色箭头标定"
        case .failed(let message):
            return "第三视角连接失败 · \(message)"
        }
    }

    func start() {
        guard !started else { return }
        started = true
        do {
            try server.start(serviceName: "Spatial Slides")
        } catch {
            lastError = error.localizedDescription
            connectionState = .failed(error.localizedDescription)
        }
    }

    func stop() {
        started = false
        server.stop()
    }

    func publish(_ presentation: PresentationModel) {
        guard presentation.hasContent else { return }
        let snapshot = makeSnapshot(presentation)
        latestSnapshot = snapshot
        send(.slidesSnapshot(snapshot))

        if latestManifestVersion != presentation.version {
            let manifest = makeManifest(presentation)
            latestManifestVersion = presentation.version
            latestManifest = manifest
            send(.manifest(manifest))
        }
    }

    func updateSharedFrame(stageFromShared: simd_float4x4) {
        self.stageFromShared = stageFromShared
    }

    func updateDeckTransform(
        _ stageTransform: simd_float4x4,
        presentation: PresentationModel,
        force: Bool = false
    ) {
        guard presentation.hasContent else { return }
        runtimeDeckTransformInStage = stageTransform

        let update = BridgeDeckTransformUpdate(
            showID: showID(presentation.show),
            transform: BridgeTransform(matrix: simd_inverse(stageFromShared) * stageTransform)
        )
        if var snapshot = latestSnapshot, snapshot.showID == update.showID {
            snapshot.deckTransform = update.transform
            latestSnapshot = snapshot
        }

        let changed = lastSentDeckTransformInStage.map {
            !matricesApproximatelyEqual($0, stageTransform)
        } ?? true
        guard hasViewer, changed else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastDeckTransformSentAt >= deckTransformSendInterval else { return }
        lastSentDeckTransformInStage = stageTransform
        lastDeckTransformSentAt = now
        send(.deckTransform(update))
    }

    private func receive(_ envelope: SpatialBridgeEnvelope) {
        guard envelope.protocolVersion == SpatialBridgeEnvelope.currentProtocolVersion else { return }
        switch envelope.payload {
        case .hello:
            if let latestManifest { send(.manifest(latestManifest)) }
            if let latestSnapshot { send(.slidesSnapshot(latestSnapshot)) }
        case .requestSnapshot:
            if let latestManifest { send(.manifest(latestManifest)) }
            if let latestSnapshot { send(.slidesSnapshot(latestSnapshot)) }
        case .requestAsset(let path):
            sendAsset(path)
        case .manifest, .slidesSnapshot, .deckTransform, .asset, .assetChunk:
            break
        }
    }

    private func makeSnapshot(_ presentation: PresentationModel) -> BridgeSlidesSnapshot {
        let sharedFromStage = simd_inverse(stageFromShared)
        let deckMatrix = sharedFromStage
            * (runtimeDeckTransformInStage ?? translationMatrix([0, 1.62, -3.0]))
        let elements = presentation.currentElements.map { element -> BridgeElementSnapshot in
            let authored = element.transform ?? ElementTransform(position: [0, 1.2, -0.5])
            let localMatrix = transformMatrix(authored)
            let beat = element.animation?.buildIn?.order ?? 0
            return BridgeElementSnapshot(
                id: element.id,
                kind: element.kind.rawValue,
                transform: BridgeTransform(matrix: sharedFromStage * localMatrix),
                size: element.size.map(BridgeVector2.init),
                visible: beat <= presentation.currentBeat,
                background: element.background,
                text: element.text,
                subtitle: element.subtitle,
                bullets: element.bullets,
                value: element.value,
                caption: element.caption,
                assetPath: element.asset,
                modelScale: element.kind == .model ? element.modelScale : nil,
                bars: element.bars?.map {
                    BridgeBarValue(label: $0.label, value: $0.value, colorHex: $0.colorHex)
                },
                points: element.points?.map {
                    BridgeScatterPoint(
                        x: $0.x,
                        y: $0.y,
                        z: $0.z,
                        label: $0.label,
                        colorHex: $0.colorHex
                    )
                },
                loopEffect: element.animation?.loop?.effect.rawValue,
                loopPeriod: element.animation?.loop?.period,
                loopAmplitude: element.animation?.loop?.amplitude
            )
        }

        return BridgeSlidesSnapshot(
            showID: showID(presentation.show),
            title: presentation.show.title,
            page: presentation.currentPage,
            pageCount: presentation.pageCount,
            beat: presentation.currentBeat,
            maxBeat: presentation.currentMaxBeat,
            motionMode: presentation.motionMode,
            slideAssetPath: presentation.currentSlideImage,
            deckTransform: BridgeTransform(matrix: deckMatrix),
            elements: elements
        )
    }

    private func makeManifest(_ presentation: PresentationModel) -> BridgeDeckManifest {
        var paths = Set<String>()
        for page in presentation.show.pages {
            if let slide = page.slide { paths.insert(slide) }
            paths.formUnion(page.elements.compactMap(\.asset))
        }
        let assets = paths.sorted().compactMap { path -> BridgeAssetDescriptor? in
            guard let url = DeckLoader.assetURL(path),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return BridgeAssetDescriptor(
                path: path,
                byteCount: data.count,
                contentHash: BridgeHash.sha256(data)
            )
        }
        return BridgeDeckManifest(
            showID: showID(presentation.show),
            title: presentation.show.title,
            pageCount: presentation.pageCount,
            assets: assets
        )
    }

    private func sendAsset(_ path: String) {
        guard !path.hasPrefix("/"),
              !path.split(separator: "/").contains(".."),
              let url = DeckLoader.assetURL(path)
        else { return }

        let server = server
        let transferID = UUID()
        assetTransferIDs[path] = transferID
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let contentHash = BridgeHash.sha256(data)
                let chunkSize = 192 * 1_024
                var offset = 0

                while offset < data.count {
                    guard await self?.isCurrentTransfer(transferID, for: path) == true else { return }
                    let end = min(offset + chunkSize, data.count)
                    let chunk = BridgeAssetChunk(
                        path: path,
                        contentHash: contentHash,
                        totalByteCount: data.count,
                        offset: offset,
                        data: Data(data[offset..<end])
                    )
                    guard let envelope = await self?.makeEnvelope(.assetChunk(chunk)) else { return }
                    try await server.sendAsync(envelope)
                    offset = end
                }
                await self?.finishTransfer(transferID, for: path)
            } catch {
                await self?.finishTransfer(transferID, for: path)
                await self?.record(error)
            }
        }
    }

    private func send(_ payload: SpatialBridgePayload) {
        do {
            try server.send(makeEnvelope(payload))
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func makeEnvelope(_ payload: SpatialBridgePayload) -> SpatialBridgeEnvelope {
        sequence += 1
        return SpatialBridgeEnvelope(sequence: sequence, payload: payload)
    }

    private func record(_ error: Error) {
        lastError = error.localizedDescription
    }

    private func isCurrentTransfer(_ transferID: UUID, for path: String) -> Bool {
        assetTransferIDs[path] == transferID
    }

    private func finishTransfer(_ transferID: UUID, for path: String) {
        if assetTransferIDs[path] == transferID {
            assetTransferIDs.removeValue(forKey: path)
        }
    }

    private func showID(_ show: Show) -> String {
        let identity = "\(show.title)|\(show.html)|\(show.pageCount)"
        return String(BridgeHash.sha256(Data(identity.utf8)).prefix(20))
    }

    private func translationMatrix(_ translation: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(translation, 1)
        )
    }

    private func transformMatrix(_ transform: ElementTransform) -> simd_float4x4 {
        var matrix = simd_float4x4(transform.orientation)
        matrix.columns.0 *= transform.scale
        matrix.columns.1 *= transform.scale
        matrix.columns.2 *= transform.scale
        matrix.columns.3 = [transform.position.x, transform.position.y, transform.position.z, 1]
        return matrix
    }

    private func matricesApproximatelyEqual(
        _ lhs: simd_float4x4,
        _ rhs: simd_float4x4,
        tolerance: Float = 0.0005
    ) -> Bool {
        for column in 0..<4 {
            for row in 0..<4 where abs(lhs[column][row] - rhs[column][row]) > tolerance {
                return false
            }
        }
        return true
    }
}
