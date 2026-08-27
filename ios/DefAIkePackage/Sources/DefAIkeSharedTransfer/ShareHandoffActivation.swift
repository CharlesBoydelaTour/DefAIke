import DefAIkeDomain
import Foundation

// What one Share activation may be, what the consent action may answer, and what the
// extension has to show afterwards.
//
// Three rules live in this file, and each one is a shape rather than a check a call site
// could forget:
//
//   * **One provider, decided before any byte is read.** ``ShareActivation`` can hold any
//     number of providers, because zero and many have to be *representable* in order to be
//     refused and tested (Requirement 2.7 and Property 4). The only way out of it is
//     ``ShareActivation/resolvedCandidate``, which either names one provider offering one
//     item or names why the activation was refused. There is no `first`, no `prefix(1)`, and
//     no "pick the best provider".
//   * **Consent is a value, not a flag.** The visible action either produces a
//     ``ConfirmedConsent`` for exactly this provider or produces nothing. A decline and a
//     cancellation are separate cases with no payload, so neither can be mistaken for a
//     failure category, and neither can be turned into a token that would let a byte be
//     read (Requirements 2.2, 2.4, and 11.10).
//   * **The handoff ends with an instruction, not a launch.** iOS does not support opening
//     the containing application from the share extension point — Apple documents that
//     support for Today and iMessage extensions only — so the extension cannot claim it
//     launches DefAIke. ``HandoffLaunchMechanism`` has one case, which makes "the user
//     opens the app" the only representable answer and a programmatic launch, a private
//     selector, or a responder-chain trick unrepresentable rather than merely discouraged
//     (design, fixed decision 4).

// MARK: - Activation

/// Why an activation cannot be handed off.
///
/// Every case is decided before the provider is touched, so a refused activation reads no
/// byte, stages nothing, creates no session, and produces no evidence. None of them is an
/// ``AnalysisError``: there is no session to fail and no verdict to withhold, which is why
/// the refusal is reported as its own value rather than as a fault.
public enum ShareActivationRefusal: Hashable, Sendable {
    /// The activation offered no provider at all.
    case noProviderOffered

    /// The activation offered more than one provider, so no single candidate exists.
    case providerCountUnsupported(Int)

    /// Exactly one provider, but it did not offer exactly one item.
    ///
    /// Carries the count the provider reported, including zero. The activation rule limits
    /// what a host may offer, but runtime counting is authoritative: a host that offers a
    /// different count is refused here rather than trusted (design, Share Extension handoff
    /// sequence).
    case itemCountUnsupported(Int)
}

/// What one activation resolved to.
///
/// Two cases, and neither is an `Optional`: "one provider offering one item" and "refused,
/// for this reason" are the only answers, and collapsing the refusals into `nil` would lose
/// the distinction an audit needs. A refusal is deliberately not an `Error`, because nothing
/// throws it — no session exists to fail, so it is a decision rather than a failure.
public enum ShareActivationCandidate: Hashable, Sendable {
    /// The one provider that may be handed off, once the user consents.
    case oneItem(SharedItemProvider)

    /// Nothing may be handed off, for this reason.
    case refused(ShareActivationRefusal)
}

/// Everything one Share activation offered.
///
/// The provider count is unconstrained on purpose, exactly as ``PhotosPickerSelection``
/// leaves the selected-item count unconstrained: Requirement 2.7 rejects any count other
/// than one *before* a session exists, so the other counts must exist to be rejected.
public struct ShareActivation: Hashable, Sendable {
    public let providers: [SharedItemProvider]

    public init(providers: [SharedItemProvider]) {
        self.providers = providers
    }

    /// The one provider that may be handed off, or why the activation was refused.
    ///
    /// The only sanctioned way to get from an activation to a provider: there is no `first`,
    /// no `prefix(1)`, and no "pick the best provider". Both counts are checked — how many
    /// providers the activation carried, and how many items the sole provider reported —
    /// because either one being wrong means DefAIke cannot tell which single image the user
    /// meant.
    public var resolvedCandidate: ShareActivationCandidate {
        guard !providers.isEmpty else { return .refused(.noProviderOffered) }
        guard providers.count == 1 else {
            return .refused(.providerCountUnsupported(providers.count))
        }
        let provider = providers[0]
        guard provider.offersExactlyOneItem else {
            return .refused(.itemCountUnsupported(provider.itemCount))
        }
        return .oneItem(provider)
    }
}

// MARK: - Consent

/// What the visible consent action must be presented for.
///
/// It names the provider the user is being asked about and the Extension Execution Policy
/// version that requires the action, so a presented screen is always tied to one activation
/// and one bound policy. It carries no bytes, no file name, no host application identity,
/// and no thumbnail: the consent action is about scope, not about content
/// (Requirements 9.11, 11.9, and 11.10).
public struct ShareConsentRequest: Hashable, Sendable {
    /// The provider the user is being asked to hand off.
    public let provider: SharedItemProvider

    /// The Extension Execution Policy version that requires a visible consent action.
    public let extensionExecutionPolicyID: ArtifactID

    public init(provider: SharedItemProvider, extensionExecutionPolicyID: ArtifactID) {
        self.provider = provider
        self.extensionExecutionPolicyID = extensionExecutionPolicyID
    }
}

/// What the user did with the visible consent action.
///
/// ``declined`` and ``cancelled`` carry nothing, which is the whole point: there is no
/// consent token on either path, so a byte cannot be read, staging cannot begin, and no
/// session or evidence can exist (Requirement 2.4). They stay separate values because
/// declining a handoff and dismissing the screen are different user acts, and neither is an
/// error (Requirement 11.17).
public enum ShareConsentDecision: Hashable, Sendable {
    /// The user performed the consent action for exactly this provider.
    case confirmed(ConfirmedConsent)

    /// The user declined the handoff.
    case declined

    /// The user dismissed the consent action without deciding.
    case cancelled
}

/// Presents the visible consent action and reports what the user chose.
///
/// A seam for the same reason the provider is one: the consent screen is the extension's
/// user interface, so it cannot be compiled or exercised on a host. Keeping it behind a
/// protocol is what lets the ordering rule — nothing reads a byte until this call has
/// answered ``ShareConsentDecision/confirmed(_:)`` — be asserted as a nonoccurrence rather
/// than reviewed by eye.
public protocol ShareConsentPresenting: Sendable {
    /// Shows the consent action for `request` and waits for the user's answer.
    ///
    /// Called at most once per activation. An implementation that cannot present the action
    /// answers ``ShareConsentDecision/cancelled``: there is no consent-presentation failure
    /// case, because a handoff that was never consented to and a handoff whose consent
    /// screen never appeared lead to exactly the same place.
    func presentConsent(for request: ShareConsentRequest) async -> ShareConsentDecision
}

// MARK: - The manual instruction

/// How the containing application is reached after a successful handoff.
///
/// One case, on purpose. The share extension point cannot open the containing application on
/// iOS, so a build that claimed otherwise would be claiming platform behavior Apple does not
/// document. Leaving programmatic launch unrepresentable means there is no value to select,
/// no branch to take, and nothing for a later change to reach for; the accompanying
/// source-scan test refuses the framework surfaces such a workaround would need.
public enum HandoffLaunchMechanism: String, Hashable, Sendable, CaseIterable {
    /// The user opens DefAIke themselves, following the displayed instruction.
    case manualUserAction = "manual-user-action"
}

/// The explicit "Open DefAIke" instruction the extension shows.
///
/// It carries an ``ApprovedCopyKey`` rather than text. Version 1 wording is an unresolved
/// approved-copy decision, and compiling an English sentence in here would make an
/// unapproved string look approved; the presentation layer resolves the key against the
/// versioned copy artifact and a key with no approved value is a fail-closed presentation
/// error rather than a fallback string.
public struct ManualOpenInstruction: Hashable, Sendable {
    /// The only way the containing application is reached.
    public static let launchMechanism: HandoffLaunchMechanism = .manualUserAction

    /// Approved copy addressing the instruction. Never the instruction's text.
    public let copyKey: ApprovedCopyKey

    public init(copyKey: ApprovedCopyKey) {
        self.copyKey = copyKey
    }
}

// MARK: - Outcomes

/// One published handoff, and what the user has to be told about it.
///
/// The ticket's existence is the commit: exactly one pending `AwaitingMainApp` session
/// exists from here, under the candidate identifier the extension allocated
/// (Requirements 2.3 and 11.12).
public struct PublishedHandoff: Hashable, Sendable {
    public let ticket: ShareTransferTicket

    /// The manual instruction, because nothing else moves the handoff forward.
    public let instruction: ManualOpenInstruction

    public init(ticket: ShareTransferTicket, instruction: ManualOpenInstruction) {
        self.ticket = ticket
        self.instruction = instruction
    }

    /// The pending session this handoff created.
    public var sessionID: AnalysisSessionID { ticket.sessionID }
}

/// A handoff the user already consented to that is still waiting for the main application.
///
/// The single ready-slot rule: a later activation offers a recovery instruction to open or
/// discard the pending handoff rather than replacing it silently, so no consented handoff is
/// ever discarded on the user's behalf (design, Share Extension handoff sequence).
public struct PendingHandoffRecovery: Hashable, Sendable {
    /// The transfer that is already published. Carries no ticket: a pending handoff is
    /// something to open or discard, and nothing here re-presents its contents.
    public let pendingTransfer: ShareTransferID

    /// The same manual instruction, because opening DefAIke is what resolves it.
    public let instruction: ManualOpenInstruction

    public init(pendingTransfer: ShareTransferID, instruction: ManualOpenInstruction) {
        self.pendingTransfer = pendingTransfer
        self.instruction = instruction
    }
}

/// Where one Share activation ended.
///
/// Exactly one case leaves anything behind. ``published(_:)`` means one ready transfer and
/// one pending session exist; every other case means the App Group container holds no
/// staging directory for this attempt, no session was created, no main-application analysis
/// began, and no evidence verdict exists (Requirement 2.4 and Property 7).
public enum ShareHandoffOutcome: Hashable, Sendable {
    /// One transfer was published atomically. The user must open DefAIke manually.
    case published(PublishedHandoff)

    /// The activation did not offer exactly one item, so nothing was read.
    case activationRefused(ShareActivationRefusal)

    /// The user declined the visible consent action.
    case declined

    /// The user cancelled, on either side of the consent action.
    case cancelled

    /// A consented handoff is already waiting. Nothing new was staged.
    case pendingHandoff(PendingHandoffRecovery)

    /// Staging began and did not reach publication.
    case failed(ShareStagingFailure)

    /// The published ticket, or `nil` in every other outcome.
    ///
    /// The one accessor, so "did this activation create a session?" has a single answer and
    /// no other case can be read as though it had.
    public var publishedTicket: ShareTransferTicket? {
        guard case .published(let handoff) = self else { return nil }
        return handoff.ticket
    }
}
