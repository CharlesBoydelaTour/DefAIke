// Binding one accepted input to the complete active verified Model Bundle, once.
//
// `AnalysisSessionBinding` (task 1.2) is the *shape* of the snapshot. This file is the
// act of taking it: which values it is derived from, what is refused before it is taken,
// and what keeps it from changing afterwards.
//
// Three separate guarantees, and they need different mechanisms:
//
//   * **Complete.** Requirement 10.13 activates the six component versions as one tuple,
//     and Requirement 10.14 binds a session to that complete tuple. So the snapshot is
//     derived from one ``BoundModelBundle`` and one ``ReleaseAdmission`` in a single
//     step. There is no partial constructor, no field a caller supplies by hand, and no
//     way to assemble a binding from two bundles.
//   * **Immutable.** Requirement 10.15 keeps every bound component version unchanged
//     while a session is active. Half of that is structural: a ``BoundAnalysisSession``
//     is a value of immutable `let`s, so no later activation can reach into one. The
//     other half is that the analysis path has to *read the snapshot* rather than ask
//     the manager again, which is why the snapshot carries the bound Preprocessing
//     Contract, Calibration Policy, and Resource Budget as values and not as
//     identifiers to look up later. A session that never consults the active pointer
//     again cannot observe an activation.
//   * **Traceable.** Requirements 4.12 and 10.18 make the report state the bound
//     versions, identity, and integrity status. ``BoundAnalysisSession/binding`` and
//     ``BoundAnalysisSession/scope`` are exactly the two values `EvidenceReport`
//     requires beyond its lanes, so report construction is handed the same snapshot the
//     inference path used rather than a second description of it.
//
// The check the *timing* makes necessary: an admission is produced once at startup, and
// an input is accepted later. A rollback in between can make a different bundle active,
// and "prior does not imply trusted" applies to binding as much as to activation. So the
// bundle is re-read at acceptance through the existing port and re-checked against the
// signed manifest, the matched allowlist entry, the running context, and the bound
// policy set. Requirement 10.16 fixes the outcome of any refusal: pixel inference is
// prevented and the session ends with `model-load-error`.
//
// What this file does not do: it never activates, verifies, or rolls back a bundle, and
// it holds no verifier, key, policy value, or budget of its own. Every value it records
// arrives from an approved artifact by way of ``ReleaseAdmission``, and an absent one is
// a refusal rather than a default.

// MARK: - Refusals

/// Why an accepted input was not bound to the active verified Model Bundle.
///
/// Deliberately separate from the closed ten-value ``AnalysisError`` set, in the same
/// way ``ModelBundleVerificationError`` is: a session sees exactly one category for
/// every case below, and a release audit needs to know which condition refused the
/// binding. The finding is never presented to a user (Requirement 11.17).
///
/// No case carries a bundle, an admission, or a snapshot. A refusal describes what was
/// refused; it never hands back a value a caller could mistake for a bound one.
public enum SessionBindingRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    /// The admission governs the Share Extension.
    ///
    /// The extension stages bytes and never binds a Model Bundle: it links no Core ML
    /// model and runs no provenance analysis, and its Resource Budget is not the one
    /// that governs analysis (Requirements 11.1 and 11.11). An analysis session bound
    /// under that admission would carry the wrong budget and claim a capability the
    /// target does not have.
    case bindingTargetNotMainApplication(ExecutionTarget)

    /// This session is already bound, and a snapshot is taken exactly once.
    ///
    /// The direct enforcement of Requirement 10.15: rebinding is the one operation that
    /// could change what an active session is bound to, so it is refused rather than
    /// applied. The existing snapshot stands.
    case sessionAlreadyBound(AnalysisSessionID)

    /// More sessions are bound than the binder will track at once.
    ///
    /// A structural safety ceiling, not a concurrency budget: see
    /// ``AnalysisSessionBinder/defaultMaximumBoundSessionCount``.
    case boundSessionCeilingReached(ceiling: Int)

    /// The Model Bundle port did not produce a verified compatible active bundle.
    ///
    /// Carries the port's fault rather than discarding it, which is the opposite of
    /// ``PreflightFailure/verifiedBundleUnavailable(expected:)`` and deliberately so. A
    /// startup gate has no session, so an ``AnalysisError`` there would be an invented
    /// evidence outcome. Here a session exists, and the port's two possibilities do not
    /// mean the same thing: `model-load-error` is a failure terminal and cancellation is
    /// not a failure at all (Requirements 11.17 and 11.18). Collapsing them would report
    /// a cancelled session as a model error.
    case activeBundleUnavailable(AnalysisFault)

    /// The signed capability manifest does not list the active bundle among the ones
    /// this build may use. Being installed and active is not being approved.
    case activeBundleNotInApprovedCatalog(ModelBundleID)

    /// The active bundle is not the bundle the matched allowlist entry's physical-device
    /// evidence was produced against.
    ///
    /// Reachable exactly when something was activated after startup. The entry's gates
    /// passed for one Model Bundle version, so binding a different one would analyze
    /// under a tuple no device evidence covers (Requirements 13.17 and 13.20).
    case activeBundleNotValidatedForConfiguration(
        configuration: ApprovedConfigurationID,
        expected: ModelBundleID,
        found: ModelBundleID
    )

    /// The active bundle is not compatible with this build, capability set, or operating
    /// system version. Nothing falls back to an older or unverified asset.
    case activeBundleNotCompatible(ModelBundleID)

    /// The active bundle's integrity projection is not `.verified`.
    ///
    /// Structurally satisfied today: ``ModelBundleIntegrityStatus`` has one member and
    /// ``BoundModelBundle`` is constructible only from a receipt whose signature and
    /// self-test both passed. Written out anyway, for the same reason the startup gate
    /// writes it out — it is the condition Requirement 10.14 rests on, and a later
    /// vocabulary that gains a second member should refuse here rather than bind
    /// silently.
    case activeBundleIntegrityNotVerified(ModelBundleID)

    /// One component version in the active bundle is not the artifact version this
    /// build's validated policy set binds (Requirements 10.7 and 10.9).
    ///
    /// Names the field rather than carrying a component vocabulary, matching
    /// ``PreflightFailure/identityMismatch(field:expected:found:)``.
    case componentVersionNotBound(field: String, expected: String, found: String)

    /// A loaded Core ML model was offered to a session it does not belong to.
    ///
    /// The runtime half of Requirement 4.1: inference has to execute the model from the
    /// bundle *this* session bound, so a model loaded from any other bundle version is
    /// refused rather than run.
    case loadedModelNotBoundToSession(expected: ModelBundleID, found: ModelBundleID)

    /// The one closed-vocabulary outcome a session may see.
    ///
    /// Requirement 10.16 fixes it for every refusal that concerns the bundle: pixel
    /// inference is prevented and the session ends with `model-load-error` at the
    /// model-load stage. ``activeBundleUnavailable(_:)`` forwards the port's own fault
    /// instead, so a cancelled session stays cancelled.
    public var analysisFault: AnalysisFault {
        switch self {
        case .activeBundleUnavailable(let fault): fault
        default: .analysis(.modelLoadError, stage: .modelLoad)
        }
    }

    public var description: String {
        switch self {
        case let .bindingTargetNotMainApplication(target):
            return """
                an analysis session binds the main application; this admission governs \
                \(target.rawValue)
                """
        case let .sessionAlreadyBound(session):
            return "session \(session.rawValue) is already bound to a Model Bundle snapshot"
        case let .boundSessionCeilingReached(ceiling):
            return "the binder already tracks its ceiling of \(ceiling) bound sessions"
        case let .activeBundleUnavailable(fault):
            return "no verified compatible Model Bundle is active: \(fault)"
        case let .activeBundleNotInApprovedCatalog(bundle):
            return "the capability manifest does not list bundle \(bundle.rawValue)"
        case let .activeBundleNotValidatedForConfiguration(configuration, expected, found):
            return """
                allowlist entry \(configuration.rawValue) was validated against bundle \
                \(expected.rawValue); \(found.rawValue) is active
                """
        case let .activeBundleNotCompatible(bundle):
            return "bundle \(bundle.rawValue) is not compatible with this running context"
        case let .activeBundleIntegrityNotVerified(bundle):
            return "the integrity projection of bundle \(bundle.rawValue) is not verified"
        case let .componentVersionNotBound(field, expected, found):
            return "\(field) must be \(expected), found \(found)"
        case let .loadedModelNotBoundToSession(expected, found):
            return """
                this session is bound to bundle \(expected.rawValue); the loaded model \
                came from \(found.rawValue)
                """
        }
    }
}

// MARK: - The snapshot

/// Everything one Analysis Session is bound to, taken once when its input was accepted.
///
/// Constructible only by ``snapshot(accepting:of:under:)``, so a binding cannot be
/// assembled field by field from values that were never checked against each other.
///
/// The policy *values* are here, not just their identifiers, and that is the point. The
/// validation, preprocessing, and calibration ports each take the artifact they apply as
/// a parameter, so a session that hands them this snapshot's copies applies the versions
/// it was bound to for its whole lifetime. Looking them up again later is what would let
/// an activation change an active session (Requirement 10.15).
///
/// What reaches a report is only ``binding`` and ``scope``, which are identifiers and
/// fixed scope statements. A Calibration Policy carries a false-accusation budget and a
/// Resource Budget carries measured limits, and neither is a user-facing result field, so
/// the values stop at the session and the identifier projection is what an audit reads
/// (Requirements 8.9 and 8.13).
public struct BoundAnalysisSession: Hashable, Sendable {
    /// The identifiers a report exposes (Requirements 4.12 and 10.18).
    public let binding: AnalysisSessionBinding

    /// The complete verified bundle this session runs against.
    ///
    /// The value the model loader is given, so inference executes the model from the
    /// bundle version bound to this session rather than from whatever is active when the
    /// load happens (Requirement 4.1).
    public let bundle: BoundModelBundle

    /// What the evidence covers and does not cover, bound to the bundle's evidence-scope
    /// artifact version.
    public let scope: EvidenceScope

    /// The bound Preprocessing Contract the validator and preprocessor apply.
    public let preprocessingContract: PreprocessingContract

    /// The bound Calibration Policy the evaluator applies.
    public let calibrationPolicy: CalibrationPolicy

    /// The main-application Resource Budget this session's work is measured against.
    public let resourceBudget: ResourceBudget

    /// The bound Provenance Policy, present exactly when this composition enables
    /// on-device Content Credential validation.
    public let provenancePolicy: ProvenancePolicy?

    /// The bound Evidence Fusion Rule, present exactly when this composition can produce
    /// a Combined Summary.
    public let fusionRule: EvidenceFusionRule?

    fileprivate init(
        binding: AnalysisSessionBinding,
        bundle: BoundModelBundle,
        scope: EvidenceScope,
        preprocessingContract: PreprocessingContract,
        calibrationPolicy: CalibrationPolicy,
        resourceBudget: ResourceBudget,
        provenancePolicy: ProvenancePolicy?,
        fusionRule: EvidenceFusionRule?
    ) {
        self.binding = binding
        self.bundle = bundle
        self.scope = scope
        self.preprocessingContract = preprocessingContract
        self.calibrationPolicy = calibrationPolicy
        self.resourceBudget = resourceBudget
        self.provenancePolicy = provenancePolicy
        self.fusionRule = fusionRule
    }

    public var sessionID: AnalysisSessionID { binding.sessionID }

    /// The bound Model Bundle version a report states (Requirement 10.18).
    public var modelBundleID: ModelBundleID { binding.modelBundleID }

    /// The bound model identity a report states (Requirement 10.18).
    public var modelIdentity: ModelIdentity { binding.modelIdentity }

    /// The bound integrity status a report states (Requirement 10.18).
    public var integrityStatus: ModelBundleIntegrityStatus {
        binding.modelBundleIntegrity.status
    }

    /// Which activation produced the bound bundle, so two activations of the same bundle
    /// identifier stay distinguishable in an audit.
    public var activationGeneration: PositiveCount { bundle.activationGeneration }

    /// Whether this composition resolved an available provenance lane.
    public var enablesProvenance: Bool { provenancePolicy != nil }

    /// Whether this composition can produce a Combined Summary.
    public var enablesFusion: Bool { fusionRule != nil }

    /// Whether `model` was loaded from the bundle version this session is bound to.
    ///
    /// All three identities, not just the bundle identifier: two activations can share a
    /// bundle identifier, and the checkpoint identity and Core ML component version are
    /// what Requirement 4.12 makes a report state.
    public func bindsLoadedModel(_ model: BoundCoreMLModel) -> Bool {
        model.bundleID == binding.modelBundleID
            && model.modelIdentity == binding.modelIdentity
            && model.coreMLModelVersion == binding.coreMLModelVersion
    }

    /// Requires `model` to be the one this session bound, and returns it.
    ///
    /// The gate the inference stage passes a loaded model through, so "the Pixel Analyzer
    /// executes the Core ML model from the bundle bound to the session" is a checked
    /// precondition rather than an ordering convention (Requirement 4.1).
    @discardableResult
    public func requireBoundModel(
        _ model: BoundCoreMLModel
    ) throws(SessionBindingRefusal) -> BoundCoreMLModel {
        guard bindsLoadedModel(model) else {
            throw .loadedModelNotBoundToSession(
                expected: binding.modelBundleID,
                found: model.bundleID
            )
        }
        return model
    }
}

// MARK: - Taking the snapshot

extension BoundAnalysisSession {
    /// Snapshots `bundle` and `admission` for the session that accepted `asset`.
    ///
    /// Takes the accepted ingest rather than a bare identifier, so "when an Analysis
    /// Session accepts an input" is expressed in the signature: there is no way to bind a
    /// session that has no retained bytes (Requirement 10.14).
    ///
    /// The checks run before anything is derived, and each one exists because the active
    /// bundle at acceptance need not be the one the startup gate verified:
    ///
    ///   1. the admission governs the main application;
    ///   2. the bundle's integrity projection is `.verified`;
    ///   3. the signed capability manifest lists the bundle;
    ///   4. the matched allowlist entry's device evidence was produced against it;
    ///   5. it is compatible with the running build, capabilities, and operating system;
    ///   6. its Preprocessing Contract, Calibration Policy, and Approved Verdict Copy
    ///      compatibility identifiers are the versions this build's validated policy set
    ///      binds.
    ///
    /// Nothing is derived from a value that failed one of them, so a refusal leaves no
    /// partial binding and no session state behind.
    public static func snapshot(
        accepting asset: ImportedEncodedAsset,
        of bundle: BoundModelBundle,
        under admission: ReleaseAdmission
    ) throws(SessionBindingRefusal) -> BoundAnalysisSession {
        guard admission.target == .mainApplication else {
            throw .bindingTargetNotMainApplication(admission.target)
        }
        guard bundle.integrity.status == .verified else {
            throw .activeBundleIntegrityNotVerified(bundle.bundleID)
        }

        let configuration = admission.configuration
        let manifest = configuration.capabilityManifest
        guard manifest.approvedBundleCatalog.contains(bundle.bundleID) else {
            throw .activeBundleNotInApprovedCatalog(bundle.bundleID)
        }
        let validated = admission.approvedConfiguration.versionTuple.modelBundle
        guard bundle.bundleID == validated else {
            throw .activeBundleNotValidatedForConfiguration(
                configuration: admission.approvedConfiguration.id,
                expected: validated,
                found: bundle.bundleID
            )
        }
        guard bundle.isCompatible(with: admission.context) else {
            throw .activeBundleNotCompatible(bundle.bundleID)
        }

        // The bundle's component versions and the policy artifacts this build read are
        // two independently signed statements about one release. A disagreement means the
        // model was described and calibrated against different policies than the ones
        // governing this session, so the session refuses rather than mixing them.
        let components = bundle.componentVersions
        try require(
            components.preprocessingContract,
            matches: configuration.preprocessingContract.id,
            field: "boundBundle.componentVersions.preprocessingContract"
        )
        try require(
            components.calibrationPolicy,
            matches: configuration.calibrationPolicy.id,
            field: "boundBundle.componentVersions.calibrationPolicy"
        )
        try require(
            components.verdictCopyCompatibility,
            matches: configuration.verdictCopyCatalog.compatibilityID,
            field: "boundBundle.componentVersions.verdictCopyCompatibility"
        )

        // The conditional artifacts are read through the admission's applicability
        // predicates rather than from the optionals directly. `enablesProvenance` is true
        // only when the signed manifest approves the capability *and* the policy it names
        // resolved, so a policy that is present without approval, or approved without a
        // policy, binds nothing (Requirements 6.2 and 7.16).
        let provenancePolicy = admission.enablesProvenance
            ? configuration.provenancePolicy
            : nil
        let fusionRule = admission.enablesFusion ? configuration.fusionRule : nil
        let budget = configuration.resourceBudgets.budget(for: admission.target)

        let binding = AnalysisSessionBinding(
            sessionID: asset.sessionID,
            appBuildID: admission.context.device.appBuild,
            deviceConfigurationID: admission.approvedConfiguration.id,
            modelBundleID: bundle.bundleID,
            modelIdentity: bundle.modelIdentity,
            coreMLModelVersion: components.coreMLModel,
            modelBundleIntegrity: bundle.integrity,
            preprocessingContractID: components.preprocessingContract,
            calibrationPolicyID: components.calibrationPolicy,
            verdictCopyCompatibilityID: components.verdictCopyCompatibility,
            capabilityManifestID: manifest.id,
            provenancePolicyID: provenancePolicy?.id,
            fusionRuleID: fusionRule?.id,
            lifecyclePolicyID: configuration.lifecyclePolicy.id,
            resourceBudgetID: budget.id
        )

        return BoundAnalysisSession(
            binding: binding,
            bundle: bundle,
            // The statement set is fixed by Requirement 8.10; what the bundle supplies is
            // the approved artifact version those statements were released as.
            scope: .version1(id: components.evidenceScope),
            preprocessingContract: configuration.preprocessingContract,
            calibrationPolicy: configuration.calibrationPolicy,
            resourceBudget: budget,
            provenancePolicy: provenancePolicy,
            fusionRule: fusionRule
        )
    }

    private static func require(
        _ found: ArtifactID,
        matches expected: ArtifactID,
        field: String
    ) throws(SessionBindingRefusal) {
        guard found == expected else {
            throw .componentVersionNotBound(
                field: field,
                expected: expected.rawValue,
                found: found.rawValue
            )
        }
    }
}

// MARK: - The binder

/// Binds each accepted input to the active verified Model Bundle exactly once, and keeps
/// that snapshot for the life of the session.
///
/// An actor because the map of bound sessions is shared mutable state, and because every
/// observer of it reads one immutable snapshot in one isolated step.
///
/// Actor isolation alone is not sufficient for ``bind(accepting:)``, and the difference
/// matters here in the same way it does for activation. Reading the active bundle
/// suspends, and an actor does not hold its executor across a suspension, so two
/// overlapping binds for one session could both find the slot empty and the later write
/// would silently replace a snapshot an active session is already using. The admission
/// checks therefore run again after the suspension, and the first writer wins: a second
/// bind for a session that is now bound is refused, never applied.
public actor AnalysisSessionBinder {
    /// Structural ceiling on simultaneously bound sessions.
    ///
    /// A safety bound in the same sense as ``ArtifactEncodingLimits``' structural
    /// ceilings: it keeps the map from growing without limit if a caller ever fails to
    /// release a session, and it expresses no policy, budget, or concurrency decision.
    /// Version 1 analyzes one image per session and commits exactly one terminal, so a
    /// correctly composed build releases each snapshot and never approaches it. It is
    /// overridable, so a caller with an approved bound can supply one.
    public static let defaultMaximumBoundSessionCount = 8

    /// The startup admission every binding is derived from.
    ///
    /// Held rather than passed per call, because permission to expose ingest is a
    /// property of the process: a second admission would be a second startup gate.
    private let admission: ReleaseAdmission

    /// The Model Bundle port, read at acceptance through its existing member.
    private let bundles: any ModelBundleManaging

    private let maximumBoundSessionCount: Int

    /// One immutable snapshot per active session.
    private var boundSessions: [AnalysisSessionID: BoundAnalysisSession] = [:]

    public init(
        admission: ReleaseAdmission,
        bundles: any ModelBundleManaging,
        maximumBoundSessionCount: Int = AnalysisSessionBinder.defaultMaximumBoundSessionCount
    ) {
        self.admission = admission
        self.bundles = bundles
        self.maximumBoundSessionCount = max(1, maximumBoundSessionCount)
    }

    /// Reads the active verified bundle and snapshots it for the accepting session.
    ///
    /// The bundle is read now rather than taken from the admission, because activation or
    /// rollback may have happened since startup and a session must bind what is active
    /// when its input is accepted (Requirement 10.14). Every refusal leaves the map
    /// unchanged, so a session that fails to bind holds nothing.
    public func bind(
        accepting asset: ImportedEncodedAsset
    ) async throws(SessionBindingRefusal) -> BoundAnalysisSession {
        // Refused before the port is called: an obvious rebind should not read the active
        // pointer at all.
        try admitBinding(for: asset.sessionID)

        let active: BoundModelBundle
        do {
            active = try await bundles.verifiedActiveBundle(for: admission.context)
        } catch {
            throw .activeBundleUnavailable(error)
        }

        // Checked again after the suspension. This is the check that makes the guarantee,
        // rather than the one above.
        try admitBinding(for: asset.sessionID)

        let snapshot = try BoundAnalysisSession.snapshot(
            accepting: asset,
            of: active,
            under: admission
        )
        boundSessions[asset.sessionID] = snapshot
        return snapshot
    }

    /// The snapshot one session is bound to, or `nil` when it is not bound.
    ///
    /// Always the snapshot taken at acceptance, whatever has been activated since. The
    /// active pointer is not consulted here, which is why it cannot be observed
    /// (Requirement 10.15).
    public func boundSession(_ id: AnalysisSessionID) -> BoundAnalysisSession? {
        boundSessions[id]
    }

    /// Forgets one session's binding, returning it if there was one.
    ///
    /// Called when a session reaches a terminal outcome. Idempotent: releasing an unbound
    /// session is not an error, so a repeated cleanup pass cannot fail.
    @discardableResult
    public func release(_ id: AnalysisSessionID) -> BoundAnalysisSession? {
        boundSessions.removeValue(forKey: id)
    }

    /// The sessions currently bound.
    public var boundSessionIDs: Set<AnalysisSessionID> { Set(boundSessions.keys) }

    /// How many sessions are currently bound.
    public var boundSessionCount: Int { boundSessions.count }

    /// Whether one more session may be bound under `id`.
    private func admitBinding(
        for id: AnalysisSessionID
    ) throws(SessionBindingRefusal) {
        guard boundSessions[id] == nil else { throw .sessionAlreadyBound(id) }
        guard boundSessions.count < maximumBoundSessionCount else {
            throw .boundSessionCeilingReached(ceiling: maximumBoundSessionCount)
        }
    }
}
