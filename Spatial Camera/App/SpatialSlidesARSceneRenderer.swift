import Combine
import RealityKit
import SpatialBridgeKit
import UIKit

@MainActor
final class SpatialSlidesARSceneRenderer {
    private let worldAnchor = AnchorEntity(world: .zero)
    private let sharedRoot = Entity()
    private let contentRoot = Entity()
    private let alignmentRoot = Entity()
    private var renderedSceneRevision = -1
    private var renderedAlignmentRevision = -1
    private var renderedFixtureVisibility = true
    private var deckEntity: ModelEntity?
    private var deckAssetPath: String?
    private var deckAssetURL: URL?
    private var deckLoadToken = UUID()
    private var elementEntities: [String: Entity] = [:]
    private var elementSnapshots: [String: BridgeElementSnapshot] = [:]
    private var elementAssetURLs: [String: URL] = [:]
    private var elementLoadTokens: [String: UUID] = [:]
    private var modelTemplates: [URL: Entity] = [:]
    private var modelLoadTasks: [URL: Task<Entity, Error>] = [:]
    private var loopStates: [String: LoopState] = [:]
    private var updateSubscription: (any Cancellable)?

    private struct LoopState {
        let effect: String
        let omega: Double
        let amplitude: Float
        var phase: Double = 0
    }

    func attach(to arView: ARView) {
        guard worldAnchor.parent == nil else { return }
        worldAnchor.addChild(sharedRoot)
        sharedRoot.addChild(contentRoot)
        worldAnchor.addChild(alignmentRoot)
        arView.scene.addAnchor(worldAnchor)
        updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.tickLoops(deltaTime: event.deltaTime)
        }
    }

    func update(
        snapshot: BridgeSlidesSnapshot?,
        alignmentFrame: SharedAlignmentFrame?,
        calibrationOrigin: SIMD3<Float>?,
        showAlignmentFixture: Bool,
        assetURL: (String) -> URL?,
        modelAssetURLs: [URL],
        reportRenderIssue: @escaping (String) -> Void,
        sceneRevision: Int,
        alignmentRevision: Int
    ) {
        if renderedAlignmentRevision != alignmentRevision
            || renderedFixtureVisibility != showAlignmentFixture {
            renderedAlignmentRevision = alignmentRevision
            renderedFixtureVisibility = showAlignmentFixture
            if let alignmentFrame {
                sharedRoot.transform.matrix = alignmentFrame.worldFromShared
                sharedRoot.isEnabled = true
                alignmentRoot.transform.matrix = alignmentFrame.worldFromShared
                installAlignmentFixture()
                alignmentRoot.isEnabled = showAlignmentFixture
            } else {
                sharedRoot.isEnabled = false
                if let calibrationOrigin {
                    alignmentRoot.position = calibrationOrigin
                    installAlignmentOrigin()
                    alignmentRoot.isEnabled = showAlignmentFixture
                } else {
                    alignmentRoot.isEnabled = false
                }
            }
        }

        prewarmModels(at: modelAssetURLs)
        guard renderedSceneRevision != sceneRevision else { return }
        renderedSceneRevision = sceneRevision
        guard let snapshot else {
            clearContent()
            return
        }
        reconcileDeck(snapshot: snapshot, assetURL: assetURL)
        reconcileElements(
            snapshot.elements,
            assetURL: assetURL,
            reportRenderIssue: reportRenderIssue
        )
    }

    private func reconcileDeck(
        snapshot: BridgeSlidesSnapshot,
        assetURL: (String) -> URL?
    ) {
        guard let path = snapshot.slideAssetPath else {
            deckLoadToken = UUID()
            deckEntity?.removeFromParent()
            deckEntity = nil
            deckAssetPath = nil
            deckAssetURL = nil
            return
        }

        let deck: ModelEntity
        if let existing = deckEntity {
            deck = existing
        } else {
            deck = ModelEntity(
                mesh: .generatePlane(width: 2.6, height: 1.4625, cornerRadius: 0.02),
                materials: [UnlitMaterial(color: .black)]
            )
            contentRoot.addChild(deck)
            deckEntity = deck
        }
        deck.transform.matrix = snapshot.deckTransform.matrix

        let url = assetURL(path)
        guard deckAssetPath != path || deckAssetURL != url else { return }
        deckAssetPath = path
        deckAssetURL = url
        deck.model?.materials = [UnlitMaterial(color: .black)]
        deckLoadToken = UUID()
        let token = deckLoadToken
        guard let url else { return }
        Task { @MainActor [weak deck] in
            guard let texture = try? await TextureResource(contentsOf: url),
                  token == self.deckLoadToken,
                  let deck else { return }
            var material = UnlitMaterial()
            material.color = .init(tint: .white, texture: .init(texture))
            deck.model?.materials = [material]
        }
    }

    private func reconcileElements(
        _ elements: [BridgeElementSnapshot],
        assetURL: (String) -> URL?,
        reportRenderIssue: @escaping (String) -> Void
    ) {
        let visibleElements = elements.filter(\.visible)
        let visibleIDs = Set(visibleElements.map(\.id))
        for id in Array(elementEntities.keys) where !visibleIDs.contains(id) {
            removeElement(id)
        }

        for element in visibleElements {
            let url = element.assetPath.flatMap(assetURL)
            let existingURL = elementAssetURLs[element.id]
            let shouldRebuild: Bool
            if let previous = elementSnapshots[element.id] {
                var definition = previous
                definition.transform = element.transform
                shouldRebuild = definition != element || existingURL != url
            } else {
                shouldRebuild = true
            }

            let entity: Entity
            if shouldRebuild {
                removeElement(element.id)
                entity = makeElement(
                    element,
                    resolvedAssetURL: url,
                    reportRenderIssue: reportRenderIssue
                )
                contentRoot.addChild(entity)
                elementEntities[element.id] = entity
                if let url { elementAssetURLs[element.id] = url }
                configureLoop(for: element)
            } else if let existing = elementEntities[element.id] {
                entity = existing
            } else {
                continue
            }

            elementSnapshots[element.id] = element
            entity.transform.matrix = element.transform.matrix
            applyCurrentLoopPose(to: entity, id: element.id)
        }
    }

    private func clearContent() {
        deckLoadToken = UUID()
        deckEntity?.removeFromParent()
        deckEntity = nil
        deckAssetPath = nil
        deckAssetURL = nil
        for id in Array(elementEntities.keys) {
            removeElement(id)
        }
    }

    private func removeElement(_ id: String) {
        elementLoadTokens[id] = UUID()
        elementEntities.removeValue(forKey: id)?.removeFromParent()
        elementSnapshots.removeValue(forKey: id)
        elementAssetURLs.removeValue(forKey: id)
        loopStates.removeValue(forKey: id)
    }

    private func installAlignmentFixture() {
        alignmentRoot.children.removeAll()

        var cyan = UnlitMaterial(color: UIColor(red: 0.1, green: 0.82, blue: 0.95, alpha: 1))
        cyan.faceCulling = .none
        let origin = ModelEntity(mesh: .generateSphere(radius: 0.035), materials: [cyan])
        alignmentRoot.addChild(origin)

        let shaft = ModelEntity(
            mesh: .generateBox(size: [0.025, 0.025, 0.28], cornerRadius: 0.01),
            materials: [cyan]
        )
        shaft.position.z = 0.14
        alignmentRoot.addChild(shaft)

        let head = ModelEntity(mesh: .generateCone(height: 0.11, radius: 0.065), materials: [cyan])
        head.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        head.position.z = 0.33
        alignmentRoot.addChild(head)
    }

    private func installAlignmentOrigin() {
        alignmentRoot.children.removeAll()
        let material = UnlitMaterial(color: UIColor(red: 0.1, green: 0.82, blue: 0.95, alpha: 1))
        let origin = ModelEntity(mesh: .generateSphere(radius: 0.035), materials: [material])
        alignmentRoot.addChild(origin)
    }

    private func makeElement(
        _ element: BridgeElementSnapshot,
        resolvedAssetURL: URL?,
        reportRenderIssue: @escaping (String) -> Void
    ) -> Entity {
        switch element.kind {
        case "model":
            let root = Entity()
            root.addChild(Self.placeholder())
            if let path = element.assetPath, let url = resolvedAssetURL {
                let token = UUID()
                elementLoadTokens[element.id] = token
                Task { @MainActor [weak root] in
                    do {
                        let loaded = try await self.cachedModelInstance(contentsOf: url)
                        guard self.elementLoadTokens[element.id] == token,
                              let root,
                              root.parent != nil else { return }
                        let scale = element.modelScale ?? 1
                        loaded.scale = [scale, scale, scale]
                        root.children.removeAll()
                        root.addChild(loaded)
                        await Task.yield()
                        let bounds = loaded.visualBounds(relativeTo: root)
                        loaded.position -= bounds.center
                        for animation in loaded.availableAnimations {
                            loaded.playAnimation(animation.repeat())
                        }
                    } catch {
                        guard self.elementLoadTokens[element.id] == token else { return }
                        reportRenderIssue("USDZ 加载失败：\(path)\n\(error.localizedDescription)")
                    }
                }
            }
            return root
        case "barChart":
            return makeBarChart(element.bars ?? [])
        case "scatter":
            return makeScatter(element.points ?? [])
        default:
            return makePanel(element)
        }
    }

    private func cachedModelInstance(contentsOf url: URL) async throws -> Entity {
        if let template = modelTemplates[url] {
            return template.clone(recursive: true)
        }
        if let task = modelLoadTasks[url] {
            let template = try await task.value
            return template.clone(recursive: true)
        }

        let task = Task { @MainActor in
            try await Entity(contentsOf: url)
        }
        modelLoadTasks[url] = task
        do {
            let template = try await task.value
            modelLoadTasks.removeValue(forKey: url)
            modelTemplates[url] = template
            return template.clone(recursive: true)
        } catch {
            modelLoadTasks.removeValue(forKey: url)
            throw error
        }
    }

    private func prewarmModels(at urls: [URL]) {
        for url in urls where modelTemplates[url] == nil && modelLoadTasks[url] == nil {
            Task { @MainActor in
                _ = try? await cachedModelInstance(contentsOf: url)
            }
        }
    }

    private func configureLoop(for element: BridgeElementSnapshot) {
        guard let effect = element.loopEffect, effect != "none" else {
            loopStates.removeValue(forKey: element.id)
            return
        }
        let period = max(element.loopPeriod ?? 6, 0.4)
        loopStates[element.id] = LoopState(
            effect: effect,
            omega: 2 * .pi / period,
            amplitude: Float(max(element.loopAmplitude ?? 1, 0))
        )
    }

    private func applyCurrentLoopPose(to entity: Entity, id: String) {
        guard let loop = loopStates[id] else { return }
        let wave = Float(sin(loop.omega * loop.phase))
        switch loop.effect {
        case "spin":
            entity.orientation = simd_quatf(
                angle: Float(loop.omega * loop.phase),
                axis: [0, 1, 0]
            ) * entity.orientation
        case "float":
            entity.position.y += (loop.amplitude <= 0 ? 1 : loop.amplitude) * 0.03 * wave
        case "breathe":
            entity.scale *= 1 + (loop.amplitude <= 0 ? 1 : loop.amplitude) * 0.04 * wave
        default:
            break
        }
    }

    private func tickLoops(deltaTime: TimeInterval) {
        guard deltaTime > 0 else { return }
        for id in Array(loopStates.keys) {
            guard var loop = loopStates[id],
                  let entity = elementEntities[id],
                  entity.isEnabled else { continue }
            let previousPhase = loop.phase
            loop.phase += deltaTime
            loopStates[id] = loop

            let previousWave = Float(sin(loop.omega * previousPhase))
            let currentWave = Float(sin(loop.omega * loop.phase))
            let amplitude = loop.amplitude <= 0 ? 1 : loop.amplitude
            switch loop.effect {
            case "spin":
                entity.orientation = simd_quatf(
                    angle: Float(loop.omega * deltaTime),
                    axis: [0, 1, 0]
                ) * entity.orientation
            case "float":
                entity.position.y += amplitude * 0.03 * (currentWave - previousWave)
            case "breathe":
                let previousScale = 1 + amplitude * 0.04 * previousWave
                let currentScale = 1 + amplitude * 0.04 * currentWave
                entity.scale *= currentScale / previousScale
            default:
                break
            }
        }
    }

    private func makePanel(_ element: BridgeElementSnapshot) -> Entity {
        let size = element.size?.simd ?? SIMD2<Float>(0.72, 0.42)
        let width = max(size.x, 0.35)
        let height = max(size.y, 0.2)
        let panel = ModelEntity(
            mesh: .generatePlane(width: width, height: height, cornerRadius: 0.025),
            materials: [UnlitMaterial(color: UIColor(white: 0.08, alpha: 0.92))]
        )

        let text = [
            element.text,
            element.value,
            element.caption,
            element.bullets?.joined(separator: "\n")
        ].compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty,
              let image = Self.textImage(text: text, aspect: CGFloat(width / height)),
              let texture = try? TextureResource(image: image, options: .init(semantic: .color))
        else { return panel }

        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        panel.model?.materials = [material]
        return panel
    }

    private func makeBarChart(_ values: [BridgeBarValue]) -> Entity {
        let root = Entity()
        let maxValue = max(values.map(\.value).max() ?? 1, 0.001)
        for (index, value) in values.prefix(12).enumerated() {
            let height = Float(value.value / maxValue) * 0.45 + 0.02
            let bar = ModelEntity(
                mesh: .generateBox(size: [0.055, height, 0.055], cornerRadius: 0.008),
                materials: [SimpleMaterial(color: Self.color(value.colorHex), isMetallic: false)]
            )
            bar.position = [Float(index) * 0.075, height / 2, 0]
            root.addChild(bar)
        }
        return root
    }

    private func makeScatter(_ points: [BridgeScatterPoint]) -> Entity {
        let root = Entity()
        for point in points.prefix(60) {
            let dot = ModelEntity(
                mesh: .generateSphere(radius: 0.018),
                materials: [SimpleMaterial(color: Self.color(point.colorHex), isMetallic: false)]
            )
            dot.position = [Float(point.x) * 0.12, Float(point.y) * 0.12, Float(point.z) * 0.12]
            root.addChild(dot)
        }
        return root
    }

    private static func placeholder() -> ModelEntity {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(red: 0.12, green: 0.78, blue: 0.92, alpha: 1))
        material.roughness = 0.25
        material.metallic = 0.55
        return ModelEntity(
            mesh: .generateBox(size: 0.28, cornerRadius: 0.035),
            materials: [material]
        )
    }

    private static func textImage(text: String, aspect: CGFloat) -> CGImage? {
        let width: CGFloat = 1_024
        let height = width / max(aspect, 0.75)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { context in
            UIColor(white: 0.06, alpha: 0.94).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: min(72, height * 0.12), weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            let rect = CGRect(x: 64, y: 48, width: width - 128, height: height - 96)
            (text as NSString).draw(in: rect, withAttributes: attributes)
        }.cgImage
    }

    private static func color(_ hex: String?) -> UIColor {
        guard let hex else { return .systemCyan }
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return .systemCyan }
        return UIColor(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}
