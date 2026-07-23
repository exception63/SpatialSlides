import CryptoKit
import Foundation

public enum BridgeHash {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(fileAt url: URL) throws -> String {
        try sha256(Data(contentsOf: url, options: .mappedIfSafe))
    }
}
