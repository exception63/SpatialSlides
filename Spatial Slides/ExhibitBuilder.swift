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

            // Two-handed pinch-scale only ENGAGES when BOTH hands' pinches land on the
            // collider of the entity that owns the ManipulationComponent. A loaded USDZ
            // is a whole SUBTREE — if any descendant keeps its own collision, the
            // wrapper's InputTargetComponent propagates down and the SECOND hand can
            // resolve to a CHILD instead of `node`, so the two-hand pair never forms
            // (single-hand move still works — exactly the bug). Strip the subtree so
            // `node` is the ONLY hittable entity — structurally identical to the charts
            // (a single entity with a passive mesh child), which scale fine on device.
            Self.stripInteraction(model)
            placeholder.removeFromParent()
            node.addChild(model)
            await Task.yield()   // let the freshly-loaded mesh's bounds settle

            // Re-center the model on node's origin, then use a CENTERED (un-offset)
            // collider: an offset box can sit slightly off the visible mesh so the
            // second hand misses it. Floor at 40 cm (the charts' grabbability).
            let b = model.visualBounds(relativeTo: node)
            model.position -= b.center
            let e = b.extents
            let shape = ShapeResource.generateBox(size: [max(e.x * 1.2, 0.4),
                                                          max(e.y * 1.2, 0.4),
                                                          max(e.z * 1.2, 0.4)])
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

    /// Recursively removes collision + input from a loaded model's subtree so only the
    /// wrapper node is a hit target — required for two-handed manipulation to pair the
    /// second hand to the same (manipulable) entity as the first.
    private static func stripInteraction(_ e: Entity) {
        e.components.remove(CollisionComponent.self)
        e.components.remove(InputTargetComponent.self)
        for child in e.children { stripInteraction(child) }
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
