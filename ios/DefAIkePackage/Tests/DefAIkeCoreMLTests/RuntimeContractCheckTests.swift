import DefAIkeCoreML
import DefAIkeDomain
import Testing

// The two pure decisions behind the adapters: what a loaded model's description has to
// promise, and what one prediction has to carry.
//
// These run over hand-built values rather than a compiled model, so every rule in
// Requirements 4.9, 4.15, and 4.16 is exercised without a `.mlmodelc` and without a
// device. The exhaustive generated-input version of the output rules is Property 14 and
// belongs to task 6.8; these are the worked examples.

@Suite("Runtime schema validation")
struct RuntimeSchemaCheckTests {
    private let input = ContractFixture.input()
    private let output = ContractFixture.output()

    private func validate(_ schema: RuntimeModelSchema) throws(RuntimeSchemaDisagreement) {
        try RuntimeSchemaCheck.validate(schema, inputContract: input, outputContract: output)
    }

    @Test("A description matching the bound contracts is accepted")
    func acceptsMatchingDescription() throws {
        try validate(SchemaFixture.matching())
    }

    @Test(
        "Either interleaved 8-bit color format carries the three RGB channels",
        arguments: [RuntimeImagePixelFormat.bgra8, .argb8]
    )
    func acceptsBothColorFormats(format: RuntimeImagePixelFormat) throws {
        try validate(SchemaFixture.matching(pixelFormat: format))
    }

    @Test(
        "One floating-point number is accepted in either spelling a description can use",
        arguments: [
            RuntimeFeatureKind.scalar(.float64),
            .scalar(.float32),
            .scalar(.float16),
            .tensor(elementCount: 1, element: .float16),
            .tensor(elementCount: 1, element: .float32),
        ]
    )
    func acceptsEitherScalarSpelling(kind: RuntimeFeatureKind) throws {
        try validate(SchemaFixture.matching(outputKind: kind))
    }

    @Test("A misnamed input is refused")
    func refusesMisnamedInput() {
        #expect(throws: RuntimeSchemaDisagreement.inputFeatureSet(
            expected: "image",
            found: ["input_1"]
        )) {
            try validate(SchemaFixture.matching(inputName: "input_1"))
        }
    }

    @Test("A second input feature is refused rather than ignored")
    func refusesSecondInput() {
        let schema = RuntimeModelSchema(
            inputs: SchemaFixture.matching().inputs + [
                RuntimeFeatureDescription(name: "threshold", kind: .scalar(.float32))
            ],
            outputs: SchemaFixture.matching().outputs
        )
        #expect(throws: RuntimeSchemaDisagreement.inputFeatureSet(
            expected: "image",
            found: ["image", "threshold"]
        )) {
            try validate(schema)
        }
    }

    @Test(
        "An input that is not a bound-size three-channel image is refused",
        arguments: [
            // A multiarray cannot represent unsigned 8-bit pixels at all.
            RuntimeFeatureKind.tensor(elementCount: 384 * 384 * 3, element: .float32),
            // The wrong crop size would be measured as parity against 384x384.
            .image(width: 224, height: 224, pixelFormat: .bgra8),
            .image(width: 384, height: 383, pixelFormat: .bgra8),
            // One 8-bit component is not three RGB channels.
            .image(width: 384, height: 384, pixelFormat: .grayscale8),
            // A format this build cannot name is not assumed to be usable.
            .image(width: 384, height: 384, pixelFormat: .other),
            .unsupported,
        ]
    )
    func refusesUnusableInputKind(kind: RuntimeFeatureKind) {
        #expect(throws: RuntimeSchemaDisagreement.inputKind(name: "image", found: kind)) {
            try validate(SchemaFixture.withInputKind(kind))
        }
    }

    @Test("A misnamed output is refused")
    func refusesMisnamedOutput() {
        #expect(throws: RuntimeSchemaDisagreement.outputFeatureSet(
            expected: "logit",
            found: ["var_318"]
        )) {
            try validate(SchemaFixture.matching(outputName: "var_318"))
        }
    }

    @Test("A second output feature is refused rather than ignored")
    func refusesSecondOutput() {
        let schema = RuntimeModelSchema(
            inputs: SchemaFixture.matching().inputs,
            outputs: SchemaFixture.matching().outputs + [
                RuntimeFeatureDescription(name: "probability", kind: .scalar(.float32))
            ]
        )
        #expect(throws: RuntimeSchemaDisagreement.outputFeatureSet(
            expected: "logit",
            found: ["logit", "probability"]
        )) {
            try validate(schema)
        }
    }

    @Test(
        "An output that is not one floating-point number is refused",
        arguments: [
            RuntimeFeatureKind.tensor(elementCount: 2, element: .float32),
            .tensor(elementCount: 0, element: .float32),
            .tensor(elementCount: 1, element: .int32),
            .scalar(.int64),
            .scalar(.other),
            .image(width: 384, height: 384, pixelFormat: .bgra8),
            .unsupported,
        ]
    )
    func refusesUnusableOutputKind(kind: RuntimeFeatureKind) {
        #expect(throws: RuntimeSchemaDisagreement.outputKind(name: "logit", found: kind)) {
            try validate(SchemaFixture.matching(outputKind: kind))
        }
    }
}

@Suite("Model output validation")
struct ModelOutputCheckTests {
    private let contract = ContractFixture.output()

    private func logit(
        _ result: RuntimeFeatureResult
    ) throws(ModelOutputDisagreement) -> RawLogit {
        try ModelOutputCheck.logit(in: result, contract: contract)
    }

    @Test(
        "One finite scalar is returned exactly as the model emitted it",
        arguments: [0.0, 0.5, -3.25, 1.390625, -0.0, 1e-300, 1e300]
    )
    func returnsFiniteValueUnchanged(value: Double) throws {
        // Unchanged is the property that matters: a rescale, clamp, or sign flip here
        // would silently redefine the positive-going direction the contract fixes and
        // invalidate every parity measurement (Requirement 4.9).
        #expect(try logit(ResultFixture.logit(value)).value == value)
    }

    @Test("An empty result is the missing-output case")
    func refusesMissingOutput() {
        #expect(throws: ModelOutputDisagreement.missingRequiredFeature(name: "logit")) {
            try logit(RuntimeFeatureResult([:]))
        }
    }

    @Test("A number carried under another name does not satisfy the contract")
    func refusesMisnamedOutput() {
        #expect(throws: ModelOutputDisagreement.missingRequiredFeature(name: "logit")) {
            try logit(RuntimeFeatureResult(["score": .scalar(0.5)]))
        }
    }

    @Test("A result carrying more than the verified schema declared is refused")
    func refusesUnexpectedFeatures() {
        let result = RuntimeFeatureResult([
            "logit": .scalar(0.5),
            "probability": .scalar(0.62),
            "class": .nonNumeric,
        ])
        #expect(throws: ModelOutputDisagreement.unexpectedFeatures(
            names: ["class", "probability"]
        )) {
            try logit(result)
        }
    }

    @Test("A value that is not one element is the nonscalar case", arguments: [0, 2, 1000])
    func refusesNonScalar(elementCount: Int) {
        let result = RuntimeFeatureResult(["logit": .nonScalar(elementCount: elementCount)])
        #expect(throws: ModelOutputDisagreement.nonScalar(
            name: "logit",
            elementCount: elementCount
        )) {
            try logit(result)
        }
    }

    @Test("A value that is not a number is the nonnumeric case")
    func refusesNonNumeric() {
        #expect(throws: ModelOutputDisagreement.nonNumeric(name: "logit")) {
            try logit(RuntimeFeatureResult(["logit": .nonNumeric]))
        }
    }

    @Test(
        "NaN and both infinities are refused rather than calibrated",
        arguments: [Double.nan, .signalingNaN, .infinity, -.infinity]
    )
    func refusesNonFinite(value: Double) {
        #expect(throws: ModelOutputDisagreement.nonFinite(name: "logit")) {
            try logit(ResultFixture.logit(value))
        }
    }
}
