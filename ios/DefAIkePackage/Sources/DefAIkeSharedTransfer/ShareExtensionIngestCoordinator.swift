import DefAIkeDomain
import Foundation

// The Share Extension's ingest coordinator.
//
// It drives one activation from "a host offered something" to either exactly one published
// ticket or nothing at all, in this order and no other:
//
//   1. count the providers and the sole provider's items, and refuse anything but one;
//   2. refuse to stage a second image while a consented handoff is still pending;
//   3. present the visible consent action;
//   4. only then borrow the host's representation, and stream it through the same retainer
//      the Photos route uses, into protected App Group staging;
//   5. publish atomically through ``SharedTransferStore``, which is the sole Share-route
//      session-creation commit;
//   6. hand back the explicit instruction to open DefAIke.
//
// Steps 1 and 2 happen before the provider is touched at all, and step 4 is unreachable
// without the ``ConfirmedConsent`` step 3 produces. That ordering is the requirement
// (Requirements 2.2, 2.7, and 11.10), and it is enforced by the shapes rather than by the
// sequence of statements: no member here reads, copies, hashes, or writes a byte, and the two
// members that can reach the provider at all take a consent token as an argument.
//
// What this file deliberately does not contain:
//
//   * Any copy, hash, or write of its own. Bytes move exactly once, through
//     ``SharedTransferStore`` and ``EncodedAssetRetainer``, so the Share route and the
//     Photos route cannot measure the same bytes differently (Requirement 2.14).
//   * Any second publication path. Publication is one call, and it either returns a ticket
//     or leaves nothing behind, which is what makes "a decline, cancellation, provider
//     failure, resource breach, or interruption before publication creates no session"
//     true without a compensating cleanup step that could be skipped
//     (Requirements 2.4 and 11.8).
//   * Any inference, model, or Content Credential work, and no way to reach it: the module
//     the extension links has no such dependency, and the accompanying source scan keeps it
//     that way (Requirement 11.11).
//   * Any way to open the containing application. The handoff ends with an instruction
//     (design, fixed decision 4).
//   * Any timeout, deadline, or retry.

// MARK: - The candidate session identifier

/// Mints the candidate ``AnalysisSessionID`` a Share handoff is staged under.
///
/// A seam because the domain does not mint identifiers, and because a test that asserts the
/// published ticket carries *the identifier the extension allocated* needs to know what that
/// was. The value has no session semantics until publication succeeds: a candidate written
/// under `staging` names a storage scope and nothing more (design, Analysis Session state
/// machine).
public protocol CandidateSessionIdentifierSource: Sendable {
    func makeCandidateSessionID() -> AnalysisSessionID
}

/// A fixed prefix followed by 128 random bits from the system generator, as lowercase
/// hexadecimal.
///
/// Not derived from a file name, a host application identity, a transfer identifier, or the
/// bytes themselves, so a session identifier cannot carry user content or correlate two
/// analyses (Requirement 9.11). ``SharedTransferStore`` mints transfer identifiers the same
/// way and for the same reason.
public struct RandomCandidateSessionIdentifierSource: CandidateSessionIdentifierSource {
    public init() {}

    public func makeCandidateSessionID() -> AnalysisSessionID {
        var generator = SystemRandomNumberGenerator()
        let digits: [Character] = Array("0123456789abcdef")
        var raw = "session-"
        raw.reserveCapacity(raw.count + 32)
        for _ in 0..<16 {
            let byte = UInt8.random(in: .min ... .max, using: &generator)
            raw.append(digits[Int(byte >> 4)])
            raw.append(digits[Int(byte & 0x0F)])
        }
        guard let sessionID = AnalysisSessionID(raw) else {
            preconditionFailure("generated session identifier is not canonical")
        }
        return sessionID
    }
}

// MARK: - Failures

/// Why the consent token the presenter returned cannot authorize a handoff.
///
/// Consent is proof of one user action for one provider under one bound policy. A token that
/// names something else is not weaker evidence, it is evidence of a different thing, so it
/// authorizes nothing.
public enum ConsentBindingDefect: String, Hashable, Sendable, CaseIterable {
    /// The token names a different provider than the one that was presented, so consent for
    /// one item is being replayed for another.
    case providerMismatch = "provider-mismatch"

    /// The token names a different Extension Execution Policy version than the one this
    /// build's transfer store is bound to (Requirement 11.9).
    case unboundExtensionExecutionPolicy = "unbound-extension-execution-policy"
}

/// Why one consented Share handoff produced no published ticket.
///
/// Every case is a no-session outcome. Publication is the only commit, so a failure here
/// means the App Group container holds nothing for this attempt, no Analysis Session exists
/// in any state, no main-application analysis began, and no evidence verdict was produced
/// (Requirement 2.4 and Property 7).
///
/// The cases are the distinctions an audit needs, and they stay separate because they mean
/// different things:
///
/// | Case | The host | DefAIke's storage |
/// |---|---|---|
/// | ``consentNotBound(_:)`` | Untouched | Never held a byte |
/// | ``activationNotOneItem(itemCount:)`` | Untouched | Never held a byte |
/// | ``resourceBreach(_:)`` | Offered a representation | Never held a byte of it |
/// | ``noRepresentationObtained(_:)`` | Offered nothing | Never held a byte |
/// | ``pendingHandoffExists(_:)`` | Untouched | Holds an *earlier* consented handoff |
/// | ``stagingIncomplete(_:)`` | Offered a representation | Staging removed; nothing remains |
/// | ``cancelled`` | Either | Nothing remains; not an error |
public enum ShareStagingFailure: Error, Hashable, Sendable {
    /// The presented consent does not authorize this handoff.
    case consentNotBound(ConsentBindingDefect)

    /// The provider did not offer exactly one item, checked again at staging time.
    ///
    /// ``ConfirmedConsent`` already refuses any other count at construction, so this is
    /// unreachable through the coordinator's own flow. It stays a case rather than an
    /// assertion because runtime counting is authoritative and an adapter called directly
    /// through ``ShareTransferStaging`` must refuse the same way (Requirement 2.7).
    case activationNotOneItem(itemCount: Int)

    /// Continuing would exceed a Share Extension Resource Budget hard limit, so the copy
    /// was never started (Requirement 11.8).
    ///
    /// Carries the metric whose check did not pass. A breach is refused before any byte is
    /// read rather than part way through, so nothing partial exists to clean up.
    case resourceBreach(ResourceMetric)

    /// The provider's access window closed with no representation, so no byte was read.
    case noRepresentationObtained(SharedItemProviderFault)

    /// A handoff the user already consented to is still waiting for the main application.
    ///
    /// Not a failure of anything the user just did, which is why the coordinator reports it
    /// as ``ShareHandoffOutcome/pendingHandoff(_:)`` instead. It is a case here because the
    /// narrow ``ShareTransferStaging`` port has no way to return a recovery instruction.
    case pendingHandoffExists(ShareTransferID)

    /// A representation was offered and publication did not commit.
    ///
    /// Nothing partial survives: ``SharedTransferStore`` removes the whole transfer before
    /// reporting, and its cleanup is idempotent.
    case stagingIncomplete(TransferStoreError)

    /// The user cancelled, or the process was interrupted, before publication committed.
    ///
    /// A separate case rather than a payload, because cancellation must never be presented
    /// as a failure category (Requirement 11.17).
    case cancelled

    /// The stage a Share staging failure is detected in.
    ///
    /// The closed stage vocabulary has one handoff stage and no separate extension-staging
    /// stage, and the handoff is the only stage the Share route reaches before the main
    /// application resumes the session. Using it keeps the extension side and the claiming
    /// side of one handoff reported under one stage.
    public static let stage: AnalysisStage = .handoffVerification

    /// The narrowed ``AnalysisFault`` view of this failure, for the
    /// ``ShareTransferStaging`` port.
    ///
    /// The port is typed `throws(AnalysisFault)`, so a failure has to cross it as either
    /// cancellation or one ``AnalysisError``. That is deliberate in the domain: no Analysis
    /// Session exists on any of these paths, so the fault is only the transport that tells
    /// the caller no handoff exists, and the extension never presents the category to a
    /// user. ``ShareExtensionIngestCoordinator/handleActivation(_:)`` is the surface that
    /// keeps the precise reason.
    ///
    /// Cancellation passes through from wherever it arrived, so no cancelled or interrupted
    /// attempt can acquire an error category on the way out. A resource breach and a bounded
    /// storage ceiling are the two failures with a truthful category — continuing would
    /// exceed an approved limit, which is `resource-limit`. Everything else is a handoff
    /// that did not complete, which is `handoff-error`.
    public var fault: AnalysisFault {
        switch self {
        case .cancelled,
             .noRepresentationObtained(.cancelled),
             .stagingIncomplete(.stagingFailed(.cancelled)):
            return .cancelled
        case .resourceBreach,
             .stagingIncomplete(.stagingFailed(.store(.capacityExceeded(scope: _)))),
             .stagingIncomplete(.store(.capacityExceeded(scope: _))):
            return .analysis(.resourceLimit, stage: Self.stage)
        case .consentNotBound,
             .activationNotOneItem,
             .noRepresentationObtained,
             .pendingHandoffExists,
             .stagingIncomplete:
            return .analysis(.handoffError, stage: Self.stage)
        }
    }
}

// MARK: - The coordinator

/// Turns one Share activation into at most one published transfer.
///
/// A value type holding no state between activations: each one resolves its own candidate,
/// asks for its own consent, mints its own candidate session identifier, and either publishes
/// or leaves nothing. Two concurrent activations share nothing except the single ready slot,
/// which ``SharedTransferStore`` refuses to let either of them replace.
public struct ShareExtensionIngestCoordinator: ShareTransferStaging {
    private let access: any SharedItemRepresentationAccess
    private let consentPresenter: any ShareConsentPresenting
    private let transfers: SharedTransferStore
    private let governor: any ResourceGoverning
    private let budget: ResourceBudget
    private let candidateSessions: any CandidateSessionIdentifierSource
    private let instruction: ManualOpenInstruction

    /// The byte quantities a handoff consumes, reserved before the copy begins.
    ///
    /// Exactly the two byte-unit metrics Requirement 11.3 puts in the Share Extension
    /// budget that this work is a direct consumer of: the encoded input being handed off,
    /// and the temporary storage the staged copy occupies. Naming them is not a policy
    /// decision about which metrics gate a stage — it is naming the resources this specific
    /// work uses. Memory, energy, thermal state, and handoff latency are measured by the
    /// Device Validation Suite against the same signed budget and are not reservable here.
    static let reservedHandoffMetrics: [ResourceMetric] = [.encodedInputSize, .temporaryStorage]

    /// Creates a coordinator, or `nil` when the resource wiring is for the wrong target.
    ///
    /// `nil` rather than a fallback: a coordinator holding the main application's budget or
    /// governor has no correct behavior available to it, and silently preferring either side
    /// is the cross-target substitution Requirement 11.1 forbids.
    ///
    /// - Parameters:
    ///   - access: The item-provider seam. The only implementation that touches an extension
    ///     item lives in the Share Extension target.
    ///   - consentPresenter: The visible consent action. Its answer is the only thing that
    ///     lets a byte be read.
    ///   - transfers: The coordinated App Group transfer store. It owns staging, atomic
    ///     publication, the single ready slot, the staged protection level, and the bound
    ///     policy versions, which this coordinator reads from it rather than holding a
    ///     second copy of.
    ///   - governor: Resource governance for the Share Extension target.
    ///   - budget: The signed Share Extension Resource Budget. Every number the breach path
    ///     compares against comes from here; there is no default, no clamp, and no way to
    ///     raise a limit.
    ///   - instruction: The explicit "Open DefAIke" instruction, as an approved copy key.
    ///     Required, with no default: the wording is an unresolved approved-copy decision,
    ///     and a compiled-in sentence would make an unapproved string look approved.
    ///   - candidateSessions: Where the candidate session identifier comes from.
    public init?(
        access: any SharedItemRepresentationAccess,
        consentPresenter: any ShareConsentPresenting,
        transfers: SharedTransferStore,
        governor: any ResourceGoverning,
        budget: ResourceBudget,
        instruction: ManualOpenInstruction,
        candidateSessions: any CandidateSessionIdentifierSource =
            RandomCandidateSessionIdentifierSource()
    ) {
        guard governor.target == .shareExtension, budget.target == .shareExtension else {
            return nil
        }
        self.access = access
        self.consentPresenter = consentPresenter
        self.transfers = transfers
        self.governor = governor
        self.budget = budget
        self.instruction = instruction
        self.candidateSessions = candidateSessions
    }

    // MARK: - One activation

    /// Resolves one activation, obtains consent, stages, publishes, and reports where it
    /// ended.
    ///
    /// The whole Share route in one call, and the only surface that presents consent. The
    /// order is load-bearing: the activation is counted and the pending slot is checked
    /// before the consent action appears, and the provider is not reachable until consent
    /// has been confirmed, so a refused activation and a declined or cancelled consent read
    /// no byte of the shared item at all.
    public func handleActivation(_ activation: ShareActivation) async -> ShareHandoffOutcome {
        let provider: SharedItemProvider
        switch activation.resolvedCandidate {
        case .refused(let refusal):
            // Refused before the provider is touched: nothing is read, staged, or created.
            return .activationRefused(refusal)
        case .oneItem(let resolved):
            provider = resolved
        }

        switch await pendingHandoff() {
        case .failure(let failure):
            return .failed(failure)
        case .success(let pending?):
            // A handoff the user already consented to is waiting. It is never replaced, and
            // asking for consent again would offer a handoff that cannot be performed.
            return .pendingHandoff(
                PendingHandoffRecovery(pendingTransfer: pending, instruction: instruction)
            )
        case .success(nil):
            break
        }

        let boundPolicyID = await transfers.extensionExecutionPolicyID
        let request = ShareConsentRequest(
            provider: provider,
            extensionExecutionPolicyID: boundPolicyID
        )
        switch await consentPresenter.presentConsent(for: request) {
        case .declined:
            return .declined
        case .cancelled:
            return .cancelled
        case .confirmed(let consent):
            switch await attemptStaging(of: provider, consent: consent) {
            case .success(let ticket):
                return .published(PublishedHandoff(ticket: ticket, instruction: instruction))
            case .failure(.cancelled):
                return .cancelled
            case .failure(.pendingHandoffExists(let pending)):
                // The slot filled while this copy was streaming. The store refused to
                // replace it and removed this attempt's staging.
                return .pendingHandoff(
                    PendingHandoffRecovery(pendingTransfer: pending, instruction: instruction)
                )
            case .failure(let failure):
                return .failed(failure)
            }
        }
    }

    // MARK: - The adapter's own surface

    /// Stages and publishes one consented provider, or reports how far the attempt got.
    ///
    /// The full-fidelity result: success is exactly one atomically published ticket, and a
    /// failure names which no-session path was taken. ``stageOne(_:consent:)`` narrows this
    /// to the domain port; this is the surface an audit and this adapter's own tests read.
    ///
    /// `consent` is checked against the provider it names and against the policy version the
    /// transfer store is bound to before anything else happens, so a presenter cannot
    /// authorize a different provider and a build with no bound policy cannot stage at all.
    public func attemptStaging(
        of provider: SharedItemProvider,
        consent: ConfirmedConsent
    ) async -> Result<ShareTransferTicket, ShareStagingFailure> {
        guard consent.provider == provider else {
            return .failure(.consentNotBound(.providerMismatch))
        }
        let boundPolicyID = await transfers.extensionExecutionPolicyID
        guard consent.extensionExecutionPolicyID == boundPolicyID else {
            return .failure(.consentNotBound(.unboundExtensionExecutionPolicy))
        }
        // Runtime counting stays authoritative even though `ConfirmedConsent` refuses any
        // other count at construction.
        guard provider.offersExactlyOneItem else {
            return .failure(.activationNotOneItem(itemCount: provider.itemCount))
        }

        let sessionID = candidateSessions.makeCandidateSessionID()
        do {
            // The copy happens inside this closure, which is inside the provider's access
            // window. Nothing captures the borrowed representation, so there is no URL to
            // read after the window has closed.
            return try await access.withRepresentation(of: provider) { borrowed in
                await self.stage(borrowed, consent: consent, sessionID: sessionID)
            }
        } catch {
            // No representation was produced, so `consume` never ran and no byte of the item
            // was read. There is nothing to clean up and no session to end.
            return .failure(
                error == .cancelled ? .cancelled : .noRepresentationObtained(error)
            )
        }
    }

    /// Streams the borrowed representation into protected staging and publishes it.
    ///
    /// Reserving comes first and the copy second, so a representation larger than the
    /// approved encoded-input ceiling is refused before a byte is read rather than stopped
    /// part way through (Requirement 11.8). Headroom is returned on every path, including
    /// the failing ones, so a refused handoff does not leave the next activation short.
    private func stage(
        _ borrowed: BorrowedSharedRepresentation,
        consent: ConfirmedConsent,
        sessionID: AnalysisSessionID
    ) async -> StagedRepresentation {
        let byteCount: UInt64
        do {
            // Attributes only: this measures the representation without reading it.
            byteCount = try EncodedAssetRetainer.measuredByteCount(ofFileAt: borrowed.fileURL)
        } catch {
            return .failure(.stagingIncomplete(.stagingFailed(error)))
        }

        let reservations: [ResourceReservation]
        switch await reserveHandoffWork(forEncodedByteCount: byteCount) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let granted):
            reservations = granted
        }

        let outcome: StagedRepresentation
        do {
            // The one commit. It streams through `EncodedAssetRetainer`, applies the policy's
            // protection level, writes the bounded ticket, and promotes atomically; a
            // failure anywhere inside it removes the whole transfer before returning.
            let ticket = try await transfers.publishTransfer(
                ofFileAt: borrowed.fileURL,
                consent: consent,
                sessionID: sessionID,
                basis: borrowed.form.preservationBasis
            )
            outcome = .success(ticket)
        } catch {
            outcome = .failure(Self.failure(from: error))
        }
        await release(reservations)
        return outcome
    }

    /// Maps a transfer-store failure onto the no-session vocabulary.
    private static func failure(from error: TransferStoreError) -> ShareStagingFailure {
        switch error {
        case .pendingHandoffExists(let transferID):
            return .pendingHandoffExists(transferID)
        case .stagingFailed(.cancelled):
            // An interruption or a user cancellation part way through the copy. Not an
            // error category, and nothing partial survives it.
            return .cancelled
        default:
            return .stagingIncomplete(error)
        }
    }

    // MARK: - The resource breach path

    /// Reserves headroom for the bytes about to be staged, or reports the breach.
    ///
    /// Every comparison starts at the injected signed budget. A metric the bound budget does
    /// not define in the requested unit is a check that cannot be performed, and a check
    /// that cannot be performed fails closed rather than passing silently: treating a
    /// missing limit as "unlimited" would make the budget advisory. Headroom already granted
    /// is returned before reporting, so a partial reservation never leaks.
    private func reserveHandoffWork(
        forEncodedByteCount byteCount: UInt64
    ) async -> Result<[ResourceReservation], ShareStagingFailure> {
        guard let amount = try? PositiveDecimal(validating: Decimal(byteCount)) else {
            // Zero bytes are not an analyzable image and not a reservable quantity. The
            // retainer refuses an empty representation for the same reason.
            return .failure(.stagingIncomplete(.stagingFailed(.emptySource)))
        }

        var granted: [ResourceReservation] = []
        for metric in Self.reservedHandoffMetrics {
            guard
                case .numeric(_, let definedUnit) = budget.limit(for: metric),
                definedUnit == .bytes,
                let request = ResourceReservationRequest(
                    metric: metric,
                    amount: amount,
                    unit: .bytes,
                    stage: ShareStagingFailure.stage
                )
            else {
                await release(granted)
                return .failure(.resourceBreach(metric))
            }

            let reservation: ResourceReservation
            do {
                reservation = try await governor.reserve(request, budget: budget)
            } catch {
                await release(granted)
                // Cancellation is not an Analysis Error and must never be presented as one,
                // so it passes through unchanged. Every other fault means the headroom was
                // not granted, which is a breach of this metric whatever the adapter named.
                return .failure(error.isCancelled ? .cancelled : .resourceBreach(metric))
            }
            guard
                reservation.target == .shareExtension,
                reservation.budgetID == budget.id,
                reservation.request == request
            else {
                // Headroom minted against another target, another budget, or another request
                // is not what was asked for. Hand it back so it does not leak, then refuse.
                await governor.release(reservation)
                await release(granted)
                return .failure(.resourceBreach(metric))
            }
            granted.append(reservation)
        }
        return .success(granted)
    }

    private func release(_ reservations: [ResourceReservation]) async {
        for reservation in reservations {
            await governor.release(reservation)
        }
    }

    // MARK: - The single ready slot

    /// The transfer already waiting for the main application, if any.
    ///
    /// Peeking takes no ownership and reads no image bytes. Only a resolvable, unexpired
    /// published transfer counts: an expired, ambiguous, or defective slot is not a handoff
    /// anyone can open, and the store clears it on the next publication attempt rather than
    /// letting it block every future handoff.
    private func pendingHandoff() async -> Result<ShareTransferID?, ShareStagingFailure> {
        do {
            switch try await transfers.readySlotState() {
            case .published(let transfer):
                return .success(transfer.ticket.transferID)
            case .empty, .unusable:
                return .success(nil)
            }
        } catch {
            return .failure(.stagingIncomplete(error))
        }
    }

    // MARK: - ShareTransferStaging

    /// The domain port. Returns the published ticket, or throws the narrowed fault.
    public func stageOne(
        _ provider: SharedItemProvider,
        consent: ConfirmedConsent
    ) async throws(AnalysisFault) -> ShareTransferTicket {
        switch await attemptStaging(of: provider, consent: consent) {
        case .success(let ticket):
            return ticket
        case .failure(let failure):
            throw failure.fault
        }
    }

    /// Removes transfer material an interrupted process left behind, before this extension
    /// accepts work.
    ///
    /// Delegates to the transfer store, which owns the `staging` → `ready` → `claimed`
    /// states and selects each removal's approved deadline. Idempotent: a second run removes
    /// nothing and still succeeds (Requirement 11.16).
    ///
    /// `policy` has to be the artifact the store is bound to. A mismatch is refused rather
    /// than obeyed: the store's deadlines come from its own bound policy, so cleaning up
    /// "under" a different version would audit the removal against a deadline that never
    /// governed the material. The port's closed error vocabulary has no wiring-fault case,
    /// so the refusal surfaces as an unavailable store.
    public func discardStagedMaterial(
        policy: DataLifecyclePolicy
    ) async throws(EphemeralStoreError) -> Void {
        let boundPolicyID = await transfers.dataLifecyclePolicyID
        guard boundPolicyID == policy.id else {
            throw .storeUnavailable
        }
        do {
            _ = try await transfers.runStartupCleanup()
        } catch {
            switch error {
            case .store(let storeError):
                throw storeError
            case .pendingHandoffExists, .stagingFailed, .manifestTooLarge, .ticketRejected:
                throw .storeUnavailable
            }
        }
    }
}
