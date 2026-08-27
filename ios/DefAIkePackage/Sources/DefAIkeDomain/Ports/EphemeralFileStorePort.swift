import Foundation

// The file-store port: the only way domain logic reaches persisted bytes.
//
// Every byte DefAIke retains lives in a protected, app-controlled, ephemeral
// location owned by the Privacy Controller (Requirements 9.1 and 9.6). Domain and
// application logic address those locations through opaque keys and never through
// file-system paths, so:
//
//   * no user-derived file name, asset identifier, or provider path can enter a
//     domain value or a log (Requirement 9.11);
//   * a traversal or absolute path is not representable at this boundary; and
//   * every property that touches storage can run against a bounded in-memory fake
//     with no file system, which is what the design's "deterministic in-memory
//     ports" testing rule requires.
//
// The port deliberately has no move, copy, enumerate-all, or "temporary directory"
// member: a caller can only create, append to, finalize, read, delete, and list one
// scope it names.

/// An opaque, app-controlled name for one stored ephemeral object.
///
/// Keys are random and non-user-derived: the design requires provider files to be
/// copied into "random app-controlled locations". A key names a location; it says
/// nothing about the bytes, and it is never shown to a user.
public struct EphemeralStorageKey: CanonicalIdentifier {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard CanonicalIdentifierSyntax.isCanonical(
            rawValue,
            maximumCharacterCount: Self.maximumCharacterCount
        ) else {
            return nil
        }
        self.rawValue = rawValue
    }
}

/// Which lifecycle-owned area a stored object belongs to.
///
/// The scope decides who deletes the object and under which deadline. Session
/// material is removed when its session ends; transfer material follows the
/// `staging` → `ready` → `claimed` progression of the Shared Transfer Store. A
/// stored object always belongs to exactly one scope, so nothing is unowned and
/// cleanup can prove an empty ownership set (Property 25).
public enum EphemeralStorageScope: Hashable, Codable, Sendable {
    /// Material owned by one Analysis Session.
    case session(AnalysisSessionID)
    /// Material owned by one Share transfer in one of its three states.
    case transfer(ShareTransferID, TransferSlotState)
}

/// Why a store operation could not complete.
///
/// Store faults are distinct from ``AnalysisError``: how a storage failure maps to a
/// user-facing category depends on where it happened, so the mapping belongs to the
/// caller's stage rather than to the store. Nothing here is presentable to a user.
public enum EphemeralStoreError: Error, Hashable, Sendable {
    /// No object exists under this key.
    case notFound(EphemeralStorageKey)
    /// The key is already in use, so a create would overwrite existing bytes.
    case keyAlreadyInUse(EphemeralStorageKey)
    /// The object exists but has not been finalized, so its bytes are incomplete.
    case notFinalized(EphemeralStorageKey)
    /// The object is finalized and immutable; appending would change analyzed bytes.
    case alreadyFinalized(EphemeralStorageKey)
    /// Continuing would exceed the store's bounded capacity. The caller decides
    /// whether that is a `resource-limit` outcome for its stage.
    case capacityExceeded(scope: EphemeralStorageScope)
    /// The required iOS data-protection level could not be applied. Fail closed:
    /// unprotected bytes are not an acceptable fallback (Requirement 9.6).
    case protectionUnavailable(FileProtectionLevel)
    /// The underlying store failed for a reason the adapter could not classify.
    /// Carries no path, no user content, and no framework error payload.
    case storeUnavailable
}

/// What a finalized object is, as measured while it was written.
///
/// The digest and byte count are computed by the adapter during the single streaming
/// pass, never by re-reading the object afterwards, so a retained-byte identity
/// check compares what was actually written (Requirements 2.9 through 2.13).
public struct EphemeralWriteReceipt: Hashable, Sendable {
    public let key: EphemeralStorageKey
    public let scope: EphemeralStorageScope
    public let byteCount: UInt64
    public let sha256: SHA256Digest
    /// The iOS data-protection level actually applied.
    public let protection: FileProtectionLevel

    public init(
        key: EphemeralStorageKey,
        scope: EphemeralStorageScope,
        byteCount: UInt64,
        sha256: SHA256Digest,
        protection: FileProtectionLevel
    ) {
        self.key = key
        self.scope = scope
        self.byteCount = byteCount
        self.sha256 = sha256
        self.protection = protection
    }
}

/// Proof that one scope's material no longer exists.
///
/// The Privacy Controller keeps receipts so a later start can tell "already deleted"
/// from "abandoned with no terminal deletion" (Requirement 11.16). A receipt records
/// how many objects were removed, which is zero on a repeated deletion: cleanup is
/// idempotent, so a second call is a success with nothing left to remove.
public struct EphemeralDeletionReceipt: Hashable, Sendable {
    public let scope: EphemeralStorageScope
    public let reason: SessionCleanupReason
    public let removedObjectCount: Int
    /// Wall-clock instant the deletion completed, for deadline auditing only.
    public let completedAt: Date

    public init(
        scope: EphemeralStorageScope,
        reason: SessionCleanupReason,
        removedObjectCount: Int,
        completedAt: Date
    ) {
        self.scope = scope
        self.reason = reason
        self.removedObjectCount = removedObjectCount
        self.completedAt = completedAt
    }
}

/// Protected, bounded, scope-owned storage for ephemeral analysis bytes.
///
/// Writing is a three-step streaming sequence — ``create(in:protection:)``, one or
/// more ``append(_:to:)`` calls, then ``finalize(_:)`` — because a provider
/// representation is copied chunk by chunk while its digest is computed, and because
/// an interrupted copy must be distinguishable from a complete one. An object that
/// was created and never finalized is never readable, so a partial copy cannot be
/// analyzed or promoted (design, Shared Transfer Store).
public protocol EphemeralFileStoring: Sendable {
    /// Creates one empty object under a fresh random key in `scope`.
    ///
    /// The store chooses the key; a caller cannot name a location, which is what
    /// keeps locations non-user-derived.
    func create(
        in scope: EphemeralStorageScope,
        protection: FileProtectionLevel
    ) async throws(EphemeralStoreError) -> EphemeralStorageKey

    /// Appends the next chunk of an unfinalized object.
    ///
    /// Chunk boundaries never affect the finalized bytes or digest, so an arbitrary
    /// partition of the same byte sequence yields the same receipt (Property 5).
    func append(
        _ chunk: [UInt8],
        to key: EphemeralStorageKey
    ) async throws(EphemeralStoreError) -> Void

    /// Closes an object and reports its measured byte count and digest.
    func finalize(
        _ key: EphemeralStorageKey
    ) async throws(EphemeralStoreError) -> EphemeralWriteReceipt

    /// Reads a finalized object's bytes.
    ///
    /// Reading an unfinalized object is ``EphemeralStoreError/notFinalized(_:)``.
    func read(_ key: EphemeralStorageKey) async throws(EphemeralStoreError) -> [UInt8]

    /// The receipt for a finalized object, or `nil` when it does not exist or has
    /// not been finalized.
    func receipt(for key: EphemeralStorageKey) async -> EphemeralWriteReceipt?

    /// Moves one finalized object into another scope, atomically.
    ///
    /// This is the only way a stored object changes owner. It is how a Share
    /// transfer goes `staging` → `ready` → `claimed`: an observer sees the object in
    /// exactly one scope, never in both and never in neither.
    func move(
        _ key: EphemeralStorageKey,
        to scope: EphemeralStorageScope
    ) async throws(EphemeralStoreError) -> Void

    /// Keys currently owned by `scope`, finalized or not.
    func keys(in scope: EphemeralStorageScope) async -> Set<EphemeralStorageKey>

    /// Removes everything `scope` owns and returns a receipt.
    ///
    /// Idempotent by contract: deleting an already-empty scope succeeds with a zero
    /// removed count rather than failing, so repeated cleanup and cleanup after an
    /// interruption behave identically (Property 25).
    func deleteAll(
        in scope: EphemeralStorageScope,
        reason: SessionCleanupReason
    ) async throws(EphemeralStoreError) -> EphemeralDeletionReceipt

    /// Every scope that currently owns at least one object.
    ///
    /// Startup cleanup uses this to find material left behind by an interrupted
    /// process before accepting new work (Requirement 11.16).
    func occupiedScopes() async -> Set<EphemeralStorageScope>
}
