import DefAIkeDomain

// Everything the four disclosure destinations are projected from, as one immutable value.
//
// Requirement 8.17 requires a user-accessible path from every Evidence Report to six
// destinations. Task 11.3 fixed that the paths exist; this task builds what they lead to.
// The destinations are not screens that read the world - they are projections of one input
// value, exactly as ``AnalysisScreen`` is a projection of a coordinator snapshot and
// ``AccessibilitySemanticsSnapshot`` is a projection of a screen. A host test constructs the
// input, projects it, and asserts everything the screens state, with no view, no navigation
// stack, and no device.
//
// The input is deliberately made of *release artifacts* rather than of controller handles:
//
//   * the signed Release Capability Manifest, because whether local Content Credential
//     validation is part of this release is a capability fact and the privacy explanation
//     has to describe it truthfully in a pixel-only build as well as a provenance-enabled
//     one (Requirement 9.16);
//   * the signed Data Lifecycle Policy, because Requirement 9.7's five cleanup deadlines
//     are supplied numbers and Requirement 9.16 requires the explanation to cover them.
//     They are carried through unchanged; none is chosen, defaulted, or rounded here;
//   * the Release Readiness Record, because the model identity, the independent
//     non-peer-reviewed status, the inherited red-team status, the versioned active known
//     limitations, and the correction channel are all externally supplied conclusions
//     recorded there (Requirements 8.17, 14.9, and 14.14). Nothing in this module derives
//     any of them;
//   * the immutable Analysis Session binding, because a destination reached from a report
//     describes *that session's* bundle and policies, not whatever the newest artifact
//     says; and
//   * the session's Approved Verdict Copy binding, because the only sentences these
//     screens may show are the ones it resolves.
//
// The projection refuses rather than reconciles. Five records have to agree about which
// session, capability manifest, lifecycle policy, and model this is, and a disagreement is
// version skew rather than a renderable state - so it throws, and no screen is produced. In
// particular, a governance record naming a different model than the session ran under would
// disclose one model's release status beside another model's verdict, which is exactly the
// disclosure Requirement 14.9 exists to make reliable.
//
// This module depends on the domain and on nothing else. There is no coordinator here, no
// privacy controller, no navigation, and no file access; the composition root reads those
// and fills in this value.

/// One of the four destinations Requirement 8.17's paths lead to.
///
/// Four screens for six destinations, because two pairs of destinations are the same screen:
/// the selected model identity and the two release-status disclosures are one
/// model-information screen, and the measured limitations are the scope-and-limitations
/// screen reached through the same path.
public enum DisclosureScreenKind: String, Hashable, Sendable, CaseIterable {
    /// The in-application privacy explanation (Requirement 9.16).
    case privacy

    /// Model identity, independent release status, and inherited red-team status
    /// (Requirements 8.17 and 14.9).
    case modelInformation = "model-information"

    /// The evidence scope, the unsupported Version 1 scopes, and what pixel evidence does
    /// not establish (Requirements 1.10, 1.15, 8.10, and 8.11).
    case scopeAndLimitations = "scope-and-limitations"

    /// The externally supplied correction channel (Requirement 14.14).
    case correctionChannel = "correction-channel"

    /// The report path that reaches this screen.
    ///
    /// Total, and consistent with ``RequiredDisclosureDestination/path`` by construction:
    /// both the model-information screen and the scope-and-limitations screen are reached
    /// through the model-information path, which is the path task 11.3 already mapped the
    /// measured-limitations destination to.
    public var entryPath: ReportDisclosurePath {
        switch self {
        case .privacy: .privacyBehavior
        case .modelInformation, .scopeAndLimitations: .modelInformation
        case .correctionChannel: .correctionChannel
        }
    }
}

extension RequiredDisclosureDestination {
    /// The screen that presents this destination.
    ///
    /// Total, with no `default`, so a new required destination cannot be added without
    /// naming the screen that answers for it. Together with ``DisclosureScreens``' four
    /// non-optional members, this is what makes "a path from every Evidence Report to every
    /// destination" structural rather than a navigation convention.
    public var screen: DisclosureScreenKind {
        switch self {
        case .selectedModelIdentity, .independentNonPeerReviewedReleaseStatus,
            .invalidInheritedRedTeamStatus:
            .modelInformation
        case .measuredLimitations: .scopeAndLimitations
        case .privacyBehavior: .privacy
        case .correctionChannel: .correctionChannel
        }
    }
}

/// Everything the four disclosure destinations are projected from.
///
/// A plain value. Constructing one is a copy of five records the composition root already
/// holds, and holding one leaks nothing: there are no bytes, dimensions, pixels, logits, or
/// evidence fields anywhere in it.
public struct DisclosureScreenInput: Hashable, Sendable {
    /// The signed capability manifest this build is approved to run under.
    public let capabilities: ReleaseCapabilityManifest

    /// The signed policy that fixes every cleanup deadline (Requirement 9.7).
    public let lifecyclePolicy: DataLifecyclePolicy

    /// The auditable record carrying the externally supplied disclosures.
    public let release: ReleaseReadinessRecord

    /// The immutable binding of the session these destinations were reached from.
    public let session: AnalysisSessionBinding

    /// The approved Evidence Scope that session was bound to.
    ///
    /// Supplied rather than reconstructed. The domain refuses a scope that omits any required
    /// covered or uncovered statement, so carrying the artifact's own value means the
    /// limitations screen cannot understate the limits and cannot disagree with the scope the
    /// session's report already stated (Requirement 8.10).
    public let scope: EvidenceScope

    /// That session's Approved Verdict Copy binding.
    public let copy: ApprovedCopyBinding

    public init(
        capabilities: ReleaseCapabilityManifest,
        lifecyclePolicy: DataLifecyclePolicy,
        release: ReleaseReadinessRecord,
        session: AnalysisSessionBinding,
        scope: EvidenceScope,
        copy: ApprovedCopyBinding
    ) {
        self.capabilities = capabilities
        self.lifecyclePolicy = lifecyclePolicy
        self.release = release
        self.session = session
        self.scope = scope
        self.copy = copy
    }
}

/// Why the disclosure destinations could not be projected.
///
/// No `unknown` case, no case carrying substitute content, and no case a caller can turn
/// into a screen. An unprojectable input yields no screens rather than partial ones, which
/// is the same fail-closed rule the copy and report layers already follow.
public enum DisclosureAssemblyError: Error, Hashable, Sendable {
    /// The approved copy binding belongs to a different session than the supplied binding.
    case copyBindingSessionMismatch(session: AnalysisSessionID, binding: AnalysisSessionID)

    /// One record was bound to a different Release Capability Manifest than the one
    /// supplied, so the records disagree about the enabled capability set - and therefore
    /// about what the privacy explanation should say about provenance validation.
    case capabilityManifestMismatch(
        source: DisclosureRecordSource,
        expected: ArtifactID,
        found: ArtifactID
    )

    /// The session ran under a different Data Lifecycle Policy than the one supplied, so
    /// the deadlines shown would not be the deadlines that applied.
    case lifecyclePolicyMismatch(session: ArtifactID, supplied: ArtifactID)

    /// The governance record discloses a different model than the session was bound to.
    ///
    /// Refused rather than shown. Disclosing one model's independent release status and
    /// inherited red-team status beside another model's verdict would make the disclosure
    /// Requirement 14.9 requires actively misleading.
    case modelIdentityMismatch(session: ModelIdentity, governance: ModelIdentity)

    /// The release record's active-limitations gate is not satisfied, so there is no
    /// published versioned limitations artifact to point a user at (Requirement 14.14).
    case activeLimitationsNotPublished(outcome: GateOutcome)

    /// The release record's correction-channel gate is not satisfied, so there is no
    /// supplied correction channel to present (Requirement 14.14).
    ///
    /// Failing closed here rather than showing an empty screen is the point: a correction
    /// channel a user cannot reach is indistinguishable from none, and inventing an address
    /// to fill the gap is forbidden.
    case correctionChannelNotSupplied(outcome: GateOutcome)

    /// Approved copy for a required surface could not be resolved. Wraps the copy layer's
    /// own refusal unchanged.
    case copy(PresentationCopyError)
}

/// Which record disagreed about the capability manifest.
///
/// Named so a version-skew failure is diagnosable without widening the error, following
/// ``CopyCompatibilitySource``.
public enum DisclosureRecordSource: String, Hashable, Sendable, CaseIterable {
    /// The immutable Analysis Session binding.
    case sessionBinding = "session-binding"
    /// The Approved Verdict Copy binding.
    case copyBinding = "copy-binding"
    /// The Release Readiness Record.
    case releaseRecord = "release-record"
}
