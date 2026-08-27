import DefAIkeDomain
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeReleaseValidation

// The three claims task 14.3 turns on, as one property over generated sample sets.
//
// Stated as the requirements state them:
//
//   * Requirement 13.19 — *a missing mandatory result is a failure.* For any sample set at all,
//     every measurement the bound plan and budgets require has exactly one recorded outcome, that
//     outcome is `passed` or `failed` and never `notExecuted`, and a measurement whose samples did
//     not come back is not satisfied. The report also keeps the plan's declared sample count in the
//     denominator of the measured completeness, at both the cell and the gate level, so a run
//     cannot raise its own ratio by taking fewer samples.
//   * Requirement 11.19 — *the two targets' measurement sets are separate.* For any sample set at
//     all, a main-application measurement never satisfies a Share Extension gate and the reverse,
//     each target's report carries only its own cells, and a sample taken in the other target's
//     process is refused before any comparison.
//   * Requirement 13.16 — *a physical-iPhone gate is not satisfiable by host or simulator
//     evidence.* For any sample set at all, including one in which every measurable cell reads
//     inside its approved limit, every resource gate this process records is `failed`, and the
//     recorded refusal names the environment the process is actually running in.
//
// The third is the interesting one, because the property has to hold *even in the case that looks
// like a pass*. One generated arm deliberately supplies a complete, within-limit sample set whose
// samples all claim `physicalIPhone`. The measurable cells pass, and the gates still fail. That
// contradiction is the design: a sample's environment is a claim its producer makes, and
// `ObservedParityEnvironment.current` is compiled from the platform, so this process cannot claim
// to be a phone whatever it is handed.
//
// Nothing here is release evidence. Every plan, budget, limit, sample count, statistic, condition,
// configuration, and version tuple below is synthetic, no physical device ran, nothing was measured
// on one, and five of the budget metrics could not have been measured anywhere in this repository.
//
// ## Why no arm throws
//
// `propertyCheck` runs its body under `try?`, so an error escaping the body reports a passing run
// in milliseconds with every arm skipped. Nothing below rethrows: every throwing sample builder and
// binding call is wrapped into a value or reported through `Issue.record`, and ``ResourceGateWitness``
// counts the cases and every arm *outside* the body, where an issue is not suppressed. Arm counters
// are compared against the case count rather than against a floor, and
// ``ResourceGateWitness/recordCompletedBody()`` is the last thing the body does, so a case that
// stopped early is countable.

extension Tag {
    /// Task 14.3's three carrying claims.
    @Tag static var resourceGateUnsatisfiable: Self
}

@Suite(
    "Resource gates are unsatisfiable without a physical iPhone",
    .tags(.resourceGateUnsatisfiable)
)
struct ResourceGateUnsatisfiablePropertyTests {

    /// **Validates: Requirements 11.19, 11.20, 13.12, 13.13, 13.14, 13.15, 13.16, 13.17, 13.19,
    /// 15.8, 15.9**
    @Test("No sample set makes a host-run resource gate pass, and no missing sample passes")
    func noSampleSetSatisfiesAHostRunGate() async {
        let witness = ResourceGateWitness()

        await propertyCheck(count: 216, input: ResourceRunShape.generator) { shape in
            witness.record(shape)
            guard let scenario = ResourceRunScenario(shape: shape) else {
                witness.recordUnbuildableInput()
                return
            }
            scenario.checkEveryRequiredCellHasExactlyOneOutcome(witness)
            scenario.checkNoOutcomeIsNotExecuted(witness)
            scenario.checkThePerturbedCellProducedTheExpectedRefusal(witness)
            scenario.checkMissingSamplesStayInTheDenominator(witness)
            scenario.checkEveryGateFailsInThisProcess(witness)
            scenario.checkNeitherTargetSatisfiesTheOthersGates(witness)
            scenario.checkAnUnrequestedCellIsAlsoAFailure(witness)
            witness.recordCompletedBody()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - What one case varies

/// How one generated case perturbs the sample set of one measurement.
///
/// Nine arms, one per way a sample series can fail to become evidence plus the control arm that
/// perturbs nothing. `none` is not filler: it is the arm in which every measurable cell reads
/// inside its limit, and it is the one that proves the gate refusal is about the process rather
/// than about a measurement that fell short.
private enum ResourcePerturbation: String, Hashable, Sendable, CaseIterable {
    /// Every declared position holds a within-limit value.
    case none

    /// The whole series is absent.
    case removeSeries = "remove-series"

    /// One declared position of the series is absent.
    case removeOneSample = "remove-one-sample"

    /// Every position exists and none can be read.
    case allUnreadable = "all-unreadable"

    /// The metric cannot be measured in the environment the run executed in.
    case notMeasurable = "not-measurable"

    /// The series was taken somewhere that cannot supply release evidence.
    case foreignEnvironment = "foreign-environment"

    /// The series was taken on a different configuration.
    case foreignConfiguration = "foreign-configuration"

    /// The series was taken under a different version tuple.
    case foreignVersionTuple = "foreign-version-tuple"

    /// The series was taken in the other target's process.
    case crossTarget = "cross-target"

    /// Whether this arm leaves the perturbed cell unsatisfied.
    var refusesTheCell: Bool { self != .none }
}

/// One generated case.
private struct ResourceRunShape: CustomStringConvertible, Sendable {
    let seed: Int
    let targetIndex: Int
    let perturbationIndex: Int
    let metricIndex: Int
    let removedOrdinalIndex: Int
    let foreignEnvironmentIndex: Int
    let sampleCountIndex: Int
    let statisticIndex: Int
    let probeIndex: Int

    /// The declared sample counts a case draws from.
    ///
    /// All at least two, so the `removeOneSample` arm always leaves a nonempty but short series
    /// rather than collapsing into the absent-series arm and making the two indistinguishable.
    static let sampleCounts = [2, 3, 5, 7]

    /// The numeric statistics a case draws from. All four, including `mean`, which is legitimate
    /// over magnitudes and refused only over thermal states.
    static let numericStatistics: [SummaryStatistic] = [
        .median, .mean, .maximum, .percentile95,
    ]

    var target: ExecutionTarget {
        ExecutionTarget.allCases[targetIndex % ExecutionTarget.allCases.count]
    }

    var otherTarget: ExecutionTarget {
        target == .mainApplication ? .shareExtension : .mainApplication
    }

    var perturbation: ResourcePerturbation {
        ResourcePerturbation.allCases[perturbationIndex % ResourcePerturbation.allCases.count]
    }

    var declaredSampleCount: Int {
        Self.sampleCounts[sampleCountIndex % Self.sampleCounts.count]
    }

    var numericStatistic: SummaryStatistic {
        Self.numericStatistics[statisticIndex % Self.numericStatistics.count]
    }

    /// The position `removeOneSample` removes: first, one in the middle, or last.
    func removedOrdinal(of declared: Int) -> Int {
        switch removedOrdinalIndex % 3 {
        case 0: 0
        case 1: declared / 2
        default: declared - 1
        }
    }

    /// The environment a `foreignEnvironment` arm claims. Never `physicalIPhone`.
    var foreignEnvironment: ExecutionEnvironment {
        foreignEnvironmentIndex % 2 == 0 ? .developmentMac : .iOSSimulator
    }

    var description: String {
        """
        seed \(seed), \(target.rawValue) perturbed by \(perturbation.rawValue), \
        \(declaredSampleCount) declared samples summarized by \(numericStatistic.rawValue), \
        foreign environment \(foreignEnvironment.rawValue)
        """
    }

    // MARK: Generator

    static var generator: Generator<ResourceRunShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            index,
            index,
            index,
            index,
            index,
            index,
            index,
            index
        )
        .map { raw in
            ResourceRunShape(
                seed: raw.0,
                targetIndex: raw.1,
                perturbationIndex: raw.2,
                metricIndex: raw.3,
                removedOrdinalIndex: raw.4,
                foreignEnvironmentIndex: raw.5,
                sampleCountIndex: raw.6,
                statisticIndex: raw.7,
                probeIndex: raw.8
            )
        }
        .eraseToAny()
    }

    /// A selector index.
    ///
    /// The range is a multiple of every modulus it is reduced by — 2 for the target and the foreign
    /// environment, 3 for the removed ordinal and the readable-metric table, 4 for the sample count
    /// and the statistic, 9 for the perturbation, and 9 for the probe metric — because 720 is
    /// 36 × 20 and 36 is their least common multiple. So each table entry is drawn with equal
    /// probability rather than with a modulus bias.
    private static var index: Generator<Int, AnySequence<Any>> {
        Gen.int(in: 0...719).eraseToAny()
    }
}

// MARK: - One case

/// One generated resource run: a bound plan and budget pair, a perturbed sample store, and the
/// report the runner produced from them.
///
/// Built once per case and never rebuilt inside an arm, so every arm reasons about the same run.
/// Construction returns `nil` rather than throwing, because a throw inside the property body is
/// discarded and would report a vacuous pass.
private struct ResourceRunScenario {
    let shape: ResourceRunShape
    let binding: ResourceValidationRunBinding
    let report: ResourceValidationReport

    /// The cell this case perturbed, or `nil` on the control arm.
    let perturbedCell: ResourceCell?

    /// Every cell of the chosen target whose measurement the runner reads at all.
    let readableCells: [ResourceCell]

    init?(shape: ResourceRunShape) {
        self.shape = shape
        guard
            let count = try? PositiveCount(validating: shape.declaredSampleCount),
            let plan = try? Sample.resourcePlan(
                sampleCount: count,
                numericStatistic: shape.numericStatistic
            ),
            let budgets = try? Sample.resourceBudgets(),
            let configuration = try? Sample.candidateConfiguration(),
            let versionTuple = try? Sample.resourceVersionTuple(),
            let binding = try? ResourceValidationRunBinding(
                plan: plan,
                budgets: budgets,
                configuration: configuration,
                versionTuple: versionTuple
            ),
            let foreignConfiguration = try? Sample.candidateConfiguration(
                hardware: DeviceHardwareID("iPhone98.\(1 + shape.seed % 8)")
            ),
            let foreignVersionTuple = try? Sample.resourceVersionTuple(provenanceEnabled: true)
        else {
            return nil
        }
        self.binding = binding

        let scoped = binding.binding(for: shape.target)
        let readable = Sample.readableCells(of: scoped)
        guard !readable.isEmpty else { return nil }
        self.readableCells = readable

        var store = FakeResourceSampleStore.complete(for: binding)
        // Every sample claims a physical iPhone, so the control arm really is the case that looks
        // like a pass. The gate refusal must not depend on the claim being false.
        store.defaultEnvironment = .physicalIPhone

        let chosen = readable[shape.metricIndex % readable.count]
        let declared = scoped.declaredSampleCount(for: chosen)
        switch shape.perturbation {
        case .none:
            self.perturbedCell = nil
        case .removeSeries:
            store.removeSeries(chosen)
            self.perturbedCell = chosen
        case .removeOneSample:
            store.removeSample(chosen, at: shape.removedOrdinal(of: declared))
            self.perturbedCell = chosen
        case .allUnreadable:
            for ordinal in 0..<declared { store.makeUnreadable(chosen, at: ordinal) }
            self.perturbedCell = chosen
        case .notMeasurable:
            store.makeNotMeasurable(chosen)
            self.perturbedCell = chosen
        case .foreignEnvironment:
            store.setEnvironment(shape.foreignEnvironment, for: chosen)
            self.perturbedCell = chosen
        case .foreignConfiguration:
            store.setConfiguration(foreignConfiguration, for: chosen)
            self.perturbedCell = chosen
        case .foreignVersionTuple:
            store.setVersionTuple(foreignVersionTuple, for: chosen)
            self.perturbedCell = chosen
        case .crossTarget:
            store.setTarget(shape.otherTarget, for: chosen)
            self.perturbedCell = chosen
        }
        self.report = ResourceMeasurementRunner(samples: store).run(binding)
    }

    /// The report for the target this case perturbed.
    var scopedReport: ResourceTargetReport { report.report(for: shape.target) }

    // MARK: Arms

    /// Requirement 13.19, first half: the mapping is total and nothing is absent.
    func checkEveryRequiredCellHasExactlyOneOutcome(_ witness: ResourceGateWitness) {
        witness.recordTotalityCheck()
        var examined = 0
        for target in ExecutionTarget.allCases {
            let scoped = report.report(for: target)
            guard scoped.requiredCells == binding.binding(for: target).requiredCells else {
                Issue.record("the report's required set is not the binding's")
                return
            }
            var satisfied = 0
            var unsatisfied = 0
            for cell in scoped.requiredCells {
                // Non-optional by type. What is checked here is that the answer is a real one:
                // every cell is either satisfied or not, and the two projections partition the
                // required set with nothing left over.
                if scoped.outcome(of: cell).isSatisfied { satisfied += 1 } else { unsatisfied += 1 }
            }
            guard satisfied + unsatisfied == scoped.requiredCells.count,
                scoped.satisfiedCells.count == satisfied,
                scoped.unsatisfiedCells.count == unsatisfied
            else {
                Issue.record("the recorded outcomes do not partition the required set")
                return
            }
            // Every cell whose measurement has no path in this repository reports that, whatever
            // this case perturbed.
            for cell in Sample.blockedCells(of: binding.binding(for: target)) {
                guard case let .measurementUnavailable(limit) = scoped.outcome(of: cell),
                    limit.blocksMeasurement
                else {
                    Issue.record("a blocked cell did not report a blocking finding")
                    return
                }
            }
            examined += scoped.requiredCells.count
        }
        witness.recordPartitionedRequiredSet(count: examined)
    }

    /// Requirement 13.19, second half: `notExecuted` is unreachable for a cell.
    func checkNoOutcomeIsNotExecuted(_ witness: ResourceGateWitness) {
        witness.recordNotExecutedCheck()
        for target in ExecutionTarget.allCases {
            let scoped = report.report(for: target)
            for cell in scoped.requiredCells where scoped.outcome(of: cell).outcome == .notExecuted {
                Issue.record("a required cell recorded notExecuted")
                return
            }
        }
        witness.recordNoNotExecutedOutcome()
    }

    /// Each perturbation arm produced the refusal it describes, and the control arm produced none.
    func checkThePerturbedCellProducedTheExpectedRefusal(_ witness: ResourceGateWitness) {
        witness.recordRefusalCheck()
        if let cell = perturbedCell {
            let outcome = scopedReport.outcome(of: cell)
            guard !outcome.isSatisfied else {
                Issue.record("a perturbed cell was satisfied")
                return
            }
            guard Self.matches(outcome, shape.perturbation) else {
                Issue.record("a perturbed cell produced an unexpected outcome shape")
                return
            }
            // Every other readable cell of the same target is unaffected, so the refusal is per
            // measurement rather than per run.
            let others = readableCells.filter { $0 != cell }
            guard others.allSatisfy({ scopedReport.outcome(of: $0).isSatisfied }) else {
                Issue.record("a perturbation refused a measurement it did not touch")
                return
            }
        } else {
            // The control arm: every measurement that can be taken was taken and read inside its
            // approved limit. Nothing else in the required set is satisfiable at all, because five
            // budget metrics have no measurement path and the two condition measurements cannot be
            // predeclared.
            guard readableCells.allSatisfy({ scopedReport.outcome(of: $0).isSatisfied }) else {
                Issue.record("the control arm left a measurable cell unsatisfied")
                return
            }
            let stragglers = scopedReport.unsatisfiedCells.filter { readableCells.contains($0) }
            guard stragglers.isEmpty else {
                Issue.record("the control arm left a measurable cell unsatisfied")
                return
            }
            witness.recordFullyMeasuredRun(cells: readableCells.count)
        }
        witness.recordProducedRefusal(shape.perturbation.rawValue)
    }

    /// Whether one outcome is the shape a perturbation describes.
    static func matches(_ outcome: ResourceCellOutcome, _ perturbation: ResourcePerturbation)
        -> Bool
    {
        switch (outcome, perturbation) {
        case let (.measurementMissing(gap), .removeSeries):
            return gap.fault == .sampleAbsent
        case (.sampleCountIncomplete, .removeOneSample):
            return true
        case let (.measurementMissing(gap), .allUnreadable):
            return gap.fault == .sampleUnreadable
        case let (.measurementMissing(gap), .notMeasurable):
            return gap.fault == .metricNotMeasurableInEnvironment
        case let (.nonQualifyingEvidence(reason), .foreignEnvironment):
            if case .notPhysicalIPhone = reason { return true }
            return false
        case let (.nonQualifyingEvidence(reason), .foreignConfiguration):
            if case .configurationMismatch = reason { return true }
            return false
        case (.nonQualifyingEvidence(.versionTupleMismatch), .foreignVersionTuple):
            return true
        case (.crossTargetSample, .crossTarget):
            return true
        default:
            return false
        }
    }

    /// Requirement 13.19: a missing sample lowers the recorded completeness at both levels.
    func checkMissingSamplesStayInTheDenominator(_ witness: ResourceGateWitness) {
        witness.recordDenominatorCheck()
        let scoped = scopedReport
        let scopedBinding = binding.binding(for: shape.target)
        var declaredTotal = 0
        for cell in readableCells {
            let summary = scoped.record(of: cell).summary
            let declared = scopedBinding.declaredSampleCount(for: cell)
            guard declared == shape.declaredSampleCount else {
                Issue.record("the declared sample count is not the plan's")
                return
            }
            // The denominator is the plan's, always, whatever came back.
            guard summary.declaredSampleCount == declared else {
                Issue.record("a summary's denominator is not the plan's declared count")
                return
            }
            guard summary.qualifyingSampleCount <= declared else {
                Issue.record("more samples qualified than the plan declared")
                return
            }
            declaredTotal += declared
        }
        guard declaredTotal > 0 else {
            Issue.record("the readable cells declare no samples at all")
            return
        }
        if let cell = perturbedCell {
            let summary = scoped.record(of: cell).summary
            let gate = cell.cellGate.gate
            switch shape.perturbation {
            case .removeSeries, .allUnreadable, .notMeasurable:
                guard summary.qualifyingSampleCount == 0, summary.completeness == .zero else {
                    Issue.record("an absent series did not read as zero of the declared count")
                    return
                }
                guard summary.declaredSampleCount > 0 else {
                    Issue.record("an absent series lost the plan's declared count")
                    return
                }
                if let gate {
                    guard scoped.gateResult(for: gate).measuredCompleteness == .zero else {
                        Issue.record("an absent series did not lower its gate's completeness")
                        return
                    }
                }
            case .removeOneSample:
                guard summary.qualifyingSampleCount == summary.declaredSampleCount - 1,
                    summary.completeness < .one,
                    !summary.isComplete
                else {
                    Issue.record("a short series did not lower the recorded completeness")
                    return
                }
            case .none, .foreignEnvironment, .foreignConfiguration, .foreignVersionTuple,
                 .crossTarget:
                // The samples came back whole; what fails is their admissibility, not the count.
                guard summary.isComplete, summary.completeness == .one else {
                    Issue.record("a whole series did not read as complete")
                    return
                }
            }
        }
        witness.recordDenominatorHeld(declaredSamples: declaredTotal)
    }

    /// Requirement 13.16: this process satisfies no resource gate.
    func checkEveryGateFailsInThisProcess(_ witness: ResourceGateWitness) {
        witness.recordGateCheck()
        guard let refusal = report.processRefusal else {
            Issue.record("a host process must record a refusal")
            return
        }
        guard refusal == .notPhysicalIPhone(ObservedParityEnvironment.current) else {
            Issue.record("the recorded refusal does not name this process's environment")
            return
        }
        var refused = 0
        for gate in DeviceGate.resourceGates {
            for result in report.perTargetGateResults(for: gate) {
                guard result.processRefusal == refusal else {
                    Issue.record("a gate result does not carry the process refusal")
                    return
                }
                // No resource gate is provenance conditional, so `notExecuted` is unreachable and
                // every result is an applicable failure.
                guard result.applicability == .applicable, result.outcome == .failed else {
                    Issue.record("a resource gate passed in a host process")
                    return
                }
                refused += 1
            }
            guard report.outcome(of: gate) == .failed else {
                Issue.record("a combined resource gate passed in a host process")
                return
            }
        }
        guard report.outcome == .failed,
            report.mainApplication.outcome == .failed,
            report.shareExtension.outcome == .failed
        else {
            Issue.record("a host run reported an overall resource pass")
            return
        }
        guard report.owedInputs.contains(.physicalIPhoneMeasurementEnvironment) else {
            Issue.record("a host run does not report that it owes a physical iPhone")
            return
        }
        witness.recordGateRefusal(gateResults: refused)
    }

    /// Requirements 11.19 and 11.20: neither target's measurements answer the other's gates.
    func checkNeitherTargetSatisfiesTheOthersGates(_ witness: ResourceGateWitness) {
        witness.recordSeparationCheck()
        var crossed = 0
        for gate in DeviceGate.resourceGates where gate.measurementTarget != nil {
            guard let owner = gate.measurementTarget else { continue }
            let foreign = owner == .mainApplication ? ExecutionTarget.shareExtension : .mainApplication
            let foreignResult = report.report(for: foreign).gateResult(for: gate)
            guard foreignResult.cells.isEmpty else {
                Issue.record("a gate drew cells from the wrong target")
                return
            }
            guard foreignResult.outcome == .failed else {
                Issue.record("a target satisfied the other target's gate")
                return
            }
            guard foreignResult.measuredCompleteness == .zero else {
                Issue.record("a target reported completeness for the other target's gate")
                return
            }
            let ownResult = report.report(for: owner).gateResult(for: gate)
            guard !ownResult.cells.isEmpty,
                ownResult.cells.allSatisfy({ $0.target == owner })
            else {
                Issue.record("a gate's own cells do not belong to its target")
                return
            }
            crossed += 1
        }
        // And a cell of one target is a failure in the other target's report, never a nil.
        for target in ExecutionTarget.allCases {
            let foreign = target == .mainApplication ? ExecutionTarget.shareExtension : .mainApplication
            let scoped = report.report(for: target)
            for cell in binding.binding(for: foreign).requiredCells {
                guard case .crossTargetSample = scoped.outcome(of: cell) else {
                    Issue.record("a foreign-target cell was not refused as cross-target")
                    return
                }
            }
        }
        witness.recordSeparationHeld(gates: crossed)
    }

    /// A cell the binding never required is a failure too, not a `nil`.
    func checkAnUnrequestedCellIsAlsoAFailure(_ witness: ResourceGateWitness) {
        witness.recordProbeCheck()
        let metric = ResourceMetric.allCases[shape.probeIndex % ResourceMetric.allCases.count]
        let scoped = scopedReport
        let probe = ResourceCell(target: shape.target, subject: .budgetMetric(metric))
        guard !scoped.requiredCells.contains(probe) else {
            // The metric belongs to this target, so it is a required cell and this arm has nothing
            // to probe. Checked against the other target's version instead, which is never required
            // here.
            let foreign = ResourceCell(target: shape.otherTarget, subject: .budgetMetric(metric))
            guard case .crossTargetSample = scoped.outcome(of: foreign) else {
                Issue.record("a foreign-target probe must be refused")
                return
            }
            witness.recordProbeRefusal()
            return
        }
        let outcome = scoped.outcome(of: probe)
        guard !outcome.isSatisfied, outcome.outcome == .failed else {
            Issue.record("an unrequested cell must be a failure")
            return
        }
        guard case let .measurementMissing(gap) = outcome,
            gap.owed == probe.owedReleaseInput
        else {
            Issue.record("an unrequested cell must report what it is owed")
            return
        }
        witness.recordProbeRefusal()
    }
}

// MARK: - The variation witness

/// Counts what the run generated and what it produced, outside the property body.
///
/// `propertyCheck` runs its body under `try?`, so a body that failed before its first assertion
/// reports a passing test in milliseconds with every arm skipped. Two habits close that gap, and
/// both matter:
///
///   * every arm counter is compared against the **case count** rather than against a floor, so a
///     run in which an arm stopped being reached fails even when the absolute number still looks
///     large; and
///   * ``recordCompletedBody()`` is the last thing the body does, so a case that ended early is
///     countable. `completedBodies == cases` alone would pass vacuously as `0 == 0`, which is why
///     the case floor sits beside it.
///
/// The produced sets are the substantive half. Every perturbation arm must actually have produced
/// its refusal, at least one case must actually have supplied a complete within-limit sample set —
/// the arm that proves the gate refusal is about the process rather than about a measurement that
/// fell short — and the counted cell, sample, and gate work must have a floor, so a run over a
/// required set that quietly shrank to a handful of cells fails here.
final class ResourceGateWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Arm counters.
    private var cases = 0
    private var completedBodies = 0
    private var unbuildableInputs = 0
    private var totalityChecks = 0
    private var partitionedRequiredSets = 0
    private var notExecutedChecks = 0
    private var noNotExecutedOutcomes = 0
    private var refusalChecks = 0
    private var producedRefusals = 0
    private var denominatorChecks = 0
    private var denominatorsHeld = 0
    private var gateChecks = 0
    private var gateRefusals = 0
    private var separationChecks = 0
    private var separationsHeld = 0
    private var probeChecks = 0
    private var probeRefusals = 0

    // Counted work.
    private var examinedCells = 0
    private var declaredSamples = 0
    private var refusedGateResults = 0
    private var separatedGates = 0
    private var fullyMeasuredRuns = 0
    private var fullyMeasuredCells = 0

    // Produced outcomes.
    private var refusalKinds: Set<String> = []

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var perturbations: Set<String> = []
    private var targets: Set<String> = []
    private var sampleCounts: Set<Int> = []
    private var statistics: Set<String> = []
    private var removedOrdinals: Set<Int> = []
    private var foreignEnvironments: Set<String> = []
    private var probeMetrics: Set<Int> = []

    fileprivate func record(_ shape: ResourceRunShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        perturbations.insert(shape.perturbation.rawValue)
        targets.insert(shape.target.rawValue)
        sampleCounts.insert(shape.declaredSampleCount)
        statistics.insert(shape.numericStatistic.rawValue)
        removedOrdinals.insert(shape.removedOrdinalIndex % 3)
        foreignEnvironments.insert(shape.foreignEnvironment.rawValue)
        probeMetrics.insert(shape.probeIndex % ResourceMetric.allCases.count)
    }

    func recordUnbuildableInput() {
        lock.lock()
        unbuildableInputs += 1
        lock.unlock()
    }

    func recordTotalityCheck() {
        lock.lock()
        totalityChecks += 1
        lock.unlock()
    }

    func recordPartitionedRequiredSet(count: Int) {
        lock.lock()
        partitionedRequiredSets += 1
        examinedCells += count
        lock.unlock()
    }

    func recordNotExecutedCheck() {
        lock.lock()
        notExecutedChecks += 1
        lock.unlock()
    }

    func recordNoNotExecutedOutcome() {
        lock.lock()
        noNotExecutedOutcomes += 1
        lock.unlock()
    }

    func recordRefusalCheck() {
        lock.lock()
        refusalChecks += 1
        lock.unlock()
    }

    func recordProducedRefusal(_ kind: String) {
        lock.lock()
        producedRefusals += 1
        refusalKinds.insert(kind)
        lock.unlock()
    }

    func recordFullyMeasuredRun(cells: Int) {
        lock.lock()
        fullyMeasuredRuns += 1
        fullyMeasuredCells += cells
        lock.unlock()
    }

    func recordDenominatorCheck() {
        lock.lock()
        denominatorChecks += 1
        lock.unlock()
    }

    func recordDenominatorHeld(declaredSamples samples: Int) {
        lock.lock()
        denominatorsHeld += 1
        declaredSamples += samples
        lock.unlock()
    }

    func recordGateCheck() {
        lock.lock()
        gateChecks += 1
        lock.unlock()
    }

    func recordGateRefusal(gateResults: Int) {
        lock.lock()
        gateRefusals += 1
        refusedGateResults += gateResults
        lock.unlock()
    }

    func recordSeparationCheck() {
        lock.lock()
        separationChecks += 1
        lock.unlock()
    }

    func recordSeparationHeld(gates: Int) {
        lock.lock()
        separationsHeld += 1
        separatedGates += gates
        lock.unlock()
    }

    func recordProbeCheck() {
        lock.lock()
        probeChecks += 1
        lock.unlock()
    }

    func recordProbeRefusal() {
        lock.lock()
        probeRefusals += 1
        lock.unlock()
    }

    func recordCompletedBody() {
        lock.lock()
        completedBodies += 1
        lock.unlock()
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 216, "the property requests at least 216 generated cases; ran \(cases)")
        #expect(
            completedBodies == cases,
            "\(cases - completedBodies) of \(cases) cases did not reach the end of the body"
        )
        #expect(
            unbuildableInputs == 0,
            "\(unbuildableInputs) described runs could not be built at all"
        )

        // Every arm ran on every case, compared against the case count rather than a floor.
        #expect(totalityChecks == cases, "totality checks: \(totalityChecks)")
        #expect(notExecutedChecks == cases, "notExecuted checks: \(notExecutedChecks)")
        #expect(refusalChecks == cases, "refusal checks: \(refusalChecks)")
        #expect(denominatorChecks == cases, "denominator checks: \(denominatorChecks)")
        #expect(gateChecks == cases, "gate checks: \(gateChecks)")
        #expect(separationChecks == cases, "separation checks: \(separationChecks)")
        #expect(probeChecks == cases, "probe checks: \(probeChecks)")

        // And every arm reached its conclusion, rather than returning early on a guard.
        #expect(
            partitionedRequiredSets == cases,
            "required sets that partitioned cleanly: \(partitionedRequiredSets)"
        )
        #expect(
            noNotExecutedOutcomes == cases,
            "runs free of a notExecuted cell outcome: \(noNotExecutedOutcomes)"
        )
        #expect(producedRefusals == cases, "arms that produced their refusal: \(producedRefusals)")
        #expect(denominatorsHeld == cases, "runs whose denominator held: \(denominatorsHeld)")
        #expect(gateRefusals == cases, "runs whose gates all refused: \(gateRefusals)")
        #expect(separationsHeld == cases, "runs whose targets stayed separate: \(separationsHeld)")
        #expect(probeRefusals == cases, "runs whose probe cell refused: \(probeRefusals)")

        // Counted work floors. A required set that shrank, a sample count that collapsed, or a gate
        // set that emptied would keep every assertion above true while measuring almost nothing.
        #expect(
            examinedCells >= cases * 17,
            "required cells examined across the run: \(examinedCells)"
        )
        #expect(
            declaredSamples >= cases * 6,
            "approved samples enumerated across the run: \(declaredSamples)"
        )
        #expect(
            refusedGateResults >= cases * 15,
            "resource gate results refused across the run: \(refusedGateResults)"
        )
        #expect(
            separatedGates >= cases * 11,
            "per-target gates checked for cross-target satisfaction: \(separatedGates)"
        )

        // The substantive half: the refusals were produced, not merely offered, and at least one
        // case supplied a complete within-limit sample set whose gates still failed.
        #expect(
            refusalKinds == Set(ResourcePerturbation.allCases.map(\.rawValue)),
            """
            perturbation arms never produced: \
            \(Set(ResourcePerturbation.allCases.map(\.rawValue)).subtracting(refusalKinds).sorted())
            """
        )
        #expect(
            fullyMeasuredRuns >= 1,
            """
            no case supplied a complete within-limit sample set, so nothing proved the gate \
            refusal is about the process rather than about a measurement that fell short
            """
        )
        #expect(
            fullyMeasuredCells >= fullyMeasuredRuns * 3,
            "measurable cells satisfied on a control arm: \(fullyMeasuredCells)"
        )

        // The generated baseline actually varied.
        #expect(seeds.count >= 100, "generated seeds: \(seeds.count)")
        #expect(
            perturbations == Set(ResourcePerturbation.allCases.map(\.rawValue)),
            "generated perturbations: \(perturbations.sorted())"
        )
        #expect(
            targets == Set(ExecutionTarget.allCases.map(\.rawValue)),
            "generated targets: \(targets.sorted())"
        )
        #expect(sampleCounts == [2, 3, 5, 7], "generated sample counts: \(sampleCounts.sorted())")
        #expect(
            statistics == Set(SummaryStatistic.allCases.map(\.rawValue)),
            "generated statistics: \(statistics.sorted())"
        )
        #expect(removedOrdinals == [0, 1, 2], "generated removed positions")
        #expect(
            foreignEnvironments == ["development-mac", "ios-simulator"],
            "generated foreign environments: \(foreignEnvironments.sorted())"
        )
        #expect(
            probeMetrics.count == ResourceMetric.allCases.count,
            "generated probe metrics: \(probeMetrics.count)"
        )
    }
}
