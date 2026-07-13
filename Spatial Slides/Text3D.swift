//
//  Text3D.swift
//  Spatial Slides
//
//  Builds bare, glowing 3D text that floats directly in space (no panel).
//  Uses an UnlitMaterial so text is always bright regardless of scene
//  lighting — a clean "hologram" look.
//
//  Text is generated at a reference point size then scaled to an exact
//  height in metres, which keeps CJK glyphs crisp and the sizing precise.
//

import RealityKit
import UIKit

enum Text3D {
    /// - Parameter height: cap-to-baseline height of the text, in metres.
    static func make(_ string: String,
                     height: Float,
                     color: UIColor,
                     weight: UIFont.Weight = .semibold) -> Entity {
        let referenceSize: CGFloat = 1.0
        let mesh = MeshResource.generateText(
            string.isEmpty ? " " : string,
            extrusionDepth: 0.02,
            font: .systemFont(ofSize: referenceSize, weight: weight),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )

        let text = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
        let bounds = mesh.bounds
        text.position = -bounds.center           // centre on local origin

        let wrapper = Entity()
        wrapper.addChild(text)
        let scale = height / max(bounds.extents.y, 0.0001)
        wrapper.scale = [scale, scale, scale]
        return wrapper
    }
}
