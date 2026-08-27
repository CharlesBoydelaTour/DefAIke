import DefAIkeDomain

// The Pixel Analyzing adapter.
//
// One call has exactly two outcomes: one finite ``RawLogit``, or one fault. There is no
// third result, no partial evidence, and no path that returns a number the output check
// did not accept.
//
// The failure mapping is the whole point of the file, so it is stated once here and
// implemented once below:
//
//   | Condition                                        | Outcome                              |
//   |--------------------------------------------------|--------------------------------------|
//   | Session cancelled at any boundary                | `cancelled`, no error, no evidence   |
//   | The bound model does not accept the input shape  | `preprocessing-error`                |
//   | The prepared buffer the token names is not there | `preprocessing-error`                |
//   | No model is loaded for the bound token           | `model-load-error`                   |
//   | Execution fails after a valid input              | `inference-error`                    |
//   | Output missing, misnamed, nonscalar, nonnumeric, |                                      |
//   | NaN, or infinite                                 | `invalid-output-error`               |
//
// Two mappings are worth stating explicitly, because the obvious alternative would
// over-claim:
//
//   * An input the bound model does not accept, or a prepared buffer that is absent or
//     not the shape it claims, is `preprocessing-error` and not `inference-error`.
//     Nothing was executed, and Requirement 4.15 and the design's error table scope
//     `inference-error` to a prediction that failed *after a valid input*. The bound
//     Preprocessing Contract's output is what is wrong, and Requirement 3.7 gives that
//     exactly one category with no fallback.
//   * A bound token that names no loaded model is `model-load-error`. There is no
//     loaded model to execute, and the analyzer does not load one itself
//     (Requirement 10.19).
//
// None of the failure paths produce Pixel Evidence, and none of them can: this adapter
// returns a logit or throws, and calibration is the only thing that produces a label
// (Requirements 4.14 through 4.16).

/// Runs one prediction against the session-bound model and validates its output.
public struct CoreMLPixelAnalyzer: PixelAnalyzing {
    /// Where the bound model was retained by ``CoreMLPixelModelLoader``.
    private let loadedModels: LoadedPixelModelStore

    /// Where the prepared 384x384 buffer lives. The image pipeline owns it; this
    /// adapter only dereferences the token the domain carries.
    private let preparedPixels: any PreparedPixelResolving

    public init(
        loadedModels: LoadedPixelModelStore,
        preparedPixels: any PreparedPixelResolving
    ) {
        self.loadedModels = loadedModels
        self.preparedPixels = preparedPixels
    }

    public func infer(
        _ input: ModelImageInput,
        model: BoundCoreMLModel
    ) async throws(AnalysisFault) -> RawLogit {
        try checkCancellation()

        // The shape the model was loaded against, checked against the shape that
        // actually arrived. Unreachable while ``ModelImageInput`` and
        // ``ModelInputContract`` both pin 384x384 unsigned 8-bit RGB, and kept as a
        // fail-closed branch so relaxing either invariant later cannot silently start
        // feeding the model a buffer it was not loaded for.
        guard model.accepts(input) else {
            throw Self.preparedInputFailure
        }

        guard let runtime = await loadedModels.runtime(for: model.model) else {
            throw AnalysisFault.analysis(.modelLoadError, stage: .modelLoad)
        }

        // The buffer has to be the one the input describes, not merely some buffer the
        // token resolves to: a disagreement here would be measured as parity against a
        // fixture it does not correspond to.
        guard let pixels = await preparedPixels.preparedPixels(for: input.buffer),
              pixels.edge == input.edge,
              pixels.channelOrder == input.channelOrder,
              UInt64(pixels.bytes.count) == input.byteCount
        else {
            throw Self.preparedInputFailure
        }

        try checkCancellation()

        let result: RuntimeFeatureResult
        do {
            result = try await runtime.predict(pixels)
        } catch {
            // Exhaustive over ``ModelPredictionFault``, so a framework error cannot
            // reach a user-facing surface and cancellation cannot be reported as an
            // inference failure.
            switch error {
            case .cancelled:
                throw AnalysisFault.cancelled
            case .executionFailed:
                throw AnalysisFault.analysis(.inferenceError, stage: .inference)
            }
        }

        // Core ML prediction is not forcibly interruptible once entered, so
        // cancellation is checked again on the way out. A cancelled session discards
        // the output rather than validating it: cancellation outranks an invalid
        // output, because a cancelled session has no error category at all.
        try checkCancellation()

        do {
            return try ModelOutputCheck.logit(in: result, contract: model.outputContract)
        } catch {
            // Every disagreement is one category. The finding is deliberately dropped
            // rather than attached: it names a feature, but a presentable diagnostic
            // built from an inference result is exactly what Requirement 9.11 keeps out
            // of the session, and Requirement 4.16 fixes one outcome for all of them.
            throw AnalysisFault.analysis(.invalidOutputError, stage: .outputValidation)
        }
    }

    /// The outcome for an input that is not the bound Preprocessing Contract's output.
    private static let preparedInputFailure = AnalysisFault.analysis(
        .preprocessingError,
        stage: .preprocessing
    )

    /// Fails closed on a cancelled session.
    private func checkCancellation() throws(AnalysisFault) {
        if Task.isCancelled {
            throw AnalysisFault.cancelled
        }
    }
}
