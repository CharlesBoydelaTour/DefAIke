import DefAIkeDomain
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeReleaseValidation

// The three claims task 14.4 turns on, as one property over generated observation sets.
//
// Stated as the requirements state them:
//
//   * Requirements 12.14 and 12.18 — *a missing or failing mandatory result blocks the application
//     version.* For any observation set at all, every position the bound plan requires has exactly
//     one recorded outcome, that outcome is `passed` or `failed` and never `notExecuted`, a position
//     whose observation did not come back is not satisfied, and the report keeps the required
//     position count in the denominator of the recorded coverage so a run cannot raise its own ratio
//     by executing fewer positions. And an unexecuted position produces no recorded cell at all, so
//     it can never appear in a matrix artifact as a pass.
//   * Requirement 12.13 — *a manual portion needs an imported reference and an approval for that
//     position.* For any observation set at all, no VoiceOver or Switch Control position is
//     satisfied by an automated run, by an approval naming another position, or by a rejected
//     decision; and every satisfied manual position carries both an imported result and an approved
//     authorization.
//   * Requirement 13.16 — *a physical-iPhone gate is not satisfiable by host or simulator evidence.*
//     For any observation set at all, including one in which every executable position completed,
//     every matrix gate this process records is `failed`, and the recorded refusal names the
//     environment the process is actually running in.
//
// The third is the interesting one, because the property has to hold *even in the case that looks
// like a pass*. One generated arm deliberately supplies a complete, completing observation set whose
// observations all claim `physicalIPhone` and whose manual positions all carry a sound imported
// pair. Those positions pass, and the gates still fail. That contradiction is the design: an
// observation's environment is a claim its producer makes, and `ObservedParityEnvironment.current` is
// compiled from the platform, so this process cannot claim to be a phone whatever it is handed.
//
// Nothing here is release evidence. Every plan, configuration, version tuple, imported result, and
// authorization below is synthetic, no physical device ran, no human executed anything, no approval
// was granted, and 36 of the 56 positions per configuration could not have been executed anywhere in
// this repository.
//
// ## Why no arm throws
//
// `propertyCheck` runs its body under `try?`, so an error escaping the body reports a passing run in
// milliseconds with every arm skipped. Nothing below rethrows: every throwing sample builder and
// binding call is wrapped into a value or reported through `Issue.record`, and ``MatrixWitness``
// counts the cases and every arm *outside* the body, where an issue is not suppressed. Arm counters
// are compared against the case count rather than against a floor, and
// ``MatrixWitness/recordCompletedBody()`` is the last thing the body does, so a case that stopped
// early is countable.

extension Tag {
    /// Task 14.4's three carrying claims.
    @Tag static var accessibilityMatrixFailClosed: Self
}

@Suite(
    "Accessibility and localization matrix cells fail closed",
    .tags(.accessibilityMatrixFailClosed)
)
struct AccessibilityMatrixFailClosedPropertyTests {

    /// **Validates: Requirements 12.13, 12.14, 12.17, 12.18**
    @Test("No observation set makes a host-run matrix gate pass, and no unexecuted position passes")
    func noObservationSetSatisfiesAHostRunGate() async {
        let witness = MatrixWitness()

        await propertyCheck(count: 216, input: MatrixRunShape.generator) { shape in
            witness.record(shape)
            guard let scenario = MatrixRunScenario(shape: shape) else {
                witness.recordUnbuildableInput()
                return
            }
            scenario.checkEveryRequiredCellHasExactlyOneOutcome(witness)
            scenario.checkNoOutcomeIsNotExecuted(witness)
            scenario.checkThePerturbedCellProducedTheExpectedRefusal(witness)
            scenario.checkMissingPositionsStayInTheDenominator(witness)
            scenario.checkEveryGateFailsInThisProcess(witness)
            scenario.checkUnexecutedPositionsProduceNoRecordedCell(witness)
            scenario.checkManualPositionsNeedImportedEvidence(witness)
            scenario.checkAnUnrequestedCellIsAlsoAFailure(witness)
            witness.recordCompletedBody()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - What one case varies

/// How one generated case perturbs the observation of one position.
///
/// Twelve arms, one per way an observation can fail to become evidence plus the control arm that
/// perturbs nothing. `none` is not filler: it is the arm in which every executable position was
/// executed and completed, and it is the one that proves the gate refusal is about the process
/// rather than about a position that fell short.
private enum MatrixPerturbation: String, Hashable, Sendable, CaseIterable {
    /// Every readable position holds an admissible, completing observation.
    case none

    /// The observation is absent.
    case removeObservation = "remove-observation"

    /// The observation exists and cannot be read.
    case unreadable

    /// The assistive technology or display condition could not be established.
    case conditionNotActivatable = "condition-not-activatable"

    /// The observation is filed against a different position.
    case misfiled

    /// The observation came back and the workflow did not complete.
    case nonCompletingCoverage = "non-completing-coverage"

    /// The observation was produced somewhere that cannot supply release evidence.
    case foreignEnvironment = "foreign-environment"

    /// The observation was produced on a different configuration.
    case foreignConfiguration = "foreign-configuration"

    /// The observation was produced under a different version tuple.
    case foreignVersionTuple = "foreign-version-tuple"

    /// A manual-only position was answered by an automated run.
    case automatedOnManualPosition = "automated-on-manual-position"

    /// A manual-only position was answered with an approval naming another position.
    case authorizationForAnotherCell = "authorization-for-another-cell"

    /// A manual-only position was answered with a rejected decision.
    case rejectedAuthorization = "rejected-authorization"

    /// Whether this arm leaves the perturbed position unsatisfied.
    var refusesTheCell: Bool { self != .none }

    /// Whether this arm needs a position no automation can establish.
    var needsAManualPosition: Bool {
        switch self {
        case .automatedOnManualPosition, .authorizationForAnotherCell, .rejectedAuthorization:
            true
        case .none, .removeObservation, .unreadable, .conditionNotActivatable, .misfiled,
             .nonCompletingCoverage, .foreignEnvironment, .foreignConfiguration,
             .foreignVersionTuple:
            false
        }
    }
}

/// One generated case.
private struct MatrixRunShape: CustomStringConvertible, Sendable {
    let seed: Int
    let perturbationIndex: Int
    let cellIndex: Int
    let manualCellIndex: Int
    let coverageIndex: Int
    let foreignEnvironmentIndex: Int
    let configurationCountIndex: Int
    let secondVersionIndex: Int
    let probeIndex: Int

    var perturbation: MatrixPerturbation {
        MatrixPerturbation.allCases[perturbationIndex % MatrixPerturbation.allCases.count]
    }

    /// The failing coverage a `nonCompletingCoverage` arm reports. Never the completing case.
    var nonCompletingCoverage: ObservedWorkflowCoverage {
        let failing = ObservedWorkflowCoverage.allCases.filter { !$0.completesTheWorkflow }
        return failing[coverageIndex % failing.count]
    }

    /// The environment a `foreignEnvironment` arm claims. Never `physicalIPhone`.
    var foreignEnvironment: ExecutionEnvironment {
        foreignEnvironmentIndex % 2 == 0 ? .developmentMac : .iOSSimulator
    }

    /// How many candidate configurations the plan enumerates: one or two.
    var configurationCount: Int { configurationCountIndex % 2 == 0 ? 1 : 2 }

    /// The second candidate's operating-system version, when there is one. Always major 18, so a
    /// two-candidate case really spans two major iOS versions.
    var secondOSVersion: String { secondVersionIndex % 2 == 0 ? "18.0.0" : "18.1.0" }

    /// The exercise the unrequested-position probe uses.
    var probeExercise: MatrixExercise {
        MatrixExercise.required[probeIndex % MatrixExercise.required.count]
    }

    var description: String {
        """
        seed \(seed), perturbed by \(perturbation.rawValue), \(configurationCount) \
        configuration(s), non-completing coverage \(nonCompletingCoverage), \
        foreign environment \(foreignEnvironment.rawValue)
        """
    }

    // MARK: Generator

    static var generator: Generator<MatrixRunShape, AnySequence<Any>> {
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
            MatrixRunShape(
                seed: raw.0,
                perturbationIndex: raw.1,
                cellIndex: raw.2,
                manualCellIndex: raw.3,
                coverageIndex: raw.4,
                foreignEnvironmentIndex: raw.5,
                configurationCountIndex: raw.6,
                secondVersionIndex: raw.7,
                probeIndex: raw.8
            )
        }
        .eraseToAny()
    }

    /// A selector index.
    ///
    /// The range is a multiple of every modulus it is reduced by — 2 for the foreign environment,
    /// the configuration count, and the second version; 8 for the failing coverage cases and the
    /// probe exercise; 10 for the manual-only readable positions; 12 for the perturbation; and 20 for
    /// the readable positions — because 720 is 2^4 · 3^2 · 5 and every one of 2, 8, 10, 12, and 20
    /// divides it. So each table entry is drawn with equal probability rather than with a modulus
    /// bias.
    private static var index: Generator<Int, AnySequence<Any>> {
        Gen.int(in: 0...719).eraseToAny()
    }
}

// MARK: - One case

/// One generated matrix run: a bound plan, a perturbed observation store, and the report the runner
/// produced from them.
///
/// Built once per case and never rebuilt inside an arm, so every arm reasons about the same run.
/// Construction returns `nil` rather than throwing, because a throw inside the property body is
/// discarded and would report a vacuous pass.
private struct MatrixRunScenario {
    let shape: MatrixRunShape
    let binding: AccessibilityMatrixCoverageBinding
    let report: AccessibilityMatrixReport

    /// The position this case perturbed, or `nil` on the control arm.
    let perturbedCell: AccessibilityMatrixCell?

    /// The first binding's readable positions, in stable order.
    let readableCells: [AccessibilityMatrixCell]

    /// The first binding's manual-only readable positions, in stable order.
    let manualCells: [AccessibilityMatrixCell]

    init?(shape: MatrixRunShape) {
        self.shape = shape
        var candidates: [CandidateDeviceConfiguration] = []
        guard let first = try? Sample.matrixConfiguration(hardware: "iPhone17.1") else {
            return nil
        }
        candidates.append(first)
        if shape.configurationCount == 2 {
            guard
                let second = try? Sample.matrixConfiguration(
                    hardware: "iPhone18.2",
                    osVersion: shape.secondOSVersion
                )
            else {
                return nil
            }
            candidates.append(second)
        }
        guard
            let plan = try? Sample.matrixPlan(configurations: candidates),
            let versionTuple = try? Sample.matrixVersionTuple(),
            let coverage = try? AccessibilityMatrixCoverageBinding(
                plan: plan,
                versionTuple: versionTuple
            ),
            let scoped = coverage.bindings.first,
            let foreignConfiguration = try? Sample.matrixConfiguration(
                hardware: "iPhone98.\(1 + shape.seed % 8)"
            ),
            let foreignVersionTuple = try? Sample.matrixVersionTuple(validationPlan: "plan.other")
        else {
            return nil
        }
        self.binding = coverage

        let readable = Sample.readableCells(of: scoped)
        let manual = readable.filter { $0.automationSupport.requiresImportedManualEvidence }
        guard readable.count == 20, manual.count == 10 else { return nil }
        self.readableCells = readable
        self.manualCells = manual

        var store = FakeMatrixObservationStore.complete(for: coverage)
        // Every observation claims a physical iPhone, so the control arm really is the case that
        // looks like a pass. The gate refusal must not depend on the claim being false.
        store.defaultEnvironment = .physicalIPhone

        let chosen = shape.perturbation.needsAManualPosition
            ? manual[shape.manualCellIndex % manual.count]
            : readable[shape.cellIndex % readable.count]
        let elsewhere = manual[(shape.manualCellIndex + 1) % manual.count]
        let other = readable[(shape.cellIndex + 1) % readable.count]

        switch shape.perturbation {
        case .none:
            self.perturbedCell = nil
        case .removeObservation:
            store.remove(chosen)
            self.perturbedCell = chosen
        case .unreadable:
            store.makeUnreadable(chosen)
            self.perturbedCell = chosen
        case .conditionNotActivatable:
            store.makeNotActivatable(chosen)
            self.perturbedCell = chosen
        case .misfiled:
            store.misfile(chosen, as: other)
            self.perturbedCell = chosen
        case .nonCompletingCoverage:
            store.setCoverage(shape.nonCompletingCoverage, for: chosen)
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
        case .automatedOnManualPosition:
            store.setExecution(.automated, for: chosen)
            self.perturbedCell = chosen
        case .authorizationForAnotherCell:
            store.setExecution(.manual(Sample.importedManual(for: elsewhere)), for: chosen)
            self.perturbedCell = chosen
        case .rejectedAuthorization:
            store.setExecution(
                .manual(Sample.importedManual(for: chosen, decision: .rejected)),
                for: chosen
            )
            self.perturbedCell = chosen
        }
        self.report = AccessibilityMatrixRunner(observations: store).run(coverage)
    }

    /// The report for the configuration this case perturbed.
    var scopedReport: AccessibilityMatrixConfigurationReport? {
        report.configurationReports.first
    }

    // MARK: Arms

    /// Requirements 12.14 and 12.18, first half: the mapping is total and nothing is absent.
    func checkEveryRequiredCellHasExactlyOneOutcome(_ witness: MatrixWitness) {
        witness.recordTotalityCheck()
        var examined = 0
        var blocked = 0
        for (offset, scoped) in report.configurationReports.enumerated() {
            let owed = binding.bindings[offset]
            guard scoped.requiredCells == owed.requiredCells else {
                Issue.record("the report's required set is not the binding's")
                return
            }
            var satisfied = 0
            var unsatisfied = 0
            for cell in scoped.requiredCells {
                // Non-optional by type. What is checked here is that the answer is a real one:
                // every position is either satisfied or not, and the two projections partition the
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
            // Every position nothing in this repository can exercise reports that, whatever this
            // case perturbed.
            for cell in Sample.blockedCells(of: owed) {
                guard case let .exerciseUnavailable(limit) = scoped.outcome(of: cell),
                    limit.blocksExercise
                else {
                    Issue.record("a blocked position did not report a blocking finding")
                    return
                }
                blocked += 1
            }
            examined += scoped.requiredCells.count
        }
        guard examined == binding.requiredCells.count else {
            Issue.record("the report examined a different number of positions than owed")
            return
        }
        witness.recordPartitionedRequiredSet(cells: examined, blocked: blocked)
    }

    /// Requirements 12.14 and 12.18, second half: `notExecuted` is unreachable for a position.
    func checkNoOutcomeIsNotExecuted(_ witness: MatrixWitness) {
        witness.recordNotExecutedCheck()
        for scoped in report.configurationReports {
            for cell in scoped.requiredCells
            where scoped.outcome(of: cell).outcome == .notExecuted {
                Issue.record("a required position recorded notExecuted")
                return
            }
        }
        witness.recordNoNotExecutedOutcome()
    }

    /// Each perturbation arm produced the refusal it describes, and the control arm produced none.
    func checkThePerturbedCellProducedTheExpectedRefusal(_ witness: MatrixWitness) {
        witness.recordRefusalCheck()
        guard let scoped = scopedReport else {
            Issue.record("a coverage run always produces at least one configuration report")
            return
        }
        if let cell = perturbedCell {
            let outcome = scoped.outcome(of: cell)
            guard !outcome.isSatisfied else {
                Issue.record("a perturbed position was satisfied")
                return
            }
            guard Self.matches(outcome, shape.perturbation) else {
                Issue.record("a perturbed position produced an unexpected outcome shape")
                return
            }
            // Every other readable position of the same configuration is unaffected, so the refusal
            // is per position rather than per run. A misfiled observation is the one exception: it
            // answers the position it claimed to be, which is another readable one.
            let others = readableCells.filter { $0 != cell }
            guard others.allSatisfy({ scoped.outcome(of: $0).isSatisfied }) else {
                Issue.record("a perturbation refused a position it did not touch")
                return
            }
        } else {
            // The control arm: every position that can be executed was executed and completed.
            // Nothing else in the required set is satisfiable at all, because all 28 localization
            // positions and the handoff-consent and retry positions are blocked.
            guard readableCells.allSatisfy({ scoped.outcome(of: $0).isSatisfied }) else {
                Issue.record("the control arm left an executable position unsatisfied")
                return
            }
            let stragglers = scoped.unsatisfiedCells.filter { readableCells.contains($0) }
            guard stragglers.isEmpty else {
                Issue.record("the control arm left an executable position unsatisfied")
                return
            }
            witness.recordFullyExecutedRun(cells: readableCells.count)
        }
        witness.recordProducedRefusal(shape.perturbation.rawValue)
    }

    /// Whether one outcome is the shape a perturbation describes.
    static func matches(
        _ outcome: AccessibilityMatrixCellOutcome,
        _ perturbation: MatrixPerturbation
    ) -> Bool {
        switch (outcome, perturbation) {
        case let (.resultMissing(gap), .removeObservation):
            return gap.fault == .observationAbsent
        case let (.resultMissing(gap), .unreadable):
            return gap.fault == .observationUnreadable
        case let (.resultMissing(gap), .conditionNotActivatable):
            return gap.fault == .conditionNotActivatable
        case let (.resultMissing(gap), .misfiled):
            return gap.fault == .observationAbsent
        case (.workflowNotCompleted, .nonCompletingCoverage):
            return true
        case let (.nonQualifyingEvidence(reason), .foreignEnvironment):
            if case .notPhysicalIPhone = reason { return true }
            return false
        case let (.nonQualifyingEvidence(reason), .foreignConfiguration):
            if case .configurationMismatch = reason { return true }
            return false
        case (.nonQualifyingEvidence(.versionTupleMismatch), .foreignVersionTuple):
            return true
        case (.automatedEvidenceNotAdmissible, .automatedOnManualPosition):
            return true
        case let (.manualEvidenceNotImported(reason), .authorizationForAnotherCell):
            if case .authorizationIsForAnotherCell = reason { return true }
            return false
        case let (.manualEvidenceNotImported(reason), .rejectedAuthorization):
            if case .authorizationDecisionIsNotApproved = reason { return true }
            return false
        default:
            return false
        }
    }

    /// Requirements 12.14 and 12.18: an unexecuted position lowers the recorded coverage.
    func checkMissingPositionsStayInTheDenominator(_ witness: MatrixWitness) {
        witness.recordDenominatorCheck()
        var requiredTotal = 0
        for scoped in report.configurationReports {
            let required = scoped.requiredCells.count
            let satisfied = scoped.satisfiedCells.count
            guard required == 56 else {
                Issue.record("a configuration owes a different number of positions than 56")
                return
            }
            guard satisfied < required else {
                Issue.record("a host run satisfied every position of a configuration")
                return
            }
            // The denominator is the required count, always. Thirty-six blocked positions alone keep
            // the coverage strictly below one, whatever came back for the other 20.
            guard scoped.recordedCoverage < .one else {
                Issue.record("the recorded coverage read whole over an incomplete matrix")
                return
            }
            for gate in DeviceGate.matrixGates {
                let result = scoped.gateResult(for: gate)
                guard result.cells.count == 28 else {
                    Issue.record("a matrix gate owes a different number of positions than 28")
                    return
                }
                guard result.recordedCoverage < .one else {
                    Issue.record("a gate's recorded coverage read whole over an incomplete matrix")
                    return
                }
            }
            // The localization gate never records a single satisfied position, so its coverage is
            // zero rather than merely low.
            let localization = scoped.gateResult(for: .localizationReadinessMatrix)
            guard localization.recordedCoverage == .zero else {
                Issue.record("the localization gate reported coverage it cannot have")
                return
            }
            requiredTotal += required
        }
        guard requiredTotal > 0 else {
            Issue.record("the run owes no position at all")
            return
        }
        witness.recordDenominatorHeld(requiredPositions: requiredTotal)
    }

    /// Requirement 13.16: this process satisfies no matrix gate.
    func checkEveryGateFailsInThisProcess(_ witness: MatrixWitness) {
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
        for gate in DeviceGate.matrixGates {
            for result in report.perConfigurationGateResults(for: gate) {
                guard result.processRefusal == refusal else {
                    Issue.record("a gate result does not carry the process refusal")
                    return
                }
                // Neither matrix gate is provenance conditional, so `notExecuted` is unreachable and
                // every result is an applicable failure.
                guard result.applicability == .applicable, result.outcome == .failed else {
                    Issue.record("a matrix gate passed in a host process")
                    return
                }
                refused += 1
            }
            guard report.outcome(of: gate) == .failed else {
                Issue.record("a combined matrix gate passed in a host process")
                return
            }
        }
        guard report.outcome == .failed, report.blocksDistribution else {
            Issue.record("a host run reported an overall matrix pass")
            return
        }
        // A gate this module does not record fails rather than passing.
        guard report.outcome(of: .preprocessingParity) == .failed,
            report.outcome(of: .handoffLatency) == .failed
        else {
            Issue.record("a gate this module does not record must not pass")
            return
        }
        guard report.owedInputs.contains(.physicalIPhoneAssistiveRunEnvironment) else {
            Issue.record("a host run does not report that it owes a physical iPhone")
            return
        }
        witness.recordGateRefusal(gateResults: refused)
    }

    /// The second bullet of task 14.4: an unexecuted position cannot become a recorded pass.
    func checkUnexecutedPositionsProduceNoRecordedCell(_ witness: MatrixWitness) {
        witness.recordRecordedCellCheck()
        let identifier = ApprovedConfigurationID("configuration-0001")
        guard let identifier else {
            Issue.record("the synthetic configuration identifier must be canonical")
            return
        }
        var produced = 0
        for scoped in report.configurationReports {
            for cell in scoped.requiredCells {
                let record = scoped.record(of: cell)
                let recorded = try? scoped.recordedCell(of: cell, as: identifier)
                guard let recorded = recorded ?? nil else {
                    // Nothing was recorded, so nothing can be published. The position then lands in
                    // the domain matrix's missing set, which is what Requirements 12.14 and 12.18
                    // block on.
                    guard record.resultReference == nil else {
                        Issue.record("a position with a result reference produced no recorded cell")
                        return
                    }
                    guard !record.outcome.isSatisfied else {
                        Issue.record("a satisfied position produced no recorded cell")
                        return
                    }
                    continue
                }
                guard record.resultReference != nil else {
                    Issue.record("a recorded cell was produced without a result reference")
                    return
                }
                // The recorded outcome is the computed one, so `passed` appears only where the
                // position was actually exercised on qualifying evidence.
                guard recorded.outcome == record.outcome.outcome else {
                    Issue.record("a recorded cell's outcome is not the computed outcome")
                    return
                }
                if recorded.outcome == .passed {
                    guard record.outcome.isSatisfied else {
                        Issue.record("a recorded cell passed without a satisfied position")
                        return
                    }
                }
                guard recorded.key == cell.recordedKey(as: identifier) else {
                    Issue.record("a recorded cell is spelled differently than its position")
                    return
                }
                produced += 1
            }
        }
        // Every blocked position produced nothing, so the produced count can never reach the
        // required count.
        guard produced < binding.requiredCells.count else {
            Issue.record("every position produced a recorded cell, which cannot be")
            return
        }
        witness.recordRecordedCells(produced)
    }

    /// Requirement 12.13: a satisfied manual position carries an imported result and an approval.
    func checkManualPositionsNeedImportedEvidence(_ witness: MatrixWitness) {
        witness.recordManualCheck()
        var checked = 0
        for scoped in report.configurationReports {
            for cell in scoped.requiredCells
            where cell.automationSupport.requiresImportedManualEvidence {
                checked += 1
                guard case let .exercised(agreement) = scoped.outcome(of: cell) else { continue }
                // Both halves, and they are separate documents: the imported human run and the
                // approved decision permitting it at this position.
                guard let authorization = agreement.evidence.manualAuthorization,
                    let imported = agreement.evidence.importedResult
                else {
                    Issue.record("a satisfied manual position carries no imported evidence")
                    return
                }
                guard authorization.isApproved else {
                    Issue.record("a satisfied manual position carries an unapproved decision")
                    return
                }
                guard authorization.source.artifact != imported.artifact,
                    authorization.source.contentDigest != imported.contentDigest
                else {
                    Issue.record("a satisfied manual position cites one record for both")
                    return
                }
            }
            // And no automatable position carries manual evidence it did not need to.
            for cell in scoped.requiredCells where cell.automationSupport.admitsAutomatedEvidence {
                guard case let .exercised(agreement) = scoped.outcome(of: cell) else { continue }
                if agreement.evidence.manualAuthorization != nil {
                    // Permitted: a sound imported pair is admissible anywhere. What is checked is
                    // that the runner recorded which mode answered it rather than discarding that.
                    guard scoped.record(of: cell).execution != nil else {
                        Issue.record("a satisfied position recorded no execution mode")
                        return
                    }
                }
            }
        }
        guard checked == 14 * report.configurationReports.count else {
            Issue.record("the manual-only position count is not 14 per configuration")
            return
        }
        witness.recordManualPositionsChecked(checked)
    }

    /// A position the binding never required is a failure too, not a `nil`.
    func checkAnUnrequestedCellIsAlsoAFailure(_ witness: MatrixWitness) {
        witness.recordProbeCheck()
        guard let scoped = scopedReport else {
            Issue.record("a coverage run always produces at least one configuration report")
            return
        }
        guard let foreignConfiguration = try? Sample.matrixConfiguration(hardware: "iPhone97.1")
        else {
            Issue.record("the synthetic probe configuration must be buildable")
            return
        }
        let probe = AccessibilityMatrixCell(
            workflow: .resultReview,
            exercise: shape.probeExercise,
            configuration: foreignConfiguration
        )
        guard !scoped.requiredCells.contains(probe) else {
            Issue.record("the probe position must be outside the required set")
            return
        }
        let outcome = scoped.outcome(of: probe)
        guard !outcome.isSatisfied, outcome.outcome == .failed else {
            Issue.record("an unrequested position must be a failure")
            return
        }
        guard case let .resultMissing(gap) = outcome, gap.owed == probe.owedReleaseInput else {
            Issue.record("an unrequested position must report what it is owed")
            return
        }
        witness.recordProbeRefusal()
    }
}

// MARK: - The variation witness

/// Counts what the run generated and what it produced, outside the property body.
///
/// `propertyCheck` runs its body under `try?`, so a body that failed before its first assertion
/// reports a passing test in milliseconds with every arm skipped. Two habits close that gap, and both
/// matter:
///
///   * every arm counter is compared against the **case count** rather than against a floor, so a run
///     in which an arm stopped being reached fails even when the absolute number still looks large;
///     and
///   * ``recordCompletedBody()`` is the last thing the body does, so a case that ended early is
///     countable. `completedBodies == cases` alone would pass vacuously as `0 == 0`, which is why the
///     case floor sits beside it.
///
/// The produced sets are the substantive half. Every perturbation arm must actually have produced its
/// refusal, at least one case must actually have supplied a complete completing observation set — the
/// arm that proves the gate refusal is about the process rather than about a position that fell
/// short — and the counted position, blocked-position, recorded-cell, and gate work must have a
/// floor, so a run over a required set that quietly shrank to a handful of positions fails here.
final class MatrixWitness: @unchecked Sendable {
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
    private var recordedCellChecks = 0
    private var recordedCellRuns = 0
    private var manualChecks = 0
    private var manualRuns = 0
    private var probeChecks = 0
    private var probeRefusals = 0

    // Counted work.
    private var examinedCells = 0
    private var blockedPositions = 0
    private var requiredPositions = 0
    private var refusedGateResults = 0
    private var recordedCells = 0
    private var manualPositions = 0
    private var fullyExecutedRuns = 0
    private var fullyExecutedCells = 0

    // Produced outcomes.
    private var refusalKinds: Set<String> = []

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var perturbations: Set<String> = []
    private var coverages: Set<String> = []
    private var foreignEnvironments: Set<String> = []
    private var configurationCounts: Set<Int> = []
    private var secondVersions: Set<String> = []
    private var probeExercises: Set<String> = []
    private var perturbedCellSlots: Set<Int> = []

    fileprivate func record(_ shape: MatrixRunShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        perturbations.insert(shape.perturbation.rawValue)
        coverages.insert("\(shape.nonCompletingCoverage)")
        foreignEnvironments.insert(shape.foreignEnvironment.rawValue)
        configurationCounts.insert(shape.configurationCount)
        secondVersions.insert(shape.secondOSVersion)
        probeExercises.insert(shape.probeExercise.key)
        perturbedCellSlots.insert(shape.cellIndex % 20)
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

    func recordPartitionedRequiredSet(cells: Int, blocked: Int) {
        lock.lock()
        partitionedRequiredSets += 1
        examinedCells += cells
        blockedPositions += blocked
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

    func recordFullyExecutedRun(cells: Int) {
        lock.lock()
        fullyExecutedRuns += 1
        fullyExecutedCells += cells
        lock.unlock()
    }

    func recordDenominatorCheck() {
        lock.lock()
        denominatorChecks += 1
        lock.unlock()
    }

    func recordDenominatorHeld(requiredPositions positions: Int) {
        lock.lock()
        denominatorsHeld += 1
        requiredPositions += positions
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

    func recordRecordedCellCheck() {
        lock.lock()
        recordedCellChecks += 1
        lock.unlock()
    }

    func recordRecordedCells(_ count: Int) {
        lock.lock()
        recordedCellRuns += 1
        recordedCells += count
        lock.unlock()
    }

    func recordManualCheck() {
        lock.lock()
        manualChecks += 1
        lock.unlock()
    }

    func recordManualPositionsChecked(_ count: Int) {
        lock.lock()
        manualRuns += 1
        manualPositions += count
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
        #expect(recordedCellChecks == cases, "recorded-cell checks: \(recordedCellChecks)")
        #expect(manualChecks == cases, "manual-evidence checks: \(manualChecks)")
        #expect(probeChecks == cases, "probe checks: \(probeChecks)")

        // And every arm reached its conclusion, rather than returning early on a guard.
        #expect(
            partitionedRequiredSets == cases,
            "required sets that partitioned cleanly: \(partitionedRequiredSets)"
        )
        #expect(
            noNotExecutedOutcomes == cases,
            "runs free of a notExecuted position outcome: \(noNotExecutedOutcomes)"
        )
        #expect(producedRefusals == cases, "arms that produced their refusal: \(producedRefusals)")
        #expect(denominatorsHeld == cases, "runs whose denominator held: \(denominatorsHeld)")
        #expect(gateRefusals == cases, "runs whose gates all refused: \(gateRefusals)")
        #expect(recordedCellRuns == cases, "runs whose recorded cells checked out: \(recordedCellRuns)")
        #expect(manualRuns == cases, "runs whose manual positions checked out: \(manualRuns)")
        #expect(probeRefusals == cases, "runs whose probe position refused: \(probeRefusals)")

        // Counted work floors. A required set that shrank, a blocked set that emptied, or a gate set
        // that emptied would keep every assertion above true while measuring almost nothing.
        #expect(
            examinedCells >= cases * 56,
            "required positions examined across the run: \(examinedCells)"
        )
        #expect(
            blockedPositions >= cases * 36,
            "positions refused before the seam across the run: \(blockedPositions)"
        )
        #expect(
            requiredPositions >= cases * 56,
            "required positions in the coverage denominator: \(requiredPositions)"
        )
        #expect(
            refusedGateResults >= cases * 2,
            "matrix gate results refused across the run: \(refusedGateResults)"
        )
        #expect(
            recordedCells >= cases * 15,
            "recorded cells produced across the run: \(recordedCells)"
        )
        #expect(
            manualPositions >= cases * 14,
            "manual-only positions checked across the run: \(manualPositions)"
        )

        // The substantive half: the refusals were produced, not merely offered, and at least one case
        // supplied a complete completing observation set whose gates still failed.
        let expectedKinds = Set(MatrixPerturbation.allCases.map { $0.rawValue })
        #expect(
            refusalKinds == expectedKinds,
            "perturbation arms never produced: \(expectedKinds.subtracting(refusalKinds).sorted())"
        )
        #expect(
            fullyExecutedRuns >= 1,
            """
            no case supplied a complete completing observation set, so nothing proved the gate \
            refusal is about the process rather than about a position that fell short
            """
        )
        #expect(
            fullyExecutedCells >= fullyExecutedRuns * 20,
            "executable positions satisfied on a control arm: \(fullyExecutedCells)"
        )

        // The generated baseline actually varied.
        #expect(seeds.count >= 100, "generated seeds: \(seeds.count)")
        #expect(
            perturbations == expectedKinds,
            "generated perturbations: \(perturbations.sorted())"
        )
        #expect(coverages.count == 8, "generated non-completing coverages: \(coverages.count)")
        #expect(
            foreignEnvironments == ["development-mac", "ios-simulator"],
            "generated foreign environments: \(foreignEnvironments.sorted())"
        )
        #expect(configurationCounts == [1, 2], "generated configuration counts")
        #expect(secondVersions == ["18.0.0", "18.1.0"], "generated second candidate versions")
        #expect(
            probeExercises.count == MatrixExercise.required.count,
            "generated probe exercises: \(probeExercises.count)"
        )
        // Sixteen of the 20 readable slots rather than all of them: with 216 cases spread over 20
        // buckets, demanding every bucket would make the assertion depend on the generator's draw
        // order rather than on the property. The floor is high enough that a run confined to a
        // handful of positions still fails.
        #expect(perturbedCellSlots.count >= 16, "generated perturbed positions")
    }
}
