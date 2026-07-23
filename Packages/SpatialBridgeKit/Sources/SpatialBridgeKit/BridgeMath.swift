import Foundation
import simd

public struct BridgeVector2: Codable, Equatable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    public init(_ value: SIMD2<Float>) {
        self.init(x: value.x, y: value.y)
    }

    public var simd: SIMD2<Float> { [x, y] }
}

public struct BridgeVector3: Codable, Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(_ value: SIMD3<Float>) {
        self.init(x: value.x, y: value.y, z: value.z)
    }

    public var simd: SIMD3<Float> { [x, y, z] }
}

public struct BridgeQuaternion: Codable, Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float
    public var w: Float

    public init(x: Float, y: Float, z: Float, w: Float) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public init(_ value: simd_quatf) {
        let vector = value.vector
        self.init(x: vector.x, y: vector.y, z: vector.z, w: vector.w)
    }

    public var simd: simd_quatf {
        simd_quatf(vector: [x, y, z, w])
    }
}

public struct BridgeTransform: Codable, Equatable, Sendable {
    public var translation: BridgeVector3
    public var rotation: BridgeQuaternion
    public var scale: BridgeVector3

    public init(
        translation: BridgeVector3 = .init(x: 0, y: 0, z: 0),
        rotation: BridgeQuaternion = .init(x: 0, y: 0, z: 0, w: 1),
        scale: BridgeVector3 = .init(x: 1, y: 1, z: 1)
    ) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    public init(matrix: simd_float4x4) {
        let xScale = length(SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z))
        let yScale = length(SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z))
        let zScale = length(SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
        var rotationMatrix = matrix
        if xScale > 0 { rotationMatrix.columns.0 /= xScale }
        if yScale > 0 { rotationMatrix.columns.1 /= yScale }
        if zScale > 0 { rotationMatrix.columns.2 /= zScale }
        rotationMatrix.columns.3 = [0, 0, 0, 1]

        translation = BridgeVector3([matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z])
        rotation = BridgeQuaternion(simd_quatf(rotationMatrix))
        scale = BridgeVector3([xScale, yScale, zScale])
    }

    public var matrix: simd_float4x4 {
        var matrix = simd_float4x4(rotation.simd)
        matrix.columns.0 *= scale.x
        matrix.columns.1 *= scale.y
        matrix.columns.2 *= scale.z
        matrix.columns.3 = [translation.x, translation.y, translation.z, 1]
        return matrix
    }
}

public struct SharedAlignmentFrame: Equatable, Sendable {
    public let worldFromShared: simd_float4x4

    public init(worldFromShared: simd_float4x4) {
        self.worldFromShared = worldFromShared
    }

    public init?(origin: SIMD3<Float>, forwardPoint: SIMD3<Float>, up: SIMD3<Float> = [0, 1, 0]) {
        let normalizedUp = normalize(up)
        var forward = forwardPoint - origin
        forward -= dot(forward, normalizedUp) * normalizedUp
        guard length(forward) >= 0.08 else { return nil }
        forward = normalize(forward)

        let right = normalize(cross(normalizedUp, forward))
        guard right.x.isFinite, right.y.isFinite, right.z.isFinite else { return nil }
        let correctedUp = normalize(cross(forward, right))

        worldFromShared = simd_float4x4(
            SIMD4<Float>(right, 0),
            SIMD4<Float>(correctedUp, 0),
            SIMD4<Float>(forward, 0),
            SIMD4<Float>(origin, 1)
        )
    }

    public var sharedFromWorld: simd_float4x4 {
        worldFromShared.inverse
    }

    public func worldPoint(fromShared point: SIMD3<Float>) -> SIMD3<Float> {
        let result = worldFromShared * SIMD4<Float>(point, 1)
        return SIMD3<Float>(result.x, result.y, result.z)
    }

    public func sharedPoint(fromWorld point: SIMD3<Float>) -> SIMD3<Float> {
        let result = sharedFromWorld * SIMD4<Float>(point, 1)
        return SIMD3<Float>(result.x, result.y, result.z)
    }

    public func sharedTransform(fromWorld matrix: simd_float4x4) -> simd_float4x4 {
        sharedFromWorld * matrix
    }
}
