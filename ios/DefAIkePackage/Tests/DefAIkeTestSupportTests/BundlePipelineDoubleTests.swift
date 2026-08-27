import DefAIkeDomain
import Testing

@testable import DefAIkeTestSupport

/// Covers the bundle values and the analysis-pipeline doubles end to end.
///
/// Two jobs. First, it checks the invariants ``BoundModelBundle`` and
/// ``BoundCoreMLModel`` enforce, which are what make an unverified bundle and a wrong
/// model identity unrepresentable rather than merely unlikely. Second, it drives the
/// pipeline stubs in sequence, so every port has a conforming implementation that is
/// actually exercised and so the call spy's ordering assertions are demonstrated on a
/// realistic sequence.
@Suite("Bundle values and pipeline doubles")
struct BundlePipelineDoubleTests {

    // MARK: - Bound bundle invariants

    @Test("A bundle binds only when its receipt describes the same bundle")
    func receiptMustMatchManifest() {
        #expect(BundleFixture.boundBundle() != nil)
        #expect(BundleFixture.boundBundle(receiptBundleID: "bundle-9999") == nil)
    }

    @Test(
        "A receipt whose checks did not pass cannot produce a bound bundle",
        arguments: [GateOutcome.failed, .notExecuted]
    )
    func unbindableReceiptIsRefused(outcome: GateOutcome) {
        #expect(BundleFixture.boundBundle(outcome: outcome) == nil)
    }

    @Test("A bound bundle projects a verified integrity record")
    func boundBundleProjectsVerifiedIntegrity() {
        let bundle = BundleFixture.requiredBoundBundle()
        let receipt = BundleFixture.receipt()

        #expect(bundle.integrity.status == .verified)
        #expect(bundle.integrity.activationReceiptID == receipt.id)
        #expect(bundle.integrity.verificationPolicyID == receipt.verificationPolicy)
        #expect(bundle.integrity.verifiedManifestDigest == receipt.verifiedManifestDigest)
        #expect(bundle.modelIdentity == RequiredPixelModel.identity)
    }

    @Test("Compatibility needs the exact build, the capabilities, and the OS minimum")
    func compatibilityIsExact() {
        let bundle = BundleFixture.requiredBoundBundle(appBuild: "build-0001")

        #expect(bundle.isCompatible(with: BundleFixture.releaseContext(appBuild: "build-0001")))
        #expect(!bundle.isCompatible(with: BundleFixture.releaseContext(appBuild: "build-0002")))
    }

    @Test("A release context without pixel analysis is not constructible")
    func pixelAnalysisIsRequired() {
        #expect(
            ReleaseContext(
                device: BundleFixture.deviceContext(),
                approvedConfiguration: PortValue.configurationID(),
                capabilityManifestID: PortValue.artifactID("capability-0001"),
                compiledCapabilities: [.shareExtensionHandoff]
            ) == nil
        )
    }

    @Test("Only the required pixel model identity can be bound")
    func onlyTheRequiredModelBinds() {
        #expect(
            BoundCoreMLModel(
                bundleID: PortValue.bundleID(),
                modelIdentity: ModelIdentity(
                    checkpointIdentifier: checkpoint("Other/some-other-detector-2026-01"),
                    requiredWeightDigest: TestSHA256.digest(ofUTF8: "other")
                ),
                coreMLModelVersion: PortValue.artifactID("coreml-model-0001"),
                inputContract: PreprocessingFixture.contract().modelInput,
                outputContract: PreprocessingFixture.modelOutputContract(),
                model: LoadedModelToken(rawValue: 1)
            ) == nil
        )
    }

    @Test("A bound model accepts exactly the contract's input shape")
    func boundModelAcceptsContractShape() {
        #expect(BundleFixture.boundModel().accepts(PortValue.modelInput()))
    }

    // MARK: - Bundle manager double

    @Test("An installed candidate activates and becomes the complete active tuple")
    func activationReplacesTheActiveTuple() async throws {
        let recorder = PortCallRecorder()
        let manager = StubModelBundleManager(recorder: recorder)
        let context = BundleFixture.releaseContext()
        let first = BundleFixture.requiredBoundBundle(bundleID: "bundle-0001")
        let second = BundleFixture.requiredBoundBundle(bundleID: "bundle-0002")
        await manager.installAndActivate(first)
        await manager.install(second)

        let activated = try await manager.activateLocalCandidate(second.bundleID, context: context)

        #expect(activated.bundleID == second.bundleID)
        #expect(await manager.activeBundle()?.bundleID == second.bundleID)
        #expect(recorder.didCall(.activateLocalCandidate(second.bundleID)))
    }

    @Test(
        "A failure at any verification boundary leaves the previous bundle active",
        arguments: StubModelBundleManager.ActivationFailurePoint.allCases
    )
    func failedActivationIsAtomic(
        point: StubModelBundleManager.ActivationFailurePoint
    ) async throws {
        let manager = StubModelBundleManager()
        let context = BundleFixture.releaseContext()
        let active = BundleFixture.requiredBoundBundle(bundleID: "bundle-0001")
        let candidate = BundleFixture.requiredBoundBundle(bundleID: "bundle-0002")
        await manager.installAndActivate(active)
        await manager.install(candidate)
        await manager.failActivation(of: candidate.bundleID, at: point)

        await #expect(throws: AnalysisFault.analysis(.modelLoadError, stage: .modelLoad)) {
            _ = try await manager.activateLocalCandidate(candidate.bundleID, context: context)
        }

        // The complete old tuple, not a mixture, and never an unverified fallback.
        let observed = try #require(await manager.activeBundle())
        #expect(observed == active)
        #expect(try await manager.verifiedActiveBundle(for: context) == active)
    }

    @Test("Rollback runs the same verification path as activation")
    func rollbackIsNotTrustedByDefault() async throws {
        let manager = StubModelBundleManager()
        let context = BundleFixture.releaseContext()
        let current = BundleFixture.requiredBoundBundle(bundleID: "bundle-0002")
        let prior = BundleFixture.requiredBoundBundle(bundleID: "bundle-0001")
        await manager.installAndActivate(current)
        await manager.install(prior)
        await manager.failActivation(of: prior.bundleID, at: .signatureVerification)

        await #expect(throws: AnalysisFault.analysis(.modelLoadError, stage: .modelLoad)) {
            _ = try await manager.rollback(to: prior.bundleID, context: context)
        }
        #expect(await manager.activeBundle()?.bundleID == current.bundleID)

        await manager.succeedActivation(of: prior.bundleID)
        #expect(try await manager.rollback(to: prior.bundleID, context: context) == prior)
    }

    @Test("An uninstalled bundle is model-load-error, never a fallback")
    func missingBundleFailsClosed() async throws {
        let manager = StubModelBundleManager()

        await #expect(throws: AnalysisFault.analysis(.modelLoadError, stage: .modelLoad)) {
            _ = try await manager.verifiedActiveBundle(for: BundleFixture.releaseContext())
        }
    }

    // MARK: - Pipeline sequence

    @Test("The pipeline doubles run in causal stage order")
    func pipelineRunsInStageOrder() async throws {
        let recorder = PortCallRecorder()
        let sessionID = PortValue.sessionID()
        let contract = PreprocessingFixture.contract()
        let budget = ResourceFixture.budget(for: .mainApplication)
        let bundle = BundleFixture.requiredBoundBundle()

        let validator = StubInputValidator(
            outcome: StubOutcome(always: PortValue.validatedImage(sessionID: sessionID)),
            recorder: recorder
        )
        let preprocessor = StubImagePreprocessor(
            outcome: StubOutcome(always: PortValue.modelInput(sessionID: sessionID)),
            recorder: recorder
        )
        let loader = StubPixelModelLoader(
            outcome: StubOutcome(always: BundleFixture.boundModel()),
            recorder: recorder
        )
        let analyzer = StubPixelAnalyzer.returning(logit: 0.5, recorder: recorder)
        let calibrator = StubPixelCalibrator.returning(.noStrongSignalDetected, recorder: recorder)

        let image = try await validator.validate(
            PortValue.asset(sessionID: sessionID),
            contract: contract,
            budget: budget
        )
        let input = try await preprocessor.prepare(image, contract: contract, budget: budget)
        let model = try await loader.loadModel(from: bundle)
        let logit = try await analyzer.infer(input, model: model)
        let evidence = try calibrator.classify(
            logit,
            quality: image.quality,
            policy: CalibrationFixture.policy()
        )

        #expect(evidence == .noStrongSignalDetected)
        #expect(
            recorder.callKinds == [.validate, .preprocess, .loadModel, .infer, .calibrate]
        )
        #expect(recorder.allCalls(of: .validate, precede: .infer))
        #expect(recorder.allCalls(of: .preprocess, precede: .infer))
    }

    @Test("A validation fault stops the pipeline before any downstream call")
    func validationFaultShortCircuits() async {
        let recorder = PortCallRecorder()
        let validator = StubInputValidator(
            outcome: StubOutcome(
                alwaysFailing: .analysis(.unsupportedStaticFormat, stage: .mediaClassification)
            ),
            recorder: recorder
        )
        _ = StubImagePreprocessor.alwaysFailing(recorder: recorder)
        _ = StubPixelAnalyzer.returning(logit: 9.0, recorder: recorder)

        await #expect(
            throws: AnalysisFault.analysis(.unsupportedStaticFormat, stage: .mediaClassification)
        ) {
            _ = try await validator.validate(
                PortValue.asset(),
                contract: PreprocessingFixture.contract(),
                budget: ResourceFixture.budget(for: .mainApplication)
            )
        }

        #expect(recorder.callKinds == [.validate])
        #expect(!recorder.didCall(PortCallKind.preprocess))
        #expect(!recorder.didCall(PortCallKind.infer))
        #expect(!recorder.didCall(PortCallKind.calibrate))
    }

    // MARK: - Helpers

    private func checkpoint(_ raw: String) -> ModelCheckpointIdentifier {
        guard let id = ModelCheckpointIdentifier(raw) else {
            preconditionFailure("checkpoint identifier is not canonical: \(raw)")
        }
        return id
    }
}
