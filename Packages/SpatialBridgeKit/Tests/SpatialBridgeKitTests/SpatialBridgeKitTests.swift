import Foundation
import Testing
import simd
@testable import SpatialBridgeKit

struct SpatialBridgeKitTests {
    @Test
    func alignmentRoundTrip() throws {
        let frame = try #require(
            SharedAlignmentFrame(origin: [1, 0.5, -2], forwardPoint: [1.2, 0.5, -1.8])
        )
        let shared = SIMD3<Float>(0.3, 1.1, -0.8)
        let world = frame.worldPoint(fromShared: shared)
        let recovered = frame.sharedPoint(fromWorld: world)
        #expect(distance(shared, recovered) < 0.0001)
    }

    @Test
    func envelopeRoundTrip() throws {
        let snapshot = BridgeSlidesSnapshot(
            showID: "demo",
            title: "Demo",
            page: 3,
            pageCount: 20,
            beat: 1,
            maxBeat: 2,
            motionMode: false,
            slideAssetPath: "slide-03.png",
            deckTransform: BridgeTransform(),
            elements: []
        )
        let original = SpatialBridgeEnvelope(
            sequence: 42,
            payload: .slidesSnapshot(snapshot)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SpatialBridgeEnvelope.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func framingHandlesPartialAndAdjacentFrames() throws {
        let first = try SpatialBridgeFrameDecoder.encode(Data("one".utf8))
        let second = try SpatialBridgeFrameDecoder.encode(Data("two".utf8))
        let joined = first + second
        var decoder = SpatialBridgeFrameDecoder()

        #expect(try decoder.append(joined.prefix(5)).isEmpty)
        let frames = try decoder.append(joined.dropFirst(5))
        #expect(frames == [Data("one".utf8), Data("two".utf8)])
    }
}
