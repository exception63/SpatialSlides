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
    private var renderGeneration = 0

    func attach(to arView: ARView) {
        guard worldAnchor.parent == nil else { return }
        worldAnchor.addChild(sharedRoot)
        sharedRoot.addChild(contentRoot)
        worldAnchor.addChild(alignmentRoot)
        arView.scene.addAnchor(worldAnchor)
    }

    func update(
        snapshot: BridgeSlidesSnapshot?,
        alignmentFrame: SharedAlignmentFrame?,
        calibrationOrigin: SIMD3<Float>?,
        showAlignmentFixture: Bool,
        assetURL: (String) -> URL?,
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

        guard renderedSceneRevision != sceneRevision else { return }
        renderedSceneRevision = sceneRevision
        renderGeneration += 1
        let generation = renderGeneration
        contentRoot.children.removeAll()
        guard let snapshot else { return }

        if let path = snapshot.slideAssetPath, let url = assetURL(path) {
            let deck = ModelEntity(
                mesh: .generatePlane(width: 2.6, height: 1.4625, cornerRadius: 0.02),
                materials: [UnlitMaterial(color: .black)]
            )
            deck.transform.matrix = snapshot.deckTransform.matrix
            contentRoot.addChild(deck)
            Task { @MainActor [weak deck] in
                guard let texture = try? await TextureResource(contentsOf: url),
                      generation == self.renderGeneration,
                      let deck else { return }
                var material = UnlitMaterial()
                material.color = .init(tint: .white, texture: .init(texture))
                deck.model?.materials = [material]
            }
        }

        for element in snapshot.elements where element.visible {
            let entity = makeElement(element, assetURL: assetURL, generation: generation)
            entity.transform.matrix = element.transform.matrix
            contentRoot.addChild(entity)
        }
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
        assetURL: (String) -> URL?,
        generation: Int
    ) -> Entity {
        switch element.kind {
        case "model":
            let root = Entity()
            root.addChild(Self.placeholder())
            if let path = element.assetPath, let url = assetURL(path) {
                Task { @MainActor [weak root] in
                    guard let loaded = try? await Entity(contentsOf: url),
                          generation == self.renderGeneration,
                          let root else { return }
                    root.children.removeAll()
                    root.addChild(loaded)
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
