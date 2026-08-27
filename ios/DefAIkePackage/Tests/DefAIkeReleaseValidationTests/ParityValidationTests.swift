import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// The parity runners: what they require, what they refuse, and what a missing result means.
//
// Four suites, split by the question each answers:
//
//   * ``ParityRequiredCellTests`` — the closed required set. Which comparisons a bound plan and
//     catalogue owe, and that a plan which omits one cannot be bound at all.
//   * ``ParityMissingResultTests`` — Requirement 13.19 in the structural form the task asks
//     for: a cell with no result is a failure, is present in the report, and lowers the
//     measured agreement rather than leaving the denominator to whatever came back.
//   * ``ParityComparisonTests`` — the eight comparisons themselves, each exercised against an
//     agreeing and a disagreeing observation.
//   * ``ParityBindingTests`` — the reconciliation refusals, one changed field at a time.
//
// Requirement 13.16 has its own suite, ``ParityPhysicalDeviceGateTests``, because its subject
// is not a comparison result but what a *process* is allowed to conclude.

// MARK: - The closed required set

/// Which comparisons a bound plan and catalogue owe.
@Suite("Parity required cells")
struct ParityRequiredCellTests {

    @Test("The eight required comparisons are exactly the eight the requirements name")
    func requiredComparisonsAreTheEight() throws {
        let binding = try Sample.parityBinding(provenanceApplicable: true)

        #expect(Set(binding.requiredComparisons) == Set(ComparisonMetric.allCases))
        #expect(binding.requiredComparisons.count == 8)
    }

    @Test("A pixel-only release owes the seven unconditional comparisons and no provenance one")
    func pixelOnlyReleaseOwesNoProvenanceComparison() throws {
        let binding = try Sample.parityBinding(provenanceApplicable: false)

        #expect(binding.requiredComparisons.count == 7)
        #expect(!binding.requiredComparisons.contains(.provenanceState))
        #expect(binding.requiredCells(for: .provenanceState).isEmpty)
    }

    @Test("Per-fixture cells come from the fixtures' own approved declarations")
    func perFixtureCellsFollowDeclarations() throws {
        let binding = try Sample.parityBinding(provenanceApplicable: true)
        let suite = binding.catalog.suite

        // Restated independently of the runner: for each comparison whose approved value comes
        // from one expectation kind, the cell count is the number of fixtures declaring it.
        for metric in ComparisonMetric.allCases {
            guard case let .expectationKind(kind) = metric.approvedExpectationSource else {
                continue
            }
            let declaring = suite.fixtures.filter { fixture in
                fixture.expectations.contains { $0.kind == kind }
            }
            #expect(
                binding.requiredCells(for: metric).count == declaring.count,
                "\(metric.rawValue) cell count must match the fixtures declaring \(kind.rawValue)"
            )
        }
    }

    @Test("Rank agreement is one cell over the model-parity family")
    func rankAgreementIsOneFamilyCell() throws {
        let binding = try Sample.parityBinding()
        let cells = binding.requiredCells(for: .rankAgreement)

        #expect(cells.count == 1)
        #expect(cells.first?.subject == .family(.modelParity))
        #expect(cells.first?.subject.fixture == nil)
    }

    @Test("Screenshot geometry is required per physical-screenshot fixture despite no expectation")
    func screenshotGeometryIsRequiredAnyway() throws {
        let binding = try Sample.parityBinding()
        let screenshots = binding.catalog.suite.fixtures(in: .physicalScreenshot)
        let cells = binding.requiredCells(for: .screenshotGeometry)

        #expect(!screenshots.isEmpty)
        #expect(cells.count == screenshots.count)
        #expect(cells.allSatisfy { $0.subject.family == .physicalScreenshot })
        // And no fixture declares an approved value for it, which is the finding.
        let declaresGeometry = binding.catalog.suite.fixtures.contains { fixture in
            fixture.expectations.contains { $0.referenceComparison == .screenshotGeometry }
        }
        #expect(!declaresGeometry)
    }

    @Test("A malformed-input fixture owes no reference comparison")
    func malformedInputOwesNoComparison() throws {
        let binding = try Sample.parityBinding()
        let malformed = binding.catalog.suite.fixtures(in: .malformedInput)

        #expect(!malformed.isEmpty)
        for fixture in malformed {
            let cells = binding.requiredCells.filter { $0.subject.fixture == fixture.id }
            #expect(cells.isEmpty, "\(fixture.id.rawValue) asserts a terminal error, not a parity")
        }
    }

    @Test("The 96 model-parity fixtures each owe a raw logit and a categorical outcome")
    func modelParityFamilyOwesBothComparisons() throws {
        let binding = try Sample.parityBinding()
        let parity = binding.catalog.suite.fixtures(in: .modelParity)

        #expect(parity.count == ReleaseFixtureSuite.requiredModelParityFixtureCount)
        for fixture in parity {
            let cells = Set(
                binding.requiredCells
                    .filter { $0.subject.fixture == fixture.id }
                    .map { $0.comparison }
            )
            #expect(cells == Set<ComparisonMetric>([.rawLogit, .categoricalOutcome]))
        }
    }

    @Test("The required cell set is stably ordered and free of duplicates")
    func requiredCellsAreOrderedAndUnique() throws {
        let binding = try Sample.parityBinding(provenanceApplicable: true)
        let cells = binding.requiredCells

        #expect(Set(cells).count == cells.count)
        let keys = cells.map { $0.orderingKey }
        #expect(keys == keys.sorted())
        // And a second binding over the same inputs enumerates identically.
        let again = try Sample.parityBinding(provenanceApplicable: true)
        #expect(again.requiredCells == cells)
    }

    @Test("Every required cell belongs to at least one parity gate")
    func everyCellBelongsToAGate() throws {
        let binding = try Sample.parityBinding(provenanceApplicable: true)

        for cell in binding.requiredCells {
            let gates = ParityRunReport.gates(for: cell)
            #expect(!gates.isEmpty, "\(cell.description) belongs to no gate")
            #expect(
                gates.allSatisfy { DeviceGate.parityGates.contains($0) },
                "\(cell.description) names a gate outside the parity block"
            )
        }
    }

    @Test("A physical-screenshot preprocessing or logit cell also answers the screenshot gate")
    func screenshotCellsAnswerTwoGates() throws {
        let binding = try Sample.parityBinding()
        let screenshot = try #require(binding.catalog.suite.fixtures(in: .physicalScreenshot).first)
        let subject = ParitySubject.fixture(screenshot.id, family: .physicalScreenshot)

        #expect(
            ParityRunReport.gates(
                for: ParityCell(subject: subject, comparison: .preprocessingOutput)
            ) == Set<DeviceGate>([.preprocessingParity, .screenshotFidelity])
        )
        #expect(
            ParityRunReport.gates(for: ParityCell(subject: subject, comparison: .rawLogit))
                == Set<DeviceGate>([.rawLogitParity, .screenshotFidelity])
        )
    }
}

// MARK: - Missing results

/// A required comparison with no result is a failure, present in the report, in the
/// denominator, and never a pass.
@Suite("Parity missing results")
struct ParityMissingResultTests {

    @Test("An empty observation store fails every required cell and reports every one")
    func emptyStoreFailsEveryCell() throws {
        let binding = try Sample.parityBinding()
        let report = ParityRunner(observations: FakeParityObservationStore.empty(for: binding))
            .run(binding)

        #expect(report.satisfiedCells.isEmpty)
        #expect(report.unsatisfiedCells.count == binding.requiredCells.count)
        #expect(report.outcome == .failed)
        // Present, not absent: every required cell has an outcome and none of them passes.
        for cell in binding.requiredCells {
            let outcome = report.outcome(of: cell)
            #expect(!outcome.isSatisfied, "\(cell.description)")
            #expect(outcome.outcome == .failed, "\(cell.description)")
        }
    }

    @Test("A missing observation is a failure, never a skip and never absent")
    func missingObservationIsAFailure() throws {
        let binding = try Sample.parityBinding()
        let report = ParityRunner(observations: FakeParityObservationStore.empty(for: binding))
            .run(binding)

        // Every cell whose observation the seam is asked for reports the absence by name.
        let asked = binding.requiredCells.filter { $0.comparison != .screenshotGeometry }
        #expect(!asked.isEmpty)
        for cell in asked {
            guard case let .resultMissing(gap) = report.outcome(of: cell) else {
                Issue.record("\(cell.description) did not report a missing result")
                continue
            }
            #expect(gap.fault == .observationAbsent)
            #expect(gap.owed == cell.comparison.owedReleaseInput)
        }
        #expect(report.missingResultCells.count == asked.count)
    }

    @Test("A cell outside the required set is a failure too, not a nil a caller could read")
    func unrequestedCellIsAlsoAFailure() throws {
        let binding = try Sample.parityBinding()
        let report = ParityRunner(observations: FakeParityObservationStore.agreeing(with: binding))
            .run(binding)
        let invented = ParityCell(
            subject: .fixture(Sample.fixture("fixture.not.catalogued"), family: .modelParity),
            comparison: .rawLogit
        )

        #expect(!binding.requiredCells.contains(invented))
        let outcome = report.outcome(of: invented)
        #expect(!outcome.isSatisfied)
        #expect(outcome.outcome == .failed)
        if case let .resultMissing(gap) = outcome {
            #expect(gap.fault == .observationAbsent)
        } else {
            Issue.record("an unrequested cell must report a missing result")
        }
    }

    @Test("No cell outcome can record notExecuted")
    func noCellOutcomeIsNotExecuted() throws {
        // The whole of "a missing result is a failure" in one assertion: the mapping from a
        // cell outcome to a `GateOutcome` has no `notExecuted` in its range, so there is no
        // observation, fault, or absence that produces one.
        let binding = try Sample.parityBinding(provenanceApplicable: true)
        var store = FakeParityObservationStore.agreeing(with: binding)
        // Stage one of every non-agreeing shape the runner can produce.
        let cells = binding.requiredCells
        let logitCell = try #require(cells.first { $0.comparison == .rawLogit })
        let labelCell = try #require(cells.first { $0.comparison == .categoricalOutcome })
        let stateCell = try #require(cells.first { $0.comparison == .provenanceState })
        let digestCell = try #require(cells.first { $0.comparison == .preprocessingOutput })
        store.remove(logitCell)
        store.makeUnreadable(labelCell)
        store.setEnvironment(.iOSSimulator, for: stateCell)
        store.set(.rawLogit(0.5), for: digestCell)

        let report = ParityRunner(observations: store).run(binding)
        for cell in cells {
            #expect(
                report.outcome(of: cell).outcome != .notExecuted,
                "\(cell.description) recorded notExecuted"
            )
        }
    }

    @Test("The compared count is the required count, so a missing cell lowers the agreement")
    func missingCellsStayInTheDenominator() throws {
        let binding = try Sample.parityBinding()
        var store = FakeParityObservationStore.agreeing(with: binding)
        let labelCells = binding.requiredCells(for: .categoricalOutcome)
        #expect(labelCells.count == 96)
        for cell in labelCells.prefix(6) { store.remove(cell) }

        let report = ParityRunner(observations: store).run(binding)
        let record = try #require(
            try report.comparisonRecord(
                for: .categoricalOutcome,
                specification: Sample.evidence("evidence.reference.categorical-outcome")
            )
        )

        #expect(record.comparedFixtureCount.value == 96)
        #expect(record.agreeingFixtureCount.value == 90)
        #expect(record.outcome == .failed)
    }

    @Test("A missing cell fails its gate even when the plan's ratio would tolerate a disagreement")
    func missingCellIsNotCoveredByAnAgreementRatio() throws {
        // A ratio bounds disagreement among comparisons that happened. It does not license a
        // comparison that did not happen, so a 50% ratio still fails on one absent cell.
        let plan = try Sample.parityPlan(agreement: [.retainedBytes: Sample.ratio(0.5)])
        let binding = try Sample.parityBinding(plan: plan)
        var store = FakeParityObservationStore.agreeing(with: binding)
        let cells = binding.requiredCells(for: .retainedBytes)
        #expect(cells.count == 2)
        store.remove(cells[0])

        let report = ParityRunner(observations: store).run(binding)
        let record = try #require(
            try report.comparisonRecord(
                for: .retainedBytes,
                specification: Sample.evidence("evidence.reference.retained-bytes")
            )
        )
        #expect(record.outcome == .failed)
        // And with the same ratio, a *disagreement* on one of the two is tolerated, which is
        // what makes the previous assertion about absence rather than about the ratio.
        var disagreeing = FakeParityObservationStore.agreeing(with: binding)
        disagreeing.set(.retainedBytesDigest(Sample.digest(0x7777)), for: cells[0])
        let tolerated = try #require(
            try ParityRunner(observations: disagreeing).run(binding).comparisonRecord(
                for: .retainedBytes,
                specification: Sample.evidence("evidence.reference.retained-bytes")
            )
        )
        #expect(tolerated.outcome == .passed)
    }

    @Test("An unreadable observation and an unavailable store are both failures")
    func unreadableAndUnavailableAreFailures() throws {
        let binding = try Sample.parityBinding()
        var store = FakeParityObservationStore.agreeing(with: binding)
        let cell = try #require(binding.requiredCells.first { $0.comparison == .rawLogit })
        store.makeUnreadable(cell)

        guard case let .resultMissing(gap) = ParityRunner(observations: store)
            .run(binding)
            .outcome(of: cell)
        else {
            Issue.record("an unreadable observation must report a missing result")
            return
        }
        #expect(gap.fault == .observationUnreadable)

        var unavailable = store
        unavailable.isUnavailable = true
        let report = ParityRunner(observations: unavailable).run(binding)
        #expect(report.satisfiedCells.isEmpty)
        for cell in binding.requiredCells where cell.comparison != .screenshotGeometry {
            guard case let .resultMissing(gap) = report.outcome(of: cell) else {
                Issue.record("\(cell.description) did not report a missing result")
                continue
            }
            #expect(gap.fault == .storeUnavailable)
        }
    }

    @Test("A run reports what it is owed, naming the physical device it does not have")
    func reportEnumeratesOwedInputs() throws {
        let binding = try Sample.parityBinding(provenanceApplicable: true)
        let report = ParityRunner(observations: FakeParityObservationStore.empty(for: binding))
            .run(binding)

        let owed = Set(report.owedInputs)
        #expect(owed.contains(.physicalIPhoneRunEnvironment))
        #expect(owed.contains(.preprocessingReferenceOutputs))
        #expect(owed.contains(.rawLogitReferences))
        #expect(owed.contains(.categoricalOutcomeReferences))
        #expect(owed.contains(.routeByteReferences))
        #expect(owed.contains(.provenanceFixtureExpectations))
        // Declaration order, so two runs report the same list.
        #expect(report.owedInputs == UnprovisionedParityInput.allCases.filter(owed.contains))
    }

    @Test("Standing implementation limits are reported whatever each cell's outcome")
    func standingLimitsAreReportedRegardless() throws {
        let binding = try Sample.parityBinding(provenanceApplicable: true)
        let agreeing = ParityRunner(observations: FakeParityObservationStore.agreeing(with: binding))
            .run(binding)
        let empty = ParityRunner(observations: FakeParityObservationStore.empty(for: binding))
            .run(binding)

        #expect(agreeing.standingLimits == empty.standingLimits)
        #expect(Set(agreeing.standingLimits) == Set(UnobservableParityEvidence.allCases))
    }
}

// MARK: - The eight comparisons

/// Each of the eight comparisons, against an agreeing and a disagreeing observation.
@Suite("Parity comparisons")
struct ParityComparisonTests {

    /// One cell of a metric, with the store agreeing on everything else.
    private func cell(
        _ metric: ComparisonMetric,
        in binding: ParityRunBinding
    ) throws -> ParityCell {
        try #require(binding.requiredCells.first { $0.comparison == metric })
    }

    @Test("A preprocessing-output digest agreement and disagreement are both recorded")
    func preprocessingOutputDigest() throws {
        let binding = try Sample.parityBinding()
        let subject = try cell(.preprocessingOutput, in: binding)
        let store = FakeParityObservationStore.agreeing(with: binding)

        #expect(ParityRunner(observations: store).run(binding).outcome(of: subject).isSatisfied)

        var mutated = store
        mutated.set(.preprocessingOutputDigest(Sample.digest(0x4242)), for: subject)
        guard case let .disagreed(finding) = ParityRunner(observations: mutated)
            .run(binding)
            .outcome(of: subject)
        else {
            Issue.record("a changed preprocessing digest must disagree")
            return
        }
        #expect(finding.detail == .digestMismatch)
        #expect(finding.comparison == .preprocessingOutput)
    }

    @Test("A raw logit inside the plan's tolerance agrees and outside it disagrees")
    func rawLogitTolerance() throws {
        let plan = try Sample.parityPlan(
            rawLogitTolerance: try NumericTolerance(
                kind: .absolute,
                value: Sample.nonNegativeDecimal(Decimal(string: "0.25")!)
            )
        )
        let binding = try Sample.parityBinding(
            plan: plan,
            catalog: try Sample.distinctLogitCatalog()
        )
        let subject = try cell(.rawLogit, in: binding)
        let approved = try #require(
            FakeParityObservationStore.approvedValue(for: subject, in: binding)
        )
        guard case let .rawLogit(value) = approved else {
            Issue.record("the model-parity expectation must be a raw logit")
            return
        }

        var inside = FakeParityObservationStore.agreeing(with: binding)
        inside.set(.rawLogit(value + 0.125), for: subject)
        let insideOutcome = ParityRunner(observations: inside).run(binding).outcome(of: subject)
        #expect(insideOutcome.isSatisfied)
        #expect(insideOutcome.deviation?.value == Decimal(0.125))

        var outside = FakeParityObservationStore.agreeing(with: binding)
        outside.set(.rawLogit(value + 0.5), for: subject)
        guard case let .disagreed(finding) = ParityRunner(observations: outside)
            .run(binding)
            .outcome(of: subject)
        else {
            Issue.record("a logit outside the plan's tolerance must disagree")
            return
        }
        if case let .deviationExceedsTolerance(deviation, tolerance) = finding.detail {
            #expect(deviation.value == Decimal(0.5))
            #expect(tolerance.kind == .absolute)
        } else {
            Issue.record("the finding must name the plan's tolerance")
        }
    }

    @Test("A raw logit inside the plan's tolerance but outside the fixture's still disagrees")
    func fixtureToleranceAlsoBinds() throws {
        // Both are approved values and neither is the runner's to relax. The sample catalogue's
        // model-parity fixtures declare a zero tolerance, so an exactly-equal observation
        // agrees and any deviation the plan would tolerate still fails the fixture's.
        let plan = try Sample.parityPlan(
            rawLogitTolerance: try NumericTolerance(kind: .absolute, value: Sample.nonNegativeDecimal(5))
        )
        let binding = try Sample.parityBinding(plan: plan)
        let subject = try cell(.rawLogit, in: binding)
        var store = FakeParityObservationStore.agreeing(with: binding)

        #expect(ParityRunner(observations: store).run(binding).outcome(of: subject).isSatisfied)

        store.set(.rawLogit(1.75), for: subject)
        guard case let .disagreed(finding) = ParityRunner(observations: store)
            .run(binding)
            .outcome(of: subject)
        else {
            Issue.record("the fixture's own tolerance must bind too")
            return
        }
        if case let .deviationExceedsFixtureTolerance(_, tolerance) = finding.detail {
            #expect(tolerance.value == 0)
        } else {
            Issue.record("the finding must name the fixture's tolerance, not the plan's")
        }
    }

    @Test("A non-finite observed logit disagrees rather than being compared", arguments: [
        Double.nan, .infinity, -.infinity,
    ])
    func nonFiniteLogitDisagrees(observed: Double) throws {
        let binding = try Sample.parityBinding()
        let subject = try cell(.rawLogit, in: binding)
        var store = FakeParityObservationStore.agreeing(with: binding)
        store.set(.rawLogit(observed), for: subject)

        guard case let .disagreed(finding) = ParityRunner(observations: store)
            .run(binding)
            .outcome(of: subject)
        else {
            Issue.record("a non-finite logit must disagree")
            return
        }
        #expect(finding.detail == .nonFiniteObservedLogit)
    }

    @Test("A deviation too large to represent as a decimal disagrees rather than being clamped")
    func unrepresentableDeviationDisagrees() throws {
        let binding = try Sample.parityBinding()
        let subject = try cell(.rawLogit, in: binding)
        var store = FakeParityObservationStore.agreeing(with: binding)
        store.set(.rawLogit(1e300), for: subject)

        guard case let .disagreed(finding) = ParityRunner(observations: store)
            .run(binding)
            .outcome(of: subject)
        else {
            Issue.record("an unrepresentable deviation must disagree")
            return
        }
        if case .deviationNotRepresentable = finding.detail {
        } else {
            Issue.record("the finding must name the unrepresentable deviation")
        }
    }

    @Test("An exact tolerance admits only an equal observation")
    func exactToleranceAdmitsOnlyEquality() throws {
        let plan = try Sample.parityPlan(
            rawLogitTolerance: try NumericTolerance(kind: .exact, value: Sample.nonNegativeDecimal(0))
        )
        let binding = try Sample.parityBinding(
            plan: plan,
            catalog: try Sample.distinctLogitCatalog()
        )
        let subject = try cell(.rawLogit, in: binding)
        var store = FakeParityObservationStore.agreeing(with: binding)

        #expect(ParityRunner(observations: store).run(binding).outcome(of: subject).isSatisfied)

        guard case let .rawLogit(value) = try #require(
            FakeParityObservationStore.approvedValue(for: subject, in: binding)
        ) else {
            Issue.record("the model-parity expectation must be a raw logit")
            return
        }
        store.set(.rawLogit(value.nextUp), for: subject)
        #expect(!ParityRunner(observations: store).run(binding).outcome(of: subject).isSatisfied)
    }

    @Test("Rank agreement is derived from the run's own logits and needs no ordering input")
    func rankAgreementIsDerived() throws {
        let binding = try Sample.parityBinding(catalog: try Sample.distinctLogitCatalog())
        let subject = try cell(.rankAgreement, in: binding)
        let store = FakeParityObservationStore.agreeing(with: binding)

        let outcome = ParityRunner(observations: store).run(binding).outcome(of: subject)
        #expect(outcome.isSatisfied)
        #expect(outcome.deviation?.value == 0)
        // The store holds no rank observation at all: the ordering is not an input.
        #expect(store.values[subject] == nil)
    }

    @Test("A swapped pair of logits is a discordant ordering")
    func swappedLogitsAreDiscordant() throws {
        let binding = try Sample.parityBinding(catalog: try Sample.distinctLogitCatalog())
        let subject = try cell(.rankAgreement, in: binding)
        var store = FakeParityObservationStore.agreeing(with: binding)

        let parity = binding.catalog.suite
            .fixtures(in: .modelParity)
            .sorted { $0.id.rawValue < $1.id.rawValue }
        let first = ParityCell(
            subject: .fixture(parity[0].id, family: .modelParity),
            comparison: .rawLogit
        )
        let second = ParityCell(
            subject: .fixture(parity[1].id, family: .modelParity),
            comparison: .rawLogit
        )
        let firstValue = try #require(store.values[first])
        let secondValue = try #require(store.values[second])
        store.set(secondValue, for: first)
        store.set(firstValue, for: second)

        guard case let .disagreed(finding) = ParityRunner(observations: store)
            .run(binding)
            .outcome(of: subject)
        else {
            Issue.record("a swapped pair must be a discordant ordering")
            return
        }
        if case let .orderingDiscordance(count, _) = finding.detail {
            // Exactly one pair inverted: the two swapped values keep their order against every
            // other fixture, because the swap is adjacent in the approved ordering.
            #expect(count == 1)
        } else {
            Issue.record("the finding must name the discordant pair count")
        }
    }

    @Test("Rank agreement is missing when any contributing logit is missing")
    func rankAgreementNeedsEveryLogit() throws {
        let binding = try Sample.parityBinding(catalog: try Sample.distinctLogitCatalog())
        let subject = try cell(.rankAgreement, in: binding)
        var store = FakeParityObservationStore.agreeing(with: binding)
        let parity = try #require(binding.catalog.suite.fixtures(in: .modelParity).first)
        store.remove(
            ParityCell(
                subject: .fixture(parity.id, family: .modelParity),
                comparison: .rawLogit
            )
        )

        guard case let .resultMissing(gap) = ParityRunner(observations: store)
            .run(binding)
            .outcome(of: subject)
        else {
            Issue.record("one absent logit must make rank agreement missing")
            return
        }
        #expect(gap.owed == .rawLogitReferences)
    }

    @Test("Equal approved logits impose no order, so a tie cannot be discordant")
    func tiedApprovedLogitsAreNotDiscordant() throws {
        // The default sample catalogue gives every model-parity fixture the same approved
        // logit, so every pair is a tie. Observing them in any order is still agreement.
        let binding = try Sample.parityBinding()
        let subject = try cell(.rankAgreement, in: binding)
        var store = FakeParityObservationStore.agreeing(with: binding)
        for (index, fixture) in binding.catalog.suite
            .fixtures(in: .modelParity)
            .sorted(by: { $0.id.rawValue < $1.id.rawValue })
            .enumerated()
        {
            store.set(
                .rawLogit(Double(index)),
                for: ParityCell(
                    subject: .fixture(fixture.id, family: .modelParity),
                    comparison: .rawLogit
                )
            )
        }

        let outcome = ParityRunner(observations: store).run(binding).outcome(of: subject)
        #expect(outcome.isSatisfied)
        #expect(outcome.deviation?.value == 0)
    }

    @Test("A categorical Pixel Evidence mismatch disagrees and names both values")
    func categoricalOutcomeMismatch() throws {
        let binding = try Sample.parityBinding()
        let subject = try cell(.categoricalOutcome, in: binding)
        var store = FakeParityObservationStore.agreeing(with: binding)

        #expect(ParityRunner(observations: store).run(binding).outcome(of: subject).isSatisfied)

        store.set(.pixelLabel(.signalsConsistentWithAIGeneration), for: subject)
        guard case let .disagreed(finding) = ParityRunner(observations: store)
            .run(binding)
            .outcome(of: subject)
        else {
            Issue.record("a different label must disagree")
            return
        }
        #expect(
            finding.detail
                == .categoricalMismatch(
                    expected: PixelLabelKey.noStrongSignalDetected.rawValue,
                    observed: PixelLabelKey.signalsConsistentWithAIGeneration.rawValue
                )
        )
    }

    @Test("Categorical agreement is fixed at 100% and one mismatch fails the gate")
    func categoricalAgreementIsExact() throws {
        let binding = try Sample.parityBinding()
        var store = FakeParityObservationStore.agreeing(with: binding)
        let subject = try cell(.categoricalOutcome, in: binding)
        store.set(.pixelLabel(.notEnoughSignal), for: subject)

        let report = ParityRunner(observations: store).run(binding)
        let record = try #require(
            try report.comparisonRecord(
                for: .categoricalOutcome,
                specification: Sample.evidence("evidence.reference.categorical-outcome")
            )
        )
        #expect(record.comparedFixtureCount.value == 96)
        #expect(record.agreeingFixtureCount.value == 95)
        #expect(record.outcome == .failed)
        #expect(record.maximumDeviation == nil)
    }

    @Test("Retained bytes and preservation status are compared separately on both routes")
    func routeComparisons() throws {
        let binding = try Sample.parityBinding()
        let bytes = binding.requiredCells(for: .retainedBytes)
        let status = binding.requiredCells(for: .bytePreservationStatus)

        let byteFamilies = Set(bytes.map { $0.subject.family })
        let statusFamilies = Set(status.map { $0.subject.family })
        #expect(byteFamilies == Set<FixtureFamily>([.photosPickerRoute, .shareExtensionRoute]))
        #expect(statusFamilies == Set<FixtureFamily>([.photosPickerRoute, .shareExtensionRoute]))

        var store = FakeParityObservationStore.agreeing(with: binding)
        #expect(bytes.allSatisfy {
            ParityRunner(observations: store).run(binding).outcome(of: $0).isSatisfied
        })

        store.set(.bytePreservationStatus(.unknown), for: status[0])
        guard case let .disagreed(finding) = ParityRunner(observations: store)
            .run(binding)
            .outcome(of: status[0])
        else {
            Issue.record("a changed preservation status must disagree")
            return
        }
        #expect(
            finding.detail
                == .categoricalMismatch(
                    expected: BytePreservationStatusKey.originalBytes.rawValue,
                    observed: BytePreservationStatusKey.unknown.rawValue
                )
        )
        // Both comparisons answer the one route gate Requirement 13.10 states.
        #expect(ComparisonMetric.retainedBytes.parityGate == .routeByteParity)
        #expect(ComparisonMetric.bytePreservationStatus.parityGate == .routeByteParity)
    }

    @Test("A provenance state is compared per fixture against its single approved state")
    func provenanceStateComparison() throws {
        let binding = try Sample.parityBinding(provenanceApplicable: true)
        let cells = binding.requiredCells(for: .provenanceState)
        #expect(!cells.isEmpty)
        var store = FakeParityObservationStore.agreeing(with: binding)

        #expect(cells.allSatisfy {
            ParityRunner(observations: store).run(binding).outcome(of: $0).isSatisfied
        })

        let subject = cells[0]
        let approved = try #require(FakeParityObservationStore.approvedValue(for: subject, in: binding))
        guard case let .provenanceState(state) = approved else {
            Issue.record("a provenance fixture must declare a provenance state")
            return
        }
        let other = ProvenanceStateKey.allCases.first { $0 != state }
        store.set(.provenanceState(try #require(other)), for: subject)
        #expect(!ParityRunner(observations: store).run(binding).outcome(of: subject).isSatisfied)
    }

    @Test("Screenshot geometry reports that its approved expected value is unrepresentable")
    func screenshotGeometryIsUnrepresentable() throws {
        let binding = try Sample.parityBinding()
        let subject = try cell(.screenshotGeometry, in: binding)
        let report = ParityRunner(observations: FakeParityObservationStore.agreeing(with: binding))
            .run(binding)

        guard case let .approvedExpectationUnrepresentable(limit) = report.outcome(of: subject)
        else {
            Issue.record("screenshot geometry must report an unrepresentable expected value")
            return
        }
        #expect(limit == .screenshotGeometryHasNoExpectationKind)
        #expect(limit.blocksComparison)
        #expect(report.expectationGapCells.contains(subject))
        // And the gate it belongs to therefore cannot pass, even with everything else agreeing.
        #expect(report.gateResult(for: .screenshotFidelity).outcome == .failed)
    }

    @Test("An observation of the wrong kind is a failure, not a comparison")
    func wrongObservationKindFails() throws {
        let binding = try Sample.parityBinding()
        let subject = try cell(.categoricalOutcome, in: binding)
        var store = FakeParityObservationStore.agreeing(with: binding)
        store.set(.preprocessingOutputDigest(Sample.digest(1)), for: subject)

        guard case let .observationKindMismatch(observed, required) = ParityRunner(observations: store)
            .run(binding)
            .outcome(of: subject)
        else {
            Issue.record("a wrong-kind observation must be a kind mismatch")
            return
        }
        #expect(observed == .preprocessingOutputDigest)
        #expect(required == .pixelLabel)
    }

    @Test("A comparison record exists for every required metric and for no other")
    func comparisonRecordsCoverTheRequiredMetrics() throws {
        let binding = try Sample.parityBinding(provenanceApplicable: true)
        let report = ParityRunner(observations: FakeParityObservationStore.agreeing(with: binding))
            .run(binding)

        for metric in ComparisonMetric.allCases {
            let record = try report.comparisonRecord(
                for: metric,
                specification: Sample.evidence("evidence.reference.\(metric.rawValue)")
            )
            if binding.requiredComparisons.contains(metric) {
                #expect(record != nil, "\(metric.rawValue) is required and has no record")
            } else {
                #expect(record == nil, "\(metric.rawValue) is not required but has a record")
            }
        }
    }

    @Test("A pixel-only run has no provenance comparison record at all")
    func pixelOnlyRunHasNoProvenanceRecord() throws {
        let binding = try Sample.parityBinding(provenanceApplicable: false)
        let report = ParityRunner(observations: FakeParityObservationStore.agreeing(with: binding))
            .run(binding)

        #expect(
            try report.comparisonRecord(
                for: .provenanceState,
                specification: Sample.evidence("evidence.reference.provenance-state")
            ) == nil
        )
        let gate = report.gateResult(for: .provenanceFixtures)
        #expect(!gate.applicability.isApplicable)
        #expect(gate.outcome == .notExecuted)
    }
}

// MARK: - Binding reconciliation

/// The reconciliations a run cannot start without.
@Suite("Parity binding reconciliation")
struct ParityBindingTests {

    private func bindingError(_ build: () throws -> ParityRunBinding) -> ParityBindingError? {
        do {
            _ = try build()
            return nil
        } catch let error as ParityBindingError {
            return error
        } catch {
            Issue.record("an unexpected error escaped the binding")
            return nil
        }
    }

    @Test("A plan that omits rank agreement cannot be bound")
    func planMustDeclareRankAgreement() throws {
        let plan = try Sample.parityPlan(
            comparisons: Sample.allParityComparisons.subtracting([.rankAgreement])
        )
        #expect(
            bindingError { try Sample.parityBinding(plan: plan) }
                == .planComparisonMissing(.rankAgreement)
        )
    }

    @Test("A plan that omits screenshot geometry cannot be bound")
    func planMustDeclareScreenshotGeometry() throws {
        let plan = try Sample.parityPlan(
            comparisons: Sample.allParityComparisons.subtracting([.screenshotGeometry])
        )
        #expect(
            bindingError { try Sample.parityBinding(plan: plan) }
                == .planComparisonMissing(.screenshotGeometry)
        )
    }

    @Test("A plan that omits a comparison the fixtures declare is refused by the catalogue")
    func planMustDeclareDeclaredComparisons() throws {
        let plan = try Sample.parityPlan(
            comparisons: Sample.allParityComparisons.subtracting([.rawLogit])
        )
        guard case let .catalogNotReconcilable(finding) = try #require(
            bindingError { try Sample.parityBinding(plan: plan) }
        ) else {
            Issue.record("the catalogue reconciliation must refuse the plan first")
            return
        }
        #expect(finding == .planComparisonMissing(.rawLogit))
    }

    @Test("A configuration the plan does not enumerate cannot be bound")
    func configurationMustBeAPlanCandidate() throws {
        let other = try Sample.candidateConfiguration(
            hardware: DeviceHardwareID("iPhone99.9")!
        )
        #expect(
            bindingError { try Sample.parityBinding(configuration: other) }
                == .configurationNotInPlan(other.hardwareIdentifier, other.osVersion)
        )
    }

    @Test("A version tuple naming another fixture suite cannot be bound")
    func versionTupleMustNameTheCatalogue() throws {
        let tuple = try Sample.parityVersionTuple(fixtureSuite: "suite.other")
        #expect(
            bindingError { try Sample.parityBinding(versionTuple: tuple) }
                == .versionTupleFixtureSuiteMismatch(
                    expected: Sample.artifact("suite.fixtures"),
                    found: Sample.artifact("suite.other")
                )
        )
    }

    @Test("A version tuple naming another plan cannot be bound")
    func versionTupleMustNameThePlan() throws {
        let tuple = try Sample.parityVersionTuple(validationPlan: "plan.other")
        #expect(
            bindingError { try Sample.parityBinding(versionTuple: tuple) }
                == .versionTuplePlanMismatch(
                    expected: Sample.artifact("plan.device-validation"),
                    found: Sample.artifact("plan.other")
                )
        )
    }

    @Test("A version tuple naming another Model Bundle cannot be bound")
    func versionTupleMustNameTheBundle() throws {
        let other = ModelBundleID("bundle.other")!
        let tuple = try Sample.parityVersionTuple(modelBundle: other)
        #expect(
            bindingError { try Sample.parityBinding(versionTuple: tuple) }
                == .versionTupleModelBundleMismatch(expected: Sample.bundle(), found: other)
        )
    }

    @Test("A version tuple naming another capability manifest cannot be bound")
    func versionTupleMustNameTheManifest() throws {
        let tuple = try Sample.parityVersionTuple(capabilityManifest: "manifest.other")
        #expect(
            bindingError { try Sample.parityBinding(versionTuple: tuple) }
                == .versionTupleCapabilityManifestMismatch(
                    expected: Sample.artifact("manifest.capability"),
                    found: Sample.artifact("manifest.other")
                )
        )
    }

    @Test("A configuration whose application build disagrees with the tuple cannot be bound")
    func configurationBuildMustMatchTheTuple() throws {
        let other = AppBuildID("build.other")!
        let configuration = try Sample.candidateConfiguration(appBuild: other)
        let plan = try Sample.parityPlan()
        // The plan enumerates the sample build, so a differing configuration is refused by the
        // candidate check first; binding the differing build into the *tuple* isolates the
        // build comparison.
        let tuple = try Sample.parityVersionTuple(appBuild: other)
        #expect(
            bindingError {
                try Sample.parityBinding(plan: plan, versionTuple: tuple)
            } == .versionTupleAppBuildMismatch(expected: other, found: Sample.appBuild())
        )
        #expect(configuration.appBuild == other)
    }

    @Test("A catalogue that does not account for all 96 references cannot be bound")
    func modelParityCoverageMustBeComplete() throws {
        // Ninety-five references, consistently: the catalogue itself reconciles, and what
        // fails is the coverage the release gate needs.
        var fixtures = try Sample.parityFixtures(count: 95)
        fixtures += try Sample.nonParityFamilyFixtures()
        let suite = try Sample.suite(fixtures: fixtures)
        let inventory = try ModelParityFixtureInventory(
            id: Sample.artifact("inventory.model-parity"),
            schemaVersion: .v1,
            source: Sample.evidence("evidence.coreml-parity"),
            references: fixtures
                .filter { $0.family == .modelParity }
                .map { ModelParityReference(fixture: $0.id, contentDigest: $0.contentDigest) }
                + [
                    ModelParityReference(
                        fixture: Sample.fixture("fixture.parity.095"),
                        contentDigest: Sample.digest(0x95)
                    )
                ],
            approval: Sample.approval(identifier: "approval.parity-inventory")
        )
        #expect(inventory.references.count == 96)
        // The inventory names a fixture the suite does not catalogue, so the catalogue refuses
        // first — which is itself the coverage gate, one step earlier.
        // The error is already typed, so it is caught without an `as` pattern.
        do {
            _ = try FixtureCatalog(
                suite: suite,
                parityInventory: inventory,
                fusionCoverage: .notApplicable(
                    decision: Sample.approval(identifier: "approval.no-fusion")
                )
            )
            Issue.record("a catalogue missing a referenced fixture must be refused")
        } catch {
            let expected = FixtureCatalogError.parityFixtureNotCatalogued(
                [Sample.fixture("fixture.parity.095")]
            )
            #expect(error == expected)
        }
    }

    @Test("A pixel-only catalogue cannot be bound to a provenance-enabled tuple")
    func capabilitySetMustAgreeWithTheCatalogue() throws {
        let tuple = try Sample.parityVersionTuple(provenanceEnabled: true)
        guard case let .catalogNotReconcilable(finding) = try #require(
            bindingError {
                try ParityRunBinding(
                    plan: try Sample.parityPlan(),
                    catalog: try Sample.catalog(provenanceApplicable: false),
                    configuration: try Sample.candidateConfiguration(),
                    versionTuple: tuple
                )
            }
        ) else {
            Issue.record("the capability reconciliation must refuse the binding")
            return
        }
        #expect(
            finding
                == .provenanceApplicabilityMismatch(suiteApplicable: false, capabilityEnabled: true)
        )
    }

    @Test("A bound run states its provenance applicability from the catalogued suite")
    func bindingReportsProvenanceApplicability() throws {
        #expect(try Sample.parityBinding(provenanceApplicable: true).provenanceApplicability
            .isApplicable)
        #expect(
            !(try Sample.parityBinding(provenanceApplicable: false).provenanceApplicability
                .isApplicable)
        )
    }
}
