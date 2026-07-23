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

@MainActor
enum ExhibitBuilder {
    typealias ModelReadyHandler = @MainActor (_ node: Entity, _ shape: ShapeResource, _ halfExtent: SIMD2<Float>) -> Void
    private static var modelTemplates: [URL: Entity] = [:]
    private static var modelLoadTasks: [URL: Task<Entity, Error>] = [:]

    static func build(_ element: ExhibitElement, onModelReady: ModelReadyHandler? = nil) -> Entity {
        switch element.kind {
        case .barChart:
            return BarChart3D.make(bars: element.bars ?? [])
        case .scatter:
            return Scatter3D.make(points: element.points ?? [])
        case .model:
            return buildModel(element, onModelReady: onModelReady)
        default:
            return Entity()   // text-ish + image → SwiftUI glass attachments
        }
    }

    // MARK: - Model (placeholder now, real USDZ when it loads)

    private static func buildModel(_ element: ExhibitElement, onModelReady: ModelReadyHandler?) -> Entity {
        let node = Entity()
        let placeholder = placeholderModel()
        node.addChild(placeholder)

        let scale = element.modelScale
        // Prefer a package asset (a .usdz beside show.json); fall back to a bundled
        // model by name. Placeholder shows until (and unless) the real model loads.
        Task { @MainActor in
            var loaded: Entity?
            if let asset = element.asset, let url = DeckLoader.assetURL(asset) {
                loaded = try? await cachedModelInstance(contentsOf: url)
            }
            if loaded == nil, let name = element.modelName {
                loaded = try? await Entity(named: name)
            }
            guard let model = loaded, node.parent != nil else { return }
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
            for animation in model.availableAnimations {
                model.playAnimation(animation.repeat())
            }
            await Task.yield()   // let the freshly-loaded mesh's bounds settle

            // Re-center the model on node's origin, then use a CENTERED (un-offset)
            // collider: an offset box can sit slightly off the visible mesh so the
            // second hand misses it. Floor at 40 cm (the charts' grabbability).
            let b = model.visualBounds(relativeTo: node)
            model.position -= b.center
            let e = b.extents
            let hitSize = SIMD3<Float>(max(e.x * 1.2, 0.4),
                                       max(e.y * 1.2, 0.4),
                                       max(e.z * 1.2, 0.4))
            let shape = ShapeResource.generateBox(size: hitSize)
            onModelReady?(node, shape, [hitSize.x / 2, hitSize.y / 2])
        }
        return node
    }

    static func prewarmModels(in show: Show) {
        let paths = Set(
            show.pages
                .flatMap(\.elements)
                .filter { $0.kind == .model }
                .compactMap(\.asset)
        )
        for path in paths.sorted().prefix(6) {
            guard let url = DeckLoader.assetURL(path),
                  modelTemplates[url] == nil,
                  modelLoadTasks[url] == nil else { continue }
            Task { @MainActor in
                _ = try? await cachedModelInstance(contentsOf: url)
            }
        }
    }

    private static func cachedModelInstance(contentsOf url: URL) async throws -> Entity {
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

    /// Recursively removes collision + input from a loaded model's subtree so only the
    /// wrapper node is a hit target — required for two-handed manipulation to pair the
    /// second hand to the same (manipulable) entity as the first.
    private static func stripInteraction(_ e: Entity) {
        e.components.remove(CollisionComponent.self)
        e.components.remove(InputTargetComponent.self)
        e.components.remove(HoverEffectComponent.self)
        e.components.remove(ManipulationComponent.self)
        e.components.remove(ManipulationComponent.HitTarget.self)
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
