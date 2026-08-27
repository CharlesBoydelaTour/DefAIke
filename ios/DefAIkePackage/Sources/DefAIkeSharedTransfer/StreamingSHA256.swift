import DefAIkeDomain
import CryptoKit
import Foundation

// Incremental SHA-256 over a byte stream.
//
// The design's byte lifecycle requires encoded bytes to be "copied once per container
// boundary, streamed rather than eagerly materialized". A digest computed by re-reading
// a finished file would be a second pass over data that may already have changed, and it
// would require holding the whole representation to hash it. Hashing happens in the same
// pass that writes, so the digest describes exactly the bytes that were written
// (Requirements 2.9 through 2.13).
//
// `CryptoKit` declares its own `SHA256Digest`, so the domain value is always spelled
// `DefAIkeDomain.SHA256Digest` here.

/// A SHA-256 hasher that also counts the bytes it consumed.
///
/// The byte count is part of the hasher rather than a separate variable the caller keeps
/// in step, because the count and the digest must describe the same stream: a handoff
/// comparison that used a count from one place and a digest from another could pass while
/// they disagree (Requirement 2.19).
///
/// Not `Sendable`: an in-flight hash is mutable state belonging to one writer. Concrete
/// stores keep it inside their own isolation.
public struct StreamingSHA256 {
    private var hasher = CryptoKit.SHA256()
    private var consumedByteCount: UInt64 = 0

    public init() {}

    /// How many bytes have been hashed so far.
    public var byteCount: UInt64 { consumedByteCount }

    /// Hashes the next chunk.
    ///
    /// Chunk boundaries never change the result: SHA-256 is defined over the byte
    /// sequence, so any partition of the same bytes finalizes to the same digest and the
    /// same count (Property 5).
    public mutating func update(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        hasher.update(data: chunk)
        consumedByteCount += UInt64(chunk.count)
    }

    /// Hashes the next chunk.
    public mutating func update(_ chunk: [UInt8]) {
        guard !chunk.isEmpty else { return }
        chunk.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        consumedByteCount += UInt64(chunk.count)
    }

    /// The digest of everything hashed so far.
    ///
    /// Non-consuming, so a caller can record a digest and keep streaming. Callers that
    /// finalize an object take the digest exactly once.
    public func digest() -> DefAIkeDomain.SHA256Digest {
        // `finalize()` consumes the hasher, so a copy is finalized and this hasher stays
        // usable. Copying is what makes the method non-consuming for the caller.
        let snapshot = hasher
        return Self.domainDigest(snapshot.finalize())
    }

    /// One-shot digest of a complete byte sequence.
    ///
    /// For short values a caller already holds in memory, such as a scope name. Encoded
    /// image bytes always go through the streaming path.
    public static func digest(of bytes: some DataProtocol) -> DefAIkeDomain.SHA256Digest {
        domainDigest(CryptoKit.SHA256.hash(data: bytes))
    }

    private static func domainDigest(
        _ digest: some Digest
    ) -> DefAIkeDomain.SHA256Digest {
        guard let value = DefAIkeDomain.SHA256Digest(bytes: Array(digest)) else {
            // Unreachable: SHA-256 is fixed at 32 bytes, which is exactly what the
            // domain value requires. A failure here would mean the digest width changed
            // underneath us, and continuing with a truncated digest would silently
            // weaken every byte-identity comparison.
            preconditionFailure("SHA-256 produced \(Array(digest).count) bytes, expected 32")
        }
        return value
    }
}
