import Foundation

public enum SpatialExperienceKind: String, Codable, Sendable {
    case slides
    case drawing
    case genericScene
}

public struct BridgeHello: Codable, Equatable, Sendable {
    public var deviceName: String
    public var experienceKind: SpatialExperienceKind
    public var protocolVersion: Int

    public init(
        deviceName: String,
        experienceKind: SpatialExperienceKind,
        protocolVersion: Int = SpatialBridgeEnvelope.currentProtocolVersion
    ) {
        self.deviceName = deviceName
        self.experienceKind = experienceKind
        self.protocolVersion = protocolVersion
    }
}

public struct BridgeAssetDescriptor: Codable, Equatable, Sendable {
    public var path: String
    public var byteCount: Int
    public var contentHash: String

    public init(path: String, byteCount: Int, contentHash: String) {
        self.path = path
        self.byteCount = byteCount
        self.contentHash = contentHash
    }
}

public struct BridgeDeckManifest: Codable, Equatable, Sendable {
    public var showID: String
    public var title: String
    public var pageCount: Int
    public var assets: [BridgeAssetDescriptor]

    public init(showID: String, title: String, pageCount: Int, assets: [BridgeAssetDescriptor]) {
        self.showID = showID
        self.title = title
        self.pageCount = pageCount
        self.assets = assets
    }
}

public struct BridgeBarValue: Codable, Equatable, Sendable {
    public var label: String
    public var value: Double
    public var colorHex: String?

    public init(label: String, value: Double, colorHex: String? = nil) {
        self.label = label
        self.value = value
        self.colorHex = colorHex
    }
}

public struct BridgeScatterPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var label: String?
    public var colorHex: String?

    public init(x: Double, y: Double, z: Double, label: String? = nil, colorHex: String? = nil) {
        self.x = x
        self.y = y
        self.z = z
        self.label = label
        self.colorHex = colorHex
    }
}

public struct BridgeElementSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var transform: BridgeTransform
    public var size: BridgeVector2?
    public var visible: Bool
    public var background: String?
    public var text: String?
    public var subtitle: String?
    public var bullets: [String]?
    public var value: String?
    public var caption: String?
    public var assetPath: String?
    public var modelScale: Float?
    public var bars: [BridgeBarValue]?
    public var points: [BridgeScatterPoint]?
    public var loopEffect: String?
    public var loopPeriod: Double?
    public var loopAmplitude: Double?

    public init(
        id: String,
        kind: String,
        transform: BridgeTransform,
        size: BridgeVector2? = nil,
        visible: Bool = true,
        background: String? = nil,
        text: String? = nil,
        subtitle: String? = nil,
        bullets: [String]? = nil,
        value: String? = nil,
        caption: String? = nil,
        assetPath: String? = nil,
        modelScale: Float? = nil,
        bars: [BridgeBarValue]? = nil,
        points: [BridgeScatterPoint]? = nil,
        loopEffect: String? = nil,
        loopPeriod: Double? = nil,
        loopAmplitude: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.transform = transform
        self.size = size
        self.visible = visible
        self.background = background
        self.text = text
        self.subtitle = subtitle
        self.bullets = bullets
        self.value = value
        self.caption = caption
        self.assetPath = assetPath
        self.modelScale = modelScale
        self.bars = bars
        self.points = points
        self.loopEffect = loopEffect
        self.loopPeriod = loopPeriod
        self.loopAmplitude = loopAmplitude
    }
}

public struct BridgeSlidesSnapshot: Codable, Equatable, Sendable {
    public var showID: String
    public var title: String
    public var page: Int
    public var pageCount: Int
    public var beat: Int
    public var maxBeat: Int
    public var motionMode: Bool
    public var slideAssetPath: String?
    public var deckTransform: BridgeTransform
    public var elements: [BridgeElementSnapshot]

    public init(
        showID: String,
        title: String,
        page: Int,
        pageCount: Int,
        beat: Int,
        maxBeat: Int,
        motionMode: Bool,
        slideAssetPath: String?,
        deckTransform: BridgeTransform,
        elements: [BridgeElementSnapshot]
    ) {
        self.showID = showID
        self.title = title
        self.page = page
        self.pageCount = pageCount
        self.beat = beat
        self.maxBeat = maxBeat
        self.motionMode = motionMode
        self.slideAssetPath = slideAssetPath
        self.deckTransform = deckTransform
        self.elements = elements
    }
}

public struct BridgeDeckTransformUpdate: Codable, Equatable, Sendable {
    public var showID: String
    public var transform: BridgeTransform

    public init(showID: String, transform: BridgeTransform) {
        self.showID = showID
        self.transform = transform
    }
}

public struct BridgeAssetData: Codable, Equatable, Sendable {
    public var path: String
    public var contentHash: String
    public var data: Data

    public init(path: String, contentHash: String, data: Data) {
        self.path = path
        self.contentHash = contentHash
        self.data = data
    }
}

public struct BridgeAssetChunk: Codable, Equatable, Sendable {
    public var path: String
    public var contentHash: String
    public var totalByteCount: Int
    public var offset: Int
    public var data: Data

    public init(path: String, contentHash: String, totalByteCount: Int, offset: Int, data: Data) {
        self.path = path
        self.contentHash = contentHash
        self.totalByteCount = totalByteCount
        self.offset = offset
        self.data = data
    }
}

public enum SpatialBridgePayload: Codable, Equatable, Sendable {
    case hello(BridgeHello)
    case manifest(BridgeDeckManifest)
    case slidesSnapshot(BridgeSlidesSnapshot)
    case deckTransform(BridgeDeckTransformUpdate)
    case requestSnapshot
    case requestAsset(String)
    case asset(BridgeAssetData)
    case assetChunk(BridgeAssetChunk)

    private enum CodingKeys: String, CodingKey {
        case type
        case hello
        case manifest
        case snapshot
        case deckTransform
        case path
        case asset
        case chunk
    }

    private enum PayloadType: String, Codable {
        case hello
        case manifest
        case slidesSnapshot
        case deckTransform
        case requestSnapshot
        case requestAsset
        case asset
        case assetChunk
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(PayloadType.self, forKey: .type) {
        case .hello:
            self = .hello(try container.decode(BridgeHello.self, forKey: .hello))
        case .manifest:
            self = .manifest(try container.decode(BridgeDeckManifest.self, forKey: .manifest))
        case .slidesSnapshot:
            self = .slidesSnapshot(try container.decode(BridgeSlidesSnapshot.self, forKey: .snapshot))
        case .deckTransform:
            self = .deckTransform(
                try container.decode(BridgeDeckTransformUpdate.self, forKey: .deckTransform)
            )
        case .requestSnapshot:
            self = .requestSnapshot
        case .requestAsset:
            self = .requestAsset(try container.decode(String.self, forKey: .path))
        case .asset:
            self = .asset(try container.decode(BridgeAssetData.self, forKey: .asset))
        case .assetChunk:
            self = .assetChunk(try container.decode(BridgeAssetChunk.self, forKey: .chunk))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let hello):
            try container.encode(PayloadType.hello, forKey: .type)
            try container.encode(hello, forKey: .hello)
        case .manifest(let manifest):
            try container.encode(PayloadType.manifest, forKey: .type)
            try container.encode(manifest, forKey: .manifest)
        case .slidesSnapshot(let snapshot):
            try container.encode(PayloadType.slidesSnapshot, forKey: .type)
            try container.encode(snapshot, forKey: .snapshot)
        case .deckTransform(let update):
            try container.encode(PayloadType.deckTransform, forKey: .type)
            try container.encode(update, forKey: .deckTransform)
        case .requestSnapshot:
            try container.encode(PayloadType.requestSnapshot, forKey: .type)
        case .requestAsset(let path):
            try container.encode(PayloadType.requestAsset, forKey: .type)
            try container.encode(path, forKey: .path)
        case .asset(let asset):
            try container.encode(PayloadType.asset, forKey: .type)
            try container.encode(asset, forKey: .asset)
        case .assetChunk(let chunk):
            try container.encode(PayloadType.assetChunk, forKey: .type)
            try container.encode(chunk, forKey: .chunk)
        }
    }
}

public struct SpatialBridgeEnvelope: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 3

    public var protocolVersion: Int
    public var sequence: UInt64
    public var sentAt: Date
    public var payload: SpatialBridgePayload

    public init(
        protocolVersion: Int = currentProtocolVersion,
        sequence: UInt64,
        sentAt: Date = Date(),
        payload: SpatialBridgePayload
    ) {
        self.protocolVersion = protocolVersion
        self.sequence = sequence
        self.sentAt = sentAt
        self.payload = payload
    }
}
