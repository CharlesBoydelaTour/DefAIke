import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// What the matrix runner records, and what it refuses to record.
//
// Three groups, and they answer three different questions:
//
//   * *the binding* — can this plan, configuration, and version tuple describe one coherent matrix
//     run at all? Every reconciliation clause is checked by changing one field of an otherwise
//     complete set of inputs.
//   * *the run* — for every position the binding owes, what does the runner do with a missing,
//     unreadable, unactivatable, misfiled, wrongly executed, unauthorized, or completing
//     observation? Twenty positions per configuration are read and 36 are refused before the seam,
//     and both halves are asserted rather than assumed.
//   * *the recorded cells* — what does the run publish into the domain's matrix shape, and what does
//     it decline to publish? An unexecuted position produces nothing at all, which is what makes it
//     land in `AccessibilityGateMatrix.missingCellKeys` rather than as a result.
//
// Nothing here is release evidence. Every plan, configuration, version tuple, imported result, and
// authorization below is synthetic, no physical device ran, no human executed anything, and no
// approval was granted.

/// Binding reconciliation, one run, and the recorded cells it produces.
@Suite("Accessibility matrix runner")
struct AccessibilityMatrixRunnerTests {

    // MARK: - The binding

    @Test("A complete plan, configuration, and version tuple bind into 56 positions")
    func aCoherentBindingCoversTheWholeMatrix() throws {
        let binding = try Sample.matrixBinding()
        #expect(binding.requiredCells.count == 56)
        #expect(binding.osMajorVersion == 17)
        #expect(binding.requiredCells(for: .accessibilityMatrix).count == 28)
        #expect(binding.requiredCells(for: .localizationReadinessMatrix).count == 28)
        // A gate this module does not record has no positions at all.
        #expect(binding.requiredCells(for: .preprocessingParity).isEmpty)
        #expect(binding.requiredCells(for: .coldModelLoad).isEmpty)
    }

    @Test("A configuration the plan does not enumerate cannot be bound")
    func aForeignConfigurationIsRefused() throws {
        let plan = try Sample.matrixPlan()
        let foreign = try Sample.matrixConfiguration(hardware: "iPhone98.1")
        // Every untyped builder is evaluated outside the `do`, so the block throws exactly
        // `AccessibilityMatrixBindingError` and a plain `catch` binds that type. A `do` mixing
        // typed and untyped throws would widen the caught value to `any Error`.
        let tuple = try Sample.matrixVersionTuple()
        var thrown: AccessibilityMatrixBindingError?
        do {
            _ = try AccessibilityMatrixBinding(
                plan: plan,
                configuration: foreign,
                versionTuple: tuple
            )
        } catch {
            thrown = error
        }
        let finding = try #require(thrown)
        guard case .configurationNotInPlan = finding else {
            Issue.record("a configuration outside the plan must be refused by name")
            return
        }
        #expect(!finding.description.isEmpty)
    }

    @Test("A version tuple naming another plan, bundle, manifest, or build cannot be bound")
    func aForeignVersionTupleIsRefused() throws {
        let plan = try Sample.matrixPlan()
        let configuration = plan.candidateConfigurations[0]

        func refusal(_ tuple: ValidationVersionTuple) -> AccessibilityMatrixBindingError? {
            do {
                _ = try AccessibilityMatrixBinding(
                    plan: plan,
                    configuration: configuration,
                    versionTuple: tuple
                )
                return nil
            } catch {
                return error
            }
        }

        let otherPlan = try Sample.matrixVersionTuple(validationPlan: "plan.other")
        let otherBundle = try Sample.matrixVersionTuple(
            modelBundle: ModelBundleID("bundle.other")!
        )
        let otherManifest = try Sample.matrixVersionTuple(capabilityManifest: "manifest.other")
        let otherBuild = try Sample.matrixVersionTuple(appBuild: AppBuildID("build.other")!)

        guard case .versionTuplePlanMismatch = try #require(refusal(otherPlan)) else {
            Issue.record("another plan must be refused by name")
            return
        }
        guard case .versionTupleModelBundleMismatch = try #require(refusal(otherBundle)) else {
            Issue.record("another Model Bundle must be refused by name")
            return
        }
        guard case .versionTupleCapabilityManifestMismatch = try #require(refusal(otherManifest))
        else {
            Issue.record("another capability manifest must be refused by name")
            return
        }
        // Requirements 12.14 and 12.18 block the affected *application version*, so evidence
        // belonging to two builds cannot form one matrix.
        guard case .versionTupleAppBuildMismatch = try #require(refusal(otherBuild)) else {
            Issue.record("another application build must be refused by name")
            return
        }
    }

    @Test("A plan cannot declare that a missing result passes")
    func theMissingResultRuleCannotBeRelaxed() throws {
        // The plan schema refuses `treat-as-pass` outright, so the binding's own check is
        // unreachable through a decoded plan. Asserted where the refusal actually lives, and the
        // binding keeps its check because relying on another type's invariant for the one behaviour
        // Requirements 12.14 and 12.18 turn on would leave nothing here that fails when the
        // invariant changes.
        var thrown: (any Error)?
        do {
            _ = try DeviceValidationPlan(
                id: Sample.artifact("plan.relaxed"),
                schemaVersion: .v1,
                candidateConfigurations: [try Sample.matrixConfiguration()],
                fixtureSuite: Sample.artifact("suite.fixtures"),
                modelBundle: Sample.bundle(),
                capabilityManifest: Sample.artifact("manifest.capability"),
                comparisons: [
                    try ComparisonSpecification(
                        metric: .categoricalOutcome,
                        reference: Sample.evidence("evidence.reference"),
                        tolerance: nil,
                        requiredAgreement: Sample.ratio(1)
                    )
                ],
                measurements: [],
                missingResultRule: .treatAsPass,
                approval: Sample.approval()
            )
        } catch {
            thrown = error
        }
        #expect(thrown != nil, "a plan whose missing result passes must not decode")
        // And the vocabulary can still name the refusal, so a future schema change is caught here.
        let named = AccessibilityMatrixBindingError.missingResultRuleNotFailure(.treatAsPass)
        #expect(named.description.contains("treat-as-pass"))
    }

    @Test("A coverage binding spans every plan candidate and every major version they run")
    func coverageSpansEveryCandidate() throws {
        let seventeen = try Sample.matrixConfiguration(hardware: "iPhone17.1", osVersion: "17.4.1")
        let eighteen = try Sample.matrixConfiguration(hardware: "iPhone18.2", osVersion: "18.1.0")
        let plan = try Sample.matrixPlan(configurations: [eighteen, seventeen])
        let binding = try Sample.matrixCoverageBinding(plan: plan)

        #expect(binding.bindings.count == 2)
        #expect(binding.supportedMajorVersions == [17, 18])
        #expect(binding.requiredCells.count == 112)
        // Ascending by hardware identifier, so two runs enumerate identically.
        let hardware = binding.configurations.map { $0.hardwareIdentifier.rawValue }
        #expect(hardware == ["iPhone17.1", "iPhone18.2"])
        #expect(binding.binding(for: seventeen)?.osMajorVersion == 17)
        #expect(binding.binding(for: eighteen)?.osMajorVersion == 18)
        let unknown = try Sample.matrixConfiguration(hardware: "iPhone99.9")
        #expect(binding.binding(for: unknown) == nil)
        // Every position is distinct, so no two devices' evidence pools under one key.
        let keys = Set(binding.requiredCells.map { $0.matrixKey })
        #expect(keys.count == 112)
    }

    @Test("A coverage binding refuses a candidate whose version tuple does not match")
    func coverageRefusesAnyCandidateThatDoesNotReconcile() throws {
        // One candidate built for another application build is enough: the whole coverage refuses
        // rather than covering the candidates that happen to reconcile.
        let matching = try Sample.matrixConfiguration(hardware: "iPhone17.1")
        let other = try Sample.matrixConfiguration(
            hardware: "iPhone18.2",
            osVersion: "18.0.0",
            appBuild: AppBuildID("build.other")!
        )
        let plan = try Sample.matrixPlan(configurations: [matching, other])
        let tuple = try Sample.matrixVersionTuple()
        var thrown: AccessibilityMatrixBindingError?
        do {
            _ = try AccessibilityMatrixCoverageBinding(plan: plan, versionTuple: tuple)
        } catch {
            thrown = error
        }
        guard case .versionTupleAppBuildMismatch = try #require(thrown) else {
            Issue.record("a candidate built for another version must refuse the whole coverage")
            return
        }
    }

    // MARK: - What the run refuses before the seam

    @Test("Thirty-six of 56 positions are refused before any observation is read")
    func blockedPositionsAreRefusedByName() throws {
        let binding = try Sample.matrixBinding()
        let store = FakeMatrixObservationStore.complete(for: binding)
        let report = AccessibilityMatrixRunner(observations: store).run(binding)

        let blocked = Sample.blockedCells(of: binding)
        let readable = Sample.readableCells(of: binding)
        #expect(blocked.count == 36)
        #expect(readable.count == 20)
        #expect(blocked.count + readable.count == binding.requiredCells.count)

        var byFinding: [String: Int] = [:]
        for cell in blocked {
            guard case let .exerciseUnavailable(limit) = report.outcome(of: cell) else {
                Issue.record("a blocked position must report a blocking finding")
                return
            }
            #expect(limit.blocksExercise)
            byFinding[limit.rawValue, default: 0] += 1
        }
        // All 28 localization positions, plus the handoff-consent and retry assistive positions.
        #expect(byFinding["localization-substitution-reaches-no-rendered-string"] == 28)
        #expect(byFinding["share-extension-exposes-no-accessibility-projection"] == 4)
        #expect(byFinding["retry-recovery-control-is-credited-to-no-workflow"] == 4)
        #expect(report.unexercisableCells.count == 36)

        // A refused position produces no result reference, so it can never become a recorded cell.
        for cell in blocked {
            #expect(report.record(of: cell).resultReference == nil)
            #expect(report.record(of: cell).execution == nil)
            #expect(report.record(of: cell).coverage == nil)
        }
    }

    @Test("Every workflow of the localization matrix is blocked, whatever the variant")
    func theLocalizationMatrixIsEntirelyBlocked() throws {
        let binding = try Sample.matrixBinding()
        let report = AccessibilityMatrixRunner(
            observations: FakeMatrixObservationStore.complete(for: binding)
        )
        .run(binding)
        let localization = binding.requiredCells(for: .localizationReadinessMatrix)
        #expect(localization.count == 28)
        for cell in localization {
            guard case let .exerciseUnavailable(limit) = report.outcome(of: cell) else {
                Issue.record("a localization position must be refused before the seam")
                return
            }
            #expect(limit == .localizationSubstitutionReachesNoRenderedString)
        }
        // And the run states the two independent reasons the substitution is inert.
        let standing = Set(report.standingLimits)
        #expect(standing.contains(.localizationCatalogKeysAreDisjointFromAddressedKeys))
        #expect(standing.contains(.fixedPixelLabelTextBypassesTheCopyCatalog))
    }

    // MARK: - What the run does with an observation

    @Test("A missing, unreadable, or unactivatable observation is a failing position")
    func everyObservationFaultFailsThePosition() throws {
        let binding = try Sample.matrixBinding()
        let readable = Sample.readableCells(of: binding)
        let subject = try #require(readable.first)

        var absent = FakeMatrixObservationStore.complete(for: binding)
        absent.remove(subject)
        var unreadable = FakeMatrixObservationStore.complete(for: binding)
        unreadable.makeUnreadable(subject)
        var inert = FakeMatrixObservationStore.complete(for: binding)
        inert.makeNotActivatable(subject)
        var unavailable = FakeMatrixObservationStore.complete(for: binding)
        unavailable.isUnavailable = true

        let expected: [(FakeMatrixObservationStore, MatrixObservationFault)] = [
            (absent, .observationAbsent),
            (unreadable, .observationUnreadable),
            (inert, .conditionNotActivatable),
        ]
        for (store, fault) in expected {
            let report = AccessibilityMatrixRunner(observations: store).run(binding)
            guard case let .resultMissing(gap) = report.outcome(of: subject) else {
                Issue.record("an unread position must report a missing result")
                return
            }
            #expect(gap.fault == fault)
            #expect(gap.owed == subject.owedReleaseInput)
            #expect(!gap.standingLimits.isEmpty)
            #expect(report.missingResultCells.contains(subject))
            // Every other readable position is unaffected, so the refusal is per position.
            let others = readable.filter { $0 != subject }
            #expect(others.allSatisfy { report.outcome(of: $0).isSatisfied })
        }

        // An unavailable store fails every readable position rather than reporting nothing.
        let empty = AccessibilityMatrixRunner(observations: unavailable).run(binding)
        #expect(empty.missingResultCells.count == 20)
        #expect(empty.satisfiedCells.isEmpty)
        #expect(empty.recordedCoverage == .zero)
    }

    @Test("An observation filed against another position answers neither")
    func aMisfiledObservationAnswersNothing() throws {
        let binding = try Sample.matrixBinding()
        let readable = Sample.readableCells(of: binding)
        let subject = try #require(readable.first)
        let other = try #require(readable.last)
        #expect(subject != other)

        var store = FakeMatrixObservationStore.complete(for: binding)
        store.misfile(subject, as: other)
        let report = AccessibilityMatrixRunner(observations: store).run(binding)

        guard case let .resultMissing(gap) = report.outcome(of: subject) else {
            Issue.record("a misfiled observation must leave its position missing")
            return
        }
        #expect(gap.fault == .observationAbsent)
        #expect(report.record(of: subject).resultReference == nil)
        // And the position it claimed to be is answered by its own observation, not twice.
        #expect(report.outcome(of: other).isSatisfied)
    }

    @Test("Each non-completing observation names the clause that failed")
    func aFailedClauseIsNamed() throws {
        let binding = try Sample.matrixBinding()
        let readable = Sample.readableCells(of: binding)
        let subject = try #require(readable.first)
        let failing = ObservedWorkflowCoverage.allCases.filter { !$0.completesTheWorkflow }
        #expect(failing.count == 8)

        for coverage in failing {
            var store = FakeMatrixObservationStore.complete(for: binding)
            store.setCoverage(coverage, for: subject)
            let report = AccessibilityMatrixRunner(observations: store).run(binding)
            guard case let .workflowNotCompleted(observed) = report.outcome(of: subject) else {
                Issue.record("a non-completing observation must be reported as such")
                return
            }
            #expect(observed == coverage)
            let record = report.record(of: subject)
            // The observation is kept beside the conclusion, so a criterion cannot be chosen after
            // the fact and presented as predeclared.
            #expect(record.coverage == coverage)
            #expect(record.outcome.wasExecuted)
            #expect(!record.outcome.isSatisfied)
            #expect(record.outcome.outcome == .failed)
        }
    }

    // MARK: - Manual evidence

    @Test("VoiceOver and Switch Control positions refuse an automated observation")
    func anAutomatedRunCannotAnswerAManualPosition() throws {
        let binding = try Sample.matrixBinding()
        let manualOnly = binding.requiredCells.filter {
            $0.automationSupport.requiresImportedManualEvidence
        }
        #expect(manualOnly.count == 14)

        var store = FakeMatrixObservationStore.complete(for: binding)
        for cell in manualOnly { store.setExecution(.automated, for: cell) }
        let report = AccessibilityMatrixRunner(observations: store).run(binding)

        var refused = 0
        for cell in manualOnly where cell.blockingLimit == nil {
            guard case let .automatedEvidenceNotAdmissible(limit) = report.outcome(of: cell) else {
                Issue.record("an automated run must not answer a manual-only position")
                return
            }
            let expected: UnobservableAccessibilityMatrixEvidence
            switch cell.exercise {
            case .assistive(.voiceOver): expected = .voiceOverCannotBeEnabledByAutomation
            default: expected = .switchControlCannotBeEnabledByAutomation
            }
            #expect(limit == expected)
            refused += 1
        }
        #expect(refused == 10, "ten manual-only positions are reachable at all")
        #expect(report.manualEvidenceGapCells.count == 10)
        // And the run states that it owes both an authorization and a host that can run these.
        let owed = Set(report.owedInputs)
        #expect(owed.contains(.manualExecutionAuthorization))
        #expect(owed.contains(.assistiveTechnologyDeviceTestHost))
        #expect(owed.contains(.voiceOverManualRunRecord))
        #expect(owed.contains(.switchControlManualRunRecord))
    }

    @Test("An imported manual result needs an approval for that exact position")
    func aBlanketApprovalDoesNotAnswerAPosition() throws {
        let binding = try Sample.matrixBinding()
        let manual = try #require(
            Sample.readableCells(of: binding).first {
                $0.automationSupport.requiresImportedManualEvidence
            }
        )
        let elsewhere = try #require(
            Sample.readableCells(of: binding).first {
                $0.automationSupport.requiresImportedManualEvidence && $0 != manual
            }
        )

        var store = FakeMatrixObservationStore.complete(for: binding)
        store.setExecution(
            .manual(
                ImportedManualEvidence(
                    cellKey: elsewhere.matrixKey,
                    importedResult: Sample.matrixEvidence("evidence.manual-run", digest: 0xA1),
                    authorization: Sample.matrixApproval("approval.manual", digest: 0xA2)
                )
            ),
            for: manual
        )
        let report = AccessibilityMatrixRunner(observations: store).run(binding)
        guard case let .manualEvidenceNotImported(reason) = report.outcome(of: manual) else {
            Issue.record("an approval for another position must not answer this one")
            return
        }
        guard case let .authorizationIsForAnotherCell(authorized, required) = reason else {
            Issue.record("the refusal must name both positions")
            return
        }
        #expect(authorized == elsewhere.matrixKey)
        #expect(required == manual.matrixKey)
    }

    @Test("A rejected or self-citing authorization does not answer a position")
    func anUnapprovedOrSelfCitingAuthorizationIsRefused() throws {
        let binding = try Sample.matrixBinding()
        let manual = try #require(
            Sample.readableCells(of: binding).first {
                $0.automationSupport.requiresImportedManualEvidence
            }
        )
        let run = Sample.matrixEvidence("evidence.manual-run", digest: 0xA1)

        let rejected = ImportedManualEvidence(
            cellKey: manual.matrixKey,
            importedResult: run,
            authorization: Sample.matrixApproval(
                "approval.manual",
                digest: 0xA2,
                decision: .rejected
            )
        )
        // The same artifact standing for both the run and its approval: a run approving itself.
        let selfCiting = ImportedManualEvidence(
            cellKey: manual.matrixKey,
            importedResult: run,
            authorization: Sample.matrixApproval("evidence.manual-run", digest: 0xA3)
        )
        // Different artifact identifiers, identical content: the same finding reached by digest.
        let sharedDigest = ImportedManualEvidence(
            cellKey: manual.matrixKey,
            importedResult: run,
            authorization: Sample.matrixApproval("approval.manual", digest: 0xA1)
        )

        for imported in [rejected, selfCiting, sharedDigest] {
            var store = FakeMatrixObservationStore.complete(for: binding)
            store.setExecution(.manual(imported), for: manual)
            let report = AccessibilityMatrixRunner(observations: store).run(binding)
            guard case let .manualEvidenceNotImported(reason) = report.outcome(of: manual) else {
                Issue.record("an inadmissible authorization must not answer a position")
                return
            }
            #expect(!reason.description.isEmpty)
            #expect(!report.outcome(of: manual).isSatisfied)
        }

        // Named individually, so the three are distinguishable in an audit.
        #expect(
            QualifyingMatrixEvidence.refusal(for: rejected, answering: manual)
                == .authorizationDecisionIsNotApproved(.rejected)
        )
        #expect(
            QualifyingMatrixEvidence.refusal(for: selfCiting, answering: manual)
                == .authorizationCitesItsOwnResult
        )
        #expect(
            QualifyingMatrixEvidence.refusal(for: sharedDigest, answering: manual)
                == .authorizationSharesTheResultDigest
        )
        // And a properly imported pair is admissible.
        let sound = Sample.importedManual(for: manual)
        #expect(QualifyingMatrixEvidence.refusal(for: sound, answering: manual) == nil)
    }

    @Test("A sound manual pair is admissible on an automatable position, and is recorded as manual")
    func theExecutionModeIsRecordedRatherThanConstrainedBothWays() throws {
        // The rule is one-directional, and this is the narrower true claim rather than the symmetric
        // one it would be tempting to assert. A position whose condition no automation can establish
        // refuses an automated observation. A position automation *can* establish does not refuse a
        // sound imported human pair: an approved authorization naming that exact position, behind a
        // separate versioned digest-bound record, is admissible evidence wherever it appears, and
        // refusing it would be this module deciding that a human cannot execute something a harness
        // could. What the runner does instead is record which mode answered the position, so an audit
        // can see that a manual result stood where an automated one was possible.
        let binding = try Sample.matrixBinding()
        let automatable = try #require(
            Sample.readableCells(of: binding).first {
                $0.automationSupport.admitsAutomatedEvidence
            }
        )
        var store = FakeMatrixObservationStore.complete(for: binding)
        store.setExecution(.manual(Sample.importedManual(for: automatable)), for: automatable)
        let report = AccessibilityMatrixRunner(observations: store).run(binding)
        // A sound imported pair passes the manual checks, and the position is then satisfied on the
        // observation's claimed environment. What this asserts is the narrower true claim: the
        // execution mode a position admits is a property of the condition, and the runner records
        // which mode answered it rather than discarding that.
        let recorded = report.record(of: automatable)
        let execution = try #require(recorded.execution)
        guard case .manual = execution else {
            Issue.record("the recorded execution mode must be the one the observation used")
            return
        }
        #expect(automatable.automationSupport.admitsAutomatedEvidence)
        #expect(!automatable.automationSupport.requiresImportedManualEvidence)
    }

    // MARK: - Recorded cells

    @Test("An unexecuted position produces no recorded cell at all")
    func anUnexecutedPositionCannotBecomeARecordedCell() throws {
        let binding = try Sample.matrixBinding()
        let identifier = ApprovedConfigurationID("configuration-0001")!
        let report = AccessibilityMatrixRunner(
            observations: FakeMatrixObservationStore.empty(for: binding)
        )
        .run(binding)

        let produced = try report.recordedCells(as: identifier)
        #expect(produced.isEmpty)
        for cell in binding.requiredCells {
            #expect(try report.recordedCell(of: cell, as: identifier) == nil)
        }
        // And that absence is exactly what the domain matrix reports as missing, which is
        // Requirements 12.14 and 12.18's "missing" written down.
        let matrix = try AccessibilityGateMatrix(
            id: Sample.artifact("matrix.accessibility"),
            schemaVersion: .v1,
            configurations: [identifier],
            supportedMajorVersions: [binding.osMajorVersion],
            accessibilityCells: [],
            localizationCells: []
        )
        #expect(matrix.missingCellKeys.count == 56)
        #expect(!matrix.isComplete)
    }

    @Test("A recorded cell carries the computed outcome and the observed execution mode")
    func recordedCellsCarryWhatTheRunRecorded() throws {
        let binding = try Sample.matrixBinding()
        let identifier = ApprovedConfigurationID("configuration-0001")!
        let report = AccessibilityMatrixRunner(
            observations: FakeMatrixObservationStore.complete(for: binding)
        )
        .run(binding)

        let produced = try report.recordedCells(as: identifier)
        // Only the 20 readable positions produced a run at all.
        #expect(produced.count == 20)
        let accessibility = produced.filter {
            if case .accessibility = $0 { return true } else { return false }
        }
        #expect(accessibility.count == 20, "no localization position was exercised")

        // Every produced key matches the position's own domain spelling.
        let producedKeys = Set(produced.map { $0.key })
        let expectedKeys = Set(
            Sample.readableCells(of: binding).map { $0.recordedKey(as: identifier) }
        )
        #expect(producedKeys == expectedKeys)

        // A manual position records the imported approval as its execution mode, which the domain
        // cell schema independently refuses to accept as a pass unless it is an approval.
        let manual = try #require(
            Sample.readableCells(of: binding).first {
                $0.automationSupport.requiresImportedManualEvidence
            }
        )
        let recorded = try #require(try report.recordedCell(of: manual, as: identifier))
        guard case let .accessibility(cell) = recorded else {
            Issue.record("an assistive position records an accessibility cell")
            return
        }
        guard case let .manual(importedEvidence) = cell.execution else {
            Issue.record("a manual position records its imported approval")
            return
        }
        #expect(importedEvidence.isApproved)
        #expect(cell.outcome == report.outcome(of: manual).outcome)
    }

    @Test("A failing position records a failed cell rather than no cell")
    func aFailingPositionIsRecordedAsFailed() throws {
        let binding = try Sample.matrixBinding()
        let identifier = ApprovedConfigurationID("configuration-0001")!
        let subject = try #require(Sample.readableCells(of: binding).first)
        var store = FakeMatrixObservationStore.complete(for: binding)
        store.setCoverage(.layoutNotReadable, for: subject)
        let report = AccessibilityMatrixRunner(observations: store).run(binding)

        let recorded = try #require(try report.recordedCell(of: subject, as: identifier))
        #expect(recorded.outcome == .failed)
        #expect(recorded.outcome != .notExecuted)
        // The distinction matters: executed-and-failed is recorded, never-executed is absent, and a
        // release audit needs both because they are closed by different work.
        #expect(report.record(of: subject).outcome.wasExecuted)
    }

    // MARK: - The whole release

    @Test("One failing configuration blocks the application version")
    func oneFailingConfigurationBlocksTheBuild() throws {
        let seventeen = try Sample.matrixConfiguration(hardware: "iPhone17.1", osVersion: "17.4.1")
        let eighteen = try Sample.matrixConfiguration(hardware: "iPhone18.2", osVersion: "18.1.0")
        let plan = try Sample.matrixPlan(configurations: [seventeen, eighteen])
        let binding = try Sample.matrixCoverageBinding(plan: plan)
        let report = AccessibilityMatrixRunner(
            observations: FakeMatrixObservationStore.complete(for: binding)
        )
        .run(binding)

        #expect(report.configurationReports.count == 2)
        #expect(report.coveredMajorVersions == [17, 18])
        #expect(report.coveredConfigurations.count == 2)
        #expect(report.requiredCells.count == 112)
        // Requirements 12.14 and 12.18 block the affected application version, which is stricter
        // than Requirement 13.19's exclusion of one candidate.
        #expect(report.outcome == .failed)
        #expect(report.blocksDistribution)
        for gate in DeviceGate.matrixGates {
            #expect(report.outcome(of: gate) == .failed)
            #expect(report.perConfigurationGateResults(for: gate).count == 2)
        }
        // A gate this module does not record has no positions and fails rather than passing.
        #expect(report.outcome(of: .preprocessingParity) == .failed)
        #expect(report.outcome(of: .handoffLatency) == .failed)
        // And the run names the bound tuple among the inputs it owes.
        #expect(report.owedInputs.contains(.boundMatrixValidationVersionTuple))
        #expect(report.owedInputs.contains(.accessibilityGateMatrixArtifact))
        #expect(report.owedInputs.contains(.approvedAccessibilityLabelCopy))
        #expect(report.owedInputs.contains(.supportedMajorVersionDeclaration))
    }

    @Test("A position outside the required set is a failure, not a nil")
    func anUnrequestedPositionIsAlsoAFailure() throws {
        let binding = try Sample.matrixBinding()
        let report = AccessibilityMatrixRunner(
            observations: FakeMatrixObservationStore.complete(for: binding)
        )
        .run(binding)
        // A position on a configuration this report does not answer for.
        let foreign = AccessibilityMatrixCell(
            workflow: .ingest,
            exercise: .assistive(.reduceMotion),
            configuration: try Sample.matrixConfiguration(hardware: "iPhone98.1")
        )
        #expect(!binding.requiredCells.contains(foreign))
        let outcome = report.outcome(of: foreign)
        #expect(!outcome.isSatisfied)
        #expect(outcome.outcome == .failed)
        guard case let .resultMissing(gap) = outcome else {
            Issue.record("an unrequested position must report what it is owed")
            return
        }
        #expect(gap.owed == foreign.owedReleaseInput)
    }
}
