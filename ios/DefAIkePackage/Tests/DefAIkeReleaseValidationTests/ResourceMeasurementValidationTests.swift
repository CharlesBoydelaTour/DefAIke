import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// What the resource, thermal, cancellation, and interruption measurement harnesses do with a
// bound plan, two signed budgets, and a sample series.
//
// Requirements 11.4, 11.19, 13.12 through 13.17, 15.8, and 15.9. Nothing in this suite is
// release evidence: every plan, budget, limit, sample count, statistic, condition, and
// measurement below is synthetic, no physical device ran, and nothing was measured on one. The
// suite's subject is the *structure* of the harness — which measurements are required, where
// each number comes from, and what a missing one does to the recorded statistic.
//
// The central asymmetry with the parity runners is worth stating up front, because it is a
// finding rather than an omission: of the nine enumerated measurements, only peak resident
// memory and the two sustained-thermal workloads have any measurement path in this repository at
// all. `PlatformResourceGovernor` reports `notMeasurable` for temporary storage, all three
// latencies, and energy, always; and the plan's measurement table has no condition dimension, so
// cancellation residual work and interruption cleanup cannot even be predeclared. So a
// structurally complete run here still refuses seven of nine main-application cells and six of
// eight Share Extension cells before it reads a single sample, and the suite asserts that by
// name rather than stubbing a path.

/// Binding, required-cell derivation, summarizing, and the missing-measurement rule.
@Suite("Resource measurement validation")
struct ResourceMeasurementValidationTests {

    // MARK: - The required set

    @Test("Each target owes its own budget metrics plus cancellation and interruption")
    func requiredCellsFollowTheTargetsBudgetMetrics() throws {
        for target in ExecutionTarget.allCases {
            let binding = try Sample.resourceTargetBinding(target: target)
            let subjects = Set(binding.requiredCells.map(\.subject))
            var expected = Set(
                ResourceMetric.requiredMetrics(for: target).map { ResourceSubject.budgetMetric($0) }
            )
            expected.insert(.cancellationResidualWork)
            expected.insert(.interruptionCleanup)
            #expect(subjects == expected)
            #expect(binding.requiredCells.allSatisfy { $0.target == target })
            // Stable order, so two runs enumerate identically.
            let keys = binding.requiredCells.map(\.orderingKey)
            #expect(keys == keys.sorted())
        }
    }

    @Test("The main application owes nine measurements and the extension eight")
    func requiredCellCountsFollowTheRequirements() throws {
        let binding = try Sample.resourceRunBinding()
        // Seven main-application budget metrics plus cancellation and interruption.
        #expect(binding.mainApplication.requiredCells.count == 9)
        // Six Share Extension budget metrics plus the same two.
        #expect(binding.shareExtension.requiredCells.count == 8)
    }

    @Test("Every resource gate this task measures has at least one required cell")
    func everyResourceGateIsCovered() throws {
        let binding = try Sample.resourceRunBinding()
        let gates = DeviceGate.resourceGates
        #expect(gates.count == 13)
        for gate in gates {
            let main = binding.mainApplication.requiredCells(for: gate)
            let sharing = binding.shareExtension.requiredCells(for: gate)
            #expect(!main.isEmpty || !sharing.isEmpty, "\(gate.rawValue) has no required cell")
        }
        // And the two condition gates are owed by both targets, because Requirement 11.19 keeps
        // their raw values and pass results apart even though one gate names them.
        for gate in [DeviceGate.cancellationResidualWork, .interruptionCleanup] {
            #expect(binding.mainApplication.requiredCells(for: gate).count == 1)
            #expect(binding.shareExtension.requiredCells(for: gate).count == 1)
        }
    }

    @Test("Two predeclared measurements belong to no mandatory device gate")
    func twoMeasurementsHaveNoMandatoryGate() throws {
        let binding = try Sample.resourceRunBinding()
        let mainGateless = binding.mainApplication.requiredCells.filter { $0.cellGate.gate == nil }
        let extensionGateless = binding.shareExtension.requiredCells.filter {
            $0.cellGate.gate == nil
        }
        let mainMetrics = mainGateless.compactMap(\.metric)
        let extensionMetrics = extensionGateless.compactMap(\.metric)
        #expect(mainMetrics == [ResourceMetric.decodedPixelCount])
        #expect(extensionMetrics == [ResourceMetric.encodedInputSize])
        // The finding is recorded rather than the cell being dropped.
        for cell in mainGateless + extensionGateless {
            guard case let .noMandatoryGate(limit) = cell.cellGate else {
                Issue.record("a gateless cell must name the finding")
                continue
            }
            #expect(!limit.blocksMeasurement)
        }
    }

    // MARK: - Every number comes from the plan

    @Test("The declared sample count and statistic are the plan's, for every measurable cell")
    func sampleCountAndStatisticComeFromThePlan() throws {
        let declared = Sample.count(7)
        let plan = try Sample.resourcePlan(sampleCount: declared, numericStatistic: .percentile95)
        let binding = try Sample.resourceRunBinding(plan: plan)
        for target in ExecutionTarget.allCases {
            let scoped = binding.binding(for: target)
            for cell in scoped.requiredCells {
                guard let metric = cell.metric else {
                    // A measurement the plan cannot predeclare has no count at all, and the
                    // harness supplies none of its own.
                    #expect(scoped.declaredSampleCount(for: cell) == 0)
                    #expect(scoped.limit(for: cell) == nil)
                    continue
                }
                #expect(scoped.declaredSampleCount(for: cell) == declared.value)
                #expect(scoped.limit(for: cell) == Sample.limit(for: metric))
                let statistic = scoped.specification(for: cell)?.summaryStatistic
                #expect(statistic == (metric.isCategorical ? .maximum : .percentile95))
            }
        }
    }

    @Test("The runner asks for exactly the plan's declared sample positions")
    func theRunnerEnumeratesThePlansSampleCount() throws {
        let declared = Sample.count(4)
        let plan = try Sample.resourcePlan(sampleCount: declared)
        let binding = try Sample.resourceTargetBinding(target: .mainApplication, plan: plan)
        let recorder = RecordingResourceSampleStore(
            backing: FakeResourceSampleStore.complete(for: binding)
        )
        _ = ResourceMeasurementRunner(samples: recorder).run(binding)

        let readable = Sample.readableCells(of: binding)
        for cell in readable {
            let asked = recorder.ordinals(for: cell)
            #expect(asked == Array(0..<declared.value), "\(cell.description) positions asked")
        }
        // And nothing was asked about the blocked cells at all.
        for cell in Sample.blockedCells(of: binding) {
            #expect(recorder.ordinals(for: cell).isEmpty, "\(cell.description) must not be read")
        }
    }

    // MARK: - Summarizing

    @Test("Each declared statistic summarizes the series the plan approved")
    func statisticsSummarizeTheDeclaredSeries() {
        let magnitudes: [Decimal] = [10, 30, 20, 50, 40]
        let median = ResourceMeasurementRunner.numericStatistic(of: magnitudes, .median)
        let maximum = ResourceMeasurementRunner.numericStatistic(of: magnitudes, .maximum)
        let mean = ResourceMeasurementRunner.numericStatistic(of: magnitudes, .mean)
        let percentile = ResourceMeasurementRunner.numericStatistic(of: magnitudes, .percentile95)
        #expect(median == Decimal(30))
        #expect(maximum == Decimal(50))
        #expect(mean == Decimal(30))
        #expect(percentile == Decimal(50))
    }

    @Test("An even-count median averages the two central magnitudes exactly")
    func evenCountMedianIsExact() {
        let median = ResourceMeasurementRunner.numericStatistic(of: [10, 20, 30, 50], .median)
        #expect(median == Decimal(25))
    }

    @Test("The nearest-rank percentile index is computed in whole numbers")
    func nearestRankIndexIsIntegral() {
        // ceil(0.95 * n) - 1, so a single sample is its own percentile and twenty samples put
        // the 95th at the last position.
        #expect(ResourceMeasurementRunner.nearestRankIndex(count: 1) == 0)
        #expect(ResourceMeasurementRunner.nearestRankIndex(count: 2) == 1)
        #expect(ResourceMeasurementRunner.nearestRankIndex(count: 5) == 4)
        #expect(ResourceMeasurementRunner.nearestRankIndex(count: 20) == 18)
        #expect(ResourceMeasurementRunner.nearestRankIndex(count: 21) == 19)
    }

    @Test("Thermal order statistics take the hotter central state")
    func thermalOrderStatisticsAreConservative() {
        let even: [ThermalState] = [.nominal, .fair, .serious, .critical]
        #expect(ResourceMeasurementRunner.orderStatistic(of: even, .median) == .serious)
        #expect(ResourceMeasurementRunner.orderStatistic(of: even, .maximum) == .critical)
        let odd: [ThermalState] = [.nominal, .fair, .serious]
        #expect(ResourceMeasurementRunner.orderStatistic(of: odd, .median) == .fair)
    }

    @Test("An arithmetic mean over thermal states has no value and no substitute")
    func thermalMeanIsRefused() {
        let states: [ThermalState] = [.nominal, .critical]
        #expect(ResourceMeasurementRunner.orderStatistic(of: states, .mean) == nil)
        #expect(!SummaryStatistic.mean.isOrderStatistic)
        for statistic in SummaryStatistic.allCases where statistic != .mean {
            #expect(statistic.isOrderStatistic, "\(statistic.rawValue) is an order statistic")
        }
    }

    @Test("A plan that summarizes a thermal metric with a mean cannot be bound")
    func thermalMeanIsABindingError() throws {
        let plan = try Sample.resourcePlan(thermalStatistic: .mean)
        let budgets = try Sample.resourceBudgets()
        let configuration = try Sample.candidateConfiguration()
        let tuple = try Sample.resourceVersionTuple()
        for target in ExecutionTarget.allCases {
            let finding = Self.bindingFinding(
                target: target,
                plan: plan,
                budgets: budgets,
                configuration: configuration,
                versionTuple: tuple
            )
            #expect(finding == .thermalSummaryStatisticNotOrdinal(.mean))
        }
    }

    // MARK: - Measurements with no path

    @Test("Five budget metrics and both condition measurements are refused before the seam")
    func metricsWithNoMeasurementPathAreRefused() throws {
        let binding = try Sample.resourceRunBinding()
        let report = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.complete(for: binding)
        )
        .run(binding)

        let expected: [ExecutionTarget: [UnobservableResourceEvidence]] = [
            .mainApplication: [
                .cancellationResidualWorkHasNoPlanSpecification,
                .coldModelLoadTimeHasNoShippingMeasurementPath,
                .energyImpactHasNoShippingMeasurementPath,
                .interruptionCleanupHasNoPlanSpecification,
                .temporaryStorageHasNoShippingMeasurementPath,
                .warmAnalysisLatencyHasNoShippingMeasurementPath,
            ],
            .shareExtension: [
                .cancellationResidualWorkHasNoPlanSpecification,
                .energyImpactHasNoShippingMeasurementPath,
                .handoffLatencyHasNoShippingMeasurementPath,
                .interruptionCleanupHasNoPlanSpecification,
                .temporaryStorageHasNoShippingMeasurementPath,
            ],
        ]
        for target in ExecutionTarget.allCases {
            let scoped = report.report(for: target)
            var found: [UnobservableResourceEvidence] = []
            for cell in scoped.unavailableMeasurementCells {
                guard case let .measurementUnavailable(limit) = scoped.outcome(of: cell) else {
                    Issue.record("an unavailable cell must name what is unavailable")
                    continue
                }
                found.append(limit)
            }
            let sortedFound = found.map(\.rawValue).sorted()
            let sortedExpected = (expected[target] ?? []).map(\.rawValue).sorted()
            #expect(sortedFound == sortedExpected, "\(target.rawValue) unavailable measurements")
        }
    }

    @Test("An unavailable measurement records no raw series and no summary")
    func unavailableMeasurementsRecordNothing() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        let report = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.complete(for: binding)
        )
        .run(binding)
        for cell in report.unavailableMeasurementCells {
            let record = report.record(of: cell)
            #expect(record.summary.rawValues.isEmpty)
            #expect(record.summary.summaryValue == nil)
            #expect(record.summary.declaredSampleCount >= 0)
            #expect(!record.summary.isComplete)
            #expect(record.outcome.outcome == .failed)
            #expect(!record.outcome.wasMeasured)
        }
    }

    // MARK: - The missing-measurement rule

    @Test("An empty store makes every required measurement a failure, not an absence")
    func anEmptyStoreFailsEveryMeasurement() throws {
        let binding = try Sample.resourceRunBinding()
        let report = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.empty(for: binding.mainApplication)
        )
        .run(binding)

        for target in ExecutionTarget.allCases {
            let scoped = report.report(for: target)
            #expect(scoped.satisfiedCells.isEmpty)
            #expect(scoped.unsatisfiedCells.count == scoped.requiredCells.count)
            for cell in scoped.requiredCells {
                let outcome = scoped.outcome(of: cell)
                #expect(!outcome.isSatisfied)
                #expect(outcome.outcome == .failed)
                #expect(outcome.outcome != .notExecuted)
            }
            #expect(scoped.outcome == .failed)
        }
        #expect(report.outcome == .failed)
    }

    @Test("A cell outside the required set is a failure, not a nil")
    func anUnrequiredCellIsAFailure() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        let report = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.complete(for: binding)
        )
        .run(binding)

        // A Share Extension cell has no place in a main-application report.
        let foreign = ResourceCell(target: .shareExtension, subject: .budgetMetric(.handoffLatency))
        let outcome = report.outcome(of: foreign)
        #expect(!outcome.isSatisfied)
        #expect(outcome.outcome == .failed)
        guard case let .crossTargetSample(observed, required) = outcome else {
            Issue.record("a foreign-target cell must be refused as cross-target")
            return
        }
        #expect(observed == .shareExtension)
        #expect(required == .mainApplication)
    }

    @Test("A short series fails even though every sample that came back qualified")
    func aShortSeriesFails() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        var store = FakeResourceSampleStore.complete(for: binding)
        let subject = try #require(
            binding.requiredCells.first { $0.metric == .peakResidentMemory }
        )
        let declared = binding.declaredSampleCount(for: subject)
        store.truncateSeries(subject, keeping: declared - 2)

        let report = ResourceMeasurementRunner(samples: store).run(binding)
        let outcome = report.outcome(of: subject)
        guard case let .sampleCountIncomplete(observed, reported) = outcome else {
            Issue.record("a short series must be refused as incomplete")
            return
        }
        #expect(observed == declared - 2)
        #expect(reported == declared)
        #expect(!outcome.isSatisfied)
    }

    @Test("A missing sample lowers the completeness statistic instead of leaving it")
    func aMissingSampleLowersCompleteness() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        let subject = try #require(
            binding.requiredCells.first { $0.metric == .peakResidentMemory }
        )
        let declared = binding.declaredSampleCount(for: subject)

        var complete = FakeResourceSampleStore.complete(for: binding)
        complete.setEnvironmentEverywhere(.physicalIPhone)
        let whole = ResourceMeasurementRunner(samples: complete).run(binding)
        let wholeSummary = whole.record(of: subject).summary
        #expect(wholeSummary.declaredSampleCount == declared)
        #expect(wholeSummary.qualifyingSampleCount == declared)
        #expect(wholeSummary.completeness == .one)
        #expect(wholeSummary.isComplete)

        var short = complete
        short.removeSample(subject, at: declared - 1)
        let partial = ResourceMeasurementRunner(samples: short).run(binding)
        let partialSummary = partial.record(of: subject).summary
        // The denominator is the plan's, so the ratio falls rather than the series shrinking.
        #expect(partialSummary.declaredSampleCount == declared)
        #expect(partialSummary.qualifyingSampleCount == declared - 1)
        #expect(partialSummary.completeness < .one)
        #expect(!partialSummary.isComplete)
    }

    @Test("A gate's measured completeness falls when one of its cells produces nothing")
    func gateCompletenessFallsWithAMissingCell() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        let subject = try #require(
            binding.requiredCells.first { $0.metric == .peakResidentMemory }
        )
        let gate = try #require(subject.cellGate.gate)

        let complete = FakeResourceSampleStore.complete(for: binding)
        let whole = ResourceMeasurementRunner(samples: complete).run(binding)
        #expect(whole.gateResult(for: gate).measuredCompleteness == .one)

        var emptied = complete
        emptied.removeSeries(subject)
        let partial = ResourceMeasurementRunner(samples: emptied).run(binding)
        // Zero of the plan's declared samples, not zero of zero.
        #expect(partial.gateResult(for: gate).measuredCompleteness == .zero)
        #expect(partial.record(of: subject).summary.declaredSampleCount > 0)
    }

    @Test("An unreadable position and an unmeasurable metric are recorded apart")
    func faultKindsAreRecordedApart() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        let subject = try #require(
            binding.requiredCells.first { $0.metric == .peakResidentMemory }
        )

        var unreadable = FakeResourceSampleStore.empty(for: binding)
        unreadable.makeUnreadable(subject, at: 0)
        guard case let .measurementMissing(first) = ResourceMeasurementRunner(samples: unreadable)
            .run(binding)
            .outcome(of: subject)
        else {
            Issue.record("an unreadable position must be a missing measurement")
            return
        }
        #expect(first.fault == .sampleUnreadable)

        var unmeasurable = FakeResourceSampleStore.empty(for: binding)
        unmeasurable.makeNotMeasurable(subject)
        guard case let .measurementMissing(second) = ResourceMeasurementRunner(
            samples: unmeasurable
        )
        .run(binding)
        .outcome(of: subject)
        else {
            Issue.record("an unmeasurable metric must be a missing measurement")
            return
        }
        #expect(second.fault == .metricNotMeasurableInEnvironment)
        #expect(second.owed == subject.owedReleaseInput)
    }

    // MARK: - Comparing against the approved limit

    @Test("A summary above the approved ceiling is an exceedance, not a pass")
    func anExceedanceIsRecorded() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        var store = FakeResourceSampleStore.complete(for: binding)
        let subject = try #require(
            binding.requiredCells.first { $0.metric == .peakResidentMemory }
        )
        store.setValueEverywhere(.quantity(1_000, unit: .bytes), for: subject)

        guard case let .exceededLimit(exceedance) = ResourceMeasurementRunner(samples: store)
            .run(binding)
            .outcome(of: subject)
        else {
            Issue.record("a magnitude above the ceiling must be an exceedance")
            return
        }
        guard case let .magnitudeExceedsLimit(summary, ceiling, unit) = exceedance.detail else {
            Issue.record("an exceedance must name the magnitude and the ceiling")
            return
        }
        #expect(summary == Decimal(1_000))
        #expect(ceiling == Decimal(100))
        #expect(unit == .bytes)
    }

    @Test("A thermal summary hotter than the approved maximum is an exceedance")
    func aThermalExceedanceIsRecorded() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        var store = FakeResourceSampleStore.complete(for: binding)
        let subject = try #require(binding.requiredCells.first { $0.metric == .thermalState })
        store.setValueEverywhere(.thermalState(.critical), for: subject)

        guard case let .exceededLimit(exceedance) = ResourceMeasurementRunner(samples: store)
            .run(binding)
            .outcome(of: subject)
        else {
            Issue.record("a state hotter than the maximum must be an exceedance")
            return
        }
        #expect(exceedance.detail == .stateExceedsLimit(summary: .critical, maximum: .fair))
    }

    @Test("A sample in the wrong unit is refused rather than converted")
    func aWrongUnitIsRefused() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        var store = FakeResourceSampleStore.complete(for: binding)
        let subject = try #require(
            binding.requiredCells.first { $0.metric == .peakResidentMemory }
        )
        store.setValueEverywhere(.quantity(10, unit: .milliseconds), for: subject)

        guard case let .sampleUnitMismatch(observed, required) = ResourceMeasurementRunner(
            samples: store
        )
        .run(binding)
        .outcome(of: subject)
        else {
            Issue.record("a milliseconds sample must not bound a bytes limit")
            return
        }
        #expect(observed == .milliseconds)
        #expect(required == .bytes)
    }

    @Test("A thermal sample cannot answer a numeric limit, or the reverse")
    func aWrongKindIsRefused() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        var store = FakeResourceSampleStore.complete(for: binding)
        let numeric = try #require(
            binding.requiredCells.first { $0.metric == .peakResidentMemory }
        )
        let categorical = try #require(binding.requiredCells.first { $0.metric == .thermalState })
        store.setValueEverywhere(.thermalState(.nominal), for: numeric)
        store.setValueEverywhere(.quantity(1, unit: .bytes), for: categorical)

        let report = ResourceMeasurementRunner(samples: store).run(binding)
        guard case let .sampleKindMismatch(firstObserved, firstRequired) = report.outcome(of: numeric)
        else {
            Issue.record("a thermal sample must not answer a numeric limit")
            return
        }
        #expect(firstObserved == .thermalState)
        #expect(firstRequired == .quantity)
        guard
            case let .sampleKindMismatch(secondObserved, secondRequired) = report.outcome(
                of: categorical
            )
        else {
            Issue.record("a quantity sample must not answer a thermal limit")
            return
        }
        #expect(secondObserved == .quantity)
        #expect(secondRequired == .thermalState)
    }

    // MARK: - Raw values and the decision are recorded apart

    @Test("The raw series and the pass decision are stored separately")
    func rawValuesAndDecisionAreSeparate() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        let report = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.complete(for: binding)
        )
        .run(binding)
        let subject = try #require(
            binding.requiredCells.first { $0.metric == .peakResidentMemory }
        )
        let record = report.record(of: subject)
        let declared = binding.declaredSampleCount(for: subject)

        // Every raw sample is retained, in the order the declared series asked for it.
        #expect(record.summary.rawValues.count == declared)
        let magnitudes = record.summary.rawValues.compactMap(\.magnitude)
        #expect(magnitudes == (0..<declared).map { Sample.withinLimitMagnitude(at: $0) })
        // The summary is the plan's declared statistic and not a value the harness chose.
        #expect(record.summary.summaryStatistic == .median)
        #expect(record.summary.summaryValue?.magnitude == Decimal(12))
        // And the decision is a separate field that the raw series does not carry.
        #expect(record.limit == Sample.limit(for: .peakResidentMemory))
        // The *cell* passes: the sample store claims `.physicalIPhone`, and barrier 1 accepts a
        // claim because a real harness is the only thing that can make one. The gate does not,
        // which is barrier 2's job and ``ResourcePhysicalDeviceGateTests``'s subject.
        #expect(record.outcome.outcome == .passed)
        #expect(report.gateResult(for: .mainApplicationPeakMemory).outcome == .failed)
    }

    @Test("A measurement record carries the raw series and refuses a thermal one")
    func measurementRecordsMirrorTheRawSeries() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        let report = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.complete(for: binding)
        )
        .run(binding)
        let specification = Sample.evidence("evidence.specification")

        let numeric = try #require(
            binding.requiredCells.first { $0.metric == .peakResidentMemory }
        )
        let record = try #require(
            try report.measurementRecord(of: numeric, specification: specification)
        )
        #expect(record.metric == .peakResidentMemory)
        #expect(record.target == .mainApplication)
        #expect(record.rawValues.count == binding.declaredSampleCount(for: numeric))
        #expect(record.summaryStatistic == .median)
        // The record carries the *cell's* outcome, which the claimed environment satisfies. The
        // gate outcome is a separate conclusion this process draws, and it fails.
        #expect(record.outcome == .passed)
        #expect(report.gateResult(for: .mainApplicationPeakMemory).outcome == .failed)

        // A thermal series has no `[Decimal]` shape, so no record is built rather than encoding
        // states as severity ordinals no artifact approved.
        let categorical = try #require(binding.requiredCells.first { $0.metric == .thermalState })
        let thermalRecord = try report.measurementRecord(
            of: categorical,
            specification: specification
        )
        #expect(thermalRecord == nil)
        #expect(
            report.standingLimits.contains(.thermalSamplesNotRepresentableInMeasurementRecord)
        )
    }

    // MARK: - Binding reconciliation

    @Test("A configuration outside the plan cannot be bound")
    func configurationOutsideThePlanIsRefused() throws {
        let other = try Sample.candidateConfiguration(hardware: DeviceHardwareID("iPhone99.9")!)
        let finding = Self.bindingFinding(
            target: .mainApplication,
            plan: try Sample.resourcePlan(),
            budgets: try Sample.resourceBudgets(),
            configuration: other,
            versionTuple: try Sample.resourceVersionTuple()
        )
        #expect(finding == .configurationNotInPlan(other.hardwareIdentifier, other.osVersion))
    }

    @Test("A budget measured by another plan cannot be bound")
    func budgetFromAnotherPlanIsRefused() throws {
        let finding = Self.bindingFinding(
            target: .mainApplication,
            plan: try Sample.resourcePlan(),
            budgets: try Sample.resourceBudgets(validationPlan: "plan.other"),
            configuration: try Sample.candidateConfiguration(),
            versionTuple: try Sample.resourceVersionTuple()
        )
        #expect(
            finding
                == .budgetNotMeasuredByPlan(
                    budget: Sample.artifact("budget.main-application"),
                    plan: Sample.artifact("plan.device-validation")
                )
        )
    }

    @Test("A budget hard limit that disagrees with the plan's pass limit cannot be bound")
    func disagreeingLimitsAreRefused() throws {
        let budgets = try Sample.resourceBudgets(
            limits: [
                .peakResidentMemory: .numeric(value: Sample.positiveDecimal(999), unit: .bytes)
            ]
        )
        for target in ExecutionTarget.allCases {
            let finding = Self.bindingFinding(
                target: target,
                plan: try Sample.resourcePlan(),
                budgets: budgets,
                configuration: try Sample.candidateConfiguration(),
                versionTuple: try Sample.resourceVersionTuple()
            )
            #expect(finding == .passLimitDisagreesWithBudget(target, .peakResidentMemory))
        }
    }

    @Test("A measurement predeclared for another application build cannot be bound")
    func aForeignMeasurementAppBuildIsRefused() throws {
        // Reachable through a valid plan, which is the finding: `DeviceValidationPlan` requires
        // every candidate configuration to carry a complete measurement set, but it never
        // reconciles a measurement's `appBuild` against the candidate's. So a plan can enumerate
        // a candidate on build A and predeclare its measurements on build B, and only this
        // binding refuses the pair (Requirement 13.20).
        let foreign = try #require(AppBuildID("build.other"))
        let plan = try Sample.resourcePlan(measurementAppBuild: foreign)
        for target in ExecutionTarget.allCases {
            let finding = Self.bindingFinding(
                target: target,
                plan: plan,
                budgets: try Sample.resourceBudgets(),
                configuration: try Sample.candidateConfiguration(),
                versionTuple: try Sample.resourceVersionTuple()
            )
            // Whichever metric sorts first for the target is the one reported; the binding stops
            // at the first finding rather than surveying all of them.
            guard case let .measurementConditionsMismatch(reported, _) = finding else {
                Issue.record("a foreign measurement build must be refused")
                continue
            }
            #expect(reported == target)
        }
    }

    @Test("A plan cannot enumerate a candidate without that candidate's measurements")
    func perCandidateCoverageIsAlreadyGuaranteed() throws {
        // `measurementSpecificationMissing` is a re-check rather than a reachable state through a
        // valid plan: `DeviceValidationPlan.init` requires the complete metric set for both
        // targets for *every* candidate configuration. A plan whose measurements name only
        // another device therefore does not enumerate this one, and the binding refuses the
        // configuration instead. Asserted so the weaker true claim is on record rather than the
        // stronger one the case name suggests.
        let other = try Sample.candidateConfiguration(hardware: DeviceHardwareID("iPhone16.2")!)
        let plan = try Sample.resourcePlan(hardware: other.hardwareIdentifier)
        #expect(!plan.candidateConfigurations.contains(try Sample.candidateConfiguration()))
        let finding = Self.bindingFinding(
            target: .mainApplication,
            plan: plan,
            budgets: try Sample.resourceBudgets(),
            configuration: try Sample.candidateConfiguration(),
            versionTuple: try Sample.resourceVersionTuple()
        )
        #expect(finding == .configurationNotInPlan(Sample.hardware(), .iOS17))
    }

    @Test("A version tuple naming another plan cannot be bound")
    func aForeignVersionTupleIsRefused() throws {
        let finding = Self.bindingFinding(
            target: .mainApplication,
            plan: try Sample.resourcePlan(),
            budgets: try Sample.resourceBudgets(),
            configuration: try Sample.candidateConfiguration(),
            versionTuple: try Sample.resourceVersionTuple(validationPlan: "plan.other")
        )
        #expect(
            finding
                == .versionTuplePlanMismatch(
                    expected: Sample.artifact("plan.device-validation"),
                    found: Sample.artifact("plan.other")
                )
        )
    }

    @Test("Both targets' bindings come from one plan, budget pair, configuration, and tuple")
    func bothBindingsShareOneTuple() throws {
        let binding = try Sample.resourceRunBinding()
        #expect(binding.mainApplication.plan == binding.shareExtension.plan)
        #expect(binding.mainApplication.configuration == binding.shareExtension.configuration)
        #expect(binding.mainApplication.versionTuple == binding.shareExtension.versionTuple)
        #expect(binding.mainApplication.budget.id != binding.shareExtension.budget.id)
        #expect(binding.binding(for: .mainApplication).target == .mainApplication)
        #expect(binding.binding(for: .shareExtension).target == .shareExtension)
    }

    // MARK: - What the run is owed

    @Test("A run reports the release-controlled inputs it is still owed")
    func aRunReportsWhatItIsOwed() throws {
        let binding = try Sample.resourceRunBinding()
        let report = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.complete(for: binding)
        )
        .run(binding)

        let owed = report.owedInputs
        for expected in [
            UnprovisionedResourceInput.deviceValidationPlanResourceMeasurements,
            .mainApplicationResourceBudget,
            .shareExtensionResourceBudget,
            .cancellationResidualWorkProcedure,
            .interruptionCleanupProcedure,
            .dataLifecycleCleanupDeadlines,
            .shareExtensionDeviceTestHost,
            .physicalIPhoneMeasurementEnvironment,
        ] {
            #expect(owed.contains(expected), "a run must report owing \(expected.rawValue)")
        }
        // In declaration order, so an audit reads a stable list.
        let ordered = UnprovisionedResourceInput.allCases.filter { owed.contains($0) }
        #expect(owed == ordered)
    }

    @Test("A run reports the standing limits that qualify what it measured")
    func aRunReportsItsStandingLimits() throws {
        let binding = try Sample.resourceRunBinding()
        let report = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.complete(for: binding)
        )
        .run(binding)

        for expected in [
            UnobservableResourceEvidence.peakResidentMemoryIsProcessWide,
            .thermalStateIsDeviceWide,
            .sustainedThermalDurationNotInPlanSchema,
            .noCancellationCheckpointBeforePromotion,
            .decodedPixelCountHasNoMandatoryDeviceGate,
            .encodedInputSizeHasNoMandatoryDeviceGate,
        ] {
            #expect(
                report.standingLimits.contains(expected),
                "a run must record \(expected.rawValue)"
            )
        }
    }
}

// MARK: - Helpers

extension ResourceMeasurementValidationTests {
    /// The binding finding for one set of inputs, or `nil` when they bind.
    ///
    /// Every untyped-throwing sample builder is evaluated by the caller, so the `do` block holds
    /// only the typed-throwing initialiser and a plain `catch` binds a `ResourceBindingError`
    /// without a downcast. Swift 6.3.3 crashes `swift-frontend` on
    /// `catch let error as T` where the block throws exactly `T`, so the plain form is the only
    /// safe one.
    static func bindingFinding(
        target: ExecutionTarget,
        plan: DeviceValidationPlan,
        budgets: ResourceBudgetSet,
        configuration: CandidateDeviceConfiguration,
        versionTuple: ValidationVersionTuple
    ) -> ResourceBindingError? {
        do {
            _ = try ResourceTargetBinding(
                target: target,
                plan: plan,
                budgets: budgets,
                configuration: configuration,
                versionTuple: versionTuple
            )
            return nil
        } catch {
            return error
        }
    }
}

/// A reader that records which positions the runner asked about.
///
/// Read-only over a backing store, so the runner sees exactly what the backing store holds. It
/// exists to assert that the sample count is the *plan's*: the runner asks for `0..<sampleCount`
/// and nothing else.
final class RecordingResourceSampleStore: ResourceSampleReading, @unchecked Sendable {
    private let backing: FakeResourceSampleStore
    private let lock = NSLock()
    private var asked: [ResourceCell: [Int]] = [:]

    init(backing: FakeResourceSampleStore) {
        self.backing = backing
    }

    func ordinals(for cell: ResourceCell) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return (asked[cell] ?? []).sorted()
    }

    func sample(
        for cell: ResourceCell,
        at index: ResourceSampleIndex
    ) throws(ResourceSampleFault) -> ResourceSample {
        lock.lock()
        asked[cell, default: []].append(index.ordinal)
        lock.unlock()
        return try backing.sample(for: cell, at: index)
    }
}
