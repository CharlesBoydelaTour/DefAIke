import DefAIkeCoreML
import DefAIkeDomain
import Testing

// One inference call, and every way it can fail.
//
// The subject is the mapping, so each test asserts both halves of it: the exact
// `AnalysisError` and the stage it is reported at. There is no assertion that Pixel
// Evidence is absent because there is nothing to assert: `infer` returns a `RawLogit`
// or throws, and only calibration produces a label — a failure has no way to reach one
// (Requirements 4.14 through 4.16).

@Suite("Core ML pixel inference")
struct PixelInferenceTests {
    /// A loaded model, plus the analyzer wired to the same store.
    private func loaded(
        runtime: StubPixelModelRuntime,
        pixels: PreparedPixelData? = PixelFixture.bound()
    ) async throws -> (BoundCoreMLModel, CoreMLPixelAnalyzer) {
        let store = LoadedPixelModelStore()
        let model = try await CoreMLPixelModelLoader(
            runtimeLoader: StubRuntimeLoader(outcome: .success(runtime)),
            loadedModels: store
        ).loadModel(from: BundleFixture.boundBundle())
        let analyzer = CoreMLPixelAnalyzer(
            loadedModels: store,
            preparedPixels: StubPixelResolver(pixels: pixels)
        )
        return (model, analyzer)
    }

    @Test("A successful prediction returns the one finite logit it emitted")
    func returnsTheEmittedLogit() async throws {
        let calls = CallCounter()
        let (model, analyzer) = try await loaded(
            runtime: StubPixelModelRuntime(outcome: .success(ResultFixture.logit(-1.75)), calls: calls)
        )

        let logit = try await analyzer.infer(PixelFixture.modelInput(), model: model)

        #expect(logit.value == -1.75)
        #expect(await calls.count == 1)
    }

    @Test("A bound token that names no loaded model is model-load-error")
    func refusesUnloadedModel() async throws {
        let analyzer = CoreMLPixelAnalyzer(
            loadedModels: LoadedPixelModelStore(),
            preparedPixels: StubPixelResolver()
        )
        // Nothing was ever registered, so this is the token of a model that is not
        // loaded. The analyzer reports that rather than loading one itself.
        await #expect(throws: AnalysisFault.analysis(.modelLoadError, stage: .modelLoad)) {
            try await analyzer.infer(PixelFixture.modelInput(), model: ModelFixture.bound(token: 99))
        }
    }

    @Test("A prepared buffer the token does not resolve to stops before execution")
    func refusesMissingBuffer() async throws {
        let calls = CallCounter()
        let (model, analyzer) = try await loaded(
            runtime: StubPixelModelRuntime(calls: calls),
            pixels: nil
        )

        // Not `inference-error`: nothing was executed, and the bound Preprocessing
        // Contract's output is what is missing (Requirement 3.7).
        await #expect(throws: AnalysisFault.analysis(.preprocessingError, stage: .preprocessing)) {
            try await analyzer.infer(PixelFixture.modelInput(), model: model)
        }
        #expect(await calls.count == 0)
    }

    @Test("A buffer that is not the shape the input describes stops before execution")
    func refusesMismatchedBuffer() async throws {
        let calls = CallCounter()
        let (model, analyzer) = try await loaded(
            runtime: StubPixelModelRuntime(calls: calls),
            // Internally consistent, but not the 384-pixel square the input names.
            pixels: PixelFixture.bound(edge: 128)
        )

        await #expect(throws: AnalysisFault.analysis(.preprocessingError, stage: .preprocessing)) {
            try await analyzer.infer(PixelFixture.modelInput(), model: model)
        }
        #expect(await calls.count == 0)
    }

    @Test("Execution failure after a valid input is inference-error")
    func mapsExecutionFailure() async throws {
        let (model, analyzer) = try await loaded(
            runtime: StubPixelModelRuntime(outcome: .failure(.executionFailed))
        )

        await #expect(throws: AnalysisFault.analysis(.inferenceError, stage: .inference)) {
            try await analyzer.infer(PixelFixture.modelInput(), model: model)
        }
    }

    @Test("Cancellation during execution is not an Analysis Error")
    func mapsCancellation() async throws {
        let (model, analyzer) = try await loaded(
            runtime: StubPixelModelRuntime(outcome: .failure(.cancelled))
        )

        await #expect(throws: AnalysisFault.cancelled) {
            try await analyzer.infer(PixelFixture.modelInput(), model: model)
        }
    }

    @Test(
        "Every unusable output is invalid-output-error at output validation",
        arguments: [
            // Missing, misnamed, nonscalar, nonnumeric, NaN, and both infinities.
            RuntimeFeatureResult([:]),
            RuntimeFeatureResult(["score": .scalar(0.5)]),
            RuntimeFeatureResult(["logit": .nonScalar(elementCount: 2)]),
            RuntimeFeatureResult(["logit": .nonNumeric]),
            RuntimeFeatureResult(["logit": .scalar(.nan)]),
            RuntimeFeatureResult(["logit": .scalar(.infinity)]),
            RuntimeFeatureResult(["logit": .scalar(-.infinity)]),
            RuntimeFeatureResult(["logit": .scalar(0.5), "probability": .scalar(0.62)]),
        ]
    )
    func mapsUnusableOutput(result: RuntimeFeatureResult) async throws {
        let (model, analyzer) = try await loaded(
            runtime: StubPixelModelRuntime(outcome: .success(result))
        )

        await #expect(
            throws: AnalysisFault.analysis(.invalidOutputError, stage: .outputValidation)
        ) {
            try await analyzer.infer(PixelFixture.modelInput(), model: model)
        }
    }

    @Test("A cancelled session is refused before anything is executed")
    func refusesCancelledSession() async throws {
        let calls = CallCounter()
        let (model, analyzer) = try await loaded(runtime: StubPixelModelRuntime(calls: calls))

        // Cancelling the surrounding task is how a session is cancelled; the analyzer
        // has no cancel member of its own to call. A task added to an already-cancelled
        // group starts cancelled, so this does not race the first check.
        let fault = await withTaskGroup(of: AnalysisFault?.self) { group in
            group.cancelAll()
            group.addTask {
                do {
                    _ = try await analyzer.infer(PixelFixture.modelInput(), model: model)
                    return nil
                } catch let fault as AnalysisFault {
                    return fault
                } catch {
                    return nil
                }
            }
            return await group.next() ?? nil
        }

        #expect(fault == .cancelled)
        #expect(await calls.count == 0)
    }
}
