import DefAIkeDomain
import Foundation

// The bounded record whose arrival under `ready` is the publication commit.
//
// A ``ShareTransferTicket`` says everything the claiming process reverifies, but it does
// not say *where* the staged bytes are: the payload lives in the ephemeral store under a
// random key the store assigns, and the ticket schema deliberately carries no storage
// location. The manifest is the store's own envelope that joins the two, and it exists
// for three reasons:
//
//   * **One rename commits a publication.** The payload object and the manifest object
//     each own a directory, so promoting a transfer is two renames rather than one. The
//     manifest's rename is defined as the commit: the payload moves into `ready` first,
//     and the transfer only becomes a published `AwaitingMainApp` session when the
//     manifest lands beside it. A payload in `ready` with no manifest is therefore an
//     interrupted publication that resolves to nothing and is cleaned up, never a session
//     with missing bytes (design, Share Extension handoff sequence).
//   * **The manifest is identifiable without guessing.** It names its own key, and its key
//     is 128 random bits the store assigns *after* the payload bytes are fixed. A payload
//     therefore cannot name the key it will be stored under, so "the object that names
//     itself" identifies the manifest without inspecting image bytes for JSON.
//   * **The encoding is bounded before it is read.** The manifest crosses a process
//     boundary, so it is validated against ``ArtifactEncodingProfile`` — byte ceiling,
//     UTF-8 validity, duplicate keys, nesting, and structural ceilings — before a single
//     field is decoded. Duplicate keys matter as much here as they do for a signed
//     artifact: without that check the same bytes could read as two different tickets in
//     the two processes, and the byte-identity comparison would stop meaning anything.
//
// The manifest is internal on purpose. It is an on-disk format, not a domain value: the
// public surface is ``ShareTransferTicket`` and ``ReadyTransfer``.

/// The store-owned envelope published beside the staged bytes.
struct TransferManifest: Hashable, Sendable {
    /// The only envelope version this build reads or writes.
    ///
    /// Separate from ``ShareTransferTicket/currentSchemaVersion``: the ticket schema is
    /// the cross-process contract the requirements name, and the envelope version
    /// describes how this store lays that ticket out on disk. Bumping one must not
    /// silently imply the other.
    static let currentSchemaVersion = 1

    let schemaVersion: Int

    /// The ticket the claiming process reverifies.
    let ticket: ShareTransferTicket

    /// The object this manifest is itself stored in.
    ///
    /// Self-naming, which is what makes the manifest identifiable inside a transfer slot
    /// without trusting the payload's contents.
    let manifestKey: EphemeralStorageKey

    /// The object holding the exact staged encoded bytes.
    let payloadKey: EphemeralStorageKey

    /// Creates a manifest, or `nil` when it is internally inconsistent.
    ///
    /// Rejects an unreadable envelope version and a manifest that names itself as its own
    /// payload. The second one is not hypothetical bookkeeping: a manifest that pointed at
    /// itself would resolve to a "payload" whose bytes are the manifest, and the byte count
    /// and digest comparison would then be comparing the record against itself.
    init?(
        schemaVersion: Int = TransferManifest.currentSchemaVersion,
        ticket: ShareTransferTicket,
        manifestKey: EphemeralStorageKey,
        payloadKey: EphemeralStorageKey
    ) {
        guard schemaVersion == Self.currentSchemaVersion else { return nil }
        guard manifestKey != payloadKey else { return nil }
        self.schemaVersion = schemaVersion
        self.ticket = ticket
        self.manifestKey = manifestKey
        self.payloadKey = payloadKey
    }

    /// The transfer this manifest belongs to.
    var transferID: ShareTransferID { ticket.transferID }

    /// The published transfer this manifest describes.
    var readyTransfer: ReadyTransfer {
        ReadyTransfer(ticket: ticket, storageKey: payloadKey)
    }
}

// MARK: - Coding

extension TransferManifest: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, ticket, manifestKey, payloadKey
    }

    /// Decodes a manifest and revalidates every invariant.
    ///
    /// Fail-closed in the same shape as ``ShareTransferTicket/init(from:)``: an unreadable
    /// envelope version or a self-referential payload key is a decoding failure, never a
    /// repaired value. The ticket nested inside revalidates its own invariants, so a
    /// tampered schema version, route, empty payload, or status-and-basis disagreement is
    /// refused here rather than by a hand-written comparison the claim path might forget.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let manifest = TransferManifest(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            ticket: try container.decode(ShareTransferTicket.self, forKey: .ticket),
            manifestKey: try container.decode(EphemeralStorageKey.self, forKey: .manifestKey),
            payloadKey: try container.decode(EphemeralStorageKey.self, forKey: .payloadKey)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: CodingKeys.schemaVersion,
                in: container,
                debugDescription: """
                    A transfer manifest must use envelope version \
                    \(Self.currentSchemaVersion) and must not name itself as its own \
                    payload.
                    """
            )
        }
        self = manifest
    }
}

/// Why a manifest could not be encoded or decoded.
///
/// Separate from ``TransferStoreError`` because the two happen at different moments: an
/// encoding fault means nothing was published, and a decoding fault means published
/// material cannot be resolved. The store maps each to its own outcome.
enum TransferManifestCodingFault: Error, Equatable, Sendable {
    /// The encoded manifest is larger than the structural ceiling.
    case tooLarge(limitBytes: UInt64, actualBytes: UInt64)

    /// The manifest could not be encoded at all.
    case notEncodable

    /// The bytes are not a readable bounded manifest.
    case unreadable(ArtifactDecodingError)
}

/// Bounded encoding and decoding for the published manifest.
enum TransferManifestCoding {
    /// Structural ceiling on one encoded manifest, in bytes.
    ///
    /// A safety ceiling in the same sense as
    /// ``CanonicalIdentifierSyntax/defaultMaximumCharacterCount``, **not** an approved
    /// release value: it expresses no budget, deadline, or gate decision, and no artifact
    /// owns it. It is derived from the schema's own bounds rather than chosen freely — a
    /// maximal manifest holds three canonical identifiers at 256 characters, one
    /// content-type hint at 128, one digest at 64, two storage keys at 32, a byte count, a
    /// timestamp, two schema versions, and four closed-vocabulary words, which is roughly
    /// 1,800 bytes with JSON punctuation and key names. Twice that leaves room for the
    /// escaping of every identifier character without leaving room for an unbounded
    /// payload, and `TransferManifestTests` pins the derivation by encoding a manifest
    /// whose every field is at its ceiling.
    static let maximumEncodedByteCount: UInt64 = 4_096

    /// The bounded encoding profile a published manifest is read under.
    ///
    /// The structural bounds are tightened from the artifact defaults to what this
    /// envelope actually contains: two object levels, a dozen members, and strings that
    /// are all identifiers, digests, hints, or closed-vocabulary words. A payload that
    /// needs more than that is not this manifest.
    private static let limits: ArtifactEncodingLimits = {
        guard let ceiling = try? PositiveByteCount(validating: maximumEncodedByteCount) else {
            // Unreachable: the ceiling above is a positive literal. Reaching it would mean
            // a bound of zero, under which every manifest is unreadable.
            preconditionFailure("the manifest ceiling must be a positive byte count")
        }
        return ArtifactEncodingLimits(
            maximumByteCount: ceiling,
            maximumNestingDepth: 4,
            maximumObjectEntryCount: 32,
            maximumArrayElementCount: 1,
            maximumStringScalarCount: CanonicalIdentifierSyntax.defaultMaximumCharacterCount
        )
    }()

    /// Encodes a manifest, or fails when it does not fit the bounded profile.
    ///
    /// The encoded bytes are validated against the same profile the reader uses, so a
    /// manifest this store writes is one this store can read back. Publishing bytes that
    /// only the writer can interpret would turn a claim into a `handoff-error` for a
    /// transfer that was never at fault.
    static func encode(
        _ manifest: TransferManifest
    ) throws(TransferManifestCodingFault) -> [UInt8] {
        let encoder = JSONEncoder()
        // Deterministic key order and unescaped solidi: a canonical identifier may contain
        // `/`, and escaping it would make the same manifest encode two ways.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // No date strategy is set on purpose. The default encodes `createdAt` as the exact
        // `Date` representation the domain's own `Codable` conformance uses, so a ticket
        // round-trips identically; an ISO-8601 strategy would silently truncate to whole
        // seconds and a ticket read back would not equal the ticket that was published.
        guard let data = try? encoder.encode(manifest) else { throw .notEncodable }
        let bytes = Array(data)
        guard UInt64(bytes.count) <= maximumEncodedByteCount else {
            throw .tooLarge(
                limitBytes: maximumEncodedByteCount,
                actualBytes: UInt64(bytes.count)
            )
        }
        return bytes
    }

    /// Validates the bounded profile, then decodes a manifest.
    ///
    /// Two passes, in this order: the profile bounds the payload, rejects duplicate keys,
    /// and refuses unbounded nesting before anything is allocated per field; then the
    /// manifest and the ticket inside it revalidate their own invariants.
    static func decode(
        _ bytes: [UInt8]
    ) throws(TransferManifestCodingFault) -> TransferManifest {
        do {
            _ = try ArtifactEncodingProfile.validate(bytes, limits: limits)
        } catch {
            throw .unreadable(error)
        }
        do {
            return try JSONDecoder().decode(TransferManifest.self, from: Data(bytes))
        } catch {
            throw .unreadable(ArtifactDecodingError.from(error))
        }
    }
}
