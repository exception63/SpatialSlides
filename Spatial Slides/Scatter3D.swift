//
//  Scatter3D.swift
//  Spatial Slides
//
//  A 3D scatter plot built from RealityKit meshes: one glowing sphere per
//  point, laid out inside a ~0.6 m cube whose axes are normalised to the data
//  range. Data is authored (not edited in-headset); the whole plot moves and
//  scales as one element via its transform.
//

import RealityKit
import UIKit

enum Scatter3D {

    static func make(points: [ScatterPoint]) -> Entity {
        let container = Entity()
        guard !points.isEmpty else { return container }

        let span: Float = 0.6                     // cube edge length, metres
        let xs = points.map { Float($0.x) }
        let ys = points.map { Float($0.y) }
        let zs = points.map { Float($0.z) }

        func norm(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
            hi > lo ? (v - lo) / (hi - lo) * span - span / 2 : 0
        }
        let (xLo, xHi) = (xs.min() ?? 0, xs.max() ?? 1)
        let (yLo, yHi) = (ys.min() ?? 0, ys.max() ?? 1)
        let (zLo, zHi) = (zs.min() ?? 0, zs.max() ?? 1)

        for point in points {
            let color = UIColor(hex: point.colorHex ?? "#5AC8FA")
            let dot = ModelEntity(
                mesh: .generateSphere(radius: 0.02),
                materials: [dotMaterial(color)]
            )
            dot.position = [
                norm(Float(point.x), xLo, xHi),
                norm(Float(point.y), yLo, yHi) + span / 2,   // sit above baseline
                norm(Float(point.z), zLo, zHi)
            ]
            container.addChild(dot)

            if let label = point.label {
                let text = Text3D.make(label, height: 0.03, color: .white)
                text.position = dot.position + [0, 0.045, 0]
                container.addChild(text)
            }
        }

        // Faint baseline plate for grounding.
        let base = ModelEntity(
            mesh: .generateBox(width: span + 0.12, height: 0.01, depth: span + 0.12, cornerRadius: 0.006),
            materials: [baseMaterial()]
        )
        base.position = [0, -0.005, 0]
        container.addChild(base)

        return container
    }

    private static func dotMaterial(_ color: UIColor) -> RealityKit.Material {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = 0.3
        material.metallic = 0.0
        material.emissiveColor = .init(color: color)
        material.emissiveIntensity = 0.7
        return material
    }

    private static func baseMaterial() -> RealityKit.Material {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor.white.withAlphaComponent(0.15))
        material.roughness = 0.6
        return material
    }
}
