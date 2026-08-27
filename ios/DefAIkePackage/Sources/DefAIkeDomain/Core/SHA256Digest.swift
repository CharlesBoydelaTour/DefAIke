// Fixed-width content digest used by handoff verification and bundle integrity.

/// A SHA-256 digest as exactly 32 bytes.
///
/// This is a domain value, not a cryptographic implementation: nothing here
/// computes a digest. Adapters compute digests with the platform's cryptographic
/// framework while streaming, then hand back this bounded value so that domain
/// comparisons (handoff byte identity, verified artifact digests) work without the
/// domain importing a cryptographic dependency.
///
/// CryptoKit declares a type with the same name. Adapters that import both
/// spell this one `DefAIkeDomain.SHA256Digest`.
public struct SHA256Digest: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Digest length in bytes. SHA-256 is fixed at 32.
    public static let byteCount = 32

    /// Number of characters in the canonical lowercase hexadecimal encoding.
    public static let hexadecimalCharacterCount = byteCount * 2

    private static let hexadecimalDigits: [Character] = Array("0123456789abcdef")

    /// The digest bytes, always exactly ``byteCount`` of them.
    public let bytes: [UInt8]

    /// Creates a digest, or `nil` when `bytes` is not exactly ``byteCount`` long.
    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    /// Creates a digest from canonical lowercase hexadecimal.
    ///
    /// Only the canonical form is accepted: exactly ``hexadecimalCharacterCount``
    /// lowercase hexadecimal characters. Uppercase, prefixed, padded, or truncated
    /// text is rejected so that two encodings of the same digest cannot disagree.
    public init?(hexadecimal: String) {
        guard hexadecimal.count == Self.hexadecimalCharacterCount else { return nil }
        var decoded: [UInt8] = []
        decoded.reserveCapacity(Self.byteCount)
        var highNibble: UInt8?
        for character in hexadecimal {
            guard let nibble = Self.nibble(character) else { return nil }
            if let high = highNibble {
                decoded.append(high << 4 | nibble)
                highNibble = nil
            } else {
                highNibble = nibble
            }
        }
        guard highNibble == nil, decoded.count == Self.byteCount else { return nil }
        self.bytes = decoded
    }

    /// The canonical lowercase hexadecimal encoding.
    public var hexadecimalString: String {
        var encoded = ""
        encoded.reserveCapacity(Self.hexadecimalCharacterCount)
        for byte in bytes {
            encoded.append(Self.hexadecimalDigits[Int(byte >> 4)])
            encoded.append(Self.hexadecimalDigits[Int(byte & 0x0F)])
        }
        return encoded
    }

    public var description: String { hexadecimalString }

    private static func nibble(_ character: Character) -> UInt8? {
        switch character {
        case "0": return 0
        case "1": return 1
        case "2": return 2
        case "3": return 3
        case "4": return 4
        case "5": return 5
        case "6": return 6
        case "7": return 7
        case "8": return 8
        case "9": return 9
        case "a": return 10
        case "b": return 11
        case "c": return 12
        case "d": return 13
        case "e": return 14
        case "f": return 15
        default: return nil
        }
    }

    /// Decodes canonical lowercase hexadecimal and rejects anything else.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard let digest = SHA256Digest(hexadecimal: encoded) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: """
                    Expected \(Self.hexadecimalCharacterCount) lowercase \
                    hexadecimal characters, found \(encoded.count).
                    """
            )
        }
        self = digest
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexadecimalString)
    }
}
