import DefAIkeDomain

// The two checks that decide whether a loaded model may be used and whether one
// prediction produced a raw logit.
//
// Both are pure total functions over values a test can build by hand, which is the
// point: the mapping in Requirements 4.9, 4.15, and 4.16 is decided here, once, and
// the adapters below only translate the finding into an ``AnalysisFault``. Neither
// function allocates, logs, awaits, or touches the framework.
//
// Neither finding carries an image-derived value. A disagreement names the feature and
// the shape of the problem, never the number that was found, so a diagnostic built
// from one cannot become a logit in a log (Requirement 9.11).

// MARK: - The generated model description

/// Why a loaded model's schema disagrees with the bound contracts.
///
/// Every case is `model-load-error`: a model whose description does not match the
/// signed contracts is not the model the session bound, and there is no partial
/// acceptance (Requirement 4.14).
public enum RuntimeSchemaDisagreement: Error, Hashable, Sendable {
    /// The description does not declare exactly the one input the contract names.
    case inputFeatureSet(expected: String, found: [String])

    /// The named input is not an unsigned 8-bit three-channel image of the bound size.
    case inputKind(name: String, found: RuntimeFeatureKind)

    /// The description does not declare exactly the one output the contract names.
    case outputFeatureSet(expected: String, found: [String])

    /// The named output is not one floating-point scalar.
    case outputKind(name: String, found: RuntimeFeatureKind)
}

/// Checks a generated model description against the bound input and output contracts.
public enum RuntimeSchemaCheck {
    /// Accepts only the schema the bound contracts describe.
    ///
    /// One input and one output, both named by the contract. Extra features are
    /// refused rather than ignored: a description that promises a second input or a
    /// second output is not the fixed single-logit model the requirements bind, and
    /// picking one feature out of several is how an adapter silently starts measuring
    /// something other than what was released (Requirements 4.9 and 10.4).
    public static func validate(
        _ schema: RuntimeModelSchema,
        inputContract: ModelInputContract,
        outputContract: ModelOutputContract
    ) throws(RuntimeSchemaDisagreement) {
        try validateInput(schema, contract: inputContract)
        try validateOutput(schema, contract: outputContract)
    }

    private static func validateInput(
        _ schema: RuntimeModelSchema,
        contract: ModelInputContract
    ) throws(RuntimeSchemaDisagreement) {
        let expected = contract.featureName.value
        guard schema.inputs.count == 1, let input = schema.inputs.first,
              input.name == expected
        else {
            throw .inputFeatureSet(expected: expected, found: schema.inputs.map(\.name).sorted())
        }
        // An unsigned 8-bit three-channel buffer is an image feature in Core ML terms:
        // a multiarray has no unsigned 8-bit element type, so a description that
        // declares one for this input disagrees with the contract rather than offering
        // an equivalent spelling. ``ModelInputContract`` has already fixed the element
        // type to `uint8` and both dimensions to 384.
        guard case .image(let width, let height, let pixelFormat) = input.kind,
              width == contract.width, height == contract.height
        else {
            throw .inputKind(name: input.name, found: input.kind)
        }
        // Total over the channel orders the contract can name, so adding one has to
        // decide its own pixel-format rule instead of inheriting this one.
        switch contract.channelOrder {
        case .rgb:
            guard pixelFormat.carriesThreeColorChannels else {
                throw .inputKind(name: input.name, found: input.kind)
            }
        }
    }

    private static func validateOutput(
        _ schema: RuntimeModelSchema,
        contract: ModelOutputContract
    ) throws(RuntimeSchemaDisagreement) {
        let expected = contract.featureName.value
        guard schema.outputs.count == 1, let output = schema.outputs.first,
              output.name == expected
        else {
            throw .outputFeatureSet(expected: expected, found: schema.outputs.map(\.name).sorted())
        }
        // One floating-point number, in either of the two ways a description can
        // describe one: a scalar feature, or a tensor declaring exactly one element.
        // The declared element type is required to be floating point rather than
        // required to equal `contract.elementType`, because a description states how
        // the feature is surfaced and not the precision the graph computes in. The
        // FP16 `mlprogram` fact is verified from the signed manifest by bundle
        // verification (Requirements 4.2 and 10.3), not from this projection. Which
        // spelling the released model uses is confirmed against the real compiled
        // model by the integration tests in task 6.11; both are accepted here because
        // both name exactly one number.
        switch output.kind {
        case .scalar(let element) where element.isFloatingPoint:
            return
        case .tensor(let elementCount, let element) where elementCount == 1 && element.isFloatingPoint:
            return
        case .scalar, .tensor, .image, .unsupported:
            throw .outputKind(name: output.name, found: output.kind)
        }
    }
}

// MARK: - One prediction's result

/// Why a runtime feature result is not one finite raw logit.
///
/// Every case is `invalid-output-error`, and none of them may be mapped to a pixel
/// label (Requirements 4.16 and 5.2). The cases are the exact conditions the
/// requirements and the design enumerate, so "missing", "misnamed", "nonscalar",
/// "nonnumeric", and "nonfinite" are each refused by name rather than collapsed into
/// one unexplained rejection.
public enum ModelOutputDisagreement: Error, Hashable, Sendable {
    /// Nothing in the result is named the way the contract requires. This is the
    /// misnamed case as well as the absent one: a result carrying the number under
    /// another name does not carry the required feature.
    case missingRequiredFeature(name: String)

    /// The result carries features beyond the one the verified schema declared.
    case unexpectedFeatures(names: [String])

    /// The required feature does not hold exactly one element.
    case nonScalar(name: String, elementCount: Int)

    /// The required feature is not a number.
    case nonNumeric(name: String)

    /// The required feature is a number, but NaN or infinite.
    case nonFinite(name: String)
}

/// Extracts the one finite raw logit a successful prediction must carry.
public enum ModelOutputCheck {
    /// The finite raw logit in `result`, or the exact reason there is not one.
    ///
    /// The returned value is the number the model emitted. Nothing here rescales,
    /// clamps, rounds, negates, or otherwise transforms it, so the positive-going
    /// direction the contract fixes is preserved by leaving the number alone, and the
    /// only value that can reach calibration is a finite one (Requirement 4.9).
    public static func logit(
        in result: RuntimeFeatureResult,
        contract: ModelOutputContract
    ) throws(ModelOutputDisagreement) -> RawLogit {
        // The contract has already fixed this to `logit`; reading it from the contract
        // rather than repeating the literal keeps one source for the name.
        let required = contract.featureName.value
        guard let value = result.features[required] else {
            throw .missingRequiredFeature(name: required)
        }
        let extra = result.features.keys.filter { $0 != required }.sorted()
        guard extra.isEmpty else {
            // The schema was pinned at load, so a result naming anything else is a
            // disagreement with the verified description. Refusing is fail-closed;
            // ignoring the extra feature would mean the model that ran is not the
            // model that was validated.
            throw .unexpectedFeatures(names: extra)
        }
        switch value {
        case .nonNumeric:
            throw .nonNumeric(name: required)
        case .nonScalar(let elementCount):
            throw .nonScalar(name: required, elementCount: elementCount)
        case .scalar(let raw):
            // ``RawLogit`` makes NaN and infinity unrepresentable, so this is the one
            // place a nonfinite model output can be turned away, and no calibration
            // path can receive one (Requirement 4.16).
            guard let logit = RawLogit(raw) else {
                throw .nonFinite(name: required)
            }
            return logit
        }
    }
}
