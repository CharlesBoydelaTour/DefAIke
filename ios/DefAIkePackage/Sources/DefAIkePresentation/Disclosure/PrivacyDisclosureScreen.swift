import DefAIkeDomain

// The in-application privacy explanation, as a value.
//
// Requirement 9.16 names eight topics the explanation must cover: local pixel inference,
// conditional local provenance validation, selected-item permissions, ephemeral retention,
// absence of telemetry, bundled-model behaviour, cleanup deadlines, and deletion behaviour.
// Requirements 1.6 through 1.9 add four more claims a user has to be able to read: the
// project is nonprofit, analysis costs nothing, needs no account, and shows no advertising.
//
// Two different kinds of thing are needed to satisfy those, and the split is what this file
// is organised around:
//
//   * **Facts.** Whether provenance validation is part of this release, what the five
//     cleanup deadlines are, which data practices are absent, whether analysis works with
//     no network. Every one of these is derivable from a signed artifact or true of the
//     build by construction, so each is a non-optional member of a closed vocabulary here.
//     A topic cannot be dropped, because there is no optional member to leave `nil`.
//   * **Sentences.** The paragraph a user actually reads. There is exactly one approved
//     surface for the whole explanation, and it is resolved unconditionally. Every other
//     sentence these topics would need - a per-topic label, the provenance availability
//     statement, a deadline's unit, an absent practice's name, the funding statement - has
//     no approved wording, and is recorded in ``UnapprovedDisclosureSurface`` rather than
//     written here.
//
// So the screen is honest in both directions at once. Structurally it proves that all eight
// topics and all four funding claims are answered; textually it shows one approved paragraph
// and records that the rest of the wording does not exist yet. That is a far more useful
// state to hand task 11.8 than a screen full of plausible sentences nobody approved.
//
// What the screen deliberately does not contain: a network client, a storage handle, a
// deletion trigger, or any way to change what it describes. It reports the privacy
// behaviour; the Privacy Controller performs it, and this module cannot reach that
// component at all.

/// One topic Requirement 9.16 requires the privacy explanation to cover.
///
/// Closed and enumerable, so a test can assert that every topic is answered rather than
/// checking a prose paragraph for keywords. Removing a case would be removing a requirement.
public enum PrivacyTopic: String, Hashable, Sendable, CaseIterable {
    /// Pixel inference runs on the device.
    case localPixelInference = "local-pixel-inference"

    /// Content Credential validation, when this release includes it, also runs on the
    /// device.
    case conditionalLocalProvenanceValidation = "conditional-local-provenance-validation"

    /// Only the single item a user selected is reachable.
    case selectedItemPermission = "selected-item-permission"

    /// Session material exists only while the session does.
    case ephemeralRetention = "ephemeral-retention"

    /// No analytics, diagnostics, third-party crash reporting, or identifiers.
    case absenceOfTelemetry = "absence-of-telemetry"

    /// The model ships inside the application and is never fetched.
    case bundledModelBehavior = "bundled-model-behavior"

    /// The supplied numeric deadlines within which session material is removed.
    case cleanupDeadlines = "cleanup-deadlines"

    /// What removal means and what it leaves behind.
    case deletionBehavior = "deletion-behavior"
}

/// Where pixel inference runs.
///
/// One case by construction (Requirement 9.1). There is no remote, hybrid, or fallback
/// inference value, because there is no remote inference path in the application to describe.
public enum PixelInferenceLocality: String, Hashable, Sendable, CaseIterable {
    /// Inference runs on the user's device.
    case onDevice = "on-device"
}

/// Whether local Content Credential validation is part of this release.
///
/// Derived from the signed capability manifest, never from a build flag read here. This is
/// the value that makes Requirement 9.16's "conditional local provenance validation"
/// truthful in both capability compositions: a pixel-only build links no validator and says
/// so, and a provenance-enabled build says the opposite. Neither answer is a default.
public enum LocalProvenanceValidationAvailability: String, Hashable, Sendable, CaseIterable {
    /// This release validates Content Credentials on the device.
    case validatedOnDevice = "validated-on-device"

    /// This release includes no Content Credential validation at all.
    ///
    /// Not "found nothing" and not "could not tell": the capability is absent from the
    /// build, which is the same distinction Requirement 8.8 draws for the evidence lane.
    case notPartOfThisRelease = "not-part-of-this-release"
}

/// Which photo-library access analysis uses.
///
/// One case by construction (Requirements 9.4 and 9.5). Full-library access is not a value
/// this type can take, so the explanation cannot describe an access level the application
/// does not request.
public enum PhotoAccessScope: String, Hashable, Sendable, CaseIterable {
    /// Only the single item selected for this session.
    case selectedItemOnly = "selected-item-only"
}

/// One data practice this release does not perform.
///
/// Requirements 9.10 through 9.13 name these five, and Requirement 9.18 has the Release
/// Process verify their absence in the build. Enumerating them as a closed set means the
/// privacy screen states five specific absences rather than one vague reassurance, and means
/// a test can assert that all five are stated.
public enum AbsentDataPractice: String, Hashable, Sendable, CaseIterable {
    /// No analytics collection (Requirement 9.10).
    case analyticsCollection = "analytics-collection"

    /// No custom diagnostic collection or transmission (Requirement 9.11).
    case customDiagnosticTransmission = "custom-diagnostic-transmission"

    /// No third-party crash-reporting service (Requirement 9.12).
    case thirdPartyCrashReporting = "third-party-crash-reporting"

    /// No analytics identifier (Requirement 9.13).
    case analyticsIdentifier = "analytics-identifier"

    /// No advertising identifier (Requirement 9.13).
    case advertisingIdentifier = "advertising-identifier"

    /// The requirement that forbids this practice, as a stable reference.
    public var forbiddenBy: String {
        switch self {
        case .analyticsCollection: "9.10"
        case .customDiagnosticTransmission: "9.11"
        case .thirdPartyCrashReporting: "9.12"
        case .analyticsIdentifier, .advertisingIdentifier: "9.13"
        }
    }
}

/// How the model reaches the device.
///
/// One case by construction. Remote model updates are architecturally deferred and disabled
/// in Version 1 (Requirement 10.21), so there is no value here describing a fetched,
/// updated, or downloaded bundle for the explanation to mention.
public enum BundledModelDelivery: String, Hashable, Sendable, CaseIterable {
    /// The model ships inside the application and is used from there.
    case packagedInsideApplication = "packaged-inside-application"
}

/// Whether an Analysis Session needs network connectivity.
///
/// One case by construction (Requirement 9.3). Offline completion is a property of the
/// application rather than a condition it reports, so there is no "requires network" value.
public enum NetworkRequirement: String, Hashable, Sendable, CaseIterable {
    /// A session completes with connectivity disabled.
    case noneForAnalysis = "none-for-analysis"
}

/// One supplied cleanup deadline, carried through unchanged.
///
/// The reason comes from the closed domain vocabulary and the deadline from the signed Data
/// Lifecycle Policy. Nothing here chooses, rounds, defaults, or formats a duration: the
/// value is the artifact's value, and the wording that would turn it into a sentence is
/// recorded as ``UnapprovedDisclosureSurface/cleanupDeadlineDurationUnit`` instead of being
/// invented.
public struct SuppliedCleanupDeadline: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// Why the session's material is being removed.
    public let reason: SessionCleanupReason

    /// The deadline the signed policy fixed for that reason.
    public let deadline: ValidatedDuration

    init(reason: SessionCleanupReason, deadline: ValidatedDuration) {
        self.reason = reason
        self.deadline = deadline
    }
}

/// What removal means.
///
/// One case by construction. The design is explicit that deletion means removal from every
/// application-controlled file-system namespace and that it does not claim physical flash
/// erasure, so the honest statement is the only one representable and the screen cannot
/// overclaim (Requirement 9.17).
public enum SessionDataRemovalScope: String, Hashable, Sendable, CaseIterable {
    /// Removed from every namespace the application controls, with no residue in
    /// application-controlled temporary or long-lived storage.
    case everyApplicationControlledNamespace = "every-application-controlled-namespace"
}

/// One claim Requirements 1.6 through 1.9 require a user to be able to read.
///
/// Facts about the build, stated as a closed set. All four are true of every Version 1
/// composition by construction - there is no purchase path, account path, advertising
/// dependency, or subscription in either production graph - so none is conditional and none
/// can be dropped for a build.
public enum ProjectAccessClaim: String, Hashable, Sendable, CaseIterable {
    /// The project is nonprofit (Requirement 1.9).
    case nonprofitProject = "nonprofit-project"

    /// Every required analysis capability costs nothing (Requirement 1.6).
    case zeroMonetaryCost = "zero-monetary-cost"

    /// Analysis needs no user account (Requirement 1.7).
    case noAccountRequired = "no-account-required"

    /// Analysis displays no advertising (Requirement 1.8).
    case noAdvertising = "no-advertising"

    /// Analysis is not behind a subscription.
    ///
    /// Implied by ``zeroMonetaryCost`` and stated separately anyway, because "free" and
    /// "not gated behind a recurring payment" are different reassurances and a reader has
    /// no reason to infer the second from the first.
    case outsideASubscription = "outside-a-subscription"

    /// The requirement this claim answers, as a stable reference.
    public var required: String {
        switch self {
        case .nonprofitProject: "1.9"
        case .zeroMonetaryCost, .outsideASubscription: "1.6"
        case .noAccountRequired: "1.7"
        case .noAdvertising: "1.8"
        }
    }
}

// MARK: - The screen

/// The in-application privacy explanation (Requirement 9.16).
///
/// Every member is non-optional. There is no representable privacy screen that omits a
/// topic, a deadline, an absent practice, or an access claim.
public struct PrivacyDisclosureScreen: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// Surfaces this screen needs and the approved vocabulary does not define. Nothing is
    /// rendered for them.
    public static let unapprovedSurfaces: Set<UnapprovedDisclosureSurface> = [
        .privacyTopicLabel,
        .localProvenanceAvailabilityStatement,
        .cleanupDeadlineDurationUnit,
        .absentDataPracticeLabel,
        .projectFundingStatement,
    ]

    /// The one approved paragraph this screen shows (Requirement 9.16).
    public let explanationCopy: ResolvedCopyReference

    /// Where pixel inference runs.
    public let pixelInference: PixelInferenceLocality

    /// Whether local Content Credential validation is part of this release.
    public let provenanceValidation: LocalProvenanceValidationAvailability

    /// Which photo access analysis uses.
    public let photoAccess: PhotoAccessScope

    /// Whether analysis needs connectivity.
    public let networkRequirement: NetworkRequirement

    /// How the model reaches the device.
    public let modelDelivery: BundledModelDelivery

    /// The five practices this release does not perform, in declaration order.
    public let absentDataPractices: [AbsentDataPractice]

    /// The five supplied cleanup deadlines, in the domain's declaration order.
    ///
    /// Ordered by the closed reason vocabulary rather than by duration, so the order is
    /// stable across releases and cannot be changed by a policy edit.
    public let cleanupDeadlines: [SuppliedCleanupDeadline]

    /// What removal means.
    public let removalScope: SessionDataRemovalScope

    /// The four access claims, in declaration order.
    public let accessClaims: [ProjectAccessClaim]

    /// The signed policy version the deadlines came from.
    ///
    /// Carried so a reader of the value - a release audit, a snapshot test - can tell which
    /// policy produced which numbers. It is an artifact identifier, never displayed as a
    /// sentence.
    public let lifecyclePolicyID: ArtifactID

    init(
        explanationCopy: ResolvedCopyReference,
        provenanceValidation: LocalProvenanceValidationAvailability,
        absentDataPractices: [AbsentDataPractice],
        cleanupDeadlines: [SuppliedCleanupDeadline],
        accessClaims: [ProjectAccessClaim],
        lifecyclePolicyID: ArtifactID
    ) {
        self.explanationCopy = explanationCopy
        self.pixelInference = .onDevice
        self.provenanceValidation = provenanceValidation
        self.photoAccess = .selectedItemOnly
        self.networkRequirement = .noneForAnalysis
        self.modelDelivery = .packagedInsideApplication
        self.absentDataPractices = absentDataPractices
        self.cleanupDeadlines = cleanupDeadlines
        self.removalScope = .everyApplicationControlledNamespace
        self.accessClaims = accessClaims
        self.lifecyclePolicyID = lifecyclePolicyID
    }

    // MARK: - Coverage

    /// The topics this screen answers, in the closed vocabulary's declaration order.
    ///
    /// Every case, always. Each topic maps onto a non-optional member above, so there is no
    /// input for which one is unanswered - which is why this is a constant rather than a
    /// computation over what happened to be populated.
    public var coveredTopics: [PrivacyTopic] { PrivacyTopic.allCases }

    /// Whether every topic Requirement 9.16 names is answered.
    ///
    /// Always true for a constructible value. Exposed so a release audit can assert it over
    /// a real screen rather than trusting that the only initializer was used.
    public var answersEveryRequiredTopic: Bool {
        Set(coveredTopics) == Set(PrivacyTopic.allCases)
    }

    /// Whether all five absences Requirements 9.10 through 9.13 require are stated.
    public var statesEveryAbsentDataPractice: Bool {
        Set(absentDataPractices) == Set(AbsentDataPractice.allCases)
    }

    /// Whether a deadline is stated for every cleanup reason (Requirement 9.7).
    public var statesEveryCleanupDeadline: Bool {
        Set(cleanupDeadlines.map(\.reason)) == Set(SessionCleanupReason.allCases)
    }

    /// Whether all four access claims Requirements 1.6 through 1.9 require are stated.
    public var statesEveryAccessClaim: Bool {
        Set(accessClaims) == Set(ProjectAccessClaim.allCases)
    }

    /// The deadline stated for one cleanup reason. Total by construction.
    public func deadline(for reason: SessionCleanupReason) -> ValidatedDuration? {
        cleanupDeadlines.first { $0.reason == reason }?.deadline
    }
}

// MARK: - Assembly

extension PrivacyDisclosureScreen {
    /// Projects the privacy explanation from one checked input.
    ///
    /// Pure and total: every checked input yields a full screen, and the only failure is the
    /// copy layer's own refusal to resolve the approved explanation. There is no branch that
    /// omits a topic, and the provenance answer is read from the signed manifest rather than
    /// decided here.
    static func projecting(
        _ input: DisclosureScreenInput
    ) throws(PresentationCopyError) -> PrivacyDisclosureScreen {
        PrivacyDisclosureScreen(
            explanationCopy: try input.copy.reference(for: .privacyExplanation),
            provenanceValidation: input.capabilities.enablesProvenance
                ? .validatedOnDevice
                : .notPartOfThisRelease,
            absentDataPractices: AbsentDataPractice.allCases,
            cleanupDeadlines: SessionCleanupReason.allCases.map { reason in
                SuppliedCleanupDeadline(
                    reason: reason,
                    deadline: input.lifecyclePolicy.deadline(for: reason)
                )
            },
            accessClaims: ProjectAccessClaim.allCases,
            lifecyclePolicyID: input.lifecyclePolicy.id
        )
    }
}
