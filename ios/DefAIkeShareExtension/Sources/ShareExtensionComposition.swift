import DefAIkeDomain
import DefAIkeSharedTransfer
import Foundation

// The Share Extension's composition root.
//
// One place assembles the whole graph, and it is the only place that may: the startup gate, the
// startup cleanup, the App Group transfer store, the item-provider access, the visible consent
// action, the resource governor bound to this target's budget, and the ingest coordinator that
// orders them. Every library module here already refuses to reach the ones it must not; what did
// not exist until this file is the wiring, and the order it happens in.
//
// MARK: - Why a ready transfer ticket cannot be reached early
//
// "Publish a handoff only after every startup gate passes" is made structural three times over,
// the same three ways the main application makes its ingest surface unreachable, and none of the
// three is a flag a later change could forget to check:
//
//   1. **`ShareExtensionAdmission` is unforgeable.** Its initializer is `fileprivate` to
//      `ShareExtensionStartupGate.swift`, and that file constructs one in exactly one place —
//      after all eight gates returned. Holding one *is* the evidence.
//   2. **The handoff surface requires one.** `AdmittedShareExtension`'s initializer is
//      `fileprivate` to this file and takes the admission, and its only call site is inside
//      `assemble(...)`, which itself cannot be called without one.
//   3. **A blocked startup has no handoff surface at all.** `ShareExtensionStartupOutcome` is an
//      enum whose blocked case carries a refusal and nothing else. There is no
//      `AdmittedShareExtension` to call a method on, so staging a handoff in a blocked extension
//      is a compile error rather than a disabled button.
//
// And one more, specific to this target, because the thing that must not escape is not a *surface*
// but a *value*: a published ticket is the Share route's session-creation commit, so
// `ReadyHandoffReceipt` — the only shape in which this target ever hands a published ticket to its
// view layer — also has a `fileprivate` initializer that takes the admission. A
// `ShareTransferTicket` on its own is just a record; it becomes *this build's committed pending
// session* only by passing through a receipt that cannot be built without the gate's evidence.
//
// MARK: - Why one-item enforcement is not delegated to the activation rule
//
// The Info.plist activation rule offers this extension for at most one image. That is a rule about
// what a share sheet *presents*, enforced by the host, and this target treats it as no evidence at
// all:
//
//   * `SharedItemProviderRegistry.register(_:)` registers every provider the host offered,
//     with each provider's true attachment count, and returns a `ShareActivation` carrying all of
//     them. It never takes `first`, never clamps a count to one, and never drops a provider to
//     make a total work out.
//   * `ShareActivation.resolvedCandidate` is the only way from an activation to a provider, and it
//     refuses zero providers, more than one provider, and a sole provider offering any count other
//     than one — before the provider is touched (Requirement 2.7).
//   * `ConfirmedConsent`'s initializer refuses any count other than one, so a consent token for a
//     multi-item activation is not representable.
//   * `ShareExtensionIngestCoordinator.attemptStaging(of:consent:)` counts again at staging time,
//     because an adapter reached directly through the `ShareTransferStaging` port must refuse the
//     same way.
//
// So a host that offers two attachments despite the activation rule is refused at runtime, by a
// value, with nothing read and nothing staged.
//
// MARK: - Why a startup refusal is not an Analysis Error
//
// The ten `AnalysisError` categories are closed, and a startup refusal sits outside them by
// construction: `ShareExtensionStartupRefusal` has no case carrying an `AnalysisError` and no
// conversion to one. A failed gate means nothing was staged, so there is no session, no stage, and
// no evidence to report. The same holds for an activation refusal, which is a
// `ShareActivationRefusal` — its own documentation records that it is deliberately not an `Error`,
// because nothing throws it.

// MARK: - Startup outcome

/// What the Share Extension's startup produced.
///
/// Two cases, and only one of them carries a handoff surface. That is the whole of "publish only
/// after every startup gate passes": there is no third case, and the blocked case has no member a
/// staging call could be made through.
enum ShareExtensionStartupOutcome: Sendable {
    /// No handoff surface was exposed, and why.
    case blocked(ShareExtensionStartupRefusal)

    /// Every gate passed. This value is the only handoff surface there is.
    case ready(AdmittedShareExtension)

    /// The admitted extension, or `nil` when startup was refused.
    var admitted: AdmittedShareExtension? {
        guard case let .ready(extensionGraph) = self else { return nil }
        return extensionGraph
    }

    /// Why startup was refused, or `nil` when it was not.
    var refusal: ShareExtensionStartupRefusal? {
        guard case let .blocked(refusal) = self else { return nil }
        return refusal
    }
}

// MARK: - The committed handoff

/// One published transfer, as this build's committed pending Analysis Session.
///
/// The wrapper exists for the reason the file comment gives: a `ShareTransferTicket` is a record
/// anyone can construct, and what must be unreachable without the startup admission is the claim
/// that *this build committed a pending session*. The initializer is `fileprivate` to this file and
/// takes the admission, so the only route to a receipt runs through `AdmittedShareExtension`, which
/// runs through the gate.
///
/// It carries no bytes, no file name, no host application identity, and no digest of user content —
/// only the identifiers the extension has to be able to name afterwards, and the approved
/// instruction the user has to be shown.
struct ReadyHandoffReceipt: Sendable {
    /// The transfer slot the main application will claim.
    let transferID: ShareTransferID

    /// The pending session the publication created, under the candidate identifier this extension
    /// allocated while staging (Requirements 2.3 and 11.12).
    let sessionID: AnalysisSessionID

    /// The explicit "Open DefAIke" instruction, because nothing else moves the handoff forward:
    /// the share extension point cannot launch the containing application on iOS.
    let instruction: PresentableApprovedText

    fileprivate init(
        admission: ShareExtensionAdmission,
        ticket: ShareTransferTicket
    ) {
        self.transferID = ticket.transferID
        self.sessionID = ticket.sessionID
        self.instruction = admission.copy.manualOpenInstruction
    }
}

/// A consented handoff that is already waiting for the main application.
///
/// The single ready-slot rule's user-visible half. Also admission-gated, for the same reason: it
/// names a committed pending session.
struct PendingHandoffNotice: Sendable {
    let transferID: ShareTransferID

    /// The recovery instruction: open or discard the pending handoff. Never a silent replacement.
    let recovery: PresentableApprovedText

    /// The same manual instruction, because opening DefAIke is what resolves it.
    let instruction: PresentableApprovedText

    fileprivate init(admission: ShareExtensionAdmission, transferID: ShareTransferID) {
        self.transferID = transferID
        self.recovery = admission.copy.pendingHandoffRecovery
        self.instruction = admission.copy.manualOpenInstruction
    }
}

/// Where one activation ended, in the vocabulary this target's view layer reads.
///
/// A narrowing of `ShareHandoffOutcome` that keeps every distinction and adds the admission gate to
/// the two cases that name a committed session. Exactly one case leaves anything behind: every
/// other case means the App Group container holds no staging directory for this attempt, no session
/// was created, no main-application analysis began, and no evidence verdict exists
/// (Requirement 2.4).
enum AdmittedHandoffOutcome: Sendable {
    /// One transfer was published atomically. The user must open DefAIke manually.
    case published(ReadyHandoffReceipt)

    /// The activation did not offer exactly one item, so nothing was read.
    ///
    /// Runtime counting, not the activation rule (Requirement 2.7).
    case activationRefused(ShareActivationRefusal)

    /// The user declined the visible consent action (Requirement 2.4).
    case declined

    /// The user cancelled, on either side of the consent action.
    case cancelled

    /// A consented handoff is already waiting. Nothing new was staged.
    case pendingHandoff(PendingHandoffNotice)

    /// Staging began and did not reach publication (Requirements 11.8 and 11.13).
    case failed(ShareStagingFailure)

    /// The committed pending session, or `nil` in every other outcome.
    ///
    /// The one accessor, so "did this activation create a session?" has a single answer and no
    /// other case can be read as though it had.
    var committedSession: AnalysisSessionID? {
        guard case let .published(receipt) = self else { return nil }
        return receipt.sessionID
    }
}

// MARK: - The admitted extension

/// The assembled graph, and the only handoff surface in the Share Extension.
///
/// Reachable only from `ShareExtensionComposition.start(...)`, and only after every startup gate
/// passed: the initializer is `fileprivate` and takes the `ShareExtensionAdmission` that proves it.
///
/// `Sendable` and immutable. The only mutable state in the graph is inside the actors it holds —
/// the transfer store, the protected file store, the provider registry, the governor — each of
/// which owns its own.
final class AdmittedShareExtension: Sendable {

    /// Permission to stage a handoff, and everything staging binds.
    let admission: ShareExtensionAdmission

    /// Turns one activation into at most one published transfer.
    private let ingest: ShareExtensionIngestCoordinator

    /// The registry one activation writes the host's providers into.
    let providers: SharedItemProviderRegistry

    /// Where the visible consent action is presented.
    ///
    /// Exposed so the principal view controller can attach itself after startup. A host with
    /// nothing attached answers `cancelled`, so an unattached graph reads no byte rather than
    /// staging without a consent action (Requirements 2.2 and 11.10).
    let consentHost: ShareConsentHost

    /// The coordinated App Group transfer store. Held so the pending slot can be inspected without
    /// going through an activation.
    private let transfers: SharedTransferStore

    fileprivate init(
        admission: ShareExtensionAdmission,
        ingest: ShareExtensionIngestCoordinator,
        providers: SharedItemProviderRegistry,
        transfers: SharedTransferStore,
        consentHost: ShareConsentHost
    ) {
        self.admission = admission
        self.ingest = ingest
        self.providers = providers
        self.transfers = transfers
        self.consentHost = consentHost
    }

    /// Runs one activation from the host's offered items to at most one published transfer.
    ///
    /// The order is the coordinator's and it is load-bearing: the activation is counted and the
    /// pending slot is checked before the consent action appears, and the provider is unreachable
    /// until consent has been confirmed — so a refused activation and a declined or cancelled
    /// consent read no byte of the shared item at all (Requirements 2.2, 2.4, 2.7, and 11.10).
    ///
    /// `items` is everything the host offered. It is not pre-filtered, not sorted, and not
    /// truncated: the counts the refusal path needs have to survive to it.
    ///
    /// Main-actor isolated because the offered items are UIKit-supplied `NSItemProvider`s, which are
    /// not `Sendable` and must not cross an isolation boundary. Registration therefore happens here,
    /// where the items already are, and only the `Sendable` `ShareActivation` travels onward.
    @MainActor
    func handleActivation(items: [OfferedExtensionItem]) async -> AdmittedHandoffOutcome {
        let activation = providers.register(items)
        let outcome = await ingest.handleActivation(activation)
        // Every activation ends here, so a token from a finished activation names nothing and a
        // borrowed representation cannot be reached after the fact.
        providers.clear()

        switch outcome {
        case let .published(handoff):
            return .published(
                ReadyHandoffReceipt(admission: admission, ticket: handoff.ticket)
            )
        case let .activationRefused(refusal):
            return .activationRefused(refusal)
        case .declined:
            return .declined
        case .cancelled:
            return .cancelled
        case let .pendingHandoff(recovery):
            return .pendingHandoff(
                PendingHandoffNotice(
                    admission: admission,
                    transferID: recovery.pendingTransfer
                )
            )
        case let .failed(failure):
            return .failed(failure)
        }
    }

    /// The consented handoff already waiting for the main application, if any.
    ///
    /// Peeking takes no ownership and reads no image bytes. `nil` covers both an empty slot and an
    /// unusable one: an expired, ambiguous, or defective slot is not a handoff anyone can open, and
    /// the transfer store clears it on the next publication attempt rather than letting it block
    /// every future handoff.
    func pendingHandoff() async -> PendingHandoffNotice? {
        guard let state = try? await transfers.readySlotState(),
            case let .published(transfer) = state
        else {
            return nil
        }
        return PendingHandoffNotice(
            admission: admission,
            transferID: transfer.ticket.transferID
        )
    }
}

// MARK: - The composition root

/// Assembles the Share Extension and runs its startup flow.
///
/// A namespace rather than a value: there is one extension graph per activation process, and a
/// second one would be a second startup gate.
enum ShareExtensionComposition {

    /// Which target this composition is, selecting the Resource Budget.
    static let target: ExecutionTarget = .shareExtension

    /// Runs startup and returns either a refusal or the one handoff surface.
    ///
    /// The order is part of the contract rather than an implementation detail, because it decides
    /// which cause an audit is told about:
    ///
    /// 1. Read the release-controlled inputs this build carries. An absent one is named.
    /// 2. Observe the running extension's identity. Observation stays separate from comparison.
    /// 3. Run the eight-gate fail-closed preflight, which checks the platform floor, resolves and
    ///    approves the signed artifact set, matches the allowlist entry, binds this target's
    ///    budget, resolves approved wording for every surface a successful handoff shows, resolves
    ///    the App Group container and configures protected storage from the bound budget, requires
    ///    the platform to enforce iOS Data Protection, and removes interrupted transfer material.
    ///    Startup cleanup is inside the gate, at its own step, so it cannot be skipped or reordered
    ///    from here (Requirements 9.9 and 11.16).
    /// 4. Only then assemble the staging graph and expose the handoff surface.
    ///
    /// A refusal at any step returns `blocked` and no `AdmittedShareExtension` is constructed, so
    /// nothing downstream of the gate exists to be called.
    @MainActor
    static func start(
        provisioning: ShareExtensionReleaseProvisioning? = nil,
        bundle: Bundle = .main,
        copyResolver: some ShareExtensionCopyResolving = UnlocalizedShareExtensionCopy(),
        protection: any DataProtectionApplying = PlatformDataProtection(),
        clock: any SessionClock = SystemSessionClock()
    ) async -> ShareExtensionStartupOutcome {
        // Step 1. The release-controlled input set.
        guard let provisioning else {
            return .blocked(.releaseInputsUnprovisioned(unprovisionedInputs(bundle: bundle)))
        }

        // Step 2. The running identity, observed rather than declared.
        let device: DeviceContext
        switch ObservedExtensionIdentity.observed(bundle: bundle) {
        case let .success(observed):
            device = observed
        case let .failure(field):
            return .blocked(.identityUnobservable(field))
        }

        // Step 3. The eight-gate fail-closed preflight.
        let preflight = ShareExtensionPreflight(device: device, provisioning: provisioning)
        let admission: ShareExtensionAdmission
        do {
            admission = try await preflight.run(
                copyResolver: copyResolver,
                protection: protection,
                clock: clock
            )
        } catch {
            return .blocked(error)
        }

        // Step 4. Only now is the staging graph assembled and the handoff surface exposed.
        return assemble(
            admission: admission,
            provisioning: provisioning,
            protection: protection,
            clock: clock
        )
    }

    /// The inputs this repository does not carry, for a startup with no provisioning.
    ///
    /// Reported as one set rather than one at a time, so a release audit sees everything owed
    /// instead of discovering the gaps across successive share invocations. The identifier half is
    /// read from the installed extension; the artifact half has no shipping reader at all.
    static func unprovisionedInputs(
        bundle: Bundle = .main
    ) -> [UnprovisionedExtensionReleaseInput] {
        var gaps: Set<UnprovisionedExtensionReleaseInput> = [.policyArtifactStore]
        if case let .failure(identifierGaps) =
            ShareExtensionReleaseProvisioning.installedIdentifiers(bundle: bundle)
        {
            gaps.formUnion(identifierGaps.inputs)
        }
        if case let .failure(field) = ObservedExtensionIdentity.observed(bundle: bundle) {
            gaps.insert(field == .appBuild ? .applicationBuildIdentity : .observedDeviceIdentity)
        }
        return gaps.sorted { $0.rawValue < $1.rawValue }
    }

    /// Assembles everything downstream of a passed gate.
    ///
    /// Split out so the admission is a parameter: this function cannot run without one, which is
    /// the same structural rule `AdmittedShareExtension`'s `fileprivate` initializer states.
    ///
    /// Every value the graph is built from comes from the admission, which means from a signed
    /// artifact: the protection level from the Extension Execution Policy, the capacity and every
    /// ceiling from the Share Extension Resource Budget, the deadlines from the Data Lifecycle
    /// Policy, and the build identity stamped into each ticket from the observed identity the gate
    /// matched against the allowlist. Nothing here chooses a number, and nothing here has a
    /// fallback.
    @MainActor
    private static func assemble(
        admission: ShareExtensionAdmission,
        provisioning: ShareExtensionReleaseProvisioning,
        protection: any DataProtectionApplying,
        clock: any SessionClock
    ) -> ShareExtensionStartupOutcome {
        let protectionLevel = admission.stagedFileProtection

        // The gate already proved this configuration resolves from the bound budget, and it has
        // released the store it swept with. Rebuilding here rather than carrying that store through
        // the admission keeps the admission a record of *evidence* rather than a container of live
        // actors, which is the same shape `ReleaseAdmission` has in the main application. The two
        // instances never coexist, and the file system is authoritative for finished objects anyway:
        // only in-flight writes are in-process state, and the gate's store had none. A second
        // configuration failure is therefore unreachable, and it still refuses rather than
        // force-unwrapping.
        let storeConfiguration: ProtectedEphemeralFileStore.Configuration
        do {
            storeConfiguration = try ProtectedEphemeralFileStore.configuration(
                rootDirectory: admission.transferRoot,
                budget: admission.budget,
                containerProtection: protectionLevel
            )
        } catch {
            return .blocked(.transferStoreNotConfigurable(error))
        }
        let store = ProtectedEphemeralFileStore(
            configuration: storeConfiguration,
            protection: protection,
            clock: clock
        )

        // The `staging` → `ready` → `claimed` protocol over the App Group container. It owns the
        // single ready slot, the atomic publication, the staged protection level, and the bound
        // policy versions, so the coordinator reads them from it rather than holding a second copy.
        let transfers = SharedTransferStore(
            store: store,
            lifecyclePolicy: admission.configuration.lifecyclePolicy,
            extensionPolicy: admission.extensionPolicy,
            // The identity every published ticket is stamped with, so the claiming application can
            // refuse a ticket from another installed composition (Requirement 2.19).
            buildID: admission.device.appBuild,
            clock: clock
        )

        let providers = SharedItemProviderRegistry()
        let consentHost = ShareConsentHost()

        // `init?` refuses a governor or budget belonging to the other target. Both are this
        // target's by construction here, so a refusal is unreachable — and it is still handled,
        // because a coordinator holding the main application's budget has no correct behavior
        // available to it (Requirement 11.1).
        guard
            let ingest = ShareExtensionIngestCoordinator(
                access: ExtensionItemRepresentationAccess(
                    registry: providers,
                    protectionLevel: protectionLevel,
                    protection: protection
                ),
                consentPresenter: ShareConsentPresenter(copy: admission.copy, host: consentHost),
                transfers: transfers,
                governor: ExtensionResourceGovernor(),
                budget: admission.budget,
                // The approved instruction, carrying a key this build can render.
                instruction: admission.copy.manualOpen
            )
        else {
            return .blocked(
                .identityMismatch(
                    field: "shareExtensionIngest.target",
                    expected: ExecutionTarget.shareExtension.rawValue,
                    found: admission.budget.target.rawValue
                )
            )
        }

        return .ready(
            AdmittedShareExtension(
                admission: admission,
                ingest: ingest,
                providers: providers,
                transfers: transfers,
                consentHost: consentHost
            )
        )
    }
}
