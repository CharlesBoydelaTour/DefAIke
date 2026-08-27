import DefAIkeDomain
import CryptoKit
import Foundation

// Stream hashing and the deterministic directory-tree digest.
//
// A Model Bundle declares a digest per artifact, and a directory artifact — the
// compiled Core ML model, the fixture directory — needs a digest over a whole tree.
// `ArtifactDigestRecord.Kind.directoryTree` says that digest follows "the
// canonicalization profile the signature covers", which is a Bundle Verification
// Policy field, not something this module gets to pick.
//
// So this file holds two separate things:
//
//   * one construction, spelled out below and implemented once; and
//   * ``ApprovedCanonicalizationProfile``, the approved statement that the policy's
//     profile is the construction this build implements. Without that statement
//     verification fails closed rather than assuming the two agree.

// MARK: - Streaming SHA-256

/// Incremental SHA-256 producing a domain digest value.
///
/// Hashing is incremental because a candidate's weight blob is hashed while it
/// streams, never by loading it. Chunk boundaries cannot change the result, so the
/// read granularity is a memory decision rather than part of the digest definition.
///
/// CryptoKit declares a `SHA256Digest` of its own; the domain value is spelled out
/// in full wherever both are in scope.
struct StreamingSHA256 {
    private var hasher = CryptoKit.SHA256()

    init() {}

    mutating func update(_ chunk: ArraySlice<UInt8>) {
        guard !chunk.isEmpty else { return }
        chunk.withUnsafeBufferPointer { buffer in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
        }
    }

    mutating func update(_ bytes: [UInt8]) {
        update(bytes[...])
    }

    mutating func finalize() -> DefAIkeDomain.SHA256Digest {
        let computed = hasher.finalize()
        guard let digest = DefAIkeDomain.SHA256Digest(bytes: Array(computed)) else {
            preconditionFailure(
                "SHA-256 must produce exactly \(DefAIkeDomain.SHA256Digest.byteCount) bytes."
            )
        }
        return digest
    }

    /// Digest of a complete byte sequence.
    static func digest(of bytes: [UInt8]) -> DefAIkeDomain.SHA256Digest {
        var hasher = StreamingSHA256()
        hasher.update(bytes)
        return hasher.finalize()
    }
}

// MARK: - Tree digest construction

/// A deterministic directory-tree digest construction this build implements.
///
/// One case, because one construction is implemented. The enumeration exists so a
/// policy that names a profile this build does not implement is refused by value
/// rather than by assumption.
public enum BundleTreeDigestConstruction: String, Codable, Sendable, Hashable, CaseIterable {
    /// Length-prefixed, kind-tagged records over every contained entry, ordered by
    /// the UTF-8 bytes of the entry's path relative to the artifact root.
    ///
    /// The record for one entry is:
    ///
    /// ```text
    /// directory: 0x00 || u64be(pathByteCount) || pathUTF8
    /// file:      0x01 || u64be(pathByteCount) || pathUTF8
    ///                 || u64be(fileByteCount) || sha256(fileBytes)
    /// ```
    ///
    /// preceded once by `u64be(labelByteCount) || labelUTF8` for the construction
    /// label. Every variable-length field is length-prefixed and every record is
    /// kind-tagged, so two different trees cannot serialize to the same bytes:
    /// renaming, adding, or removing an entry — including an empty directory —
    /// changes the digest, and so does moving bytes between two files.
    case sortedKindTaggedRecords = "sorted-kind-tagged-records"

    /// Domain-separation label committed at the start of every tree digest.
    var label: String {
        switch self {
        case .sortedKindTaggedRecords:
            return "defaike.model-bundle.tree-digest.sorted-kind-tagged-records"
        }
    }
}

/// The approved statement binding the active policy's canonicalization profile to the
/// construction this build implements.
///
/// The policy carries a reference to the approved profile document, not the rule
/// itself, so nothing in the policy can tell a build which code path to run. This
/// value is that missing link, and it is an approved release input for the same
/// reason the profile is: an implementation claiming to match a profile is a claim
/// somebody has to sign off on. Presence is not approval, so the record carries the
/// decision.
public struct ApprovedCanonicalizationProfile: Hashable, Sendable {
    /// The profile document. Must equal the active policy's
    /// `canonicalizationProfile`, identity, version, and content digest alike.
    public let profile: EvidenceSource

    /// The construction this build runs for `directoryTree` artifacts.
    public let construction: BundleTreeDigestConstruction

    /// The decision that recorded the correspondence between the two.
    public let approval: ApprovalRecord

    public init(
        profile: EvidenceSource,
        construction: BundleTreeDigestConstruction,
        approval: ApprovalRecord
    ) {
        self.profile = profile
        self.construction = construction
        self.approval = approval
    }
}

/// Builds a deterministic digest over the members of one directory artifact.
enum BundleTreeDigest {
    /// One member of a directory artifact, already reduced to its identity.
    enum Member: Hashable, Sendable {
        /// A directory, at this path relative to the artifact root.
        case directory(relativePath: String)
        /// A file, with the bytes actually observed while streaming it.
        case file(relativePath: String, byteCount: UInt64, digest: DefAIkeDomain.SHA256Digest)

        var relativePath: String {
            switch self {
            case let .directory(path): return path
            case let .file(path, _, _): return path
            }
        }
    }

    /// Digests `members` under `construction`.
    ///
    /// Ordering is imposed here rather than assumed of the caller, so enumeration
    /// order cannot change the result.
    static func digest(
        of members: [Member],
        construction: BundleTreeDigestConstruction
    ) -> DefAIkeDomain.SHA256Digest {
        var hasher = StreamingSHA256()
        hasher.update(lengthPrefixed(Array(construction.label.utf8)))
        let ordered = members.sorted {
            $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
        }
        for member in ordered {
            switch member {
            case let .directory(relativePath):
                hasher.update([0x00])
                hasher.update(lengthPrefixed(Array(relativePath.utf8)))
            case let .file(relativePath, byteCount, digest):
                hasher.update([0x01])
                hasher.update(lengthPrefixed(Array(relativePath.utf8)))
                hasher.update(bigEndian(byteCount))
                hasher.update(digest.bytes)
            }
        }
        return hasher.finalize()
    }

    private static func lengthPrefixed(_ bytes: [UInt8]) -> [UInt8] {
        bigEndian(UInt64(bytes.count)) + bytes
    }

    private static func bigEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * UInt64($0))) }
    }
}
