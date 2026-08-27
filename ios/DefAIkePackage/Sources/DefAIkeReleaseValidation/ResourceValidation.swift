import DefAIkeDomain
import Foundation

// Running the nine resource, thermal, cancellation, and interruption measurements
// Requirements 13.12 through 13.17 name, separately for each target, against the bound Device
// Validation Plan and the two signed Resource Budgets.
//
// The runner does one thing: for every measurement the bound plan and budget *owe*, it puts
// the approved limit beside the declared statistic over what the run measured and records one
// outcome. It has no other job, and in particular:
//
//   | Decision | Where it comes from |
//   |---|---|
//   | how many samples to take | ``ResourceMeasurementSpecification/sampleCount`` |
//   | which statistic summarizes them | ``ResourceMeasurementSpecification/summaryStatistic`` |
//   | the workload, warmth, concurrency, thermal and power start | the same specification |
//   | the pass limit | ``ResourceMeasurementSpecification/passLimit`` |
//   | the hard limit | ``ResourceBudget/limit(for:)`` for *this* target |
//   | which configurations are candidates | ``DeviceValidationPlan/candidateConfigurations`` |
//   | what a missing result means | ``MissingResultRule``, and only `treat-as-failure` binds |
//   | any timeout or deadline | nowhere. There is none, and there is no seam to inject one |
//   | whether the result may approve a configuration | nowhere in this module |
//
// There is no `outcome:` parameter anywhere in this file's public surface. A caller cannot hand
// in a ``GateOutcome`` or a ``ResourceCellOutcome``; every one is computed from an approved
// limit and samples that came back.
//
// ## Three rules this file exists to make structural
//
// **A missing measurement is a failure, and it lowers the statistic rather than vanishing from
// it.** Two denominators, and both come from the plan:
//
//   * *Within one measurement.* ``ResourceMeasurementSummary/declaredSampleCount`` is the
//     plan's approved sample count, always, whatever came back.
//     ``ResourceMeasurementSummary/completeness`` is the qualifying count over that declared
//     count, so a run that took three of five approved samples reports 3/5 and not 3/3 — and
//     ``ResourceCellOutcome/sampleCountIncomplete(observed:declared:)`` fails the cell. An
//     approved sample count is not a floor a run may undershoot: it is the series the plan
//     approved a statistic over, and a median of three samples is not the median the plan
//     approved.
//   * *Across a gate.* ``ResourceGateResult/measuredCompleteness`` sums qualifying samples over
//     summed declared samples for the gate's required cells, so a cell with no samples at all
//     lowers the gate's measured completeness instead of leaving the ratio to be whatever came
//     back.
//
// ``ResourceTargetReport/record(of:)`` is non-optional and total over every `ResourceCell`,
// including ones outside the required set, and its answer for anything it has no record for is
// a failure. ``ResourceCellOutcome/outcome`` returns ``GateOutcome/passed`` or
// ``GateOutcome/failed`` and never ``GateOutcome/notExecuted``. So there is no `nil` for a
// caller to read as satisfied and no cell that can be absent from the report.
//
// **A main-application measurement cannot satisfy a Share Extension limit, or the reverse.**
// Four independent barriers:
//
//   1. ``ResourceCell`` carries its target, so the two targets' `peak-resident-memory`
//      measurements are different cells with different outcomes.
//   2. ``ResourceTargetBinding`` selects its own budget through
//      ``ResourceBudgetSet/budget(for:)`` — the caller does not pass a budget — and refuses one
//      that carries the other target. The same posture `ResourceController.init?` takes.
//   3. ``ResourceSample`` records the process it was taken in, and a sample whose target is not
//      the cell's is refused with ``ResourceCellOutcome/crossTargetSample(observed:required:)``
//      before any comparison. ``QualifyingResourceEvidence`` refuses it a second time.
//   4. ``ResourceTargetReport/gateResult(for:)`` computes a gate from *this* target's cells
//      only, so a main-application report has no cells for `handoff-latency` and records it as
//      failed rather than as satisfied-elsewhere. Raw values and the pass decision are stored
//      per target and never merged (Requirements 11.19, 11.20).
//
// **A physical-iPhone gate is not satisfiable by host or simulator evidence.** Two independent
// barriers, and both have to be crossed:
//
//   1. ``ResourceCellOutcome/withinLimit`` carries a ``ResourceMeasurementAgreement``, which can
//      only be built from a ``QualifyingResourceEvidence``, whose only initialiser is internal
//      to this module and refuses any sample not taken on a physical iPhone, in the cell's
//      target process, on the bound configuration, on a configuration the approved plan
//      enumerates, under the bound version tuple (Requirements 13.16 and 13.20).
//   2. ``ResourceTargetReport/gateResult(for:)`` additionally consults
//      ``ObservedParityEnvironment/current``, which is decided by the platform this module was
//      compiled for and cannot be supplied, overridden, or configured. A run in a host test
//      process or a simulator therefore fails every resource gate no matter what its samples
//      claim.
//
// Barrier 1 bounds what a sample can become; barrier 2 bounds what a *process* can conclude.
// Today this repository has no physical iPhone and only a simulator runtime, so barrier 2 is
// failing for every gate and the report says so by name. That is the correct result and not a
// limitation of the runner: a host-satisfiable device gate would be a false pass.

// MARK: - Measurement results

/// One measurement that read inside its approved limit, on evidence that may back a
/// physical-device gate.
///
/// The only satisfying outcome, and the only type in this module that means "this measurement
/// passed". It cannot be constructed outside the module and cannot be constructed inside it
/// without a ``QualifyingResourceEvidence``.
public struct ResourceMeasurementAgreement: Hashable, Sendable {
    public let cell: ResourceCell

    /// Proof that every sample behind this measurement may back a device gate.
    public let evidence: QualifyingResourceEvidence

    /// The declared statistic over the complete approved series.
    public let summaryValue: ObservedResourceValue

    /// The approved limit the summary was compared against.
    ///
    /// Retained rather than replaced by "within limit", so a release record carries the
    /// measured value beside the limit it met and a later limit change is auditable against it.
    public let limit: ValidatedLimit

    init(
        cell: ResourceCell,
        evidence: QualifyingResourceEvidence,
        summaryValue: ObservedResourceValue,
        limit: ValidatedLimit
    ) {
        self.cell = cell
        self.evidence = evidence
        self.summaryValue = summaryValue
        self.limit = limit
    }
}

/// Why one measurement did not read inside its approved limit.
public enum ResourceExceedanceDetail: Hashable, Sendable, CustomStringConvertible {
    /// The summarized magnitude exceeds the approved numeric ceiling.
    case magnitudeExceedsLimit(summary: Decimal, ceiling: Decimal, unit: ResourceLimitUnit)

    /// The summarized thermal state is hotter than the approved maximum.
    case stateExceedsLimit(summary: ThermalState, maximum: ThermalState)

    /// The samples and the approved limit are different kinds of value.
    ///
    /// A thermal state cannot be compared to a byte ceiling. The plan schema already binds a
    /// limit's kind to its metric, so this is a sample that arrived in the wrong shape, and it
    /// is a failure rather than a conversion.
    case limitKindMismatch(sampleKind: ObservedResourceValueKind, limitIsCategorical: Bool)

    public var description: String {
        switch self {
        case let .magnitudeExceedsLimit(summary, ceiling, unit):
            return "\(summary) \(unit.rawValue) exceeds the approved limit \(ceiling)"
        case let .stateExceedsLimit(summary, maximum):
            return "\(summary.rawValue) is hotter than the approved maximum \(maximum.rawValue)"
        case let .limitKindMismatch(sampleKind, limitIsCategorical):
            return "a \(sampleKind.rawValue) sample cannot be compared to a "
                + (limitIsCategorical ? "thermal-state limit" : "numeric limit")
        }
    }
}

/// One measurement that was taken and did not read inside its limit.
public struct ResourceLimitExceedance: Hashable, Sendable {
    public let cell: ResourceCell
    public let detail: ResourceExceedanceDetail

    /// The summarized value, when the measurement produced one.
    public let summaryValue: ObservedResourceValue?

    init(
        cell: ResourceCell,
        detail: ResourceExceedanceDetail,
        summaryValue: ObservedResourceValue? = nil
    ) {
        self.cell = cell
        self.detail = detail
        self.summaryValue = summaryValue
    }
}

/// A required measurement with no result at all, and what is owed for it.
///
/// Carries three things because a release audit needs all three: why nothing came back, which
/// release-controlled input would supply it, and which standing limits apply to that
/// measurement whether or not the input ever arrives.
public struct ResourceMeasurementGap: Hashable, Sendable {
    public let fault: ResourceSampleFault
    public let owed: UnprovisionedResourceInput
    public let standingLimits: Set<UnobservableResourceEvidence>

    init(
        fault: ResourceSampleFault,
        owed: UnprovisionedResourceInput,
        standingLimits: Set<UnobservableResourceEvidence>
    ) {
        self.fault = fault
        self.owed = owed
        self.standingLimits = standingLimits
    }
}

/// The outcome of one required resource measurement.
///
/// Nine cases, exactly one of which satisfies the cell. There is no case meaning "skipped",
/// "pending", "not applicable", "approximated", or "assumed", and no case that a missing
/// result maps to other than a failure.
public enum ResourceCellOutcome: Hashable, Sendable, CustomStringConvertible {
    /// Summarized over the complete approved series, on qualifying evidence, and inside the
    /// approved limit.
    case withinLimit(ResourceMeasurementAgreement)

    /// Measured and outside the approved limit.
    case exceededLimit(ResourceLimitExceedance)

    /// No sample came back for a required measurement (Requirement 13.19).
    case measurementMissing(ResourceMeasurementGap)

    /// Fewer samples came back than the plan's approved sample count.
    ///
    /// Distinct from ``measurementMissing`` because the two describe different failures: one
    /// measurement was not taken, the other was taken fewer times than approved. Both fail. An
    /// approved sample count is not a floor a run may undershoot.
    case sampleCountIncomplete(observed: Int, declared: Int)

    /// A sample came back but cannot satisfy a physical-device gate (Requirement 13.16).
    case nonQualifyingEvidence(NonQualifyingParityEvidence)

    /// A sample was taken in the other target's process (Requirements 11.19, 11.20).
    case crossTargetSample(observed: ExecutionTarget, required: ExecutionTarget)

    /// Nothing in this repository can take this measurement, or the plan cannot predeclare it.
    case measurementUnavailable(UnobservableResourceEvidence)

    /// The samples are a different kind of value than the approved limit.
    case sampleKindMismatch(observed: ObservedResourceValueKind, required: ObservedResourceValueKind)

    /// The samples are stated in a different unit than the approved limit.
    case sampleUnitMismatch(observed: ResourceLimitUnit, required: ResourceLimitUnit)

    /// Whether this cell is satisfied. True for ``withinLimit`` alone.
    public var isSatisfied: Bool {
        if case .withinLimit = self { true } else { false }
    }

    /// Whether a complete measurement was actually summarized and compared, passing or not.
    ///
    /// Distinct from ``isSatisfied``: a gate tolerates nothing here, but a release audit needs
    /// to distinguish "measured and over the limit" from "never measured", because the two are
    /// closed by different work.
    public var wasMeasured: Bool {
        switch self {
        case .withinLimit, .exceededLimit: true
        case .measurementMissing, .sampleCountIncomplete, .nonQualifyingEvidence,
             .crossTargetSample, .measurementUnavailable, .sampleKindMismatch,
             .sampleUnitMismatch:
            false
        }
    }

    /// The recorded gate outcome for this cell.
    ///
    /// ``GateOutcome/notExecuted`` is deliberately unreachable. Every required measurement is
    /// asked for, so a measurement with no samples is a failing measurement rather than one
    /// that quietly did not participate — the same rule the parity runners apply to a missing
    /// observation.
    public var outcome: GateOutcome { isSatisfied ? .passed : .failed }

    /// The summarized value this cell produced, when it produced one.
    public var summaryValue: ObservedResourceValue? {
        switch self {
        case let .withinLimit(agreement): agreement.summaryValue
        case let .exceededLimit(exceedance): exceedance.summaryValue
        case .measurementMissing, .sampleCountIncomplete, .nonQualifyingEvidence,
             .crossTargetSample, .measurementUnavailable, .sampleKindMismatch,
             .sampleUnitMismatch:
            nil
        }
    }

    public var description: String {
        switch self {
        case let .withinLimit(agreement):
            return "within limit on "
                + agreement.evidence.configuration.hardwareIdentifier.rawValue
        case let .exceededLimit(exceedance):
            return "exceeded: \(exceedance.detail.description)"
        case let .measurementMissing(gap):
            return "\(gap.fault.description); owed: \(gap.owed.rawValue)"
        case let .sampleCountIncomplete(observed, declared):
            return "\(observed) of \(declared) approved samples came back"
        case let .nonQualifyingEvidence(reason):
            return "non-qualifying evidence: \(reason.description)"
        case let .crossTargetSample(observed, required):
            return "measured in \(observed.rawValue); \(required.rawValue) was required"
        case let .measurementUnavailable(limit):
            return "no measurement is available: \(limit.rawValue)"
        case let .sampleKindMismatch(observed, required):
            return "measured a \(observed.rawValue) where a \(required.rawValue) was required"
        case let .sampleUnitMismatch(observed, required):
            return "measured in \(observed.rawValue) where \(required.rawValue) was required"
        }
    }
}

// MARK: - The raw series

/// Every raw sample one measurement produced, and the declared statistic over them.
///
/// Kept apart from ``ResourceCellOutcome`` on purpose: Requirement 11.19 requires raw values
/// and the pass or fail result to be recorded separately, so a threshold cannot be chosen after
/// observing a measurement and then presented as if it had been predeclared.
///
/// ``declaredSampleCount`` is the plan's, always. It does not shrink to what came back, which
/// is what makes ``completeness`` a statistic a missing sample *lowers* rather than one a
/// missing sample disappears from.
public struct ResourceMeasurementSummary: Hashable, Sendable {
    /// The plan's approved sample count, or `0` when the plan declares no measurement at all.
    public let declaredSampleCount: Int

    /// Samples that came back, were taken in the right process, and qualified.
    public let qualifyingSampleCount: Int

    /// The statistic the plan declared, or `nil` when the plan declares no measurement.
    public let summaryStatistic: SummaryStatistic?

    /// The raw samples, in the order the declared series asked for them.
    ///
    /// Retained rather than replaced by the summary, so a release record carries the series.
    public let rawValues: [ObservedResourceValue]

    /// The declared statistic over ``rawValues``, or `nil` when nothing summarizable came back.
    ///
    /// Present even when the series is incomplete, because the raw record is what it is; the
    /// pass decision is ``ResourceCellOutcome``'s and it refuses an incomplete series.
    public let summaryValue: ObservedResourceValue?

    init(
        declaredSampleCount: Int,
        qualifyingSampleCount: Int,
        summaryStatistic: SummaryStatistic?,
        rawValues: [ObservedResourceValue],
        summaryValue: ObservedResourceValue?
    ) {
        self.declaredSampleCount = declaredSampleCount
        self.qualifyingSampleCount = qualifyingSampleCount
        self.summaryStatistic = summaryStatistic
        self.rawValues = rawValues
        self.summaryValue = summaryValue
    }

    /// Whether the approved series came back whole.
    ///
    /// Compared as whole counts rather than through the decimal ratio, so the pass decision
    /// never depends on decimal division. A declared count of zero is never complete: a
    /// measurement the plan cannot predeclare has no approved series to complete.
    public var isComplete: Bool {
        declaredSampleCount > 0 && qualifyingSampleCount == declaredSampleCount
    }

    /// Qualifying samples over the plan's approved sample count.
    ///
    /// The statistic a missing sample lowers. Reported rather than used for the pass decision,
    /// which ``isComplete`` makes on integers.
    public var completeness: UnitInterval {
        guard declaredSampleCount > 0, qualifyingSampleCount > 0 else { return .zero }
        guard qualifyingSampleCount < declaredSampleCount else { return .one }
        let ratio = Decimal(qualifyingSampleCount) / Decimal(declaredSampleCount)
        // A quotient of two positive counts with the numerator below the denominator is inside
        // `0...1`. The fallback is a fail-closed floor rather than a value this module chose.
        return (try? UnitInterval(validating: ratio)) ?? .zero
    }

    /// A summary for a measurement the plan cannot predeclare.
    static let notDeclared = ResourceMeasurementSummary(
        declaredSampleCount: 0,
        qualifyingSampleCount: 0,
        summaryStatistic: nil,
        rawValues: [],
        summaryValue: nil
    )
}

/// One required measurement's raw series, its approved limit, and its pass or fail result.
public struct ResourceCellRecord: Hashable, Sendable {
    public let cell: ResourceCell

    /// The raw values and the declared statistic over them.
    public let summary: ResourceMeasurementSummary

    /// The approved limit, or `nil` when the plan declares no measurement.
    public let limit: ValidatedLimit?

    /// The pass or fail result, kept apart from the raw series.
    public let outcome: ResourceCellOutcome

    /// Standing limits that qualify what this measurement establishes, whatever its outcome.
    public let standingLimits: Set<UnobservableResourceEvidence>

    init(
        cell: ResourceCell,
        summary: ResourceMeasurementSummary,
        limit: ValidatedLimit?,
        outcome: ResourceCellOutcome,
        standingLimits: Set<UnobservableResourceEvidence>
    ) {
        self.cell = cell
        self.summary = summary
        self.limit = limit
        self.outcome = outcome
        self.standingLimits = standingLimits
    }
}

// MARK: - The bindings

/// One plan, one target's budget, one configuration, and one version tuple, reconciled.
///
/// Construction is the reconciliation gate. A value of this type means the plan declares a
/// complete measurement specification for every metric this target's budget limits *on this
/// exact configuration*, the plan's pass limit and the budget's hard limit agree for every one
/// of them, the budget was measured by this plan, the version tuple names this exact plan,
/// bundle, manifest, and build, and the plan's missing-result rule is `treat-as-failure`.
///
/// It does not mean anything was measured. That is ``ResourceMeasurementRunner``'s job, and it
/// needs samples.
public struct ResourceTargetBinding: Hashable, Sendable {
    public let target: ExecutionTarget
    public let plan: DeviceValidationPlan

    /// The budget for ``target``, selected from the signed set rather than passed in.
    public let budget: ResourceBudget

    public let configuration: CandidateDeviceConfiguration
    public let versionTuple: ValidationVersionTuple

    /// The closed set of measurements this binding owes, in a stable order.
    public let requiredCells: [ResourceCell]

    /// The predeclared specification for each metric, reconciled at construction.
    private let specifications: [ResourceMetric: ResourceMeasurementSpecification]

    public init(
        target: ExecutionTarget,
        plan: DeviceValidationPlan,
        budgets: ResourceBudgetSet,
        configuration: CandidateDeviceConfiguration,
        versionTuple: ValidationVersionTuple
    ) throws(ResourceBindingError) {
        guard plan.missingResultRule == .treatAsFailure else {
            throw ResourceBindingError.missingResultRuleNotFailure(plan.missingResultRule)
        }
        guard plan.candidateConfigurations.contains(configuration) else {
            throw ResourceBindingError.configurationNotInPlan(
                configuration.hardwareIdentifier,
                configuration.osVersion
            )
        }
        // The caller does not choose a budget. `ResourceBudgetSet` already guarantees each side
        // carries its own target, so this selection cannot return the other target's artifact —
        // and it is checked anyway, because target separation is the behaviour this task turns
        // on and relying on another type's invariant for it would leave nothing here that fails
        // when the invariant changes.
        let selected = budgets.budget(for: target)
        guard selected.target == target else {
            throw ResourceBindingError.budgetTargetMismatch(
                expected: target,
                found: selected.target
            )
        }
        guard selected.validationPlan == plan.id else {
            throw ResourceBindingError.budgetNotMeasuredByPlan(
                budget: selected.id,
                plan: plan.id
            )
        }
        guard versionTuple.validationPlan == plan.id else {
            throw ResourceBindingError.versionTuplePlanMismatch(
                expected: plan.id,
                found: versionTuple.validationPlan
            )
        }
        guard versionTuple.modelBundle == plan.modelBundle else {
            throw ResourceBindingError.versionTupleModelBundleMismatch(
                expected: plan.modelBundle,
                found: versionTuple.modelBundle
            )
        }
        guard versionTuple.capabilityManifest == plan.capabilityManifest else {
            throw ResourceBindingError.versionTupleCapabilityManifestMismatch(
                expected: plan.capabilityManifest,
                found: versionTuple.capabilityManifest
            )
        }
        guard configuration.appBuild == versionTuple.appBuild else {
            throw ResourceBindingError.versionTupleAppBuildMismatch(
                expected: versionTuple.appBuild,
                found: configuration.appBuild
            )
        }

        var reconciled: [ResourceMetric: ResourceMeasurementSpecification] = [:]
        for metric in ResourceMetric.requiredMetrics(for: target).sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            guard let hardLimit = selected.limit(for: metric) else {
                throw ResourceBindingError.budgetLimitMissing(target, metric)
            }
            let matching = plan.measurements.first {
                $0.target == target
                    && $0.metric == metric
                    && $0.hardwareIdentifier == configuration.hardwareIdentifier
                    && $0.osVersion == configuration.osVersion
            }
            guard let specification = matching else {
                throw ResourceBindingError.measurementSpecificationMissing(target, metric)
            }
            guard specification.appBuild == configuration.appBuild else {
                throw ResourceBindingError.measurementConditionsMismatch(target, metric)
            }
            // Both numbers are approved and neither is this module's to prefer, so a
            // disagreement is a reconciliation failure rather than a choice: the release has
            // published two different limits for one metric (Requirements 15.8, 15.9).
            guard specification.passLimit == hardLimit else {
                throw ResourceBindingError.passLimitDisagreesWithBudget(target, metric)
            }
            if metric.isCategorical, !specification.summaryStatistic.isOrderStatistic {
                throw ResourceBindingError.thermalSummaryStatisticNotOrdinal(
                    specification.summaryStatistic
                )
            }
            reconciled[metric] = specification
        }

        let cells = ResourceSubject.required(for: target)
            .map { ResourceCell(target: target, subject: $0) }
            .sorted { $0.orderingKey < $1.orderingKey }
        guard !cells.isEmpty else { throw ResourceBindingError.requiredCellSetEmpty }

        self.target = target
        self.plan = plan
        self.budget = selected
        self.configuration = configuration
        self.versionTuple = versionTuple
        self.requiredCells = cells
        self.specifications = reconciled
    }

    /// The predeclared specification for one cell, or `nil` for a measurement the plan cannot
    /// declare.
    public func specification(for cell: ResourceCell) -> ResourceMeasurementSpecification? {
        guard cell.target == target, let metric = cell.metric else { return nil }
        return specifications[metric]
    }

    /// The plan's approved sample count for one cell, or `0` when the plan declares none.
    ///
    /// The denominator of ``ResourceMeasurementSummary/completeness``, and the range the runner
    /// enumerates sample positions over. It comes from the plan and nowhere else.
    public func declaredSampleCount(for cell: ResourceCell) -> Int {
        specification(for: cell)?.sampleCount.value ?? 0
    }

    /// The approved pass limit for one cell, or `nil` when the plan declares none.
    public func limit(for cell: ResourceCell) -> ValidatedLimit? {
        specification(for: cell)?.passLimit
    }

    /// The required cells for one gate, in stable order.
    public func requiredCells(for gate: DeviceGate) -> [ResourceCell] {
        requiredCells.filter { $0.cellGate.gate == gate }
    }
}

/// Both targets' bindings, built from one plan, one budget set, one configuration, and one
/// version tuple.
///
/// Requirement 13.20 forbids assembling gate evidence across builds, bundles, fixture suites,
/// plans, capability sets, or implementation versions. This type is how that becomes
/// unrepresentable rather than checked: there is no initialiser that takes two independently
/// constructed ``ResourceTargetBinding`` values, so a run cannot pair a main-application
/// binding from one tuple with a Share Extension binding from another.
public struct ResourceValidationRunBinding: Hashable, Sendable {
    public let mainApplication: ResourceTargetBinding
    public let shareExtension: ResourceTargetBinding

    public init(
        plan: DeviceValidationPlan,
        budgets: ResourceBudgetSet,
        configuration: CandidateDeviceConfiguration,
        versionTuple: ValidationVersionTuple
    ) throws(ResourceBindingError) {
        self.mainApplication = try ResourceTargetBinding(
            target: .mainApplication,
            plan: plan,
            budgets: budgets,
            configuration: configuration,
            versionTuple: versionTuple
        )
        self.shareExtension = try ResourceTargetBinding(
            target: .shareExtension,
            plan: plan,
            budgets: budgets,
            configuration: configuration,
            versionTuple: versionTuple
        )
    }

    /// The binding for one target. Total.
    public func binding(for target: ExecutionTarget) -> ResourceTargetBinding {
        switch target {
        case .mainApplication: mainApplication
        case .shareExtension: shareExtension
        }
    }

    public var configuration: CandidateDeviceConfiguration { mainApplication.configuration }
    public var versionTuple: ValidationVersionTuple { mainApplication.versionTuple }
    public var plan: DeviceValidationPlan { mainApplication.plan }
}

// MARK: - Gate results

/// The recorded result of one resource gate, for one target's cells.
public struct ResourceGateResult: Hashable, Sendable {
    public let gate: DeviceGate
    public let applicability: GateApplicability

    /// The target whose cells this result was computed from.
    public let target: ExecutionTarget

    /// The required cells this gate is computed from, in stable order.
    public let cells: [ResourceCell]

    /// The recorded outcome.
    ///
    /// ``GateOutcome/notExecuted`` is unreachable here. No resource gate is provenance
    /// conditional, so no approved decision can declare one inapplicable, and a gate whose
    /// cells were never measured fails rather than being absent.
    public let outcome: GateOutcome

    /// Qualifying samples over summed approved sample counts across this gate's cells.
    ///
    /// The gate-level statistic a missing measurement lowers. The denominator is the plan's
    /// declared total, so a cell that produced nothing at all pulls the ratio down instead of
    /// leaving it to be computed over whichever cells reported.
    public let measuredCompleteness: UnitInterval

    /// Why an applicable gate cannot pass in this process, when that is the reason.
    ///
    /// Non-`nil` whenever ``ObservedParityEnvironment/canProducePhysicalDeviceEvidence`` is
    /// false, which is every host and simulator run.
    public let processRefusal: NonQualifyingParityEvidence?

    init(
        gate: DeviceGate,
        applicability: GateApplicability,
        target: ExecutionTarget,
        cells: [ResourceCell],
        outcome: GateOutcome,
        measuredCompleteness: UnitInterval,
        processRefusal: NonQualifyingParityEvidence?
    ) {
        self.gate = gate
        self.applicability = applicability
        self.target = target
        self.cells = cells
        self.outcome = outcome
        self.measuredCompleteness = measuredCompleteness
        self.processRefusal = processRefusal
    }
}

// MARK: - One target's report

/// Everything one target's resource run recorded.
///
/// A total mapping over the binding's closed required-cell set plus the projections a release
/// record needs. Constructible only inside this module, and only by a run: there is no
/// initialiser that takes outcomes, so a caller cannot assemble a report that declares a
/// measurement within limit.
public struct ResourceTargetReport: Hashable, Sendable {
    public let target: ExecutionTarget
    public let plan: ArtifactID
    public let budget: ArtifactID
    public let configuration: CandidateDeviceConfiguration
    public let versionTuple: ValidationVersionTuple

    /// Where this run's *process* was executing.
    ///
    /// Observed from the platform, never supplied. A caller cannot set it, so a host test run
    /// cannot report itself as a physical iPhone.
    public let runEnvironment: ExecutionEnvironment

    /// The closed required-cell set, in stable order.
    public let requiredCells: [ResourceCell]

    private let records: [ResourceCell: ResourceCellRecord]

    init(
        binding: ResourceTargetBinding,
        runEnvironment: ExecutionEnvironment,
        records: [ResourceCell: ResourceCellRecord]
    ) {
        self.target = binding.target
        self.plan = binding.plan.id
        self.budget = binding.budget.id
        self.configuration = binding.configuration
        self.versionTuple = binding.versionTuple
        self.runEnvironment = runEnvironment
        self.requiredCells = binding.requiredCells
        self.records = records
    }

    // MARK: The total mapping

    /// The record of one measurement. Total, and never satisfied without a measurement.
    ///
    /// Non-optional by design. The run recorded exactly one record per required cell, so every
    /// cell in ``requiredCells`` has a real answer here; and a cell *outside* the required set —
    /// including one belonging to the other target — gets the same failure a missing
    /// measurement gets, because "this measurement was never required of this target" is not a
    /// reason to treat it as done. There is deliberately no `nil`, no `Optional`, and no
    /// default that a caller could read as a pass.
    public func record(of cell: ResourceCell) -> ResourceCellRecord {
        if let recorded = records[cell] { return recorded }
        if cell.target != target {
            return ResourceCellRecord(
                cell: cell,
                summary: .notDeclared,
                limit: nil,
                outcome: .crossTargetSample(observed: cell.target, required: target),
                standingLimits: cell.standingMeasurementLimits
            )
        }
        return ResourceCellRecord(
            cell: cell,
            summary: .notDeclared,
            limit: nil,
            outcome: .measurementMissing(
                ResourceMeasurementGap(
                    fault: .sampleAbsent,
                    owed: cell.owedReleaseInput,
                    standingLimits: cell.standingMeasurementLimits
                )
            ),
            standingLimits: cell.standingMeasurementLimits
        )
    }

    /// The outcome of one measurement. Total.
    public func outcome(of cell: ResourceCell) -> ResourceCellOutcome { record(of: cell).outcome }

    // MARK: Projections

    /// Required measurements that read inside their approved limit.
    public var satisfiedCells: [ResourceCell] {
        requiredCells.filter { outcome(of: $0).isSatisfied }
    }

    /// Required measurements that did not, for any reason.
    public var unsatisfiedCells: [ResourceCell] {
        requiredCells.filter { !outcome(of: $0).isSatisfied }
    }

    /// Required measurements with no sample at all.
    public var missingMeasurementCells: [ResourceCell] {
        requiredCells.filter {
            if case .measurementMissing = outcome(of: $0) { true } else { false }
        }
    }

    /// Required measurements whose approved series came back short.
    public var incompleteSeriesCells: [ResourceCell] {
        requiredCells.filter {
            if case .sampleCountIncomplete = outcome(of: $0) { true } else { false }
        }
    }

    /// Required measurements whose samples cannot back a device gate.
    public var nonQualifyingCells: [ResourceCell] {
        requiredCells.filter {
            if case .nonQualifyingEvidence = outcome(of: $0) { true } else { false }
        }
    }

    /// Required measurements answered by a sample from the other target's process.
    public var crossTargetCells: [ResourceCell] {
        requiredCells.filter {
            if case .crossTargetSample = outcome(of: $0) { true } else { false }
        }
    }

    /// Required measurements nothing in this repository can take.
    public var unavailableMeasurementCells: [ResourceCell] {
        requiredCells.filter {
            if case .measurementUnavailable = outcome(of: $0) { true } else { false }
        }
    }

    /// Required measurements that belong to no mandatory device gate.
    ///
    /// Still required to pass: ``outcome`` requires every required cell, not only every gate,
    /// so a gateless measurement cannot quietly stop mattering.
    public var gatelessCells: [ResourceCell] {
        requiredCells.filter { $0.cellGate.gate == nil }
    }

    /// Why no gate can pass in this process, when that is so.
    ///
    /// Non-`nil` on a development Mac and in a simulator. This is the value that makes
    /// Requirement 13.16 structural rather than advisory: it is computed from
    /// ``ObservedParityEnvironment/current`` and there is no parameter, artifact, or approval
    /// that changes it.
    public var processRefusal: NonQualifyingParityEvidence? {
        runEnvironment.isPhysicalDeviceEvidence ? nil : .notPhysicalIPhone(runEnvironment)
    }

    /// Qualifying samples over summed approved sample counts across every required cell.
    public var measuredCompleteness: UnitInterval { Self.completeness(of: requiredCells, in: self) }

    /// The release-controlled inputs this run is still owed, in declaration order.
    public var owedInputs: [UnprovisionedResourceInput] {
        var owed = Set<UnprovisionedResourceInput>()
        for cell in requiredCells {
            switch outcome(of: cell) {
            case let .measurementMissing(gap):
                owed.insert(gap.owed)
            case .sampleCountIncomplete, .measurementUnavailable, .sampleKindMismatch,
                 .sampleUnitMismatch:
                owed.insert(cell.owedReleaseInput)
            case .withinLimit, .exceededLimit, .nonQualifyingEvidence, .crossTargetSample:
                continue
            }
        }
        if processRefusal != nil || !nonQualifyingCells.isEmpty {
            owed.insert(.physicalIPhoneMeasurementEnvironment)
        }
        if !owed.isEmpty {
            // The plan's measurement half and this target's budget are what every one of these
            // gaps ultimately hangs from, so they are named rather than left implied.
            owed.insert(.deviceValidationPlanResourceMeasurements)
            switch target {
            case .mainApplication: owed.insert(.mainApplicationResourceBudget)
            case .shareExtension:
                owed.insert(.shareExtensionResourceBudget)
                // A Share Extension measurement set has no execution home: both declared
                // device-test targets are hosted by the application.
                owed.insert(.shareExtensionDeviceTestHost)
            }
        }
        if !requiredCells(for: .interruptionCleanup).isEmpty
            || !requiredCells(for: .cancellationResidualWork).isEmpty
        {
            owed.insert(.dataLifecycleCleanupDeadlines)
        }
        return UnprovisionedResourceInput.allCases.filter { owed.contains($0) }
    }

    /// Standing limits that qualify what this run's measurements establish.
    ///
    /// Reported whatever each cell's outcome, because they are properties of the implementation
    /// and the artifact schema rather than of a measurement.
    public var standingLimits: [UnobservableResourceEvidence] {
        let applicable = Set(requiredCells.flatMap { $0.standingMeasurementLimits })
        return UnobservableResourceEvidence.allCases.filter { applicable.contains($0) }
    }

    /// The overall outcome for this target.
    ///
    /// Passing requires every resource gate belonging to this target to pass *and* every
    /// required cell to be satisfied. The second clause is what keeps the two gateless
    /// measurements — decoded pixel count and encoded input size — from becoming invisible.
    public var outcome: GateOutcome {
        guard unsatisfiedCells.isEmpty else { return .failed }
        let gates = DeviceGate.resourceGates.filter { gate in
            !requiredCells(for: gate).isEmpty
        }
        for gate in gates where !gateResult(for: gate).outcome.isPassing {
            return .failed
        }
        return gates.isEmpty ? .failed : .passed
    }

    // MARK: Gates

    /// The required cells for one gate, in stable order.
    public func requiredCells(for gate: DeviceGate) -> [ResourceCell] {
        requiredCells.filter { $0.cellGate.gate == gate }
    }

    /// The recorded result of one resource gate, computed from *this target's* cells only.
    ///
    /// A gate with no cells in this target records ``GateOutcome/failed`` rather than a pass:
    /// the main application takes no handoff-latency measurement, so a main-application report
    /// has nothing to say about that gate and saying nothing is not saying it passed. That is
    /// how a main-application result is kept from satisfying a Share Extension limit
    /// (Requirements 11.19, 11.20).
    public func gateResult(for gate: DeviceGate) -> ResourceGateResult {
        let cells = requiredCells(for: gate)
        let completeness = Self.completeness(of: cells, in: self)
        guard let refusal = processRefusal else {
            let measured = cells.isEmpty
                ? GateOutcome.failed
                : (cells.allSatisfy { outcome(of: $0).isSatisfied } ? .passed : .failed)
            return ResourceGateResult(
                gate: gate,
                applicability: .applicable,
                target: target,
                cells: cells,
                outcome: measured,
                measuredCompleteness: completeness,
                processRefusal: nil
            )
        }
        // Barrier 2. No amount of within-limit measurement in a host or simulator process
        // satisfies a physical-device gate, and the refusal travels with the result so the
        // reason is recorded rather than inferred from a bare failure.
        return ResourceGateResult(
            gate: gate,
            applicability: .applicable,
            target: target,
            cells: cells,
            outcome: .failed,
            measuredCompleteness: completeness,
            processRefusal: refusal
        )
    }

    /// The domain measurement record for one cell, for a device result set.
    ///
    /// The raw series is exactly what came back; the outcome is this module's. Returns `nil`
    /// for a categorical metric, because `MeasurementRecord.rawValues` is `[Decimal]` and
    /// encoding thermal states as severity ordinals would put numbers no artifact approved into
    /// a release record — recorded as
    /// ``UnobservableResourceEvidence/thermalSamplesNotRepresentableInMeasurementRecord`` and
    /// not worked around. Also `nil` for a measurement the plan cannot predeclare, which has no
    /// limit and no statistic to record.
    public func measurementRecord(
        of cell: ResourceCell,
        specification: EvidenceSource
    ) throws -> MeasurementRecord? {
        guard cell.target == target, let metric = cell.metric, !metric.isCategorical else {
            return nil
        }
        let recorded = record(of: cell)
        guard let limit = recorded.limit,
            let statistic = recorded.summary.summaryStatistic
        else {
            return nil
        }
        let magnitudes = recorded.summary.rawValues.compactMap { $0.magnitude }
        guard !magnitudes.isEmpty else { return nil }
        return try MeasurementRecord(
            metric: metric,
            target: target,
            specification: specification,
            rawValues: magnitudes,
            summaryStatistic: statistic,
            summaryValue: recorded.summary.summaryValue?.magnitude ?? 0,
            limit: limit,
            outcome: recorded.outcome.outcome
        )
    }

    // MARK: Completeness

    /// Qualifying samples over summed approved sample counts, for a set of cells.
    ///
    /// The declared total is the plan's and never shrinks to what came back, which is the whole
    /// of "a missing measurement lowers the statistic" in one function. An empty cell set has no
    /// approved series at all and reads zero rather than one: nothing to measure is not
    /// complete.
    static func completeness(of cells: [ResourceCell], in report: ResourceTargetReport) -> UnitInterval
    {
        var declared = 0
        var qualifying = 0
        for cell in cells {
            let summary = report.record(of: cell).summary
            declared += summary.declaredSampleCount
            qualifying += summary.qualifyingSampleCount
        }
        guard declared > 0, qualifying > 0 else { return .zero }
        guard qualifying < declared else { return .one }
        let ratio = Decimal(qualifying) / Decimal(declared)
        return (try? UnitInterval(validating: ratio)) ?? .zero
    }
}

// MARK: - Both targets

/// Everything one device configuration's resource run recorded, partitioned by target.
///
/// Requirement 11.19 requires main-application and Share Extension resource behaviour to be
/// reported as separate measurement sets with separate pass or fail gate results, and
/// Requirement 11.20 requires handoff viability to be approved independently. This type is that
/// shape: two reports, never merged, with no member that reduces them to one measurement set.
public struct ResourceValidationReport: Hashable, Sendable {
    public let mainApplication: ResourceTargetReport
    public let shareExtension: ResourceTargetReport

    init(mainApplication: ResourceTargetReport, shareExtension: ResourceTargetReport) {
        self.mainApplication = mainApplication
        self.shareExtension = shareExtension
    }

    /// One target's report. Total.
    public func report(for target: ExecutionTarget) -> ResourceTargetReport {
        switch target {
        case .mainApplication: mainApplication
        case .shareExtension: shareExtension
        }
    }

    /// Where this run's process was executing. The same for both targets, by construction.
    public var runEnvironment: ExecutionEnvironment { mainApplication.runEnvironment }

    /// Why no gate can pass in this process, when that is so.
    public var processRefusal: NonQualifyingParityEvidence? { mainApplication.processRefusal }

    /// The per-target result of one gate, for every target that measures it.
    ///
    /// One entry for a per-target resource gate and two for cancellation residual work and
    /// interruption cleanup, whose single `DeviceGate` case covers both processes while
    /// Requirement 11.19 still requires each target's raw values and pass result to be recorded
    /// apart. Nothing here merges the two.
    public func perTargetGateResults(for gate: DeviceGate) -> [ResourceGateResult] {
        if let target = gate.measurementTarget {
            return [report(for: target).gateResult(for: gate)]
        }
        return ExecutionTarget.allCases.map { report(for: $0).gateResult(for: gate) }
    }

    /// The combined outcome of one gate across every target that measures it.
    ///
    /// Passing requires every contributing target to pass. A gate no target measures — a
    /// parity, accessibility, or localization gate — has no cells here and fails, because this
    /// module measures resources and has nothing to say about those.
    public func outcome(of gate: DeviceGate) -> GateOutcome {
        let results = perTargetGateResults(for: gate)
        guard !results.isEmpty else { return .failed }
        return results.allSatisfy { $0.outcome.isPassing } ? .passed : .failed
    }

    /// The overall resource outcome for this configuration.
    ///
    /// Passing requires both targets to pass independently. Requirement 11.20's independence
    /// runs the other way too: a Share Extension pass does not carry the main application, and
    /// this is the only member that looks at both.
    public var outcome: GateOutcome {
        mainApplication.outcome.isPassing && shareExtension.outcome.isPassing
            ? .passed
            : .failed
    }

    /// Every release-controlled input either target is still owed, in declaration order.
    public var owedInputs: [UnprovisionedResourceInput] {
        let owed = Set(mainApplication.owedInputs).union(shareExtension.owedInputs)
        return UnprovisionedResourceInput.allCases.filter { owed.contains($0) }
    }

    /// Every standing limit either target's measurements are qualified by.
    public var standingLimits: [UnobservableResourceEvidence] {
        let applicable = Set(mainApplication.standingLimits)
            .union(shareExtension.standingLimits)
        return UnobservableResourceEvidence.allCases.filter { applicable.contains($0) }
    }
}

// MARK: - The runner

/// Runs one configuration's resource, thermal, cancellation, and interruption measurements.
///
/// Holds nothing but the injected sample reader, so it carries no approved value of its own and
/// no state two runs could share. It cannot be constructed without a reader, which is the
/// structural form of "a run without samples does not happen" — and a reader with nothing in it
/// produces a report in which every measurement is a failure, not an empty report.
///
/// There is no clock, no `Duration`, no deadline, and no elapsed-time member anywhere in this
/// type. Requirements 15.8 and 15.9 make the plan the authoritative source of numeric
/// analysis-time limits and Property 36 forbids synthesizing one, so the latency metrics arrive
/// as measured magnitudes through the sample seam and are compared to the plan's own approved
/// limits. Nothing here times anything.
public struct ResourceMeasurementRunner: Sendable {
    private let samples: any ResourceSampleReading

    /// Creates a runner over the sample reader.
    ///
    /// Required, with no default. There is no convenience initialiser and no in-module reader:
    /// a runner without samples cannot exist rather than comparing against something this
    /// module chose.
    public init(samples: any ResourceSampleReading) {
        self.samples = samples
    }

    /// Measures every cell both targets require and records one result for each.
    ///
    /// Never throws. A resource run's failures are its result, and turning the first missing
    /// sample into a thrown error would stop the run at the first gap and report nothing about
    /// the rest — which is exactly the partial evidence Requirement 13.19 refuses.
    public func run(_ binding: ResourceValidationRunBinding) -> ResourceValidationReport {
        ResourceValidationReport(
            mainApplication: run(binding.mainApplication),
            shareExtension: run(binding.shareExtension)
        )
    }

    /// Measures every cell one target requires and records one result for each.
    public func run(_ binding: ResourceTargetBinding) -> ResourceTargetReport {
        var records: [ResourceCell: ResourceCellRecord] = [:]
        for cell in binding.requiredCells {
            records[cell] = evaluate(cell, in: binding)
        }
        return ResourceTargetReport(
            binding: binding,
            runEnvironment: ObservedParityEnvironment.current,
            records: records
        )
    }

    // MARK: One cell

    private func evaluate(
        _ cell: ResourceCell,
        in binding: ResourceTargetBinding
    ) -> ResourceCellRecord {
        let standing = cell.standingMeasurementLimits
        // A measurement nothing can take, or one the plan cannot predeclare, is refused before
        // any sample is read, so a run cannot appear to have measured it.
        if let blocking = standing
            .sorted(by: { $0.rawValue < $1.rawValue })
            .first(where: \.blocksMeasurement)
        {
            return ResourceCellRecord(
                cell: cell,
                summary: .notDeclared,
                limit: binding.limit(for: cell),
                outcome: .measurementUnavailable(blocking),
                standingLimits: standing
            )
        }
        guard let limit = binding.limit(for: cell) else {
            // Unreachable through a binding: every metric cell has a reconciled specification,
            // and every condition cell is blocked above. Recorded as a missing measurement
            // rather than compared without a limit.
            return ResourceCellRecord(
                cell: cell,
                summary: .notDeclared,
                limit: nil,
                outcome: .measurementMissing(gap(for: cell, fault: .sampleAbsent)),
                standingLimits: standing
            )
        }
        let declared = binding.declaredSampleCount(for: cell)
        let statistic = binding.specification(for: cell)?.summaryStatistic

        var observed: [ResourceSample] = []
        var firstFault: ResourceSampleFault?
        for ordinal in 0..<declared {
            do {
                observed.append(
                    try samples.sample(for: cell, at: ResourceSampleIndex(ordinal: ordinal))
                )
            } catch {
                // A plain `catch` rather than `catch let error as ResourceSampleFault`: with
                // typed throws the pattern is always true, and Swift 6.3.3 crashes
                // `swift-frontend` in `SILGenCleanup` rather than only warning about it.
                if firstFault == nil { firstFault = error }
            }
        }

        let summary = Self.summarize(
            observed.map(\.value),
            declared: declared,
            statistic: statistic,
            limit: limit
        )

        func record(_ outcome: ResourceCellOutcome) -> ResourceCellRecord {
            ResourceCellRecord(
                cell: cell,
                summary: summary,
                limit: limit,
                outcome: outcome,
                standingLimits: standing
            )
        }

        guard !observed.isEmpty else {
            return record(.measurementMissing(gap(for: cell, fault: firstFault ?? .sampleAbsent)))
        }
        // A sample from the other target's process is refused before the environment gate, so
        // the report names target separation rather than reporting a generic refusal for it.
        if let foreign = observed.first(where: { $0.target != binding.target }) {
            return record(
                .crossTargetSample(observed: foreign.target, required: binding.target)
            )
        }
        let requiredKind: ObservedResourceValueKind = limit.isCategoricalLimit
            ? .thermalState
            : .quantity
        if let wrongKind = observed.first(where: { $0.value.kind != requiredKind }) {
            return record(
                .sampleKindMismatch(observed: wrongKind.value.kind, required: requiredKind)
            )
        }
        if case let .numeric(_, unit: declaredUnit) = limit,
            let wrongUnit = observed.first(where: { $0.value.unit != declaredUnit })
        {
            return record(
                .sampleUnitMismatch(
                    observed: wrongUnit.value.unit ?? declaredUnit,
                    required: declaredUnit
                )
            )
        }
        guard
            let evidence = QualifyingResourceEvidence(
                samples: observed,
                plan: binding.plan,
                target: binding.target,
                configuration: binding.configuration,
                versionTuple: binding.versionTuple
            )
        else {
            return record(.nonQualifyingEvidence(Self.refusal(for: observed, in: binding)))
        }
        // An approved sample count is not a floor. A statistic over a shorter series is not the
        // statistic the plan approved, so the incomplete series fails here even though every
        // sample that did come back qualified (Requirement 13.19).
        guard summary.isComplete else {
            return record(
                .sampleCountIncomplete(observed: observed.count, declared: declared)
            )
        }
        guard let summarized = summary.summaryValue else {
            // Unreachable while the series is complete and nonempty. Recorded as a missing
            // measurement rather than compared against nothing.
            return record(.measurementMissing(gap(for: cell, fault: .sampleUnreadable)))
        }
        return record(
            Self.compare(cell: cell, summary: summarized, limit: limit, evidence: evidence)
        )
    }

    // MARK: Comparing

    private static func compare(
        cell: ResourceCell,
        summary: ObservedResourceValue,
        limit: ValidatedLimit,
        evidence: QualifyingResourceEvidence
    ) -> ResourceCellOutcome {
        switch (limit, summary) {
        case let (.numeric(value: ceiling, unit: unit), .quantity(measured, unit: measuredUnit)):
            guard measuredUnit == unit else {
                return .sampleUnitMismatch(observed: measuredUnit, required: unit)
            }
            guard measured <= ceiling.value else {
                return .exceededLimit(
                    ResourceLimitExceedance(
                        cell: cell,
                        detail: .magnitudeExceedsLimit(
                            summary: measured,
                            ceiling: ceiling.value,
                            unit: unit
                        ),
                        summaryValue: summary
                    )
                )
            }
            return .withinLimit(
                ResourceMeasurementAgreement(
                    cell: cell,
                    evidence: evidence,
                    summaryValue: summary,
                    limit: limit
                )
            )
        case let (.thermal(maximumState: maximum), .thermalState(measured)):
            guard measured <= maximum else {
                return .exceededLimit(
                    ResourceLimitExceedance(
                        cell: cell,
                        detail: .stateExceedsLimit(summary: measured, maximum: maximum),
                        summaryValue: summary
                    )
                )
            }
            return .withinLimit(
                ResourceMeasurementAgreement(
                    cell: cell,
                    evidence: evidence,
                    summaryValue: summary,
                    limit: limit
                )
            )
        case (.numeric, .thermalState), (.thermal, .quantity):
            // Already reconciled against the limit's kind before this point. Recorded as an
            // exceedance rather than as a pass.
            return .exceededLimit(
                ResourceLimitExceedance(
                    cell: cell,
                    detail: .limitKindMismatch(
                        sampleKind: summary.kind,
                        limitIsCategorical: limit.isCategoricalLimit
                    ),
                    summaryValue: summary
                )
            )
        }
    }

    // MARK: Summarizing

    /// The plan's declared statistic over the samples that came back.
    ///
    /// The declared count is carried through unchanged whatever came back, which is what makes
    /// a missing sample lower ``ResourceMeasurementSummary/completeness`` instead of
    /// disappearing from it.
    static func summarize(
        _ values: [ObservedResourceValue],
        declared: Int,
        statistic: SummaryStatistic?,
        limit: ValidatedLimit
    ) -> ResourceMeasurementSummary {
        guard let statistic, !values.isEmpty else {
            return ResourceMeasurementSummary(
                declaredSampleCount: declared,
                qualifyingSampleCount: values.count,
                summaryStatistic: statistic,
                rawValues: values,
                summaryValue: nil
            )
        }
        let summarized: ObservedResourceValue?
        if limit.isCategoricalLimit {
            let states = values.compactMap { $0.state }
            summarized = states.count == values.count
                ? orderStatistic(of: states.sorted(), statistic).map { .thermalState($0) }
                : nil
        } else {
            let magnitudes = values.compactMap { $0.magnitude }
            let units = Set(values.compactMap { $0.unit })
            summarized = magnitudes.count == values.count && units.count == 1
                ? numericStatistic(of: magnitudes, statistic)
                    .map { .quantity($0, unit: units.first ?? .bytes) }
                : nil
        }
        return ResourceMeasurementSummary(
            declaredSampleCount: declared,
            qualifyingSampleCount: values.count,
            summaryStatistic: statistic,
            rawValues: values,
            summaryValue: summarized
        )
    }

    /// One numeric statistic over a nonempty sample series.
    ///
    /// Written without a `default`, so a new summary statistic forces a decision here rather
    /// than defaulting to one this module picked.
    static func numericStatistic(
        of magnitudes: [Decimal],
        _ statistic: SummaryStatistic
    ) -> Decimal? {
        guard !magnitudes.isEmpty else { return nil }
        let sorted = magnitudes.sorted()
        switch statistic {
        case .maximum:
            return sorted.last
        case .median:
            let count = sorted.count
            if count % 2 == 1 { return sorted[count / 2] }
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        case .mean:
            let total = sorted.reduce(Decimal.zero, +)
            return total / Decimal(sorted.count)
        case .percentile95:
            return sorted[nearestRankIndex(count: sorted.count)]
        }
    }

    /// One order statistic over a sorted, nonempty thermal series.
    ///
    /// `mean` is unreachable: ``ResourceTargetBinding`` refuses a plan that declares a
    /// nonordinal statistic for a categorical metric, because there is no state halfway between
    /// two states. It returns `nil` here rather than picking a neighbour.
    ///
    /// An even-count median takes the *hotter* of the two central states. That choice is stated
    /// rather than implied: the cooler one would let a run pass on a state it half reached, and
    /// a thermal limit is a ceiling.
    static func orderStatistic(
        of sorted: [ThermalState],
        _ statistic: SummaryStatistic
    ) -> ThermalState? {
        guard !sorted.isEmpty else { return nil }
        switch statistic {
        case .maximum:
            return sorted.last
        case .median:
            // `count / 2` is the middle element for an odd count and the hotter of the two
            // central elements for an even one, which is the conservative reading of a ceiling.
            return sorted[sorted.count / 2]
        case .percentile95:
            return sorted[nearestRankIndex(count: sorted.count)]
        case .mean:
            return nil
        }
    }

    /// The nearest-rank index of the 95th percentile of a series of `count` samples.
    ///
    /// `ceil(0.95 * count) - 1`, computed in integers so no decimal rounding enters a release
    /// decision. The plan declares *which* percentile and no artifact declares an interpolation
    /// rule, which is recorded as
    /// ``UnobservableResourceEvidence/percentileInterpolationNotInPlanSchema`` rather than
    /// presented as an approved method.
    static func nearestRankIndex(count: Int) -> Int {
        guard count > 1 else { return 0 }
        let rank = (95 * count + 99) / 100
        return min(max(rank - 1, 0), count - 1)
    }

    // MARK: Refusals

    /// Why a set of samples cannot back a device gate.
    ///
    /// Reports the first reason found, in the order the requirements impose it: the environment
    /// first (Requirement 13.16), then the configuration, then the version tuple (Requirement
    /// 13.20).
    private static func refusal(
        for observed: [ResourceSample],
        in binding: ResourceTargetBinding
    ) -> NonQualifyingParityEvidence {
        for sample in observed where !sample.environment.isPhysicalDeviceEvidence {
            return .notPhysicalIPhone(sample.environment)
        }
        for sample in observed where sample.configuration != binding.configuration {
            return .configurationMismatch(
                expected: binding.configuration.hardwareIdentifier,
                observed: sample.configuration.hardwareIdentifier
            )
        }
        for sample in observed
        where !binding.plan.candidateConfigurations.contains(sample.configuration) {
            return .configurationNotInPlan(
                sample.configuration.hardwareIdentifier,
                sample.configuration.osVersion
            )
        }
        if observed.contains(where: { $0.versionTuple != binding.versionTuple }) {
            return .versionTupleMismatch
        }
        if !binding.plan.candidateConfigurations.contains(binding.configuration) {
            return .configurationNotInPlan(
                binding.configuration.hardwareIdentifier,
                binding.configuration.osVersion
            )
        }
        // An empty sample set also fails qualification. It is a version-tuple refusal only in
        // the sense that nothing established one; either way it is not a pass.
        return .versionTupleMismatch
    }

    private func gap(for cell: ResourceCell, fault: ResourceSampleFault) -> ResourceMeasurementGap {
        ResourceMeasurementGap(
            fault: fault,
            owed: cell.owedReleaseInput,
            standingLimits: cell.standingMeasurementLimits
        )
    }
}

// MARK: - Limit shape

extension ValidatedLimit {
    /// Whether this limit is a thermal state rather than a numeric ceiling.
    ///
    /// Written without a `default`, so a new limit kind forces the decision.
    var isCategoricalLimit: Bool {
        switch self {
        case .numeric: false
        case .thermal: true
        }
    }
}
