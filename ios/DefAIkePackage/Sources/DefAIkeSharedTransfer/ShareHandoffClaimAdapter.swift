import DefAIkeDomain
import Foundation

// The main app's side of the Share handoff.
//
// The extension's side ended at one commit: an atomic `staging → ready` rename that
// created exactly one pending `AwaitingMainApp` session. This file is the mirror image. It
// takes ownership of that slot, and then it does the one thing the extension could not do
// for it — establish, from bytes this process read and measured itself, that what arrived
// is what was handed off (Requirements 2.3, 2.19, 11.12, and 11.13).
//
// The order is the requirement, so the order is what this file is built around:
//
//   1. **Claim atomically.** ``SharedTransferStore`` renames the manifest out of `ready`,
//      so a second claimer sees an empty slot rather than the same pending session. The
//      ticket, including its ``AnalysisSessionID``, crosses untouched.
//   2. **Check what needs no bytes.** Schema version, route, and the staging build's
//      identity are compared before a byte is read. A ticket from another installed
//      composition is refused without copying its payload.
//   3. **Bound before allocating.** The claimed object's measured length is compared
//      against the ticket's `byteCount` before the payload is read, so a truncated or
//      oversized payload is refused rather than materialized.
//   4. **Recopy and recompute.** The bytes are streamed into app-private protected
//      session storage, which measures its own byte count and SHA-256 during the write.
//      The comparison is therefore against what reached *this* process's storage, not
//      against a number the ticket carried about itself.
//   5. **Preserve the status unchanged.** ``ImportedEncodedAsset`` re-derives the
//      status/basis relationship, so a ticket whose two preservation fields were altered
//      independently cannot become an accepted ingest.
//   6. **Delete, then hand over.** A verified claim releases the App Group copy; a failed
//      one deletes every state of the transfer *and* the partial session copy.
//
// What this file deliberately does not do:
//
//   * Bind the Model Bundle. That happens strictly after verification, on the application
//     side of the ``ShareTransferClaiming`` port, through the bundle port the domain
//     declares. This module cannot name that port, let alone call it: it ships inside the
//     Share Extension, so a model, a validator, or an image pipeline is not reachable from
//     here at all. "Handoff-error before validation, provenance processing, or pixel
//     inference" is therefore a fact about the module graph rather than a promise about
//     call order, and `ShareExtensionIngestCoordinatorTests`' source scan keeps it one.
//   * Repair anything. There is no case that trims a payload to the ticketed length,
//     re-derives a status from the bytes, or accepts a digest that "nearly" matches.
//   * Invent a category for a mismatch. Every mismatch is `handoff-error`; the only other
//     category reachable from here is `resource-limit`, and only for a bounded storage
//     ceiling that was actually hit.

// MARK: - What a claim can find wrong

/// One independently recheckable fact about a claimed handoff that did not match.
///
/// Named individually because Requirement 2.19 turns *any* of them into the same outcome,
/// and an audit that only saw "handoff-error" could not tell a foreign build from a
/// corrupted payload. Every case is something this process established for itself: the
/// ticket is never asked to confirm its own contents.
public enum HandoffMismatch: String, Hashable, Sendable, CaseIterable {
    /// The ticket's schema version is not the one this build reads.
    ///
    /// Unreachable through ``ShareTransferTicket``'s decoder, which refuses any other
    /// version. Kept as a case because the claim path must not depend on a decoder
    /// invariant staying where it is: a version this build cannot read is a handoff it
    /// cannot verify, whichever layer notices.
    case schemaVersion = "schema-version"

    /// The ticket does not record the Share route.
    ///
    /// Also refused at ticket construction. Rechecked here for the same reason: the route
    /// is what the resumed session records (Requirement 2.8), so it is verified rather
    /// than assumed.
    case route = "route"

    /// The build that staged the transfer is not the build claiming it.
    ///
    /// Two installed compositions share no handoff slot by design — each has its own App
    /// Group — so reaching this means the container held a ticket from a build this one is
    /// not. It is checked before any byte is read.
    case stagingBuildIdentity = "staging-build-identity"

    /// The claimed object's measured length disagrees with the ticket's byte count.
    case byteCount = "byte-count"

    /// The digest recomputed over the recopied bytes disagrees with the ticket's.
    case digest = "digest"

    /// The ticket's preservation status is not the one its basis establishes.
    ///
    /// The status must cross the boundary unchanged (Requirement 11.12), and it is only
    /// meaningful together with the basis that justifies it. A ticket whose status and
    /// basis were altered independently is caught here rather than presented as a weaker
    /// but still trustworthy status.
    case preservationStatus = "preservation-status"
}

/// Why one claim attempt produced no verified ingest.
///
/// Split by what the claiming process can say afterwards, because that is what decides
/// where each one goes:
///
/// | Case | A pending session existed | The material |
/// |---|---|---|
/// | ``slotNotResumable(_:)`` | Maybe; the reason says | Removed |
/// | ``mismatch(_:)`` | Yes | Removed, including the partial copy |
/// | ``recopyRefused(_:)`` | Yes | Removed, including the partial copy |
/// | ``store(_:)`` | Yes | Removal attempted; the next startup finishes it |
/// | ``cancelled`` | Yes | Removed |
public enum ShareClaimFailure: Error, Hashable, Sendable {
    /// Ready material existed but was not one resumable published transfer.
    ///
    /// Carries the store's finding, which is the only thing that says whether a session
    /// was ever committed: an expired or ambiguous slot names none, and a defective slot
    /// names one only when its ticket was readable.
    case slotNotResumable(UnusableReadySlotReason)

    /// A fact this process rechecked did not match the ticket.
    case mismatch(HandoffMismatch)

    /// The recopy into app-private protected session storage did not complete.
    ///
    /// Distinct from ``mismatch(_:)`` because nothing disagreed — the copy simply could not
    /// be made. A bounded capacity ceiling is the one storage refusal with a truthful
    /// category of its own.
    case recopyRefused(EphemeralStoreError)

    /// The transfer store refused or failed.
    case store(TransferStoreError)

    /// The user cancelled, or the process was interrupted, during the claim.
    ///
    /// A separate case rather than a payload: cancellation is its own terminal outcome and
    /// must never be presented as a failure category (Requirement 11.17).
    case cancelled

    /// The stage every Share handoff failure is detected in.
    public static let stage: AnalysisStage = .handoffVerification

    /// The narrowed ``AnalysisFault`` view of this failure, for the
    /// ``ShareTransferClaiming`` port.
    ///
    /// `handoff-error` for every mismatch and every incomplete handoff, which is exactly
    /// what Requirements 2.19 and 11.13 specify. `resource-limit` only for a bounded
    /// storage ceiling that was actually reached — the same rule the Photos route and the
    /// extension's staging path use, so one condition does not acquire two categories
    /// depending on which adapter noticed it. Cancellation passes through unchanged, so no
    /// cancelled or interrupted claim can acquire an error category on the way out.
    public var fault: AnalysisFault {
        switch self {
        case .cancelled:
            return .cancelled
        case .recopyRefused(.capacityExceeded(scope: _)),
             .store(.store(.capacityExceeded(scope: _))),
             .store(.stagingFailed(.store(.capacityExceeded(scope: _)))):
            return .analysis(.resourceLimit, stage: Self.stage)
        case .slotNotResumable, .mismatch, .recopyRefused, .store:
            return .analysis(.handoffError, stage: Self.stage)
        }
    }
}

// MARK: - What a claim produced

/// A handoff this process verified byte for byte.
///
/// The asset's session identifier is the ticket's, unchanged since the extension allocated
/// it under `staging` (Requirements 2.3 and 11.12). The transfer identifier is carried
/// alongside it so an audit can tie the resumed session back to the slot it came from; the
/// ticket itself is not, because every fact worth acting on has already been rechecked and
/// is in the asset.
public struct VerifiedHandoff: Hashable, Sendable {
    /// The accepted ingest, owned by app-private protected session storage.
    public let asset: ImportedEncodedAsset

    /// The transfer slot this session was handed off through.
    public let transferID: ShareTransferID

    public init(asset: ImportedEncodedAsset, transferID: ShareTransferID) {
        self.asset = asset
        self.transferID = transferID
    }

    /// The session resumed by this claim.
    public var sessionID: AnalysisSessionID { asset.sessionID }
}

/// A pending session that must end without evidence, and why.
///
/// The session identifier is the whole reason this type exists. A failed handoff is not a
/// refusal of something the user is about to do — it is the end of a session the user
/// already consented to and that already exists in `AwaitingMainApp`, so the app has to
/// resume *exactly* it in order to terminate it (Requirements 2.19 and 11.13).
public struct FailedHandoff: Hashable, Sendable {
    /// The pending session this claim was resuming.
    public let sessionID: AnalysisSessionID

    /// The transfer slot it came from.
    public let transferID: ShareTransferID

    /// What went wrong, at full fidelity.
    public let failure: ShareClaimFailure

    public init(
        sessionID: AnalysisSessionID,
        transferID: ShareTransferID,
        failure: ShareClaimFailure
    ) {
        self.sessionID = sessionID
        self.transferID = transferID
        self.failure = failure
    }

    /// The narrowed fault this session terminates with.
    public var fault: AnalysisFault { failure.fault }
}

/// Where one claim attempt ended.
///
/// Five cases, and they are not collapsible. "Nothing was pending" and "a pending session
/// just failed verification" are the two the requirements are most insistent about keeping
/// apart: the first is an ordinary launch with no Share handoff, and presenting it as the
/// `handoff-error` the second produces would show a user an error for an analysis they
/// never started.
public enum ShareClaimOutcome: Hashable, Sendable {
    /// The ready slot was empty. No pending Share session exists.
    case nothingPending

    /// Material existed, named no session, and was removed.
    ///
    /// An expired pending handoff, an ambiguous slot, or a publication that never
    /// committed. Nothing resumes and nothing failed, because no session was ever created
    /// (design, Analysis Session state machine).
    case discarded(UnusableReadySlotReason)

    /// The slot could not be resolved or its ownership could not be taken, so no ticket
    /// was read.
    ///
    /// Distinct from ``discarded(_:)`` because the store did not reach a finding: without a
    /// readable ticket there is no session identifier, so nothing can be resumed in order
    /// to be terminated, and inventing one would attribute a failure to a session that may
    /// not exist. Material the store could not remove is removed by the next startup
    /// cleanup, which treats unkept ready material as abandoned.
    case unresolvable(TransferStoreError)

    /// The handoff verified exactly. This session resumes with these bytes.
    case verified(VerifiedHandoff)

    /// A pending session exists and must terminate without evidence.
    case failed(FailedHandoff)

    /// The verified handoff, or `nil` in every other outcome.
    ///
    /// The one accessor, so "did a session resume?" has a single answer and no other case
    /// can be read as though it had.
    public var verifiedHandoff: VerifiedHandoff? {
        guard case .verified(let handoff) = self else { return nil }
        return handoff
    }

    /// The session that failed verification, or `nil` in every other outcome.
    public var failedHandoff: FailedHandoff? {
        guard case .failed(let handoff) = self else { return nil }
        return handoff
    }
}

// MARK: - The adapter

/// Claims the one published transfer, reverifies it, and resumes its session.
///
/// A value type holding no state between claims: each attempt takes ownership of at most
/// one slot and either verifies it or removes it. Two concurrent attempts contend only on
/// the atomic claim inside ``SharedTransferStore``, which lets exactly one of them win.
public struct ShareHandoffClaimAdapter: ShareTransferClaiming {
    private let transfers: SharedTransferStore
    private let sessionStore: any EphemeralFileStoring
    private let sessionFileProtection: FileProtectionLevel
    private let chunkSizeInBytes: Int

    /// Creates the adapter.
    ///
    /// - Parameters:
    ///   - transfers: The coordinated App Group transfer store. It owns the atomic claim,
    ///     the single ready slot, and every removal's approved deadline. The adapter never
    ///     reaches App Group storage any other way.
    ///   - sessionStore: Protected **app-private** ephemeral storage. Deliberately a
    ///     different store from the one behind `transfers`: the verified bytes have to end
    ///     up somewhere the Share Extension cannot reach, and passing the App Group store
    ///     here would leave them in the shared container (design, session storage roots).
    ///   - sessionFileProtection: The iOS data-protection level the recopied session bytes
    ///     are created with (Requirement 9.6). Required, with no default, for the same
    ///     reason the Photos route requires one: the level a supported analysis lifecycle
    ///     needs is a physical-device validation result, and compiling one in here would
    ///     make an unvalidated choice look approved. A level that cannot be applied fails
    ///     the claim closed rather than falling back to unprotected bytes.
    ///   - chunkSizeInBytes: I/O buffer size for the recopy. A structural bound: it
    ///     changes how many passes the copy takes, never how large a payload may be, and
    ///     the finalized bytes, count, and digest are identical for every value. Clamped
    ///     to at least one byte so a misconfigured value cannot turn the copy into a
    ///     nonterminating loop of zero-length appends.
    public init(
        transfers: SharedTransferStore,
        sessionStore: any EphemeralFileStoring,
        sessionFileProtection: FileProtectionLevel,
        chunkSizeInBytes: Int = EncodedAssetRetainer.defaultChunkSizeInBytes
    ) {
        self.transfers = transfers
        self.sessionStore = sessionStore
        self.sessionFileProtection = sessionFileProtection
        self.chunkSizeInBytes = max(1, chunkSizeInBytes)
    }

    // MARK: - The adapter's own surface

    /// Claims and verifies the pending handoff, or reports where the attempt ended.
    ///
    /// The full-fidelity result: ``claimReadyTransfer(claimingBuildID:)`` narrows this to
    /// the domain port, and this is the surface an audit and this adapter's own tests read.
    ///
    /// `claimingBuildID` is this build's identity. It is compared against the build that
    /// staged the ticket before any byte is read, so a ticket that could only have come
    /// from another installed composition costs nothing to refuse.
    public func attemptClaim(
        claimingBuildID: AppBuildID
    ) async -> ShareClaimOutcome {
        let claimed: ClaimedTransfer
        do {
            switch try await transfers.claimReadyTransfer() {
            case .nothingToClaim:
                return .nothingPending
            case .rejected(let reason):
                // The store already removed the material. Whether a session existed is
                // the reason's to say, not this adapter's to guess.
                return Self.outcome(forUnusable: reason)
            case .claimed(let transfer):
                claimed = transfer
            }
        } catch {
            return .unresolvable(error)
        }

        switch await verify(claimed, claimingBuildID: claimingBuildID) {
        case .success(let asset):
            // Verified. The App Group copy has served its purpose and the session owns the
            // bytes now, so the shared container keeps nothing (Requirement 9.5).
            await discardQuietly(claimed.transferID, reason: .completed)
            return .verified(
                VerifiedHandoff(asset: asset, transferID: claimed.transferID)
            )
        case .failure(let failure):
            // The session exists, so it is resumed in order to be ended. Every state of
            // the transfer goes, and so does the partial session copy: a verification that
            // did not pass leaves no bytes anywhere.
            await deleteFailedTransfer(claimed, reason: Self.cleanupReason(for: failure))
            return .failed(
                FailedHandoff(
                    sessionID: claimed.sessionID,
                    transferID: claimed.transferID,
                    failure: failure
                )
            )
        }
    }

    // MARK: - Verification

    /// Recopies the claimed payload and establishes that it is what the ticket describes.
    ///
    /// Ordered so each check happens before the work it would make pointless: the three
    /// facts that need no bytes first, then the length bound, then the copy, then the
    /// comparison against what the copy measured.
    private func verify(
        _ claimed: ClaimedTransfer,
        claimingBuildID: AppBuildID
    ) async -> Result<ImportedEncodedAsset, ShareClaimFailure> {
        let ticket = claimed.ticket

        // Nothing here reads a byte of the payload.
        guard ticket.schemaVersion == ShareTransferTicket.currentSchemaVersion else {
            return .failure(.mismatch(.schemaVersion))
        }
        guard ticket.route == .shareExtension else {
            return .failure(.mismatch(.route))
        }
        guard ticket.extensionBuildID == claimingBuildID else {
            return .failure(.mismatch(.stagingBuildIdentity))
        }
        guard ticket.preservationBasis.supports(ticket.preservationStatus) else {
            return .failure(.mismatch(.preservationStatus))
        }

        // The bound, taken from what the object measured when it was written. A payload
        // that is not the ticketed length is refused before it is allocated for.
        guard let stored = await transfers.claimedPayloadReceipt(of: claimed) else {
            return .failure(.mismatch(.byteCount))
        }
        guard stored.byteCount == ticket.byteCount else {
            return .failure(.mismatch(.byteCount))
        }

        let payload: [UInt8]
        do {
            payload = try await transfers.readClaimedPayload(of: claimed)
        } catch {
            return .failure(.store(error))
        }
        guard UInt64(payload.count) == ticket.byteCount else {
            // The object's recorded measurement and its actual length disagree.
            return .failure(.mismatch(.byteCount))
        }

        let receipt: EphemeralWriteReceipt
        switch await recopy(payload, for: ticket.sessionID) {
        case .success(let written):
            receipt = written
        case .failure(let failure):
            return .failure(failure)
        }

        // The comparison the whole file exists for. `recomputedDigest` was computed by the
        // app-private store while writing, over the bytes that actually reached it.
        guard ticket.matches(
            recomputedByteCount: receipt.byteCount,
            recomputedDigest: receipt.sha256,
            claimingBuildID: claimingBuildID
        ) else {
            return .failure(
                .mismatch(receipt.byteCount == ticket.byteCount ? .digest : .byteCount)
            )
        }

        guard
            let handle = EncodedAssetHandle(sessionID: ticket.sessionID, receipt: receipt),
            let asset = ImportedEncodedAsset(
                route: ticket.route,
                handle: handle,
                // Carried across unchanged, never re-derived from the bytes
                // (Requirement 11.12).
                preservationStatus: ticket.preservationStatus,
                preservationBasis: ticket.preservationBasis,
                contentTypeHint: ticket.contentTypeHint
            )
        else {
            // The handle refuses an empty object or a scope that is not this session's,
            // and the asset refuses a status its basis does not establish. Both were
            // already checked, so reaching this means the store finalized something that
            // does not describe what was written. Fail closed rather than accept it.
            return .failure(.mismatch(.byteCount))
        }
        return .success(asset)
    }

    /// Streams `payload` into the session's app-private protected storage.
    ///
    /// The destination store computes the byte count and SHA-256 during this single write,
    /// which is what makes the later comparison a recomputation rather than a restatement
    /// of the ticket. Nothing partial survives a failure: the session scope is emptied
    /// before returning, so a caller never has to distinguish "failed" from "failed and
    /// left something behind".
    private func recopy(
        _ payload: [UInt8],
        for sessionID: AnalysisSessionID
    ) async -> Result<EphemeralWriteReceipt, ShareClaimFailure> {
        let scope = EphemeralStorageScope.session(sessionID)
        let key: EphemeralStorageKey
        do {
            key = try await sessionStore.create(in: scope, protection: sessionFileProtection)
        } catch {
            return .failure(.recopyRefused(error))
        }

        var offset = 0
        while offset < payload.count {
            // Checked at every chunk boundary, so a cancelled claim stops within one
            // buffer rather than after the whole payload.
            guard !Task.isCancelled else {
                await discardSessionCopy(sessionID, reason: .cancelled)
                return .failure(.cancelled)
            }
            let end = min(offset + chunkSizeInBytes, payload.count)
            do {
                try await sessionStore.append(Array(payload[offset..<end]), to: key)
            } catch {
                await discardSessionCopy(sessionID, reason: .interrupted)
                return .failure(.recopyRefused(error))
            }
            offset = end
        }

        do {
            return .success(try await sessionStore.finalize(key))
        } catch {
            await discardSessionCopy(sessionID, reason: .interrupted)
            return .failure(.recopyRefused(error))
        }
    }

    // MARK: - Removal

    /// Removes every trace of a handoff that did not verify.
    ///
    /// Both namespaces, every time. The App Group states hold the bytes the extension
    /// staged and the session scope holds however much of the recopy completed, and
    /// leaving either would leave encoded image bytes behind for a session that produced
    /// no evidence.
    private func deleteFailedTransfer(
        _ claimed: ClaimedTransfer,
        reason: SessionCleanupReason
    ) async {
        await discardQuietly(claimed.transferID, reason: reason)
        await discardSessionCopy(claimed.sessionID, reason: reason)
    }

    /// Removes a transfer without masking the failure being reported.
    ///
    /// A cleanup that itself fails must not replace the original cause with a storage
    /// fault: the caller is already reporting one, and material that could not be removed
    /// is removed by the next startup cleanup.
    private func discardQuietly(
        _ transferID: ShareTransferID,
        reason: SessionCleanupReason
    ) async {
        _ = try? await transfers.discardTransfer(transferID, reason: reason)
    }

    private func discardSessionCopy(
        _ sessionID: AnalysisSessionID,
        reason: SessionCleanupReason
    ) async {
        _ = try? await sessionStore.deleteAll(in: .session(sessionID), reason: reason)
    }

    // MARK: - Classification

    /// The outcome an unusable ready slot produces.
    ///
    /// The distinction is whether a session was ever committed. An expired or ambiguous
    /// slot, and a publication whose ticket was never readable, created none — there is
    /// nothing to resume and nothing to terminate, so the material is simply gone. A
    /// defective slot whose ticket *was* readable created one, and that session has to end
    /// with `handoff-error`.
    private static func outcome(
        forUnusable reason: UnusableReadySlotReason
    ) -> ShareClaimOutcome {
        guard case .defective(let transfer) = reason,
            let pendingSession = transfer.pendingSession
        else {
            return .discarded(reason)
        }
        return .failed(
            FailedHandoff(
                sessionID: pendingSession,
                transferID: transfer.transferID,
                failure: .slotNotResumable(reason)
            )
        )
    }

    /// The approved deadline a failed claim's removal is audited against.
    ///
    /// A verification failure ends a session with an error, so its material is an error
    /// termination. A cancellation is a cancellation. Neither changes how immediately the
    /// removal happens.
    private static func cleanupReason(for failure: ShareClaimFailure) -> SessionCleanupReason {
        switch failure {
        case .cancelled: .cancelled
        case .slotNotResumable, .mismatch, .recopyRefused, .store: .errorTerminated
        }
    }

    // MARK: - ShareTransferClaiming

    /// The published transfer awaiting this app, or `nil` when the ready slot is empty.
    ///
    /// Takes no ownership and reads no image bytes, so calling it twice is the same as
    /// calling it once. Only a resolvable, unexpired published transfer counts: an expired,
    /// ambiguous, or defective slot is not a handoff anyone can open, and reporting one as
    /// pending would offer a session that cannot be resumed.
    ///
    /// The port's error vocabulary is the store's, so a transfer-store failure that is not
    /// itself a storage fault surfaces as an unavailable store rather than as an invented
    /// category.
    public func peekReadyTransfer() async throws(EphemeralStoreError) -> ReadyTransfer? {
        do {
            return try await transfers.readySlotState().publishedTransfer
        } catch {
            switch error {
            case .store(let storeError):
                throw storeError
            case .pendingHandoffExists, .stagingFailed, .manifestTooLarge, .ticketRejected:
                throw .storeUnavailable
            }
        }
    }

    /// The domain port. Returns the accepted ingest, `nil` when nothing is pending, or
    /// throws the narrowed fault.
    ///
    /// `nil` covers an empty slot, material that named no session, and a slot the store
    /// could not resolve, because all three lead to the same place: there is no session to
    /// resume and none to terminate. ``attemptClaim(claimingBuildID:)`` keeps them apart
    /// for an audit.
    public func claimReadyTransfer(
        claimingBuildID: AppBuildID
    ) async throws(AnalysisFault) -> ImportedEncodedAsset? {
        switch await attemptClaim(claimingBuildID: claimingBuildID) {
        case .nothingPending, .discarded, .unresolvable:
            return nil
        case .verified(let handoff):
            return handoff.asset
        case .failed(let handoff):
            throw handoff.fault
        }
    }
}
