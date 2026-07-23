import Foundation

public enum BridgeAssetAssemblyError: LocalizedError, Equatable, Sendable {
    case invalidSize
    case metadataMismatch
    case unexpectedOffset(expected: Int, received: Int)
    case chunkExceedsTotal

    public var errorDescription: String? {
        switch self {
        case .invalidSize:
            return "素材大小不合法"
        case .metadataMismatch:
            return "素材分块信息不一致"
        case .unexpectedOffset(let expected, let received):
            return "素材分块顺序异常：预期 \(expected)，收到 \(received)"
        case .chunkExceedsTotal:
            return "素材分块超过声明大小"
        }
    }
}

public struct BridgeAssetAssembler: Sendable {
    public static let maximumAssetByteCount = 256 * 1_024 * 1_024

    public let path: String
    public let contentHash: String
    public let totalByteCount: Int
    public private(set) var receivedByteCount = 0

    private var data = Data()

    public init(path: String, contentHash: String, totalByteCount: Int) throws {
        guard totalByteCount > 0, totalByteCount <= Self.maximumAssetByteCount else {
            throw BridgeAssetAssemblyError.invalidSize
        }
        self.path = path
        self.contentHash = contentHash
        self.totalByteCount = totalByteCount
    }

    public var progress: Double {
        Double(receivedByteCount) / Double(totalByteCount)
    }

    public mutating func append(_ chunk: BridgeAssetChunk) throws -> Data? {
        guard chunk.path == path,
              chunk.contentHash == contentHash,
              chunk.totalByteCount == totalByteCount else {
            throw BridgeAssetAssemblyError.metadataMismatch
        }
        guard chunk.offset == receivedByteCount else {
            throw BridgeAssetAssemblyError.unexpectedOffset(
                expected: receivedByteCount,
                received: chunk.offset
            )
        }
        guard receivedByteCount + chunk.data.count <= totalByteCount else {
            throw BridgeAssetAssemblyError.chunkExceedsTotal
        }

        data.append(chunk.data)
        receivedByteCount = data.count
        return receivedByteCount == totalByteCount ? data : nil
    }
}
