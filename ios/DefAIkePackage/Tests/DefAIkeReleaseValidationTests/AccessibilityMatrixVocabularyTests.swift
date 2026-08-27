import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// The vocabularies this task adds, and the total mappings that keep them closed.
//
// A gap vocabulary earns its keep only if it is enumerable, disjoint from the others a release audit
// pools it with, and reached by something. This suite checks the first two directly and the third
// through the runner suites. It also checks the mappings written without a `default`, because their
// whole purpose is that adding a workflow, an assistive condition, or a localization variant to the
// domain becomes a compile error rather than a matrix position that quietly stops being required.

/// Closed vocabularies, disjointness, and total mappings.
@Suite("Accessibility matrix vocabularies")
struct AccessibilityMatrixVocabularyTests {

    // MARK: - Enumerability and shape

    @Test("Both gap vocabularies are enumerable, unique, and kebab-case")
    func gapVocabulariesAreWellFormed() {
        let owed: [String] = UnprovisionedAccessibilityMatrixInput.allCases.map { $0.rawValue }
        let unobservable: [String] = UnobservableAccessibilityMatrixEvidence.allCases.map {
            $0.rawValue
        }
        #expect(owed.count == 12)
        #expect(unobservable.count == 12)
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
        for input in UnprovisionedAccessibilityMatrixInput.allCases {
            #expect(input.description == input.rawValue)
        }
        for limit in UnobservableAccessibilityMatrixEvidence.allCases {
            #expect(limit.description == limit.rawValue)
        }
    }

    @Test("The matrix vocabularies are disjoint from the parity and resource vocabularies")
    func vocabulariesAreDisjoint() {
        // A release audit pools these lists, so two different gaps must never collide on one
        // identifier. Checked against the four vocabularies this module declares, which the type
        // system makes available; the five declared in `DefAIkePresentation`, `DefAIkeApp`, and
        // `DefAIkeShareExtension` are not reachable from this target, and all 24 raw values added
        // here were verified by inspection across the whole `ios` tree to occur in one file.
        let owed = Set(UnprovisionedAccessibilityMatrixInput.allCases.map { $0.rawValue })
        let unobservable = Set(UnobservableAccessibilityMatrixEvidence.allCases.map { $0.rawValue })
        let parityOwed = Set(UnprovisionedParityInput.allCases.map { $0.rawValue })
        let parityUnobservable = Set(UnobservableParityEvidence.allCases.map { $0.rawValue })
        let resourceOwed = Set(UnprovisionedResourceInput.allCases.map { $0.rawValue })
        let resourceUnobservable = Set(UnobservableResourceEvidence.allCases.map { $0.rawValue })

        #expect(owed.isDisjoint(with: unobservable))
        for other in [parityOwed, parityUnobservable, resourceOwed, resourceUnobservable] {
            #expect(owed.isDisjoint(with: other))
            #expect(unobservable.isDisjoint(with: other))
        }
        // And the two domain vocabularies a matrix position is keyed on are disjoint too, which is
        // what makes one key namespace unambiguous.
        let conditions = Set(AssistiveCondition.allCases.map { $0.rawValue })
        let variants = Set(LocalizationTestVariant.allCases.map { $0.rawValue })
        #expect(conditions.isDisjoint(with: variants))
    }

    @Test("Three findings block a position and nine only qualify it")
    func blockingFindingsArePartitioned() {
        let blocking = UnobservableAccessibilityMatrixEvidence.allCases.filter { $0.blocksExercise }
        let qualifying = UnobservableAccessibilityMatrixEvidence.allCases.filter {
            !$0.blocksExercise
        }
        #expect(blocking.count == 3)
        #expect(qualifying.count == 9)
        let total = UnobservableAccessibilityMatrixEvidence.allCases.count
        #expect(blocking.count + qualifying.count == total)

        let blockingValues = Set(blocking.map { $0.rawValue })
        let expected: Set<String> = Set(
            [
                UnobservableAccessibilityMatrixEvidence
                    .localizationSubstitutionReachesNoRenderedString,
                .shareExtensionExposesNoAccessibilityProjection,
                .retryRecoveryControlIsCreditedToNoWorkflow,
            ]
            .map { $0.rawValue }
        )
        #expect(blockingValues == expected)
    }

    @Test("Every observation fault is a refusal and none is recoverable")
    func observationFaultsAreAllRefusals() {
        #expect(MatrixObservationFault.allCases.count == 4)
        for fault in MatrixObservationFault.allCases {
            #expect(!fault.description.isEmpty)
            // No fault carries a path, a framework code, or a partial value.
            #expect(!fault.description.contains("/"))
        }
        let descriptions = Set(MatrixObservationFault.allCases.map { $0.description })
        #expect(descriptions.count == 4)
    }

    @Test("The observed coverage vocabulary has exactly one completing case")
    func exactlyOneCoverageCompletesTheWorkflow() {
        #expect(ObservedWorkflowCoverage.allCases.count == 9)
        let completing = ObservedWorkflowCoverage.allCases.filter { $0.completesTheWorkflow }
        #expect(completing == [ObservedWorkflowCoverage.workflowCompleted])
        for coverage in ObservedWorkflowCoverage.allCases {
            #expect(!coverage.description.isEmpty)
        }
        let descriptions = Set(ObservedWorkflowCoverage.allCases.map { $0.description })
        #expect(descriptions.count == 9)
    }

    // MARK: - Total mappings

    @Test("The five automation variants are classified, and two of them are manual only")
    func automationSupportIsTotal() {
        var automatable: [String] = []
        var inert: [String] = []
        var manual: [String] = []
        for exercise in MatrixExercise.required {
            switch exercise.automationSupport {
            case .automatable:
                automatable.append(exercise.key)
            case .automatableWithoutEffect:
                inert.append(exercise.key)
            case .manualOnly:
                manual.append(exercise.key)
            }
        }
        #expect(automatable.sorted() == ["largest-dynamic-type", "reduce-motion"])
        #expect(manual.sorted() == ["switch-control", "voice-over"])
        #expect(inert.sorted() == ["bidirectional", "expansion", "long-word", "pseudolocalized"])
        #expect(automatable.count + inert.count + manual.count == MatrixExercise.required.count)

        // An inert or manual-only exercise never admits an automated observation, and only a
        // manual-only one demands imported human evidence.
        for exercise in MatrixExercise.required {
            let support = exercise.automationSupport
            switch support {
            case .automatable:
                #expect(support.admitsAutomatedEvidence)
                #expect(!support.requiresImportedManualEvidence)
                #expect(support.limit == nil)
            case .automatableWithoutEffect:
                #expect(!support.admitsAutomatedEvidence)
                #expect(!support.requiresImportedManualEvidence)
                #expect(support.limit != nil)
            case .manualOnly:
                #expect(!support.admitsAutomatedEvidence)
                #expect(support.requiresImportedManualEvidence)
                #expect(support.limit != nil)
            }
            #expect(!support.description.isEmpty)
        }
    }

    @Test("Every exercise names one of the two matrix gates and nothing else")
    func gateMappingIsTotal() {
        for condition in AssistiveCondition.allCases {
            #expect(MatrixExercise.assistive(condition).gate == DeviceGate.accessibilityMatrix)
        }
        for variant in LocalizationTestVariant.allCases {
            let exercise = MatrixExercise.localization(variant)
            #expect(exercise.gate == DeviceGate.localizationReadinessMatrix)
        }
        #expect(DeviceGate.matrixGates == [.accessibilityMatrix, .localizationReadinessMatrix])
        // Neither is provenance conditional, which is why `notExecuted` is unreachable for one.
        let conditional = DeviceGate.matrixGates.filter { $0.isProvenanceConditional }
        #expect(conditional.isEmpty)
        // And neither is a per-target resource gate.
        let targeted = DeviceGate.matrixGates.filter { $0.measurementTarget != nil }
        #expect(targeted.isEmpty)
    }

    @Test("The matrix gates are exactly what the parity and resource gate sets leave over")
    func matrixGatesCompleteTheMandatorySet() {
        let matrix = Set(DeviceGate.matrixGates)
        let parity = Set(DeviceGate.parityGates)
        let resource = Set(DeviceGate.resourceGates)
        #expect(matrix.count == 2)
        #expect(matrix.isDisjoint(with: parity))
        #expect(matrix.isDisjoint(with: resource))
        #expect(matrix.union(parity).union(resource) == DeviceGate.mandatoryGates)
        // In declaration order, so an audit reads a stable list.
        let ordered = DeviceGate.allCases.filter { matrix.contains($0) }
        #expect(DeviceGate.matrixGates == ordered)
    }

    @Test("Every position names what it is owed and what qualifies it")
    func everyCellNamesItsOwedInputAndLimits() throws {
        let configuration = try Sample.matrixConfiguration()
        for cell in AccessibilityMatrixCell.required(on: configuration) {
            #expect(!cell.standingLimits.isEmpty, "\(cell.description) has no standing findings")
            switch cell.exercise {
            case .localization:
                #expect(cell.owedReleaseInput == .localizationReadinessSuiteProcedure)
            case let .assistive(condition):
                switch condition {
                case .voiceOver:
                    #expect(cell.owedReleaseInput == .voiceOverManualRunRecord)
                case .switchControl:
                    #expect(cell.owedReleaseInput == .switchControlManualRunRecord)
                case .largestDynamicType, .reduceMotion:
                    #expect(cell.owedReleaseInput == .accessibilityMatrixProcedure)
                }
            }
            // Four findings apply to every position, because all four are properties of the layers
            // a matrix run observes rather than of any one position.
            for universal in [
                UnobservableAccessibilityMatrixEvidence.accessibilityMatrixCellHasNoPlanSpecification,
                .assistiveConditionIsAbsentFromThePlanMeasurementKey,
                .supportedMajorVersionSetIsDerivedFromPlanCandidates,
                .workflowOperabilityIsNotReachableFromThisModule,
            ] {
                #expect(cell.standingLimits.contains(universal), "\(cell.description)")
            }
        }
    }

    @Test("The required position set is every workflow against every exercise")
    func requiredCellsAreTheFullCrossProduct() throws {
        let configuration = try Sample.matrixConfiguration()
        let cells = AccessibilityMatrixCell.required(on: configuration)
        let workflows = AccessibilityWorkflow.allCases.count
        let exercises = MatrixExercise.required.count
        #expect(workflows == 7)
        #expect(exercises == 8)
        #expect(cells.count == workflows * exercises)
        #expect(cells.count == 56)
        #expect(Set(cells).count == cells.count)
        let keys = Set(cells.map { $0.matrixKey })
        #expect(keys.count == cells.count)
        // No position is uncovered, checked against the closed domain vocabularies.
        let uncovered = AccessibilityMatrixBinding.uncoveredPositions(in: cells)
        #expect(uncovered.isEmpty)
        // And the ordering is stable and total.
        let orderingKeys = cells.map { $0.orderingKey }
        #expect(orderingKeys == orderingKeys.sorted())
        // Twenty-eight per matrix.
        let accessibility = cells.filter { $0.gate == .accessibilityMatrix }
        let localization = cells.filter { $0.gate == .localizationReadinessMatrix }
        #expect(accessibility.count == 28)
        #expect(localization.count == 28)
    }

    @Test("Removing any workflow or exercise from the set is reported as uncovered")
    func uncoveredPositionsAreReported() throws {
        let configuration = try Sample.matrixConfiguration()
        let cells = AccessibilityMatrixCell.required(on: configuration)
        // Dropping every position of one workflow is reported by name.
        let withoutRetry = cells.filter { $0.workflow != .retry }
        let retryGaps = AccessibilityMatrixBinding.uncoveredPositions(in: withoutRetry)
        #expect(retryGaps.contains("retry"))
        // Dropping one crossing is reported too, even though both axes stay covered.
        let dropped = try #require(cells.first { $0.workflow == .analysis })
        let withoutOne = cells.filter { $0 != dropped }
        let crossingGaps = AccessibilityMatrixBinding.uncoveredPositions(in: withoutOne)
        let expectedKey = "\(dropped.workflow.rawValue)/\(dropped.exercise.key)"
        #expect(crossingGaps == [expectedKey])
    }

    @Test("A position's major iOS version is its configuration's and cannot be set")
    func majorVersionIsDerivedFromTheConfiguration() throws {
        let seventeen = try Sample.matrixConfiguration(hardware: "iPhone17.1", osVersion: "17.4.1")
        let eighteen = try Sample.matrixConfiguration(hardware: "iPhone18.2", osVersion: "18.0.0")
        let first = AccessibilityMatrixCell(
            workflow: .ingest,
            exercise: .assistive(.voiceOver),
            configuration: seventeen
        )
        let second = AccessibilityMatrixCell(
            workflow: .ingest,
            exercise: .assistive(.voiceOver),
            configuration: eighteen
        )
        #expect(first.osMajorVersion == 17)
        #expect(second.osMajorVersion == 18)
        #expect(first.matrixKey != second.matrixKey)
        #expect(first.matrixKey.contains("ios17"))
        #expect(second.matrixKey.contains("ios18"))
        #expect(first != second)
    }

    @Test("A position's recorded key is the domain's spelling, not a second one")
    func recordedKeyDelegatesToTheDomain() throws {
        let configuration = try Sample.matrixConfiguration()
        let identifier = ApprovedConfigurationID("configuration-0001")!
        let accessibility = AccessibilityMatrixCell(
            workflow: .resultReview,
            exercise: .assistive(.reduceMotion),
            configuration: configuration
        )
        let localization = AccessibilityMatrixCell(
            workflow: .resultReview,
            exercise: .localization(.pseudolocalized),
            configuration: configuration
        )
        let expectedAccessibility = AccessibilityResultCell.key(
            workflow: .resultReview,
            condition: .reduceMotion,
            osMajorVersion: 17,
            configuration: identifier
        )
        let expectedLocalization = LocalizationResultCell.key(
            workflow: .resultReview,
            variant: .pseudolocalized,
            osMajorVersion: 17,
            configuration: identifier
        )
        #expect(accessibility.recordedKey(as: identifier) == expectedAccessibility)
        #expect(localization.recordedKey(as: identifier) == expectedLocalization)
        // The runner's own key uses the hardware identifier, because a *candidate* configuration
        // has no approved identifier yet and minting one would name an approval nobody made.
        #expect(accessibility.matrixKey.hasSuffix(configuration.hardwareIdentifier.rawValue))
        #expect(!accessibility.matrixKey.contains(identifier.rawValue))
    }

    // MARK: - One satisfying outcome

    @Test("Exactly one cell outcome satisfies a position")
    func onlyExercisedSatisfiesAPosition() throws {
        let binding = try Sample.matrixBinding()
        let cell = try #require(Sample.readableCells(of: binding).first)
        let observation = MatrixCellObservation(
            cell: cell,
            coverage: .workflowCompleted,
            execution: Sample.admissibleExecution(for: cell),
            resultReference: Sample.matrixEvidence("evidence.matrix-run", digest: 0xB1),
            environment: .physicalIPhone,
            configuration: binding.configuration,
            versionTuple: binding.versionTuple
        )
        let evidence = try #require(
            QualifyingMatrixEvidence(
                observation: observation,
                cell: cell,
                plan: binding.plan,
                configuration: binding.configuration,
                versionTuple: binding.versionTuple
            )
        )
        let satisfying = AccessibilityMatrixCellOutcome.exercised(
            MatrixCellAgreement(cell: cell, evidence: evidence, coverage: .workflowCompleted)
        )
        let others: [AccessibilityMatrixCellOutcome] = [
            .workflowNotCompleted(.layoutNotReadable),
            .resultMissing(
                MatrixResultGap(
                    fault: .observationAbsent,
                    owed: cell.owedReleaseInput,
                    standingLimits: cell.standingLimits
                )
            ),
            .nonQualifyingEvidence(.notPhysicalIPhone(.developmentMac)),
            .exerciseUnavailable(.localizationSubstitutionReachesNoRenderedString),
            .automatedEvidenceNotAdmissible(.voiceOverCannotBeEnabledByAutomation),
            .manualEvidenceNotImported(.manualEvidenceAbsent),
        ]

        #expect(satisfying.isSatisfied)
        #expect(satisfying.outcome == .passed)
        #expect(satisfying.wasExecuted)
        for outcome in others {
            #expect(!outcome.isSatisfied, "\(outcome.description) must not satisfy a position")
            #expect(outcome.outcome == .failed)
            #expect(outcome.outcome != .notExecuted)
            #expect(!outcome.description.isEmpty)
        }
        // Only the two executed outcomes count as executed; nothing else may be read that way.
        let executed = others.filter { $0.wasExecuted }
        #expect(executed.count == 1)
        let firstExecuted = try #require(executed.first)
        #expect(firstExecuted.description.hasPrefix("did not complete"))
        // The evidence records a physical iPhone and nothing else.
        #expect(evidence.environment == .physicalIPhone)
    }

    @Test("Every reason an imported manual result is refused has its own description")
    func manualRefusalsAreNamed() {
        let refusals: [NonImportableManualEvidence] = [
            .manualEvidenceAbsent,
            .authorizationIsForAnotherCell(authorized: "a", required: "b"),
            .authorizationDecisionIsNotApproved(.rejected),
            .authorizationCitesItsOwnResult,
            .authorizationSharesTheResultDigest,
        ]
        for refusal in refusals {
            #expect(!refusal.description.isEmpty)
        }
        let descriptions = Set(refusals.map { $0.description })
        #expect(descriptions.count == refusals.count)
    }

    @Test("A coverage ratio never reads whole from an incomplete or absent position set")
    func coverageIsFailClosed() throws {
        let binding = try Sample.matrixBinding()
        let empty = AccessibilityMatrixRunner(
            observations: FakeMatrixObservationStore.empty(for: binding)
        )
        .run(binding)
        // Nothing was observed, so the coverage is zero over the required count rather than
        // undefined or whole.
        #expect(empty.recordedCoverage == .zero)
        #expect(empty.satisfiedCells.isEmpty)
        #expect(empty.unsatisfiedCells.count == binding.requiredCells.count)

        // An empty position set reads zero rather than one: nothing to execute is not complete
        // coverage.
        let none = AccessibilityMatrixConfigurationReport.coverage(of: [], in: empty)
        #expect(none == .zero)

        // And a run whose every readable position was observed still reads below one, because the
        // 36 blocked positions stay in the denominator. Twenty of 56, never 20 of 20.
        //
        // The satisfied positions here are the deliberate contradiction the sibling runners rest
        // on: an observation's environment is a claim its producer makes, and every observation in
        // the complete store claims a physical iPhone, so the *positions* pass. What no host run can
        // do is make a *gate* pass, which
        // ``AccessibilityMatrixPhysicalDeviceGateTests`` asserts and the last two lines here
        // restate.
        let complete = AccessibilityMatrixRunner(
            observations: FakeMatrixObservationStore.complete(for: binding)
        )
        .run(binding)
        #expect(complete.recordedCoverage < .one)
        #expect(complete.satisfiedCells.count == Sample.readableCells(of: binding).count)
        #expect(complete.satisfiedCells.count == 20)
        #expect(complete.unsatisfiedCells.count == 36)
        #expect(complete.outcome == .failed)
        for gate in DeviceGate.matrixGates {
            #expect(complete.gateResult(for: gate).outcome == .failed)
        }
    }

    @Test("The known GateResultReference defect is not relied on anywhere here")
    func inapplicableGateReferenceIsNotTrusted() throws {
        // `GateResultReference.isSatisfied` answers `decision.isApproved` for a `notApplicable`
        // gate, so a reference can report itself satisfied without any run having happened. That is
        // a defect this task reports rather than fixes, and nothing in this module consults it: both
        // matrix gates are always applicable and their outcome is computed from positions.
        let reference = try GateResultReference(
            gate: .accessibilityMatrix,
            applicability: Sample.notApplicable(),
            outcome: .notExecuted,
            result: Sample.evidence("evidence.matrix"),
            environment: .developmentMac
        )
        #expect(reference.outcome == .notExecuted)
        #expect(reference.isSatisfied, "the defect is real and is asserted so it stays visible")

        let binding = try Sample.matrixBinding()
        let report = AccessibilityMatrixRunner(
            observations: FakeMatrixObservationStore.complete(for: binding)
        )
        .run(binding)
        for gate in DeviceGate.matrixGates {
            let result = report.gateResult(for: gate)
            #expect(result.applicability == .applicable)
            #expect(result.outcome == .failed)
            #expect(result.outcome != .notExecuted)
        }
    }
}
