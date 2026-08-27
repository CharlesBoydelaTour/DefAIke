import DefAIkeCoreML
import DefAIkeDomain
import Foundation
import PropertyBased
import Testing

// Design Property 14: model output and failure mapping are exact.
//
// The design states it as: for any model-load result, prediction result, and output
// feature set, a load failure maps only to `model-load-error`, an execution failure maps
// only to `inference-error`, and success yields a raw output only when there is exactly
// one finite scalar named `logit`; every missing, misnamed, wrong-shaped, NaN, or infinite
// output maps only to `invalid-output-error`, and no failure produces Pixel Evidence.
//
// Four requirement leaves. Requirement 4.9 fixes one finite positive-going raw logit named
// `logit` on success, Requirement 4.14 fixes `model-load-error` for a load failure,
// Requirement 4.15 fixes `inference-error` for an execution failure, and Requirement 4.16
// fixes `invalid-output-error` for a missing or nonfinite output and forbids mapping it to
// a pixel label. This file generates one load outcome family, one prediction outcome, and
// one output feature set family per case, mutates exactly one aspect per arm, and
// quantifies four halves over the real `CoreMLPixelModelLoader` and `CoreMLPixelAnalyzer`:
//
//   * **the constant half** — the feature name the production contract pins and the three
//     error category strings are the ones the requirements name, and every generated mutant
//     really is outside the accepted set. Without this, every refusal below would be
//     measured against whatever the code happened to carry (Requirements 4.9, 4.14, 4.15,
//     4.16);
//   * **the load half** — every generated load outcome that is not a success produces
//     exactly `model-load-error`, whether the framework refused the compiled model, the
//     generated model description disagreed about the output feature, or the bound token
//     names no loaded model. Nothing is executed and no label is produced
//     (Requirement 4.14);
//   * **the execution half** — a prediction that fails after a valid input produces exactly
//     `inference-error`, the prediction really was attempted, and no label is produced
//     (Requirement 4.15);
//   * **the output half** — a prediction that returns a defective feature set produces
//     exactly `invalid-output-error` at output validation, the pure check names the one
//     cause it found, and no label is produced; a prediction that returns exactly one
//     finite scalar named `logit` produces that number unchanged, and exactly one label
//     (Requirements 4.9, 4.16).
//
// ## How "and no failure produces Pixel Evidence" is made non-vacuous
//
// `PixelAnalyzing.infer` returns a `RawLogit` or throws, so a failure has no channel
// through which a label could travel — which is exactly why asserting its absence is
// worthless on its own. Every case therefore runs a label-producing step past the analyzer,
// and the accepted arm is the **positive control**: the same fixtures, the same store, the
// same analyzer, and the same step, with only the prediction outcome changed, provably
// record one label. ``PixelEvidenceSink`` counts what that step produced, so an empty
// recording on a failure arm is a measured zero beside a measured one rather than an
// unreachable branch. If the control ever stops producing a label, the witness reports every
// absence assertion as unbacked instead of letting them pass vacuously.
//
// ``LabelProducingStep`` is a spy, not calibration. It returns the label the generated case
// programmed it with, so a recorded label proves only that a label-producing step was
// reached with a finite logit. Which of the three labels a given finite logit deserves is
// the validated Calibration Policy's decision and Property 16's subject. The real
// `PixelCalibrating` port additionally requires a validated Calibration Policy; no approved
// policy artifact exists in this repository, and inventing a False Accusation Budget, a
// decision boundary, or an abstention half-width in order to call it would be fabricating
// approved values. The structural point the spy makes is the one Property 14 needs: the only
// way into a label is through a finite `RawLogit`, and `RawLogit` cannot hold NaN or an
// infinity.
//
// ## Floating-point exactness
//
// Every finiteness claim is asserted with `isFinite`, `isNaN`, `isInfinite`, and `sign`
// rather than with an arithmetic comparison, because `NaN != NaN` makes an equality
// assertion over a nonfinite value silently meaningless, and `-0.0 == 0.0` is true while the
// two are distinguishable. "The number the model emitted, unchanged" is asserted on
// `bitPattern`, which separates `-0.0` from `+0.0` and admits no rescale, clamp, round, or
// sign flip. The generated finite family includes both zeros, both signed subnormals, both
// signed greatest-finite magnitudes, and one value that is finite as a `Double` but
// overflows `Float`, so a narrowing conversion anywhere on the path would turn it infinite
// and fail the accepted arm. The nonfinite family carries quiet NaN, signalling NaN, and
// both infinities as separate members, because a check written against one spelling of NaN
// does not cover the other, and the two infinities differ only in sign.
//
// Nonfinite and nonnumeric stay separate throughout: Requirements 4.15 and 4.16 distinguish
// missing, misnamed, nonscalar, nonnumeric, and nonfinite, each is generated on its own, and
// each names its own cause.
//
// ## What this file does not assert
//
//   * That a session keeps its bound bundle snapshot across a later activation, or that a
//     report states the bound versions. That is Property 13's statement.
//   * Which of the three labels a finite logit maps to, or any abstention rule. That is
//     Property 16's.
//   * Whether a manifest's artifact inventory is complete and mutation-sensitive, or whether
//     activation and rollback are atomic. Those are Properties 26 and 27.
//   * Cancellation. It is a separate terminal outcome and never an Analysis Error, so it is
//     outside the mapping this property states.
//
// Nothing here is release evidence. No signature is verified, no compiled model is loaded,
// no parity or tolerance is measured, and no compute-unit placement is observed or claimed.
// The bundle, receipt, and digests come from `InferenceFixtures.swift`, which says the same
// of itself. Real fixtures and a real compiled model belong to task 6.11, and device
// behavior belongs to the physical-device suite.
//
// ## Why no arm throws
//
// `propertyCheck` runs its body under `try?`, so an error escaping the body reports a
// passing run in milliseconds with every arm skipped. Nothing below rethrows: every throwing
// call is reduced to a value or reported through `Issue.record`, and
// ``ModelOutputMappingWitness`` counts the cases and every arm *outside* the body, where an
// issue is not suppressed. The arm counters are compared against the case count rather than
// against a floor, and the last thing the body does is record that it reached the end, so a
// case that stopped early is countable.

extension Tag {
    /// Design Property 14.
    ///
    /// Declared here rather than in a shared tag namespace: each design property gets one
    /// dedicated file, and a shared namespace would be a merge point between property files
    /// written independently of each other.
    @Tag static var property14ModelOutputFailureMapping: Self
}

@Suite(
    "Property 14: Model output and failure mapping are exact",
    .tags(.property14ModelOutputFailureMapping)
)
struct ModelOutputFailureMappingPropertyTests {
    /// Runs at the library default of 100 generated cases, which is the minimum the design
    /// requires; `PropertyToolchainWiringTests` pins that default. Every member of every
    /// family runs on every case, so each coverage assertion is a multiple of the case count
    /// and no arm depends on a lucky draw. Every generator is composed with `zip`, so the
    /// shrinkers compose.
    ///
    /// **Validates: Requirements 4.9, 4.14, 4.15, 4.16**
    @Test("Every load, execution, and output outcome maps to exactly one required result")
    func modelOutputAndFailureMappingIsExact() async {
        let witness = ModelOutputMappingWitness()

        await propertyCheck(input: ModelOutcomeShape.generator) { shape in
            witness.record(shape)

            let scenario = ModelOutputScenario.checkedConstants(shape, witness: witness)
            // Both orders are generated because the arms share nothing but the fixtures: a
            // refusal that only holds once a successful prediction has run, or a control that
            // only produces a label when nothing has failed first, shows up here.
            if shape.controlRunsFirst {
                await scenario.checkSuccessYieldsOneFiniteLogitAndOneLabel()
                await scenario.checkEveryLoadFailureIsModelLoadError()
                await scenario.checkExecutionFailureIsInferenceError()
                await scenario.checkEveryOutputDefectIsInvalidOutputError()
            } else {
                await scenario.checkEveryLoadFailureIsModelLoadError()
                await scenario.checkExecutionFailureIsInferenceError()
                await scenario.checkEveryOutputDefectIsInvalidOutputError()
                await scenario.checkSuccessYieldsOneFiniteLogitAndOneLabel()
            }

            witness.recordCompletedBody()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - The reference model

/// The four requirement leaves, written from the requirement text rather than from the code
/// under test.
///
/// Small on purpose. Its value is that it restates Requirement 4.9's feature name and
/// Requirements 4.14 through 4.16's category strings literally, so the comparison is against
/// the requirement rather than against a second reading of the implementation. If a
/// production constant ever drifts, the constant half fails here instead of every refusal
/// below quietly measuring the drifted value.
private enum ReferenceModelOutputMapping {
    /// Requirement 4.9: the emitted raw logit is named `logit`.
    static let requiredFeatureName = "logit"

    /// Requirement 4.14.
    static let loadFailureCategory = "model-load-error"

    /// Requirement 4.15.
    static let executionFailureCategory = "inference-error"

    /// Requirement 4.16.
    static let invalidOutputCategory = "invalid-output-error"

    /// The one result a step outcome requires.
    enum Required: Hashable {
        /// Requirement 4.9: one finite raw logit and nothing else.
        case oneFiniteLogit

        /// Exactly one Analysis Error category, by its requirement string.
        case category(String)
    }

    /// The required result for one load, prediction, and output triple.
    ///
    /// A total function in the causal order the requirements imply: a load failure is decided
    /// before anything is executed, an execution failure before there is an output to inspect,
    /// and the output feature set only once a prediction has returned one. Written as
    /// exhaustive `switch`es so a step outcome added later cannot fall through unclassified.
    static func required(
        load: LoadStepOutcome,
        prediction: PredictionStepOutcome,
        output: OutputFeatureSetShape
    ) -> Required {
        switch load {
        case .loadFails:
            return .category(loadFailureCategory)
        case .loadSucceeds:
            break
        }
        switch prediction {
        case .executionFails:
            return .category(executionFailureCategory)
        case .returnsFeatureSet:
            break
        }
        switch output {
        case .oneFiniteScalarNamedLogit:
            return .oneFiniteLogit
        case .missing, .misnamed, .nonScalar, .nonNumeric, .nonFinite, .extraFeature:
            return .category(invalidOutputCategory)
        }
    }
}

/// Whether the bound model could be loaded and reached (Requirement 4.14).
private enum LoadStepOutcome: Hashable {
    case loadSucceeds
    case loadFails
}

/// Whether one prediction returned a feature set (Requirement 4.15).
private enum PredictionStepOutcome: Hashable {
    case returnsFeatureSet
    case executionFails
}

/// What one returned feature set carries, as the requirements enumerate it.
///
/// One member per named cause, so a finding names one cause rather than an unexplained
/// rejection. Requirement 4.16 gives every defective member the same single Analysis Error:
/// "each defect maps to its own exact required error" means each has its own named cause and
/// all of them have the one required category, not that there are six categories.
private enum OutputFeatureSetShape: Hashable, CaseIterable {
    /// The accepted shape: exactly one member, named `logit`, holding one finite number.
    case oneFiniteScalarNamedLogit

    /// Nothing at all.
    case missing

    /// The number, under a name that is not `logit`.
    case misnamed

    /// The required name, holding a value that is not one element.
    case nonScalar

    /// The required name, holding a value that is not a number.
    case nonNumeric

    /// The required name, holding NaN or an infinity.
    case nonFinite

    /// The accepted member, plus a second one the verified description never declared.
    ///
    /// The set-level counterpart of ``misnamed``: a result carrying more than the verified
    /// description promised is not the output that was validated, so picking the required
    /// member out of several would mean measuring a model other than the released one.
    case extraFeature

    /// Every defective shape, in declaration order.
    static let defects: [OutputFeatureSetShape] =
        allCases.filter { $0 != .oneFiniteScalarNamedLogit }

    /// A canonical token for failure messages and the witness's produced sets.
    var token: String {
        switch self {
        case .oneFiniteScalarNamedLogit: "one-finite-scalar"
        case .missing: "missing"
        case .misnamed: "misnamed"
        case .nonScalar: "nonscalar"
        case .nonNumeric: "nonnumeric"
        case .nonFinite: "nonfinite"
        case .extraFeature: "extra-feature"
        }
    }
}

/// Why the bound model could not be loaded or reached.
///
/// One member per way the load step can fail while every other input stays valid, so each
/// arm mutates exactly one aspect. The framework members are exhaustive over
/// ``ModelRuntimeLoadFault``'s non-cancellation cases, and ``frameworkFault`` is a `switch`,
/// so a fault added there later cannot go ungenerated.
private enum LoadDefect: Hashable, CaseIterable {
    /// This build has no compiled model for the verified bundle.
    case compiledModelUnavailable

    /// The framework refused the compiled model or the load configuration.
    case frameworkRefusedLoad

    /// The load succeeded at the framework, but the generated model description disagrees
    /// with the bound output contract.
    case outputDescriptionDisagrees

    /// The model loaded, but the bound token names no loaded model.
    ///
    /// A different model is loaded in the same store under a different token, so an adapter
    /// that reached for "the model that is loaded" instead of the one the session bound would
    /// satisfy this arm's category assertion and fail its call-count assertion.
    case boundTokenNamesNoLoadedModel

    var token: String {
        switch self {
        case .compiledModelUnavailable: "compiled-model-unavailable"
        case .frameworkRefusedLoad: "framework-refused-load"
        case .outputDescriptionDisagrees: "output-description-disagrees"
        case .boundTokenNamesNoLoadedModel: "bound-token-names-no-loaded-model"
        }
    }

    /// The framework fault this defect injects, if it injects one.
    var frameworkFault: ModelRuntimeLoadFault? {
        switch self {
        case .compiledModelUnavailable: .compiledModelUnavailable
        case .frameworkRefusedLoad: .frameworkRefusedLoad
        case .outputDescriptionDisagrees, .boundTokenNamesNoLoadedModel: nil
        }
    }

    /// How many models remain loaded after this defect has been refused.
    ///
    /// Zero for a refused load, because nothing may be left behind for a later inference to
    /// find. One for the unbound-token arm, whose unrelated model was loaded before the arm
    /// began and must be left exactly as it was found.
    var expectedLoadedModelCount: Int {
        self == .boundTokenNamesNoLoadedModel ? 1 : 0
    }
}

/// Which member of the generated model description's output declaration is wrong.
///
/// Output-side on purpose: `PixelModelLoadingTests` pins the input-side and whole-description
/// refusals at examples, and Property 14's subject is the output. Each member changes one
/// declared fact and leaves the rest of the description matching the bound contracts.
private enum OutputDescriptionDefect: Hashable, CaseIterable {
    /// The sole output feature is declared under a name that is not `logit`.
    case declaredName

    /// The output is declared as a tensor holding a number of elements that is not one.
    case declaredElementCount

    /// The output is declared as one number of a type that is not floating point.
    case declaredElementType

    /// The output is declared as something the bound contracts cannot describe.
    case declaredKind

    var token: String {
        switch self {
        case .declaredName: "declared-name"
        case .declaredElementCount: "declared-element-count"
        case .declaredElementType: "declared-element-type"
        case .declaredKind: "declared-kind"
        }
    }
}

// MARK: - Generated shape

/// One generated triple of load outcome, prediction outcome, and output feature set.
///
/// Every field is a bounded integer or a flag, and each mutant value is read off the shape by
/// modulus, so a family is exercised across all of its members over 100 cases instead of
/// collapsing onto one.
private struct ModelOutcomeShape: Sendable, CustomStringConvertible {
    /// Drives the one varying finite value, so a case's values move together and a failing
    /// case names one seed.
    let seed: Int

    let finiteValueIndex: Int
    let misnamedIndex: Int
    let elementCountIndex: Int
    let extraNameIndex: Int
    let loadDefectIndex: Int
    let descriptionDefectIndex: Int
    let nonFiniteIndex: Int
    let labelIndex: Int

    /// Whether the positive control runs before the refusals.
    let controlRunsFirst: Bool

    // MARK: The accepted value

    /// The finite values a model may legitimately emit.
    ///
    /// Eight entries, seven of them exact edge values and one varying with the seed. Both
    /// zeros are present because `-0.0 == 0.0` while their signs differ; both signed
    /// subnormals because a subnormal is finite and a check written against `isNormal` would
    /// wrongly refuse one; both signed greatest-finite magnitudes because they are the
    /// largest values a rescale could overflow; and one value that is finite as a `Double`
    /// and infinite as a `Float`, so a narrowing conversion anywhere on the path would turn
    /// the accepted arm into a nonfinite refusal.
    var finiteLogitTable: [Double] {
        [
            0.0,
            -0.0,
            .leastNonzeroMagnitude,
            -.leastNonzeroMagnitude,
            .greatestFiniteMagnitude,
            -.greatestFiniteMagnitude,
            Self.finiteInDoubleInfiniteInFloat,
            Double(seed) / 128.0 - 39.0625,
        ]
    }

    /// One finite `Double` the model may legitimately emit.
    var finiteLogitValue: Double { finiteLogitTable[finiteValueIndex % finiteLogitTable.count] }

    /// Finite as a `Double`, infinite as a `Float`.
    static let finiteInDoubleInfiniteInFloat = Double(Float.greatestFiniteMagnitude) * 2.0

    /// The number of entries in the finite family, for the witness's coverage assertion.
    static let finiteValueCount = 8

    // MARK: The mutant output feature sets

    /// A feature name that is not `logit`.
    ///
    /// Near misses on purpose: a plural, a letter case, a trailing and a leading space, an
    /// index suffix, and a generated-graph name. A check that compared names loosely,
    /// trimmed whitespace, or lowercased would accept one of these, and an unrelated name
    /// alone would not catch it.
    var misnamedFeatureName: String {
        let table = ["logits", "Logit", "logit ", " logit", "logit_0", "var_318"]
        return table[misnamedIndex % table.count]
    }

    /// An element count that is not one.
    ///
    /// Below, just above, the channel count, the crop edge, and one whole 384-by-384 RGB
    /// plane: a check that accepted "at least one element" would pass on four of these.
    var nonScalarElementCount: Int {
        let table = [0, 2, 3, 384, 384 * 384 * 3]
        return table[elementCountIndex % table.count]
    }

    /// A second feature name the verified description never declared.
    var extraFeatureName: String {
        let table = ["probability", "score", "confidence", "var_1"]
        return table[extraNameIndex % table.count]
    }

    /// A `Double` that is not finite.
    var nonFiniteLogitValue: Double {
        let table: [Double] = [.nan, .signalingNaN, .infinity, -.infinity]
        return table[nonFiniteIndex % table.count]
    }

    /// A canonical token naming which nonfinite value this case generated.
    ///
    /// Read through `isNaN`, `isSignalingNaN`, and `sign` rather than through equality,
    /// because `NaN != NaN` would make a lookup by comparison fall through.
    var nonFiniteToken: String {
        let value = nonFiniteLogitValue
        if value.isNaN {
            return value.isSignalingNaN ? "signalling-nan" : "quiet-nan"
        }
        return value.sign == .minus ? "negative-infinity" : "positive-infinity"
    }

    /// Every nonfinite spelling the family generates.
    static let nonFiniteTokens: Set<String> = [
        "quiet-nan", "signalling-nan", "positive-infinity", "negative-infinity",
    ]

    // MARK: The mutant load outcomes

    var loadDefect: LoadDefect {
        LoadDefect.allCases[loadDefectIndex % LoadDefect.allCases.count]
    }

    var outputDescriptionDefect: OutputDescriptionDefect {
        OutputDescriptionDefect.allCases[
            descriptionDefectIndex % OutputDescriptionDefect.allCases.count
        ]
    }

    /// An element type that is not floating point.
    ///
    /// `other` is included because a numeric type a later SDK adds must not be accepted as a
    /// logit by default.
    var nonFloatingElementType: RuntimeElementType {
        let table: [RuntimeElementType] = [.int32, .int64, .other]
        return table[descriptionDefectIndex % table.count]
    }

    // MARK: The programmed control label

    /// The label the spy is programmed to produce.
    ///
    /// Drawn from the generated case rather than fixed, so a recorded label is unmistakably
    /// the value the test supplied and not a calibration decision this file made.
    var programmedLabel: PixelEvidence {
        PixelEvidence.allCases[labelIndex % PixelEvidence.allCases.count]
    }

    // MARK: Description

    var description: String {
        """
        seed \(seed), finite bits \(finiteLogitValue.bitPattern) \
        (sign \(finiteLogitValue.sign == .minus ? "-" : "+")), \
        misnamed "\(misnamedFeatureName)", element count \(nonScalarElementCount), \
        extra "\(extraFeatureName)", load defect \(loadDefect.token), \
        description defect \(outputDescriptionDefect.token), \
        nonfloating \(nonFloatingElementType), nonfinite \(nonFiniteToken), \
        label \(programmedLabel.rawValue), control first \(controlRunsFirst)
        """
    }

    // MARK: Generator

    static var generator: Generator<ModelOutcomeShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            index,
            index,
            index,
            index,
            index,
            index,
            index,
            index,
            Gen.bool
        )
        .map { raw in
            ModelOutcomeShape(
                seed: raw.0,
                finiteValueIndex: raw.1,
                misnamedIndex: raw.2,
                elementCountIndex: raw.3,
                extraNameIndex: raw.4,
                loadDefectIndex: raw.5,
                descriptionDefectIndex: raw.6,
                nonFiniteIndex: raw.7,
                labelIndex: raw.8,
                controlRunsFirst: raw.9
            )
        }
        .eraseToAny()
    }

    /// A selector index.
    ///
    /// The range is a multiple of every modulus it is reduced by (3, 4, 5, 6, 8), so each
    /// table entry is drawn with equal probability rather than with a modulus bias.
    private static var index: Generator<Int, AnySequence<Any>> {
        Gen.int(in: 0...959).eraseToAny()
    }
}

// MARK: - The positive control

/// One label a label-producing step produced, and the number it was produced from.
private struct ProducedLabel: Hashable {
    let label: PixelEvidence

    /// The bit pattern of the logit the step was handed, so an arm can show the step received
    /// the number the model emitted rather than merely some number.
    let logitBitPattern: UInt64
}

/// Records every Pixel Evidence label a label-producing step was asked to produce.
///
/// An actor because the analyzer and the step are reached from an asynchronous scenario and
/// the recording has to be readable after the arm finishes.
private actor PixelEvidenceSink {
    private(set) var produced: [ProducedLabel] = []

    func record(_ entry: ProducedLabel) {
        produced.append(entry)
    }
}

/// The one step in the pixel lane that can produce a label, narrowed to its input.
///
/// A spy, not calibration. It takes a `RawLogit` and nothing else, mirroring the shape of
/// `PixelCalibrating`, whose real signature additionally requires a validated Calibration
/// Policy. It returns the label the generated case programmed it with, so a recorded label
/// proves that a label-producing step was reached with a finite logit and nothing more.
/// Which of the three labels a finite logit deserves is the validated Calibration Policy's
/// decision and Property 16's subject; this file makes no such decision and encodes no
/// budget, boundary, or half-width.
///
/// `RawLogit` cannot hold NaN or an infinity, so there is no argument through which a
/// nonfinite output could reach this step.
private struct LabelProducingStep {
    let sink: PixelEvidenceSink
    let programmedLabel: PixelEvidence

    func produce(from logit: RawLogit) async {
        await sink.record(
            ProducedLabel(label: programmedLabel, logitBitPattern: logit.value.bitPattern)
        )
    }
}

// MARK: - One generated case

/// One generated triple, run against the real loader and the real analyzer.
///
/// The adapters are the production ones. The seams `InferenceFixtures.swift` provides stand
/// in for the framework, so each arm changes exactly one of: the load outcome, the prediction
/// outcome, or the returned feature set. Everything else — the verified bundle, the bound
/// contracts, the prepared buffer, and the label-producing step — is held at its accepted
/// value, so a refusal names one cause.
private struct ModelOutputScenario {
    let shape: ModelOutcomeShape
    let witness: ModelOutputMappingWitness

    /// The accepted feature set: exactly one member, named `logit`, holding the generated
    /// finite value.
    private var acceptedResult: RuntimeFeatureResult {
        ResultFixture.logit(shape.finiteLogitValue)
    }

    // MARK: - The constant half

    /// Builds the scenario after confirming the pinned constants and the generated mutants.
    ///
    /// The constant check runs first because every later refusal is measured against these
    /// values: if a production constant ever drifts from the requirement text, this fails
    /// here rather than letting the rest of the file quietly certify the drifted value
    /// (Requirements 4.9, 4.14, 4.15, 4.16).
    static func checkedConstants(
        _ shape: ModelOutcomeShape,
        witness: ModelOutputMappingWitness
    ) -> ModelOutputScenario {
        #expect(
            ModelOutputContract.requiredFeatureName
                == ReferenceModelOutputMapping.requiredFeatureName,
            "the pinned output feature name is not the one Requirement 4.9 names"
        )
        #expect(
            ContractFixture.output().featureName.value
                == ReferenceModelOutputMapping.requiredFeatureName
        )
        // Requirement 4.9's positive-going direction: larger means more evidence. The
        // contract carries the direction, and the accepted arm asserts the emitted number is
        // returned untransformed, which is how the direction is preserved.
        #expect(ContractFixture.output().isPositiveGoing)
        #expect(
            AnalysisError.modelLoadError.rawValue
                == ReferenceModelOutputMapping.loadFailureCategory
        )
        #expect(
            AnalysisError.inferenceError.rawValue
                == ReferenceModelOutputMapping.executionFailureCategory
        )
        #expect(
            AnalysisError.invalidOutputError.rawValue
                == ReferenceModelOutputMapping.invalidOutputCategory
        )
        // Three distinct categories, so an arm expecting one of them cannot be satisfied by
        // another.
        #expect(
            Set([
                ReferenceModelOutputMapping.loadFailureCategory,
                ReferenceModelOutputMapping.executionFailureCategory,
                ReferenceModelOutputMapping.invalidOutputCategory,
            ]).count == 3
        )

        // Every generated mutant really is outside the accepted set. Without this, a
        // generator that happened to produce an accepted value would make a refusal arm
        // assert the opposite of what it reads.
        #expect(
            shape.misnamedFeatureName != ReferenceModelOutputMapping.requiredFeatureName,
            "the generated misnamed feature must not be the required name"
        )
        #expect(
            shape.extraFeatureName != ReferenceModelOutputMapping.requiredFeatureName,
            "the generated extra feature must not be the required name"
        )
        #expect(
            shape.nonScalarElementCount != 1,
            "the generated nonscalar element count must not be one element"
        )
        #expect(
            !shape.nonFloatingElementType.isFloatingPoint,
            "the generated element type must not be a floating-point one"
        )
        // Asserted with the predicates rather than with `==`, because `NaN != NaN` makes an
        // equality comparison over a nonfinite value meaningless.
        let nonFinite = shape.nonFiniteLogitValue
        #expect(!nonFinite.isFinite, "the generated nonfinite value must not be finite")
        #expect(
            nonFinite.isNaN || nonFinite.isInfinite,
            "a nonfinite Double is NaN or an infinity"
        )
        let accepted = shape.finiteLogitValue
        #expect(accepted.isFinite, "the generated accepted value must be finite")
        #expect(!accepted.isNaN)
        #expect(!accepted.isInfinite)
        // The whole accepted family is finite, not only the member this case drew, and the
        // subnormal members really are subnormal rather than zero.
        for value in shape.finiteLogitTable {
            #expect(value.isFinite, "every accepted family member must be finite")
        }
        #expect(Double.leastNonzeroMagnitude.isSubnormal)
        #expect(Double.leastNonzeroMagnitude.isFinite)
        // The member chosen to overflow a narrower type really does, so the arm that would
        // catch a narrowing conversion is not asserting a vacuous fact.
        #expect(ModelOutcomeShape.finiteInDoubleInfiniteInFloat.isFinite)
        #expect(!Float(ModelOutcomeShape.finiteInDoubleInfiniteInFloat).isFinite)

        witness.recordConstantCheck()
        return ModelOutputScenario(shape: shape, witness: witness)
    }

    // MARK: - The load half

    /// Every load outcome that is not a success produces exactly `model-load-error`, nothing
    /// is executed, and no label is produced (Requirement 4.14).
    ///
    /// All four defects run on every case, so the family is covered by construction rather
    /// than by a lucky draw; the generated selectors decide what each defect's mutant value
    /// is.
    func checkEveryLoadFailureIsModelLoadError() async {
        for defect in LoadDefect.allCases {
            await checkLoadFailure(defect)
        }
        witness.recordLoadHalf()
    }

    private func checkLoadFailure(_ defect: LoadDefect) async {
        let expected = ReferenceModelOutputMapping.required(
            load: .loadFails,
            prediction: .returnsFeatureSet,
            output: .oneFiniteScalarNamedLogit
        )
        let sink = PixelEvidenceSink()
        let predictions = CallCounter()

        // Held at its accepted value everywhere the defect is not: the feature set the
        // runtime would return is the good one, so a `model-load-error` here cannot have come
        // from the output.
        let runtime = StubPixelModelRuntime(
            schema: schema(for: defect),
            outcome: .success(acceptedResult),
            calls: predictions
        )
        let store = LoadedPixelModelStore()

        let fault: AnalysisFault?
        switch defect {
        case .boundTokenNamesNoLoadedModel:
            // A different model is loaded in the same store, under a token the session did not
            // bind. Reaching for "the loaded model" instead of the bound one would execute
            // this runtime and fail the call count below.
            let issued = await store.register(runtime)
            let unbound = LoadedModelToken(rawValue: issued.rawValue &+ 1)
            #expect(
                await store.runtime(for: unbound) == nil,
                "the unbound token must name no loaded model"
            )
            fault = await attemptInference(
                model: ModelFixture.bound(token: unbound.rawValue),
                store: store,
                sink: sink
            ).fault

        case .compiledModelUnavailable, .frameworkRefusedLoad, .outputDescriptionDisagrees:
            let loaderOutcome: Result<StubPixelModelRuntime, ModelRuntimeLoadFault> =
                if let injected = defect.frameworkFault {
                    .failure(injected)
                } else {
                    .success(runtime)
                }
            let loader = CoreMLPixelModelLoader(
                runtimeLoader: StubRuntimeLoader(outcome: loaderOutcome),
                loadedModels: store
            )
            do {
                let model = try await loader.loadModel(from: BundleFixture.boundBundle())
                Issue.record("\(defect.token) must not produce a bound model: \(model.model)")
                fault = nil
            } catch {
                // Already an ``AnalysisFault``: the port's typed `throws` is what makes this
                // total, so there is no untyped branch to classify.
                fault = error
            }
        }

        guard let fault else { return }
        let attempted = await predictions.count
        let produced = await sink.produced
        let loadedAfterward = await store.loadedModelCount

        // Exactly one result: the whole fault, category and stage together.
        #expect(
            fault == .analysis(.modelLoadError, stage: .modelLoad),
            "\(defect.token) produced \(fault)"
        )
        // The same category, sourced from the requirement text rather than from the enum.
        #expect(
            fault.analysisError.map(\.rawValue).map(ReferenceModelOutputMapping.Required.category)
                == expected,
            "\(defect.token) did not produce the category Requirement 4.14 names"
        )
        #expect(!fault.isCancelled, "a load failure is not cancellation")

        // Nothing was executed: a load that produced no bound model cannot have run a
        // prediction, and a bound token that names no loaded model must not fall back to one.
        #expect(attempted == 0, "\(defect.token) attempted \(attempted) prediction(s)")
        #expect(
            loadedAfterward == defect.expectedLoadedModelCount,
            "\(defect.token) left \(loadedAfterward) loaded model(s)"
        )
        // No Pixel Evidence. Measured, not assumed: the accepted arm records one label
        // through this same step on every case.
        #expect(produced.isEmpty, "\(defect.token) produced \(produced)")
        witness.recordLoadRefusal(defect)
    }

    /// The generated model description for one load defect: matching the bound contracts,
    /// except for the one output member ``OutputDescriptionDefect`` names.
    private func schema(for defect: LoadDefect) -> RuntimeModelSchema {
        guard defect == .outputDescriptionDisagrees else { return SchemaFixture.matching() }
        switch shape.outputDescriptionDefect {
        case .declaredName:
            return SchemaFixture.matching(outputName: shape.misnamedFeatureName)
        case .declaredElementCount:
            return SchemaFixture.matching(
                outputKind: .tensor(elementCount: shape.nonScalarElementCount, element: .float32)
            )
        case .declaredElementType:
            return SchemaFixture.matching(outputKind: .scalar(shape.nonFloatingElementType))
        case .declaredKind:
            return SchemaFixture.matching(outputKind: .unsupported)
        }
    }

    // MARK: - The execution half

    /// A prediction that fails after a valid input produces exactly `inference-error`, the
    /// prediction really was attempted, and no label is produced (Requirement 4.15).
    func checkExecutionFailureIsInferenceError() async {
        let expected = ReferenceModelOutputMapping.required(
            load: .loadSucceeds,
            prediction: .executionFails,
            output: .oneFiniteScalarNamedLogit
        )
        let sink = PixelEvidenceSink()
        let predictions = CallCounter()
        let runtime = StubPixelModelRuntime(
            outcome: .failure(.executionFailed),
            calls: predictions
        )

        guard
            let outcome = await runPipeline(
                runtime: runtime,
                predictions: predictions,
                sink: sink
            )
        else { return }
        guard let fault = outcome.attempt.fault else {
            Issue.record("a failed execution must not return a logit")
            return
        }

        #expect(
            fault == .analysis(.inferenceError, stage: .inference),
            "a failed execution produced \(fault)"
        )
        #expect(
            fault.analysisError.map(\.rawValue).map(ReferenceModelOutputMapping.Required.category)
                == expected,
            "a failed execution did not produce the category Requirement 4.15 names"
        )
        #expect(!fault.isCancelled, "an execution failure is not cancellation")
        // Not `model-load-error`: the model loaded and the input was valid, so this failure is
        // scoped to the prediction. The call count is what shows it was attempted rather than
        // refused beforehand.
        #expect(
            outcome.predictionCount == 1,
            "the prediction was attempted \(outcome.predictionCount) time(s)"
        )
        #expect(outcome.loadedModelCount == 1, "the loaded model must stay loaded")
        #expect(outcome.produced.isEmpty, "a failed execution produced \(outcome.produced)")
        witness.recordExecutionRefusal()
    }

    // MARK: - The output half

    /// Every defective feature set produces exactly `invalid-output-error` at output
    /// validation, names its one cause, and produces no label (Requirements 4.9 and 4.16).
    ///
    /// Every defect runs on every case. Each mutates exactly one aspect of the accepted set,
    /// so the pure check's finding names one cause and the arm attributes the refusal to that
    /// cause rather than to the act of building a different result.
    func checkEveryOutputDefectIsInvalidOutputError() async {
        for defect in OutputFeatureSetShape.defects {
            await checkOutputDefect(defect)
        }
        witness.recordOutputHalf()
    }

    private func checkOutputDefect(_ defect: OutputFeatureSetShape) async {
        let expected = ReferenceModelOutputMapping.required(
            load: .loadSucceeds,
            prediction: .returnsFeatureSet,
            output: defect
        )
        let result = featureSet(for: defect)

        // The pure check first: one named cause per defect, so a refusal is attributable.
        // `ModelOutputCheck` is total, so this is the exact finding rather than one of several
        // the adapter might have produced.
        do {
            let logit = try ModelOutputCheck.logit(in: result, contract: ContractFixture.output())
            Issue.record("\(defect.token) must not yield a logit: \(logit.value.bitPattern)")
            return
        } catch {
            #expect(
                error == expectedFinding(for: defect),
                "\(defect.token) named \(error) rather than its own cause"
            )
        }

        let sink = PixelEvidenceSink()
        let predictions = CallCounter()
        let runtime = StubPixelModelRuntime(outcome: .success(result), calls: predictions)

        guard
            let outcome = await runPipeline(
                runtime: runtime,
                predictions: predictions,
                sink: sink
            )
        else { return }
        guard let fault = outcome.attempt.fault else {
            Issue.record("\(defect.token) must not yield a logit through the analyzer")
            return
        }

        #expect(
            fault == .analysis(.invalidOutputError, stage: .outputValidation),
            "\(defect.token) produced \(fault)"
        )
        #expect(
            fault.analysisError.map(\.rawValue).map(ReferenceModelOutputMapping.Required.category)
                == expected,
            "\(defect.token) did not produce the category Requirement 4.16 names"
        )
        #expect(!fault.isCancelled, "an unusable output is not cancellation")
        // The prediction really ran and really returned this set, so the refusal came from
        // inspecting the output rather than from never having one.
        #expect(
            outcome.predictionCount == 1,
            "\(defect.token) attempted \(outcome.predictionCount) prediction(s)"
        )
        #expect(outcome.loadedModelCount == 1, "the loaded model must stay loaded")
        // Requirement 4.16: never mapped to a pixel label.
        #expect(outcome.produced.isEmpty, "\(defect.token) produced \(outcome.produced)")
        witness.recordOutputRefusal(defect, nonFiniteToken: shape.nonFiniteToken)
    }

    /// The accepted feature set with exactly one aspect mutated.
    private func featureSet(for defect: OutputFeatureSetShape) -> RuntimeFeatureResult {
        let required = ReferenceModelOutputMapping.requiredFeatureName
        switch defect {
        case .oneFiniteScalarNamedLogit:
            return acceptedResult
        case .missing:
            return RuntimeFeatureResult([:])
        case .misnamed:
            return RuntimeFeatureResult([
                shape.misnamedFeatureName: .scalar(shape.finiteLogitValue)
            ])
        case .nonScalar:
            return RuntimeFeatureResult([
                required: .nonScalar(elementCount: shape.nonScalarElementCount)
            ])
        case .nonNumeric:
            return RuntimeFeatureResult([required: .nonNumeric])
        case .nonFinite:
            return RuntimeFeatureResult([required: .scalar(shape.nonFiniteLogitValue)])
        case .extraFeature:
            return RuntimeFeatureResult([
                required: .scalar(shape.finiteLogitValue),
                shape.extraFeatureName: .scalar(shape.finiteLogitValue),
            ])
        }
    }

    /// The one finding each defect must produce, written from the requirement's own vocabulary
    /// of causes: missing, misnamed, nonscalar, nonnumeric, and nonfinite.
    ///
    /// Missing and misnamed share one finding by construction, because a result carrying the
    /// number under another name does not carry the required feature at all. `nil` is
    /// unreachable: every caller draws from ``OutputFeatureSetShape/defects``, and comparing
    /// against an optional keeps the accepted member from needing an invented finding.
    private func expectedFinding(for defect: OutputFeatureSetShape) -> ModelOutputDisagreement? {
        let required = ReferenceModelOutputMapping.requiredFeatureName
        switch defect {
        case .oneFiniteScalarNamedLogit:
            return nil
        case .missing, .misnamed:
            return .missingRequiredFeature(name: required)
        case .nonScalar:
            return .nonScalar(name: required, elementCount: shape.nonScalarElementCount)
        case .nonNumeric:
            return .nonNumeric(name: required)
        case .nonFinite:
            return .nonFinite(name: required)
        case .extraFeature:
            return .unexpectedFeatures(names: [shape.extraFeatureName])
        }
    }

    // MARK: - The accepted arm, which is also the positive control

    /// Exactly one finite scalar named `logit` yields that number unchanged and exactly one
    /// label, and nothing else (Requirement 4.9).
    ///
    /// This is the positive control every "no Pixel Evidence" assertion above leans on: the
    /// same fixtures, the same store, the same analyzer, and the same label-producing step,
    /// with only the prediction outcome changed. If this arm ever stops producing a label, the
    /// witness's `evidenceProductions == cases` assertion fails and every absence assertion
    /// above is reported as unbacked rather than passing vacuously.
    func checkSuccessYieldsOneFiniteLogitAndOneLabel() async {
        let expected = ReferenceModelOutputMapping.required(
            load: .loadSucceeds,
            prediction: .returnsFeatureSet,
            output: .oneFiniteScalarNamedLogit
        )
        #expect(expected == .oneFiniteLogit)

        let emitted = shape.finiteLogitValue
        let result = acceptedResult

        // Exactly one member, and it is the required one. "One finite positive-going raw
        // logit" is a claim about the whole set, not only about the member that was read.
        #expect(result.features.count == 1, "the accepted set carries \(result.features.count)")
        #expect(
            result.features.keys.sorted() == [ReferenceModelOutputMapping.requiredFeatureName]
        )

        let sink = PixelEvidenceSink()
        let predictions = CallCounter()
        let runtime = StubPixelModelRuntime(outcome: .success(result), calls: predictions)

        guard
            let outcome = await runPipeline(
                runtime: runtime,
                predictions: predictions,
                sink: sink
            )
        else { return }
        if let fault = outcome.attempt.fault {
            Issue.record("one finite scalar named logit must not be refused: \(fault)")
            return
        }
        guard let logit = outcome.attempt.logit else {
            Issue.record("a successful prediction must return one logit")
            return
        }

        // Finiteness by predicate, not by comparison.
        #expect(logit.value.isFinite, "the returned logit must be finite")
        #expect(!logit.value.isNaN)
        #expect(!logit.value.isInfinite)
        // Sign explicitly, so `-0.0` is not accepted as `+0.0`.
        #expect(logit.value.sign == emitted.sign, "the sign was not preserved")
        // The number the model emitted, unchanged. `bitPattern` admits no rescale, clamp,
        // round, sign flip, or narrowing round trip, and it separates the two zeros that `==`
        // cannot. A transform here would silently redefine the positive-going direction the
        // contract fixes and invalidate every parity measurement.
        #expect(
            logit.value.bitPattern == emitted.bitPattern,
            "the returned logit is not the number the model emitted"
        )
        #expect(
            outcome.predictionCount == 1,
            "the prediction was attempted \(outcome.predictionCount) time(s)"
        )
        #expect(outcome.loadedModelCount == 1, "the loaded model must stay loaded")
        // The positive control's own claim: exactly one label, produced from exactly the
        // number the model emitted. One, not at least one: a second label would mean two lane
        // results for one prediction.
        #expect(
            outcome.produced == [
                ProducedLabel(
                    label: shape.programmedLabel,
                    logitBitPattern: emitted.bitPattern
                )
            ],
            "the accepted output produced \(outcome.produced)"
        )
        witness.recordEvidenceProduction(emitted)
    }

    // MARK: - Running one arm

    /// One inference attempt, reduced to a value so nothing rethrows out of the property body.
    private struct InferenceAttempt {
        let logit: RawLogit?
        let fault: AnalysisFault?
    }

    /// Everything one arm's run produced.
    private struct PipelineOutcome {
        let attempt: InferenceAttempt
        let predictionCount: Int
        let produced: [ProducedLabel]
        let loadedModelCount: Int
    }

    /// Loads `runtime` through the real loader, runs one inference through the real analyzer,
    /// and passes any returned logit to the label-producing step.
    ///
    /// `nil` only when the load itself failed, which none of the arms calling this expect; the
    /// issue is recorded here so the caller does not have to rethrow.
    private func runPipeline(
        runtime: StubPixelModelRuntime,
        predictions: CallCounter,
        sink: PixelEvidenceSink
    ) async -> PipelineOutcome? {
        let store = LoadedPixelModelStore()
        let loader = CoreMLPixelModelLoader(
            runtimeLoader: StubRuntimeLoader(outcome: .success(runtime)),
            loadedModels: store
        )
        let model: BoundCoreMLModel
        do {
            model = try await loader.loadModel(from: BundleFixture.boundBundle())
        } catch {
            Issue.record("a description matching the bound contracts must load: \(error)")
            return nil
        }
        let attempt = await attemptInference(model: model, store: store, sink: sink)
        return PipelineOutcome(
            attempt: attempt,
            predictionCount: await predictions.count,
            produced: await sink.produced,
            loadedModelCount: await store.loadedModelCount
        )
    }

    /// Runs one inference and, on success, the label-producing step.
    ///
    /// The typed `throws(AnalysisFault)` on the port is what makes the `catch` total: an
    /// adapter cannot leak a framework error or an invented category through it, so there is
    /// no untyped branch to classify here.
    private func attemptInference(
        model: BoundCoreMLModel,
        store: LoadedPixelModelStore,
        sink: PixelEvidenceSink
    ) async -> InferenceAttempt {
        let analyzer = CoreMLPixelAnalyzer(
            loadedModels: store,
            preparedPixels: StubPixelResolver()
        )
        let step = LabelProducingStep(sink: sink, programmedLabel: shape.programmedLabel)
        do {
            let logit = try await analyzer.infer(PixelFixture.modelInput(), model: model)
            await step.produce(from: logit)
            return InferenceAttempt(logit: logit, fault: nil)
        } catch {
            return InferenceAttempt(logit: nil, fault: error)
        }
    }
}

// MARK: - The variation witness

/// Counts what the run generated and what it produced, outside the property body.
///
/// `propertyCheck` runs its body under `try?`, so a body that failed before its first
/// assertion reports a passing test in milliseconds with every arm skipped. Two habits close
/// that gap, and both matter:
///
///   * every arm counter is compared against the **case count** rather than against a floor,
///     so a run in which an arm stopped being reached fails even if the absolute number still
///     looks large; and
///   * ``recordCompletedBody()`` is the last thing the body does, so a case that ended early
///     is countable. `completedBodies == cases` alone would pass vacuously as `0 == 0`, which
///     is why the case floor sits beside it.
///
/// The produced sets are the substantive half. Every load defect must actually have been
/// refused as `model-load-error`, every output defect as `invalid-output-error`, all four
/// nonfinite spellings by name, and the accepted arm must actually have produced one label on
/// every case — which is what turns "no failure produces Pixel Evidence" from a claim about
/// an unreachable branch into a measured zero beside a measured one.
private final class ModelOutputMappingWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Arm counters.
    private var cases = 0
    private var completedBodies = 0
    private var constantChecks = 0
    private var loadHalves = 0
    private var loadRefusals = 0
    private var executionRefusals = 0
    private var outputHalves = 0
    private var outputRefusals = 0
    private var evidenceProductions = 0

    // Produced outcomes.
    private var refusedLoadDefects: Set<String> = []
    private var refusedOutputDefects: Set<String> = []
    private var refusedNonFiniteSpellings: Set<String> = []
    private var returnedLogitBitPatterns: Set<UInt64> = []

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var finiteBitPatterns: Set<UInt64> = []
    private var misnamedNames: Set<String> = []
    private var elementCounts: Set<Int> = []
    private var extraNames: Set<String> = []
    private var selectedLoadDefects: Set<String> = []
    private var descriptionDefects: Set<String> = []
    private var nonFloatingTypes: Set<String> = []
    private var nonFiniteSpellings: Set<String> = []
    private var programmedLabels: Set<String> = []
    private var controlOrders: Set<Bool> = []

    func record(_ shape: ModelOutcomeShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        finiteBitPatterns.insert(shape.finiteLogitValue.bitPattern)
        misnamedNames.insert(shape.misnamedFeatureName)
        elementCounts.insert(shape.nonScalarElementCount)
        extraNames.insert(shape.extraFeatureName)
        selectedLoadDefects.insert(shape.loadDefect.token)
        descriptionDefects.insert(shape.outputDescriptionDefect.token)
        nonFloatingTypes.insert("\(shape.nonFloatingElementType)")
        nonFiniteSpellings.insert(shape.nonFiniteToken)
        programmedLabels.insert(shape.programmedLabel.rawValue)
        controlOrders.insert(shape.controlRunsFirst)
    }

    func recordConstantCheck() {
        lock.lock()
        constantChecks += 1
        lock.unlock()
    }

    func recordLoadHalf() {
        lock.lock()
        loadHalves += 1
        lock.unlock()
    }

    func recordLoadRefusal(_ defect: LoadDefect) {
        lock.lock()
        loadRefusals += 1
        refusedLoadDefects.insert(defect.token)
        lock.unlock()
    }

    func recordExecutionRefusal() {
        lock.lock()
        executionRefusals += 1
        lock.unlock()
    }

    func recordOutputHalf() {
        lock.lock()
        outputHalves += 1
        lock.unlock()
    }

    func recordOutputRefusal(_ defect: OutputFeatureSetShape, nonFiniteToken: String) {
        lock.lock()
        outputRefusals += 1
        refusedOutputDefects.insert(defect.token)
        if defect == .nonFinite {
            refusedNonFiniteSpellings.insert(nonFiniteToken)
        }
        lock.unlock()
    }

    func recordEvidenceProduction(_ emitted: Double) {
        lock.lock()
        evidenceProductions += 1
        returnedLogitBitPatterns.insert(emitted.bitPattern)
        lock.unlock()
    }

    /// Called last in the body, so a case that stopped early is countable.
    func recordCompletedBody() {
        lock.lock()
        completedBodies += 1
        lock.unlock()
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases; ran \(cases)")
        #expect(
            completedBodies == cases,
            "\(cases - completedBodies) of \(cases) cases did not reach the end of the body"
        )

        // Every arm ran on every case. Compared against the case count rather than against a
        // floor: an arm that stopped being reached fails here even when the absolute number
        // still looks large.
        #expect(constantChecks == cases, "constant checks: \(constantChecks)")
        #expect(loadHalves == cases, "load halves: \(loadHalves)")
        #expect(outputHalves == cases, "output halves: \(outputHalves)")
        #expect(executionRefusals == cases, "execution refusals: \(executionRefusals)")

        // Every member of both families was refused on every case.
        #expect(
            loadRefusals == cases * LoadDefect.allCases.count,
            "load failures refused by the real path: \(loadRefusals)"
        )
        #expect(
            outputRefusals == cases * OutputFeatureSetShape.defects.count,
            "output defects refused by the real path: \(outputRefusals)"
        )
        #expect(
            refusedLoadDefects == Set(LoadDefect.allCases.map(\.token)),
            """
            load defects never refused: \
            \(Set(LoadDefect.allCases.map(\.token)).subtracting(refusedLoadDefects).sorted())
            """
        )
        #expect(
            refusedOutputDefects == Set(OutputFeatureSetShape.defects.map(\.token)),
            """
            output defects never refused: \
            \(Set(OutputFeatureSetShape.defects.map(\.token))
                .subtracting(refusedOutputDefects).sorted())
            """
        )
        // All four nonfinite spellings were refused, not only whichever one a lucky draw
        // produced. Quiet and signalling NaN are separate members because a check written
        // against one does not cover the other.
        #expect(
            refusedNonFiniteSpellings == ModelOutcomeShape.nonFiniteTokens,
            "nonfinite spellings refused: \(refusedNonFiniteSpellings.sorted())"
        )

        // The positive control that backs every absence assertion above. If this is not the
        // case count, the "no Pixel Evidence" claims were measured against a path that does
        // not produce evidence at all.
        #expect(
            evidenceProductions == cases,
            """
            the accepted output produced exactly one label \(evidenceProductions) time(s); \
            a lower number means every absence assertion above is unbacked
            """
        )
        // Every generated finite value came back, so "unchanged" was measured over the whole
        // accepted family rather than over whichever member happened to be drawn last.
        #expect(
            returnedLogitBitPatterns == finiteBitPatterns,
            """
            accepted logits returned \(returnedLogitBitPatterns.count) distinct bit patterns \
            for \(finiteBitPatterns.count) generated ones
            """
        )

        // The generated baseline actually varied.
        #expect(seeds.count >= 50, "generated seeds: \(seeds.count)")
        #expect(
            finiteBitPatterns.count >= ModelOutcomeShape.finiteValueCount,
            "generated finite values: \(finiteBitPatterns.count)"
        )
        #expect(
            misnamedNames == ["logits", "Logit", "logit ", " logit", "logit_0", "var_318"],
            "generated misnamed features: \(misnamedNames.sorted())"
        )
        #expect(
            elementCounts == [0, 2, 3, 384, 384 * 384 * 3],
            "generated element counts: \(elementCounts.sorted())"
        )
        #expect(
            extraNames == ["probability", "score", "confidence", "var_1"],
            "generated extra features: \(extraNames.sorted())"
        )
        #expect(
            selectedLoadDefects == Set(LoadDefect.allCases.map(\.token)),
            "generated load defects: \(selectedLoadDefects.sorted())"
        )
        #expect(
            descriptionDefects == Set(OutputDescriptionDefect.allCases.map(\.token)),
            "generated description defects: \(descriptionDefects.sorted())"
        )
        #expect(
            nonFloatingTypes == ["int32", "int64", "other"],
            "generated nonfloating element types: \(nonFloatingTypes.sorted())"
        )
        #expect(
            nonFiniteSpellings == ModelOutcomeShape.nonFiniteTokens,
            "generated nonfinite spellings: \(nonFiniteSpellings.sorted())"
        )
        #expect(
            programmedLabels == Set(PixelEvidence.allCases.map(\.rawValue)),
            "generated labels: \(programmedLabels.sorted())"
        )
        #expect(controlOrders == [false, true], "only one control order was generated")
    }
}
