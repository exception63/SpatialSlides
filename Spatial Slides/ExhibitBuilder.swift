//
//  ExhibitBuilder.swift
//  Spatial Slides
//
//  Builds the genuinely 3D primitives (bar chart, model). Text/stat/image
//  are handled as SwiftUI glass panels (see ExhibitElementView); this file
//  only produces RealityKit entities.
//

import RealityKit
import UIKit
import SwiftUI

enum ExhibitBuilder {

    static func build(_ element: ExhibitElement) -> Entity {
        switch element.kind {
        case .barChart:
            return BarChart3D.make(bars: element.bars ?? [])
        case .scatter:
            return Scatter3D.make(points: element.points ?? [])
        case .model:
            return buildModel(element)
        default:
            return Entity()   // text-ish + image → SwiftUI glass attachments
        }
    }

    // MARK: - Model (placeholder now, real USDZ when it loads)

    private static func buildModel(_ element: ExhibitElement) -> Entity {
        let node = Entity()
        let placeholder = placeholderModel()
        node.addChild(placeholder)

        let scale = element.modelScale
        // Prefer a package asset (a .usdz beside show.json); fall back to a bundled
        // model by name. Placeholder shows until (and unless) the real model loads.
        Task { @MainActor in
            var loaded: Entity?
            if let asset = element.asset, let url = DeckLoader.assetURL(asset) {
                loaded = try? await Entity(contentsOf: url)
            }
            if loaded == nil, let name = element.modelName {
                loaded = try? await Entity(named: name)
            }
            guard let model = loaded else { return }
            model.scale = [scale, scale, scale]
            placeholder.removeFromParent()
            node.addChild(model)

            // Size a grab region to the visible model and enable FULL native
            // manipulation — move, one/two-hand rotate, and two-hand pinch-scale —
            // exactly like the charts (which resize fine on device). Two-handed scale
            // only STARTS when the SECOND hand's pinch also lands on this collider:
            // the charts' box is ~40 cm so both hands land easily, but the bear's
            // tight ~18 cm box was too small for the second hand → scaling never
            // engaged (even though one-hand grab/move worked). Floor the box at 40 cm
            // to match the charts' grabbability. We do NOT disable built-in scaling.
            let bounds = node.visualBounds(relativeTo: node)
            let e = bounds.extents
            let shape = ShapeResource.generateBox(size: [max(e.x * 1.4, 0.4),
                                                          max(e.y * 1.4, 0.4),
                                                          max(e.z * 1.4, 0.4)])
                .offsetBy(translation: bounds.center)
            node.components.set(InputTargetComponent())
            node.components.set(HoverEffectComponent())
            node.components.set(CollisionComponent(shapes: [shape]))
            ManipulationComponent.configureEntity(node, collisionShapes: [shape])
            if var manip = node.components[ManipulationComponent.self] {
                manip.releaseBehavior = .stay
                node.components.set(manip)
            }
        }
        return node
    }

    /// A bright, tilted rounded cube — reads as a solid 3D object from a
    /// single viewpoint (unlike a sphere), and stays visible regardless of
    /// scene lighting thanks to strong emission.
    static func placeholderModel() -> Entity {
        var material = PhysicallyBasedMaterial()
        let color = UIColor(hex: "#5AC8FA")
        material.baseColor = .init(tint: color)
        material.roughness = 0.25
        material.metallic = 0.6
        material.emissiveColor = .init(color: color)
        material.emissiveIntensity = 0.7

        let cube = ModelEntity(
            mesh: .generateBox(size: 0.4, cornerRadius: 0.04),
            materials: [material]
        )
        cube.orientation = simd_quatf(angle: .pi / 6, axis: [1, 0, 0])
            * simd_quatf(angle: .pi / 5, axis: [0, 1, 0])
        return cube
    }
}
