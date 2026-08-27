import Foundation
import Testing

@testable import DefAIkeDomain
@testable import DefAIkeModelBundle

/// Step 6 of the verification order: load the candidate and run its release self-tests
/// offline under the active approved budget (Requirements 10.11 and 10.20).
///
/// The runner's job is narrow and worth stating: it reads each fixture from the candidate's
/// own verified tree, hands it to an executor, and compares what came back to what the
/// bundle declared. So these tests seed observations and assert which finding each
/// disagreement produces, plus that the run reserves and samples the approved budget and
/// never leaves a rejected candidate loaded.
@Suite("Release self-test execution")
struct ReleaseSelfTestExecutionTests {
    // MARK: Helpers

    private static let label = PixelLabelKey.noStrongSignalDetected

    private static func runner(
        executor: FakeSelfTestExecutor,
        governor: StubResourceGovernor = StubResourceGovernor(),
        candidate: CompatibleCandidate,
        budget: ResourceBudget? = nil
    ) -> ReleaseSelfTestRunner {
        ReleaseSelfTestRunner(
            execution: executor,
            content: candidate.integrity.tree,
            resources: governor,
            budget: budget ?? candidate.configuration.resourceBudgets.mainApplication
        )
    }

    /// The finding one run produced, or `nil` when every expectation agreed.
    private static func finding(
        _ runner: ReleaseSelfTestRunner,
        _ bindable: CompatibleBundleCandidate
    ) async -> ModelBundleVerificationError? {
        do {
            _ = try await runner.run(bindable)
            return nil
        } catch {
            return error
        }
    }

    private static func finding(
        _ runner: ReleaseSelfTestRunner,
        _ candidate: CompatibleCandidate
    ) async throws -> ModelBundleVerificationError? {
        await finding(runner, try candidate.bindable())
    }

    // MARK: A passing run

    @Test("A run in which every declared expectation agrees produces a passing report")
    func agreeingRunPasses() async throws {
        let candidate = try CompatibleBundleAssembler.standard(
            selfTests: [
                SampleSelfTest(
                    caseID: "self-test.one",
                    fixtureID: "fixture.one",
                    suiteRelativePath: "one.jpg",
                    bytes: Array("one".utf8),
                    expectations: [
                        .pixelLabel(Self.label),
                        .rawLogit(value: 1.5, tolerance: Sample.nonNegativeDecimal(0)),
                    ]
                ),
                SampleSelfTest(
                    caseID: "self-test.two",
                    fixtureID: "fixture.two",
                    suiteRelativePath: "two.jpg",
                    bytes: Array("two".utf8),
                    expectations: [.analysisError(.decodingError)]
                ),
            ]
        )
        let executor = FakeSelfTestExecutor(observations: [
            "fixture.one": SelfTestObservation(rawLogit: RawLogit(1.5), pixelLabel: Self.label),
            "fixture.two": SelfTestObservation(analysisError: .decodingError),
        ])
        let runner = Self.runner(executor: executor, candidate: candidate)

        let tested = try await runner.run(try candidate.bindable())
        #expect(tested.selfTestOutcome == .passed)
        #expect(tested.report.executedCases.map(\.rawValue) == ["self-test.one", "self-test.two"])
        #expect(tested.report.comparedExpectationCount == 3)
        #expect(tested.report.specificationID == Sample.artifact("spec.self-tests"))
        #expect(
            tested.report.resourceBudgetID
                == candidate.configuration.resourceBudgets.mainApplication.id
        )
        #expect(tested.report.unmeasurableMetrics.isEmpty)
        #expect(executor.unloadCount == 1)
        #expect(executor.outstandingLoads == 0)
    }

    @Test("The candidate's own contracts and component versions are what the executor is told")
    func executorReceivesTheCandidateNotTheActiveBundle() async throws {
        let candidate = try CompatibleBundleAssembler.standard()
        let executor = FakeSelfTestExecutor(observations: [
            "fixture.sample": SelfTestObservation(pixelLabel: Self.label)
        ])
        _ = try await Self.runner(executor: executor, candidate: candidate)
            .run(try candidate.bindable())

        let context = try #require(executor.loadedContexts.first)
        #expect(context.bundleID == Sample.bundle())
        #expect(context.compiledModelPath == candidate.layout.compiledModel)
        #expect(context.modelIdentity == RequiredPixelModel.identity)
        #expect(context.outputContract.featureName.value == ModelOutputContract.requiredFeatureName)
        #expect(context.preprocessingContractVersion == Sample.artifact("contract.preprocessing"))
        #expect(context.calibrationPolicyVersion == Sample.artifact("policy.calibration"))
        #expect(context.coreMLModelVersion == Sample.artifact("component.core-ml-model"))
    }

    @Test("Fixture bytes come from the candidate's verified tree, with their verified digest")
    func fixtureBytesComeFromTheVerifiedTree() async throws {
        let bytes = Array("one".utf8)
        let candidate = try CompatibleBundleAssembler.standard(
            selfTests: [SampleSelfTest(bytes: bytes)]
        )
        let executor = FakeSelfTestExecutor(observations: [
            "fixture.sample": SelfTestObservation(pixelLabel: Self.label)
        ])
        _ = try await Self.runner(executor: executor, candidate: candidate)
            .run(try candidate.bindable())

        #expect(executor.runFixtures == [Sample.fixtureID()])
        #expect(executor.suppliedDigests == [StreamingSHA256.digest(of: bytes)])
    }

    // MARK: Missing and disagreeing results

    @Test("A declared expectation the run produced no value for is refused")
    func missingObservationRefused() async throws {
        let candidate = try CompatibleBundleAssembler.standard(
            selfTests: [SampleSelfTest(expectations: [.pixelLabel(Self.label)])]
        )
        // The executor reports nothing at all, which is what a silent run looks like.
        let runner = Self.runner(executor: FakeSelfTestExecutor(), candidate: candidate)
        #expect(
            try await Self.finding(runner, candidate)
                == .selfTestExpectationNotProduced(
                    case: Sample.selfTestCaseID(),
                    kind: .pixelLabel
                ),
            "a missing result is never a pass"
        )
    }

    @Test("A disagreeing label is refused")
    func disagreeingLabelRefused() async throws {
        let candidate = try CompatibleBundleAssembler.standard(
            selfTests: [SampleSelfTest(expectations: [.pixelLabel(.notEnoughSignal)])]
        )
        let executor = FakeSelfTestExecutor(observations: [
            "fixture.sample": SelfTestObservation(pixelLabel: .signalsConsistentWithAIGeneration)
        ])
        let runner = Self.runner(executor: executor, candidate: candidate)
        #expect(
            try await Self.finding(runner, candidate)
                == .selfTestExpectationMismatch(case: Sample.selfTestCaseID(), kind: .pixelLabel)
        )
    }

    @Test("A logit is compared against the tolerance the bundle itself declares")
    func logitToleranceComesFromTheBundle() async throws {
        // Tolerance 0.5 around 2.0: inside, on the boundary, and outside.
        let outcomes: [(Double, Bool)] = [(2.4, true), (2.5, true), (1.5, true), (2.6, false), (1.4, false)]
        for (observed, agrees) in outcomes {
            let candidate = try CompatibleBundleAssembler.standard(
                selfTests: [
                    SampleSelfTest(
                        expectations: [
                            .rawLogit(
                                value: 2.0,
                                tolerance: Sample.nonNegativeDecimal(
                                    Decimal(sign: .plus, exponent: -1, significand: 5)
                                )
                            )
                        ]
                    )
                ]
            )
            let executor = FakeSelfTestExecutor(observations: [
                "fixture.sample": SelfTestObservation(rawLogit: RawLogit(observed))
            ])
            let runner = Self.runner(executor: executor, candidate: candidate)
            let finding = try await Self.finding(runner, candidate)
            #expect(
                (finding == nil) == agrees,
                "\(observed) against 2.0 ± 0.5 should \(agrees ? "agree" : "disagree")"
            )
        }
    }

    @Test("A zero tolerance means exact equality")
    func zeroToleranceIsExact() async throws {
        for (observed, agrees) in [(2.0, true), (2.000000001, false)] {
            let candidate = try CompatibleBundleAssembler.standard(
                selfTests: [
                    SampleSelfTest(
                        expectations: [
                            .rawLogit(value: 2.0, tolerance: Sample.nonNegativeDecimal(0))
                        ]
                    )
                ]
            )
            let executor = FakeSelfTestExecutor(observations: [
                "fixture.sample": SelfTestObservation(rawLogit: RawLogit(observed))
            ])
            let runner = Self.runner(executor: executor, candidate: candidate)
            #expect((try await Self.finding(runner, candidate) == nil) == agrees)
        }
    }

    @Test("A nonfinite logit is not a value an observation can carry")
    func nonFiniteLogitIsNotRepresentable() {
        // Requirement 4.16 keeps a nonfinite output away from any label mapping. The domain
        // makes that unconstructible rather than checked, so a self-test observation cannot
        // smuggle one into a comparison.
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(RawLogit(value) == nil)
        }
    }

    @Test("A digest expectation is compared byte for byte")
    func preprocessingDigestCompared() async throws {
        let expected = StreamingSHA256.digest(of: Array("model-input-bytes".utf8))
        for (observed, agrees) in [(expected, true), (Sample.digest("d"), false)] {
            let candidate = try CompatibleBundleAssembler.standard(
                selfTests: [
                    SampleSelfTest(expectations: [.preprocessingOutputDigest(expected)])
                ]
            )
            let executor = FakeSelfTestExecutor(observations: [
                "fixture.sample": SelfTestObservation(preprocessingOutputDigest: observed)
            ])
            let runner = Self.runner(executor: executor, candidate: candidate)
            #expect((try await Self.finding(runner, candidate) == nil) == agrees)
        }
    }

    @Test("A case expecting one Analysis Error is not satisfied by another")
    func analysisErrorMustMatchExactly() async throws {
        let candidate = try CompatibleBundleAssembler.standard(
            selfTests: [SampleSelfTest(expectations: [.analysisError(.unsupportedMedia)])]
        )
        let executor = FakeSelfTestExecutor(observations: [
            "fixture.sample": SelfTestObservation(analysisError: .decodingError)
        ])
        let runner = Self.runner(executor: executor, candidate: candidate)
        #expect(
            try await Self.finding(runner, candidate)
                == .selfTestExpectationMismatch(case: Sample.selfTestCaseID(), kind: .analysisError)
        )
    }

    // MARK: Executor faults

    @Test("Each executor fault maps to its own finding")
    func executorFaultsMapExactly() async throws {
        let expected: [SelfTestExecutionFault: ModelBundleVerificationError] = [
            .modelLoadFailed: .selfTestCandidateLoadFailed(Sample.bundle()),
            .executionFailed: .selfTestExecutionFailed(Sample.selfTestCaseID()),
            .invalidOutput: .selfTestOutputInvalid(Sample.selfTestCaseID()),
        ]
        for (fault, finding) in expected {
            let candidate = try CompatibleBundleAssembler.standard()
            let executor = FakeSelfTestExecutor()
            executor.runFaults["fixture.sample"] = fault
            let runner = Self.runner(executor: executor, candidate: candidate)
            #expect(try await Self.finding(runner, candidate) == finding)
            #expect(executor.outstandingLoads == 0, "a rejected candidate must not stay loaded")
        }
    }

    @Test("A candidate whose model will not load is refused without running a case")
    func loadFailureRefused() async throws {
        let candidate = try CompatibleBundleAssembler.standard()
        let executor = FakeSelfTestExecutor()
        executor.loadFault = .modelLoadFailed
        let runner = Self.runner(executor: executor, candidate: candidate)
        #expect(
            try await Self.finding(runner, candidate)
                == .selfTestCandidateLoadFailed(Sample.bundle())
        )
        #expect(executor.runFixtures.isEmpty)
        #expect(executor.unloadCount == 0, "nothing was loaded, so nothing is unloaded")
    }

    @Test("A rejected candidate is unloaded on every failure path")
    func rejectedCandidateIsUnloaded() async throws {
        let candidate = try CompatibleBundleAssembler.standard(
            selfTests: [SampleSelfTest(expectations: [.pixelLabel(.notEnoughSignal)])]
        )
        let executor = FakeSelfTestExecutor(observations: [
            "fixture.sample": SelfTestObservation(pixelLabel: Self.label)
        ])
        let runner = Self.runner(executor: executor, candidate: candidate)
        _ = try await Self.finding(runner, candidate)
        #expect(executor.unloadCount == 1)
        #expect(executor.outstandingLoads == 0)
    }

    // MARK: The approved budget

    @Test("A budget measured for the other target is refused")
    func wrongTargetBudgetRefused() async throws {
        let candidate = try CompatibleBundleAssembler.standard()
        let executor = FakeSelfTestExecutor()
        let runner = Self.runner(
            executor: executor,
            candidate: candidate,
            budget: candidate.configuration.resourceBudgets.shareExtension
        )
        #expect(
            try await Self.finding(runner, candidate)
                == .selfTestBudgetTargetMismatch(
                    expected: .mainApplication,
                    found: .shareExtension
                )
        )
        #expect(executor.loadedContexts.isEmpty, "no model loads under the wrong budget")
    }

    @Test("A controller governing the other target is refused")
    func wrongTargetControllerRefused() async throws {
        let candidate = try CompatibleBundleAssembler.standard()
        let runner = Self.runner(
            executor: FakeSelfTestExecutor(),
            governor: StubResourceGovernor(target: .shareExtension),
            candidate: candidate
        )
        #expect(
            try await Self.finding(runner, candidate)
                == .selfTestBudgetTargetMismatch(
                    expected: .mainApplication,
                    found: .shareExtension
                )
        )
    }

    @Test("A refused memory reservation stops the run before the fixture is read")
    func refusedReservationStopsTheRun() async throws {
        let candidate = try CompatibleBundleAssembler.standard()
        let executor = FakeSelfTestExecutor(observations: [
            "fixture.sample": SelfTestObservation(pixelLabel: Self.label)
        ])
        let runner = Self.runner(
            executor: executor,
            governor: StubResourceGovernor(refusedMetrics: [.peakResidentMemory]),
            candidate: candidate
        )
        #expect(
            try await Self.finding(runner, candidate)
                == .selfTestResourceLimitReached(.peakResidentMemory)
        )
        #expect(executor.runFixtures.isEmpty, "headroom is reserved before the bytes are read")
    }

    @Test("A cancelled reservation is not recorded as a measured budget breach")
    func cancelledReservationIsNotABreach() async throws {
        // Both outcomes refuse the candidate, but only one of them is evidence that a hard
        // limit was reached, and a receipt should not confuse the two.
        let candidate = try CompatibleBundleAssembler.standard()
        let runner = Self.runner(
            executor: FakeSelfTestExecutor(),
            governor: StubResourceGovernor(cancelledMetrics: [.peakResidentMemory]),
            candidate: candidate
        )
        #expect(
            try await Self.finding(runner, candidate)
                == .selfTestResourceReservationRefused(.peakResidentMemory)
        )
    }

    @Test("A measured hard-limit breach stops the run, so an incomplete run cannot pass")
    func measuredBreachStopsTheRun() async throws {
        let candidate = try CompatibleBundleAssembler.standard()
        let executor = FakeSelfTestExecutor(observations: [
            "fixture.sample": SelfTestObservation(pixelLabel: Self.label)
        ])
        let runner = Self.runner(
            executor: executor,
            governor: StubResourceGovernor(breaching: [.thermalState]),
            candidate: candidate
        )
        #expect(
            try await Self.finding(runner, candidate)
                == .selfTestResourceLimitReached(.thermalState)
        )
        #expect(
            executor.loadedContexts.isEmpty,
            "a device already at a hard limit does not get a candidate loaded onto it first"
        )
    }

    @Test("The budget is sampled before the model loads and after every case")
    func budgetIsSampledAroundTheRun() async throws {
        let candidate = try CompatibleBundleAssembler.standard(
            selfTests: [
                SampleSelfTest(
                    caseID: "self-test.one",
                    fixtureID: "fixture.one",
                    suiteRelativePath: "one.jpg"
                ),
                SampleSelfTest(
                    caseID: "self-test.two",
                    fixtureID: "fixture.two",
                    suiteRelativePath: "two.jpg"
                ),
            ]
        )
        let executor = FakeSelfTestExecutor(observations: [
            "fixture.one": SelfTestObservation(pixelLabel: Self.label),
            "fixture.two": SelfTestObservation(pixelLabel: Self.label),
        ])
        let governor = StubResourceGovernor()
        _ = try await Self.runner(executor: executor, governor: governor, candidate: candidate)
            .run(try candidate.bindable())

        let metrics = ResourceMetric.requiredMetrics(for: .mainApplication)
        #expect(
            governor.log.observed.count == metrics.count * 3,
            "once before the run and once after each of the two cases"
        )
        #expect(Set(governor.log.observed) == metrics)
    }

    @Test("Headroom reserved for a fixture is returned, whether the case passes or fails")
    func reservedHeadroomIsAlwaysReturned() async throws {
        for expected in [Self.label, .notEnoughSignal] {
            let candidate = try CompatibleBundleAssembler.standard(
                selfTests: [SampleSelfTest(expectations: [.pixelLabel(expected)])]
            )
            let executor = FakeSelfTestExecutor(observations: [
                "fixture.sample": SelfTestObservation(pixelLabel: Self.label)
            ])
            let governor = StubResourceGovernor()
            let runner = Self.runner(executor: executor, governor: governor, candidate: candidate)
            _ = try await Self.finding(runner, candidate)
            #expect(governor.log.reserved == [.peakResidentMemory])
            #expect(
                governor.log.released == governor.log.reserved,
                "a failing case must not leak headroom that would refuse the next one"
            )
        }
    }

    @Test("An unmeasurable metric is recorded, not treated as a breach or a pass")
    func unmeasurableMetricIsRecorded() async throws {
        let candidate = try CompatibleBundleAssembler.standard()
        let executor = FakeSelfTestExecutor(observations: [
            "fixture.sample": SelfTestObservation(pixelLabel: Self.label)
        ])
        let runner = Self.runner(
            executor: executor,
            governor: StubResourceGovernor(unmeasurable: [.energyImpact, .decodedPixelCount]),
            candidate: candidate
        )
        let tested = try await runner.run(try candidate.bindable())
        #expect(tested.report.unmeasurableMetrics == [.decodedPixelCount, .energyImpact])
    }

    @Test("Only the main application's own metrics are sampled")
    func onlyGovernedMetricsAreSampled() async throws {
        let candidate = try CompatibleBundleAssembler.standard()
        let executor = FakeSelfTestExecutor(observations: [
            "fixture.sample": SelfTestObservation(pixelLabel: Self.label)
        ])
        // A Share Extension metric cannot stop a main-application run, because the
        // main-application budget does not define it.
        let runner = Self.runner(
            executor: executor,
            governor: StubResourceGovernor(breaching: [.handoffLatency]),
            candidate: candidate
        )
        #expect(try await Self.finding(runner, candidate) == nil)
    }

    // MARK: Fixture integrity at execution time

    @Test("A fixture that changed after resolution is refused rather than run")
    func fixtureChangedAfterResolutionRefused() async throws {
        // The resolved plan carries the digest step 5 measured; the tree now holds different
        // bytes of the same length, so only the digest catches it. Re-measuring at execution
        // time is what keeps an executor from being handed bytes nobody approved.
        var candidate = try CompatibleBundleAssembler.standard(
            selfTests: [SampleSelfTest(bytes: Array("original".utf8))]
        )
        let bindable = try candidate.bindable()
        candidate.integrity.tree.overwriteContent(
            "\(CompatibleBundleAssembler.fixtureRootPath)/sample.jpg",
            text: "0riginal"
        )
        let executor = FakeSelfTestExecutor(observations: [
            "fixture.sample": SelfTestObservation(pixelLabel: Self.label)
        ])
        let runner = Self.runner(executor: executor, candidate: candidate)
        #expect(
            await Self.finding(runner, bindable)
                == .selfTestFixtureDigestMismatch(Sample.fixtureID())
        )
        #expect(executor.runFixtures.isEmpty)
    }

    @Test("A fixture that became unreadable after resolution is refused")
    func unreadableFixtureRefused() async throws {
        var candidate = try CompatibleBundleAssembler.standard()
        let bindable = try candidate.bindable()
        let path = "\(CompatibleBundleAssembler.fixtureRootPath)/sample.jpg"
        candidate.integrity.tree.unreadablePaths.insert(path)
        let runner = Self.runner(executor: FakeSelfTestExecutor(), candidate: candidate)
        #expect(await Self.finding(runner, bindable) == .artifactUnreadable(Sample.path(path)))
    }

    // MARK: The seam carries no way to reach the network

    @Test("Nothing in the module's sources references a network or file-system API")
    func moduleHasNoNetworkOrFileSystemSurface() throws {
        // Requirements 10.20 and 10.21 make "with network connectivity disabled" a property
        // of the dependency graph rather than a runtime setting, and the module reaches bytes
        // only through the injected content seam. This asserts both from the source: a later
        // change that imports a networking or file-system framework here fails the test
        // rather than quietly widening what verification can touch.
        let forbidden = [
            "import Network", "import FoundationNetworking", "URLSession", "URLRequest",
            "NSURLConnection", "FileManager", "import CFNetwork",
        ]
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DefAIkeModelBundle")
        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "the module's sources must be readable for this to mean anything")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                #expect(
                    !text.contains(token),
                    "\(file.lastPathComponent) must not reference \(token)"
                )
            }
        }
    }
}