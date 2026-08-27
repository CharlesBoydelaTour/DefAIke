import DefAIkeDomain
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeReleaseValidation

// The two claims task 14.2 turns on, as one property over generated observation sets.
//
// Stated as the requirements state them:
//
//   * Requirement 13.19 — *a missing mandatory result is a failure.* For any observation set
//     at all, every comparison the bound plan and catalogue require has exactly one recorded
//     outcome, that outcome is `passed` or `failed` and never `notExecuted`, and a cell whose
//     observation did not come back is not satisfied. The report also keeps the missing cell
//     in the denominator of the measured agreement, so a run cannot raise its own ratio by
//     observing fewer fixtures.
//   * Requirement 13.16 — *a physical-iPhone gate is not satisfiable by host or simulator
//     evidence.* For any observation set at all, including one in which every comparison
//     agrees, every applicable parity gate this process records is `failed`, and the recorded
//     refusal names the environment the process is actually running in.
//
// The second is the interesting one, because the property has to hold *even in the case that
// looks like a pass*. One generated arm deliberately supplies a fully agreeing observation
// set whose observations all claim `physicalIPhone`. The cells agree, and the gates still
// fail. That contradiction is the design: an observation's environment is a claim its
// producer makes, and `ObservedParityEnvironment.current` is compiled from the platform, so
// this process cannot claim to be a phone whatever it is handed.
//
// Nothing here is release evidence. Every plan, catalogue, fixture, expected value,
// tolerance, configuration, and version tuple below is synthetic, no physical device ran, no
// Core ML model was loaded, and no fixture parity was measured. The suite's whole subject is
// what a *host* run is permitted to conclude, which is: nothing.
//
// ## Why no arm throws
//
// `propertyCheck` runs its body under `try?`, so an error escaping the body reports a passing
// run in milliseconds with every arm skipped. Nothing below rethrows: every throwing sample
// builder and binding call is wrapped into a value or reported through `Issue.record`, and
// ``ParityGateWitness`` counts the cases and every arm *outside* the body, where an issue is
// not suppressed. Arm counters are compared against the case count rather than against a
// floor, and ``ParityGateWitness/recordCompletedBody()`` is the last thing the body does, so
// a case that stopped early is countable.

extension Tag {
    /// Task 14.2's two carrying claims.
    ///
    /// Declared here rather than in a shared namespace, matching the repository's one-tag-per
    /// property-file convention.
    @Tag static var parityGateUnsatisfiable: Self
}

@Suite(
    "Parity gates are unsatisfiable without a physical iPhone",
    .tags(.parityGateUnsatisfiable)
)
struct ParityGateUnsatisfiablePropertyTests {

    /// **Validates: Requirements 4.13, 6.18, 13.6, 13.7, 13.8, 13.9, 13.10, 13.11, 13.16,
    /// 13.21**
    @Test("No observation set makes a host-run parity gate pass, and no missing cell passes")
    func noObservationSetSatisfiesAHostRunGate() async {
        let witness = ParityGateWitness()

        await propertyCheck(count: 120, input: ParityRunShape.generator) { shape in
            witness.record(shape)
            guard let scenario = ParityRunScenario(shape: shape, witness: witness) else {
                witness.recordUnbuildableInput()
                return
            }
            scenario.checkEveryRequiredCellHasExactlyOneOutcome()
            scenario.checkNoOutcomeIsNotExecuted()
            scenario.checkThePerturbedCellsProducedTheExpectedRefusal()
            scenario.checkMissingCellsStayInTheDenominator()
            scenario.checkEveryApplicableGateFailsInThisProcess()
            scenario.checkAnUnrequestedCellIsAlsoAFailure()
            witness.recordCompletedBody()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - What one case varies

/// How one generated case perturbs the observation set.
///
/// Eight arms, one per way an observation can fail to become evidence plus the control arm
/// that perturbs nothing. `none` is not filler: it is the arm in which every comparison
/// agrees, and it is the one that proves the gate refusal is about the process rather than
/// about a disagreement somewhere.
private enum ParityPerturbation: String, Hashable, Sendable, CaseIterable {
    /// Every observation is the approved expected value.
    case none

    /// The observation is absent from the store.
    case removeObservation = "remove-observation"

    /// The observation exists but cannot be read.
    case makeUnreadable = "make-unreadable"

    /// The observation is a value of a different kind.
    case wrongKind = "wrong-kind"

    /// The observation is the right kind and the wrong value.
    case wrongValue = "wrong-value"

    /// The observation was produced somewhere that cannot supply release evidence.
    case foreignEnvironment = "foreign-environment"

    /// The observation was produced on a different configuration.
    case foreignConfiguration = "foreign-configuration"

    /// The observation was produced under a different version tuple.
    case foreignVersionTuple = "foreign-version-tuple"

    /// Whether this arm leaves a perturbed cell unsatisfied.
    var refusesTheCell: Bool { self != .none }
}

/// The observed comparisons a case can perturb.
///
/// Rank agreement and screenshot geometry are excluded because neither is read through the
/// observation seam: rank agreement is derived from the raw-logit observations, so perturbing
/// a logit already perturbs it, and screenshot geometry has no approved expected value at all.
/// Both are still asserted about — every arm checks that the screenshot-geometry cells report
/// an unrepresentable expectation and that the derived rank cell has an outcome.
private let observedComparisons: [ComparisonMetric] = ComparisonMetric.allCases
    .filter { $0.requiredObservationKind != nil }
    .sorted { $0.rawValue < $1.rawValue }

/// One generated case.
private struct ParityRunShape: CustomStringConvertible, Sendable {
    let seed: Int
    let provenanceApplicable: Bool
    let distinctLogits: Bool
    let comparisonIndex: Int
    let perturbationIndex: Int
    let cellCountIndex: Int
    let foreignEnvironmentIndex: Int
    let probeIndex: Int

    /// Observed comparisons this case's capability set actually owes.
    ///
    /// A pixel-only release owes no provenance comparison at all, so perturbing one would
    /// perturb nothing and the denominator arm would have no record to read. Narrowing here
    /// rather than skipping in the arm keeps every arm running on every case.
    var applicableComparisons: [ComparisonMetric] {
        provenanceApplicable
            ? observedComparisons
            : observedComparisons.filter { !$0.isProvenanceConditional }
    }

    /// The comparison this case perturbs.
    var comparison: ComparisonMetric {
        applicableComparisons[comparisonIndex % applicableComparisons.count]
    }

    /// How it perturbs it.
    var perturbation: ParityPerturbation {
        ParityPerturbation.allCases[perturbationIndex % ParityPerturbation.allCases.count]
    }

    /// How many cells of that comparison it perturbs.
    var perturbedCellCount: Int { 1 + cellCountIndex % 3 }

    /// The environment a `foreignEnvironment` arm claims.
    ///
    /// Never `physicalIPhone`: an arm that claimed it would perturb nothing.
    var foreignEnvironment: ExecutionEnvironment {
        foreignEnvironmentIndex % 2 == 0 ? .developmentMac : .iOSSimulator
    }

    var description: String {
        """
        seed \(seed), provenance \(provenanceApplicable), distinct logits \(distinctLogits), \
        \(comparison.rawValue) perturbed by \(perturbation.rawValue) on \
        \(perturbedCellCount) cell(s), foreign environment \(foreignEnvironment.rawValue)
        """
    }

    // MARK: Generator

    static var generator: Generator<ParityRunShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.bool,
            Gen.bool,
            index,
            index,
            index,
            index,
            index
        )
        .map { raw in
            ParityRunShape(
                seed: raw.0,
                provenanceApplicable: raw.1,
                distinctLogits: raw.2,
                comparisonIndex: raw.3,
                perturbationIndex: raw.4,
                cellCountIndex: raw.5,
                foreignEnvironmentIndex: raw.6,
                probeIndex: raw.7
            )
        }
        .eraseToAny()
    }

    /// A selector index.
    ///
    /// The range is a multiple of every modulus it is reduced by (2, 3, 5, 6, 8), so each
    /// table entry is drawn with equal probability rather than with a modulus bias.
    private static var index: Generator<Int, AnySequence<Any>> {
        Gen.int(in: 0...959).eraseToAny()
    }
}

// MARK: - One case

/// One generated parity run: a bound plan and catalogue, a perturbed observation store, and
/// the report the runner produced from them.
///
/// Built once per case and never rebuilt inside an arm, so every arm reasons about the same
/// run. Construction returns `nil` rather than throwing, because a throw inside the property
/// body is discarded and would report a vacuous pass.
private struct ParityRunScenario {
    let shape: ParityRunShape
    let witness: ParityGateWitness
    let binding: ParityRunBinding
    let report: ParityRunReport

    /// The cells this case perturbed, in the order they were perturbed.
    let perturbedCells: [ParityCell]

    init?(shape: ParityRunShape, witness: ParityGateWitness) {
        self.shape = shape
        self.witness = witness
        guard
            let catalog = try? (
                shape.distinctLogits
                    ? Sample.distinctLogitCatalog(
                        provenanceApplicable: shape.provenanceApplicable
                    )
                    : Sample.catalog(provenanceApplicable: shape.provenanceApplicable)
            ),
            let plan = try? Sample.parityPlan(),
            let configuration = try? Sample.candidateConfiguration(),
            let versionTuple = try? Sample.parityVersionTuple(
                provenanceEnabled: shape.provenanceApplicable
            ),
            let binding = try? ParityRunBinding(
                plan: plan,
                catalog: catalog,
                configuration: configuration,
                versionTuple: versionTuple
            ),
            let foreignConfiguration = try? Sample.candidateConfiguration(
                hardware: DeviceHardwareID("iPhone98.\(1 + shape.seed % 8)")
            ),
            let foreignVersionTuple = try? Sample.parityVersionTuple(
                provenanceEnabled: !shape.provenanceApplicable
            )
        else {
            return nil
        }
        self.binding = binding

        var store = FakeParityObservationStore.agreeing(with: binding)
        let candidates = binding.requiredCells(for: shape.comparison)
        let chosen = Array(candidates.prefix(shape.perturbedCellCount))
        for cell in chosen {
            switch shape.perturbation {
            case .none:
                continue
            case .removeObservation:
                store.remove(cell)
            case .makeUnreadable:
                store.makeUnreadable(cell)
            case .wrongKind:
                store.set(Self.wrongKindValue(for: shape.comparison), for: cell)
            case .wrongValue:
                guard
                    let approved = FakeParityObservationStore.approvedValue(
                        for: cell,
                        in: binding
                    ),
                    let disagreeing = Self.disagreeingValue(for: approved)
                else {
                    continue
                }
                store.set(disagreeing, for: cell)
            case .foreignEnvironment:
                store.setEnvironment(shape.foreignEnvironment, for: cell)
            case .foreignConfiguration:
                store.setConfiguration(foreignConfiguration, for: cell)
            case .foreignVersionTuple:
                store.setVersionTuple(foreignVersionTuple, for: cell)
            }
        }
        self.perturbedCells = shape.perturbation == .none ? [] : chosen
        self.report = ParityRunner(observations: store).run(binding)
    }

    /// A value of a different kind than the comparison needs.
    static func wrongKindValue(for comparison: ComparisonMetric) -> ObservedParityValue {
        comparison.requiredObservationKind == .rawLogit
            ? .pixelLabel(.notEnoughSignal)
            : .rawLogit(0.125)
    }

    /// A value of the right kind that is not the approved one.
    ///
    /// The raw-logit offset is far outside every tolerance the sample plan declares, so the
    /// arm is about disagreement rather than about a boundary.
    static func disagreeingValue(for approved: ObservedParityValue) -> ObservedParityValue? {
        switch approved {
        case let .preprocessingOutputDigest(digest):
            return .preprocessingOutputDigest(Self.otherDigest(than: digest))
        case let .retainedBytesDigest(digest):
            return .retainedBytesDigest(Self.otherDigest(than: digest))
        case let .rawLogit(value):
            return .rawLogit(value + 1_000)
        case let .pixelLabel(label):
            return PixelLabelKey.allCases.first { $0 != label }.map { .pixelLabel($0) }
        case let .bytePreservationStatus(status):
            return BytePreservationStatusKey.allCases
                .first { $0 != status }
                .map { .bytePreservationStatus($0) }
        case let .provenanceState(state):
            return ProvenanceStateKey.allCases.first { $0 != state }.map { .provenanceState($0) }
        }
    }

    static func otherDigest(than digest: DefAIkeDomain.SHA256Digest) -> DefAIkeDomain.SHA256Digest
    {
        let candidate = Sample.digest(0xD1_5A_C0)
        return candidate == digest ? Sample.digest(0xD1_5A_C1) : candidate
    }

    // MARK: Arms

    /// Requirement 13.19, first half: the mapping is total and nothing is absent.
    func checkEveryRequiredCellHasExactlyOneOutcome() {
        witness.recordTotalityCheck()
        guard report.requiredCells == binding.requiredCells else {
            Issue.record("the report's required set is not the binding's")
            return
        }
        var satisfied = 0
        var unsatisfied = 0
        for cell in binding.requiredCells {
            // Non-optional by type. What is checked here is that the answer is a real one:
            // every cell is either satisfied or not, and the two projections partition the
            // required set with nothing left over.
            if report.outcome(of: cell).isSatisfied { satisfied += 1 } else { unsatisfied += 1 }
        }
        guard satisfied + unsatisfied == binding.requiredCells.count,
            report.satisfiedCells.count == satisfied,
            report.unsatisfiedCells.count == unsatisfied
        else {
            Issue.record("the recorded outcomes do not partition the required set")
            return
        }
        // Every screenshot-geometry cell reports its unrepresentable expectation, whatever
        // this case perturbed, and the derived rank cell always has an outcome.
        for cell in binding.requiredCells(for: .screenshotGeometry) {
            guard case .approvedExpectationUnrepresentable = report.outcome(of: cell) else {
                Issue.record("a screenshot-geometry cell did not report its expectation gap")
                return
            }
        }
        guard binding.requiredCells(for: .rankAgreement).count == 1 else {
            Issue.record("rank agreement must be exactly one cell")
            return
        }
        witness.recordPartitionedRequiredSet(count: binding.requiredCells.count)
    }

    /// Requirement 13.19, second half: `notExecuted` is unreachable for a cell.
    func checkNoOutcomeIsNotExecuted() {
        witness.recordNotExecutedCheck()
        for cell in binding.requiredCells where report.outcome(of: cell).outcome == .notExecuted {
            Issue.record("a required cell recorded notExecuted")
            return
        }
        witness.recordNoNotExecutedOutcome()
    }

    /// Each perturbation arm produced the refusal it describes, and nothing else did.
    func checkThePerturbedCellsProducedTheExpectedRefusal() {
        witness.recordRefusalCheck()
        for cell in perturbedCells {
            let outcome = report.outcome(of: cell)
            guard !outcome.isSatisfied else {
                Issue.record("a perturbed cell was satisfied")
                return
            }
            guard Self.matches(outcome, shape.perturbation) else {
                Issue.record("a perturbed cell produced an unexpected outcome shape")
                return
            }
        }
        if shape.perturbation == .none {
            // The control arm: every comparison that can be made agreed. Only the
            // screenshot-geometry cells are unsatisfied, and they are unsatisfied because no
            // approved expected value for them is representable.
            let stragglers = report.unsatisfiedCells.filter {
                $0.comparison != .screenshotGeometry
            }
            guard stragglers.isEmpty else {
                Issue.record("the control arm left a comparison unsatisfied")
                return
            }
            witness.recordFullyAgreeingRun()
        }
        witness.recordProducedRefusal(shape.perturbation.rawValue)
    }

    /// Whether one outcome is the shape a perturbation describes.
    static func matches(_ outcome: ParityCellOutcome, _ perturbation: ParityPerturbation) -> Bool {
        switch (outcome, perturbation) {
        case let (.resultMissing(gap), .removeObservation):
            return gap.fault == .observationAbsent
        case let (.resultMissing(gap), .makeUnreadable):
            return gap.fault == .observationUnreadable
        case (.observationKindMismatch, .wrongKind):
            return true
        case (.disagreed, .wrongValue):
            return true
        case let (.nonQualifyingEvidence(reason), .foreignEnvironment):
            if case .notPhysicalIPhone = reason { return true }
            return false
        case let (.nonQualifyingEvidence(reason), .foreignConfiguration):
            if case .configurationMismatch = reason { return true }
            return false
        case (.nonQualifyingEvidence(.versionTupleMismatch), .foreignVersionTuple):
            return true
        default:
            return false
        }
    }

    /// Requirement 13.19: a missing cell lowers the measured agreement.
    func checkMissingCellsStayInTheDenominator() {
        witness.recordDenominatorCheck()
        let specification = Sample.evidence("evidence.reference.\(shape.comparison.rawValue)")
        // `try?` flattens the method's own `nil` — a metric the binding does not require —
        // into the same optional as a thrown schema error, and either is a failure here.
        guard let record = try? report.comparisonRecord(
            for: shape.comparison,
            specification: specification
        ) else {
            Issue.record("a required comparison produced no record")
            return
        }
        let required = binding.requiredCells(for: shape.comparison).count
        guard record.comparedFixtureCount.value == required else {
            Issue.record("the compared count is not the required count")
            return
        }
        let agreeing = report.satisfiedCells.filter { $0.comparison == shape.comparison }.count
        guard record.agreeingFixtureCount.value == agreeing else {
            Issue.record("the agreeing count does not match the satisfied cells")
            return
        }
        if shape.perturbation.refusesTheCell, !perturbedCells.isEmpty {
            guard record.agreeingFixtureCount.value < record.comparedFixtureCount.value else {
                Issue.record("a refused cell did not lower the measured agreement")
                return
            }
            guard record.outcome == .failed else {
                Issue.record("a refused cell did not fail its comparison")
                return
            }
        }
        witness.recordDenominatorHeld()
    }

    /// Requirement 13.16: this process satisfies no applicable parity gate.
    func checkEveryApplicableGateFailsInThisProcess() {
        witness.recordGateCheck()
        guard let refusal = report.processRefusal else {
            Issue.record("a host process must record a refusal")
            return
        }
        guard refusal == .notPhysicalIPhone(ObservedParityEnvironment.current) else {
            Issue.record("the recorded refusal does not name this process's environment")
            return
        }
        var applicable = 0
        for gate in DeviceGate.parityGates {
            let result = report.gateResult(for: gate)
            guard result.processRefusal == refusal else {
                Issue.record("a gate result does not carry the process refusal")
                return
            }
            if result.applicability.isApplicable {
                applicable += 1
                guard result.outcome == .failed else {
                    Issue.record("an applicable parity gate passed in a host process")
                    return
                }
            } else {
                // The one legitimate `notExecuted`: the conditional provenance gate under an
                // approved decision that it does not apply.
                guard gate.isProvenanceConditional, result.outcome == .notExecuted else {
                    Issue.record("an inapplicable gate recorded something other than notExecuted")
                    return
                }
            }
        }
        let expectedApplicable = shape.provenanceApplicable
            ? DeviceGate.parityGates.count
            : DeviceGate.parityGates.count - 1
        guard applicable == expectedApplicable else {
            Issue.record("the applicable gate count does not follow the capability set")
            return
        }
        guard report.outcome == .failed else {
            Issue.record("a host run reported an overall parity pass")
            return
        }
        guard report.owedInputs.contains(.physicalIPhoneRunEnvironment) else {
            Issue.record("a host run does not report that it owes a physical iPhone")
            return
        }
        witness.recordGateRefusal(applicableGates: applicable)
    }

    /// A cell the binding never required is a failure too, not a `nil`.
    func checkAnUnrequestedCellIsAlsoAFailure() {
        witness.recordProbeCheck()
        let comparison = ComparisonMetric.allCases[
            shape.probeIndex % ComparisonMetric.allCases.count
        ]
        guard let identifier = FixtureID("fixture.probe.\(1 + shape.seed % 997)") else {
            Issue.record("the probe fixture identifier is not canonical")
            return
        }
        let probe = ParityCell(
            subject: .fixture(identifier, family: .modelParity),
            comparison: comparison
        )
        guard !binding.requiredCells.contains(probe) else {
            Issue.record("the probe cell must not be a required cell")
            return
        }
        let outcome = report.outcome(of: probe)
        guard !outcome.isSatisfied, outcome.outcome == .failed else {
            Issue.record("an unrequested cell must be a failure")
            return
        }
        guard case let .resultMissing(gap) = outcome, gap.owed == comparison.owedReleaseInput else {
            Issue.record("an unrequested cell must report what it is owed")
            return
        }
        witness.recordProbeRefusal()
    }
}

// MARK: - The variation witness

/// Counts what the run generated and what it produced, outside the property body.
///
/// `propertyCheck` runs its body under `try?`, so a body that failed before its first
/// assertion reports a passing test in milliseconds with every arm skipped. Two habits close
/// that gap, and both matter:
///
///   * every arm counter is compared against the **case count** rather than against a floor,
///     so a run in which an arm stopped being reached fails even when the absolute number
///     still looks large; and
///   * ``recordCompletedBody()`` is the last thing the body does, so a case that ended early
///     is countable. `completedBodies == cases` alone would pass vacuously as `0 == 0`, which
///     is why the case floor sits beside it.
///
/// The produced sets are the substantive half. Every perturbation arm must actually have
/// produced its refusal, at least one case must actually have supplied a fully agreeing
/// observation set — the arm that proves the gate refusal is about the process rather than
/// about a disagreement — and the counted cell and gate work must have a floor, so a run over
/// a catalogue that quietly shrank to a handful of cells fails here.
private final class ParityGateWitness: @unchecked Sendable {
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
    private var probeChecks = 0
    private var probeRefusals = 0

    // Counted work.
    private var comparedCells = 0
    private var refusedApplicableGates = 0
    private var fullyAgreeingRuns = 0

    // Produced outcomes.
    private var refusalKinds: Set<String> = []

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var perturbations: Set<String> = []
    private var comparisons: Set<String> = []
    private var provenanceSettings: Set<Bool> = []
    private var logitSettings: Set<Bool> = []
    private var cellCounts: Set<Int> = []
    private var foreignEnvironments: Set<String> = []
    private var probeComparisons: Set<Int> = []

    func record(_ shape: ParityRunShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        perturbations.insert(shape.perturbation.rawValue)
        comparisons.insert(shape.comparison.rawValue)
        provenanceSettings.insert(shape.provenanceApplicable)
        logitSettings.insert(shape.distinctLogits)
        cellCounts.insert(shape.perturbedCellCount)
        foreignEnvironments.insert(shape.foreignEnvironment.rawValue)
        probeComparisons.insert(shape.probeIndex % ComparisonMetric.allCases.count)
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
        comparedCells += count
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

    func recordFullyAgreeingRun() {
        lock.lock()
        fullyAgreeingRuns += 1
        lock.unlock()
    }

    func recordDenominatorCheck() {
        lock.lock()
        denominatorChecks += 1
        lock.unlock()
    }

    func recordDenominatorHeld() {
        lock.lock()
        denominatorsHeld += 1
        lock.unlock()
    }

    func recordGateCheck() {
        lock.lock()
        gateChecks += 1
        lock.unlock()
    }

    func recordGateRefusal(applicableGates: Int) {
        lock.lock()
        gateRefusals += 1
        refusedApplicableGates += applicableGates
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

        #expect(cases >= 120, "the property requests at least 120 generated cases; ran \(cases)")
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
        #expect(probeRefusals == cases, "runs whose probe cell refused: \(probeRefusals)")

        // Counted work floors. A catalogue that shrank, or a gate set that emptied, would keep
        // every assertion above true while measuring almost nothing.
        #expect(
            comparedCells >= cases * 200,
            "required cells examined across the run: \(comparedCells)"
        )
        #expect(
            refusedApplicableGates >= cases * 6,
            "applicable parity gates refused across the run: \(refusedApplicableGates)"
        )

        // The substantive half: the refusals were produced, not merely offered, and at least
        // one case supplied a fully agreeing observation set whose gates still failed.
        #expect(
            refusalKinds == Set(ParityPerturbation.allCases.map(\.rawValue)),
            """
            perturbation arms never produced: \
            \(Set(ParityPerturbation.allCases.map(\.rawValue)).subtracting(refusalKinds).sorted())
            """
        )
        #expect(
            fullyAgreeingRuns >= 1,
            """
            no case supplied a fully agreeing observation set, so nothing proved the gate \
            refusal is about the process rather than about a disagreement
            """
        )

        // The generated baseline actually varied.
        #expect(seeds.count >= 60, "generated seeds: \(seeds.count)")
        #expect(
            perturbations == Set(ParityPerturbation.allCases.map(\.rawValue)),
            "generated perturbations: \(perturbations.sorted())"
        )
        #expect(
            comparisons == Set(observedComparisons.map(\.rawValue)),
            "generated comparisons: \(comparisons.sorted())"
        )
        #expect(provenanceSettings == [true, false], "generated capability sets")
        #expect(logitSettings == [true, false], "generated catalogue shapes")
        #expect(cellCounts == [1, 2, 3], "generated perturbed cell counts: \(cellCounts.sorted())")
        #expect(
            foreignEnvironments == ["development-mac", "ios-simulator"],
            "generated foreign environments: \(foreignEnvironments.sorted())"
        )
        #expect(
            probeComparisons.count == ComparisonMetric.allCases.count,
            "generated probe comparisons: \(probeComparisons.count)"
        )
    }
}
