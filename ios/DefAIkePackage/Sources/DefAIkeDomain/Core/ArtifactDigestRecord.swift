// Canonical artifact paths and the digest records a verified bundle projects into
// a session binding.

/// A canonical relative path inside an immutable artifact tree.
///
/// Structural canonicality only: nonempty, relative, no empty component, no `.`
/// or `..` component, no backslash, no whitespace or control character, bounded
/// length. Symlink rejection, declared-only-contents checks, and the rest of the
/// bundle verification order belong to the Model Bundle layer, which resolves
/// paths against a real directory. This type exists so a traversal or absolute
/// path cannot be represented in a digest record at all.
public struct CanonicalRelativePath: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Structural ceiling on path length. A safety bound, not an approved value.
    public static let maximumCharacterCount = 1024

    public let rawValue: String

    public init?(_ rawValue: String) {
        guard !rawValue.isEmpty, rawValue.count <= Self.maximumCharacterCount else {
            return nil
        }
        guard !rawValue.hasPrefix("/") else { return nil }
        guard !rawValue.contains("\\") else { return nil }
        // Printable ASCII without space: excludes control characters, newlines,
        // and whitespace that a path comparison could normalize away.
        guard rawValue.allSatisfy({ character in
            guard let ascii = character.asciiValue else { return false }
            return ascii > 0x20 && ascii < 0x7F
        }) else {
            return nil
        }
        let components = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".."
        }) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let path = CanonicalRelativePath(rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Rejected a noncanonical relative artifact path."
            )
        }
        self = path
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One declared artifact's canonical path, kind, byte count, and digest.
public struct ArtifactDigestRecord: Hashable, Codable, Sendable {
    /// Whether the digest covers a single file or a deterministic directory tree.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A single file's byte digest.
        case file
        /// A directory's deterministic tree digest, as specified by the Bundle
        /// Verification Policy's canonicalization profile.
        case directoryTree
    }

    public let path: CanonicalRelativePath
    public let kind: Kind
    public let byteCount: UInt64
    public let digest: SHA256Digest

    public init(
        path: CanonicalRelativePath,
        kind: Kind,
        byteCount: UInt64,
        digest: SHA256Digest
    ) {
        self.path = path
        self.kind = kind
        self.byteCount = byteCount
        self.digest = digest
    }
}
