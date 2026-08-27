import DefAIkeDomain

// The Pixel Model Loading adapter.
//
// The order of the steps is the requirement, not an implementation preference:
//
//   1. Load exactly the compiled model the session-bound verified bundle names, with a
//      configuration that permits Apple Neural Engine execution (Requirements 4.1 and
//      4.11).
//   2. Validate the generated model description against the bundle's signed input and
//      output contracts before the model is reachable for inference (Requirement 4.14
//      and the design's Pixel Analyzer section).
//   3. Only then produce a ``BoundCoreMLModel``.
//
// Step 3 is the point of the type: a ``BoundCoreMLModel`` cannot be constructed by any
// other path in this module, and its own initializer refuses any identity other than
// the Lowq checkpoint, so "inference runs the sole permitted model from the bound
// verified bundle" is structural rather than a convention (Requirement 1.16).
//
// Every failure is `.analysis(.modelLoadError, stage: .modelLoad)` with nothing
// registered and nothing bound. There is no fallback to an older or unverified asset,
// no retry under a different configuration, and no discovery or download member to
// reach (Requirements 10.19 and 10.21).

/// Loads the one model a verified Model Bundle names.
public struct CoreMLPixelModelLoader: PixelModelLoading {
    /// How a compiled model becomes a usable runtime. The Core ML implementation is
    /// ``CoreMLModelRuntimeLoader``; the seam is what lets the mapping above be tested
    /// without a compiled model.
    private let runtimeLoader: any PixelModelRuntimeLoading

    /// Where the loaded model is retained for the analyzer.
    private let loadedModels: LoadedPixelModelStore

    public init(
        runtimeLoader: any PixelModelRuntimeLoading,
        loadedModels: LoadedPixelModelStore
    ) {
        self.runtimeLoader = runtimeLoader
        self.loadedModels = loadedModels
    }

    public func loadModel(
        from bundle: BoundModelBundle
    ) async throws(AnalysisFault) -> BoundCoreMLModel {
        try checkCancellation()

        let runtime: any PixelModelRuntime
        do {
            runtime = try await runtimeLoader.loadRuntime(for: bundle)
        } catch {
            // Exhaustive over ``ModelRuntimeLoadFault``: a new load fault cannot arrive
            // here as an unclassified default, and cancellation stays outside the
            // Analysis Error vocabulary (Requirement 11.17).
            switch error {
            case .cancelled:
                throw AnalysisFault.cancelled
            case .compiledModelUnavailable, .frameworkRefusedLoad:
                throw Self.loadFailure
            }
        }

        do {
            try RuntimeSchemaCheck.validate(
                runtime.schema,
                inputContract: bundle.manifest.inputContract,
                outputContract: bundle.manifest.outputContract
            )
        } catch {
            // The finding names which part of the description disagreed. It is not
            // presentable and is not carried into the session: Requirement 4.14 fixes
            // one category for every load failure, and the recovery action is the same
            // for all of them.
            throw Self.loadFailure
        }

        // Checked before registration rather than after, so a cancelled load leaves no
        // loaded model behind for cleanup to find (Requirement 11.14).
        try checkCancellation()

        let token = await loadedModels.register(runtime)
        guard let model = BoundCoreMLModel(
            bundleID: bundle.bundleID,
            modelIdentity: bundle.modelIdentity,
            coreMLModelVersion: bundle.componentVersions.coreMLModel,
            inputContract: bundle.manifest.inputContract,
            outputContract: bundle.manifest.outputContract,
            model: token
        ) else {
            // Only reachable for a bundle whose identity is not the Lowq checkpoint.
            // The manifest schema already refuses one, so this is defense in depth
            // rather than an expected path — and it releases the model it just
            // registered, because a refused load must leave nothing loaded.
            await loadedModels.release(token)
            throw Self.loadFailure
        }
        return model
    }

    /// The single outcome every load failure produces (Requirement 4.14).
    private static let loadFailure = AnalysisFault.analysis(.modelLoadError, stage: .modelLoad)

    /// Fails closed on a cancelled session.
    ///
    /// Cancellation is not an Analysis Error and must never be presented as one, which
    /// is why ``AnalysisFault`` keeps it separate (Requirements 11.14 and 15.7).
    private func checkCancellation() throws(AnalysisFault) {
        if Task.isCancelled {
            throw AnalysisFault.cancelled
        }
    }
}
