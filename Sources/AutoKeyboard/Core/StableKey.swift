import CryptoKit
import Foundation

enum StableKeyEncoder {
    static func encode(_ parts: String...) -> String {
        parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

enum StableDigest {
    static func sha256Prefix(_ text: String, bytes: Int = 16) -> String {
        let hash = SHA256.hash(data: Data(text.utf8))
        return hash.prefix(bytes).map { String(format: "%02x", $0) }.joined()
    }
}
