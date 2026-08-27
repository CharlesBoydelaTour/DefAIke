import DefAIkeDomain
import Foundation

// Running the accessibility and Localization Readiness matrices Requirements 12.13 and 12.17
// require, for every workflow, every assistive condition, every localization variant, every
// candidate configuration the bound plan enumerates, and the major iOS version each of those
// configurations runs.
//
// The runner does one thing: for every position the bound plan *owes*, it asks what the run
// observed and records one outcome. It has no other job, and in particular:
//
//   | Decision | Where it comes from |
//   |---|---|
//   | which workflows are required | `AccessibilityWorkflow.allCases` |
//   | which assistive conditions are required | `AssistiveCondition.allCases` |
//   | which localization variants are required | `LocalizationTestVariant.allCases` |
//   | which configurations to cover | ``DeviceValidationPlan/candidateConfigurations`` |
//   | which major iOS version a position runs at | that position's configuration |
//   | how a position is spelled | `AccessibilityResultCell.key` / `LocalizationResultCell.key` |
//   | what a missing result means | ``MissingResultRule``, and only `treat-as-failure` binds |
//   | whether a manual portion is permitted | an imported ``ApprovalRecord``, and nowhere else |
//   | whether the result may approve a configuration | nowhere in this module |
//
// There is no `outcome:` parameter anywhere in this file's public surface. A caller cannot hand in
// a ``GateOutcome`` or an ``AccessibilityMatrixCellOutcome``; every one is computed from what an
// observation reported.
//
// ## Four rules this file exists to make structural
//
// **An unexecuted position cannot read as passed, and it lowers the statistic rather than leaving
// it.** ``AccessibilityMatrixConfigurationReport`` holds a total mapping over a closed
// required-position set. Every required position has exactly one
// ``AccessibilityMatrixCellOutcome``, only ``AccessibilityMatrixCellOutcome/exercised`` satisfies
// one, and ``AccessibilityMatrixCellOutcome/outcome`` returns ``GateOutcome/passed`` or
// ``GateOutcome/failed`` and never ``GateOutcome/notExecuted``.
// ``AccessibilityMatrixConfigurationReport/record(of:)`` is non-optional and total over every
// `AccessibilityMatrixCell`, including ones outside the required set, and its answer for anything
// it has no record for is a failure. The denominator of
// ``AccessibilityMatrixGateResult/recordedCoverage`` is the *required* position count, always, so a
// position with no observation lowers the recorded coverage instead of disappearing from it — 20 of
// 56 rather than 20 of 20. And the projection to the domain's recorded cells emits nothing at all
// for a position with no observation, so an unexecuted position appears in
// `AccessibilityGateMatrix.missingCellKeys` and can never appear as a recorded pass.
//
// **A manual portion needs an imported reference *and* an approval for that exact position.** A
// cell whose condition no automation can establish refuses an automated observation outright, and
// accepts a manual one only when ``QualifyingMatrixEvidence`` finds all of: a versioned,
// digest-bound ``EvidenceSource`` naming the imported human run; an ``ApprovalRecord`` whose
// decision is an approval; that approval naming *this* position; and the approval's own record
// being a different artifact with different content than the result it approves. None of those five
// is producible by the runner, and the last two are what stop a blanket approval and a
// self-approving run from standing in for a human conclusion.
//
// **A physical-iPhone gate is not satisfiable by host or simulator evidence.** Two independent
// barriers, and both have to be crossed:
//
//   1. ``AccessibilityMatrixCellOutcome/exercised`` carries a ``MatrixCellAgreement``, which can
//      only be built from a ``QualifyingMatrixEvidence``, whose only initialiser is internal to
//      this module and refuses any observation not produced on a physical iPhone, on the bound
//      configuration, on a configuration the approved plan enumerates, under the bound version
//      tuple (Requirements 13.16 and 13.20).
//   2. ``AccessibilityMatrixConfigurationReport/gateResult(for:)`` additionally consults
//      ``ObservedParityEnvironment/current``, which is decided by the platform this module was
//      compiled for and cannot be supplied, overridden, or configured. A run in a host test
//      process or a simulator therefore fails both matrix gates no matter what its observations
//      claim.
//
// Barrier 1 bounds what an observation can become; barrier 2 bounds what a *process* can conclude.
// Today this repository has no physical iPhone and only a simulator runtime, so barrier 2 is
// failing for every gate and the report says so by name.
//
// **A failing position blocks the application version rather than excluding one configuration.**
// Requirements 12.14 and 12.18 block distribution "of the affected application version", which is
// stricter than Requirement 13.19's exclusion of one candidate configuration.
// ``AccessibilityMatrixReport/outcome`` therefore requires *every* configuration to pass, and
// ``AccessibilityMatrixReport/blocksDistribution`` is the direct reading of that.

// MARK: - Cell results

/// One matrix position that was exercised and completed, on evidence that may back a
/// physical-device gate.
///
/// The only satisfying outcome, and the only type in this module that means "this position
/// passed". It cannot be constructed outside the module and cannot be constructed inside it
/// without a ``QualifyingMatrixEvidence``.
public struct MatrixCellAgreement: Hashable, Sendable {
    public let cell: AccessibilityMatrixCell

    /// Proof that the observation behind this pass may back a device gate.
    public let evidence: QualifyingMatrixEvidence

    /// What the run observed. Always ``ObservedWorkflowCoverage/workflowCompleted``.
    ///
    /// Retained rather than replaced by "passed", so a release record carries the observation
    /// beside the conclusion drawn from it.
    public let coverage: ObservedWorkflowCoverage

    init(
        cell: AccessibilityMatrixCell,
        evidence: QualifyingMatrixEvidence,
        coverage: ObservedWorkflowCoverage
    ) {
        self.cell = cell
        self.evidence = evidence
        self.coverage = coverage
    }
}

/// A required position with no observation at all, and what is owed for it.
///
/// Carries three things because a release audit needs all three: why nothing came back, which
/// release-controlled input would supply it, and which standing findings apply to that position
/// whether or not the input ever arrives.
public struct MatrixResultGap: Hashable, Sendable {
    public let fault: MatrixObservationFault
    public let owed: UnprovisionedAccessibilityMatrixInput
    public let standingLimits: Set<UnobservableAccessibilityMatrixEvidence>

    init(
        fault: MatrixObservationFault,
        owed: UnprovisionedAccessibilityMatrixInput,
        standingLimits: Set<UnobservableAccessibilityMatrixEvidence>
    ) {
        self.fault = fault
        self.owed = owed
        self.standingLimits = standingLimits
    }
}

/// The outcome of one required matrix position.
///
/// Seven cases, exactly one of which satisfies the position. There is no case meaning "skipped",
/// "pending", "not applicable", "waived", or "assumed", and no case that a missing observation maps
/// to other than a failure.
public enum AccessibilityMatrixCellOutcome: Hashable, Sendable, CustomStringConvertible {
    /// Exercised on qualifying evidence, and the workflow completed.
    case exercised(MatrixCellAgreement)

    /// Exercised and the workflow did not complete, for the named reason.
    case workflowNotCompleted(ObservedWorkflowCoverage)

    /// No observation came back for a required position (Requirements 12.14, 12.18).
    case resultMissing(MatrixResultGap)

    /// An observation came back but cannot satisfy a physical-device gate (Requirement 13.16).
    case nonQualifyingEvidence(NonQualifyingParityEvidence)

    /// Nothing in this repository can exercise this position at all.
    case exerciseUnavailable(UnobservableAccessibilityMatrixEvidence)

    /// An automated observation answered a position no automation can establish.
    ///
    /// Distinct from ``resultMissing`` because the two are closed by different work: a missing
    /// observation arrives when someone runs the position, and this one arrives only when the
    /// automated claim is replaced by an imported human result with an approved authorization.
    case automatedEvidenceNotAdmissible(UnobservableAccessibilityMatrixEvidence)

    /// The imported human result or its authorization does not stand behind this position.
    case manualEvidenceNotImported(NonImportableManualEvidence)

    /// Whether this position is satisfied. True for ``exercised`` alone.
    public var isSatisfied: Bool {
        if case .exercised = self { true } else { false }
    }

    /// Whether the position was actually executed, completing or not.
    ///
    /// Distinct from ``isSatisfied``: a release audit needs to tell "executed and failed" from
    /// "never executed", because the two are closed by different work. Neither satisfies a gate:
    /// Requirements 12.14 and 12.18 block on missing *and* on failing.
    public var wasExecuted: Bool {
        switch self {
        case .exercised, .workflowNotCompleted: true
        case .resultMissing, .nonQualifyingEvidence, .exerciseUnavailable,
             .automatedEvidenceNotAdmissible, .manualEvidenceNotImported:
            false
        }
    }

    /// The recorded gate outcome for this position.
    ///
    /// ``GateOutcome/notExecuted`` is deliberately unreachable. Every required position is asked
    /// for, so a position with no observation is a failing position rather than one that quietly
    /// did not participate — the same rule the parity and resource runners apply.
    public var outcome: GateOutcome { isSatisfied ? .passed : .failed }

    public var description: String {
        switch self {
        case let .exercised(agreement):
            return "completed on "
                + agreement.evidence.configuration.hardwareIdentifier.rawValue
        case let .workflowNotCompleted(coverage):
            return "did not complete: \(coverage.description)"
        case let .resultMissing(gap):
            return "\(gap.fault.description); owed: \(gap.owed.rawValue)"
        case let .nonQualifyingEvidence(reason):
            return "non-qualifying evidence: \(reason.description)"
        case let .exerciseUnavailable(limit):
            return "not exercisable: \(limit.rawValue)"
        case let .automatedEvidenceNotAdmissible(limit):
            return "an automated run cannot answer this position: \(limit.rawValue)"
        case let .manualEvidenceNotImported(reason):
            return "manual evidence not imported: \(reason.description)"
        }
    }
}

/// One required position's observation, its execution mode, and its pass or fail result.
///
/// The observation and the conclusion are kept apart on purpose: a release record has to carry what
/// was seen beside what was decided, so a criterion cannot be chosen after observing a run and then
/// presented as if it had been predeclared.
public struct AccessibilityMatrixCellRecord: Hashable, Sendable {
    public let cell: AccessibilityMatrixCell

    /// What the run observed, or `nil` when nothing came back.
    public let coverage: ObservedWorkflowCoverage?

    /// How the position was executed, or `nil` when it was not.
    public let execution: ObservedMatrixExecution?

    /// The immutable, versioned, digest-bound record of the run, or `nil` when there was none.
    ///
    /// `nil` is what makes an unexecuted position unable to become a recorded cell:
    /// ``AccessibilityMatrixConfigurationReport/recordedCell(of:as:)`` returns nothing without it,
    /// so the position shows up as missing from the produced matrix rather than as a result.
    public let resultReference: EvidenceSource?

    /// The pass or fail result, kept apart from the observation.
    public let outcome: AccessibilityMatrixCellOutcome

    /// Standing findings that qualify what this position establishes, whatever its outcome.
    public let standingLimits: Set<UnobservableAccessibilityMatrixEvidence>

    init(
        cell: AccessibilityMatrixCell,
        coverage: ObservedWorkflowCoverage?,
        execution: ObservedMatrixExecution?,
        resultReference: EvidenceSource?,
        outcome: AccessibilityMatrixCellOutcome,
        standingLimits: Set<UnobservableAccessibilityMatrixEvidence>
    ) {
        self.cell = cell
        self.coverage = coverage
        self.execution = execution
        self.resultReference = resultReference
        self.outcome = outcome
        self.standingLimits = standingLimits
    }
}

/// One recorded matrix cell, in the domain's own shape.
///
/// Two cases because the two matrices are separate artifacts inside one
/// `AccessibilityGateMatrix`. Produced only for a position that actually has an immutable result
/// reference behind it.
public enum RecordedMatrixCell: Hashable, Sendable {
    case accessibility(AccessibilityResultCell)
    case localization(LocalizationResultCell)

    /// The domain's matrix key for this cell.
    public var key: String {
        switch self {
        case let .accessibility(cell): cell.description
        case let .localization(cell): cell.description
        }
    }

    /// The recorded outcome.
    public var outcome: GateOutcome {
        switch self {
        case let .accessibility(cell): cell.outcome
        case let .localization(cell): cell.outcome
        }
    }
}

// MARK: - The bindings

/// One plan, one candidate configuration, and one version tuple, reconciled.
///
/// Construction is the reconciliation gate. A value of this type means the configuration is a plan
/// candidate at or above the supported minimum, the version tuple names this exact plan, bundle,
/// manifest, and build, the configuration's own build agrees with the tuple's, the plan's
/// missing-result rule is `treat-as-failure`, and the derived position set covers every workflow
/// against every assistive condition and every localization variant.
///
/// It does not mean anything was executed. That is ``AccessibilityMatrixRunner``'s job, and it needs
/// observations.
public struct AccessibilityMatrixBinding: Hashable, Sendable {
    public let plan: DeviceValidationPlan
    public let configuration: CandidateDeviceConfiguration
    public let versionTuple: ValidationVersionTuple

    /// The closed set of positions this binding owes, in a stable order.
    ///
    /// Derived once at construction so a run cannot enumerate a different set than the one the
    /// binding was validated against.
    public let requiredCells: [AccessibilityMatrixCell]

    public init(
        plan: DeviceValidationPlan,
        configuration: CandidateDeviceConfiguration,
        versionTuple: ValidationVersionTuple
    ) throws(AccessibilityMatrixBindingError) {
        guard plan.missingResultRule == .treatAsFailure else {
            throw AccessibilityMatrixBindingError.missingResultRuleNotFailure(
                plan.missingResultRule
            )
        }
        guard plan.candidateConfigurations.contains(configuration) else {
            throw AccessibilityMatrixBindingError.configurationNotInPlan(
                configuration.hardwareIdentifier,
                configuration.osVersion
            )
        }
        guard configuration.osVersion >= .iOS17 else {
            throw AccessibilityMatrixBindingError.configurationBelowSupportedMinimum(
                configuration.osVersion
            )
        }
        guard versionTuple.validationPlan == plan.id else {
            throw AccessibilityMatrixBindingError.versionTuplePlanMismatch(
                expected: plan.id,
                found: versionTuple.validationPlan
            )
        }
        guard versionTuple.modelBundle == plan.modelBundle else {
            throw AccessibilityMatrixBindingError.versionTupleModelBundleMismatch(
                expected: plan.modelBundle,
                found: versionTuple.modelBundle
            )
        }
        guard versionTuple.capabilityManifest == plan.capabilityManifest else {
            throw AccessibilityMatrixBindingError.versionTupleCapabilityManifestMismatch(
                expected: plan.capabilityManifest,
                found: versionTuple.capabilityManifest
            )
        }
        // Requirements 12.14 and 12.18 block "the affected application version", so the evidence
        // has to belong to one build. A configuration whose own build disagrees with the tuple's
        // would put two builds' results under one matrix.
        guard configuration.appBuild == versionTuple.appBuild else {
            throw AccessibilityMatrixBindingError.versionTupleAppBuildMismatch(
                expected: versionTuple.appBuild,
                found: configuration.appBuild
            )
        }

        let cells = AccessibilityMatrixCell.required(on: configuration)
        guard !cells.isEmpty else { throw AccessibilityMatrixBindingError.requiredCellSetEmpty }
        // Reconciled against the domain's own closed vocabularies rather than against a count
        // restated here, so a derivation that dropped a workflow, a condition, or a variant is a
        // binding failure instead of a matrix that runs a subset and presents it as the result.
        let missing = Self.uncoveredPositions(in: cells)
        guard missing.isEmpty else {
            throw AccessibilityMatrixBindingError.requiredCoverageIncomplete(missing: missing)
        }

        self.plan = plan
        self.configuration = configuration
        self.versionTuple = versionTuple
        self.requiredCells = cells
    }

    /// The major iOS version every position in this binding is executed at.
    public var osMajorVersion: Int { configuration.osVersion.majorVersion }

    /// The required positions for one gate, in stable order.
    public func requiredCells(for gate: DeviceGate) -> [AccessibilityMatrixCell] {
        requiredCells.filter { $0.gate == gate }
    }

    /// Names of the workflows, conditions, and variants the derived set does not cover.
    ///
    /// Empty for a correct derivation. Computed from the domain vocabularies, so adding a case to
    /// any of the three makes this report it rather than letting the matrix shrink.
    static func uncoveredPositions(in cells: [AccessibilityMatrixCell]) -> [String] {
        var missing: [String] = []
        let workflows = Set(cells.map(\.workflow))
        for workflow in AccessibilityWorkflow.allCases where !workflows.contains(workflow) {
            missing.append(workflow.rawValue)
        }
        let exercised = Set(cells.map(\.exercise))
        for exercise in MatrixExercise.required where !exercised.contains(exercise) {
            missing.append(exercise.key)
        }
        // And every pair, not only every axis: a set covering all seven workflows and all eight
        // exercises could still omit one crossing.
        for workflow in AccessibilityWorkflow.allCases {
            for exercise in MatrixExercise.required {
                let present = cells.contains {
                    $0.workflow == workflow && $0.exercise == exercise
                }
                if !present { missing.append("\(workflow.rawValue)/\(exercise.key)") }
            }
        }
        return missing
    }
}

/// Every candidate configuration's binding, built from one plan and one version tuple.
///
/// Requirement 12.13 requires coverage of *each* supported major iOS version and *every* approved
/// configuration, and Requirement 13.20 forbids assembling gate evidence across builds, bundles,
/// fixture suites, plans, capability sets, or implementation versions. This type is how both become
/// structural rather than checked: there is no initialiser that takes independently constructed
/// per-configuration bindings, so a run cannot pair one configuration's evidence from one tuple
/// with another's from a different tuple, and it cannot cover a subset of the plan's candidates.
public struct AccessibilityMatrixCoverageBinding: Hashable, Sendable {
    public let plan: DeviceValidationPlan
    public let versionTuple: ValidationVersionTuple

    /// One binding per plan candidate, ascending by hardware identifier and version.
    public let bindings: [AccessibilityMatrixBinding]

    public init(
        plan: DeviceValidationPlan,
        versionTuple: ValidationVersionTuple
    ) throws(AccessibilityMatrixBindingError) {
        var built: [AccessibilityMatrixBinding] = []
        for configuration in plan.candidateConfigurations.sorted(by: Self.ascending) {
            built.append(
                try AccessibilityMatrixBinding(
                    plan: plan,
                    configuration: configuration,
                    versionTuple: versionTuple
                )
            )
        }
        guard !built.isEmpty else { throw AccessibilityMatrixBindingError.requiredCellSetEmpty }
        // Two candidates that produce one position would pool two devices' evidence under one key,
        // so one of them silently stops being recorded.
        var seen: Set<String> = []
        for binding in built {
            for cell in binding.requiredCells {
                guard seen.insert(cell.matrixKey).inserted else {
                    throw AccessibilityMatrixBindingError.duplicateMatrixPosition(cell.matrixKey)
                }
            }
        }
        self.plan = plan
        self.versionTuple = versionTuple
        self.bindings = built
    }

    /// The configurations this coverage spans, in the bindings' order.
    public var configurations: [CandidateDeviceConfiguration] { bindings.map(\.configuration) }

    /// The major iOS versions this coverage spans, ascending.
    ///
    /// Derived from the plan's candidates, because nothing in the plan declares a supported-version
    /// set — recorded as
    /// ``UnobservableAccessibilityMatrixEvidence/supportedMajorVersionSetIsDerivedFromPlanCandidates``
    /// rather than presented as the release's own declaration.
    public var supportedMajorVersions: [Int] {
        Set(bindings.map(\.osMajorVersion)).sorted()
    }

    /// The binding for one configuration, or `nil` when the plan does not enumerate it.
    public func binding(
        for configuration: CandidateDeviceConfiguration
    ) -> AccessibilityMatrixBinding? {
        bindings.first { $0.configuration == configuration }
    }

    /// Every position this coverage owes, across every configuration, in stable order.
    public var requiredCells: [AccessibilityMatrixCell] {
        bindings.flatMap(\.requiredCells).sorted { $0.orderingKey < $1.orderingKey }
    }

    private static func ascending(
        _ lhs: CandidateDeviceConfiguration,
        _ rhs: CandidateDeviceConfiguration
    ) -> Bool {
        if lhs.hardwareIdentifier.rawValue != rhs.hardwareIdentifier.rawValue {
            return lhs.hardwareIdentifier.rawValue < rhs.hardwareIdentifier.rawValue
        }
        return lhs.osVersion < rhs.osVersion
    }
}

// MARK: - Gate results

/// The recorded result of one matrix gate, for one configuration's positions.
public struct AccessibilityMatrixGateResult: Hashable, Sendable {
    public let gate: DeviceGate

    /// Always ``GateApplicability/applicable``.
    ///
    /// Neither matrix gate is provenance conditional, and Requirements 12.8 and 12.10 through
    /// 12.12 make every workflow, condition, and variant mandatory for every distribution. There is
    /// no member a waiver could occupy, which is why ``GateOutcome/notExecuted`` is unreachable
    /// here.
    public let applicability: GateApplicability

    /// The configuration whose positions this result was computed from.
    public let configuration: CandidateDeviceConfiguration

    /// The required positions this gate is computed from, in stable order.
    public let cells: [AccessibilityMatrixCell]

    /// The recorded outcome.
    public let outcome: GateOutcome

    /// Satisfied positions over the *required* position count.
    ///
    /// The statistic a missing position lowers. The denominator is the required count and never
    /// shrinks to what came back, so a gate whose observations covered a handful of positions
    /// reports a low coverage instead of a high one computed over the handful.
    public let recordedCoverage: UnitInterval

    /// Why an applicable gate cannot pass in this process, when that is the reason.
    ///
    /// Non-`nil` whenever ``ObservedParityEnvironment/canProducePhysicalDeviceEvidence`` is false,
    /// which is every host and simulator run.
    public let processRefusal: NonQualifyingParityEvidence?

    init(
        gate: DeviceGate,
        applicability: GateApplicability,
        configuration: CandidateDeviceConfiguration,
        cells: [AccessibilityMatrixCell],
        outcome: GateOutcome,
        recordedCoverage: UnitInterval,
        processRefusal: NonQualifyingParityEvidence?
    ) {
        self.gate = gate
        self.applicability = applicability
        self.configuration = configuration
        self.cells = cells
        self.outcome = outcome
        self.recordedCoverage = recordedCoverage
        self.processRefusal = processRefusal
    }
}

// MARK: - One configuration's report

/// Everything one configuration's matrix run recorded.
///
/// A total mapping over the binding's closed required-position set plus the projections a release
/// record needs. Constructible only inside this module, and only by a run: there is no initialiser
/// that takes outcomes, so a caller cannot assemble a report that declares a position passed.
public struct AccessibilityMatrixConfigurationReport: Hashable, Sendable {
    public let plan: ArtifactID
    public let configuration: CandidateDeviceConfiguration
    public let versionTuple: ValidationVersionTuple

    /// The major iOS version every position in this report was executed at.
    public let osMajorVersion: Int

    /// Where this run's *process* was executing.
    ///
    /// Observed from the platform, never supplied. A caller cannot set it, so a host test run
    /// cannot report itself as a physical iPhone.
    public let runEnvironment: ExecutionEnvironment

    /// The closed required-position set, in stable order.
    public let requiredCells: [AccessibilityMatrixCell]

    private let records: [AccessibilityMatrixCell: AccessibilityMatrixCellRecord]

    init(
        binding: AccessibilityMatrixBinding,
        runEnvironment: ExecutionEnvironment,
        records: [AccessibilityMatrixCell: AccessibilityMatrixCellRecord]
    ) {
        self.plan = binding.plan.id
        self.configuration = binding.configuration
        self.versionTuple = binding.versionTuple
        self.osMajorVersion = binding.osMajorVersion
        self.runEnvironment = runEnvironment
        self.requiredCells = binding.requiredCells
        self.records = records
    }

    // MARK: The total mapping

    /// The record of one position. Total, and never satisfied without an observation.
    ///
    /// Non-optional by design. The run recorded exactly one record per required position, so every
    /// position in ``requiredCells`` has a real answer here; and a position *outside* the required
    /// set — including one belonging to another configuration — gets the same failure a missing
    /// observation gets, because "this position was never required of this configuration" is not a
    /// reason to treat it as done. There is deliberately no `nil`, no `Optional`, and no default
    /// that a caller could read as a pass.
    public func record(of cell: AccessibilityMatrixCell) -> AccessibilityMatrixCellRecord {
        if let recorded = records[cell] { return recorded }
        return AccessibilityMatrixCellRecord(
            cell: cell,
            coverage: nil,
            execution: nil,
            resultReference: nil,
            outcome: .resultMissing(
                MatrixResultGap(
                    fault: .observationAbsent,
                    owed: cell.owedReleaseInput,
                    standingLimits: cell.standingLimits
                )
            ),
            standingLimits: cell.standingLimits
        )
    }

    /// The outcome of one position. Total.
    public func outcome(of cell: AccessibilityMatrixCell) -> AccessibilityMatrixCellOutcome {
        record(of: cell).outcome
    }

    // MARK: Projections

    /// Required positions that were exercised and completed.
    public var satisfiedCells: [AccessibilityMatrixCell] {
        requiredCells.filter { outcome(of: $0).isSatisfied }
    }

    /// Required positions that were not, for any reason.
    public var unsatisfiedCells: [AccessibilityMatrixCell] {
        requiredCells.filter { !outcome(of: $0).isSatisfied }
    }

    /// Required positions with no observation at all.
    public var missingResultCells: [AccessibilityMatrixCell] {
        requiredCells.filter {
            if case .resultMissing = outcome(of: $0) { true } else { false }
        }
    }

    /// Required positions whose observation cannot back a device gate.
    public var nonQualifyingCells: [AccessibilityMatrixCell] {
        requiredCells.filter {
            if case .nonQualifyingEvidence = outcome(of: $0) { true } else { false }
        }
    }

    /// Required positions nothing in this repository can exercise.
    public var unexercisableCells: [AccessibilityMatrixCell] {
        requiredCells.filter {
            if case .exerciseUnavailable = outcome(of: $0) { true } else { false }
        }
    }

    /// Required positions that need imported human evidence and do not have it.
    ///
    /// The two shapes of that failure together: an automated observation answering a manual-only
    /// position, and a manual observation whose imported reference or authorization does not stand
    /// behind the position.
    public var manualEvidenceGapCells: [AccessibilityMatrixCell] {
        requiredCells.filter {
            switch outcome(of: $0) {
            case .automatedEvidenceNotAdmissible, .manualEvidenceNotImported: true
            default: false
            }
        }
    }

    /// Required positions that need imported human evidence at all.
    ///
    /// Reported whatever their outcome, because it is a property of the condition rather than of a
    /// run: VoiceOver and Switch Control positions can never be automated.
    public var manualOnlyCells: [AccessibilityMatrixCell] {
        requiredCells.filter { $0.automationSupport.requiresImportedManualEvidence }
    }

    /// Required positions a device harness can execute without a human.
    public var automatableCells: [AccessibilityMatrixCell] {
        requiredCells.filter { $0.automationSupport.admitsAutomatedEvidence }
    }

    /// Why no gate can pass in this process, when that is so.
    ///
    /// Non-`nil` on a development Mac and in a simulator. This is the value that makes Requirement
    /// 13.16 structural rather than advisory: it is computed from
    /// ``ObservedParityEnvironment/current`` and there is no parameter, artifact, or approval that
    /// changes it.
    public var processRefusal: NonQualifyingParityEvidence? {
        runEnvironment.isPhysicalDeviceEvidence ? nil : .notPhysicalIPhone(runEnvironment)
    }

    /// Satisfied positions over the required position count, across both matrices.
    public var recordedCoverage: UnitInterval {
        Self.coverage(of: requiredCells, in: self)
    }

    /// The release-controlled inputs this run is still owed, in declaration order.
    public var owedInputs: [UnprovisionedAccessibilityMatrixInput] {
        var owed = Set<UnprovisionedAccessibilityMatrixInput>()
        for cell in requiredCells {
            switch outcome(of: cell) {
            case let .resultMissing(gap):
                owed.insert(gap.owed)
            case .exerciseUnavailable, .workflowNotCompleted:
                owed.insert(cell.owedReleaseInput)
            case .automatedEvidenceNotAdmissible, .manualEvidenceNotImported:
                owed.insert(cell.owedReleaseInput)
                owed.insert(.manualExecutionAuthorization)
                owed.insert(.assistiveTechnologyDeviceTestHost)
            case .exercised, .nonQualifyingEvidence:
                continue
            }
        }
        if processRefusal != nil || !nonQualifyingCells.isEmpty {
            owed.insert(.physicalIPhoneAssistiveRunEnvironment)
        }
        if !owed.isEmpty {
            // Everything above ultimately hangs from these four, so they are named rather than
            // left implied: the plan the candidate list comes from, the artifact a recorded run is
            // published into, the label copy without which no workflow is operable, and the
            // absence of any declared supported-version set.
            owed.insert(.deviceValidationPlanCandidateConfigurations)
            owed.insert(.accessibilityGateMatrixArtifact)
            owed.insert(.approvedAccessibilityLabelCopy)
            owed.insert(.supportedMajorVersionDeclaration)
        }
        if !manualOnlyCells.isEmpty {
            owed.insert(.manualExecutionAuthorization)
        }
        return UnprovisionedAccessibilityMatrixInput.allCases.filter { owed.contains($0) }
    }

    /// Standing findings that qualify what this run's positions establish.
    ///
    /// Reported whatever each position's outcome, because they are properties of the implementation
    /// and the artifact schema rather than of a run.
    public var standingLimits: [UnobservableAccessibilityMatrixEvidence] {
        let applicable = Set(requiredCells.flatMap { $0.standingLimits })
        return UnobservableAccessibilityMatrixEvidence.allCases.filter { applicable.contains($0) }
    }

    /// The overall outcome for this configuration.
    ///
    /// Passing requires every required position to be satisfied *and* both matrix gates to pass.
    /// The first clause is what keeps a position that belongs to neither gate — there are none
    /// today, and the check is written so a future one could not become invisible — from quietly
    /// stopping to matter.
    public var outcome: GateOutcome {
        guard unsatisfiedCells.isEmpty else { return .failed }
        let gates = DeviceGate.matrixGates
        for gate in gates where !gateResult(for: gate).outcome.isPassing {
            return .failed
        }
        return gates.isEmpty ? .failed : .passed
    }

    // MARK: Gates

    /// The required positions for one gate, in stable order.
    public func requiredCells(for gate: DeviceGate) -> [AccessibilityMatrixCell] {
        requiredCells.filter { $0.gate == gate }
    }

    /// The recorded result of one matrix gate, computed from *this configuration's* positions only.
    ///
    /// A gate with no positions here records ``GateOutcome/failed`` rather than a pass: this module
    /// records two matrices, so it has nothing to say about a parity, resource, thermal,
    /// cancellation, or interruption gate, and saying nothing is not saying it passed.
    public func gateResult(for gate: DeviceGate) -> AccessibilityMatrixGateResult {
        let cells = requiredCells(for: gate)
        let coverage = Self.coverage(of: cells, in: self)
        guard let refusal = processRefusal else {
            let recorded = cells.isEmpty
                ? GateOutcome.failed
                : (cells.allSatisfy { outcome(of: $0).isSatisfied } ? .passed : .failed)
            return AccessibilityMatrixGateResult(
                gate: gate,
                applicability: .applicable,
                configuration: configuration,
                cells: cells,
                outcome: recorded,
                recordedCoverage: coverage,
                processRefusal: nil
            )
        }
        // Barrier 2. No amount of completed workflow in a host or simulator process satisfies a
        // physical-device gate, and the refusal travels with the result so the reason is recorded
        // rather than inferred from a bare failure.
        return AccessibilityMatrixGateResult(
            gate: gate,
            applicability: .applicable,
            configuration: configuration,
            cells: cells,
            outcome: .failed,
            recordedCoverage: coverage,
            processRefusal: refusal
        )
    }

    // MARK: Recorded cells

    /// The domain's recorded cell for one position, under an approved configuration identifier.
    ///
    /// Returns `nil` for a position with no immutable result reference behind it — which is every
    /// position no run executed. That is the point: an unexecuted position produces no recorded
    /// cell, so it lands in `AccessibilityGateMatrix.missingCellKeys` and the release validator
    /// refuses the matrix. There is no path from "nothing happened" to a recorded pass.
    ///
    /// The recorded outcome is this position's computed outcome, so `passed` appears only where
    /// ``AccessibilityMatrixCellOutcome/exercised`` was reached — which needs a
    /// ``QualifyingMatrixEvidence``. The execution mode carries the imported approval for a manual
    /// position, which the domain cell schema independently refuses to accept as a pass unless it is
    /// an approval.
    public func recordedCell(
        of cell: AccessibilityMatrixCell,
        as identifier: ApprovedConfigurationID
    ) throws -> RecordedMatrixCell? {
        let recorded = record(of: cell)
        guard let reference = recorded.resultReference, let execution = recorded.execution else {
            return nil
        }
        let mode: MatrixExecutionMode
        switch execution {
        case .automated:
            mode = .automated
        case let .manual(imported):
            mode = .manual(importedEvidence: imported.authorization)
        }
        switch cell.exercise {
        case let .assistive(condition):
            return .accessibility(
                try AccessibilityResultCell(
                    workflow: cell.workflow,
                    condition: condition,
                    osMajorVersion: cell.osMajorVersion,
                    configuration: identifier,
                    outcome: recorded.outcome.outcome,
                    execution: mode,
                    evidence: reference
                )
            )
        case let .localization(variant):
            return .localization(
                try LocalizationResultCell(
                    workflow: cell.workflow,
                    variant: variant,
                    osMajorVersion: cell.osMajorVersion,
                    configuration: identifier,
                    outcome: recorded.outcome.outcome,
                    execution: mode,
                    evidence: reference
                )
            )
        }
    }

    /// Every recorded cell this configuration produced, under an approved configuration identifier.
    ///
    /// Positions with no observation contribute nothing, so the returned list is shorter than the
    /// required set exactly when the run was incomplete.
    public func recordedCells(
        as identifier: ApprovedConfigurationID
    ) throws -> [RecordedMatrixCell] {
        var produced: [RecordedMatrixCell] = []
        for cell in requiredCells {
            if let recorded = try recordedCell(of: cell, as: identifier) {
                produced.append(recorded)
            }
        }
        return produced
    }

    // MARK: Coverage

    /// Satisfied positions over the required position count, for a set of positions.
    ///
    /// The required count is the denominator and never shrinks to what came back, which is the
    /// whole of "an unexecuted position lowers the statistic" in one function. An empty position set
    /// reads zero rather than one: nothing to execute is not complete coverage.
    static func coverage(
        of cells: [AccessibilityMatrixCell],
        in report: AccessibilityMatrixConfigurationReport
    ) -> UnitInterval {
        let required = cells.count
        let satisfied = cells.filter { report.outcome(of: $0).isSatisfied }.count
        guard required > 0, satisfied > 0 else { return .zero }
        guard satisfied < required else { return .one }
        let ratio = Decimal(satisfied) / Decimal(required)
        // A quotient of two positive counts with the numerator below the denominator is inside
        // `0...1`. The fallback is a fail-closed floor rather than a value this module chose.
        return (try? UnitInterval(validating: ratio)) ?? .zero
    }
}

// MARK: - Every configuration

/// Everything one release's matrix run recorded, partitioned by configuration.
///
/// Requirement 12.13 requires coverage of every approved configuration and each supported major
/// iOS version, and Requirements 12.14 and 12.18 block the affected *application version* rather
/// than excluding one configuration. This type is that shape: one report per candidate, never
/// merged, and an overall outcome that requires all of them.
public struct AccessibilityMatrixReport: Hashable, Sendable {
    public let plan: ArtifactID
    public let versionTuple: ValidationVersionTuple

    /// One report per candidate configuration, in the coverage binding's order.
    public let configurationReports: [AccessibilityMatrixConfigurationReport]

    init(
        plan: ArtifactID,
        versionTuple: ValidationVersionTuple,
        configurationReports: [AccessibilityMatrixConfigurationReport]
    ) {
        self.plan = plan
        self.versionTuple = versionTuple
        self.configurationReports = configurationReports
    }

    /// One configuration's report, or `nil` when the run did not cover it.
    ///
    /// `nil` here is not a pass: ``outcome`` is computed from the reports the run produced, and
    /// ``coveredConfigurations`` states which those were, so a configuration the run never covered
    /// is visible as uncovered rather than as satisfied.
    public func report(
        for configuration: CandidateDeviceConfiguration
    ) -> AccessibilityMatrixConfigurationReport? {
        configurationReports.first { $0.configuration == configuration }
    }

    /// The configurations this run covered.
    public var coveredConfigurations: [CandidateDeviceConfiguration] {
        configurationReports.map(\.configuration)
    }

    /// The major iOS versions this run covered, ascending.
    public var coveredMajorVersions: [Int] {
        Set(configurationReports.map(\.osMajorVersion)).sorted()
    }

    /// Where this run's process was executing. The same for every configuration, by construction.
    public var runEnvironment: ExecutionEnvironment {
        configurationReports.first?.runEnvironment ?? ObservedParityEnvironment.current
    }

    /// Why no gate can pass in this process, when that is so.
    public var processRefusal: NonQualifyingParityEvidence? {
        runEnvironment.isPhysicalDeviceEvidence ? nil : .notPhysicalIPhone(runEnvironment)
    }

    /// Every required position across every configuration, in stable order.
    public var requiredCells: [AccessibilityMatrixCell] {
        configurationReports
            .flatMap(\.requiredCells)
            .sorted { $0.orderingKey < $1.orderingKey }
    }

    /// Required positions that were exercised and completed, across every configuration.
    public var satisfiedCells: [AccessibilityMatrixCell] {
        configurationReports.flatMap(\.satisfiedCells)
    }

    /// Required positions that were not, across every configuration.
    public var unsatisfiedCells: [AccessibilityMatrixCell] {
        configurationReports.flatMap(\.unsatisfiedCells)
    }

    /// The per-configuration result of one gate.
    ///
    /// One entry per covered configuration. Nothing here merges them: Requirement 12.13 records
    /// evidence per configuration, and a pass on one iPhone is not a pass on another.
    public func perConfigurationGateResults(
        for gate: DeviceGate
    ) -> [AccessibilityMatrixGateResult] {
        configurationReports.map { $0.gateResult(for: gate) }
    }

    /// The combined outcome of one gate across every covered configuration.
    ///
    /// Passing requires every configuration to pass. A gate this module does not record has no
    /// positions and fails, because saying nothing about a parity or resource gate is not saying it
    /// passed.
    public func outcome(of gate: DeviceGate) -> GateOutcome {
        let results = perConfigurationGateResults(for: gate)
        guard !results.isEmpty else { return .failed }
        guard results.allSatisfy({ !$0.cells.isEmpty }) else { return .failed }
        return results.allSatisfy { $0.outcome.isPassing } ? .passed : .failed
    }

    /// The overall matrix outcome for this release.
    ///
    /// Passing requires every covered configuration to pass. Requirements 12.14 and 12.18 block
    /// distribution of the affected application version, which is stricter than Requirement
    /// 13.19's exclusion of one candidate: one failing position on one iPhone blocks the build.
    public var outcome: GateOutcome {
        guard !configurationReports.isEmpty else { return .failed }
        return configurationReports.allSatisfy { $0.outcome.isPassing } ? .passed : .failed
    }

    /// Whether these results block distribution of this application version.
    ///
    /// The direct reading of Requirements 12.14 and 12.18, and the only member in this file that
    /// answers a distribution question. It answers `true` today, on every configuration, for
    /// reasons the report names one position at a time.
    public var blocksDistribution: Bool { !outcome.isPassing }

    /// Every release-controlled input any configuration is still owed, in declaration order.
    public var owedInputs: [UnprovisionedAccessibilityMatrixInput] {
        var owed = Set<UnprovisionedAccessibilityMatrixInput>()
        for report in configurationReports { owed.formUnion(report.owedInputs) }
        if !owed.isEmpty { owed.insert(.boundMatrixValidationVersionTuple) }
        return UnprovisionedAccessibilityMatrixInput.allCases.filter { owed.contains($0) }
    }

    /// Every standing finding any configuration's positions are qualified by.
    public var standingLimits: [UnobservableAccessibilityMatrixEvidence] {
        var applicable = Set<UnobservableAccessibilityMatrixEvidence>()
        for report in configurationReports { applicable.formUnion(report.standingLimits) }
        return UnobservableAccessibilityMatrixEvidence.allCases.filter { applicable.contains($0) }
    }
}

// MARK: - The runner

/// Runs one release's accessibility and Localization Readiness matrices.
///
/// Holds nothing but the injected observation reader, so it carries no approved value of its own and
/// no state two runs could share. It cannot be constructed without a reader, which is the structural
/// form of "a run without observations does not happen" — and a reader with nothing in it produces a
/// report in which every position is a failure, not an empty report.
///
/// There is no member here that records, approves, waives, or synthesizes anything. In particular
/// there is no way to mark a position executed, no way to import an approval, and no way to relax
/// the environment gate.
public struct AccessibilityMatrixRunner: Sendable {
    private let observations: any MatrixObservationReading

    /// Creates a runner over the observation reader.
    ///
    /// Required, with no default. There is no convenience initialiser and no in-module reader: a
    /// runner without observations cannot exist rather than concluding something this module chose.
    public init(observations: any MatrixObservationReading) {
        self.observations = observations
    }

    /// Executes every position every candidate configuration requires and records one result each.
    ///
    /// Never throws. A matrix run's failures are its result, and turning the first missing
    /// observation into a thrown error would stop the run at the first gap and report nothing about
    /// the rest — which is exactly the partial evidence Requirements 12.14 and 12.18 refuse.
    public func run(_ binding: AccessibilityMatrixCoverageBinding) -> AccessibilityMatrixReport {
        AccessibilityMatrixReport(
            plan: binding.plan.id,
            versionTuple: binding.versionTuple,
            configurationReports: binding.bindings.map { run($0) }
        )
    }

    /// Executes every position one configuration requires and records one result each.
    public func run(
        _ binding: AccessibilityMatrixBinding
    ) -> AccessibilityMatrixConfigurationReport {
        var records: [AccessibilityMatrixCell: AccessibilityMatrixCellRecord] = [:]
        for cell in binding.requiredCells {
            records[cell] = evaluate(cell, in: binding)
        }
        return AccessibilityMatrixConfigurationReport(
            binding: binding,
            runEnvironment: ObservedParityEnvironment.current,
            records: records
        )
    }

    // MARK: One position

    private func evaluate(
        _ cell: AccessibilityMatrixCell,
        in binding: AccessibilityMatrixBinding
    ) -> AccessibilityMatrixCellRecord {
        let standing = cell.standingLimits
        // A position nothing can exercise is refused before any observation is read, so a run
        // cannot appear to have executed it.
        if let blocking = cell.blockingLimit {
            return AccessibilityMatrixCellRecord(
                cell: cell,
                coverage: nil,
                execution: nil,
                resultReference: nil,
                outcome: .exerciseUnavailable(blocking),
                standingLimits: standing
            )
        }

        var observed: MatrixCellObservation?
        var fault: MatrixObservationFault?
        do {
            observed = try observations.observation(for: cell)
        } catch {
            // A plain `catch` rather than `catch let error as MatrixObservationFault`: with typed
            // throws the pattern is always true, and Swift 6.3.3 crashes `swift-frontend` in
            // `SILGenCleanup` rather than only warning about it.
            fault = error
        }

        guard let observation = observed else {
            return AccessibilityMatrixCellRecord(
                cell: cell,
                coverage: nil,
                execution: nil,
                resultReference: nil,
                outcome: .resultMissing(
                    MatrixResultGap(
                        fault: fault ?? .observationAbsent,
                        owed: cell.owedReleaseInput,
                        standingLimits: standing
                    )
                ),
                standingLimits: standing
            )
        }

        func record(_ outcome: AccessibilityMatrixCellOutcome) -> AccessibilityMatrixCellRecord {
            AccessibilityMatrixCellRecord(
                cell: cell,
                coverage: observation.coverage,
                execution: observation.execution,
                resultReference: observation.resultReference,
                outcome: outcome,
                standingLimits: standing
            )
        }

        // An observation filed against another position answers nothing, and it is a missing
        // result for *this* position rather than a mismatched one that might still count.
        guard observation.cell == cell else {
            return AccessibilityMatrixCellRecord(
                cell: cell,
                coverage: nil,
                execution: nil,
                resultReference: nil,
                outcome: .resultMissing(
                    MatrixResultGap(
                        fault: .observationAbsent,
                        owed: cell.owedReleaseInput,
                        standingLimits: standing
                    )
                ),
                standingLimits: standing
            )
        }

        // The execution mode is checked before the environment gate, so the report names the
        // specific reason a manual position was not answered rather than a generic refusal for it.
        let support = cell.automationSupport
        switch observation.execution {
        case .automated:
            if !support.admitsAutomatedEvidence {
                let limit = support.limit ?? .workflowOperabilityIsNotReachableFromThisModule
                return record(.automatedEvidenceNotAdmissible(limit))
            }
        case let .manual(imported):
            if let refusal = QualifyingMatrixEvidence.refusal(for: imported, answering: cell) {
                return record(.manualEvidenceNotImported(refusal))
            }
        }

        guard
            let evidence = QualifyingMatrixEvidence(
                observation: observation,
                cell: cell,
                plan: binding.plan,
                configuration: binding.configuration,
                versionTuple: binding.versionTuple
            )
        else {
            return record(.nonQualifyingEvidence(Self.refusal(for: observation, in: binding)))
        }
        guard observation.coverage.completesTheWorkflow else {
            return record(.workflowNotCompleted(observation.coverage))
        }
        return record(
            .exercised(
                MatrixCellAgreement(
                    cell: cell,
                    evidence: evidence,
                    coverage: observation.coverage
                )
            )
        )
    }

    // MARK: Refusals

    /// Why one observation cannot back a device gate.
    ///
    /// Reports the first reason found, in the order the requirements impose it: the environment
    /// first (Requirement 13.16), then the configuration, then the version tuple (Requirement
    /// 13.20).
    private static func refusal(
        for observation: MatrixCellObservation,
        in binding: AccessibilityMatrixBinding
    ) -> NonQualifyingParityEvidence {
        if !observation.environment.isPhysicalDeviceEvidence {
            return .notPhysicalIPhone(observation.environment)
        }
        if observation.configuration != binding.configuration {
            return .configurationMismatch(
                expected: binding.configuration.hardwareIdentifier,
                observed: observation.configuration.hardwareIdentifier
            )
        }
        if !binding.plan.candidateConfigurations.contains(observation.configuration) {
            return .configurationNotInPlan(
                observation.configuration.hardwareIdentifier,
                observation.configuration.osVersion
            )
        }
        if observation.versionTuple != binding.versionTuple {
            return .versionTupleMismatch
        }
        if !binding.plan.candidateConfigurations.contains(binding.configuration) {
            return .configurationNotInPlan(
                binding.configuration.hardwareIdentifier,
                binding.configuration.osVersion
            )
        }
        // Unreachable through a binding, whose construction already established every clause above.
        // Reported as a version-tuple refusal in the sense that nothing established one; either way
        // it is not a pass.
        return .versionTupleMismatch
    }
}
