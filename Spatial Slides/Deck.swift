//
//  Deck.swift  →  the spatial "show" model.
//  Spatial Slides
//
//  ONE unified form (2026-07-12 rewrite): a presentation is a single all-in-one
//  HTML deck (slides + embedded transcript, exposing window.deckAPI) plus a
//  spatial sidecar. Everything is driven by one `currentPage`:
//    • far 主屏  — the HTML deck in present mode (deckAPI.setActive)
//    • carousel  — a ring of per-page thumbnails around the viewer
//    • near      — this page's extracted spatial elements (key lines, 3D models)
//    • left      — the synced transcript
//
//  The package (a `.sslides` folder, produced by spatial-authoring/tools/
//  spatialize.mjs) carries deck.html, show.json, thumb-NN.png, and 3D assets.
//  This file is the on-disk contract for show.json; all types are Codable.
//

import Foundation
import simd

// MARK: - Show (the whole presentation)

struct Show: Codable {
    var title: String
    var html: String          // package-relative HTML (the far 主屏 + transcript source)
    var pageCount: Int
    var pages: [ShowPage]
    var environment: EnvironmentConfig?   // optional 3D scene for full-immersion mode

    enum CodingKeys: String, CodingKey { case title, html, pageCount, pages, environment }
    init(title: String, html: String, pageCount: Int, pages: [ShowPage], environment: EnvironmentConfig? = nil) {
        self.title = title; self.html = html; self.pageCount = pageCount; self.pages = pages; self.environment = environment
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Spatial Show"
        html = try c.decodeIfPresent(String.self, forKey: .html) ?? "deck.html"
        pages = try c.decodeIfPresent([ShowPage].self, forKey: .pages) ?? []
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? pages.count
        environment = try c.decodeIfPresent(EnvironmentConfig.self, forKey: .environment)
    }

    /// An empty placeholder (shown before any package loads).
    static let empty = Show(title: "打开一个演示", html: "", pageCount: 0, pages: [])
}

// MARK: - Immersive environment (optional 3D scene behind the show)

/// An optional 3D environment for full-immersion mode: a package-relative USDZ scene
/// (e.g. a baked low-poly stage) placed behind everything. Absent → the plain dark
/// dome. Position/scale/yaw are here so a scene can be re-fitted from show.json without
/// a rebuild (net-of-package convention: drop `environment.usdz` beside show.json).
struct EnvironmentConfig: Codable {
    var asset: String = "environment.usdz"
    var scale: Float = 1
    var position: SIMD3<Float> = .zero
    var yaw: Float = 0            // radians, about +Y
    enum CodingKeys: String, CodingKey { case asset, scale, position, yaw }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        asset = try c.decodeIfPresent(String.self, forKey: .asset) ?? "environment.usdz"
        scale = try c.decodeIfPresent(Float.self, forKey: .scale) ?? 1
        if let p = try c.decodeIfPresent([Float].self, forKey: .position), p.count >= 3 {
            position = SIMD3<Float>(p[0], p[1], p[2])
        }
        yaw = try c.decodeIfPresent(Float.self, forKey: .yaw) ?? 0
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(asset, forKey: .asset)
        if scale != 1 { try c.encode(scale, forKey: .scale) }
        if position != .zero { try c.encode([position.x, position.y, position.z], forKey: .position) }
        if yaw != 0 { try c.encode(yaw, forKey: .yaw) }
    }
}

/// A resolved environment ready to load: an absolute URL plus its placement.
struct ResolvedEnvironment {
    let url: URL
    let scale: Float
    let position: SIMD3<Float>
    let yaw: Float
}

// MARK: - Page (one HTML slide + its spatial accents)

struct ShowPage: Identifiable, Codable {
    var index: Int
    var title: String
    var thumbnail: String       // package-relative PNG (a carousel card)
    var slide: String?          // package-relative hi-res PNG for the static far panel (#1)
    var anchor: String          // SLIDE_MAP id (kept for reference)
    var transcript: String      // this page's speaker script → the native transcript board
    var elements: [ExhibitElement]   // near-field spatial accents for this page
    var id: Int { index }

    enum CodingKeys: String, CodingKey { case index, title, thumbnail, slide, anchor, transcript, elements }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        thumbnail = try c.decodeIfPresent(String.self, forKey: .thumbnail) ?? ""
        slide = try c.decodeIfPresent(String.self, forKey: .slide)
        anchor = try c.decodeIfPresent(String.self, forKey: .anchor) ?? ""
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        elements = try c.decodeIfPresent([ExhibitElement].self, forKey: .elements) ?? []
    }
}

// MARK: - Element transform

/// Per-element spatial placement. Rotation is Euler angles in radians (XYZ);
/// scale uniform. Persisted in show.json and rewritten by the in-headset editor.
struct ElementTransform: Codable, Equatable {
    var position: SIMD3<Float>
    var rotationEuler: SIMD3<Float>
    var scale: Float

    init(position: SIMD3<Float>, rotationEuler: SIMD3<Float> = .zero, scale: Float = 1) {
        self.position = position; self.rotationEuler = rotationEuler; self.scale = scale
    }
    enum CodingKeys: String, CodingKey { case position, rotationEuler, scale }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = Self.vec3(try c.decodeIfPresent([Float].self, forKey: .position) ?? [])
        rotationEuler = Self.vec3(try c.decodeIfPresent([Float].self, forKey: .rotationEuler) ?? [])
        scale = try c.decodeIfPresent(Float.self, forKey: .scale) ?? 1
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode([position.x, position.y, position.z], forKey: .position)
        if rotationEuler != .zero {
            try c.encode([rotationEuler.x, rotationEuler.y, rotationEuler.z], forKey: .rotationEuler)
        }
        if scale != 1 { try c.encode(scale, forKey: .scale) }
    }
    private static func vec3(_ a: [Float]) -> SIMD3<Float> {
        SIMD3<Float>(a.count > 0 ? a[0] : 0, a.count > 1 ? a[1] : 0, a.count > 2 ? a[2] : 0)
    }

    /// Euler (radians, XYZ) → quaternion for RealityKit.
    var orientation: simd_quatf {
        simd_quatf(angle: rotationEuler.x, axis: [1, 0, 0])
        * simd_quatf(angle: rotationEuler.y, axis: [0, 1, 0])
        * simd_quatf(angle: rotationEuler.z, axis: [0, 0, 1])
    }

    static func from(position: SIMD3<Float>, orientation q: simd_quatf, scale: Float) -> ElementTransform {
        ElementTransform(position: position, rotationEuler: eulerXYZ(from: q), scale: scale)
    }

    /// Inverse of `orientation`: decomposes a quaternion into XYZ Euler angles of
    /// R = Rx·Ry·Rz. Handles the ±90° gimbal-lock case. Host round-trip verified.
    static func eulerXYZ(from q: simd_quatf) -> SIMD3<Float> {
        let c0 = q.act(SIMD3<Float>(1, 0, 0))
        let c1 = q.act(SIMD3<Float>(0, 1, 0))
        let c2 = q.act(SIMD3<Float>(0, 0, 1))
        let m00 = c0.x, m10 = c0.y
        let m01 = c1.x, m11 = c1.y
        let m02 = c2.x, m12 = c2.y, m22 = c2.z
        let sy = min(max(m02, -1), 1)
        let y = asin(sy)
        let x: Float, z: Float
        if abs(sy) < 0.99999 {
            x = atan2(-m12, m22); z = atan2(-m01, m00)
        } else {
            x = 0; z = atan2(m10, m11)
        }
        return SIMD3<Float>(x, y, z)
    }
}

// MARK: - Animation (optional per-element; near accents can build in / loop)

enum BuildEffect: String, Codable {
    case flyIn, fade, scale, none
    init(from d: Decoder) throws { self = BuildEffect(rawValue: try d.singleValueContainer().decode(String.self)) ?? .flyIn }
}
enum LoopEffect: String, Codable {
    case spin, float, breathe, none
    init(from d: Decoder) throws { self = LoopEffect(rawValue: try d.singleValueContainer().decode(String.self)) ?? .none }
}
enum EmphasisEffect: String, Codable {
    case pulse, glow, highlight, bounce, none
    init(from d: Decoder) throws { self = EmphasisEffect(rawValue: try d.singleValueContainer().decode(String.self)) ?? .pulse }
}

struct BuildIn: Codable {
    var effect: BuildEffect = .flyIn
    var order: Int = 0, delay: Double = 0, duration: Double = 0.5
    enum CodingKeys: String, CodingKey { case effect, order, delay, duration }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        effect = try c.decodeIfPresent(BuildEffect.self, forKey: .effect) ?? .flyIn
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        delay = try c.decodeIfPresent(Double.self, forKey: .delay) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0.5
    }
}
struct LoopAnim: Codable {
    var effect: LoopEffect = .none
    var period: Double = 6, amplitude: Double = 1
    enum CodingKeys: String, CodingKey { case effect, period, amplitude }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        effect = try c.decodeIfPresent(LoopEffect.self, forKey: .effect) ?? .none
        period = try c.decodeIfPresent(Double.self, forKey: .period) ?? 6
        amplitude = try c.decodeIfPresent(Double.self, forKey: .amplitude) ?? 1
    }
}
struct Emphasis: Codable {
    var effect: EmphasisEffect = .none
    enum CodingKeys: String, CodingKey { case effect }
    init(from d: Decoder) throws {
        effect = try d.container(keyedBy: CodingKeys.self).decodeIfPresent(EmphasisEffect.self, forKey: .effect) ?? .none
    }
}
struct ElementAnimation: Codable { var buildIn: BuildIn?; var loop: LoopAnim?; var emphasis: Emphasis? }

// MARK: - Table (a spatial glass grid)

struct TableData: Codable {
    var columns: [String]; var rows: [[String]]; var header: Bool = true
    init(columns: [String], rows: [[String]], header: Bool = true) { self.columns = columns; self.rows = rows; self.header = header }
    enum CodingKeys: String, CodingKey { case columns, rows, header }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? []
        rows = try c.decodeIfPresent([[String]].self, forKey: .rows) ?? []
        header = try c.decodeIfPresent(Bool.self, forKey: .header) ?? true
    }
}

// MARK: - Element (a near-field spatial accent)

enum ElementKind: String, Codable {
    case title, statement, text, bullets, stat, barChart, scatter, table, model, image
}

struct ExhibitElement: Identifiable {
    var id: String = UUID().uuidString
    var kind: ElementKind
    var transform: ElementTransform?
    var size: SIMD2<Float>?
    var background: String?      // "glass" | "none" | "glow"

    var text: String?
    var subtitle: String?
    var align: String?
    var bullets: [String]?
    var value: String?
    var caption: String?

    var bars: [BarValue]?
    var points: [ScatterPoint]?
    var table: TableData?
    var animation: ElementAnimation?

    var asset: String?           // package-relative file (image / USDZ model)
    var modelName: String?       // bundled model by name (fallback)
    var modelScale: Float = 1
    var imageName: String?

    /// Text-ish + image render as SwiftUI glass panels (attachments); chart/model
    /// kinds are built from RealityKit meshes.
    var usesAttachment: Bool {
        switch kind {
        case .title, .statement, .text, .bullets, .stat, .table, .image: return true
        case .barChart, .scatter, .model: return false
        }
    }
}

extension ExhibitElement: Codable {
    enum CodingKeys: String, CodingKey {
        case id, kind, transform, size, background, text, subtitle, align, bullets,
             value, caption, bars, points, table, animation, asset, modelName, modelScale, imageName
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try c.decode(ElementKind.self, forKey: .kind)
        transform = try c.decodeIfPresent(ElementTransform.self, forKey: .transform)
        if let s = try c.decodeIfPresent([Float].self, forKey: .size), s.count >= 2 { size = SIMD2<Float>(s[0], s[1]) }
        background = try c.decodeIfPresent(String.self, forKey: .background)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        align = try c.decodeIfPresent(String.self, forKey: .align)
        bullets = try c.decodeIfPresent([String].self, forKey: .bullets)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        bars = try c.decodeIfPresent([BarValue].self, forKey: .bars)
        points = try c.decodeIfPresent([ScatterPoint].self, forKey: .points)
        table = try c.decodeIfPresent(TableData.self, forKey: .table)
        animation = try c.decodeIfPresent(ElementAnimation.self, forKey: .animation)
        asset = try c.decodeIfPresent(String.self, forKey: .asset)
        modelName = try c.decodeIfPresent(String.self, forKey: .modelName)
        modelScale = try c.decodeIfPresent(Float.self, forKey: .modelScale) ?? 1
        imageName = try c.decodeIfPresent(String.self, forKey: .imageName)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(transform, forKey: .transform)
        if let size { try c.encode([size.x, size.y], forKey: .size) }
        try c.encodeIfPresent(background, forKey: .background)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(subtitle, forKey: .subtitle)
        try c.encodeIfPresent(align, forKey: .align)
        try c.encodeIfPresent(bullets, forKey: .bullets)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(caption, forKey: .caption)
        try c.encodeIfPresent(bars, forKey: .bars)
        try c.encodeIfPresent(points, forKey: .points)
        try c.encodeIfPresent(table, forKey: .table)
        try c.encodeIfPresent(animation, forKey: .animation)
        try c.encodeIfPresent(asset, forKey: .asset)
        try c.encodeIfPresent(modelName, forKey: .modelName)
        if modelScale != 1 { try c.encode(modelScale, forKey: .modelScale) }
        try c.encodeIfPresent(imageName, forKey: .imageName)
    }
}

// MARK: - Chart data

struct BarValue: Identifiable, Codable {
    var id: String = UUID().uuidString
    var label: String; var value: Double; var colorHex: String?
    init(_ label: String, _ value: Double, _ colorHex: String? = nil) { self.label = label; self.value = value; self.colorHex = colorHex }
    enum CodingKeys: String, CodingKey { case id, label, value, colorHex }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        value = try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
    }
}

struct ScatterPoint: Codable {
    var x: Double, y: Double, z: Double
    var label: String?; var colorHex: String?
    init(x: Double, y: Double, z: Double = 0, label: String? = nil, colorHex: String? = nil) {
        self.x = x; self.y = y; self.z = z; self.label = label; self.colorHex = colorHex
    }
    enum CodingKeys: String, CodingKey { case x, y, z, label, colorHex }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        z = try c.decodeIfPresent(Double.self, forKey: .z) ?? 0
        label = try c.decodeIfPresent(String.self, forKey: .label)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
    }
}
