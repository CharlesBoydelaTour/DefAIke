import DefAIkeDomain

// Why a resource-measurement run cannot start, what it is still owed, and what a
// within-limit reading would not establish even if every artifact arrived.
//
// The same three-vocabulary split the parity runners use, for the same reason: the actions
// that close the three are different, and a release audit that conflates them waits for the
// wrong thing.
//
//   * ``ResourceBindingError`` — *this run's inputs disagree with each other*. The plan
//     declares no measurement for a metric the bound budget requires, the plan's pass limit
//     disagrees with the budget's hard limit, the version tuple names a different plan, the
//     measurement was predeclared for a different device. A reconciliation finding: nothing
//     was measured and nothing should be.
//   * ``UnprovisionedResourceInput`` — *a release-controlled input this repository does not
//     carry*. An approved plan, the two signed budgets, the measurement workloads, the
//     sustained-thermal procedure, a physical iPhone, a Share Extension device-test host.
//     Closing one is a release-artifact, packaging, or hardware change.
//   * ``UnobservableResourceEvidence`` — *something the implementation or the schema does not
//     expose*, so a measurement either cannot be taken at all or does not establish what its
//     name suggests. Closing one is a schema or implementation change, and no amount of
//     provisioning helps.
//
// The third vocabulary carries this task's central finding. `PlatformResourceGovernor` — the
// only thing in this repository that measures anything — reads exactly three metrics:
// `peakResidentMemory` from `task_vm_info` phys_footprint, `thermalState` from `ProcessInfo`,
// and the reservation-accounted `decodedPixelCount`/`encodedInputSize`. Temporary storage,
// all three latencies, and energy impact return `.notMeasurable`, always. So five of the
// budget metrics this task is asked to measure have no measurement path in this repository at
// all, and two of the nine enumerated measurements — cancellation residual work and
// interruption cleanup — cannot even be predeclared, because
// `DeviceValidationPlan.measurements` is keyed by target and metric and has no condition or
// phase dimension to hang a cancellation or interruption measurement on.
//
// None of that is stubbed. Each is a value, each fails its cell closed, and each is reported.
//
// No vocabulary here has a case meaning "proceed anyway", "assume", "approximate", "skip", or
// "warn". A resource run either compares an approved limit against a qualifying, complete
// sample series, or it produces one of these.

// MARK: - Reconciliation findings

/// Why a plan, a budget pair, a configuration, and a version tuple cannot be bound into one
/// target's resource-measurement run.
public enum ResourceBindingError: Error, Equatable, Sendable, CustomStringConvertible {

    /// The configuration under test is not one the approved plan enumerates.
    case configurationNotInPlan(DeviceHardwareID, PlatformVersion)

    /// The budget selected for this target does not carry this target.
    ///
    /// ``ResourceBudgetSet`` already refuses this, so it is unreachable through a decoded
    /// pair. Checked again because target separation is the one behaviour this task turns on,
    /// and relying on another type's invariant for it would leave nothing here that fails
    /// when the invariant changes (Requirement 11.1).
    case budgetTargetMismatch(expected: ExecutionTarget, found: ExecutionTarget)

    /// The budget was not measured by the bound plan.
    ///
    /// Requirement 15.9 makes the plan the authoritative release source for numeric
    /// analysis-time and resource limits. A budget whose `validationPlan` names some other
    /// plan carries numbers this run has no approved derivation for.
    case budgetNotMeasuredByPlan(budget: ArtifactID, plan: ArtifactID)

    /// The version tuple names a different validation plan.
    case versionTuplePlanMismatch(expected: ArtifactID, found: ArtifactID)

    /// The version tuple names a different Model Bundle than the plan.
    case versionTupleModelBundleMismatch(expected: ModelBundleID, found: ModelBundleID)

    /// The version tuple names a different capability manifest than the plan.
    case versionTupleCapabilityManifestMismatch(expected: ArtifactID, found: ArtifactID)

    /// The configuration's application build disagrees with the version tuple's.
    case versionTupleAppBuildMismatch(expected: AppBuildID, found: AppBuildID)

    /// The plan declares no measurement for a metric this target's budget limits.
    ///
    /// Stricter than the plan schema's own coverage check in one way that matters: this one
    /// is scoped to the *bound configuration*, so a plan that declares a metric only for some
    /// other candidate iPhone is refused here rather than producing a cell with no
    /// predeclared sample count, statistic, or pass limit (Requirements 11.4, 13.12, 13.13).
    case measurementSpecificationMissing(ExecutionTarget, ResourceMetric)

    /// The plan's declared measurement for this metric was predeclared for a different
    /// device, operating-system version, or application build than the bound configuration.
    case measurementConditionsMismatch(ExecutionTarget, ResourceMetric)

    /// The bound budget defines no hard limit for a metric the target requires.
    ///
    /// ``ResourceBudget`` refuses this, and it is re-checked for the same reason
    /// ``budgetTargetMismatch`` is: a missing limit must never read as "unlimited".
    case budgetLimitMissing(ExecutionTarget, ResourceMetric)

    /// The plan's declared pass limit and the budget's hard limit for one metric disagree.
    ///
    /// Both are approved values and neither is this module's to prefer, so a disagreement is
    /// a reconciliation failure rather than a choice. Requirements 15.8 and 15.9 make the
    /// plan authoritative, which is precisely why a budget that contradicts it cannot be
    /// silently overridden: the release has published two different numbers.
    case passLimitDisagreesWithBudget(ExecutionTarget, ResourceMetric)

    /// The plan declares a nonordinal summary statistic for a categorical metric.
    ///
    /// Thermal state is `Comparable`, so median, maximum, and the 95th percentile are all
    /// well-defined order statistics over a sample series. An arithmetic mean is not: there
    /// is no state halfway between `serious` and `critical`. The plan schema permits the
    /// combination, which is a defect this module reports rather than works around.
    case thermalSummaryStatisticNotOrdinal(SummaryStatistic)

    /// The plan's missing-result rule is not "treat as failure".
    ///
    /// The plan schema already refuses this. Checked again because a runner that trusted the
    /// rule to be right without reading it would be relying on another type's invariant for
    /// the behaviour Requirement 13.19 turns on.
    case missingResultRuleNotFailure(MissingResultRule)

    /// The binding produces no required measurement at all.
    ///
    /// A run with nothing to measure is not a passing run. It has no evidence.
    case requiredCellSetEmpty

    public var description: String {
        switch self {
        case let .configurationNotInPlan(hardware, osVersion):
            return "\(hardware.rawValue)@\(osVersion.description) is not a plan candidate"
        case let .budgetTargetMismatch(expected, found):
            return "the budget carries target \(found.rawValue), not \(expected.rawValue)"
        case let .budgetNotMeasuredByPlan(budget, plan):
            return "budget \(budget.rawValue) was not measured by plan \(plan.rawValue)"
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
        case let .measurementSpecificationMissing(target, metric):
            return "the plan declares no \(target.rawValue) measurement for \(metric.rawValue)"
        case let .measurementConditionsMismatch(target, metric):
            return "the \(target.rawValue) \(metric.rawValue) measurement was predeclared for "
                + "another configuration"
        case let .budgetLimitMissing(target, metric):
            return "the \(target.rawValue) budget defines no limit for \(metric.rawValue)"
        case let .passLimitDisagreesWithBudget(target, metric):
            return "the plan's pass limit and the \(target.rawValue) budget's hard limit for "
                + "\(metric.rawValue) disagree"
        case let .thermalSummaryStatisticNotOrdinal(statistic):
            return "\(statistic.rawValue) is not an order statistic over thermal states"
        case let .missingResultRuleNotFailure(rule):
            return "the plan's missing-result rule is \(rule.rawValue)"
        case .requiredCellSetEmpty:
            return "the bound plan and budget require no measurement at all"
        }
    }
}

// MARK: - Release-controlled inputs this repository does not carry

/// One release-controlled input a resource-measurement run needs and this repository does not
/// have.
///
/// A closed, enumerable vocabulary, in the established style, with raw values disjoint from
/// every other gap vocabulary in this module so a release audit can pool them without two
/// different gaps colliding on one identifier.
///
/// Closing a gap is a release-artifact, packaging, or hardware change. It is not a change to
/// this file, and no case here is closable by writing code.
public enum UnprovisionedResourceInput: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    /// The approved Device Validation Plan's resource-measurement half does not exist.
    ///
    /// Requirement 11.4 requires every resource measurement to predeclare its device
    /// configuration, operating-system version, build, workload, cold or warm state,
    /// concurrency, starting thermal and power conditions, sample count, summary statistic,
    /// and pass limit. `DeviceValidationPlan` is a schema with no approved instance anywhere
    /// outside test samples, so not one of those values exists for any metric.
    case deviceValidationPlanResourceMeasurements =
        "device-validation-plan-resource-measurements"

    /// No signed main-application Resource Budget exists (Requirements 11.1, 11.2).
    case mainApplicationResourceBudget = "main-application-resource-budget"

    /// No signed Share Extension Resource Budget exists (Requirements 11.1, 11.3).
    ///
    /// Owed separately from the main application's, because Requirement 11.20 approves
    /// handoff viability independently and one artifact cannot answer for both.
    case shareExtensionResourceBudget = "share-extension-resource-budget"

    /// No approved main-application measurement workload exists (Requirement 13.12).
    case mainApplicationMeasurementWorkloads = "main-application-measurement-workloads"

    /// No approved Share Extension handoff workload exists (Requirement 13.13).
    case shareExtensionMeasurementWorkloads = "share-extension-measurement-workloads"

    /// No approved sustained-thermal workload, duration, or measurement method exists
    /// (Requirements 13.14, 13.15).
    case sustainedThermalWorkloadProcedure = "sustained-thermal-workload-procedure"

    /// No approved cancellation residual-work measurement procedure exists.
    ///
    /// Requirement 11.14 and Property 35 fix the behaviour; the design adds that
    /// physical-device cancellation tests measure residual work. What is missing is the
    /// predeclared procedure: which stage cancellation is injected at, what counts as
    /// residual, and the pass limit.
    case cancellationResidualWorkProcedure = "cancellation-residual-work-procedure"

    /// No approved interruption-cleanup measurement procedure exists (Requirement 11.16).
    case interruptionCleanupProcedure = "interruption-cleanup-procedure"

    /// No approved Data Lifecycle Policy cleanup deadlines exist.
    ///
    /// Requirement 11.16 measures interruption cleanup against the active policy's
    /// interrupted-session deadline, and Requirement 11.15 against its cancellation deadline.
    /// `DataLifecyclePolicy` is a schema with no approved instance, so both deadlines are
    /// undecided and this module will not supply one: an unapproved deadline is the
    /// synthesized timeout Requirements 15.8 and 15.9 forbid.
    case dataLifecycleCleanupDeadlines = "data-lifecycle-cleanup-deadlines"

    /// No release-controlled validation version tuple is bound.
    ///
    /// No release-approved `AppBuildID` exists for a run to legitimately name — the local
    /// build identity is a development placeholder — and Requirement 13.20 forbids assembling
    /// gate evidence across tuples.
    case boundResourceValidationVersionTuple = "bound-resource-validation-version-tuple"

    /// No Share Extension device-test host exists.
    ///
    /// `ios/project.yml` declares one `DefAIkeDeviceValidationTests` target, named against
    /// `DefAIkeApp`. It does not run inside the Share Extension process, and an app-adjacent
    /// test cannot observe the extension's own peak footprint, temporary storage, energy, or
    /// thermal behaviour.
    /// Requirement 11.19's separate Share Extension measurement set therefore has no
    /// execution home yet, which is a project-configuration change rather than a code one.
    case shareExtensionDeviceTestHost = "share-extension-device-test-host"

    /// No physical iPhone is available to measure on.
    ///
    /// The blocking one, and the reason every resource gate in this repository is failing
    /// rather than pending. Requirement 13.16 admits only physical-iPhone results, this
    /// repository has no device, and the only installed runtime is a simulator runtime. So
    /// every sample any run here can produce is a development-Mac or simulator sample, and
    /// ``QualifyingResourceEvidence`` refuses all of them.
    ///
    /// Nothing in this module reduces the gate to what a host can do. A host-satisfiable
    /// device gate would be a false pass, and a failing gate is the honest answer.
    case physicalIPhoneMeasurementEnvironment = "physical-iphone-measurement-environment"

    public var description: String { rawValue }
}

/// The complete set of release-controlled inputs one resource run does not have.
public struct UnprovisionedResourceRun: Error, Hashable, Sendable {
    public let inputs: [UnprovisionedResourceInput]

    public init(inputs: [UnprovisionedResourceInput]) {
        self.inputs = inputs
    }
}

// MARK: - Evidence the implementation or the schema cannot produce

/// Something a resource measurement would need that the implementation or the artifact schema
/// does not expose.
///
/// A separate vocabulary from ``UnprovisionedResourceInput`` because the two are closed by
/// different work. A missing budget arrives when a release signs one; the absence of a
/// condition dimension in `DeviceValidationPlan.measurements` does not, because there is no
/// artifact to sign — the schema would have to change first.
///
/// Nothing here is a defect this module fixes. Each is reported.
public enum UnobservableResourceEvidence: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    // MARK: Metrics with no measurement path

    /// Nothing in this repository measures temporary storage.
    ///
    /// `PlatformResourceGovernor.measuredValue(of:in:)` returns `nil` for
    /// `temporaryStorage`, so `observe` answers `.notMeasurable` and never
    /// `.withinHardLimit`. Requirements 13.12 and 13.13 require the measurement for both
    /// targets, so both targets' cells fail closed here rather than being reported as within
    /// a limit nothing was compared to.
    case temporaryStorageHasNoShippingMeasurementPath =
        "temporary-storage-has-no-shipping-measurement-path"

    /// Nothing in this repository measures cold model-load time (Requirement 13.12).
    case coldModelLoadTimeHasNoShippingMeasurementPath =
        "cold-model-load-time-has-no-shipping-measurement-path"

    /// Nothing in this repository measures warm analysis latency (Requirement 13.12).
    case warmAnalysisLatencyHasNoShippingMeasurementPath =
        "warm-analysis-latency-has-no-shipping-measurement-path"

    /// Nothing in this repository measures handoff latency (Requirement 13.13).
    case handoffLatencyHasNoShippingMeasurementPath =
        "handoff-latency-has-no-shipping-measurement-path"

    /// Nothing in this repository measures energy impact.
    ///
    /// Requirements 13.12 and 13.13 require it for both targets. iOS exposes no supported
    /// in-process energy reading, and the governor reports `.notMeasurable` rather than
    /// deriving one from elapsed time or CPU share.
    case energyImpactHasNoShippingMeasurementPath =
        "energy-impact-has-no-shipping-measurement-path"

    // MARK: Measurements the plan schema cannot predeclare

    /// The plan cannot predeclare a cancellation residual-work measurement.
    ///
    /// `DeviceValidationPlan.measurements` is keyed by target, metric, and configuration, and
    /// its required coverage is exactly the target's budget metric set. There is no
    /// condition, phase, or stage dimension, so a cancellation-condition measurement of a
    /// metric already declared for the ordinary workload cannot be expressed: the uniqueness
    /// rule refuses the second entry. `DeviceGate.cancellationResidualWork` therefore has no
    /// predeclared sample count, summary statistic, or pass limit, and its cell fails closed.
    case cancellationResidualWorkHasNoPlanSpecification =
        "cancellation-residual-work-has-no-plan-specification"

    /// The plan cannot predeclare an interruption-cleanup measurement.
    ///
    /// The same schema gap, plus a second one: Requirement 11.16 measures cleanup against the
    /// Data Lifecycle Policy's interrupted-session deadline, and `ValidatedLimit` has no case
    /// that carries a policy deadline. `DeviceGate.interruptionCleanup` therefore has no
    /// predeclared limit at all, and its cell fails closed.
    case interruptionCleanupHasNoPlanSpecification =
        "interruption-cleanup-has-no-plan-specification"

    // MARK: Predeclared measurements with no mandatory gate

    /// No `DeviceGate` case names decoded pixel count.
    ///
    /// Requirement 11.2 requires the main-application budget to limit it and Requirement 11.4
    /// requires the plan to predeclare its measurement, but Requirement 13.12's mandatory
    /// gate list is cold load, warm latency, peak resident memory, temporary storage, and
    /// energy. So the measurement is required and belongs to no gate. The cell exists and is
    /// still required to pass — this module's overall outcome requires every required cell,
    /// not only every gate — which is why a gateless cell cannot quietly stop mattering.
    case decodedPixelCountHasNoMandatoryDeviceGate =
        "decoded-pixel-count-has-no-mandatory-device-gate"

    /// No `DeviceGate` case names encoded input size (Requirements 11.3, 13.13).
    case encodedInputSizeHasNoMandatoryDeviceGate =
        "encoded-input-size-has-no-mandatory-device-gate"

    // MARK: Limits on what a reading establishes

    /// The plan schema carries no sustained-thermal duration or measurement method.
    ///
    /// Requirements 13.14 and 13.15 name "the numeric workload, duration, measurement method,
    /// and pass limits in the Device Validation Plan".
    /// `ResourceMeasurementSpecification` has a workload `EvidenceSource`, a starting thermal
    /// state, a sample count, a statistic, and a pass limit; it has no duration field and no
    /// measurement-method field. Both can only travel inside the referenced workload
    /// artifact, which this module cannot read. So a thermal pass establishes that the
    /// declared statistic over the observed states was within the declared limit — not that
    /// the approved duration was sustained.
    case sustainedThermalDurationNotInPlanSchema = "sustained-thermal-duration-not-in-plan-schema"

    /// The plan schema declares which percentile, not how to compute it.
    ///
    /// `SummaryStatistic.percentile95` names the statistic and nothing declares an
    /// interpolation rule, so two conforming runners could summarize the same samples
    /// differently. This module uses the nearest-rank definition and reports the gap rather
    /// than presenting its choice as an approved one.
    case percentileInterpolationNotInPlanSchema = "percentile-interpolation-not-in-plan-schema"

    /// Thermal samples cannot be recorded in a `MeasurementRecord`.
    ///
    /// `MeasurementRecord.rawValues` is `[Decimal]` and requires a nonempty series for any
    /// executed outcome, but a thermal sample is a `ThermalState`. Encoding states as
    /// severity ordinals would put numbers no artifact approved into a release record, so this
    /// module declines to build a `MeasurementRecord` for a categorical metric and keeps the
    /// raw states in its own report instead.
    case thermalSamplesNotRepresentableInMeasurementRecord =
        "thermal-samples-not-representable-in-measurement-record"

    /// Peak resident memory is process-wide, not session-scoped.
    ///
    /// `task_vm_info` phys_footprint is a property of the whole process. A within-limit
    /// reading therefore establishes that the process stayed inside the budget while the
    /// workload ran; it does not attribute the footprint to the Analysis Session, and it
    /// cannot separate the session's allocation from anything else the process holds.
    case peakResidentMemoryIsProcessWide = "peak-resident-memory-is-process-wide"

    /// Thermal state is device-wide, not workload-attributable.
    ///
    /// `ProcessInfo.thermalState` describes the device. A sustained-workload thermal reading
    /// therefore establishes what the device reported while the workload ran, not that the
    /// workload caused it, and Requirement 11.4's starting-thermal-state condition is what
    /// bounds the confounding rather than anything this module can measure.
    case thermalStateIsDeviceWide = "thermal-state-is-device-wide"

    /// No cancellation checkpoint exists between manifest finalize and atomic promotion, nor
    /// between joining the report and committing it.
    ///
    /// A session cancelled in either window completes and publishes. Recorded here because
    /// this task's cancellation measurement must measure what is actually true: residual work
    /// after cancellation is not bounded at those two points, so a cancellation
    /// residual-work pass would not establish that a late commit is impossible.
    ///
    /// A finding from earlier work, reported and not fixed here. The join-to-commit half was
    /// re-read while writing this: `AnalysisCoordinator` has a cancellation boundary
    /// immediately before the lane join and then runs `setStage(.evidenceJoining)`,
    /// `commitJoinedEvidence`, and `end(after:)` with no further check. The
    /// finalize-to-promotion half is in the bundle and transfer paths and was not re-read, so
    /// it is carried forward rather than re-established.
    case noCancellationCheckpointBeforePromotion = "no-cancellation-checkpoint-before-promotion"

    /// Whether this limit prevents the measurement from being taken at all.
    ///
    /// True for the five metrics with no measurement path and the two measurements the plan
    /// cannot predeclare. The rest narrow what a reading establishes without preventing it,
    /// so they are recorded beside a cell whose outcome is reached normally.
    ///
    /// Written without a `default`, so a new limit forces a decision about whether it blocks.
    public var blocksMeasurement: Bool {
        switch self {
        case .temporaryStorageHasNoShippingMeasurementPath,
             .coldModelLoadTimeHasNoShippingMeasurementPath,
             .warmAnalysisLatencyHasNoShippingMeasurementPath,
             .handoffLatencyHasNoShippingMeasurementPath,
             .energyImpactHasNoShippingMeasurementPath,
             .cancellationResidualWorkHasNoPlanSpecification,
             .interruptionCleanupHasNoPlanSpecification:
            true
        case .decodedPixelCountHasNoMandatoryDeviceGate,
             .encodedInputSizeHasNoMandatoryDeviceGate,
             .sustainedThermalDurationNotInPlanSchema,
             .percentileInterpolationNotInPlanSchema,
             .thermalSamplesNotRepresentableInMeasurementRecord,
             .peakResidentMemoryIsProcessWide,
             .thermalStateIsDeviceWide,
             .noCancellationCheckpointBeforePromotion:
            false
        }
    }

    public var description: String { rawValue }
}
