import DefAIkeDomain
import Foundation

// The coordinated App Group transfer store.
//
// This is the minimal cross-process surface between the Share Extension and the main app.
// It moves one image's encoded bytes and one bounded ticket, and nothing else: no evidence,
// no decoded pixels, no model input, no model output, and no shared database (design,
// Shared Transfer Store).
//
// The whole component exists to make one sentence true: **successful atomic
// `staging → ready` publication is the sole Share-route session-creation commit.** Three
// rules follow from it, and each is structural here rather than a convention:
//
//   * There is no intermediate value a caller can hold between staging and publication.
//     ``publishTransfer(ofFileAt:consent:sessionID:basis:)`` either returns a ticket — which
//     means exactly one pending `AwaitingMainApp` session now exists — or throws and leaves
//     nothing behind. A decline, cancellation, provider failure, resource breach, or
//     interruption before the commit therefore cannot create a session, because there was
//     never a half-published slot to inherit (Requirements 2.4, 11.8, and 11.11).
//   * The commit is one rename. A transfer's payload and manifest each own a directory, so
//     promotion is two renames; the manifest's rename into `ready` is defined as the commit
//     and the payload's rename precedes it. An interrupted publication leaves a payload no
//     manifest names, which resolves to nothing and is cleaned up.
//   * Claim changes ownership without changing identity. The claim commit is the mirror
//     image — the manifest's rename *out of* `ready` — and the ticket, including its
//     ``AnalysisSessionID``, is carried through untouched (Requirements 2.3 and 11.12).
//
// Cross-process coordination is the atomic directory rename itself, which the design
// permits as a validated equivalent to `NSFileCoordinator`. Two processes cannot both
// promote or both claim the same slot: the rename that wins moves the source away, and the
// one that loses observes an absent source and reports an empty slot rather than a second
// commit. That choice still owes physical-device validation, like the protection level it
// sits beside; a host result is not evidence for either.
//
// Nothing here reaches inference, provenance, image-pipeline, or model-bundle code, which
// is what keeps the module shippable inside the extension.

/// Why a transfer-store operation did not complete.
///
/// Deliberately not an ``AnalysisError``. How a transfer failure is reported depends on
/// which side observed it: a resource breach while staging is `resource-limit` for the
/// extension, an unresolvable ready slot is `handoff-error` for the main app, and a pending
/// handoff is a recovery instruction rather than a failure at all. The two ingest adapters
/// own that mapping (tasks 4.4 and 4.5); this type only reports what happened.
public enum TransferStoreError: Error, Hashable, Sendable {
    /// A nonexpired published transfer already exists, so nothing was published.
    ///
    /// The single ready-slot rule: while a pending handoff the user already consented to is
    /// waiting, a later invocation presents a recovery instruction to open or discard it
    /// rather than replacing it silently (design, Share Extension handoff sequence).
    case pendingHandoffExists(ShareTransferID)

    /// Staging failed before the commit. No session and no ready material exist.
    case stagingFailed(EncodedAssetRetentionError)

    /// The assembled manifest does not fit the bounded encoding, so nothing was published.
    case manifestTooLarge(limitBytes: UInt64, actualBytes: UInt64)

    /// The assembled ticket or manifest is internally inconsistent, so nothing was
    /// published.
    ///
    /// Unreachable in practice: the store derives every ticket field from what it measured
    /// or from an approved artifact. It fails closed rather than publishing a ticket the
    /// claiming process would be obliged to reject.
    case ticketRejected

    /// The underlying store refused or failed. Carries no path and no user content.
    case store(EphemeralStoreError)
}

/// Why published material cannot be resumed.
///
/// Every case means the same thing to a user — there is no usable pending handoff — and
/// different things to an audit, which is why they are distinct.
public enum UnusableReadySlotReason: Hashable, Sendable {
    /// More than one ready slot exists, so no pending handoff is unambiguous.
    ///
    /// The single ready-slot rule exists to prevent ambiguous multiple pending images, so
    /// the store refuses to choose between them rather than guessing which one the user
    /// meant. Cleanup removes them all and the user shares again.
    case ambiguousSlotCount(Int)

    /// The published transfer is past the deadline the active Data Lifecycle Policy sets
    /// for material with no terminal deletion (Requirements 9.9 and 11.16).
    ///
    /// Carries no session identifier on purpose. An expired pending handoff is discarded
    /// under the lifecycle policy, not reported as a failed analysis, so there is no
    /// session for the main app to resume and terminate.
    case expired(ShareTransferID)

    /// The publication or claim did not complete, so the slot is not one resolvable
    /// transfer.
    case defective(DefectiveTransfer)
}

/// A transfer slot that is present but not resumable.
public struct DefectiveTransfer: Hashable, Sendable {
    public let transferID: ShareTransferID

    /// The session the ticket named, when a ticket could be read at all.
    ///
    /// This is the difference between a publication that never committed and one that
    /// committed and then broke. `nil` means no readable ticket, so no session was ever
    /// created and there is nothing to terminate — the material is simply removed. A
    /// value means that session exists and the main app has to resume exactly it in order
    /// to end it with `handoff-error` (Requirements 2.19 and 11.13).
    ///
    /// Only the session identifier is carried, never the ticket. A ticket from a broken
    /// slot has already failed verification, and nothing downstream may treat any other
    /// field of it as established.
    public let pendingSession: AnalysisSessionID?

    /// What is structurally wrong with the slot.
    public let defect: PublicationDefect

    public init(
        transferID: ShareTransferID,
        pendingSession: AnalysisSessionID?,
        defect: PublicationDefect
    ) {
        self.transferID = transferID
        self.pendingSession = pendingSession
        self.defect = defect
    }
}

/// What is structurally wrong with a transfer slot.
public enum PublicationDefect: String, Hashable, Sendable, CaseIterable {
    /// No object in the slot resolves as its own manifest.
    ///
    /// Absent, truncated, oversized, and unreadable manifests are one finding: the
    /// publication did not complete. A payload alone is never a session.
    case manifestMissing = "manifest-missing"

    /// More than one object in the slot resolves as a manifest.
    case manifestAmbiguous = "manifest-ambiguous"

    /// The manifest names a payload the slot does not own.
    case payloadMissing = "payload-missing"

    /// The named payload exists but was never finalized, so its bytes are incomplete.
    case payloadIncomplete = "payload-incomplete"

    /// The stored payload's measured byte count or digest disagrees with the ticket.
    ///
    /// The measurements were taken during the single streaming write, so a disagreement
    /// means the ticket and the bytes are not describing the same object. Nothing is
    /// resumed from it (Requirements 2.19 and 11.13).
    case measurementMismatch = "measurement-mismatch"
}

/// What the one ready slot currently holds.
public enum ReadySlotState: Hashable, Sendable {
    /// Nothing is published. There is no pending Share session.
    case empty

    /// Exactly one published transfer is awaiting the main app.
    case published(ReadyTransfer)

    /// Material exists but is not one resumable published transfer.
    case unusable(UnusableReadySlotReason)

    /// The published transfer, or `nil` in every other state.
    public var publishedTransfer: ReadyTransfer? {
        guard case .published(let transfer) = self else { return nil }
        return transfer
    }
}

/// One transfer this process now owns.
///
/// The claim moved ownership; it did not change the ticket. The session identifier the
/// extension allocated while staging is the identifier the main app resumes under
/// (Requirements 2.3 and 11.12).
public struct ClaimedTransfer: Hashable, Sendable {
    public let ticket: ShareTransferTicket

    /// The finalized, protected object holding the exact staged bytes, now owned by the
    /// `claimed` state.
    public let payloadKey: EphemeralStorageKey

    public init(ticket: ShareTransferTicket, payloadKey: EphemeralStorageKey) {
        self.ticket = ticket
        self.payloadKey = payloadKey
    }

    public var transferID: ShareTransferID { ticket.transferID }

    /// The pending session this transfer carries, unchanged by the claim.
    public var sessionID: AnalysisSessionID { ticket.sessionID }

    /// The scope that owns the claimed bytes.
    public var scope: EphemeralStorageScope { .transfer(ticket.transferID, .claimed) }
}

/// The result of one claim attempt.
///
/// Three outcomes, because they lead to three different places: nothing to resume, one
/// session to resume, and one failed handoff to report. An `Optional` would collapse the
/// first and the last, and "no pending image" must never be presented as the
/// `handoff-error` a mismatch produces.
public enum ClaimOutcome: Hashable, Sendable {
    /// The ready slot was empty. No session is pending.
    case nothingToClaim

    /// The published transfer is now owned by this process.
    case claimed(ClaimedTransfer)

    /// Material existed but could not be claimed. It has been removed.
    case rejected(UnusableReadySlotReason)
}

/// What startup cleanup removed, and what survived it.
public struct StartupCleanupReport: Hashable, Sendable {
    /// One receipt per scope that actually held something.
    public let receipts: [EphemeralDeletionReceipt]

    /// The published transfer cleanup deliberately kept, if any.
    ///
    /// A committed pending handoff is a session the user already consented to, so it
    /// survives a restart until its lifecycle deadline passes. `staging` and `claimed`
    /// material never survives: a restart is proof that the process holding it was
    /// interrupted.
    public let retainedTransfer: ShareTransferID?

    public init(receipts: [EphemeralDeletionReceipt], retainedTransfer: ShareTransferID?) {
        self.receipts = receipts
        self.retainedTransfer = retainedTransfer
    }

    /// Total objects removed across every scope.
    public var removedObjectCount: Int {
        receipts.reduce(0) { $0 + $1.removedObjectCount }
    }
}

// MARK: - The store

/// The `staging` → `ready` → `claimed` transfer protocol over protected App Group storage.
///
/// An actor, because the ready slot is a single-occupancy resource and the invariant that
/// protects it is read-then-act. Serializing within a process is not enough on its own —
/// the extension and the app are different processes — which is why the commit is also an
/// atomic rename.
///
/// Every deadline and every protection level is injected as an approved artifact value.
/// There is no compiled-in expiry, no default protection level, and no way for a caller to
/// ask for silent replacement of a pending handoff.
public actor SharedTransferStore {

    private let store: any EphemeralFileStoring
    private let retainer: EncodedAssetRetainer
    private let lifecyclePolicy: DataLifecyclePolicy
    private let extensionPolicy: ExtensionExecutionPolicy
    private let buildID: AppBuildID
    private let clock: any SessionClock

    /// Creates a transfer store over `store`.
    ///
    /// - Parameters:
    ///   - store: Protected ephemeral storage rooted in the registered App Group
    ///     container. The store owns only ``EphemeralStorageScope/transfer(_:_:)`` scopes
    ///     inside it and never touches session material, so the same underlying store can
    ///     serve both without one lifecycle deleting the other's bytes.
    ///   - lifecyclePolicy: The versioned Data Lifecycle Policy. Its deadlines decide when
    ///     a pending handoff has expired and are the only source of that number.
    ///   - extensionPolicy: The versioned Extension Execution Policy. It fixes the staged
    ///     file-protection level and forbids silent replacement of a pending handoff.
    ///   - buildID: This build's identity, recorded in every ticket this store publishes so
    ///     two installed compositions cannot exchange tickets (Requirement 2.19).
    ///   - clock: Wall-clock readings for ticket timestamps and deadline evaluation.
    ///   - chunkSizeInBytes: I/O buffer size for the streaming copy. A structural bound; it
    ///     changes how many passes a copy takes, never how large a copy may be.
    public init(
        store: any EphemeralFileStoring,
        lifecyclePolicy: DataLifecyclePolicy,
        extensionPolicy: ExtensionExecutionPolicy,
        buildID: AppBuildID,
        clock: any SessionClock = SystemSessionClock(),
        chunkSizeInBytes: Int = EncodedAssetRetainer.defaultChunkSizeInBytes
    ) {
        self.store = store
        self.retainer = EncodedAssetRetainer(store: store, chunkSizeInBytes: chunkSizeInBytes)
        self.lifecyclePolicy = lifecyclePolicy
        self.extensionPolicy = extensionPolicy
        self.buildID = buildID
        self.clock = clock
    }

    /// The data-protection level staged and published material is created with.
    ///
    /// Read from the Extension Execution Policy rather than chosen here: the design
    /// defaults to complete protection unless physical-device validation shows a supported
    /// handoff lifecycle needs a different level, and records that choice in the policy.
    public var stagedFileProtection: FileProtectionLevel {
        extensionPolicy.stagedFileProtection
    }

    /// The Extension Execution Policy version this store is bound to.
    ///
    /// Published so an ingest adapter can check a consent token against the policy that
    /// actually governs this store rather than against a second copy of the artifact it was
    /// handed separately. One bound value, one place to read it (Requirement 11.9).
    public var extensionExecutionPolicyID: ArtifactID { extensionPolicy.id }

    /// The Data Lifecycle Policy version this store's deadlines come from.
    ///
    /// Published for the same reason: a cleanup asked to run under a different policy
    /// version would be audited against a deadline that never governed the material.
    public var dataLifecyclePolicyID: ArtifactID { lifecyclePolicy.id }

    // MARK: - Startup cleanup

    /// Removes transfer material an interrupted process left behind, before this process
    /// accepts work.
    ///
    /// Both processes run this at startup (design, Shared Transfer Store). What survives is
    /// exactly one thing: a published transfer whose lifecycle deadline has not passed.
    /// Everything else goes, because a restart is evidence that whoever owned it was
    /// interrupted:
    ///
    /// | Found | Removed under | Why |
    /// |---|---|---|
    /// | `staging` | interrupted-session deadline | Staging is never promoted after an interruption |
    /// | `claimed` | interrupted-session deadline | The claiming session cannot be resumed from it |
    /// | `ready`, unresolvable or expired | abandoned-session deadline | Not a resumable session |
    /// | `ready`, resolvable and current | *kept* | A consented pending handoff |
    ///
    /// The reason on each receipt selects which approved deadline the removal is audited
    /// against; the removal itself is immediate in every case. Idempotent: a second run
    /// removes nothing and still succeeds (Requirements 9.9 and 11.16).
    ///
    /// This also sweeps the emptied slot directories a successful publication or claim
    /// leaves behind. Those hold no objects — the material was renamed out of them — so
    /// they are structural residue rather than retained data, and every state of every
    /// transfer this cleanup can see is removed rather than only the states that still hold
    /// something.
    @discardableResult
    public func runStartupCleanup() async throws(TransferStoreError) -> StartupCleanupReport {
        let resolved = try await resolveReadySlot()
        let retained: ShareTransferID?
        if case .published(let manifest) = resolved {
            retained = manifest.transferID
        } else {
            retained = nil
        }

        var receipts: [EphemeralDeletionReceipt] = []
        for transfer in try await transferIdentifiers() {
            for state in TransferSlotState.allCases {
                if transfer == retained, state == .ready { continue }
                // A ready slot that is not being kept is material with no terminal
                // deletion receipt; staging and claimed residue is an interruption.
                let reason: SessionCleanupReason = state == .ready ? .abandoned : .interrupted
                let receipt = try await delete(.transfer(transfer, state), reason: reason)
                if receipt.removedObjectCount > 0 { receipts.append(receipt) }
            }
        }
        return StartupCleanupReport(receipts: receipts, retainedTransfer: retained)
    }

    // MARK: - Inspection

    /// What the ready slot holds, without claiming it.
    ///
    /// Peeking is how the app decides whether a pending session exists at all, and how the
    /// extension decides whether to present the recovery instruction instead of staging a
    /// second image. It takes no ownership, so calling it twice is the same as calling it
    /// once.
    public func readySlotState() async throws(TransferStoreError) -> ReadySlotState {
        try await resolveReadySlot().state
    }

    // MARK: - Publication

    /// Streams the consented representation into `staging` and publishes it as exactly one
    /// ready transfer.
    ///
    /// This is the Share route's session-creation commit and the only one. Returning a
    /// ticket means one pending `AwaitingMainApp` session exists; throwing means none does
    /// and nothing was left on disk.
    ///
    /// A ``ConfirmedConsent`` is required, so the store cannot read a byte before the user's
    /// visible action, and the recorded content-type hint is the one the consented provider
    /// declared rather than a free parameter (Requirements 2.2 and 11.10). The provider's
    /// temporary representation is read only; the copy is streamed and hashed in one pass,
    /// and the ticket's byte count and digest are what that pass measured.
    ///
    /// The ready slot is checked twice: once before any byte is written, so a pending
    /// handoff costs nothing to detect, and once immediately before the commit, so a
    /// handoff that became pending during the copy is still not replaced.
    ///
    /// - Parameters:
    ///   - source: The consented provider's temporary file. Never modified, moved, or
    ///     removed.
    ///   - consent: Proof of the visible consent action for exactly this provider.
    ///   - sessionID: The candidate session identifier the extension allocated. It has no
    ///     session semantics until this call returns successfully, and it is preserved
    ///     through claim.
    ///   - basis: The evidence for what the provider actually exposed. The recorded
    ///     ``BytePreservationStatus`` is the most conservative status that basis supports
    ///     and is not a parameter (Requirements 2.9 through 2.11).
    public func publishTransfer(
        ofFileAt source: URL,
        consent: ConfirmedConsent,
        sessionID: AnalysisSessionID,
        basis: PreservationBasis
    ) async throws(TransferStoreError) -> ShareTransferTicket {
        try await refuseOrClearReadySlot()

        let transferID = Self.makeTransferID()
        let staging = EphemeralStorageScope.transfer(transferID, .staging)

        let payload: EphemeralWriteReceipt
        do {
            payload = try await retainer.retainCopy(
                ofFileAt: source,
                into: staging,
                protection: extensionPolicy.stagedFileProtection
            )
        } catch {
            // The retainer already removed what it created. Discarding the whole transfer
            // as well keeps "a failed attempt leaves no state" true for every scope.
            await discardQuietly(transferID, reason: Self.cleanupReason(for: error))
            throw .stagingFailed(error)
        }

        guard let ticket = ShareTransferTicket(
            transferID: transferID,
            sessionID: sessionID,
            contentTypeHint: consent.provider.contentTypeHint,
            byteCount: payload.byteCount,
            sha256: payload.sha256,
            preservationStatus: basis.mostConservativeStatus,
            preservationBasis: basis,
            extensionBuildID: buildID,
            createdAt: clock.wallClockNow
        ) else {
            await discardQuietly(transferID, reason: .interrupted)
            throw .ticketRejected
        }

        let manifestKey: EphemeralStorageKey
        do {
            manifestKey = try await writeManifest(ticket, payloadKey: payload.key, in: staging)
        } catch {
            await discardQuietly(transferID, reason: .interrupted)
            throw error
        }

        do {
            // Second check, immediately before the commit: the pending slot may have been
            // filled while this copy was streaming.
            try await refuseOrClearReadySlot()
        } catch {
            await discardQuietly(transferID, reason: .interrupted)
            throw error
        }

        let ready = EphemeralStorageScope.transfer(transferID, .ready)
        do {
            // The payload arrives under `ready` first and is not yet a session: nothing
            // names it. The manifest's rename is the commit.
            try await store.move(payload.key, to: ready)
            try await store.move(manifestKey, to: ready)
        } catch {
            await discardQuietly(transferID, reason: .interrupted)
            throw .store(error)
        }
        return ticket
    }

    // MARK: - Claim

    /// Atomically claims the published transfer and hands it to this process unchanged.
    ///
    /// The manifest's rename out of `ready` is the claim commit, mirroring publication: the
    /// slot stops being published the instant ownership changes, so a second claimer sees
    /// an empty slot rather than the same pending session. The ticket, including its
    /// ``AnalysisSessionID``, crosses untouched — this method verifies that the stored
    /// bytes are the ones the ticket describes, and never edits either.
    ///
    /// What this does *not* do is the main app's verification flow: recopying into
    /// app-private session storage, recomputing the digest over that copy, comparing the
    /// claiming build identity, and resuming the session or terminating it with
    /// `handoff-error`. That is the Ingest Coordinator's work, and it starts from
    /// ``ClaimOutcome``.
    public func claimReadyTransfer() async throws(TransferStoreError) -> ClaimOutcome {
        switch try await resolveReadySlot() {
        case .empty:
            return .nothingToClaim

        case .unusable(let reason):
            try await discardReadySlots(reason: Self.cleanupReason(for: reason))
            return .rejected(reason)

        case .published(let manifest):
            let transferID = manifest.transferID
            let claimed = EphemeralStorageScope.transfer(transferID, .claimed)
            do {
                try await store.move(manifest.manifestKey, to: claimed)
            } catch {
                // Either another claimer won the rename, or the slot failed under us.
                // Re-resolving separates the two instead of reporting a store failure for
                // a transfer that is simply no longer pending.
                if case .empty = try await resolveReadySlot() { return .nothingToClaim }
                throw .store(error)
            }
            do {
                try await store.move(manifest.payloadKey, to: claimed)
            } catch {
                // Ownership already changed, so this transfer can never be published
                // again. Remove it and report it rather than handing back a claim whose
                // bytes are elsewhere. The session was committed, so the main app still
                // has to resume it in order to end it with `handoff-error`.
                await discardQuietly(transferID, reason: .errorTerminated)
                return .rejected(.defective(
                    DefectiveTransfer(
                        transferID: transferID,
                        pendingSession: manifest.ticket.sessionID,
                        defect: .payloadMissing
                    )
                ))
            }
            return .claimed(
                ClaimedTransfer(ticket: manifest.ticket, payloadKey: manifest.payloadKey)
            )
        }
    }

    // MARK: - Reading a claim

    /// What the claimed payload measured when it was written, without reading a byte of
    /// it.
    ///
    /// The claiming process needs this *before* it copies: comparing the stored object's
    /// measured length against the ticket's `byteCount` is what lets an oversized or
    /// truncated payload be refused before anything is allocated for it, rather than part
    /// way through (design, byte and image lifecycle). `nil` means the claimed scope does
    /// not own that object, or it was never finalized, and either one is a claim that
    /// cannot be verified.
    ///
    /// The key is checked against the `claimed` scope's contents rather than trusted, so
    /// this cannot be used to read a session's bytes or another transfer's.
    public func claimedPayloadReceipt(
        of claimed: ClaimedTransfer
    ) async -> EphemeralWriteReceipt? {
        guard await store.keys(in: claimed.scope).contains(claimed.payloadKey) else {
            return nil
        }
        return await store.receipt(for: claimed.payloadKey)
    }

    /// The claimed payload's bytes, for the recopy into app-private session storage.
    ///
    /// The store returns what is actually on disk under the claimed key, which is the
    /// point: the claiming process rehashes *these* bytes rather than trusting the byte
    /// count and digest the ticket carries (Requirements 2.19 and 11.13).
    ///
    /// Scoped the same way as ``claimedPayloadReceipt(of:)``: a key the `claimed` scope
    /// does not own is reported absent rather than read.
    public func readClaimedPayload(
        of claimed: ClaimedTransfer
    ) async throws(TransferStoreError) -> [UInt8] {
        guard await store.keys(in: claimed.scope).contains(claimed.payloadKey) else {
            throw .store(.notFound(claimed.payloadKey))
        }
        do {
            return try await store.read(claimed.payloadKey)
        } catch {
            throw .store(error)
        }
    }

    // MARK: - Removal

    /// Removes every state of one transfer.
    ///
    /// The whole transfer, not one slot: a transfer that failed part way through a
    /// publication or a claim can own material in two states at once, and leaving either
    /// behind would leave encoded image bytes in the App Group container. Idempotent, so it
    /// is safe on a startup path, after an interruption, and after a previous removal of the
    /// same transfer.
    ///
    /// `reason` selects which approved deadline the removal is audited against; the removal
    /// itself is immediate in every case.
    @discardableResult
    public func discardTransfer(
        _ transferID: ShareTransferID,
        reason: SessionCleanupReason
    ) async throws(TransferStoreError) -> [EphemeralDeletionReceipt] {
        var receipts: [EphemeralDeletionReceipt] = []
        for state in TransferSlotState.allCases {
            receipts.append(try await delete(.transfer(transferID, state), reason: reason))
        }
        return receipts
    }

    // MARK: - Resolution

    /// The ready slot, with the manifest the public state deliberately hides.
    private enum ResolvedSlot {
        case empty
        case published(TransferManifest)
        case unusable(UnusableReadySlotReason)

        var state: ReadySlotState {
            switch self {
            case .empty: .empty
            case .published(let manifest): .published(manifest.readyTransfer)
            case .unusable(let reason): .unusable(reason)
            }
        }
    }

    private func resolveReadySlot() async throws(TransferStoreError) -> ResolvedSlot {
        let published = try await readyTransferIdentifiers()
        guard let transferID = published.first else { return .empty }
        guard published.count == 1 else {
            return .unusable(.ambiguousSlotCount(published.count))
        }
        switch try await resolve(transferID, in: .ready) {
        case .defective(let pendingSession, let defect):
            return .unusable(.defective(
                DefectiveTransfer(
                    transferID: transferID,
                    pendingSession: pendingSession,
                    defect: defect
                )
            ))
        case .resolved(let manifest):
            guard !clock.isDue(
                createdAt: manifest.ticket.createdAt,
                deadline: lifecyclePolicy.deadline(for: .abandoned)
            ) else {
                return .unusable(.expired(transferID))
            }
            return .published(manifest)
        }
    }

    private enum Resolution {
        case resolved(TransferManifest)
        /// A defect, with the session the ticket named when the ticket was readable.
        case defective(AnalysisSessionID?, PublicationDefect)
    }

    /// Resolves one transfer slot into its manifest, or names what is wrong with it.
    ///
    /// The manifest is found by self-naming rather than by content sniffing: a candidate is
    /// accepted only when it decodes as a manifest whose `manifestKey` is the key it was
    /// read from. Storage keys are 128 random bits the store assigns after the payload's
    /// bytes are fixed, so a payload cannot name the key it will be stored under, and image
    /// bytes therefore cannot impersonate the record that commits their own publication.
    private func resolve(
        _ transferID: ShareTransferID,
        in state: TransferSlotState
    ) async throws(TransferStoreError) -> Resolution {
        let scope = EphemeralStorageScope.transfer(transferID, state)
        let keys = await store.keys(in: scope)
        var manifests: [TransferManifest] = []
        for key in keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            // An unfinalized object has no receipt and no complete bytes, so it is never a
            // manifest candidate.
            guard let receipt = await store.receipt(for: key) else { continue }
            guard receipt.byteCount <= TransferManifestCoding.maximumEncodedByteCount else {
                continue
            }
            let bytes: [UInt8]
            do {
                bytes = try await store.read(key)
            } catch {
                throw .store(error)
            }
            guard let manifest = try? TransferManifestCoding.decode(bytes),
                manifest.manifestKey == key,
                manifest.transferID == transferID
            else {
                continue
            }
            manifests.append(manifest)
        }
        // No readable ticket means no publication committed, so there is no session to
        // name. Two readable tickets name two, which is no answer at all.
        guard manifests.count == 1, let manifest = manifests.first else {
            return .defective(nil, manifests.isEmpty ? .manifestMissing : .manifestAmbiguous)
        }
        let pendingSession = manifest.ticket.sessionID
        guard keys.contains(manifest.payloadKey) else {
            return .defective(pendingSession, .payloadMissing)
        }
        guard let payload = await store.receipt(for: manifest.payloadKey) else {
            return .defective(pendingSession, .payloadIncomplete)
        }
        // The measurements were taken during the single streaming write, so this compares
        // the ticket against what actually reached the file rather than against itself.
        guard payload.byteCount == manifest.ticket.byteCount,
            payload.sha256 == manifest.ticket.sha256
        else {
            return .defective(pendingSession, .measurementMismatch)
        }
        return .resolved(manifest)
    }

    // MARK: - The single ready slot

    /// Refuses to proceed while a pending handoff exists, and clears one that is not
    /// resumable.
    ///
    /// The asymmetry is the point. A published, current transfer is a handoff the user
    /// consented to, so it is never replaced. An expired, ambiguous, or defective slot is
    /// not a session anyone can open, so leaving it would block every future handoff.
    private func refuseOrClearReadySlot() async throws(TransferStoreError) {
        switch try await resolveReadySlot() {
        case .empty:
            return
        case .published(let manifest):
            // `ExtensionExecutionPolicy` rejects `replaceSilently` at construction, so an
            // approved policy can only ask for a recovery instruction. Switching
            // exhaustively keeps that a compile-time fact: a third value would stop this
            // compiling instead of quietly inheriting one of these behaviors.
            switch extensionPolicy.pendingHandoffPolicy {
            case .instructRecovery, .replaceSilently:
                throw .pendingHandoffExists(manifest.transferID)
            }
        case .unusable:
            try await discardReadySlots(reason: .abandoned)
        }
    }

    /// Removes every transfer that owns ready material.
    private func discardReadySlots(
        reason: SessionCleanupReason
    ) async throws(TransferStoreError) {
        for transferID in try await readyTransferIdentifiers() {
            _ = try await discardTransfer(transferID, reason: reason)
        }
    }

    // MARK: - Manifest writing

    private func writeManifest(
        _ ticket: ShareTransferTicket,
        payloadKey: EphemeralStorageKey,
        in scope: EphemeralStorageScope
    ) async throws(TransferStoreError) -> EphemeralStorageKey {
        let key: EphemeralStorageKey
        do {
            key = try await store.create(
                in: scope,
                protection: extensionPolicy.stagedFileProtection
            )
        } catch {
            throw .store(error)
        }
        // The key exists before the bytes do, which is what lets the manifest name itself.
        guard let manifest = TransferManifest(
            ticket: ticket,
            manifestKey: key,
            payloadKey: payloadKey
        ) else {
            throw .ticketRejected
        }
        let bytes: [UInt8]
        do {
            bytes = try TransferManifestCoding.encode(manifest)
        } catch {
            switch error {
            case .tooLarge(let limit, let actual):
                throw .manifestTooLarge(limitBytes: limit, actualBytes: actual)
            case .notEncodable, .unreadable:
                throw .ticketRejected
            }
        }
        do {
            try await store.append(bytes, to: key)
            _ = try await store.finalize(key)
        } catch {
            throw .store(error)
        }
        return key
    }

    // MARK: - Scope helpers

    /// Every transfer that owns at least one object, in a deterministic order.
    private func transferIdentifiers() async throws(TransferStoreError) -> [ShareTransferID] {
        var identifiers: Set<ShareTransferID> = []
        for scope in await store.occupiedScopes() {
            // Session material belongs to the session lifecycle, not to this store. It is
            // skipped rather than cleaned up, so a shared root cannot have one lifecycle
            // delete the other's bytes.
            guard case .transfer(let transferID, _) = scope else { continue }
            identifiers.insert(transferID)
        }
        return identifiers.sorted { $0.rawValue < $1.rawValue }
    }

    /// Every transfer that owns ready material, in a deterministic order.
    private func readyTransferIdentifiers() async throws(TransferStoreError) -> [ShareTransferID] {
        var identifiers: [ShareTransferID] = []
        for scope in await store.occupiedScopes() {
            guard case .transfer(let transferID, .ready) = scope else { continue }
            identifiers.append(transferID)
        }
        return identifiers.sorted { $0.rawValue < $1.rawValue }
    }

    private func delete(
        _ scope: EphemeralStorageScope,
        reason: SessionCleanupReason
    ) async throws(TransferStoreError) -> EphemeralDeletionReceipt {
        do {
            return try await store.deleteAll(in: scope, reason: reason)
        } catch {
            throw .store(error)
        }
    }

    /// Removes a transfer on a failure path without masking the failure being reported.
    ///
    /// A cleanup that itself fails must not replace the original cause with a storage
    /// fault: the caller is already throwing, and the material that could not be removed is
    /// removed by the next startup cleanup.
    private func discardQuietly(
        _ transferID: ShareTransferID,
        reason: SessionCleanupReason
    ) async {
        _ = try? await discardTransfer(transferID, reason: reason)
    }

    /// The cleanup reason a failed staging attempt removes its material under.
    private static func cleanupReason(
        for error: EncodedAssetRetentionError
    ) -> SessionCleanupReason {
        switch error {
        case .cancelled: .cancelled
        case .sourceUnreadable, .emptySource, .incompleteCopy, .store: .interrupted
        }
    }

    /// The cleanup reason unresumable ready material is removed under at claim.
    ///
    /// A slot whose ticket was readable ends a session the user is about to be shown a
    /// `handoff-error` for, so its removal is audited as an error termination. Expired and
    /// ambiguous material never becomes an analysis at all, so it is abandoned material.
    private static func cleanupReason(
        for reason: UnusableReadySlotReason
    ) -> SessionCleanupReason {
        switch reason {
        case .expired, .ambiguousSlotCount:
            .abandoned
        case .defective(let transfer):
            transfer.pendingSession == nil ? .abandoned : .errorTerminated
        }
    }

    // MARK: - Identity

    private static let hexadecimalDigits: [Character] = Array("0123456789abcdef")

    /// Transfer name length in hexadecimal characters: 16 random bytes.
    private static let transferIDCharacterCount = 32

    /// A fresh random transfer name.
    ///
    /// 128 bits from the system generator. A transfer identifier appears in a scope marker
    /// and in a published ticket, so it must not be derived from a file name, an asset
    /// identifier, a session identifier, or the bytes themselves (Requirement 9.11).
    private static func makeTransferID() -> ShareTransferID {
        var generator = SystemRandomNumberGenerator()
        var raw = ""
        raw.reserveCapacity(transferIDCharacterCount)
        for _ in 0..<(transferIDCharacterCount / 2) {
            let byte = UInt8.random(in: .min ... .max, using: &generator)
            raw.append(hexadecimalDigits[Int(byte >> 4)])
            raw.append(hexadecimalDigits[Int(byte & 0x0F)])
        }
        guard let transferID = ShareTransferID(raw) else {
            preconditionFailure("generated transfer identifier is not canonical: \(raw)")
        }
        return transferID
    }
}
