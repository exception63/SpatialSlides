//
//  BarChart3D.swift
//  Spatial Slides
//
//  A 3D bar chart built from RealityKit meshes. Bars are built at full
//  height (always visible); the whole chart animates in via the stage's
//  generic scale-in. Labels are bare 3D text (Text3D).
//

import RealityKit
import UIKit

enum BarChart3D {

    static func make(bars: [BarValue]) -> Entity {
        let container = Entity()
        guard !bars.isEmpty else { return container }

        let maxValue = max(bars.map(\.value).max() ?? 1, 1)
        let barWidth: Float = 0.14
        let gap: Float = 0.09
        let maxHeight: Float = 0.6
        let depth: Float = 0.14

        let step = barWidth + gap
        let totalWidth = step * Float(bars.count) - gap
        let startX = -totalWidth / 2 + barWidth / 2

        for (i, bar) in bars.enumerated() {
            let height = max(Float(bar.value / maxValue) * maxHeight, 0.01)
            let x = startX + Float(i) * step
            let color = UIColor(hex: bar.colorHex ?? "#5AC8FA")

            let box = ModelEntity(
                mesh: .generateBox(width: barWidth, height: height, depth: depth, cornerRadius: 0.012),
                materials: [barMaterial(color)]
            )
            box.position = [x, height / 2, 0]     // rest on the baseline
            container.addChild(box)

            let label = Text3D.make(bar.label, height: 0.05, color: .white)
            label.position = [x, -0.065, depth / 2 + 0.001]
            container.addChild(label)

            let value = Text3D.make(formatted(bar.value), height: 0.045, color: color)
            value.position = [x, height + 0.05, depth / 2 + 0.001]
            container.addChild(value)
        }

        // Baseline plate.
        let base = ModelEntity(
            mesh: .generateBox(width: totalWidth + 0.2, height: 0.012, depth: depth + 0.14, cornerRadius: 0.006),
            materials: [baseMaterial()]
        )
        base.position = [0, -0.006, 0]
        container.addChild(base)

        return container
    }

    // MARK: - Materials

    private static func barMaterial(_ color: UIColor) -> RealityKit.Material {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = 0.35
        material.metallic = 0.0
        material.emissiveColor = .init(color: color)
        material.emissiveIntensity = 0.55
        return material
    }

    private static func baseMaterial() -> RealityKit.Material {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor.white.withAlphaComponent(0.18))
        material.roughness = 0.6
        return material
    }

    private static func formatted(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
