import DefAIkeCoreML
import DefAIkeDomain
import Testing

// What loading a model produces, and what every failure to load produces.
//
// The seam stands in for Core ML, so these assert the adapter's contract: exactly the
// bound bundle's identifiers on success, exactly `model-load-error` on every failure,
// nothing left loaded when a load is refused, and cancellation kept outside the
// Analysis Error vocabulary (Requirements 4.1, 4.14, and 11.17).

@Suite("Core ML pixel model loading")
struct PixelModelLoadingTests {
    private func loader(
        _ outcome: Result<StubPixelModelRuntime, ModelRuntimeLoadFault>,
        store: LoadedPixelModelStore
    ) -> CoreMLPixelModelLoader {
        CoreMLPixelModelLoader(
            runtimeLoader: StubRuntimeLoader(outcome: outcome),
            loadedModels: store
        )
    }

    @Test("A loaded model carries the bound bundle's identifiers and contracts")
    func bindsTheBundleValues() async throws {
        let bundle = BundleFixture.boundBundle()
        let store = LoadedPixelModelStore()
        let model = try await loader(.success(StubPixelModelRuntime()), store: store)
            .loadModel(from: bundle)

        #expect(model.bundleID == bundle.bundleID)
        #expect(model.modelIdentity == RequiredPixelModel.identity)
        #expect(model.coreMLModelVersion == bundle.componentVersions.coreMLModel)
        #expect(model.inputContract == bundle.manifest.inputContract)
        #expect(model.outputContract == bundle.manifest.outputContract)
        // The bound model accepts the shape the Preprocessor produces, which is what
        // the analyzer checks before it executes anything.
        #expect(model.accepts(PixelFixture.modelInput()))
        #expect(await store.loadedModelCount == 1)
        #expect(await store.runtime(for: model.model) != nil)
    }

    @Test(
        "Every framework load failure is model-load-error with nothing left loaded",
        arguments: [
            ModelRuntimeLoadFault.compiledModelUnavailable,
            .frameworkRefusedLoad,
        ]
    )
    func mapsLoadFailures(fault: ModelRuntimeLoadFault) async throws {
        let store = LoadedPixelModelStore()
        await #expect(throws: AnalysisFault.analysis(.modelLoadError, stage: .modelLoad)) {
            try await loader(.failure(fault), store: store).loadModel(
                from: BundleFixture.boundBundle()
            )
        }
        #expect(await store.loadedModelCount == 0)
    }

    @Test("Cancellation during load is not an Analysis Error")
    func mapsCancellation() async throws {
        let store = LoadedPixelModelStore()
        await #expect(throws: AnalysisFault.cancelled) {
            try await loader(.failure(.cancelled), store: store).loadModel(
                from: BundleFixture.boundBundle()
            )
        }
        #expect(await store.loadedModelCount == 0)
    }

    @Test(
        "A description that disagrees with the bound contracts is refused at load",
        arguments: [
            // Wrong input name, wrong crop size, and an output that is neither named
            // nor shaped the way the contract fixes.
            SchemaFixture.matching(inputName: "input_1"),
            SchemaFixture.withInputKind(
                .image(width: 224, height: 224, pixelFormat: .bgra8)
            ),
            SchemaFixture.matching(outputName: "var_318"),
            SchemaFixture.matching(outputKind: .tensor(elementCount: 2, element: .float32)),
        ]
    )
    func refusesSchemaDisagreement(schema: RuntimeModelSchema) async throws {
        let store = LoadedPixelModelStore()
        await #expect(throws: AnalysisFault.analysis(.modelLoadError, stage: .modelLoad)) {
            try await loader(.success(StubPixelModelRuntime(schema: schema)), store: store)
                .loadModel(from: BundleFixture.boundBundle())
        }
        // A refused load leaves nothing loaded, so a later inference cannot find a
        // model the contracts never accepted.
        #expect(await store.loadedModelCount == 0)
    }

    @Test("Each load registers its own model rather than replacing the previous one")
    func registersDistinctModels() async throws {
        let store = LoadedPixelModelStore()
        let subject = loader(.success(StubPixelModelRuntime()), store: store)
        let first = try await subject.loadModel(from: BundleFixture.boundBundle())
        let second = try await subject.loadModel(from: BundleFixture.boundBundle())

        // Two activations have to be distinguishable, so a session that bound the first
        // is not silently re-pointed at the second (Requirement 10.14).
        #expect(first.model != second.model)
        #expect(await store.loadedModelCount == 2)
    }

    @Test("Releasing a loaded model is idempotent")
    func releaseIsIdempotent() async throws {
        let store = LoadedPixelModelStore()
        let model = try await loader(.success(StubPixelModelRuntime()), store: store)
            .loadModel(from: BundleFixture.boundBundle())

        await store.release(model.model)
        await store.release(model.model)

        #expect(await store.loadedModelCount == 0)
        #expect(await store.runtime(for: model.model) == nil)
    }
}
