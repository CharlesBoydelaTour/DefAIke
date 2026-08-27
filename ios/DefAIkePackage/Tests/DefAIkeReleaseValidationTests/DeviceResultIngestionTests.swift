import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// Ingesting many device results at once: whole fixture families, whole version tuples, whole
// configurations, and both execution targets, arriving together.
//
// The four sibling tasks each test one runner in isolation. This suite tests the span between
// them — what a *release* is allowed to conclude when results arrive in bulk, from mixed
// sources, across configurations and version tuples. Design Property 1 is the statement being
// checked: a configuration is allowlisted only when every mandatory gate passes and the device,
// OS, build, Model Bundle, fixture suite, validation plan, capability set, and implementation
// versions are identical across every record; any missing, failing, Mac-only, or version-mixed
// evidence excludes it.
//
// **No number, identifier, tolerance, limit, sample count, agreement ratio, configuration, or
// version tuple anywhere in this file is an approved release value.** Every one is synthetic
// scaffolding built by `Sample`. There is no approved `DeviceValidationPlan`, no signed
// `ReleaseFixtureSuite`, none of the 96 model-parity fixtures, and no physical iPhone: only the
// iOS 26.5 simulator runtime exists. So every device gate in this repository is genuinely
// unsatisfiable, and this suite asserts that as the correct reported state rather than working
// around it. Nothing here manufactures an approved artifact, and no test here makes a device
// gate appear satisfiable.
//
// An observation or sample that *claims* `.physicalIPhone` is a claim its producer makes, not
// evidence. It lets the comparison arithmetic run on a host, which is why cells in these tests
// can pass. Gates cannot: they consult `ObservedParityEnvironment.current`, compiled from the
// platform, with no parameter.

// MARK: - Fixture families

/// Which families a catalogue owes, and what each one contributes to an ingestion.
@Suite("Device result ingestion: fixture families")
struct DeviceResultIngestionFixtureFamilyTests {

    // MARK: A complete catalogue

    @Test("A complete catalogue accounts for all 96 model-parity references and every family")
    func completeCatalogueAccountsForEveryFamily() throws {
        let binding = try Sample.parityBinding()
        let parity = binding.catalog.suite.fixtures(in: .modelParity)
        #expect(parity.count == ReleaseFixtureSuite.requiredModelParityFixtureCount)
        #expect(parity.count == 96)
        #expect(binding.catalog.suite.hasCompleteModelParityCoverage)

        let missing = binding.catalog.suite.missingFamilies
        #expect(missing.isEmpty)

        // Every unconditional family is populated, and none of the six provenance families is,
        // because this release's suite carries an approved decision that provenance does not
        // apply (Requirement 13.5).
        let populated = Set(binding.catalog.suite.fixtures.map(\.family))
        #expect(populated == FixtureFamily.unconditionalFamilies)
    }

    @Test("Each family contributes exactly the comparison cells its approved expectations declare")
    func eachFamilyContributesItsOwnCells() throws {
        let binding = try Sample.parityBinding()

        // Derived from the catalogue rather than restated, then checked against the absolute
        // numbers, so a change to either side is visible.
        let declaringLogit = binding.catalog.suite.fixtures.filter { fixture in
            fixture.expectations.contains { $0.kind == .rawLogit }
        }
        let declaringPixelLabel = binding.catalog.suite.fixtures.filter { fixture in
            fixture.expectations.contains { $0.kind == .pixelLabel }
        }
        let declaringPreprocessing = binding.catalog.suite.fixtures.filter { fixture in
            fixture.expectations.contains { $0.kind == .preprocessingOutputDigest }
        }

        let logitCells = binding.requiredCells(for: .rawLogit)
        #expect(logitCells.count == declaringLogit.count)
        #expect(logitCells.count == 97)

        let categoricalCells = binding.requiredCells(for: .categoricalOutcome)
        #expect(categoricalCells.count == declaringPixelLabel.count)
        #expect(categoricalCells.count == 96)

        let preprocessingCells = binding.requiredCells(for: .preprocessingOutput)
        #expect(preprocessingCells.count == declaringPreprocessing.count)
        #expect(preprocessingCells.count == 8)

        // The two route families are one gate over two comparisons (Requirement 13.10).
        let retainedCells = binding.requiredCells(for: .retainedBytes)
        let preservationCells = binding.requiredCells(for: .bytePreservationStatus)
        #expect(retainedCells.count == 2)
        #expect(preservationCells.count == 2)

        // Rank agreement has no per-fixture meaning, so it is one cell over the family.
        let rankCells = binding.requiredCells(for: .rankAgreement)
        #expect(rankCells.count == 1)
        let rankFamilies = rankCells.map(\.subject.family)
        #expect(rankFamilies == [FixtureFamily.modelParity])

        // Screenshot geometry exists per screenshot fixture even though no expectation kind can
        // carry its approved value (Requirement 13.9).
        let geometryCells = binding.requiredCells(for: .screenshotGeometry)
        #expect(geometryCells.count == binding.catalog.suite.fixtures(in: .physicalScreenshot).count)
        #expect(geometryCells.count == 1)
    }

    @Test("The malformed-input family is required, populated, and contributes no comparison")
    func malformedInputContributesNoComparison() throws {
        let binding = try Sample.parityBinding()
        let malformed = binding.catalog.suite.fixtures(in: .malformedInput)
        #expect(!malformed.isEmpty)

        // Its only approved expected result is a terminal Analysis Error, which is not a
        // comparison against a reference artifact, so Requirements 13.6 through 13.11 do not
        // cover it and it owes no cell.
        let record = try #require(malformed.first)
        let kinds = record.expectations.map(\.kind)
        #expect(kinds == [FixtureExpectationKind.analysisError])

        let cells = binding.requiredCells.filter { $0.subject.family == .malformedInput }
        #expect(cells.isEmpty)

        // And it is still a required family: a release that dropped it would be refused at
        // catalogue construction, not at the comparison.
        let required = binding.catalog.suite.requiredFamilies
        #expect(required.contains(.malformedInput))
    }

    // MARK: An incomplete catalogue

    @Test("A missing fixture family is refused at catalogue construction, so no run happens")
    func missingFamilyIsRefusedBeforeAnyRun() throws {
        let fixtures = try Sample.completeFixtures(excluding: [.physicalScreenshot])
        let suite = try Sample.suite(fixtures: fixtures)
        let inventory = try Sample.parityInventory(matching: fixtures)
        let coverage = ConditionalArtifactBinding<FusionFixtureCoverage>.notApplicable(
            decision: Sample.approval(identifier: "approval.no-fusion")
        )

        var thrown: FixtureCatalogError?
        do {
            _ = try FixtureCatalog(
                suite: suite,
                parityInventory: inventory,
                fusionCoverage: coverage
            )
        } catch {
            thrown = error
        }
        #expect(thrown == .requiredFamilyEmpty(.physicalScreenshot))

        // The consequence for an ingestion: there is no catalogue, so there is no binding, so
        // there is no partial parity result to read. A missing family removes the whole run
        // rather than shrinking it.
        #expect(suite.missingFamilies == [FixtureFamily.physicalScreenshot])
    }

    @Test("A model-parity family short of 96 cannot be catalogued at all")
    func shortParityFamilyCannotBeCatalogued() throws {
        var fixtures = try Sample.parityFixtures(count: 95)
        fixtures += try Sample.nonParityFamilyFixtures()
        let suite = try Sample.suite(fixtures: fixtures)
        #expect(!suite.hasCompleteModelParityCoverage)

        // The approved inventory carries all 96 references, and the catalogue reconciles against
        // it in both directions, so the shortfall is refused by identity rather than by count.
        let inventory = try Sample.parityInventory(matching: try Sample.parityFixtures())
        let coverage = ConditionalArtifactBinding<FusionFixtureCoverage>.notApplicable(
            decision: Sample.approval(identifier: "approval.no-fusion")
        )
        var thrown: FixtureCatalogError?
        do {
            _ = try FixtureCatalog(
                suite: suite,
                parityInventory: inventory,
                fusionCoverage: coverage
            )
        } catch {
            thrown = error
        }
        let error = try #require(thrown)
        guard case let .parityFixtureNotCatalogued(uncatalogued) = error else {
            Issue.record("a short model-parity family must be refused by fixture identity")
            return
        }
        #expect(uncatalogued == [Sample.fixture("fixture.parity.095")])

        // Finding, reported not fixed: because `ModelParityFixtureInventory` requires exactly 96
        // unique references and `ReleaseFixtureSuite` requires unique fixture identifiers, every
        // constructible `FixtureCatalog` already has exactly 96 catalogued model-parity
        // fixtures. `ParityBindingError.modelParityCoverageIncomplete` is therefore unreachable
        // through a constructible catalogue — a second, dead enforcement of the same rule.
        let complete = try Sample.catalog()
        #expect(complete.suite.hasCompleteModelParityCoverage)
        #expect(complete.suite.fixtures(in: .modelParity).count == 96)
    }

    // MARK: Families whose gate cannot be satisfied

    @Test("The physical-screenshot family fails closed even when every observation agrees")
    func screenshotGeometryFailsClosedOnACompleteRun() throws {
        let binding = try Sample.parityBinding()
        let report = ParityRunner(observations: FakeParityObservationStore.agreeing(with: binding))
            .run(binding)

        let geometry = binding.requiredCells(for: .screenshotGeometry)
        #expect(!geometry.isEmpty)
        for cell in geometry {
            guard case let .approvedExpectationUnrepresentable(limit) = report.outcome(of: cell)
            else {
                Issue.record("a screenshot-geometry cell must report an unrepresentable value")
                continue
            }
            #expect(limit == .screenshotGeometryHasNoExpectationKind)
        }
        // So `screenshot-fidelity` is unsatisfiable by construction, independently of the
        // missing physical device: `ComparisonMetric.screenshotGeometry` has no
        // `FixtureExpectationKind`.
        let fidelity = report.gateResult(for: .screenshotFidelity)
        #expect(fidelity.outcome == .failed)
        #expect(fidelity.applicability.isApplicable)
    }

    @Test("A pixel-only ingestion records the provenance family gate as not executed")
    func provenanceGateIsNotExecutedForAPixelOnlyRelease() throws {
        let binding = try Sample.parityBinding()
        let report = ParityRunner(observations: FakeParityObservationStore.agreeing(with: binding))
            .run(binding)

        let provenanceCells = binding.requiredCells(for: .provenanceState)
        #expect(provenanceCells.isEmpty)

        // The one legitimate `notExecuted` in the whole ingestion, and it needs an approved
        // decision behind it rather than an absence of results.
        let gate = report.gateResult(for: .provenanceFixtures)
        #expect(!gate.applicability.isApplicable)
        #expect(gate.outcome == .notExecuted)
        #expect(report.provenanceApplicability == binding.catalog.suite.provenanceApplicability)
    }

    @Test("A provenance-enabled ingestion adds every provenance family's cells")
    func provenanceEnabledAddsProvenanceCells() throws {
        let binding = try Sample.parityBinding(provenanceApplicable: true)
        let provenanceCells = binding.requiredCells(for: .provenanceState)
        #expect(provenanceCells.count == 16)

        let families = Set(provenanceCells.map(\.subject.family))
        #expect(families == FixtureFamily.provenanceFamilies)

        let report = ParityRunner(observations: FakeParityObservationStore.agreeing(with: binding))
            .run(binding)
        let gate = report.gateResult(for: .provenanceFixtures)
        #expect(gate.applicability.isApplicable)
        #expect(gate.cells.count == 16)
        // Applicable now, and failing, because this process is not a phone.
        #expect(gate.outcome == .failed)
    }
}

// MARK: - One version tuple, or none

/// Requirement 13.20: gate evidence for one configuration comes from one exact version tuple.
@Suite("Device result ingestion: one version tuple, or none")
struct DeviceResultIngestionVersionTupleTests {

    // MARK: The binding refuses a tuple that names something else

    @Test("A tuple naming another fixture suite cannot bind")
    func otherFixtureSuiteCannotBind() throws {
        let thrown = try Self.parityBindingError(
            versionTuple: try Sample.parityVersionTuple(fixtureSuite: "suite.other")
        )
        #expect(
            thrown
                == .versionTupleFixtureSuiteMismatch(
                    expected: Sample.artifact("suite.fixtures"),
                    found: Sample.artifact("suite.other")
                )
        )
    }

    @Test("A tuple naming another validation plan cannot bind")
    func otherValidationPlanCannotBind() throws {
        let thrown = try Self.parityBindingError(
            versionTuple: try Sample.parityVersionTuple(validationPlan: "plan.other")
        )
        #expect(
            thrown
                == .versionTuplePlanMismatch(
                    expected: Sample.artifact("plan.device-validation"),
                    found: Sample.artifact("plan.other")
                )
        )
    }

    @Test("A tuple naming another Model Bundle cannot bind")
    func otherModelBundleCannotBind() throws {
        let other = ModelBundleID("bundle.other")!
        let thrown = try Self.parityBindingError(
            versionTuple: try Sample.parityVersionTuple(modelBundle: other)
        )
        #expect(
            thrown == .versionTupleModelBundleMismatch(expected: Sample.bundle(), found: other)
        )
    }

    @Test("A tuple naming another capability manifest cannot bind")
    func otherCapabilityManifestCannotBind() throws {
        let thrown = try Self.parityBindingError(
            versionTuple: try Sample.parityVersionTuple(capabilityManifest: "manifest.other")
        )
        #expect(
            thrown
                == .versionTupleCapabilityManifestMismatch(
                    expected: Sample.artifact("manifest.capability"),
                    found: Sample.artifact("manifest.other")
                )
        )
    }

    @Test("A tuple naming another application build cannot bind")
    func otherApplicationBuildCannotBind() throws {
        let other = AppBuildID("build.other")!
        let thrown = try Self.parityBindingError(
            versionTuple: try Sample.parityVersionTuple(appBuild: other)
        )
        #expect(
            thrown == .versionTupleAppBuildMismatch(expected: other, found: Sample.appBuild())
        )
    }

    @Test("A tuple enabling another capability set cannot bind")
    func otherCapabilitySetCannotBind() throws {
        // The suite carries an approved decision that provenance does not apply, so a
        // provenance-enabled tuple would run six families of fixtures the catalogue does not
        // hold — and the reverse would carry fixtures for a lane the release never produces.
        let thrown = try Self.parityBindingError(
            versionTuple: try Sample.parityVersionTuple(provenanceEnabled: true)
        )
        #expect(
            thrown
                == .catalogNotReconcilable(
                    .provenanceApplicabilityMismatch(suiteApplicable: false, capabilityEnabled: true)
                )
        )
    }

    // MARK: Implementation versions are reconciled at the evidence, not at the binding

    @Test("Mixed capability implementation versions bind and are then refused per observation")
    func implementationVersionMixingIsCaughtAtTheEvidence() throws {
        let binding = try Sample.parityBinding()
        let drifted = try ValidationVersionTuple(
            appBuild: Sample.appBuild(),
            modelBundle: Sample.bundle(),
            fixtureSuite: Sample.artifact("suite.fixtures"),
            validationPlan: Sample.artifact("plan.device-validation"),
            capabilityManifest: Sample.artifact("manifest.capability"),
            capabilities: [.pixelAnalysis],
            capabilityImplementationVersions: [
                CapabilityImplementationEntry(
                    capability: .pixelAnalysis,
                    version: Sample.version("2.0.0")
                )
            ]
        )
        // It differs from the bound tuple in exactly one field, and that field is one
        // Requirement 13.20 names.
        #expect(drifted != binding.versionTuple)
        #expect(drifted.appBuild == binding.versionTuple.appBuild)
        #expect(drifted.modelBundle == binding.versionTuple.modelBundle)
        #expect(drifted.capabilities == binding.versionTuple.capabilities)

        // Finding, reported not fixed: `ParityRunBinding` reconciles the plan, suite, bundle,
        // manifest, and build, and does not compare capability implementation versions against
        // anything. So the drifted tuple binds.
        let second = try Sample.parityBinding(versionTuple: drifted)
        #expect(second.versionTuple == drifted)

        // The clause is enforced one observation at a time instead, because
        // `QualifyingParityEvidence` compares whole tuples.
        var store = FakeParityObservationStore.agreeing(with: binding)
        let subject = try #require(binding.requiredCells(for: .categoricalOutcome).first)
        store.setVersionTuple(drifted, for: subject)
        let outcome = ParityRunner(observations: store).run(binding).outcome(of: subject)
        guard case let .nonQualifyingEvidence(reason) = outcome else {
            Issue.record("a drifted implementation version must not satisfy a cell")
            return
        }
        #expect(reason == .versionTupleMismatch)
    }

    // MARK: Mixing two tuples inside one ingestion

    @Test("Evidence that mixes two builds in one ingestion satisfies nothing it touches")
    func mixedBuildsExcludeTheCellsTheyTouch() throws {
        let binding = try Sample.parityBinding(catalog: try Sample.distinctLogitCatalog())
        var store = FakeParityObservationStore.agreeing(with: binding)
        let otherBuild = AppBuildID("build.other")!
        let otherTuple = try Sample.parityVersionTuple(appBuild: otherBuild)

        let logits = binding.requiredCells(for: .rawLogit)
        let mixed = Array(logits.prefix(6))
        #expect(mixed.count == 6)
        for cell in mixed { store.setVersionTuple(otherTuple, for: cell) }

        let report = ParityRunner(observations: store).run(binding)
        for cell in mixed {
            guard case let .nonQualifyingEvidence(reason) = report.outcome(of: cell) else {
                Issue.record("a cell measured under another build must not be satisfied")
                continue
            }
            #expect(reason == .versionTupleMismatch)
        }
        // The refusal is per observation, not per run: the cells it did not touch still agree.
        let untouched = logits.filter { !mixed.contains($0) }
        let untouchedSatisfied = untouched.allSatisfy { report.outcome(of: $0).isSatisfied }
        #expect(untouchedSatisfied)

        // And the derived rank agreement, which reads every model-parity logit of this same run,
        // is refused because one of its contributors ran under another build.
        let rank = try #require(binding.requiredCells(for: .rankAgreement).first)
        guard case let .nonQualifyingEvidence(rankReason) = report.outcome(of: rank) else {
            Issue.record("a mixed contributor must refuse the derived ordering")
            return
        }
        #expect(rankReason == .versionTupleMismatch)

        // The gate the mixed cells belong to fails, and so does the run.
        #expect(report.gateResult(for: .rawLogitParity).outcome == .failed)
        #expect(report.outcome == .failed)
        let owed = report.owedInputs
        #expect(owed.contains(.physicalIPhoneRunEnvironment))
    }

    @Test("A resource ingestion cannot pair two targets from two tuples")
    func resourceRunBindingSharesOneTupleAcrossBothTargets() throws {
        let binding = try Sample.resourceRunBinding()
        // There is no initialiser taking two independently constructed target bindings, so both
        // sides necessarily share the configuration, the tuple, and the plan.
        #expect(binding.mainApplication.versionTuple == binding.shareExtension.versionTuple)
        #expect(binding.mainApplication.configuration == binding.shareExtension.configuration)
        #expect(binding.mainApplication.plan.id == binding.shareExtension.plan.id)
        // The budget is the one thing that is meant to differ, and each side selects its own.
        #expect(binding.mainApplication.budget.id != binding.shareExtension.budget.id)
        #expect(binding.mainApplication.budget.target == .mainApplication)
        #expect(binding.shareExtension.budget.target == .shareExtension)
    }

    @Test("Share Extension samples under another tuple are refused, main-application untouched")
    func mixedTupleAcrossTargetsRefusesOnlyTheMixedTarget() throws {
        let binding = try Sample.resourceRunBinding()
        var store = FakeResourceSampleStore.complete(for: binding)
        let otherBuild = AppBuildID("build.other")!
        let otherTuple = try Sample.resourceVersionTuple(appBuild: otherBuild)

        let extensionCells = Sample.readableCells(of: binding.shareExtension)
        #expect(!extensionCells.isEmpty)
        for cell in extensionCells { store.setVersionTuple(otherTuple, for: cell) }

        let report = ResourceMeasurementRunner(samples: store).run(binding)
        for cell in extensionCells {
            guard case let .nonQualifyingEvidence(reason) = report.shareExtension.outcome(of: cell)
            else {
                Issue.record("an extension measurement under another build must be refused")
                continue
            }
            #expect(reason == .versionTupleMismatch)
        }
        let mainSatisfied = Sample.readableCells(of: binding.mainApplication).allSatisfy {
            report.mainApplication.outcome(of: $0).isSatisfied
        }
        #expect(mainSatisfied)
        #expect(report.outcome == .failed)
    }

    @Test("Matrix positions under another tuple are refused inside one coverage run")
    func mixedTupleInsideOneMatrixRun() throws {
        let binding = try Sample.matrixBinding()
        var store = FakeMatrixObservationStore.complete(for: binding)
        let otherBuild = AppBuildID("build.other")!
        let otherTuple = try Sample.matrixVersionTuple(appBuild: otherBuild)

        let readable = Sample.readableCells(of: binding)
        let mixed = Array(readable.prefix(4))
        for cell in mixed { store.setVersionTuple(otherTuple, for: cell) }

        let report = AccessibilityMatrixRunner(observations: store).run(binding)
        for cell in mixed {
            guard case let .nonQualifyingEvidence(reason) = report.outcome(of: cell) else {
                Issue.record("a position executed under another build must be refused")
                continue
            }
            #expect(reason == .versionTupleMismatch)
        }
        let untouched = readable.filter { !mixed.contains($0) }
        let untouchedSatisfied = untouched.allSatisfy { report.outcome(of: $0).isSatisfied }
        #expect(untouchedSatisfied)
        #expect(report.nonQualifyingCells.count == mixed.count)
    }

    // MARK: Helper

    /// The binding error one parity tuple produces, or `nil` when the binding succeeds.
    ///
    /// The sample builders are resolved before the `do` block: they throw untyped errors, and a
    /// `do` block mixing those with `ParityRunBinding`'s typed throws loses the typed `catch`.
    static func parityBindingError(
        versionTuple: ValidationVersionTuple
    ) throws -> ParityBindingError? {
        let plan = try Sample.parityPlan()
        let catalog = try Sample.catalog()
        let configuration = try Sample.candidateConfiguration()
        var thrown: ParityBindingError?
        do {
            _ = try ParityRunBinding(
                plan: plan,
                catalog: catalog,
                configuration: configuration,
                versionTuple: versionTuple
            )
        } catch {
            thrown = error
        }
        return thrown
    }
}

// MARK: - Results from more than one device

/// What happens when one ingestion carries results from two configurations.
@Suite("Device result ingestion: results from more than one device")
struct DeviceResultIngestionMixedDeviceTests {

    @Test("A parity cell refuses evidence from another approved candidate")
    func anotherApprovedCandidateCannotAnswerThisCandidatesCell() throws {
        let otherHardware = DeviceHardwareID("iPhone16.2")!
        let other = try Sample.candidateConfiguration(hardware: otherHardware)
        let plan = try Sample.resourcePlan(extraConfigurations: [other])
        let binding = try Sample.parityBinding(plan: plan)

        // Both are candidates the approved plan enumerates, so this is not a question about an
        // unapproved device: it is that one candidate's result does not answer another's cell.
        #expect(plan.candidateConfigurations.contains(other))
        #expect(plan.candidateConfigurations.contains(binding.configuration))

        var store = FakeParityObservationStore.agreeing(with: binding)
        let subject = try #require(binding.requiredCells(for: .categoricalOutcome).first)
        store.setConfiguration(other, for: subject)

        let outcome = ParityRunner(observations: store).run(binding).outcome(of: subject)
        guard case let .nonQualifyingEvidence(reason) = outcome else {
            Issue.record("another candidate's result must not satisfy this candidate's cell")
            return
        }
        #expect(
            reason
                == .configurationMismatch(
                    expected: binding.configuration.hardwareIdentifier,
                    observed: other.hardwareIdentifier
                )
        )
    }

    @Test("A configuration the plan never enumerated is refused as a mismatch")
    func unenumeratedConfigurationIsRefused() throws {
        let binding = try Sample.parityBinding()
        let stranger = try Sample.candidateConfiguration(
            hardware: DeviceHardwareID("iPhone99.9")!
        )
        #expect(!binding.plan.candidateConfigurations.contains(stranger))

        var store = FakeParityObservationStore.agreeing(with: binding)
        let subject = try #require(binding.requiredCells(for: .categoricalOutcome).first)
        store.setConfiguration(stranger, for: subject)

        let outcome = ParityRunner(observations: store).run(binding).outcome(of: subject)
        guard case let .nonQualifyingEvidence(reason) = outcome else {
            Issue.record("an unenumerated configuration must not satisfy a cell")
            return
        }
        // Finding, reported not fixed: the refusal is reported as a configuration *mismatch*
        // rather than as `configurationNotInPlan`, because the bound configuration is always a
        // plan candidate and the mismatch check runs first. `NonQualifyingParityEvidence
        // .configurationNotInPlan` is therefore unreachable from `ParityRunner`'s refusal path.
        // Either way it is not a pass.
        #expect(
            reason
                == .configurationMismatch(
                    expected: binding.configuration.hardwareIdentifier,
                    observed: stranger.hardwareIdentifier
                )
        )
    }

    @Test("A matrix ingestion keeps two candidates' results separate")
    func matrixIngestionKeepsCandidatesSeparate() throws {
        let first = try Sample.matrixConfiguration(hardware: "iPhone17.1", osVersion: "17.0.0")
        let second = try Sample.matrixConfiguration(hardware: "iPhone16.2", osVersion: "18.1.0")
        let plan = try Sample.matrixPlan(configurations: [first, second])
        let coverage = try Sample.matrixCoverageBinding(plan: plan)

        #expect(coverage.bindings.count == 2)
        let majors = coverage.supportedMajorVersions
        #expect(majors == [17, 18])

        let report = AccessibilityMatrixRunner(
            observations: FakeMatrixObservationStore.complete(for: coverage)
        ).run(coverage)

        #expect(report.configurationReports.count == 2)
        let covered = report.coveredConfigurations
        #expect(covered.count == 2)
        let coveredMajors = report.coveredMajorVersions
        #expect(coveredMajors == [17, 18])

        // Nothing merges them. One gate produces one result per configuration, and each result
        // names the configuration it was computed from.
        let gateResults = report.perConfigurationGateResults(for: .accessibilityMatrix)
        #expect(gateResults.count == 2)
        let gateConfigurations = gateResults.map(\.configuration)
        #expect(gateConfigurations == covered)
        for result in gateResults {
            #expect(result.cells.count == 28)
            let sameConfiguration = result.cells.allSatisfy {
                $0.configuration == result.configuration
            }
            #expect(sameConfiguration)
        }
        #expect(report.requiredCells.count == 112)
        #expect(report.blocksDistribution)
    }

    @Test("One candidate's observation cannot answer another candidate's position")
    func crossCandidateObservationIsRefused() throws {
        let first = try Sample.matrixConfiguration(hardware: "iPhone17.1", osVersion: "17.0.0")
        let second = try Sample.matrixConfiguration(hardware: "iPhone16.2", osVersion: "18.1.0")
        let plan = try Sample.matrixPlan(configurations: [first, second])
        let coverage = try Sample.matrixCoverageBinding(plan: plan)
        var store = FakeMatrixObservationStore.complete(for: coverage)

        let secondBinding = try #require(
            coverage.bindings.first { $0.configuration == second }
        )
        let subject = try #require(Sample.readableCells(of: secondBinding).first)
        store.setConfiguration(first, for: subject)

        let report = AccessibilityMatrixRunner(observations: store).run(coverage)
        let secondReport = try #require(report.report(for: second))
        guard case let .nonQualifyingEvidence(reason) = secondReport.outcome(of: subject) else {
            Issue.record("one candidate's run must not answer another candidate's position")
            return
        }
        #expect(
            reason
                == .configurationMismatch(
                    expected: second.hardwareIdentifier,
                    observed: first.hardwareIdentifier
                )
        )

        // The other candidate's report is untouched, so the refusal is per observation rather
        // than per ingestion.
        let firstBinding = try #require(coverage.bindings.first { $0.configuration == first })
        let firstReport = try #require(report.report(for: first))
        let firstSatisfied = Sample.readableCells(of: firstBinding).allSatisfy {
            firstReport.outcome(of: $0).isSatisfied
        }
        #expect(firstSatisfied)
        #expect(secondReport.nonQualifyingCells.count == 1)
    }

    @Test("A resource sample from another candidate is refused")
    func resourceSampleFromAnotherCandidateIsRefused() throws {
        let otherHardware = DeviceHardwareID("iPhone16.2")!
        let other = try Sample.candidateConfiguration(hardware: otherHardware)
        let plan = try Sample.resourcePlan(extraConfigurations: [other])
        let budgets = try Sample.resourceBudgets()
        let binding = try Sample.resourceRunBinding(plan: plan, budgets: budgets)

        var store = FakeResourceSampleStore.complete(for: binding)
        let subject = try #require(
            binding.mainApplication.requiredCells.first { $0.metric == .peakResidentMemory }
        )
        store.setConfiguration(other, for: subject)

        let report = ResourceMeasurementRunner(samples: store).run(binding)
        guard case let .nonQualifyingEvidence(reason) = report.mainApplication.outcome(of: subject)
        else {
            Issue.record("a sample from another candidate must not satisfy a measurement")
            return
        }
        #expect(
            reason
                == .configurationMismatch(
                    expected: binding.configuration.hardwareIdentifier,
                    observed: other.hardwareIdentifier
                )
        )
    }
}

// MARK: - Separate main-application and Share Extension measurement sets

/// Requirements 11.19 and 11.20, across a whole two-target ingestion.
@Suite("Device result ingestion: separate app and extension measurement sets")
struct DeviceResultIngestionTargetSeparationTests {

    @Test("The two targets' required cell sets are disjoint and each carries its own target")
    func requiredCellSetsAreDisjoint() throws {
        let binding = try Sample.resourceRunBinding()
        let main = Set(binding.mainApplication.requiredCells)
        let extensionCells = Set(binding.shareExtension.requiredCells)
        #expect(main.isDisjoint(with: extensionCells))

        let mainTargets = Set(binding.mainApplication.requiredCells.map(\.target))
        let extensionTargets = Set(binding.shareExtension.requiredCells.map(\.target))
        #expect(mainTargets == [ExecutionTarget.mainApplication])
        #expect(extensionTargets == [ExecutionTarget.shareExtension])

        // Peak resident memory is owed by both, and the two cells are different cells, which is
        // what stops one reading from answering both.
        let mainMemory = try #require(
            binding.mainApplication.requiredCells.first { $0.metric == .peakResidentMemory }
        )
        let extensionMemory = try #require(
            binding.shareExtension.requiredCells.first { $0.metric == .peakResidentMemory }
        )
        #expect(mainMemory != extensionMemory)
    }

    @Test("Each target's limit is selected from its own budget, never passed in")
    func eachTargetSelectsItsOwnBudget() throws {
        let binding = try Sample.resourceRunBinding()
        let budgets = try Sample.resourceBudgets()

        // The caller never chooses: `ResourceBudgetSet.budget(for:)` decides, and the set
        // already guarantees each side carries its own target.
        #expect(budgets.budget(for: .mainApplication).target == .mainApplication)
        #expect(budgets.budget(for: .shareExtension).target == .shareExtension)
        #expect(binding.mainApplication.budget.id == budgets.budget(for: .mainApplication).id)
        #expect(binding.shareExtension.budget.id == budgets.budget(for: .shareExtension).id)

        // And a budget pair with swapped targets cannot exist to be handed in.
        let swapped = try Sample.resourceBudget(
            target: .shareExtension,
            identifier: "budget.swapped"
        )
        #expect(throws: ArtifactSchemaError.self) {
            _ = try ResourceBudgetSet(
                mainApplication: swapped,
                shareExtension: try Sample.resourceBudget(
                    target: .shareExtension,
                    identifier: "budget.share-extension"
                )
            )
        }
    }

    @Test("A main-application report records the handoff-latency gate as failed with no coverage")
    func mainApplicationReportSaysNothingAboutHandoffLatency() throws {
        let binding = try Sample.resourceRunBinding()
        let report = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.complete(for: binding)
        ).run(binding)

        // Every measurement the main application can take was taken and read inside its limit.
        let mainSatisfied = Sample.readableCells(of: binding.mainApplication).allSatisfy {
            report.mainApplication.outcome(of: $0).isSatisfied
        }
        #expect(mainSatisfied)

        // And the main application still records `handoff-latency` as failed, with zero
        // completeness, because it has no cells for it — saying nothing is not saying it passed.
        let handoff = report.mainApplication.gateResult(for: .handoffLatency)
        #expect(handoff.cells.isEmpty)
        #expect(handoff.outcome == .failed)
        #expect(handoff.measuredCompleteness == .zero)
        #expect(handoff.target == .mainApplication)

        // Symmetrically, the extension has nothing to say about cold model load.
        let coldLoad = report.shareExtension.gateResult(for: .coldModelLoad)
        #expect(coldLoad.cells.isEmpty)
        #expect(coldLoad.outcome == .failed)
        #expect(coldLoad.measuredCompleteness == .zero)
        #expect(coldLoad.target == .shareExtension)
    }

    @Test("A main-application measurement cannot satisfy an extension limit, or the reverse")
    func neitherTargetsMeasurementSatisfiesTheOthersLimit() throws {
        let binding = try Sample.resourceRunBinding()
        var store = FakeResourceSampleStore.complete(for: binding)

        let mainMemory = try #require(
            binding.mainApplication.requiredCells.first { $0.metric == .peakResidentMemory }
        )
        let extensionMemory = try #require(
            binding.shareExtension.requiredCells.first { $0.metric == .peakResidentMemory }
        )
        // One ingestion in which each target's harness filed its samples in the other's process.
        store.setTarget(.shareExtension, for: mainMemory)
        store.setTarget(.mainApplication, for: extensionMemory)

        let report = ResourceMeasurementRunner(samples: store).run(binding)

        guard case let .crossTargetSample(mainObserved, mainRequired) = report.mainApplication
            .outcome(of: mainMemory)
        else {
            Issue.record("an extension-process sample must not answer a main-application cell")
            return
        }
        #expect(mainObserved == .shareExtension)
        #expect(mainRequired == .mainApplication)

        guard case let .crossTargetSample(extensionObserved, extensionRequired) = report
            .shareExtension.outcome(of: extensionMemory)
        else {
            Issue.record("a main-application sample must not answer an extension cell")
            return
        }
        #expect(extensionObserved == .mainApplication)
        #expect(extensionRequired == .shareExtension)

        // The refusal names target separation rather than the environment, so a release audit
        // reads the reason that actually applies.
        #expect(report.mainApplication.crossTargetCells == [mainMemory])
        #expect(report.shareExtension.crossTargetCells == [extensionMemory])
        #expect(report.outcome(of: .mainApplicationPeakMemory) == .failed)
        #expect(report.outcome(of: .shareExtensionPeakMemory) == .failed)
    }

    @Test("One target's cell read through the other's report is a cross-target failure")
    func aForeignCellReadThroughAReportIsAFailure() throws {
        let binding = try Sample.resourceRunBinding()
        let report = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.complete(for: binding)
        ).run(binding)

        // The mapping is total, including over cells that belong to the other target. "Never
        // required of this target" is not a reason to treat a measurement as done.
        let foreign = ResourceCell(target: .shareExtension, subject: .budgetMetric(.handoffLatency))
        let outcome = report.mainApplication.outcome(of: foreign)
        #expect(!outcome.isSatisfied)
        #expect(outcome.outcome == .failed)
        guard case let .crossTargetSample(observed, required) = outcome else {
            Issue.record("a foreign cell must be reported as a cross-target failure")
            return
        }
        #expect(observed == .shareExtension)
        #expect(required == .mainApplication)
    }

    @Test("An extension failure does not carry the main application, and neither carries the other")
    func targetOutcomesAreIndependent() throws {
        let binding = try Sample.resourceRunBinding()
        var store = FakeResourceSampleStore.complete(for: binding)

        // Push every extension measurement over its limit, leaving the main application whole.
        for cell in Sample.readableCells(of: binding.shareExtension) {
            guard let metric = cell.metric, !metric.isCategorical else { continue }
            store.setValueEverywhere(
                .quantity(1_000, unit: Sample.unit(for: metric)),
                for: cell
            )
        }

        let report = ResourceMeasurementRunner(samples: store).run(binding)
        let mainSatisfied = Sample.readableCells(of: binding.mainApplication).allSatisfy {
            report.mainApplication.outcome(of: $0).isSatisfied
        }
        #expect(mainSatisfied)

        let extensionNumeric = Sample.readableCells(of: binding.shareExtension).filter { cell in
            guard let metric = cell.metric else { return false }
            return !metric.isCategorical
        }
        #expect(!extensionNumeric.isEmpty)
        let extensionExceeded = extensionNumeric.allSatisfy { cell in
            if case .exceededLimit = report.shareExtension.outcome(of: cell) { true } else { false }
        }
        #expect(extensionExceeded)

        // Requirement 11.20 runs both ways: neither target's result approves the other, and the
        // only member that looks at both requires both.
        #expect(report.shareExtension.outcome == .failed)
        #expect(report.mainApplication.outcome == .failed)
        #expect(report.outcome == .failed)
    }

    @Test("Cancellation and interruption are reported per target under one shared gate")
    func conditionGatesAreStillReportedPerTarget() throws {
        let binding = try Sample.resourceRunBinding()
        let report = ResourceMeasurementRunner(
            samples: FakeResourceSampleStore.complete(for: binding)
        ).run(binding)

        for gate in [DeviceGate.cancellationResidualWork, .interruptionCleanup] {
            // No target owns the gate, so both are reported, separately, and neither is merged
            // away (Requirement 11.19).
            #expect(gate.measurementTarget == nil)
            let results = report.perTargetGateResults(for: gate)
            #expect(results.count == 2)
            let targets = results.map(\.target)
            #expect(targets == [ExecutionTarget.mainApplication, .shareExtension])
            for result in results {
                #expect(result.cells.count == 1)
                #expect(result.outcome == .failed)
            }
            #expect(report.outcome(of: gate) == .failed)
        }

        // Finding, reported not fixed: `DeviceValidationPlan.measurements` is keyed by
        // target/metric/hardware@os with no condition or phase dimension, so neither
        // measurement can be predeclared at all while Requirement 13.17 makes both gates
        // mandatory. Each cell says so by name instead of failing anonymously.
        let cancellation = ResourceCell(
            target: .mainApplication,
            subject: .cancellationResidualWork
        )
        guard case let .measurementUnavailable(limit) = report.mainApplication
            .outcome(of: cancellation)
        else {
            Issue.record("a cancellation-condition cell must name why it cannot be measured")
            return
        }
        #expect(limit == .cancellationResidualWorkHasNoPlanSpecification)
        #expect(binding.mainApplication.specification(for: cancellation) == nil)
    }
}
