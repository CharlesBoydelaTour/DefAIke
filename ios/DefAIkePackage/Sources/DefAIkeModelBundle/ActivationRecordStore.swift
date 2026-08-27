import DefAIkeDomain

// The one thing step 7 reaches out for: durable storage for receipts and the active
// pointer.
//
// The design fixes the mechanism rather than leaving it to an adapter's judgement: "The
// active pointer is written to a temporary file, synchronized, and atomically renamed."
// That is three separable operations, so this seam exposes three members rather than one
// `setActivePointer`. A single write-the-pointer member would make atomicity a promise an
// adapter makes in prose; separating stage, synchronize, and publish makes the ordering
// something the caller performs and a test can interrupt at each boundary.
//
// Two things are deliberately absent, and their absence is the requirement rather than a
// convention:
//
//   * No member takes a URL, a host, a session, or a remote catalogue, and none discovers,
//     fetches, or downloads a bundle. Bundles ship inside the application version, so
//     there is no update channel for one to travel over (Requirements 10.19 and 10.21).
//   * No member overwrites, edits, or deletes a persisted receipt. A receipt is the
//     immutable record of one verification run; the only way to change what is active is
//     to write a new receipt and publish a new pointer.

// MARK: - What is published

/// Names one activation the store has written and synchronized but not yet published.
///
/// Opaque and process-scoped, like every other adapter token: a staged activation is a
/// half-finished operation inside one store instance and must not cross a process or App
/// Group boundary.
public struct StagedActivationToken: OpaqueAdapterToken {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// Which locally installed Model Bundle is active, and which receipt authorized it.
///
/// Three fields, written and replaced as one value. That is what makes the pointer
/// atomically replaceable: there is no state in which the bundle identity has advanced
/// but the receipt it was verified by has not (Requirement 10.13).
///
/// The pointer names a receipt; it does not carry a verification outcome of its own. A
/// published pointer is therefore a record of what happened, never a claim that the bundle
/// it names may be used now — that answer comes from a completed verification run.
public struct ActiveBundlePointer: Hashable, Codable, Sendable {
    public let bundleID: ModelBundleID

    /// The receipt this activation wrote. Persisted before the pointer that names it.
    public let receiptID: ArtifactID

    /// Monotonic across published activations, so two activations are distinguishable.
    public let activationGeneration: PositiveCount

    public init(
        bundleID: ModelBundleID,
        receiptID: ArtifactID,
        activationGeneration: PositiveCount
    ) {
        self.bundleID = bundleID
        self.receiptID = receiptID
        self.activationGeneration = activationGeneration
    }

    /// The pointer one receipt authorizes.
    ///
    /// Derived rather than assembled by a caller, so a pointer cannot name one bundle while
    /// citing a receipt for another.
    public init(receipt: ActivationReceipt) {
        self.init(
            bundleID: receipt.bundleID,
            receiptID: receipt.id,
            activationGeneration: receipt.activationGeneration
        )
    }
}

// MARK: - Why the store refused

/// Why the activation record store could not complete one operation.
///
/// Five structural outcomes, no framework error and no absolute path. Which verification
/// finding each becomes depends on the step that was running, so the mapping belongs to the
/// activator rather than to the store — with one exception: ``receiptConflict`` means the
/// same thing wherever it happens, because it is the store refusing to let an immutable
/// record change.
public enum ActivationStoreFault: Error, Equatable, Sendable {
    /// The store is unavailable, or its published pointer could not be read or decoded.
    case storeUnavailable

    /// A different receipt already exists under that identifier.
    ///
    /// Never returned for a byte-identical rewrite: persisting the same receipt again is
    /// how a retry after an interrupted publish succeeds, and it changes nothing.
    case receiptConflict

    /// The write did not complete.
    case writeFailed

    /// Staged bytes did not reach stable storage.
    case synchronizationFailed

    /// The atomic replacement of the published pointer did not complete.
    case replacementFailed
}

// MARK: - The seam

/// Persists immutable activation receipts and publishes the active bundle pointer.
///
/// The contract an implementation owes its caller, in the order the activator relies on it:
///
///   * ``persistReceipt(_:)`` returns only once the receipt is durable. The pointer that
///     names it is published afterwards, so a pointer can never reference a receipt that
///     has not reached stable storage.
///   * ``persistReceipt(_:)`` writes an identifier once. A byte-identical rewrite succeeds
///     and changes nothing; a different receipt under an existing identifier is
///     ``ActivationStoreFault/receiptConflict``. Immutability is "these bytes never change",
///     not "this call may only happen once".
///   * ``stage(_:)`` writes the pointer somewhere the published pointer cannot be reached
///     from, and publishes nothing.
///   * ``publish(_:)`` replaces the published pointer with the staged one in a single
///     atomic operation. It never reads the published pointer, modifies it, and writes it
///     back, because a reader interleaved with that sequence could observe a partial value.
///   * ``discard(_:)`` is idempotent and non-failing, so every exit path from an
///     interrupted activation can drop its staged state unconditionally.
///
/// Deliberately absent: any member that mutates or removes a published receipt, any member
/// that writes the published pointer other than by replacing it wholesale, and any member
/// that reaches a network.
public protocol ActivationRecordStoring: Sendable {
    /// The published pointer, or `nil` on a clean install where nothing has been activated.
    ///
    /// `nil` and a fault are different answers: "nothing is active yet" is a normal state,
    /// while an unreadable or malformed pointer is a refusal.
    func activePointer() async throws(ActivationStoreFault) -> ActiveBundlePointer?

    /// The receipt persisted under one identifier, or `nil` when none is.
    func receipt(
        _ id: ArtifactID
    ) async throws(ActivationStoreFault) -> ActivationReceipt?

    /// Persists one receipt durably and immutably.
    func persistReceipt(_ receipt: ActivationReceipt) async throws(ActivationStoreFault)

    /// Writes `pointer` to a staging location, publishing nothing.
    func stage(
        _ pointer: ActiveBundlePointer
    ) async throws(ActivationStoreFault) -> StagedActivationToken

    /// Flushes staged bytes to stable storage.
    func synchronize(_ staged: StagedActivationToken) async throws(ActivationStoreFault)

    /// Atomically replaces the published pointer with the staged one.
    func publish(_ staged: StagedActivationToken) async throws(ActivationStoreFault)

    /// Drops staged state that will not be published.
    func discard(_ staged: StagedActivationToken) async
}
