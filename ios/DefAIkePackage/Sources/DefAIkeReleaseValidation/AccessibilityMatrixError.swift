import DefAIkeDomain

// Why an accessibility and Localization Readiness matrix run cannot start, what it is still owed,
// and what a recorded pass would not establish even if every artifact arrived.
//
// The same three-vocabulary split the parity and resource runners use, for the same reason: the
// actions that close the three are different, and a release audit that conflates them waits for
// the wrong thing.
//
//   * ``AccessibilityMatrixBindingError`` — *this run's inputs disagree with each other*. The
//     configuration is not a plan candidate, the version tuple names a different plan, the
//     configuration's build disagrees with the tuple's, the plan's missing-result rule is not
//     `treat-as-failure`. A reconciliation finding: nothing was executed and nothing should be.
//   * ``UnprovisionedAccessibilityMatrixInput`` — *a release-controlled input this repository does
//     not carry*. An approved matrix artifact, the per-cell procedures, the imported VoiceOver and
//     Switch Control run records, the approved decision permitting a manual portion, the approved
//     accessibility label copy, a physical iPhone, a device test host with assistive technology
//     available. Closing one is a release-artifact, process, or hardware change.
//   * ``UnobservableAccessibilityMatrixEvidence`` — *something the implementation or the schema
//     does not expose*, so a cell either cannot be exercised at all or does not establish what its
//     name suggests. Closing one is a schema or implementation change, and no amount of
//     provisioning helps.
//
// The third vocabulary carries this task's central findings, and there are three that block
// outright:
//
//   * **The Localization Readiness substitution reaches no rendered string.** The shipped catalog
//     holds three `copy.pixel-label.*` keys, the four readiness catalogs hold exactly that key
//     set, and the keys any accessible element addresses are disjoint from both. The one
//     renderable element resolves through a fixed-text path that bypasses the catalog, so
//     expansion, long-word, bidirectional, and pseudolocalized runs all render the same English.
//     Requirements 12.15 and 12.17 exist to exercise a mechanism that is, today, inert.
//   * **The Share Extension exposes no accessibility projection.** Handoff consent lives in a
//     target that has no accessibility layer and for which the approved copy surface defines no
//     entry, so the `handoff-consent` workflow has nothing to exercise on either side of the
//     module boundary.
//   * **The retry workflow's recovery control is credited to no workflow.** The required identity
//     set for retry names the image-selection control while the error screen exposes recovery
//     under a different identity, so the retry position is inoperable *and* carries no diagnosis.
//     A defect reported here, not fixed here.
//
// And one finding is about this module's own reach rather than about the subject: workflow
// operability is measured in the presentation layer, which `DefAIkeReleaseValidation` does not
// and must not depend on. The matrix is therefore modelled over the domain's workflow, condition,
// and variant vocabularies plus imported evidence, the way the parity runner models comparisons
// over `ComparisonMetric` without reaching the pipeline.
//
// No vocabulary here has a case meaning "proceed anyway", "assume", "skip", or "warn". A matrix
// run either records a qualifying observation of a completed workflow, or it produces one of
// these.

// MARK: - Reconciliation findings

/// Why a plan, a configuration, and a version tuple cannot be bound into one configuration's
/// matrix run.
public enum AccessibilityMatrixBindingError: Error, Equatable, Sendable, CustomStringConvertible {

    /// The configuration under test is not one the approved plan enumerates.
    case configurationNotInPlan(DeviceHardwareID, PlatformVersion)

    /// The configuration runs an operating-system version below the supported minimum.
    ///
    /// `CandidateDeviceConfiguration` already refuses this and the matrix cell schema refuses a
    /// major version below 17 as well. Checked again because the major version a cell records is
    /// derived from this field, and relying on another type's invariant for the one value this
    /// task derives would leave nothing here that fails when the invariant changes.
    case configurationBelowSupportedMinimum(PlatformVersion)

    /// The version tuple names a different validation plan.
    case versionTuplePlanMismatch(expected: ArtifactID, found: ArtifactID)

    /// The version tuple names a different Model Bundle than the plan.
    case versionTupleModelBundleMismatch(expected: ModelBundleID, found: ModelBundleID)

    /// The version tuple names a different capability manifest than the plan.
    case versionTupleCapabilityManifestMismatch(expected: ArtifactID, found: ArtifactID)

    /// The configuration's application build disagrees with the version tuple's.
    ///
    /// Requirements 12.14 and 12.18 block "the affected application version", so the evidence has
    /// to belong to one build rather than being pooled across builds (Requirement 13.20).
    case versionTupleAppBuildMismatch(expected: AppBuildID, found: AppBuildID)

    /// The plan's missing-result rule is not "treat as failure".
    ///
    /// The plan schema already refuses this. Checked again because a runner that trusted the rule
    /// to be right without reading it would be relying on another type's invariant for the
    /// behaviour Requirements 12.14 and 12.18 turn on.
    case missingResultRuleNotFailure(MissingResultRule)

    /// The binding produces no required cell at all.
    ///
    /// A run with nothing to execute is not a passing run. It has no evidence.
    case requiredCellSetEmpty

    /// The derived required set does not cover every workflow, condition, and variant the domain
    /// declares.
    ///
    /// Checked against the closed domain vocabularies rather than against a list restated here, so
    /// the runner and the matrix schema cannot drift about which positions a release owes. A
    /// derivation that produced fewer would run a subset and present it as the matrix result.
    case requiredCoverageIncomplete(missing: [String])

    /// Two candidate configurations in the plan produce the same matrix position.
    ///
    /// A collision means two devices' evidence would be pooled under one key, so one of them
    /// silently stops being recorded.
    case duplicateMatrixPosition(String)

    public var description: String {
        switch self {
        case let .configurationNotInPlan(hardware, osVersion):
            return "\(hardware.rawValue)@\(osVersion.description) is not a plan candidate"
        case let .configurationBelowSupportedMinimum(osVersion):
            return "\(osVersion.description) is below the supported minimum "
                + PlatformVersion.iOS17.description
        case let .versionTuplePlanMismatch(expected, found):
            return "the version tuple names plan \(found.rawValue), not \(expected.rawValue)"
        case let .versionTupleModelBundleMismatch(expected, found):
            return "the version tuple names Model Bundle \(found.rawValue), not "
                + expected.rawValue
        case let .versionTupleCapabilityManifestMismatch(expected, found):
            return "the version tuple names capability manifest \(found.rawValue), not "
                + expected.rawValue
        case let .versionTupleAppBuildMismatch(expected, found):
            return "the configuration names application build \(found.rawValue), not "
                + expected.rawValue
        case let .missingResultRuleNotFailure(rule):
            return "the plan's missing-result rule is \(rule.rawValue)"
        case .requiredCellSetEmpty:
            return "the bound plan requires no matrix position at all"
        case let .requiredCoverageIncomplete(missing):
            return "the required set covers no position for " + missing.sorted().joined(
                separator: ", "
            )
        case let .duplicateMatrixPosition(key):
            return "two candidate configurations produce the matrix position \(key)"
        }
    }
}

// MARK: - Release-controlled inputs this repository does not carry

/// One release-controlled input a matrix run needs and this repository does not have.
///
/// A closed, enumerable vocabulary, in the established style, with raw values disjoint from every
/// other gap vocabulary in this module so a release audit can pool them without two different gaps
/// colliding on one identifier.
///
/// Closing a gap is a release-artifact, process, or hardware change. It is not a change to this
/// file, and no case here is closable by writing code.
public enum UnprovisionedAccessibilityMatrixInput: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    /// No approved Device Validation Plan exists, so there is no candidate configuration list and
    /// no missing-result rule for a matrix run to bind to.
    ///
    /// The plan is where Requirement 12.13's "every Release Approved iPhone Configuration" and
    /// "each supported major iOS version" ultimately come from, and it is a schema with no
    /// approved instance anywhere outside test samples.
    case deviceValidationPlanCandidateConfigurations =
        "device-validation-plan-candidate-configurations"

    /// No approved Accessibility Gate Matrix artifact exists.
    ///
    /// `AccessibilityGateMatrix` is a schema with no approved instance, so there is nothing for a
    /// run's recorded cells to be published into and nothing for the release validator to check.
    case accessibilityGateMatrixArtifact = "accessibility-gate-matrix-artifact"

    /// No approved per-cell accessibility procedure exists.
    ///
    /// Requirement 12.13 requires the tests executed and recorded; what is missing is the
    /// predeclared procedure for each position — which steps constitute the workflow, how the
    /// display condition is established, and what counts as reachable without clipping. The plan
    /// schema has nowhere to carry it, which is
    /// ``UnobservableAccessibilityMatrixEvidence/accessibilityMatrixCellHasNoPlanSpecification``.
    case accessibilityMatrixProcedure = "accessibility-matrix-procedure"

    /// No approved Localization Readiness Suite procedure exists (Requirements 12.15 through
    /// 12.17).
    case localizationReadinessSuiteProcedure = "localization-readiness-suite-procedure"

    /// No imported VoiceOver run record exists.
    ///
    /// VoiceOver cannot be enabled by a test process, so every VoiceOver position needs a human
    /// run whose immutable, versioned, digest-bound record is imported. None exists.
    case voiceOverManualRunRecord = "voice-over-manual-run-record"

    /// No imported Switch Control run record exists, for the same reason.
    case switchControlManualRunRecord = "switch-control-manual-run-record"

    /// No approved decision permitting a manual portion exists.
    ///
    /// Separate from the run records, and deliberately: a human result is a measurement and an
    /// approval is a conclusion about whether that measurement may stand for a mandatory gate at
    /// a named position. Requirement 12.13 needs both, and this module manufactures neither.
    case manualExecutionAuthorization = "manual-execution-authorization"

    /// No approved accessibility label copy exists.
    ///
    /// Most required workflows are inoperable purely because the labels their controls would
    /// expose are not in an approved copy surface. Until they are, no complete matrix run is
    /// possible on any configuration, however much hardware is available.
    case approvedAccessibilityLabelCopy = "approved-accessibility-label-copy"

    /// No release-controlled declaration of the supported major iOS versions exists.
    ///
    /// The plan enumerates candidate configurations and each names one exact operating-system
    /// version, so a supported-major-version set can only be *derived* from them. A release
    /// distributed to a major version no candidate runs is therefore undetectable here, which is
    /// ``UnobservableAccessibilityMatrixEvidence/supportedMajorVersionSetIsDerivedFromPlanCandidates``.
    case supportedMajorVersionDeclaration = "supported-major-version-declaration"

    /// No device test host with assistive technology available exists.
    ///
    /// The declared device-validation test targets are hosted by the application, and an
    /// app-hosted unit-test host cannot drive the application under VoiceOver or Switch Control at
    /// all. Requirement 12.13's assistive positions therefore have no execution home yet, which is
    /// a project-configuration and process change rather than a code one.
    case assistiveTechnologyDeviceTestHost = "assistive-technology-device-test-host"

    /// No release-controlled validation version tuple is bound.
    ///
    /// The application build identity is `0`/`0.0.0` in both shipping targets, so no `AppBuildID` a
    /// run could legitimately name exists, and Requirement 13.20 forbids assembling gate evidence
    /// across tuples.
    case boundMatrixValidationVersionTuple = "bound-matrix-validation-version-tuple"

    /// No physical iPhone is available to execute on.
    ///
    /// The blocking one, and the reason every matrix gate in this repository is failing rather
    /// than pending. Requirement 13.16 admits only physical-iPhone results, this repository has no
    /// device, and the only installed runtime is a simulator runtime. So every observation any run
    /// here can produce is a development-Mac or simulator observation, and
    /// ``QualifyingMatrixEvidence`` refuses all of them.
    ///
    /// Nothing in this module reduces the gate to what a host can do. A host-satisfiable device
    /// gate would be a false pass, and a failing gate is the honest answer.
    case physicalIPhoneAssistiveRunEnvironment = "physical-iphone-assistive-run-environment"

    public var description: String { rawValue }
}

/// The complete set of release-controlled inputs one matrix run does not have.
///
/// A named type rather than a bare array, so the reason travels as one value and an audit sees the
/// whole list rather than whichever gap was checked first.
public struct UnprovisionedAccessibilityMatrixRun: Error, Hashable, Sendable {
    public let inputs: [UnprovisionedAccessibilityMatrixInput]

    public init(inputs: [UnprovisionedAccessibilityMatrixInput]) {
        self.inputs = inputs
    }
}

// MARK: - Evidence the implementation or the schema cannot produce

/// Something a matrix cell would need that the implementation or the artifact schema does not
/// expose.
///
/// A separate vocabulary from ``UnprovisionedAccessibilityMatrixInput`` because the two are closed
/// by different work. A missing matrix artifact arrives when a release signs one; the absence of a
/// condition dimension in the plan's measurement key does not, because there is no artifact to
/// sign — the schema would have to change first.
///
/// Nothing here is a defect this module fixes. Each is reported.
public enum UnobservableAccessibilityMatrixEvidence: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    // MARK: Conditions no automation can establish

    /// A test process cannot turn VoiceOver on.
    ///
    /// iOS exposes no supported interface for it, so a VoiceOver position is executable only by a
    /// human. Not blocking: an imported human result with an approved authorization for that exact
    /// position is a real path, and this module refuses only to invent one.
    case voiceOverCannotBeEnabledByAutomation = "voice-over-cannot-be-enabled-by-automation"

    /// A test process cannot turn Switch Control on, for the same reason.
    case switchControlCannotBeEnabledByAutomation =
        "switch-control-cannot-be-enabled-by-automation"

    // MARK: The Localization Readiness mechanism

    /// Substituting a Localization Readiness catalog replaces no rendered string.
    ///
    /// The blocking one on the localization side. The set of localization keys any accessible
    /// element addresses is disjoint from both the shipped catalog's key set and the readiness
    /// catalogs', and the single renderable element resolves through a fixed-text path that never
    /// consults a catalog. So all four variants render identical English and the bracket-clipping
    /// signal pseudolocalization exists to produce cannot appear. A localization cell is therefore
    /// not exercisable at all, rather than exercisable and passing.
    case localizationSubstitutionReachesNoRenderedString =
        "localization-substitution-reaches-no-rendered-string"

    /// The readiness catalogs' keys are disjoint from the keys any element addresses.
    ///
    /// Stated separately from the blocking finding because it is the first of two independent
    /// reasons the substitution is inert, and closing one does not close the other.
    case localizationCatalogKeysAreDisjointFromAddressedKeys =
        "localization-catalog-keys-are-disjoint-from-addressed-keys"

    /// The one renderable element's text bypasses the copy catalog.
    ///
    /// The second independent reason. Even a catalog whose keys matched would not reach this
    /// element, because its text is resolved by a fixed-value path rather than by a catalog
    /// lookup.
    case fixedPixelLabelTextBypassesTheCopyCatalog =
        "fixed-pixel-label-text-bypasses-the-copy-catalog"

    // MARK: Workflows with nothing to exercise

    /// The Share Extension exposes no accessibility projection.
    ///
    /// Handoff consent lives in `DefAIkeShareExtension`, which cannot reach the presentation
    /// module, has no accessibility projection of its own, and for which the approved copy surface
    /// defines no entry. Requirements 12.11 and 12.12 make the handoff-consent workflow mandatory
    /// under every assistive condition, so the position exists and is blocked rather than dropped:
    /// a requirement that silently stops being checked is worse than one that fails closed.
    case shareExtensionExposesNoAccessibilityProjection =
        "share-extension-exposes-no-accessibility-projection"

    /// The retry workflow's recovery control is credited to no workflow.
    ///
    /// The required identity set for the retry workflow names the image-selection control, while
    /// every error screen exposes recovery under a distinct recovery identity. So the retry
    /// position reports the recovery control as absent from the screen, is inoperable, and carries
    /// no blocking-gap diagnosis of its own — the red cell has no cause attached to it. A defect
    /// found by earlier work, reported here and not fixed here.
    case retryRecoveryControlIsCreditedToNoWorkflow =
        "retry-recovery-control-is-credited-to-no-workflow"

    // MARK: Limits on what a recorded pass establishes

    /// Every projected accessibility element exposes no programmatic value.
    ///
    /// Requirement 12.2's nonempty-value check therefore passes vacuously, satisfied only by its
    /// own escape hatch for elements that expose no value. A matrix pass under any assistive
    /// condition establishes that labels, traits, and order held; it does not establish that a
    /// stateful control's value matched its displayed state, because there are no values to match.
    case everyExposedAccessibilityValueIsAbsent = "every-exposed-accessibility-value-is-absent"

    /// Workflow operability is not reachable from this module.
    ///
    /// Operability is computed in `DefAIkePresentation`, and `DefAIkeReleaseValidation` depends
    /// on `DefAIkeDomain` alone. Adding the edge would put nonshipping release tooling into the
    /// presentation module's dependents, so the matrix is modelled over the domain's workflow,
    /// condition, and variant vocabularies plus imported evidence instead. A recorded pass
    /// therefore states what a device harness observed; this module does not independently
    /// establish that the workflow's required controls exist.
    case workflowOperabilityIsNotReachableFromThisModule =
        "workflow-operability-is-not-reachable-from-this-module"

    /// The plan schema cannot predeclare a matrix cell.
    ///
    /// `DeviceValidationPlan` carries comparison specifications keyed by comparison metric and
    /// resource measurement specifications keyed by target, metric, and configuration. It has no
    /// accessibility or localization dimension at all, so no position's procedure, steps, or
    /// reachability criterion can be predeclared. Not blocking: unlike a resource limit, a matrix
    /// cell needs no approved number — Requirements 12.1 through 12.16 are the criterion. What is
    /// missing is the procedure, which is owed as
    /// ``UnprovisionedAccessibilityMatrixInput/accessibilityMatrixProcedure``.
    case accessibilityMatrixCellHasNoPlanSpecification =
        "accessibility-matrix-cell-has-no-plan-specification"

    /// The plan's measurement key has no condition or phase dimension.
    ///
    /// `plan.measurements` is unique on target, metric, hardware identifier, and operating-system
    /// version. A VoiceOver-enabled position and a Switch-Control-enabled position of the same
    /// workflow on the same device differ in none of those four, so the two cannot be predeclared
    /// apart even if the schema gained an accessibility metric: the uniqueness rule would refuse
    /// the second entry. The same schema gap earlier work found for cancellation and interruption
    /// conditions, reaching the assistive conditions the same way.
    case assistiveConditionIsAbsentFromThePlanMeasurementKey =
        "assistive-condition-is-absent-from-the-plan-measurement-key"

    /// The supported major-version set is derived from the plan's candidates.
    ///
    /// Nothing in the plan declares which major iOS versions a release supports, so the set is
    /// derived from the versions its candidate configurations run. The derivation is exact for a
    /// release whose candidates cover every supported version and silently narrow for one whose
    /// candidates do not — and this module cannot tell the two apart, because there is no declared
    /// set to compare against.
    case supportedMajorVersionSetIsDerivedFromPlanCandidates =
        "supported-major-version-set-is-derived-from-plan-candidates"

    /// Whether this finding prevents the cell from being exercised at all.
    ///
    /// True for the three that remove the subject: a localization substitution that reaches no
    /// rendered string, a workflow whose target has no accessibility projection, and a workflow
    /// whose recovery control belongs to no workflow. The rest narrow what a recorded pass
    /// establishes without preventing the run, so they are recorded beside a cell whose outcome is
    /// reached normally.
    ///
    /// Written without a `default`, so a new finding forces a decision about whether it blocks.
    public var blocksExercise: Bool {
        switch self {
        case .localizationSubstitutionReachesNoRenderedString,
             .shareExtensionExposesNoAccessibilityProjection,
             .retryRecoveryControlIsCreditedToNoWorkflow:
            true
        case .voiceOverCannotBeEnabledByAutomation,
             .switchControlCannotBeEnabledByAutomation,
             .localizationCatalogKeysAreDisjointFromAddressedKeys,
             .fixedPixelLabelTextBypassesTheCopyCatalog,
             .everyExposedAccessibilityValueIsAbsent,
             .workflowOperabilityIsNotReachableFromThisModule,
             .accessibilityMatrixCellHasNoPlanSpecification,
             .assistiveConditionIsAbsentFromThePlanMeasurementKey,
             .supportedMajorVersionSetIsDerivedFromPlanCandidates:
            false
        }
    }

    public var description: String { rawValue }
}
