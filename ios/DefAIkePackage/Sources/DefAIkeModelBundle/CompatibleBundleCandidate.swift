import DefAIkeDomain

// The two values steps 4 through 6 of the verification order produce.
//
// ``VerifiedBundleArtifactTree`` says the bytes are the signed bytes and nothing else.
// That is not enough to bind a session to: the same intact tree could describe a model
// this build must not run, a component set the build is not compatible with, or a
// self-test specification whose fixtures are absent. So compatibility and self-tests each
// produce their own value, and neither is constructible from outside this module.
//
// The progression is deliberate and one-directional:
//
//   VerifiedBundleArtifactTree  — the bytes are the signed bytes  (task 6.1)
//   CompatibleBundleCandidate   — and this build may run them, and the self-tests are
//                                 complete                        (task 6.2, steps 4–5)
//   SelfTestedBundleCandidate   — and they passed offline         (task 6.2, step 6)
//
// Nothing here activates anything. Requirement 10.12 keeps a failed candidate from
// replacing the active bundle, and Requirement 10.13 makes activation the atomic
// replacement of a complete component tuple; both belong to the receipt and activation
// step, which consumes ``SelfTestedBundleCandidate`` rather than producing it.

/// A verified candidate this build may run, whose self-test artifacts are complete.
///
/// Constructible only by a compatibility run that reached the end without a finding.
///
/// What it does **not** claim: that any self-test has executed. A complete specification
/// and a passing run are separate facts (Requirements 10.10 and 10.11).
public struct CompatibleBundleCandidate: Hashable, Sendable {
    /// The integrity-verified tree this candidate was resolved from.
    public let tree: VerifiedBundleArtifactTree

    /// The approved role-to-path binding compatibility resolved against.
    public let layout: ApprovedBundleLayout

    /// The signed capability manifest version this compatibility decision was made
    /// under, so a candidate cannot be carried across builds.
    public let capabilityManifestID: ArtifactID

    /// The application build the candidate was found compatible with.
    public let appBuild: AppBuildID

    /// The digest of the weight blob as actually measured in the tree.
    ///
    /// Equal to ``ModelIdentity/requiredWeightDigest`` — otherwise this value would not
    /// exist. Recorded because a receipt should carry the measurement, not the claim
    /// (Requirement 10.4).
    public let measuredWeightDigest: SHA256Digest

    /// The candidate's complete self-test specification and fixture catalogue.
    public let selfTests: VerifiedSelfTestPlan

    init(
        tree: VerifiedBundleArtifactTree,
        layout: ApprovedBundleLayout,
        capabilityManifestID: ArtifactID,
        appBuild: AppBuildID,
        measuredWeightDigest: SHA256Digest,
        selfTests: VerifiedSelfTestPlan
    ) {
        self.tree = tree
        self.layout = layout
        self.capabilityManifestID = capabilityManifestID
        self.appBuild = appBuild
        self.measuredWeightDigest = measuredWeightDigest
        self.selfTests = selfTests
    }

    public var bundleID: ModelBundleID { tree.bundleID }

    public var manifest: ModelBundleManifest { tree.manifest }

    public var modelIdentity: ModelIdentity { tree.manifest.modelIdentity }

    /// The six component versions activation replaces as one tuple
    /// (Requirements 10.7 and 10.13).
    public var componentVersions: BundleComponentVersions { tree.manifest.componentVersions }

    /// What an executor needs to load and run this candidate.
    public var executionContext: SelfTestExecutionContext {
        SelfTestExecutionContext(
            bundleID: bundleID,
            compiledModelPath: layout.compiledModel,
            modelIdentity: modelIdentity,
            coreMLModelVersion: componentVersions.coreMLModel,
            inputContract: manifest.inputContract,
            outputContract: manifest.outputContract,
            preprocessingContractVersion: componentVersions.preprocessingContract,
            calibrationPolicyVersion: componentVersions.calibrationPolicy
        )
    }
}

/// A compatible candidate whose release self-tests ran offline and agreed with every
/// declared expectation.
///
/// The last value before activation, and the only one a receipt may record a passing
/// self-test outcome from.
public struct SelfTestedBundleCandidate: Hashable, Sendable {
    public let candidate: CompatibleBundleCandidate

    /// What the run did, for the receipt an activation writes.
    public let report: SelfTestRunReport

    init(candidate: CompatibleBundleCandidate, report: SelfTestRunReport) {
        self.candidate = candidate
        self.report = report
    }

    /// The self-test outcome a receipt records.
    ///
    /// Always ``GateOutcome/passed``: this value exists only for a run in which every
    /// declared expectation was compared and agreed. A candidate whose self-tests failed,
    /// or never ran, produces a finding instead, so `notExecuted` can never be written as
    /// a passing result (Requirement 10.11).
    public var selfTestOutcome: GateOutcome { .passed }

    public var bundleID: ModelBundleID { candidate.bundleID }
}

/// What one complete self-test run did.
///
/// Records the run rather than judging it: the judgment is that this value exists at all.
/// It carries no image data, no fixture bytes, and no logit value, so it is safe to
/// persist in a receipt (Requirement 9.11).
public struct SelfTestRunReport: Hashable, Sendable {
    /// The specification version that was run.
    public let specificationID: ArtifactID

    /// Every case that ran, in execution order.
    public let executedCases: [SelfTestCaseID]

    /// How many declared expectations were compared. Equals the plan's declared total —
    /// a run that compared fewer is not a run that passed.
    public let comparedExpectationCount: Int

    /// The Resource Budget version the run was governed by (Requirement 10.11).
    public let resourceBudgetID: ArtifactID

    /// Budget metrics the environment could not measure, in a stable order.
    ///
    /// Recorded rather than silently dropped. An unmeasurable metric is not a breach and
    /// not a pass: self-test admission is decided by expectation agreement, and the
    /// budget stops a run only on a measured breach.
    public let unmeasurableMetrics: [ResourceMetric]

    init(
        specificationID: ArtifactID,
        executedCases: [SelfTestCaseID],
        comparedExpectationCount: Int,
        resourceBudgetID: ArtifactID,
        unmeasurableMetrics: [ResourceMetric]
    ) {
        self.specificationID = specificationID
        self.executedCases = executedCases
        self.comparedExpectationCount = comparedExpectationCount
        self.resourceBudgetID = resourceBudgetID
        self.unmeasurableMetrics = unmeasurableMetrics.sorted { $0.rawValue < $1.rawValue }
    }
}
