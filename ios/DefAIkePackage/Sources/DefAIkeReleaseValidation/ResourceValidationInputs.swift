import DefAIkeDomain
import Foundation

// The closed set of resource and interruption measurements a device run owes, partitioned by
// target, and where each one's limit and conditions come from.
//
// Requirements 13.12 and 13.13 name the per-target resource measurements: cold load, warm
// latency, peak resident memory, temporary storage, and energy for the main application;
// handoff latency, peak resident memory, temporary storage, and energy for the Share
// Extension. Requirements 13.14 and 13.15 add the two sustained-thermal workloads.
// Requirements 11.14 through 11.16 and 15.6 add cancellation residual work and interruption
// cleanup. `ResourceMetric` in the domain is already exactly the budget metric set, and
// `DeviceGate` already names each gate, so nothing here invents a metric or a gate.
//
// What this file adds is the layout: for a given target, *which* measurements are owed, from
// *which* predeclared specification, against *which* limit, in *which* unit, contributing to
// *which* gate. Every one of those is a total function over a closed vocabulary, written
// without a `default`, so adding a resource metric to the domain is a compile error here
// rather than a measurement that quietly stops being required.
//
// Three rules run through the whole file, and each is structural rather than documentary:
//
//   * **Every number comes from the plan.** There is no member anywhere here that computes,
//     defaults, rounds, clamps, or infers a sample count, a summary statistic, a measurement
//     condition, a workload, or a limit. ``ResourceMeasurementSpecification`` supplies all of
//     them, and a metric the bound plan does not declare for the bound configuration has no
//     cell that can pass. There is no `Duration`, no clock, and no deadline in this module:
//     Requirements 15.8 and 15.9 make the plan the authoritative source of numeric
//     analysis-time limits, and a harness that timed anything itself would be synthesizing
//     one.
//   * **A target's measurement cannot satisfy the other target's limit.** ``ResourceCell``
//     carries its ``ExecutionTarget``, ``ResourceSample`` carries the target it was taken in,
//     and the two must agree. The limit is read from the budget
//     ``ResourceBudgetSet/budget(for:)`` selects, which the set already guarantees carries the
//     matching target — the caller never chooses a budget, the same posture
//     `ResourceController.init?` takes.
//   * **A sample records where it was produced.** ``ResourceSample`` requires an
//     ``ExecutionEnvironment``, the configuration, and the version tuple, so a host sample is
//     recordable and honest. Turning one into evidence that satisfies a device gate needs
//     ``QualifyingResourceEvidence``, whose only initialiser is internal to this module and
//     refuses anything but a physical iPhone on a configuration the bound plan enumerates.

// MARK: - What is measured

/// What one required measurement is about.
///
/// Two shapes, because two of the nine enumerated measurements are not a budget metric under
/// the plan's ordinary workload. Cancellation residual work and interruption cleanup are
/// conditions imposed on a session rather than dimensions of one, and the plan's measurement
/// table has no place to declare them — see
/// ``UnobservableResourceEvidence/cancellationResidualWorkHasNoPlanSpecification``. They are
/// still cells, because Requirement 13.17 makes both mandatory gates and a requirement that
/// silently stops being checked is worse than one that fails closed.
public enum ResourceSubject: Hashable, Sendable, CustomStringConvertible {
    /// One budget metric, measured under the plan's predeclared conditions.
    case budgetMetric(ResourceMetric)

    /// Work that must not continue after a user cancellation (Requirements 11.14, 15.6).
    case cancellationResidualWork

    /// Ephemeral material that must be gone after an operating-system interruption
    /// (Requirement 11.16).
    case interruptionCleanup

    /// The budget metric this subject measures, or `nil` for the two condition subjects.
    public var metric: ResourceMetric? {
        switch self {
        case let .budgetMetric(metric): metric
        case .cancellationResidualWork, .interruptionCleanup: nil
        }
    }

    /// A stable identifier, for ordering and description.
    public var key: String {
        switch self {
        case let .budgetMetric(metric): metric.rawValue
        case .cancellationResidualWork: "cancellation-residual-work"
        case .interruptionCleanup: "interruption-cleanup"
        }
    }

    public var description: String { key }

    /// Every subject a target owes, in a stable order.
    ///
    /// The budget metric set comes from the domain rather than from a list restated here, so
    /// the harness and the budget schema cannot drift about which metrics a target measures
    /// (Requirements 11.2, 11.3).
    public static func required(for target: ExecutionTarget) -> [ResourceSubject] {
        var subjects = ResourceMetric.requiredMetrics(for: target)
            .sorted { $0.rawValue < $1.rawValue }
            .map { ResourceSubject.budgetMetric($0) }
        subjects.append(.cancellationResidualWork)
        subjects.append(.interruptionCleanup)
        return subjects
    }
}

/// One measurement a device run owes: a target and what is measured.
///
/// The unit of the closed required set, and the reason a main-application measurement cannot
/// satisfy a Share Extension limit: the target is part of the cell's identity, so the
/// `peak-resident-memory` cell of one target is a different cell from the other's and each
/// carries its own outcome.
public struct ResourceCell: Hashable, Sendable, CustomStringConvertible {
    public let target: ExecutionTarget
    public let subject: ResourceSubject

    public init(target: ExecutionTarget, subject: ResourceSubject) {
        self.target = target
        self.subject = subject
    }

    /// The budget metric this cell measures, or `nil` for a condition subject.
    public var metric: ResourceMetric? { subject.metric }

    /// A stable ordering key, so two runs over the same binding enumerate identically.
    public var orderingKey: String { "\(target.rawValue)\u{1F}\(subject.key)" }

    public var description: String { "\(target.rawValue)/\(subject.key)" }
}

// MARK: - Which gate a cell answers

/// The mandatory device gate one cell contributes to, or the finding that none names it.
///
/// Total over target and subject, written without a `default`. The second case is not a
/// placeholder: it is the finding that a measurement the requirements make mandatory belongs
/// to no `DeviceGate` case, which is a different blocker from a release artifact this
/// repository has not been given.
public enum ResourceCellGate: Hashable, Sendable, CustomStringConvertible {
    /// The gate this cell's result is recorded under.
    case gate(DeviceGate)

    /// No mandatory gate names this measurement.
    case noMandatoryGate(UnobservableResourceEvidence)

    /// The gate, or `nil` when none names the measurement.
    public var gate: DeviceGate? {
        switch self {
        case let .gate(gate): gate
        case .noMandatoryGate: nil
        }
    }

    public var description: String {
        switch self {
        case let .gate(gate): gate.rawValue
        case let .noMandatoryGate(limit): "no mandatory gate: \(limit.rawValue)"
        }
    }
}

extension ResourceCell {

    /// The mandatory device gate this cell's result is recorded under.
    ///
    /// Written as an exhaustive switch over target and metric with no `default`, so a new
    /// resource metric forces a decision about which gate it answers rather than defaulting
    /// to none. The mapping is Requirements 13.12 through 13.15 restated once: the gate names
    /// already encode the target, which is why there are separate
    /// `main-application-peak-memory` and `share-extension-peak-memory` gates rather than one
    /// gate parameterised by target.
    public var cellGate: ResourceCellGate {
        switch subject {
        case .cancellationResidualWork:
            return .gate(.cancellationResidualWork)
        case .interruptionCleanup:
            return .gate(.interruptionCleanup)
        case let .budgetMetric(metric):
            switch (target, metric) {
            case (.mainApplication, .coldModelLoadTime):
                return .gate(.coldModelLoad)
            case (.mainApplication, .warmAnalysisLatency):
                return .gate(.warmAnalysisLatency)
            case (.mainApplication, .peakResidentMemory):
                return .gate(.mainApplicationPeakMemory)
            case (.mainApplication, .temporaryStorage):
                return .gate(.mainApplicationTemporaryStorage)
            case (.mainApplication, .energyImpact):
                return .gate(.mainApplicationEnergy)
            case (.mainApplication, .thermalState):
                return .gate(.sustainedAnalysisThermal)
            case (.mainApplication, .decodedPixelCount):
                return .noMandatoryGate(.decodedPixelCountHasNoMandatoryDeviceGate)
            case (.shareExtension, .handoffLatency):
                return .gate(.handoffLatency)
            case (.shareExtension, .peakResidentMemory):
                return .gate(.shareExtensionPeakMemory)
            case (.shareExtension, .temporaryStorage):
                return .gate(.shareExtensionTemporaryStorage)
            case (.shareExtension, .energyImpact):
                return .gate(.shareExtensionEnergy)
            case (.shareExtension, .thermalState):
                return .gate(.sustainedHandoffThermal)
            case (.shareExtension, .encodedInputSize):
                return .noMandatoryGate(.encodedInputSizeHasNoMandatoryDeviceGate)
            case (.mainApplication, .encodedInputSize),
                 (.mainApplication, .handoffLatency),
                 (.shareExtension, .decodedPixelCount),
                 (.shareExtension, .coldModelLoadTime),
                 (.shareExtension, .warmAnalysisLatency):
                // Not a cell any binding produces: the required subject set comes from
                // `ResourceMetric.requiredMetrics(for:)`, which never pairs these. Answered
                // as "no mandatory gate" rather than by picking one, because a cell this
                // module cannot place is not a cell that passed.
                return .noMandatoryGate(
                    target == .mainApplication
                        ? .encodedInputSizeHasNoMandatoryDeviceGate
                        : .decodedPixelCountHasNoMandatoryDeviceGate
                )
            }
        }
    }

    /// The release-controlled input a missing measurement for this cell is owed from.
    ///
    /// Total, so a gap is always attributable to something a release has to supply rather
    /// than to "no result".
    public var owedReleaseInput: UnprovisionedResourceInput {
        switch subject {
        case .cancellationResidualWork:
            return .cancellationResidualWorkProcedure
        case .interruptionCleanup:
            return .interruptionCleanupProcedure
        case let .budgetMetric(metric):
            if metric == .thermalState { return .sustainedThermalWorkloadProcedure }
            switch target {
            case .mainApplication: return .mainApplicationMeasurementWorkloads
            case .shareExtension: return .shareExtensionMeasurementWorkloads
            }
        }
    }

    /// Standing limits that qualify what a within-limit reading for this cell establishes.
    ///
    /// Recorded whatever the outcome, because they are properties of the implementation and
    /// the artifact schema rather than of one run: they do not become true when a cell fails
    /// and false when it passes. A limit whose
    /// ``UnobservableResourceEvidence/blocksMeasurement`` is true additionally prevents the
    /// measurement from being taken at all.
    public var standingMeasurementLimits: Set<UnobservableResourceEvidence> {
        switch subject {
        case .cancellationResidualWork:
            // Two findings, not one. The specification is missing, *and* a cancellation
            // residual-work pass would not establish that a late commit is impossible: there
            // is no cancellation checkpoint between manifest finalize and atomic promotion,
            // nor between joining the report and committing it.
            return [
                .cancellationResidualWorkHasNoPlanSpecification,
                .noCancellationCheckpointBeforePromotion,
            ]
        case .interruptionCleanup:
            return [.interruptionCleanupHasNoPlanSpecification]
        case let .budgetMetric(metric):
            switch metric {
            case .temporaryStorage:
                return [.temporaryStorageHasNoShippingMeasurementPath]
            case .coldModelLoadTime:
                return [.coldModelLoadTimeHasNoShippingMeasurementPath]
            case .warmAnalysisLatency:
                return [.warmAnalysisLatencyHasNoShippingMeasurementPath]
            case .handoffLatency:
                return [.handoffLatencyHasNoShippingMeasurementPath]
            case .energyImpact:
                return [.energyImpactHasNoShippingMeasurementPath]
            case .peakResidentMemory:
                return [.peakResidentMemoryIsProcessWide]
            case .thermalState:
                return [
                    .thermalStateIsDeviceWide,
                    .sustainedThermalDurationNotInPlanSchema,
                    .thermalSamplesNotRepresentableInMeasurementRecord,
                ]
            case .decodedPixelCount:
                return [.decodedPixelCountHasNoMandatoryDeviceGate]
            case .encodedInputSize:
                return [.encodedInputSizeHasNoMandatoryDeviceGate]
            }
        }
    }
}

extension DeviceGate {
    /// The resource, thermal, cancellation, and interruption gates this task measures, in
    /// declaration order.
    ///
    /// Derived from ``ResourceCell/cellGate`` over the required subject sets rather than
    /// restated, so the two cannot drift.
    public static var resourceGates: [DeviceGate] {
        var gates: Set<DeviceGate> = []
        for target in ExecutionTarget.allCases {
            for subject in ResourceSubject.required(for: target) {
                if let gate = ResourceCell(target: target, subject: subject).cellGate.gate {
                    gates.insert(gate)
                }
            }
        }
        return DeviceGate.allCases.filter { gates.contains($0) }
    }

    /// Whether this gate is measured separately for each target.
    ///
    /// True for the eleven per-target resource and thermal gates. False for cancellation
    /// residual work and interruption cleanup, whose single gate covers both targets even
    /// though Requirement 11.19 still requires the two targets' raw values and pass results to
    /// be recorded apart — which is why a gate result for those two is computed from each
    /// target's cells separately and only then combined.
    public var isPerTargetResourceGate: Bool { measurementTarget != nil }
}

// MARK: - Samples

/// The kind of value one sample carries.
///
/// Two cases, mirroring ``ValidatedLimit``: a quantity in a declared unit, or a thermal state.
/// The mirror is deliberate, so a sample cannot arrive in a shape no approved limit could have
/// been written in, and a byte count cannot be handed in where a thermal state was owed.
public enum ObservedResourceValueKind: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    case quantity
    case thermalState = "thermal-state"

    public var description: String { rawValue }
}

/// One observed resource value.
///
/// Carries no limit, no tolerance, and no outcome. A run supplies what it measured; what that
/// means is the comparison's answer, and the comparison reads its limit from the approved
/// plan.
public enum ObservedResourceValue: Hashable, Sendable, CustomStringConvertible {
    /// A measured magnitude and the unit it was measured in.
    ///
    /// The unit travels with the value because a limit in bytes cannot bound a reading stated
    /// in milliseconds, and comparing magnitudes across units is the substitution
    /// Requirement 11.2's unit-carrying limits exist to prevent.
    case quantity(Decimal, unit: ResourceLimitUnit)

    /// A measured thermal state.
    case thermalState(ThermalState)

    public var kind: ObservedResourceValueKind {
        switch self {
        case .quantity: .quantity
        case .thermalState: .thermalState
        }
    }

    /// The measured magnitude, for a quantity sample.
    public var magnitude: Decimal? {
        switch self {
        case let .quantity(value, _): value
        case .thermalState: nil
        }
    }

    /// The unit, for a quantity sample.
    public var unit: ResourceLimitUnit? {
        switch self {
        case let .quantity(_, unit): unit
        case .thermalState: nil
        }
    }

    /// The measured state, for a thermal sample.
    public var state: ThermalState? {
        switch self {
        case .quantity: nil
        case let .thermalState(state): state
        }
    }

    public var description: String {
        switch self {
        case let .quantity(value, unit): "\(value) \(unit.rawValue)"
        case let .thermalState(state): state.rawValue
        }
    }
}

/// One sample's ordinal position within the plan's declared sample count.
///
/// Constructible only inside this module. That is what makes the sample count the plan's
/// rather than the reader's: the run enumerates `0..<sampleCount` from the approved
/// specification and asks for each position by name, so a store holding fewer samples cannot
/// shrink the series — it reports a fault for the positions it does not have, and those
/// positions stay in the denominator.
public struct ResourceSampleIndex: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The zero-based position, strictly below the plan's declared sample count.
    public let ordinal: Int

    init(ordinal: Int) {
        self.ordinal = ordinal
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.ordinal < rhs.ordinal }

    public var description: String { "#\(ordinal)" }
}

/// One sample, and the exact conditions it was taken under.
///
/// Public and permissive on purpose. A development-Mac or simulator sample is a real thing a
/// run produces, and recording it honestly is better than refusing to represent it —
/// Requirement 13.16 asks for M3 Pro timing to be *classified* as development evidence, not
/// discarded. What no caller can do is turn one into a satisfied gate: that needs
/// ``QualifyingResourceEvidence``, and its initialiser is internal to this module.
public struct ResourceSample: Hashable, Sendable {
    /// The cell this sample answers.
    public let cell: ResourceCell

    /// Its position in the declared series.
    public let index: ResourceSampleIndex

    /// What was measured.
    public let value: ObservedResourceValue

    /// The process the sample was taken in.
    ///
    /// Distinct from ``cell``'s target, and compared against it. A sample taken in the main
    /// application cannot answer a Share Extension cell however it is filed, which is the
    /// structural half of Requirement 11.19's separate measurement sets.
    public let target: ExecutionTarget

    /// Where the sample was produced.
    public let environment: ExecutionEnvironment

    /// The configuration it was produced on.
    public let configuration: CandidateDeviceConfiguration

    /// The exact version tuple the run used (Requirements 13.17 and 13.20).
    public let versionTuple: ValidationVersionTuple

    public init(
        cell: ResourceCell,
        index: ResourceSampleIndex,
        value: ObservedResourceValue,
        target: ExecutionTarget,
        environment: ExecutionEnvironment,
        configuration: CandidateDeviceConfiguration,
        versionTuple: ValidationVersionTuple
    ) {
        self.cell = cell
        self.index = index
        self.value = value
        self.target = target
        self.environment = environment
        self.configuration = configuration
        self.versionTuple = versionTuple
    }
}

/// Proof that the samples behind one measurement may back a physical-device gate.
///
/// The whole of Requirement 13.16 in one type, for resources. There is exactly one way to
/// obtain a value: ``init(samples:plan:target:configuration:versionTuple:)``, which is
/// internal to this module and returns `nil` unless every contributing sample was taken
///
///   1. in ``ExecutionEnvironment/physicalIPhone``,
///   2. in the process the cell's target names,
///   3. on the configuration the run is bound to,
///   4. on a configuration the approved plan enumerates as a candidate, and
///   5. under the exact version tuple the run is bound to (Requirement 13.20).
///
/// ``ResourceMeasurementAgreement`` can only be built from one of these, and
/// ``ResourceCellOutcome/withinLimit`` can only be built from a
/// ``ResourceMeasurementAgreement``. So a satisfied resource cell is not "a cell that read
/// inside its limit and happened to be on a phone": it is a value the type system will not
/// let a host or simulator sample produce. A caller outside this module has no initialiser at
/// all, which is why no test in this repository can manufacture one.
public struct QualifyingResourceEvidence: Hashable, Sendable {
    /// The target every contributing sample was taken in.
    public let target: ExecutionTarget

    /// The configuration every contributing sample was taken on.
    public let configuration: CandidateDeviceConfiguration

    /// The version tuple every contributing sample ran under.
    public let versionTuple: ValidationVersionTuple

    /// Always ``ExecutionEnvironment/physicalIPhone``. Retained so a recorded measurement
    /// states its environment rather than leaving it implied.
    public var environment: ExecutionEnvironment { .physicalIPhone }

    /// The number of samples this proof covers. Never zero.
    public let sampleCount: Int

    init?(
        samples: [ResourceSample],
        plan: DeviceValidationPlan,
        target: ExecutionTarget,
        configuration: CandidateDeviceConfiguration,
        versionTuple: ValidationVersionTuple
    ) {
        guard !samples.isEmpty else { return nil }
        guard plan.candidateConfigurations.contains(configuration) else { return nil }
        for sample in samples {
            guard sample.environment.isPhysicalDeviceEvidence,
                sample.target == target,
                sample.cell.target == target,
                sample.configuration == configuration,
                sample.versionTuple == versionTuple
            else {
                return nil
            }
        }
        self.target = target
        self.configuration = configuration
        self.versionTuple = versionTuple
        self.sampleCount = samples.count
    }
}

// MARK: - Summary statistics

extension SummaryStatistic {
    /// Whether this statistic is an order statistic, and so defined over a `Comparable` value
    /// that is not a number.
    ///
    /// Median, maximum, and the 95th percentile are positions in a sorted series and are
    /// therefore defined over thermal states. An arithmetic mean is not: there is no state
    /// halfway between `serious` and `critical`. The plan schema permits `mean` for a
    /// categorical metric, which ``ResourceBindingError/thermalSummaryStatisticNotOrdinal(_:)``
    /// refuses and this module reports as a schema defect.
    ///
    /// Written without a `default`, so a new statistic forces the decision.
    public var isOrderStatistic: Bool {
        switch self {
        case .median, .maximum, .percentile95: true
        case .mean: false
        }
    }
}
