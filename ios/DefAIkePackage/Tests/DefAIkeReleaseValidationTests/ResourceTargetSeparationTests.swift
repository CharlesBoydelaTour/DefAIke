import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// Requirements 11.19 and 11.20, asserted as properties of the types rather than as rules the
// harness follows.
//
// The requirements are that main-application and Share Extension resource behaviour are measured
// and reported as *separate* sets with *separate* pass or fail gate results, and that handoff
// viability is approved independently of analysis viability. The honest way to assert that is not
// "the harness would notice a swapped measurement" — it is that a main-application measurement
// cannot become a satisfied Share Extension limit at all, by four independent routes, and that
// removing any one of them would leave the other three failing.
//
//   1. **Cell identity.** ``ResourceCell`` carries its target, so the two `peak-resident-memory`
//      measurements are different cells with different records. There is no member anywhere that
//      merges them.
//   2. **Budget selection.** ``ResourceTargetBinding`` selects its own budget through
//      ``ResourceBudgetSet/budget(for:)``. The caller never passes a budget, so there is no
//      argument to get wrong, and a set whose sides were swapped is refused at construction.
//   3. **Sample provenance.** ``ResourceSample`` records the process it was taken in, and the
//      runner refuses one whose target is not the cell's before any comparison.
//      ``QualifyingResourceEvidence`` refuses it again.
//   4. **Gate scope.** ``ResourceTargetReport/gateResult(for:)`` computes a gate from *this*
//      target's cells only, so a main-application report has no cells for `handoff-latency` and
//      records it as failed rather than as satisfied-elsewhere.
//
// Nothing here is release evidence. Every plan, budget, limit, and measurement is synthetic and
// no physical device ran.

/// What keeps one target's measurement from satisfying the other target's limit.
@Suite("Resource measurement target separation")
struct ResourceTargetSeparationTests {

    // MARK: - Cell identity

    @Test("The two targets' shared metrics are different cells")
    func sharedMetricsAreDistinctCells() throws {
        let binding = try Sample.resourceRunBinding()
        let shared: [ResourceMetric] = [
            .peakResidentMemory, .temporaryStorage, .energyImpact, .thermalState,
        ]
        for metric in shared {
            let main = ResourceCell(target: .mainApplication, subject: .budgetMetric(metric))
            let sharing = ResourceCell(target: .shareExtension, subject: .budgetMetric(metric))
            #expect(main != sharing)
            #expect(binding.mainApplication.requiredCells.contains(main))
            #expect(binding.shareExtension.requiredCells.contains(sharing))
            #expect(!binding.mainApplication.requiredCells.contains(sharing))
            #expect(!binding.shareExtension.requiredCells.contains(main))
            // And a shared metric answers a differently named gate per target.
            #expect(main.cellGate != sharing.cellGate)
        }
    }

    @Test("Each target's exclusive metrics belong to that target alone")
    func exclusiveMetricsBelongToOneTarget() throws {
        let binding = try Sample.resourceRunBinding()
        let mainOnly: [ResourceMetric] = [
            .decodedPixelCount, .coldModelLoadTime, .warmAnalysisLatency,
        ]
        let extensionOnly: [ResourceMetric] = [.encodedInputSize, .handoffLatency]
        let mainMetrics = Set(binding.mainApplication.requiredCells.compactMap(\.metric))
        let extensionMetrics = Set(binding.shareExtension.requiredCells.compactMap(\.metric))
        for metric in mainOnly {
            #expect(mainMetrics.contains(metric))
            #expect(!extensionMetrics.contains(metric))
        }
        for metric in extensionOnly {
            #expect(extensionMetrics.contains(metric))
            #expect(!mainMetrics.contains(metric))
        }
    }

    // MARK: - Budget selection

    @Test("A binding selects its own target's budget rather than being handed one")
    func aBindingSelectsItsOwnBudget() throws {
        let budgets = try Sample.resourceBudgets()
        for target in ExecutionTarget.allCases {
            let binding = try Sample.resourceTargetBinding(target: target, budgets: budgets)
            #expect(binding.budget.target == target)
            #expect(binding.budget.id == budgets.budget(for: target).id)
        }
        // And the two budgets are separate artifacts, so one cannot answer for both.
        #expect(budgets.mainApplication.id != budgets.shareExtension.id)
    }

    @Test("A budget set whose sides carry the wrong target is not constructible")
    func aSwappedBudgetSetIsNotConstructible() throws {
        // `ResourceBudgetSet` refuses the swap, which is why
        // `ResourceBindingError.budgetTargetMismatch` is a re-check rather than a reachable state
        // through a decoded pair. Asserted so the weaker true claim is on record: the binding's
        // check is defence in depth, not the only barrier.
        let main = try Sample.resourceBudget(
            target: .mainApplication,
            identifier: "budget.main-application"
        )
        let sharing = try Sample.resourceBudget(
            target: .shareExtension,
            identifier: "budget.share-extension"
        )
        var refused = false
        do {
            _ = try ResourceBudgetSet(mainApplication: sharing, shareExtension: main)
        } catch {
            refused = true
        }
        #expect(refused, "a swapped budget pair must not be constructible")
    }

    @Test("Each target's limits are read from its own budget")
    func limitsComeFromTheOwnTargetsBudget() throws {
        // The two targets get different ceilings for the metric they share, so a limit read from
        // the wrong budget would be visible.
        let mainLimits: [ResourceMetric: ValidatedLimit] = [
            .peakResidentMemory: .numeric(value: Sample.positiveDecimal(400), unit: .bytes)
        ]
        let extensionLimits: [ResourceMetric: ValidatedLimit] = [
            .peakResidentMemory: .numeric(value: Sample.positiveDecimal(50), unit: .bytes)
        ]
        let plan = try Sample.resourcePlan(limits: [:])
        _ = plan

        for (target, limits) in [
            (ExecutionTarget.mainApplication, mainLimits),
            (ExecutionTarget.shareExtension, extensionLimits),
        ] {
            let scopedPlan = try Sample.resourcePlan(limits: limits)
            let budgets = try Sample.resourceBudgets(limits: limits)
            let binding = try Sample.resourceTargetBinding(
                target: target,
                plan: scopedPlan,
                budgets: budgets
            )
            let cell = try #require(
                binding.requiredCells.first { $0.metric == .peakResidentMemory }
            )
            #expect(binding.limit(for: cell) == limits[.peakResidentMemory])
            #expect(binding.budget.limit(for: .peakResidentMemory) == limits[.peakResidentMemory])
        }
    }

    @Test("A measurement inside one target's limit can be outside the other's")
    func oneTargetsPassIsTheOthersFailure() throws {
        // The same measured magnitude, two different approved ceilings. It passes for the target
        // whose budget admits it and fails for the target whose budget does not, which is the
        // substantive form of "these limits are not interchangeable".
        let generous: [ResourceMetric: ValidatedLimit] = [
            .peakResidentMemory: .numeric(value: Sample.positiveDecimal(400), unit: .bytes)
        ]
        let strict: [ResourceMetric: ValidatedLimit] = [
            .peakResidentMemory: .numeric(value: Sample.positiveDecimal(5), unit: .bytes)
        ]
        var outcomes: [ExecutionTarget: Bool] = [:]
        for (target, limits) in [
            (ExecutionTarget.mainApplication, generous),
            (ExecutionTarget.shareExtension, strict),
        ] {
            let binding = try Sample.resourceTargetBinding(
                target: target,
                plan: try Sample.resourcePlan(limits: limits),
                budgets: try Sample.resourceBudgets(limits: limits)
            )
            let cell = try #require(
                binding.requiredCells.first { $0.metric == .peakResidentMemory }
            )
            var store = FakeResourceSampleStore.complete(for: binding)
            store.setValueEverywhere(.quantity(10, unit: .bytes), for: cell)
            let report = ResourceMeasurementRunner(samples: store).run(binding)
            outcomes[target] = report.outcome(of: cell).isSatisfied
        }
        #expect(outcomes[.mainApplication] == true)
        #expect(outcomes[.shareExtension] == false)
    }

    // MARK: - Sample provenance

    @Test("A sample taken in the other target's process cannot satisfy a cell")
    func aCrossTargetSampleCannotSatisfyACell() throws {
        for target in ExecutionTarget.allCases {
            let other: ExecutionTarget = target == .mainApplication
                ? .shareExtension
                : .mainApplication
            let binding = try Sample.resourceTargetBinding(target: target)
            var store = FakeResourceSampleStore.complete(for: binding)
            let cell = try #require(
                binding.requiredCells.first { $0.metric == .peakResidentMemory }
            )
            store.setTarget(other, for: cell)

            let report = ResourceMeasurementRunner(samples: store).run(binding)
            guard case let .crossTargetSample(observed, required) = report.outcome(of: cell) else {
                Issue.record("a sample from the other process must be refused")
                continue
            }
            #expect(observed == other)
            #expect(required == target)
            #expect(report.crossTargetCells.contains(cell))
            #expect(!report.satisfiedCells.contains(cell))
        }
    }

    @Test("A cross-target sample is refused even when it claims a physical iPhone")
    func aCrossTargetSampleIsRefusedDespiteAPhysicalClaim() throws {
        let binding = try Sample.resourceTargetBinding(target: .shareExtension)
        var store = FakeResourceSampleStore.complete(for: binding)
        store.setEnvironmentEverywhere(.physicalIPhone)
        let cell = try #require(binding.requiredCells.first { $0.metric == .thermalState })
        store.setTarget(.mainApplication, for: cell)

        let report = ResourceMeasurementRunner(samples: store).run(binding)
        #expect(!report.outcome(of: cell).isSatisfied)
        // And the refusal names target separation rather than the environment, so a release audit
        // reads the right reason.
        guard case .crossTargetSample = report.outcome(of: cell) else {
            Issue.record("the refusal must name target separation")
            return
        }
    }

    @Test("Qualifying evidence refuses a sample from the other target's process")
    func qualifyingEvidenceRefusesACrossTargetSample() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        let cell = try #require(binding.requiredCells.first { $0.metric == .peakResidentMemory })
        let foreign = ResourceSample(
            cell: cell,
            index: ResourceSampleIndex(ordinal: 0),
            value: .quantity(10, unit: .bytes),
            target: .shareExtension,
            environment: .physicalIPhone,
            configuration: binding.configuration,
            versionTuple: binding.versionTuple
        )
        // The second barrier, checked directly: even with a physical-iPhone claim, the bound
        // configuration, and the bound tuple, a foreign target produces no proof.
        let evidence = QualifyingResourceEvidence(
            samples: [foreign],
            plan: binding.plan,
            target: .mainApplication,
            configuration: binding.configuration,
            versionTuple: binding.versionTuple
        )
        #expect(evidence == nil)
    }

    // MARK: - Gate scope

    @Test("A target's report fails every gate belonging only to the other target")
    func aTargetsReportFailsTheOtherTargetsGates() throws {
        let binding = try Sample.resourceRunBinding()
        let report = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.complete(for: binding)
        )
        .run(binding)

        for target in ExecutionTarget.allCases {
            let scoped = report.report(for: target)
            for gate in DeviceGate.resourceGates where gate.measurementTarget != nil {
                let result = scoped.gateResult(for: gate)
                if gate.measurementTarget == target {
                    #expect(!result.cells.isEmpty, "\(gate.rawValue) needs \(target.rawValue) cells")
                } else {
                    #expect(
                        result.cells.isEmpty,
                        "\(gate.rawValue) must have no \(target.rawValue) cells"
                    )
                    #expect(
                        result.outcome == .failed,
                        "\(gate.rawValue) must not pass from a \(target.rawValue) report"
                    )
                    // Zero of the plan's declared samples for this target, not zero of zero.
                    #expect(result.measuredCompleteness == .zero)
                }
            }
        }
    }

    @Test("A parity or accessibility gate is failed by both targets' reports")
    func nonResourceGatesAreNotSatisfiedHere() throws {
        let binding = try Sample.resourceRunBinding()
        let report = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.complete(for: binding)
        )
        .run(binding)
        let foreignGates: [DeviceGate] = [
            .preprocessingParity, .rawLogitParity, .rankAgreement, .categoricalAgreement,
            .screenshotFidelity, .routeByteParity, .provenanceFixtures, .accessibilityMatrix,
            .localizationReadinessMatrix,
        ]
        for gate in foreignGates {
            #expect(!DeviceGate.resourceGates.contains(gate))
            #expect(report.outcome(of: gate) == .failed)
            for target in ExecutionTarget.allCases {
                #expect(report.report(for: target).gateResult(for: gate).cells.isEmpty)
                #expect(report.report(for: target).gateResult(for: gate).outcome == .failed)
            }
        }
    }

    @Test("The condition gates record one result per target rather than one merged result")
    func conditionGatesAreRecordedPerTarget() throws {
        let binding = try Sample.resourceRunBinding()
        let report = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.complete(for: binding)
        )
        .run(binding)
        for gate in [DeviceGate.cancellationResidualWork, .interruptionCleanup] {
            #expect(gate.measurementTarget == nil)
            #expect(!gate.isPerTargetResourceGate)
            let results = report.perTargetGateResults(for: gate)
            #expect(results.count == 2)
            #expect(Set(results.map(\.target)) == Set(ExecutionTarget.allCases))
            for result in results {
                #expect(result.cells.count == 1)
                #expect(result.cells.allSatisfy { $0.target == result.target })
                #expect(result.outcome == .failed)
            }
        }
        // A per-target gate reports once, for its own target.
        for gate in DeviceGate.resourceGates where gate.measurementTarget != nil {
            let results = report.perTargetGateResults(for: gate)
            #expect(results.count == 1)
            #expect(results.first?.target == gate.measurementTarget)
        }
    }

    // MARK: - Independent approval

    @Test("One target's overall outcome does not carry the other's")
    func targetOutcomesAreIndependent() throws {
        // Requirement 11.20 runs both ways: an extension pass does not approve the application,
        // and an application pass does not approve the handoff. Both targets fail here for the
        // same two reasons — measurements with no path, and a host process — and the report keeps
        // the two answers apart rather than reducing them to one.
        let binding = try Sample.resourceRunBinding()
        let report = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.complete(for: binding)
        )
        .run(binding)
        #expect(report.mainApplication.outcome == .failed)
        #expect(report.shareExtension.outcome == .failed)
        #expect(report.outcome == .failed)
        // The two reports carry different budgets and different required sets, which is the
        // structural form of "separate measurement sets".
        #expect(report.mainApplication.budget != report.shareExtension.budget)
        #expect(report.mainApplication.requiredCells != report.shareExtension.requiredCells)
        #expect(report.mainApplication.target == .mainApplication)
        #expect(report.shareExtension.target == .shareExtension)
    }

    @Test("Nothing in the resource sources merges the two targets' measurement sets")
    func noMemberMergesTheTwoTargets() throws {
        for name in ResourcePhysicalDeviceGateTests.resourceSources {
            let code = ResourcePhysicalDeviceGateTests.strippingComments(
                try ResourcePhysicalDeviceGateTests.moduleSource(named: name)
            )
            for token in [
                "allTargets", "anyTarget", "mergedTargets", "combinedBudget", "eitherTarget",
                "budget(for: .mainApplication)", "budget(for: .shareExtension)",
                "func merge", "func pool", "func flatten",
            ] {
                #expect(!code.contains(token), "\(name) must not reference \(token)")
            }
        }
    }
}
