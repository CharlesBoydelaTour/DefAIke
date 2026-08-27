import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// What a bulk ingestion is allowed to retain, to count, and to conclude.
//
// Three questions, each spanning all four runners rather than sitting inside one of them:
//
//   * **Retention.** A pass keeps the number it measured beside it, so a later tolerance or
//     limit change is auditable against what actually happened rather than against the word
//     "within".
//   * **Denominators.** A missing result is a failure *and* it lowers the statistic. The
//     interesting half is the denominator: an approved sample count, agreement ratio, or
//     coverage target must never license a measurement that did not happen.
//   * **Where the results came from.** Development-Mac and simulator readings are classified
//     rather than discarded, and no caller — inside this process or outside the module — can
//     turn one into a satisfied gate.
//
// **No number, identifier, tolerance, limit, sample count, agreement ratio, configuration, or
// version tuple anywhere in this file is an approved release value.** There is no approved
// `DeviceValidationPlan`, no signed `ReleaseFixtureSuite`, none of the 96 model-parity
// fixtures, and no physical iPhone. Every device gate in this repository is unsatisfiable, and
// that is the correct reported state.

// MARK: - Raw value retention

/// What a recorded result keeps beside its conclusion.
@Suite("Device result ingestion: raw values are retained beside the conclusion")
struct DeviceResultIngestionRetentionTests {

    @Test("A passing raw-logit comparison retains the deviation it measured")
    func aPassRetainsItsDeviation() throws {
        let binding = try Sample.parityBinding(catalog: try Sample.distinctLogitCatalog())
        var store = FakeParityObservationStore.agreeing(with: binding)

        let cell = try #require(binding.requiredCells(for: .rawLogit).first)
        let fixtureID = try #require(cell.subject.fixture)
        let fixture = try #require(
            binding.catalog.suite.fixtures.first { $0.id == fixtureID }
        )
        let declared = try #require(fixture.expectations.first { $0.kind == .rawLogit })
        guard case let .rawLogit(approved, fixtureTolerance) = declared else {
            Issue.record("a model-parity fixture declares an approved raw logit")
            return
        }
        // One whole unit of drift: inside the plan's approved absolute tolerance and inside the
        // fixture's own, so the comparison agrees and still has a number to report.
        store.set(.rawLogit(approved + 1), for: cell)

        let report = ParityRunner(observations: store).run(binding)
        guard case let .agreed(agreement) = report.outcome(of: cell) else {
            Issue.record("a deviation inside both approved tolerances must agree")
            return
        }
        let deviation = try #require(agreement.deviation)
        #expect(deviation.value > 0)
        #expect(deviation.value == Decimal(1))
        #expect(deviation.value <= fixtureTolerance.value)

        // The cell's own projection reports the same measured number rather than "within
        // tolerance", and it travels into the domain comparison record.
        let projected = try #require(report.outcome(of: cell).deviation)
        #expect(projected == deviation)
        let record = try #require(
            try report.comparisonRecord(
                for: .rawLogit,
                specification: Sample.evidence("evidence.reference.raw-logit")
            )
        )
        let maximum = try #require(record.maximumDeviation)
        #expect(maximum.value == Decimal(1))
    }

    @Test("A resource measurement retains its whole raw series beside the pass")
    func aMeasurementRetainsItsRawSeries() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        let report = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.complete(for: binding)
        ).run(binding)

        let cell = try #require(binding.requiredCells.first { $0.metric == .peakResidentMemory })
        let record = report.record(of: cell)
        #expect(record.outcome.isSatisfied)

        // Every sample, in the order the declared series asked for them, not replaced by the
        // summary (Requirement 11.19 keeps raw values and the pass decision apart).
        let magnitudes = record.summary.rawValues.compactMap { $0.magnitude }
        #expect(magnitudes == [10, 11, 12, 13, 14])
        #expect(record.summary.summaryStatistic == SummaryStatistic.median)
        #expect(record.summary.summaryValue == ObservedResourceValue.quantity(12, unit: .bytes))
        #expect(record.limit != nil)

        let domainRecord = try #require(
            try report.measurementRecord(
                of: cell,
                specification: Sample.evidence("evidence.spec.peak-resident-memory")
            )
        )
        #expect(domainRecord.rawValues == [10, 11, 12, 13, 14])
        #expect(domainRecord.summaryValue == 12)
        #expect(domainRecord.outcome == .passed)
        #expect(domainRecord.target == .mainApplication)
    }

    @Test("An exceeded measurement retains the value that exceeded the limit")
    func anExceedanceRetainsItsValue() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        var store = FakeResourceSampleStore.complete(for: binding)
        let cell = try #require(binding.requiredCells.first { $0.metric == .peakResidentMemory })
        store.setValueEverywhere(.quantity(1_000, unit: .bytes), for: cell)

        let report = ResourceMeasurementRunner(samples: store).run(binding)
        let record = report.record(of: cell)
        guard case let .exceededLimit(exceedance) = record.outcome else {
            Issue.record("a magnitude above the approved ceiling must exceed its limit")
            return
        }
        #expect(exceedance.summaryValue == ObservedResourceValue.quantity(1_000, unit: .bytes))
        guard case let .magnitudeExceedsLimit(summary, ceiling, unit) = exceedance.detail else {
            Issue.record("a numeric exceedance names the summary, the ceiling, and the unit")
            return
        }
        #expect(summary == 1_000)
        #expect(ceiling == 100)
        #expect(unit == ResourceLimitUnit.bytes)

        // The failure keeps its series too, so a later limit change is auditable against it.
        #expect(record.summary.rawValues.count == 5)
        let domainRecord = try #require(
            try report.measurementRecord(
                of: cell,
                specification: Sample.evidence("evidence.spec.peak-resident-memory")
            )
        )
        #expect(domainRecord.rawValues.count == 5)
        #expect(domainRecord.outcome == .failed)
    }

    @Test("A thermal series is retained here and cannot be recorded in a MeasurementRecord")
    func thermalSeriesIsNotRepresentableInTheDomainRecord() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        let report = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.complete(for: binding)
        ).run(binding)

        let cell = try #require(binding.requiredCells.first { $0.metric == .thermalState })
        let record = report.record(of: cell)
        #expect(record.outcome.isSatisfied)

        // The module keeps the whole categorical series.
        #expect(record.summary.rawValues.count == 5)
        let states = record.summary.rawValues.compactMap { $0.state }
        #expect(states.count == 5)
        #expect(record.summary.summaryValue == ObservedResourceValue.thermalState(.nominal))

        // Known gap, reported not worked around: `MeasurementRecord.rawValues` is `[Decimal]`,
        // so a thermal series cannot be recorded at all without encoding severity ordinals no
        // artifact approved. The record is `nil` and the finding is named beside the cell.
        let domainRecord = try report.measurementRecord(
            of: cell,
            specification: Sample.evidence("evidence.spec.thermal-state")
        )
        #expect(domainRecord == nil)
        let carriesFinding = record.standingLimits
            .contains(.thermalSamplesNotRepresentableInMeasurementRecord)
        #expect(carriesFinding)
        let reported = report.standingLimits
        #expect(reported.contains(.thermalSamplesNotRepresentableInMeasurementRecord))
    }

    @Test("A matrix position retains what was observed beside the conclusion drawn from it")
    func aMatrixPositionRetainsItsObservation() throws {
        let binding = try Sample.matrixBinding()
        var store = FakeMatrixObservationStore.complete(for: binding)
        let subject = try #require(
            Sample.readableCells(of: binding).first {
                $0.exercise == .assistive(.largestDynamicType)
            }
        )
        store.setCoverage(.layoutNotReadable, for: subject)

        let report = AccessibilityMatrixRunner(observations: store).run(binding)
        let record = report.record(of: subject)
        #expect(record.coverage == ObservedWorkflowCoverage.layoutNotReadable)
        #expect(record.execution != nil)
        #expect(record.resultReference != nil)

        // The conclusion names the observation rather than replacing it with a bare failure.
        guard case let .workflowNotCompleted(coverage) = record.outcome else {
            Issue.record("a clipped layout must be recorded as a workflow that did not complete")
            return
        }
        #expect(coverage == .layoutNotReadable)
        #expect(record.outcome.wasExecuted)
        #expect(!record.outcome.isSatisfied)
    }
}

// MARK: - Denominators

/// A missing result lowers the statistic. The denominator is the plan's, not what came back.
@Suite("Device result ingestion: a missing result lowers the statistic")
struct DeviceResultIngestionDenominatorTests {

    @Test("A run that compared 90 of 96 fixtures reports 90 of 96, not 90 of 90")
    func aMissingComparisonStaysInTheDenominator() throws {
        let binding = try Sample.parityBinding()
        let categorical = binding.requiredCells(for: .categoricalOutcome)
        #expect(categorical.count == 96)

        var store = FakeParityObservationStore.agreeing(with: binding)
        let dropped = Array(categorical.prefix(6))
        for cell in dropped { store.remove(cell) }

        let report = ParityRunner(observations: store).run(binding)
        let record = try #require(
            try report.comparisonRecord(
                for: .categoricalOutcome,
                specification: Sample.evidence("evidence.reference.categorical-outcome")
            )
        )
        // The denominator is the required cell count, so the six that produced nothing lower the
        // measured agreement instead of leaving it to be computed over whatever came back.
        #expect(record.comparedFixtureCount.value == 96)
        #expect(record.agreeingFixtureCount.value == 90)
        #expect(record.outcome == .failed)
        #expect(report.missingResultCells.count == 6)
        #expect(report.gateResult(for: .categoricalAgreement).outcome == .failed)
        let owed = report.owedInputs
        #expect(owed.contains(.categoricalOutcomeReferences))

        // Requirement 13.8 asks for 100% categorical agreement, and the plan schema pins the
        // ratio for this one metric rather than leaving it to a release to declare — so there is
        // no relaxed ratio here that a missing comparison could hide behind.
        #expect(throws: ArtifactSchemaError.self) {
            _ = try ComparisonSpecification(
                metric: .categoricalOutcome,
                reference: Sample.evidence("evidence.reference.categorical-outcome"),
                tolerance: nil,
                requiredAgreement: Sample.ratio(Decimal(1) / Decimal(2))
            )
        }
    }

    @Test("An approved agreement ratio bounds disagreement and never licenses an absence")
    func anApprovedRatioNeverLicensesAnAbsence() throws {
        // The provenance-state comparison is the categorical metric whose ratio a release *can*
        // declare below one, so it is where the contrast between "compared and disagreed" and
        // "never compared" is observable at all.
        let plan = try Sample.parityPlan(
            agreement: [.provenanceState: Sample.ratio(Decimal(1) / Decimal(2))]
        )
        let binding = try Sample.parityBinding(provenanceApplicable: true, plan: plan)
        let provenance = binding.requiredCells(for: .provenanceState)
        #expect(provenance.count == 16)
        let specification = Sample.evidence("evidence.reference.provenance-state")

        // Six comparisons that happened and disagreed: 10 of 16 agree, which clears the approved
        // ratio, and the comparison passes.
        var disagreeing = FakeParityObservationStore.agreeing(with: binding)
        for cell in provenance.prefix(6) {
            let approved = try #require(Self.approvedProvenanceState(of: cell, in: binding))
            let other = try #require(ProvenanceStateKey.allCases.first { $0 != approved })
            disagreeing.set(.provenanceState(other), for: cell)
        }
        let disagreed = ParityRunner(observations: disagreeing).run(binding)
        let disagreedRecord = try #require(
            try disagreed.comparisonRecord(for: .provenanceState, specification: specification)
        )
        #expect(disagreedRecord.comparedFixtureCount.value == 16)
        #expect(disagreedRecord.agreeingFixtureCount.value == 10)
        #expect(disagreedRecord.outcome == .passed)
        #expect(disagreed.missingResultCells.isEmpty)

        // Six comparisons that did not happen: the same two counts, and the opposite conclusion.
        // A ratio bounds disagreement among comparisons that were made; it does not license one
        // that was not.
        var missing = FakeParityObservationStore.agreeing(with: binding)
        for cell in provenance.prefix(6) { missing.remove(cell) }
        let absent = ParityRunner(observations: missing).run(binding)
        let absentRecord = try #require(
            try absent.comparisonRecord(for: .provenanceState, specification: specification)
        )
        #expect(absentRecord.comparedFixtureCount.value == 16)
        #expect(absentRecord.agreeingFixtureCount.value == 10)
        #expect(absentRecord.outcome == .failed)
        #expect(absent.missingResultCells.count == 6)
    }

    /// The approved provenance state one cell's fixture declares.
    static func approvedProvenanceState(
        of cell: ParityCell,
        in binding: ParityRunBinding
    ) -> ProvenanceStateKey? {
        guard let fixtureID = cell.subject.fixture,
            let fixture = binding.catalog.suite.fixtures.first(where: { $0.id == fixtureID })
        else {
            return nil
        }
        for expectation in fixture.expectations {
            if case let .provenanceState(state) = expectation { return state }
        }
        return nil
    }

    @Test("A short sample series keeps the plan's declared count in the denominator")
    func aShortSeriesKeepsTheDeclaredDenominator() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        let cell = try #require(binding.requiredCells.first { $0.metric == .peakResidentMemory })
        let declared = binding.declaredSampleCount(for: cell)
        #expect(declared == 5)

        var store = FakeResourceSampleStore.complete(for: binding)
        store.truncateSeries(cell, keeping: 3)

        let report = ResourceMeasurementRunner(samples: store).run(binding)
        let record = report.record(of: cell)
        #expect(record.summary.declaredSampleCount == 5)
        #expect(record.summary.qualifyingSampleCount == 3)
        #expect(!record.summary.isComplete)
        #expect(record.summary.completeness == Sample.ratio(Decimal(3) / Decimal(5)))

        // Every sample that came back qualified, and the measurement still fails: an approved
        // sample count is not a floor a run may undershoot.
        guard case let .sampleCountIncomplete(observed, reported) = record.outcome else {
            Issue.record("a short series must fail as an incomplete sample count")
            return
        }
        #expect(observed == 3)
        #expect(reported == 5)
        #expect(record.summary.rawValues.count == 3)

        // The gate-level statistic is over the plan's declared total for this gate's cells.
        let gate = report.gateResult(for: .mainApplicationPeakMemory)
        #expect(gate.cells == [cell])
        #expect(gate.outcome == .failed)
        #expect(gate.measuredCompleteness == Sample.ratio(Decimal(3) / Decimal(5)))
    }

    @Test("A target's completeness is over every required cell's declared count")
    func targetCompletenessIsOverEveryRequiredCell() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        let complete = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.complete(for: binding)
        ).run(binding)

        // Three of nine main-application cells have a measurement path at all, so the declared
        // total is 15: the other six are refused before the seam and declare no series.
        let readable = Sample.readableCells(of: binding)
        let blocked = Sample.blockedCells(of: binding)
        #expect(readable.count == 3)
        #expect(blocked.count == 6)
        #expect(binding.requiredCells.count == 9)
        #expect(complete.measuredCompleteness == .one)

        var store = FakeResourceSampleStore.complete(for: binding)
        let cell = try #require(readable.first { $0.metric == .peakResidentMemory })
        store.truncateSeries(cell, keeping: 3)
        let short = ResourceMeasurementRunner(samples: store).run(binding)
        #expect(short.measuredCompleteness == Sample.ratio(Decimal(13) / Decimal(15)))
        #expect(short.measuredCompleteness != .one)
    }

    @Test("A configuration reports 20 of 56 positions and the localization gate reports none")
    func matrixCoverageIsOverTheRequiredPositionCount() throws {
        let binding = try Sample.matrixBinding()
        let report = AccessibilityMatrixRunner(
            observations: FakeMatrixObservationStore.complete(for: binding)
        ).run(binding)

        // Fifty-six required positions, twenty of which anything in this repository can exercise.
        #expect(report.requiredCells.count == 56)
        #expect(report.satisfiedCells.count == 20)
        #expect(report.recordedCoverage == Sample.ratio(Decimal(20) / Decimal(56)))

        let accessibility = report.gateResult(for: .accessibilityMatrix)
        #expect(accessibility.cells.count == 28)
        #expect(accessibility.recordedCoverage == Sample.ratio(Decimal(20) / Decimal(28)))
        #expect(accessibility.outcome == .failed)

        // The localization gate reports zero of 28: substituting a readiness catalog replaces no
        // rendered string, so not one of its positions can be exercised.
        let localization = report.gateResult(for: .localizationReadinessMatrix)
        #expect(localization.cells.count == 28)
        #expect(localization.recordedCoverage == .zero)
        #expect(localization.outcome == .failed)
        #expect(report.unsatisfiedCells.count == 36)
    }

    @Test("An unexecuted position produces no recorded matrix cell, so it cannot be a pass")
    func unexecutedPositionsShrinkTheProducedMatrix() throws {
        let binding = try Sample.matrixBinding()
        let identifier = ApprovedConfigurationID("configuration-0001")!
        let report = AccessibilityMatrixRunner(
            observations: FakeMatrixObservationStore.complete(for: binding)
        ).run(binding)

        let produced = try report.recordedCells(as: identifier)
        // Shorter than the required set exactly when the run was incomplete, so the missing
        // positions land in the matrix artifact's missing-cell set rather than anywhere else.
        #expect(produced.count == 20)
        #expect(produced.count < report.requiredCells.count)
        let outcomes = Set(produced.map(\.outcome))
        #expect(outcomes == [GateOutcome.passed])
    }

    @Test("An empty ingestion reports every required cell as a failure, not an empty report")
    func anEmptyIngestionReportsEveryCellAsAFailure() throws {
        let parityBinding = try Sample.parityBinding()
        let parityReport = ParityRunner(
            observations: FakeParityObservationStore.empty(for: parityBinding)
        ).run(parityBinding)
        #expect(parityReport.satisfiedCells.isEmpty)
        #expect(parityReport.requiredCells.count == parityBinding.requiredCells.count)
        var parityNotExecuted = 0
        for cell in parityBinding.requiredCells
        where parityReport.outcome(of: cell).outcome == .notExecuted {
            parityNotExecuted += 1
        }
        #expect(parityNotExecuted == 0)

        let resourceBinding = try Sample.resourceRunBinding()
        let resourceReport = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.empty(for: resourceBinding.mainApplication)
        ).run(resourceBinding)
        #expect(resourceReport.mainApplication.satisfiedCells.isEmpty)
        #expect(resourceReport.shareExtension.satisfiedCells.isEmpty)
        #expect(resourceReport.mainApplication.measuredCompleteness == .zero)

        let matrixBinding = try Sample.matrixBinding()
        let matrixReport = AccessibilityMatrixRunner(
            observations: FakeMatrixObservationStore.empty(for: matrixBinding)
        ).run(matrixBinding)
        #expect(matrixReport.satisfiedCells.isEmpty)
        #expect(matrixReport.recordedCoverage == .zero)
        #expect(matrixReport.unsatisfiedCells.count == 56)
    }
}

// MARK: - Where the results came from

/// Requirement 13.16 across the whole ingestion: rejection, and classification of what is
/// rejected.
@Suite("Device result ingestion: Mac and simulator evidence")
struct DeviceResultIngestionEnvironmentTests {

    // MARK: The whole ingestion, contradicted

    @Test("One full ingestion satisfies cells, satisfies no gate, and names why")
    func aFullIngestionSatisfiesCellsAndNoGates() throws {
        let parityBinding = try Sample.parityBinding()
        var parityStore = FakeParityObservationStore.agreeing(with: parityBinding)
        parityStore.setEnvironmentEverywhere(.physicalIPhone)
        let parityReport = ParityRunner(observations: parityStore).run(parityBinding)

        let resourceBinding = try Sample.resourceRunBinding()
        var resourceStore = FakeResourceSampleStore.complete(for: resourceBinding)
        resourceStore.setEnvironmentEverywhere(.physicalIPhone)
        let resourceReport = ResourceMeasurementRunner(samples: resourceStore).run(resourceBinding)

        let matrixBinding = try Sample.matrixCoverageBinding()
        var matrixStore = FakeMatrixObservationStore.complete(for: matrixBinding)
        matrixStore.setEnvironmentEverywhere(.physicalIPhone)
        let matrixReport = AccessibilityMatrixRunner(observations: matrixStore).run(matrixBinding)

        // Every observation in the ingestion claims a physical iPhone, and cells pass on it.
        #expect(!parityReport.satisfiedCells.isEmpty)
        #expect(!resourceReport.mainApplication.satisfiedCells.isEmpty)
        #expect(!resourceReport.shareExtension.satisfiedCells.isEmpty)
        #expect(!matrixReport.satisfiedCells.isEmpty)

        // Not one gate passes, because a gate is a conclusion *this process* draws and this
        // process is not a phone.
        var passing: [String] = []
        for gate in DeviceGate.parityGates
        where parityReport.gateResult(for: gate).outcome == .passed {
            passing.append(gate.rawValue)
        }
        for gate in DeviceGate.resourceGates where resourceReport.outcome(of: gate) == .passed {
            passing.append(gate.rawValue)
        }
        for gate in DeviceGate.matrixGates where matrixReport.outcome(of: gate) == .passed {
            passing.append(gate.rawValue)
        }
        #expect(passing.isEmpty)

        // And the three gate sets together are every mandatory gate, so the ingestion leaves
        // none satisfied and none unaccounted for.
        let covered = Set(
            DeviceGate.parityGates + DeviceGate.resourceGates + DeviceGate.matrixGates
        )
        #expect(covered == DeviceGate.mandatoryGates)
        #expect(covered.count == 22)

        // Each report names the refusal rather than leaving a bare failure to be interpreted.
        let refusal = NonQualifyingParityEvidence.notPhysicalIPhone(ObservedParityEnvironment.current)
        #expect(parityReport.processRefusal == refusal)
        #expect(resourceReport.processRefusal == refusal)
        #expect(matrixReport.processRefusal == refusal)
        #expect(!ObservedParityEnvironment.canProducePhysicalDeviceEvidence)
        #expect(matrixReport.blocksDistribution)
    }

    @Test("Every recorded run environment is this process, whatever the observations claimed")
    func recordedEnvironmentIsAlwaysThisProcess() throws {
        let parityBinding = try Sample.parityBinding()
        var parityStore = FakeParityObservationStore.agreeing(with: parityBinding)
        parityStore.setEnvironmentEverywhere(.physicalIPhone)
        let parityReport = ParityRunner(observations: parityStore).run(parityBinding)

        let resourceBinding = try Sample.resourceRunBinding()
        var resourceStore = FakeResourceSampleStore.complete(for: resourceBinding)
        resourceStore.setEnvironmentEverywhere(.physicalIPhone)
        let resourceReport = ResourceMeasurementRunner(samples: resourceStore).run(resourceBinding)

        let matrixBinding = try Sample.matrixBinding()
        var matrixStore = FakeMatrixObservationStore.complete(for: matrixBinding)
        matrixStore.setEnvironmentEverywhere(.physicalIPhone)
        let matrixReport = AccessibilityMatrixRunner(observations: matrixStore).run(matrixBinding)

        let observed = ObservedParityEnvironment.current
        #expect(parityReport.runEnvironment == observed)
        #expect(resourceReport.runEnvironment == observed)
        #expect(matrixReport.runEnvironment == observed)
        #expect(observed != .physicalIPhone)
    }

    // MARK: Development-Mac results are classified, not discarded

    @Test("A development-Mac timing series is retained, summarized, and classified")
    func developmentMacTimingIsClassifiedRatherThanDiscarded() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        var store = FakeResourceSampleStore.complete(for: binding)
        store.setEnvironmentEverywhere(.developmentMac)

        let report = ResourceMeasurementRunner(samples: store).run(binding)
        let cell = try #require(binding.requiredCells.first { $0.metric == .peakResidentMemory })
        let record = report.record(of: cell)

        // Requirement 13.16 asks for M3 Pro timing to be *classified* as development evidence,
        // not discarded. The whole series survives, with the declared statistic over it.
        #expect(record.summary.rawValues.count == binding.declaredSampleCount(for: cell))
        #expect(record.summary.summaryValue == ObservedResourceValue.quantity(12, unit: .bytes))
        #expect(record.limit != nil)

        // And it is classified by the environment it came from rather than reported as absent.
        guard case let .nonQualifyingEvidence(reason) = record.outcome else {
            Issue.record("a development-Mac series must be refused by environment, not dropped")
            return
        }
        #expect(reason == .notPhysicalIPhone(.developmentMac))
        #expect(!record.outcome.isSatisfied)
        #expect(!record.outcome.wasMeasured)
        let owed = report.owedInputs
        #expect(owed.contains(.physicalIPhoneMeasurementEnvironment))

        // Finding, pinned not fixed: `ResourceMeasurementSummary.qualifyingSampleCount` counts
        // samples that came back, not samples that qualified, so an entirely non-qualifying
        // series still reads complete. No false pass results — the outcome refuses it — but the
        // completeness statistic overstates what qualified.
        #expect(record.summary.qualifyingSampleCount == 5)
        #expect(record.summary.isComplete)
        #expect(record.summary.completeness == .one)
    }

    @Test("A development-Mac parity observation is recorded and named, not dropped")
    func developmentMacParityObservationIsNamed() throws {
        let binding = try Sample.parityBinding()
        var store = FakeParityObservationStore.agreeing(with: binding)
        store.setEnvironmentEverywhere(.developmentMac)

        let report = ParityRunner(observations: store).run(binding)
        let compared = binding.requiredCells.filter { $0.comparison != .screenshotGeometry }
        #expect(!compared.isEmpty)
        #expect(report.nonQualifyingCells.count == compared.count)
        #expect(report.satisfiedCells.isEmpty)

        // The cells are still in the required set and still reported one at a time; a Mac run
        // does not shrink the ingestion.
        #expect(report.requiredCells.count == binding.requiredCells.count)
        let subject = try #require(compared.first)
        guard case let .nonQualifyingEvidence(reason) = report.outcome(of: subject) else {
            Issue.record("a development-Mac observation must be refused by environment")
            return
        }
        #expect(reason == .notPhysicalIPhone(.developmentMac))
    }

    @Test("A development-Mac gate result is recordable as a failure and unrepresentable as a pass")
    func developmentMacGateResultIsRecordableOnlyAsAFailure() throws {
        let result = Sample.evidence("evidence.m3-pro-timing")
        let recorded = try GateResultReference(
            gate: .warmAnalysisLatency,
            applicability: .applicable,
            outcome: .failed,
            result: result,
            environment: .developmentMac
        )
        // Representable, so the development measurement is classified rather than unrecordable.
        #expect(recorded.environment == .developmentMac)
        #expect(!recorded.isSatisfied)

        // And rejected at exactly the point where it would become release evidence.
        #expect(throws: ArtifactSchemaError.self) {
            _ = try GateResultReference(
                gate: .warmAnalysisLatency,
                applicability: .applicable,
                outcome: .passed,
                result: result,
                environment: .developmentMac
            )
        }
        for environment in [ExecutionEnvironment.iOSSimulator, .developmentMac] {
            #expect(throws: ArtifactSchemaError.self) {
                _ = try GateResultReference(
                    gate: .categoricalAgreement,
                    applicability: .applicable,
                    outcome: .passed,
                    result: result,
                    environment: environment
                )
            }
        }
    }

    @Test("A known defect: an entry whose every gate is inapplicable reports itself satisfied")
    func inapplicableGateEvidenceReportsItselfSatisfied() throws {
        let tuple = try Sample.parityVersionTuple()
        let configuration = try Sample.candidateConfiguration()
        let result = Sample.evidence("evidence.nothing-ran")
        let evidence = try DeviceGate.mandatoryGates
            .sorted { $0.rawValue < $1.rawValue }
            .map { gate in
                try GateResultReference(
                    gate: gate,
                    applicability: Sample.notApplicable(),
                    outcome: .notExecuted,
                    result: result,
                    environment: .developmentMac
                )
            }
        let entry = try ApprovedDeviceConfiguration(
            id: ApprovedConfigurationID("configuration-0001")!,
            configuration: configuration,
            versionTuple: tuple,
            gateEvidence: evidence
        )

        // Pinned so it stays visible, not fixed here: `GateResultReference.isSatisfied` answers
        // `decision.isApproved` for a `notApplicable` gate, so an entry in which nothing ran, on
        // any device, reports no unsatisfied gate at all. Nothing in DefAIkeReleaseValidation
        // consults it — the four runners compute every outcome from cells.
        #expect(entry.unsatisfiedGates.isEmpty)
        let outcomes = Set(evidence.map(\.outcome))
        #expect(outcomes == [GateOutcome.notExecuted])
        let environments = Set(evidence.map(\.environment))
        #expect(environments == [ExecutionEnvironment.developmentMac])
    }

    // MARK: No caller can manufacture qualifying evidence

    @Test("The only initialiser of qualifying parity evidence refuses every non-physical claim")
    func qualifyingParityEvidenceRefusesEveryNonPhysicalClaim() throws {
        let binding = try Sample.parityBinding()
        let cell = try #require(binding.requiredCells(for: .categoricalOutcome).first)
        func observation(
            environment: ExecutionEnvironment,
            configuration: CandidateDeviceConfiguration,
            versionTuple: ValidationVersionTuple
        ) -> ParityObservation {
            ParityObservation(
                cell: cell,
                value: .pixelLabel(.noStrongSignalDetected),
                environment: environment,
                configuration: configuration,
                versionTuple: versionTuple
            )
        }

        // Reachable only through `@testable import`: the initialiser is internal to the module,
        // so this is the one call site in the repository that can attempt it at all.
        let admitted = QualifyingParityEvidence(
            observations: [
                observation(
                    environment: .physicalIPhone,
                    configuration: binding.configuration,
                    versionTuple: binding.versionTuple
                )
            ],
            plan: binding.plan,
            configuration: binding.configuration,
            versionTuple: binding.versionTuple
        )
        #expect(admitted != nil)
        #expect(admitted?.environment == .physicalIPhone)
        #expect(admitted?.observationCount == 1)

        // Clause 1: not a physical iPhone.
        for environment in [ExecutionEnvironment.developmentMac, .iOSSimulator] {
            let refused = QualifyingParityEvidence(
                observations: [
                    observation(
                        environment: environment,
                        configuration: binding.configuration,
                        versionTuple: binding.versionTuple
                    )
                ],
                plan: binding.plan,
                configuration: binding.configuration,
                versionTuple: binding.versionTuple
            )
            #expect(refused == nil)
        }

        // Clause 2: nothing observed at all.
        let empty = QualifyingParityEvidence(
            observations: [],
            plan: binding.plan,
            configuration: binding.configuration,
            versionTuple: binding.versionTuple
        )
        #expect(empty == nil)

        // Clause 3: a configuration the approved plan does not enumerate — reachable here and
        // not through the runner, whose bound configuration is always a plan candidate.
        let stranger = try Sample.candidateConfiguration(
            hardware: DeviceHardwareID("iPhone99.9")!
        )
        #expect(!binding.plan.candidateConfigurations.contains(stranger))
        let notACandidate = QualifyingParityEvidence(
            observations: [
                observation(
                    environment: .physicalIPhone,
                    configuration: stranger,
                    versionTuple: binding.versionTuple
                )
            ],
            plan: binding.plan,
            configuration: stranger,
            versionTuple: binding.versionTuple
        )
        #expect(notACandidate == nil)

        // Clause 4: a different configuration than the run is bound to.
        let mismatched = QualifyingParityEvidence(
            observations: [
                observation(
                    environment: .physicalIPhone,
                    configuration: stranger,
                    versionTuple: binding.versionTuple
                )
            ],
            plan: binding.plan,
            configuration: binding.configuration,
            versionTuple: binding.versionTuple
        )
        #expect(mismatched == nil)

        // Clause 5: a different version tuple.
        let otherTuple = try Sample.parityVersionTuple(
            appBuild: AppBuildID("build.other")!
        )
        let mixedTuple = QualifyingParityEvidence(
            observations: [
                observation(
                    environment: .physicalIPhone,
                    configuration: binding.configuration,
                    versionTuple: otherTuple
                )
            ],
            plan: binding.plan,
            configuration: binding.configuration,
            versionTuple: binding.versionTuple
        )
        #expect(mixedTuple == nil)
    }

    @Test("The only initialiser of qualifying resource evidence refuses every non-physical claim")
    func qualifyingResourceEvidenceRefusesEveryNonPhysicalClaim() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        let cell = try #require(binding.requiredCells.first { $0.metric == .peakResidentMemory })
        func sample(
            target: ExecutionTarget,
            environment: ExecutionEnvironment,
            configuration: CandidateDeviceConfiguration,
            versionTuple: ValidationVersionTuple
        ) -> ResourceSample {
            // `ResourceSampleIndex` has no public initialiser either, so even naming a position
            // in the declared series needs `@testable import`.
            ResourceSample(
                cell: cell,
                index: ResourceSampleIndex(ordinal: 0),
                value: .quantity(10, unit: .bytes),
                target: target,
                environment: environment,
                configuration: configuration,
                versionTuple: versionTuple
            )
        }

        let admitted = QualifyingResourceEvidence(
            samples: [
                sample(
                    target: .mainApplication,
                    environment: .physicalIPhone,
                    configuration: binding.configuration,
                    versionTuple: binding.versionTuple
                )
            ],
            plan: binding.plan,
            target: .mainApplication,
            configuration: binding.configuration,
            versionTuple: binding.versionTuple
        )
        #expect(admitted != nil)
        #expect(admitted?.target == .mainApplication)

        // The other process.
        let foreignTarget = QualifyingResourceEvidence(
            samples: [
                sample(
                    target: .shareExtension,
                    environment: .physicalIPhone,
                    configuration: binding.configuration,
                    versionTuple: binding.versionTuple
                )
            ],
            plan: binding.plan,
            target: .mainApplication,
            configuration: binding.configuration,
            versionTuple: binding.versionTuple
        )
        #expect(foreignTarget == nil)

        for environment in [ExecutionEnvironment.developmentMac, .iOSSimulator] {
            let refused = QualifyingResourceEvidence(
                samples: [
                    sample(
                        target: .mainApplication,
                        environment: environment,
                        configuration: binding.configuration,
                        versionTuple: binding.versionTuple
                    )
                ],
                plan: binding.plan,
                target: .mainApplication,
                configuration: binding.configuration,
                versionTuple: binding.versionTuple
            )
            #expect(refused == nil)
        }

        let empty = QualifyingResourceEvidence(
            samples: [],
            plan: binding.plan,
            target: .mainApplication,
            configuration: binding.configuration,
            versionTuple: binding.versionTuple
        )
        #expect(empty == nil)

        let stranger = try Sample.candidateConfiguration(
            hardware: DeviceHardwareID("iPhone99.9")!
        )
        let notACandidate = QualifyingResourceEvidence(
            samples: [
                sample(
                    target: .mainApplication,
                    environment: .physicalIPhone,
                    configuration: stranger,
                    versionTuple: binding.versionTuple
                )
            ],
            plan: binding.plan,
            target: .mainApplication,
            configuration: stranger,
            versionTuple: binding.versionTuple
        )
        #expect(notACandidate == nil)

        let otherTuple = try Sample.resourceVersionTuple(
            appBuild: AppBuildID("build.other")!
        )
        let mixedTuple = QualifyingResourceEvidence(
            samples: [
                sample(
                    target: .mainApplication,
                    environment: .physicalIPhone,
                    configuration: binding.configuration,
                    versionTuple: otherTuple
                )
            ],
            plan: binding.plan,
            target: .mainApplication,
            configuration: binding.configuration,
            versionTuple: binding.versionTuple
        )
        #expect(mixedTuple == nil)
    }

    @Test("The only initialiser of qualifying matrix evidence refuses every non-physical claim")
    func qualifyingMatrixEvidenceRefusesEveryNonPhysicalClaim() throws {
        let binding = try Sample.matrixBinding()
        let cell = try #require(
            Sample.readableCells(of: binding).first {
                $0.exercise == .assistive(.largestDynamicType)
            }
        )
        let manualCell = try #require(
            Sample.readableCells(of: binding).first { $0.exercise == .assistive(.voiceOver) }
        )
        func observation(
            for answered: AccessibilityMatrixCell,
            execution: ObservedMatrixExecution,
            environment: ExecutionEnvironment,
            configuration: CandidateDeviceConfiguration,
            versionTuple: ValidationVersionTuple
        ) -> MatrixCellObservation {
            MatrixCellObservation(
                cell: answered,
                coverage: .workflowCompleted,
                execution: execution,
                resultReference: Sample.matrixEvidence("evidence.matrix-run", digest: 0xB1),
                environment: environment,
                configuration: configuration,
                versionTuple: versionTuple
            )
        }

        let admitted = QualifyingMatrixEvidence(
            observation: observation(
                for: cell,
                execution: .automated,
                environment: .physicalIPhone,
                configuration: binding.configuration,
                versionTuple: binding.versionTuple
            ),
            cell: cell,
            plan: binding.plan,
            configuration: binding.configuration,
            versionTuple: binding.versionTuple
        )
        #expect(admitted != nil)
        #expect(admitted?.environment == .physicalIPhone)

        for environment in [ExecutionEnvironment.developmentMac, .iOSSimulator] {
            let refused = QualifyingMatrixEvidence(
                observation: observation(
                    for: cell,
                    execution: .automated,
                    environment: environment,
                    configuration: binding.configuration,
                    versionTuple: binding.versionTuple
                ),
                cell: cell,
                plan: binding.plan,
                configuration: binding.configuration,
                versionTuple: binding.versionTuple
            )
            #expect(refused == nil)
        }

        // An automated claim cannot answer a position no supported automation can establish,
        // even on a physical iPhone.
        let automatedVoiceOver = QualifyingMatrixEvidence(
            observation: observation(
                for: manualCell,
                execution: .automated,
                environment: .physicalIPhone,
                configuration: binding.configuration,
                versionTuple: binding.versionTuple
            ),
            cell: manualCell,
            plan: binding.plan,
            configuration: binding.configuration,
            versionTuple: binding.versionTuple
        )
        #expect(automatedVoiceOver == nil)

        // And an imported human result approved for a different position does not answer this
        // one.
        let wrongAuthorization = QualifyingMatrixEvidence(
            observation: observation(
                for: manualCell,
                execution: .manual(Sample.importedManual(for: cell)),
                environment: .physicalIPhone,
                configuration: binding.configuration,
                versionTuple: binding.versionTuple
            ),
            cell: manualCell,
            plan: binding.plan,
            configuration: binding.configuration,
            versionTuple: binding.versionTuple
        )
        #expect(wrongAuthorization == nil)

        // A rejection is representable and refused: presence is not approval.
        let rejected = QualifyingMatrixEvidence(
            observation: observation(
                for: manualCell,
                execution: .manual(Sample.importedManual(for: manualCell, decision: .rejected)),
                environment: .physicalIPhone,
                configuration: binding.configuration,
                versionTuple: binding.versionTuple
            ),
            cell: manualCell,
            plan: binding.plan,
            configuration: binding.configuration,
            versionTuple: binding.versionTuple
        )
        #expect(rejected == nil)

        let stranger = try Sample.matrixConfiguration(hardware: "iPhone99.9")
        #expect(!binding.plan.candidateConfigurations.contains(stranger))
        let notACandidate = QualifyingMatrixEvidence(
            observation: observation(
                for: cell,
                execution: .automated,
                environment: .physicalIPhone,
                configuration: stranger,
                versionTuple: binding.versionTuple
            ),
            cell: cell,
            plan: binding.plan,
            configuration: stranger,
            versionTuple: binding.versionTuple
        )
        #expect(notACandidate == nil)

        let otherTuple = try Sample.matrixVersionTuple(
            appBuild: AppBuildID("build.other")!
        )
        let mixedTuple = QualifyingMatrixEvidence(
            observation: observation(
                for: cell,
                execution: .automated,
                environment: .physicalIPhone,
                configuration: binding.configuration,
                versionTuple: otherTuple
            ),
            cell: cell,
            plan: binding.plan,
            configuration: binding.configuration,
            versionTuple: binding.versionTuple
        )
        #expect(mixedTuple == nil)
    }

    @Test("Every qualifying-evidence type in the module is unreachable from a client")
    func noQualifyingEvidenceTypeIsClientConstructible() throws {
        // Each sibling suite audits its own declaration. This one states the invariant over the
        // whole module: there are exactly three of these types, and not one of them has an
        // initialiser or a decoder a caller outside `DefAIkeReleaseValidation` could use.
        let declarations = [
            ("ParityValidationInputs.swift", "QualifyingParityEvidence"),
            ("ResourceValidationInputs.swift", "QualifyingResourceEvidence"),
            ("AccessibilityMatrixInputs.swift", "QualifyingMatrixEvidence"),
        ]
        for (file, type) in declarations {
            let code = ParityPhysicalDeviceGateTests.strippingComments(
                try ParityPhysicalDeviceGateTests.moduleSource(named: file)
            )
            #expect(code.contains("public struct \(type): Hashable, Sendable {"))
            #expect(!code.contains("public struct \(type): Hashable, Codable"))
            #expect(!code.contains("public init?("))
            #expect(code.contains("    init?("))
        }

        // And the module declares no fourth one, so the enumeration above is the whole set.
        var declared: [String] = []
        for name in try Self.moduleSourceNames() {
            let code = ParityPhysicalDeviceGateTests.strippingComments(
                try ParityPhysicalDeviceGateTests.moduleSource(named: name)
            )
            for line in code.split(separator: "\n", omittingEmptySubsequences: false)
            where line.contains("struct Qualifying") {
                declared.append(String(line))
            }
        }
        #expect(declared.count == 3)
    }

    @Test("The observed environment has no setter, no injection point, and no runtime read")
    func observedEnvironmentCannotBeSupplied() throws {
        let code = ParityPhysicalDeviceGateTests.strippingComments(
            try ParityPhysicalDeviceGateTests.moduleSource(named: "ParityValidationInputs.swift")
        )
        #expect(code.contains("#if targetEnvironment(simulator)"))
        #expect(code.contains("#elseif os(iOS)"))
        #expect(code.contains("public static let current: ExecutionEnvironment"))

        // The one decision the whole ingestion's gate outcomes hang from, and there is nothing
        // to configure: no settable storage, no process environment, no bundle, no defaults.
        for token in [
            "static var current", "ProcessInfo", "UserDefaults", "Bundle.main", "Bundle(",
            "Bundle.module", "func setCurrent", "current =", "allowSimulator", "allowHost",
            "treatAsPhysical", "assumePhysical",
        ] {
            #expect(!code.contains(token), "the observed environment must not reference a setter")
        }

        // And every runner reads that one value rather than taking a parameter.
        for name in ["ParityValidation.swift", "ResourceValidation.swift"] {
            let runner = ParityPhysicalDeviceGateTests.strippingComments(
                try ParityPhysicalDeviceGateTests.moduleSource(named: name)
            )
            #expect(runner.contains("runEnvironment: ObservedParityEnvironment.current"))
        }
        let matrix = ParityPhysicalDeviceGateTests.strippingComments(
            try ParityPhysicalDeviceGateTests.moduleSource(
                named: "AccessibilityMatrixValidation.swift"
            )
        )
        #expect(matrix.contains("runEnvironment: ObservedParityEnvironment.current"))
    }

    // MARK: Helper

    /// Every Swift file name in the module's source directory.
    ///
    /// Enumerated rather than listed, so a new module source is scanned instead of skipped.
    static func moduleSourceNames() throws -> [String] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DefAIkeReleaseValidation")
        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "the module's sources must be readable for this to mean anything")
        return files.map(\.lastPathComponent).sorted()
    }
}
