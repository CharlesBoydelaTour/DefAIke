import DefAIkeDomain

// Why a release record cannot be assembled, what the assembly is still owed, and what a
// complete record would not establish even if every artifact arrived.
//
// The same three-vocabulary split tasks 14.2, 14.3, 14.4, and 14.6 use, for the same reason:
// the actions that close the three are different, and a release audit that conflates them
// waits for the wrong thing.
//
//   * ``ReleaseRecordCoherenceError`` — *the evidence handed in disagrees with itself or with
//     the signed capability manifest*. Two runners reporting different version tuples for one
//     configuration, an implementation version the manifest does not name, an application
//     build the manifest does not name, a Model Bundle outside the approved catalogue. A
//     reconciliation finding: nothing was joined and nothing should be believed. Requirement
//     13.20 excludes such a configuration outright, so these are refusals rather than
//     findings recorded beside a result.
//   * ``UnprovisionedReleaseRecordInput`` — *a release-controlled input this repository does
//     not carry*. One case per evidence kind the record joins, so an absent kind is
//     attributable to something a release has to supply rather than to "no result". Closing
//     one is a release-artifact, approval, or measurement change.
//   * ``UnobservableReleaseRecordEvidence`` — *something a complete record still would not
//     establish*. The "signature" available here is not a signature scheme; three mandatory
//     device gates are unsatisfiable by construction; the record binds no Data Lifecycle
//     deadline; a published claim's coverage is never reconciled against the slice
//     measurements behind it; and a completeness statistic counts samples that came back
//     rather than samples that qualified. Closing one needs different artifacts or a different
//     schema, not more provisioning.
//
// No vocabulary here has a case meaning "proceed anyway", "assume", "approximate", "skip", or
// "warn". Requirement 14.15 blocks the affected public distribution on *any* missing or
// failing applicable mandatory entry, and Requirement 13.22 blocks distribution when no
// candidate configuration passes; a reporting surface that could downgrade one would be how
// those clauses stop holding.
//
// Every raw value here was checked for disjointness against the fifteen closed vocabularies
// already in the `ios` tree, so a release audit can pool them without two different gaps
// colliding on one identifier.

// MARK: - The twelve joined evidence kinds

/// One kind of evidence the release record joins.
///
/// Exactly the twelve task 14.8 enumerates. A closed vocabulary rather than a free string,
/// because the record's whole job is to state which evidence a gate rests on, and a kind that
/// existed in one place and not another would be a gate nobody could attribute.
///
/// The kinds are *sources*, not gates. Several gates read one kind — the four archive gates
/// all come from one audit run — and one gate can read two, which is why gate membership is a
/// property of the gate rather than a partition of this vocabulary.
public enum ReleaseRecordEvidenceKind: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    /// The approved calibration release: budgets, slices, population separation
    /// (Requirements 5.15 through 5.23).
    case calibration = "calibration-release"

    /// The produced Model Bundle's recorded verification, activation, and rollback evidence
    /// (Requirements 10.8 through 10.13, 10.17, 14.13, 14.16).
    case bundle = "model-bundle-release-evidence"

    /// The privacy half of the archive audit: forbidden capabilities in shipped bytes
    /// (Requirements 9.10 through 9.13, 9.18).
    case privacy = "privacy-audit-evidence"

    /// The archive audit's dependency, digest, notice, and corpus-exclusion findings
    /// (Requirements 14.5 and 14.6).
    case archive = "archive-audit-evidence"

    /// The accessibility matrix run (Requirements 12.13 and 12.14).
    case accessibility = "accessibility-matrix-evidence"

    /// The Localization Readiness matrix run (Requirements 12.17 and 12.18).
    case localization = "localization-readiness-evidence"

    /// The repository code-license and dataset-terms approval records
    /// (Requirements 14.2 through 14.4).
    case legal = "distribution-rights-records"

    /// The recorded model governance and red-team risk decision
    /// (Requirements 14.9 and 14.10).
    case governance = "model-governance-evidence"

    /// The physical-device parity and resource evidence behind the allowlist
    /// (Requirements 13.6 through 13.22).
    case device = "physical-device-evidence"

    /// The Release Fixture Suite and its parity inventory (Requirement 13.4).
    case fixture = "release-fixture-suite-evidence"

    /// The signed Release Capability Manifest this record answers for (Requirement 14.1).
    case capability = "release-capability-manifest"

    /// The published active limitations and the user-accessible correction channel
    /// (Requirement 14.14).
    case limitationAndCorrectionChannel = "limitations-and-correction-channel"

    public var description: String { rawValue }
}

extension ReleaseGate {

    /// The joined evidence kinds this gate's outcome is computed from, in declaration order.
    ///
    /// Written without a `default`, so adding a release gate forces a decision about which
    /// evidence answers it rather than leaving a gate that reads nothing. Several gates read
    /// one kind and two read two, which is why this is a set-valued property of the gate rather
    /// than a partition of ``ReleaseRecordEvidenceKind``.
    ///
    /// The four corpus and calibration evidence gates read the ``ReleaseRecordEvidenceKind/
    /// calibration`` kind because that is the domain's own grouping: `ReleaseGate` files
    /// `corpus-identifier-correction` and `duplicate-hash-disposition` under evidence and
    /// calibration, and Requirement 14.7 makes corpus remediation a precondition of using a
    /// regenerated comparison in a release claim rather than a separate release surface.
    public var contributingEvidenceKinds: [ReleaseRecordEvidenceKind] {
        switch self {
        case .calibrationSliceBudgets, .contemporaryPhoneCameraSlice, .populationSeparation,
             .corpusIdentifierCorrection, .duplicateHashDisposition:
            [.calibration]
        case .benchmarkClaimBindings:
            [.calibration, .limitationAndCorrectionChannel]
        case .initialModelBundleSignature, .initialModelBundleSelfTests, .bundleActivation,
             .bundleRollback:
            [.bundle]
        case .privacyAudit:
            [.privacy]
        case .archiveAudit, .dependencyNotices, .corpusExclusion:
            [.archive]
        case .accessibilityMatrix:
            [.accessibility]
        case .localizationReadinessMatrix:
            [.localization]
        case .deviceAllowlist:
            [.device]
        case .fixtureSuiteCompleteness:
            [.fixture]
        case .capabilityManifestMatch:
            [.capability]
        case .repositoryCodeLicense, .dataDistributionRights:
            [.legal]
        case .modelGovernanceDecision:
            [.governance]
        case .activeLimitationsPublication, .correctionChannel:
            [.limitationAndCorrectionChannel]
        case .provenanceFeasibility, .fusionRuleApproval:
            [.capability, .device]
        }
    }

    /// The release-controlled input a gate with no evidence is owed from. Total.
    ///
    /// Attributed to something a release has to supply, never to "no result", so an unresolved
    /// gate names the work that closes it.
    public var owedReleaseRecordInput: UnprovisionedReleaseRecordInput {
        switch self {
        case .calibrationSliceBudgets, .contemporaryPhoneCameraSlice, .populationSeparation,
             .benchmarkClaimBindings:
            .approvedCalibrationRelease
        case .corpusIdentifierCorrection, .duplicateHashDisposition:
            .regeneratedCorpusRemediationEvidence
        case .initialModelBundleSignature, .initialModelBundleSelfTests, .bundleActivation,
             .bundleRollback:
            .producedModelBundleReleaseEvidence
        case .privacyAudit, .archiveAudit, .dependencyNotices, .corpusExclusion:
            .archiveAuditReleaseInputDocument
        case .accessibilityMatrix, .localizationReadinessMatrix:
            .accessibilityAndLocalizationMatrixRun
        case .deviceAllowlist:
            .coherentPhysicalDeviceEvidenceSet
        case .fixtureSuiteCompleteness:
            .signedReleaseFixtureSuiteInventory
        case .capabilityManifestMatch:
            .signedReleaseCapabilityManifest
        case .repositoryCodeLicense, .dataDistributionRights:
            .approvedDistributionRightsRecords
        case .modelGovernanceDecision:
            .recordedModelGovernanceDecision
        case .activeLimitationsPublication, .correctionChannel:
            .publishedLimitationsAndCorrectionChannel
        case .provenanceFeasibility, .fusionRuleApproval:
            .conditionalCapabilityApplicabilityDecision
        }
    }
}

// MARK: - Reconciliation findings

/// Why one configuration's device evidence cannot be joined into one coherent set.
///
/// Every case is a Requirement 13.20 exclusion: the evidence mixes application builds, Model
/// Bundle versions, Release Fixture Suite versions, Device Validation Plan versions,
/// capability sets, or capability implementation versions. A refusal rather than a recorded
/// failure, because a value of ``CoherentDeviceEvidence`` is what "one coherent set" means and
/// there is no reduced set a release falls back to.
public enum ReleaseRecordCoherenceError: Error, Equatable, Sendable, CustomStringConvertible {

    /// Two runners reported different configurations for one evidence set.
    case configurationMixed(expected: DeviceHardwareID, found: DeviceHardwareID)

    /// Two runners reported different operating-system versions for one evidence set.
    case operatingSystemVersionMixed(expected: PlatformVersion, found: PlatformVersion)

    /// Two runners reported different version tuples for one evidence set.
    ///
    /// Whole-tuple inequality, which is what makes this check cover the field
    /// ``ParityRunBinding`` never reconciles: a tuple differing only in a capability
    /// implementation version binds at the parity layer, and this refuses it here.
    case versionTupleMixed(ReleaseRecordEvidenceKind)

    /// Two runners were executed in different environments for one evidence set.
    case runEnvironmentMixed(expected: ExecutionEnvironment, found: ExecutionEnvironment)

    /// The tuple names an application build other than the signed manifest's.
    ///
    /// The record-level identity check. Without it two sibling allowlist entries can disagree
    /// about the application build and every layer below accepts both.
    case appBuildNotTheManifestBuild(expected: AppBuildID, found: AppBuildID)

    /// The configuration's own application build disagrees with the tuple's.
    case configurationAppBuildMismatch(expected: AppBuildID, found: AppBuildID)

    /// The tuple names a capability manifest other than the signed one.
    case capabilityManifestMismatch(expected: ArtifactID, found: ArtifactID)

    /// The tuple's capability set is not the manifest's compiled set.
    case capabilitySetMismatch(expected: [String], found: [String])

    /// The tuple's implementation version for one capability is not the manifest's.
    ///
    /// The clause Requirement 13.20 names last and the one no binding layer checks. Compared
    /// as a keyed mapping rather than as a list, so entry order cannot hide a disagreement and
    /// a reordering cannot manufacture one.
    case capabilityImplementationVersionMismatch(
        capability: CapabilityID,
        expected: CapabilityImplementationVersion,
        found: CapabilityImplementationVersion
    )

    /// The tuple names a Model Bundle outside the manifest's approved catalogue.
    case modelBundleOutsideApprovedCatalog(ModelBundleID)

    /// The catalogued suite is not the suite the tuple names.
    case fixtureSuiteMismatch(expected: ArtifactID, found: ArtifactID)

    /// One runner's plan is not the plan the tuple names.
    case validationPlanMismatch(
        kind: ReleaseRecordEvidenceKind,
        expected: ArtifactID,
        found: ArtifactID
    )

    public var description: String {
        switch self {
        case let .configurationMixed(expected, found):
            return "evidence for \(expected.rawValue) carries a result from \(found.rawValue)"
        case let .operatingSystemVersionMixed(expected, found):
            return "evidence for iOS \(expected.description) carries a result from "
                + "iOS \(found.description)"
        case let .versionTupleMixed(kind):
            return "\(kind.rawValue) ran under a different version tuple"
        case let .runEnvironmentMixed(expected, found):
            return "one runner executed in \(expected.rawValue) and another in \(found.rawValue)"
        case let .appBuildNotTheManifestBuild(expected, found):
            return "the manifest names build \(expected.rawValue); the evidence names "
                + "\(found.rawValue)"
        case let .configurationAppBuildMismatch(expected, found):
            return "the tuple names build \(expected.rawValue); the configuration names "
                + "\(found.rawValue)"
        case let .capabilityManifestMismatch(expected, found):
            return "the signed manifest is \(expected.rawValue); the evidence names "
                + "\(found.rawValue)"
        case let .capabilitySetMismatch(expected, found):
            return "the manifest compiles \(expected); the evidence names \(found)"
        case let .capabilityImplementationVersionMismatch(capability, expected, found):
            return "\(capability.rawValue) is implemented at \(expected.description) in the "
                + "manifest and at \(found.description) in the evidence"
        case let .modelBundleOutsideApprovedCatalog(bundle):
            return "\(bundle.rawValue) is not in the approved bundle catalogue"
        case let .fixtureSuiteMismatch(expected, found):
            return "the tuple names suite \(expected.rawValue); the catalogue is "
                + "\(found.rawValue)"
        case let .validationPlanMismatch(kind, expected, found):
            return "\(kind.rawValue) ran against plan \(found.rawValue); the tuple names "
                + "\(expected.rawValue)"
        }
    }
}

/// Why a release record could not be emitted as release output.
///
/// Distinct from ``ReleaseRecordCoherenceError``, which refuses evidence before a record
/// exists. These are the states an *assembled* record reports, and each one is a Requirement
/// 14.15, 14.16, 14.17, or 13.22 block rather than something a caller retries differently.
public enum ReleaseRecordOutputRefusal: Error, Equatable, Sendable, CustomStringConvertible {

    /// One or more applicable mandatory gates are failing (Requirement 14.15).
    case mandatoryGatesFailing([ReleaseGate])

    /// One or more applicable mandatory gates have no result (Requirement 14.15).
    case mandatoryGatesUnresolved([ReleaseGate])

    /// A gate names no evidence artifact at all, so Requirement 14.1's mapping is unwritable.
    case gateNamesNoEvidence([ReleaseGate])

    /// No candidate configuration passes every mandatory device gate (Requirement 13.22).
    case noPassingDeviceConfiguration

    /// A hard public-launch blocker is missing or failing (Requirements 14.16 and 14.17).
    case hardPublicLaunchBlocker([ReleaseGate])

    /// A release-controlled input the record joins does not exist.
    case unprovisionedInputs([UnprovisionedReleaseRecordInput])

    public var description: String {
        switch self {
        case let .mandatoryGatesFailing(gates):
            return "failing mandatory gates: \(gates.map(\.rawValue).sorted())"
        case let .mandatoryGatesUnresolved(gates):
            return "mandatory gates with no result: \(gates.map(\.rawValue).sorted())"
        case let .gateNamesNoEvidence(gates):
            return "gates naming no evidence artifact: \(gates.map(\.rawValue).sorted())"
        case .noPassingDeviceConfiguration:
            return "no candidate iPhone configuration passes every mandatory device gate"
        case let .hardPublicLaunchBlocker(gates):
            return "hard public-launch blockers: \(gates.map(\.rawValue).sorted())"
        case let .unprovisionedInputs(inputs):
            return "release-controlled inputs owed: \(inputs.map(\.rawValue).sorted())"
        }
    }
}

// MARK: - Release-controlled inputs the assembly does not have

/// A release-controlled input one record assembly does not carry.
///
/// One case per joined evidence kind, plus the two citation-shaped inputs a gate entry needs
/// before Requirement 14.1's mapping can be written at all. Raw values are disjoint from every
/// other gap vocabulary in this repository.
///
/// Closing a gap is a release-artifact, approval, or physical-measurement change. It is not a
/// change to this file, and no case here is closable by writing code — in particular, none is
/// closable by *this* module producing the artifact: an approval is a decision, a measurement
/// is a measurement, and a published document is prose a release owner writes.
public enum UnprovisionedReleaseRecordInput: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    /// No approved calibration release exists.
    ///
    /// Requirement 5.1 fixes one False Accusation Budget no greater than 1.0% for every
    /// mandatory Release Gating Slice, Requirement 5.15 predeclares the slices, and
    /// Requirement 5.22 blocks the affected bundle and application combination when any slice
    /// exceeds the budget or fails the confidence-interval rule. No product Calibration Policy
    /// exists yet, so nothing has been evaluated against a budget.
    case approvedCalibrationRelease = "approved-calibration-release"

    /// No produced Model Bundle release evidence exists.
    ///
    /// Requirement 14.13 requires the signature, digests, compatibility, self-test,
    /// activation, and rollback results recorded before distribution, and Requirement 14.16
    /// makes a missing one a hard blocker. Task 14.5 built the creation and verification
    /// tooling; no signed bundle has been produced, and a synthetic one stops at the approved
    /// weight blob by design.
    case producedModelBundleReleaseEvidence = "produced-model-bundle-release-evidence"

    /// No archive-audit release input document exists.
    ///
    /// Requirements 14.5 and 14.6 need the notice, digest, dependency, corpus, and prohibited
    /// capability findings, and Requirement 9.18 needs the privacy verification. Task 14.6's
    /// audit produces the document; it has to be run and its output supplied.
    case archiveAuditReleaseInputDocument = "archive-audit-release-input-document"

    /// No regenerated corpus remediation evidence exists.
    ///
    /// Requirement 14.7 requires the 13 ReWIND identifier collisions corrected, uniqueness
    /// verified, and every affected evidence artifact regenerated before a regenerated
    /// comparison supports a release claim; Requirement 14.8 requires the four duplicate
    /// content hashes classified. Both need approved records task 14.7 consumes and does not
    /// author.
    case regeneratedCorpusRemediationEvidence = "regenerated-corpus-remediation-evidence"

    /// No accessibility and Localization Readiness matrix run exists.
    ///
    /// Requirement 12.13 requires the matrices executed and recorded on every approved
    /// configuration and each supported major iOS version, and Requirements 12.14 and 12.18
    /// block the affected application version when a mandatory result is missing.
    case accessibilityAndLocalizationMatrixRun = "accessibility-and-localization-matrix-run"

    /// No coherent physical-device evidence set exists for any configuration.
    ///
    /// Requirement 13.18 admits a configuration only on matching device, operating-system,
    /// application-build, Model Bundle, fixture-suite, plan, capability, and implementation
    /// versions, and Requirement 13.22 blocks distribution when none passes. Only the iOS 26.5
    /// simulator runtime is available here, and a simulator result cannot satisfy a device
    /// gate.
    case coherentPhysicalDeviceEvidenceSet = "coherent-physical-device-evidence-set"

    /// No approved distribution-rights records exist.
    ///
    /// Requirement 14.2 requires a root repository code-license file with terms compatible
    /// with the intended open-source distribution, Requirement 14.3 requires written dataset
    /// and benchmark terms, and Requirement 14.4 blocks the affected public distribution while
    /// either is unresolved. Task 14.6 measured that no root licence or notice file exists.
    case approvedDistributionRightsRecords = "approved-distribution-rights-records"

    /// No recorded model governance and red-team risk decision exists.
    ///
    /// Requirement 14.10 requires the release-owner decision recorded before public
    /// distribution and Requirement 14.17 blocks on a missing or failing one. The upstream
    /// checkpoint reports `redteam_validation_valid: false`, which Requirement 14.9 requires
    /// disclosed; the disclosure is not the decision.
    case recordedModelGovernanceDecision = "recorded-model-governance-decision"

    /// No signed Release Fixture Suite and parity inventory exist.
    ///
    /// Requirement 13.4 requires the existing 96 model-parity fixtures plus release-approved
    /// orientation, colour-space, alpha, aspect-ratio, physical-screenshot, JPEG, PNG,
    /// HEIC/HEIF, malformed-input, Photos picker, and Share Extension handoff fixtures. None
    /// of the 96 references is in this repository.
    case signedReleaseFixtureSuiteInventory = "signed-release-fixture-suite-inventory"

    /// No signed Release Capability Manifest exists.
    ///
    /// Requirement 14.1 requires each gate mapped to source artifact identifiers and versions,
    /// and every one of those is read from the manifest rather than chosen here.
    case signedReleaseCapabilityManifest = "signed-release-capability-manifest"

    /// No published active limitations document or user-accessible correction channel exists.
    ///
    /// Requirement 14.14 requires both published with each public release, and Requirement
    /// 14.12 binds every published claim to them.
    case publishedLimitationsAndCorrectionChannel = "published-limitations-and-correction-channel"

    /// No approved applicability decision exists for a conditional capability gate.
    ///
    /// Requirement 6.1 evaluates the Provenance Feasibility Gate before the enabled capability
    /// set is chosen and Requirement 6.3 permits a pixel-only release when it does not pass;
    /// Requirements 7.15 and 7.16 do the same for fusion. Both outcomes are recorded
    /// decisions, and neither is representable as an absent field.
    case conditionalCapabilityApplicabilityDecision =
        "conditional-capability-applicability-decision"

    /// A gate has evidence but no immutable citation for it.
    ///
    /// Requirement 14.1 requires the source artifact identifier, artifact version, and result.
    /// A result with no citation is not a mapping, and this module cannot mint an artifact
    /// identifier, version, or content digest for evidence someone else produced.
    case releaseGateEvidenceCitation = "release-gate-evidence-citation"

    public var description: String { rawValue }
}

/// The complete set of release-controlled inputs one record assembly does not have.
public struct UnprovisionedReleaseRecord: Error, Hashable, Sendable {
    public let inputs: [UnprovisionedReleaseRecordInput]

    public init(inputs: [UnprovisionedReleaseRecordInput]) {
        self.inputs = inputs
    }
}

// MARK: - Evidence a complete record would still not establish

/// Something a complete release record would need that no available artifact exposes.
///
/// A separate vocabulary from ``UnprovisionedReleaseRecordInput`` because the two are closed by
/// different work. A missing approval arrives when a release owner decides; the fact that the
/// available signature construction is not a signature scheme does not, because there is no
/// artifact to approve — the construction would have to change.
///
/// Nothing here is a defect this module fixes. Each is reported beside the record it qualifies,
/// whatever that record's gate outcomes are, because each is a property of the available
/// artifacts rather than of one assembly.
public enum UnobservableReleaseRecordEvidence: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    /// The available signature construction verifies under every declared algorithm.
    ///
    /// The stand-in digests the key bytes concatenated with the message, so one "signature"
    /// verifies under every `SignatureAlgorithm` the schema can name. A verification pass over
    /// a release record therefore establishes that the bytes are the bytes that were measured,
    /// and nothing about who produced them or under which scheme. Requirement 14.1's
    /// *auditable* record is served by the canonical bytes; the *signed* half is not.
    case signatureStandInVerifiesUnderEveryDeclaredAlgorithm =
        "signature-stand-in-verifies-under-every-declared-algorithm"

    /// No mandatory device-gate set is jointly satisfiable in this repository.
    ///
    /// Three of the 22 cannot pass whatever is measured: `screenshot-fidelity` compares a
    /// metric no expectation kind can carry an approved value for, and
    /// `cancellation-residual-work` and `interruption-cleanup` cannot be predeclared because
    /// the plan's measurement schema has no condition or phase dimension while Requirement
    /// 13.17 makes both mandatory. So an empty allowlist here is over-determined: it would stay
    /// empty even with a physical iPhone and a complete plan.
    case noJointlySatisfiableMandatoryDeviceGateSetExists =
        "no-jointly-satisfiable-mandatory-device-gate-set-exists"

    /// No record gate binds a Data Lifecycle Policy deadline.
    ///
    /// Requirement 9.7 requires versioned numeric cleanup deadlines defined before
    /// distribution and Requirement 9.17 requires them met, but `ValidatedLimit` has no case
    /// that carries a deadline and `ReleaseGate` has no entry for one. A record can therefore
    /// be complete while no gate answers for the five deadlines.
    case dataLifecycleDeadlinesAreNotBoundToAnyRecordGate =
        "data-lifecycle-deadlines-are-not-bound-to-any-record-gate"

    /// A published claim's coverage is not reconciled against the slice measurements behind it.
    ///
    /// Requirement 8.16 requires the sample counts, coverage, and uncertainty interval
    /// reported with a claim, and Requirement 14.12 binds the claim to immutable dataset,
    /// score, and report identifiers. Neither the claim schema nor this assembly compares the
    /// claim's coverage against the approved calibration release's slice measurements, so two
    /// numbers describing one evaluation can disagree and both be recorded.
    case publishedClaimCoverageIsNotReconciledAgainstSliceMeasurements =
        "published-claim-coverage-is-not-reconciled-against-slice-measurements"

    /// A recorded completeness statistic counts samples that came back, not samples that
    /// qualified.
    ///
    /// `ResourceMeasurementSummary.qualifyingSampleCount` counts returned samples, so a wholly
    /// non-qualifying series reads complete. No false pass follows — the cell outcome refuses
    /// the series — but the statistic a record carries overstates what was measured, and this
    /// assembly copies it rather than recomputing a number the runner did not produce.
    case recordCompletenessStatisticsCountReturnedRatherThanQualifyingSamples =
        "record-completeness-statistics-count-returned-rather-than-qualifying-samples"

    public var description: String { rawValue }
}
