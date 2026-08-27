import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// The three vocabularies this task adds, and the total mappings that keep them closed.
//
// A gap vocabulary earns its keep only if it is enumerable, disjoint from the others a release
// audit pools it with, and reached by something. This suite checks the first two directly and the
// third through the runner suites. It also checks the mappings written without a `default`, because
// their whole purpose is that adding a domain case becomes a compile error rather than a
// measurement that quietly stops being required — and a test that enumerates them catches a
// mapping that was widened with a catch-all after the fact.

/// Closed vocabularies, disjointness, and total mappings.
@Suite("Resource validation vocabularies")
struct ResourceVocabularyTests {

    // MARK: - Enumerability and shape

    @Test("Both gap vocabularies are enumerable, unique, and kebab-case")
    func gapVocabulariesAreWellFormed() {
        let owed = UnprovisionedResourceInput.allCases.map(\.rawValue)
        let unobservable = UnobservableResourceEvidence.allCases.map(\.rawValue)
        #expect(owed.count == 12)
        #expect(unobservable.count == 15)
        #expect(Set(owed).count == owed.count)
        #expect(Set(unobservable).count == unobservable.count)
        for value in owed + unobservable {
            #expect(!value.isEmpty)
            #expect(value == value.lowercased(), "\(value) must be lower-case")
            #expect(!value.contains(" "), "\(value) must not contain a space")
            #expect(!value.contains("_"), "\(value) must be kebab-case")
            #expect(!value.hasPrefix("-") && !value.hasSuffix("-"), "\(value) must not edge-hyphen")
        }
        // The description is the raw value, so an audit line and a decoded value cannot differ.
        for input in UnprovisionedResourceInput.allCases {
            #expect(input.description == input.rawValue)
        }
        for limit in UnobservableResourceEvidence.allCases {
            #expect(limit.description == limit.rawValue)
        }
    }

    @Test("The resource vocabularies are disjoint from the parity vocabularies")
    func vocabulariesAreDisjoint() {
        // A release audit pools these lists, so two different gaps must never collide on one
        // identifier. Checked against the two vocabularies this module declares, which the type
        // system makes available; the five declared in `DefAIkePresentation`, `DefAIkeApp`, and
        // `DefAIkeShareExtension` are not reachable from this target and were verified by
        // inspection across the whole `ios` tree.
        let owed = Set(UnprovisionedResourceInput.allCases.map(\.rawValue))
        let unobservable = Set(UnobservableResourceEvidence.allCases.map(\.rawValue))
        let parityOwed = Set(UnprovisionedParityInput.allCases.map(\.rawValue))
        let parityUnobservable = Set(UnobservableParityEvidence.allCases.map(\.rawValue))

        #expect(owed.isDisjoint(with: unobservable))
        #expect(owed.isDisjoint(with: parityOwed))
        #expect(owed.isDisjoint(with: parityUnobservable))
        #expect(unobservable.isDisjoint(with: parityOwed))
        #expect(unobservable.isDisjoint(with: parityUnobservable))
    }

    @Test("Seven findings block a measurement and eight only qualify it")
    func blockingLimitsArePartitioned() {
        let blocking = UnobservableResourceEvidence.allCases.filter(\.blocksMeasurement)
        let qualifying = UnobservableResourceEvidence.allCases.filter { !$0.blocksMeasurement }
        #expect(blocking.count == 7)
        #expect(qualifying.count == 8)
        #expect(blocking.count + qualifying.count == UnobservableResourceEvidence.allCases.count)

        let blockingValues = Set(blocking.map(\.rawValue))
        let expected: Set<String> = Set(
            [
                UnobservableResourceEvidence.temporaryStorageHasNoShippingMeasurementPath,
                .coldModelLoadTimeHasNoShippingMeasurementPath,
                .warmAnalysisLatencyHasNoShippingMeasurementPath,
                .handoffLatencyHasNoShippingMeasurementPath,
                .energyImpactHasNoShippingMeasurementPath,
                .cancellationResidualWorkHasNoPlanSpecification,
                .interruptionCleanupHasNoPlanSpecification,
            ]
            .map(\.rawValue)
        )
        #expect(blockingValues == expected)
    }

    @Test("Every sample fault is a refusal and none is recoverable")
    func sampleFaultsAreAllRefusals() {
        #expect(ResourceSampleFault.allCases.count == 4)
        for fault in ResourceSampleFault.allCases {
            #expect(!fault.description.isEmpty)
            // No fault carries a path, a framework code, or a partial value.
            #expect(!fault.description.contains("/"))
        }
        #expect(Set(ResourceSampleFault.allCases.map(\.description)).count == 4)
    }

    // MARK: - Total mappings

    @Test("Every target-and-metric pair maps to a gate or a named finding")
    func theGateMappingIsTotal() {
        for target in ExecutionTarget.allCases {
            for metric in ResourceMetric.allCases {
                let cell = ResourceCell(target: target, subject: .budgetMetric(metric))
                switch cell.cellGate {
                case let .gate(gate):
                    // A per-target gate must name this cell's own target.
                    if let owner = gate.measurementTarget {
                        #expect(owner == target, "\(gate.rawValue) must belong to \(target.rawValue)")
                    }
                case let .noMandatoryGate(limit):
                    #expect(!limit.blocksMeasurement)
                }
            }
            // And both condition subjects map to their own gate.
            let cancellation = ResourceCell(target: target, subject: .cancellationResidualWork)
            let interruption = ResourceCell(target: target, subject: .interruptionCleanup)
            #expect(cancellation.cellGate == .gate(.cancellationResidualWork))
            #expect(interruption.cellGate == .gate(.interruptionCleanup))
        }
    }

    @Test("Every required cell names what it is owed and what qualifies it")
    func everyCellNamesItsOwedInputAndLimits() {
        for target in ExecutionTarget.allCases {
            for subject in ResourceSubject.required(for: target) {
                let cell = ResourceCell(target: target, subject: subject)
                #expect(!cell.standingMeasurementLimits.isEmpty, "\(cell.description) has no limits")
                // The owed input follows the target for a workload and the subject for a
                // condition, and never crosses targets.
                switch subject {
                case .cancellationResidualWork:
                    #expect(cell.owedReleaseInput == .cancellationResidualWorkProcedure)
                case .interruptionCleanup:
                    #expect(cell.owedReleaseInput == .interruptionCleanupProcedure)
                case let .budgetMetric(metric) where metric.isCategorical:
                    #expect(cell.owedReleaseInput == .sustainedThermalWorkloadProcedure)
                case .budgetMetric:
                    let expected: UnprovisionedResourceInput = target == .mainApplication
                        ? .mainApplicationMeasurementWorkloads
                        : .shareExtensionMeasurementWorkloads
                    #expect(cell.owedReleaseInput == expected)
                }
            }
        }
    }

    @Test("The resource and parity gate sets partition the mandatory gates")
    func gateSetsPartitionTheMandatoryGates() {
        let resource = Set(DeviceGate.resourceGates)
        let parity = Set(DeviceGate.parityGates)
        #expect(resource.count == 13)
        #expect(parity.count == 7)
        #expect(resource.isDisjoint(with: parity))
        // Everything else is the accessibility and localization matrices, which are neither
        // module's subject.
        let remainder = Set(DeviceGate.allCases).subtracting(resource).subtracting(parity)
        #expect(remainder == [.accessibilityMatrix, .localizationReadinessMatrix])
        #expect(resource.union(parity).union(remainder) == DeviceGate.mandatoryGates)
        // The resource gates are in declaration order, so an audit reads a stable list.
        let ordered = DeviceGate.allCases.filter { resource.contains($0) }
        #expect(DeviceGate.resourceGates == ordered)
    }

    @Test("Eleven resource gates are per target and two cover both")
    func perTargetGatesAreIdentified() {
        let perTarget = DeviceGate.resourceGates.filter(\.isPerTargetResourceGate)
        let shared = DeviceGate.resourceGates.filter { !$0.isPerTargetResourceGate }
        #expect(perTarget.count == 11)
        #expect(shared == [.cancellationResidualWork, .interruptionCleanup])
        let mainGates = perTarget.filter { $0.measurementTarget == .mainApplication }
        let extensionGates = perTarget.filter { $0.measurementTarget == .shareExtension }
        #expect(mainGates.count == 6)
        #expect(extensionGates.count == 5)
        // No resource gate is provenance conditional, which is why `notExecuted` is unreachable
        // for one.
        #expect(DeviceGate.resourceGates.allSatisfy { !$0.isProvenanceConditional })
    }

    @Test("The required subject set is the target's budget metrics plus the two conditions")
    func requiredSubjectsFollowTheDomain() {
        for target in ExecutionTarget.allCases {
            let subjects = ResourceSubject.required(for: target)
            let metrics = subjects.compactMap(\.metric)
            #expect(Set(metrics) == ResourceMetric.requiredMetrics(for: target))
            #expect(subjects.count == metrics.count + 2)
            #expect(subjects.contains(.cancellationResidualWork))
            #expect(subjects.contains(.interruptionCleanup))
            #expect(Set(subjects).count == subjects.count)
            // The two condition subjects carry no metric, so they cannot be mistaken for one.
            #expect(ResourceSubject.cancellationResidualWork.metric == nil)
            #expect(ResourceSubject.interruptionCleanup.metric == nil)
        }
    }

    @Test("The observed value vocabulary mirrors the approved limit shapes")
    func observedValuesMirrorTheLimitShapes() {
        #expect(ObservedResourceValueKind.allCases.count == 2)
        let quantity = ObservedResourceValue.quantity(1, unit: .bytes)
        let thermal = ObservedResourceValue.thermalState(.nominal)
        #expect(quantity.kind == .quantity)
        #expect(thermal.kind == .thermalState)
        // A quantity carries a magnitude and a unit and no state; a state carries neither.
        #expect(quantity.magnitude == Decimal(1))
        #expect(quantity.unit == .bytes)
        #expect(quantity.state == nil)
        #expect(thermal.magnitude == nil)
        #expect(thermal.unit == nil)
        #expect(thermal.state == .nominal)
        // And the limit shapes are the same two, so no sample can arrive in a shape no approved
        // limit could have been written in.
        let numericLimit = ValidatedLimit.numeric(value: Sample.positiveDecimal(1), unit: .bytes)
        let thermalLimit = ValidatedLimit.thermal(maximumState: .fair)
        #expect(!numericLimit.isCategoricalLimit)
        #expect(thermalLimit.isCategoricalLimit)
    }

    // MARK: - One satisfying outcome

    @Test("Exactly one cell outcome satisfies a measurement")
    func onlyWithinLimitSatisfiesACell() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        let cell = try #require(binding.requiredCells.first { $0.metric == .peakResidentMemory })
        let limit = try #require(binding.limit(for: cell))
        let evidence = try #require(
            QualifyingResourceEvidence(
                samples: [
                    ResourceSample(
                        cell: cell,
                        index: ResourceSampleIndex(ordinal: 0),
                        value: .quantity(1, unit: .bytes),
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
        )
        let satisfying = ResourceCellOutcome.withinLimit(
            ResourceMeasurementAgreement(
                cell: cell,
                evidence: evidence,
                summaryValue: .quantity(1, unit: .bytes),
                limit: limit
            )
        )
        let others: [ResourceCellOutcome] = [
            .exceededLimit(
                ResourceLimitExceedance(
                    cell: cell,
                    detail: .magnitudeExceedsLimit(summary: 1, ceiling: 0, unit: .bytes)
                )
            ),
            .measurementMissing(
                ResourceMeasurementGap(
                    fault: .sampleAbsent,
                    owed: cell.owedReleaseInput,
                    standingLimits: cell.standingMeasurementLimits
                )
            ),
            .sampleCountIncomplete(observed: 1, declared: 5),
            .nonQualifyingEvidence(.notPhysicalIPhone(.developmentMac)),
            .crossTargetSample(observed: .shareExtension, required: .mainApplication),
            .measurementUnavailable(.energyImpactHasNoShippingMeasurementPath),
            .sampleKindMismatch(observed: .thermalState, required: .quantity),
            .sampleUnitMismatch(observed: .milliseconds, required: .bytes),
        ]

        #expect(satisfying.isSatisfied)
        #expect(satisfying.outcome == .passed)
        #expect(satisfying.wasMeasured)
        for outcome in others {
            #expect(!outcome.isSatisfied, "\(outcome.description) must not satisfy a cell")
            #expect(outcome.outcome == .failed)
            #expect(outcome.outcome != .notExecuted)
            #expect(!outcome.description.isEmpty)
        }
        // Only the two compared outcomes count as measured; nothing else may be read that way.
        let measured = others.filter(\.wasMeasured)
        #expect(measured.count == 1)
        #expect(measured.first?.description.hasPrefix("exceeded") == true)
    }

    @Test("A completeness ratio never reads whole from an incomplete or absent series")
    func completenessIsFailClosed() {
        let absent = ResourceMeasurementSummary.notDeclared
        #expect(absent.completeness == .zero)
        #expect(!absent.isComplete)

        let whole = ResourceMeasurementRunner.summarize(
            [.quantity(1, unit: .bytes), .quantity(2, unit: .bytes)],
            declared: 2,
            statistic: .maximum,
            limit: .numeric(value: Sample.positiveDecimal(10), unit: .bytes)
        )
        #expect(whole.isComplete)
        #expect(whole.completeness == .one)

        let short = ResourceMeasurementRunner.summarize(
            [.quantity(1, unit: .bytes)],
            declared: 4,
            statistic: .maximum,
            limit: .numeric(value: Sample.positiveDecimal(10), unit: .bytes)
        )
        #expect(!short.isComplete)
        #expect(short.completeness < .one)
        #expect(short.declaredSampleCount == 4)
        #expect(short.qualifyingSampleCount == 1)

        // More samples than the plan declared is also not complete: an equality, not a floor.
        let over = ResourceMeasurementRunner.summarize(
            [.quantity(1, unit: .bytes), .quantity(2, unit: .bytes), .quantity(3, unit: .bytes)],
            declared: 2,
            statistic: .maximum,
            limit: .numeric(value: Sample.positiveDecimal(10), unit: .bytes)
        )
        #expect(!over.isComplete)
    }

    @Test("A mixed-unit series produces no summary rather than one in an arbitrary unit")
    func mixedUnitsProduceNoSummary() {
        let mixed = ResourceMeasurementRunner.summarize(
            [.quantity(1, unit: .bytes), .quantity(2, unit: .milliseconds)],
            declared: 2,
            statistic: .maximum,
            limit: .numeric(value: Sample.positiveDecimal(10), unit: .bytes)
        )
        #expect(mixed.summaryValue == nil)
        #expect(mixed.rawValues.count == 2)
        #expect(mixed.qualifyingSampleCount == 2)
    }

    @Test("A thermal series summarized by a mean produces no value")
    func thermalMeanProducesNoSummary() {
        let summary = ResourceMeasurementRunner.summarize(
            [.thermalState(.nominal), .thermalState(.critical)],
            declared: 2,
            statistic: .mean,
            limit: .thermal(maximumState: .fair)
        )
        #expect(summary.summaryValue == nil)
        #expect(summary.summaryStatistic == .mean)
        #expect(summary.rawValues.count == 2)
    }

    @Test("A sample index is a position in the plan's series and nothing else")
    func sampleIndexIsAnOrdinal() {
        let first = ResourceSampleIndex(ordinal: 0)
        let second = ResourceSampleIndex(ordinal: 1)
        #expect(first < second)
        #expect(first.ordinal == 0)
        #expect(first.description == "#0")
        #expect(first != second)
    }

    @Test("A cell's ordering key and description identify its target")
    func cellIdentityCarriesItsTarget() {
        let main = ResourceCell(target: .mainApplication, subject: .budgetMetric(.peakResidentMemory))
        let sharing = ResourceCell(
            target: .shareExtension,
            subject: .budgetMetric(.peakResidentMemory)
        )
        #expect(main.orderingKey != sharing.orderingKey)
        #expect(main.description.hasPrefix("main-application/"))
        #expect(sharing.description.hasPrefix("share-extension/"))
        #expect(main.description.hasSuffix("peak-resident-memory"))
    }
}
