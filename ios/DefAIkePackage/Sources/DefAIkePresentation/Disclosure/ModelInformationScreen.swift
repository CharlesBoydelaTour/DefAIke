import DefAIkeDomain

// Model identity and release status, as a value.
//
// Requirement 8.17 requires a path from every Evidence Report to the selected model
// identity, its measured limitations, its independent non-peer-reviewed release status, and
// its invalid inherited red-team status. Requirement 14.9 fixes what the last two disclose:
// the checkpoint is an independent non-peer-reviewed fine-tune, its upstream red-team
// validation flag is false, and no valid red-team report is inherited. Requirement 14.14
// adds the versioned active known limitations published with each release.
//
// None of that is decided here. Every field is read from the Release Readiness Record's
// governance record and gate entries, which is where the requirements put those
// conclusions, and this module derives no governance conclusion of any kind. What it does
// add is a refusal: the governance record has to disclose the same model the session ran
// under, or no screen is produced. A report whose verdict came from one model and whose
// "about this model" screen described another would make the disclosure worse than absent.
//
// The red-team status is the field most easily got wrong, so it is a two-case enum rather
// than a `Bool` pair a view could read in either direction:
//
//   * ``RedTeamValidationDisclosure/noValidInheritedReport`` is the only value reachable
//     when the upstream flag is false, and the domain independently refuses a record that
//     pairs a false flag with an inherited valid report. So an invalid status cannot be
//     projected into a value that reads as valid, whatever a view does with it.
//   * ``RedTeamValidationDisclosure/validInheritedReport`` exists because a future model
//     refresh may legitimately inherit one (Requirement 14.11 repeats the checks for a
//     refresh). It is not reachable from a record with a false flag, and nothing here
//     hard-codes the current checkpoint's values - the model identity type is deliberately
//     free of constants for exactly that reason.
//
// The screen shows one approved sentence, the same ``VerdictCopySurface/modelInformation``
// surface the report's onward path is labelled with. Every other sentence these disclosures
// need - the field labels for the identity, the independent-release-status statement, the
// inherited-red-team statement, the limitations reference label - has no approved wording
// and is recorded rather than written.

/// Whether a valid red-team report is inherited for the selected checkpoint
/// (Requirement 14.9).
///
/// Two cases, derived totally from the governance record. There is no `unknown`, no
/// `pending`, and no optional, so "we did not say" is not a state this screen can be in.
public enum RedTeamValidationDisclosure: String, Hashable, Sendable, CaseIterable {
    /// No valid red-team report is inherited, and the upstream validation flag is false.
    ///
    /// The status this release's checkpoint records. Presented as the absence of a valid
    /// report rather than as an unstated or pending one.
    case noValidInheritedReport = "no-valid-inherited-report"

    /// A valid red-team report is inherited.
    ///
    /// Unreachable while the upstream validation flag is false: the domain's governance
    /// record refuses that pairing outright, so this case cannot be used to dress an invalid
    /// status as a valid one.
    case validInheritedReport = "valid-inherited-report"

    /// Whether this disclosure states that a valid report exists.
    public var claimsAValidReport: Bool { self == .validInheritedReport }
}

/// Whether the selected checkpoint has been independently peer reviewed
/// (Requirement 14.9).
///
/// An enum rather than a `Bool`, so the disclosure reads the same way at every use site and
/// a caller cannot invert it by dropping a `!`.
public enum PeerReviewDisclosure: String, Hashable, Sendable, CaseIterable {
    /// An independent fine-tune that has not been peer reviewed.
    case independentNonPeerReviewed = "independent-non-peer-reviewed"

    /// A peer-reviewed release.
    case peerReviewed = "peer-reviewed"
}

/// A reference to one versioned external release document.
///
/// The document itself lives outside this repository. What the record supplies is its
/// artifact identifier, its exact version, and a digest binding the reference to fixed
/// content - which is enough to point a user at a specific published version and not
/// enough to render its text. So this type carries the reference and no content, and the
/// wording that would introduce it is recorded as a gap.
///
/// Used for the versioned active known limitations and for the correction channel, which
/// Requirement 14.14 publishes together.
public struct SuppliedDocumentReference: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The immutable evidence entry identifying the document.
    public let source: EvidenceSource

    /// The document's artifact identifier.
    public var artifact: ArtifactID { source.artifact }

    /// The exact published version this release binds.
    public var version: SchemaSemanticVersion { source.version }

    init(source: EvidenceSource) {
        self.source = source
    }
}

// MARK: - The screen

/// Model identity, release status, and the published limitations reference
/// (Requirements 8.17, 14.9, and 14.14).
public struct ModelInformationScreen: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// Surfaces this screen needs and the approved vocabulary does not define. Nothing is
    /// rendered for them.
    public static let unapprovedSurfaces: Set<UnapprovedDisclosureSurface> = [
        .modelIdentityFieldLabel,
        .independentReleaseStatusStatement,
        .inheritedRedTeamStatusStatement,
        .activeLimitationsReferenceLabel,
    ]

    /// The one approved sentence this screen shows (Requirement 8.17).
    public let informationCopy: ResolvedCopyReference

    /// The identity of the model the session was bound to, checked against the governance
    /// record before this screen exists.
    public let modelIdentity: ModelIdentity

    /// The Model Bundle version the session ran under.
    public let modelBundleID: ModelBundleID

    /// The Core ML component version the session ran under.
    public let coreMLModelVersion: ArtifactID

    /// The Calibration Policy version the session ran under.
    public let calibrationPolicyID: ArtifactID

    /// Whether the checkpoint is independently peer reviewed (Requirement 14.9).
    public let peerReview: PeerReviewDisclosure

    /// Whether a valid red-team report is inherited (Requirement 14.9).
    public let redTeamValidation: RedTeamValidationDisclosure

    /// The versioned active known limitations published with this release
    /// (Requirement 14.14).
    public let activeLimitations: SuppliedDocumentReference

    init(
        informationCopy: ResolvedCopyReference,
        modelIdentity: ModelIdentity,
        modelBundleID: ModelBundleID,
        coreMLModelVersion: ArtifactID,
        calibrationPolicyID: ArtifactID,
        peerReview: PeerReviewDisclosure,
        redTeamValidation: RedTeamValidationDisclosure,
        activeLimitations: SuppliedDocumentReference
    ) {
        self.informationCopy = informationCopy
        self.modelIdentity = modelIdentity
        self.modelBundleID = modelBundleID
        self.coreMLModelVersion = coreMLModelVersion
        self.calibrationPolicyID = calibrationPolicyID
        self.peerReview = peerReview
        self.redTeamValidation = redTeamValidation
        self.activeLimitations = activeLimitations
    }

    // MARK: - Audits

    /// Whether this screen makes the two disclosures Requirement 14.9 requires.
    ///
    /// True exactly when the checkpoint is disclosed as an independent non-peer-reviewed
    /// fine-tune and as inheriting no valid red-team report. False for a record describing a
    /// different situation, which is a coherent thing for a future refresh to report and is
    /// not what this release's checkpoint records.
    public var makesTheRequiredGovernanceDisclosures: Bool {
        peerReview == .independentNonPeerReviewed
            && redTeamValidation == .noValidInheritedReport
    }

    /// Whether this screen presents an inherited red-team report as valid.
    ///
    /// The negative form of the check, stated separately because it is the failure a release
    /// audit cares about: Requirement 14.9's status must never be shown as valid for this
    /// release.
    public var presentsAValidInheritedRedTeamReport: Bool {
        redTeamValidation.claimsAValidReport
    }

    /// The destinations this screen answers for (Requirement 8.17).
    ///
    /// Computed from the destination-to-screen mapping rather than listed, so it cannot fall
    /// out of step with it.
    public var destinations: [RequiredDisclosureDestination] {
        RequiredDisclosureDestination.allCases.filter { $0.screen == .modelInformation }
    }
}

// MARK: - Assembly

extension ModelInformationScreen {
    /// Projects the model-information screen from one checked input.
    ///
    /// Refuses two things and derives nothing. It refuses a governance record that discloses
    /// a different model than the session ran under, and it refuses a release whose
    /// active-limitations gate is unsatisfied, because Requirement 14.14 publishes the
    /// versioned limitations with the release and an unpublished reference points a user
    /// nowhere. Every remaining field is copied from the record.
    static func projecting(
        _ input: DisclosureScreenInput
    ) throws(DisclosureAssemblyError) -> ModelInformationScreen {
        let governance = input.release.modelGovernance
        guard governance.modelIdentity == input.session.modelIdentity else {
            throw .modelIdentityMismatch(
                session: input.session.modelIdentity,
                governance: governance.modelIdentity
            )
        }

        let limitationsGate = input.release.record(for: .activeLimitationsPublication)
        guard limitationsGate.isSatisfied else {
            throw .activeLimitationsNotPublished(outcome: limitationsGate.outcome)
        }

        let informationCopy: ResolvedCopyReference
        do {
            informationCopy = try input.copy.reference(for: .modelInformation)
        } catch {
            throw .copy(error)
        }

        return ModelInformationScreen(
            informationCopy: informationCopy,
            modelIdentity: governance.modelIdentity,
            modelBundleID: input.session.modelBundleID,
            coreMLModelVersion: input.session.coreMLModelVersion,
            calibrationPolicyID: input.session.calibrationPolicyID,
            peerReview: governance.isIndependentNonPeerReviewed
                ? .independentNonPeerReviewed
                : .peerReviewed,
            redTeamValidation: disclosure(for: governance),
            activeLimitations: SuppliedDocumentReference(source: limitationsGate.evidence)
        )
    }

    /// The red-team disclosure for one governance record.
    ///
    /// A false upstream flag yields the invalid disclosure unconditionally, whatever the
    /// inherited status field says. The domain already refuses the incoherent pairing, and
    /// this is the second, independent reason an invalid status cannot be projected as a
    /// valid one: the flag alone decides.
    private static func disclosure(
        for governance: ModelGovernanceDecisionRecord
    ) -> RedTeamValidationDisclosure {
        guard governance.redTeamValidationValid else { return .noValidInheritedReport }
        switch governance.inheritedRedTeamStatus {
        case .validReportInherited: return .validInheritedReport
        case .invalidNoReportInherited: return .noValidInheritedReport
        }
    }
}
