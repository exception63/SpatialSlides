import Foundation

public enum SpatialBridgeFramingError: Error, Equatable {
    case frameTooLarge(Int)
    case invalidLength
}

public struct SpatialBridgeFrameDecoder: Sendable {
    public static let maximumFrameLength = 64 * 1_024 * 1_024
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while buffer.count >= MemoryLayout<UInt32>.size {
            let frameStart = buffer.startIndex
            let headerEnd = buffer.index(frameStart, offsetBy: 4)
            let length = buffer[frameStart..<headerEnd].reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            guard length > 0 else { throw SpatialBridgeFramingError.invalidLength }
            guard length <= Self.maximumFrameLength else {
                throw SpatialBridgeFramingError.frameTooLarge(Int(length))
            }
            let totalLength = 4 + Int(length)
            guard buffer.count >= totalLength else { break }
            let frameEnd = buffer.index(frameStart, offsetBy: totalLength)
            frames.append(Data(buffer[headerEnd..<frameEnd]))
            buffer.removeSubrange(frameStart..<frameEnd)
        }

        return frames
    }

    public static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw SpatialBridgeFramingError.invalidLength }
        guard payload.count <= maximumFrameLength else {
            throw SpatialBridgeFramingError.frameTooLarge(payload.count)
        }

        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }
}
