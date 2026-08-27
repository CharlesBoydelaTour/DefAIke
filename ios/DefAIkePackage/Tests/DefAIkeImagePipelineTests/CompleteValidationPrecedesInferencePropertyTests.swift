import DefAIkeDomain
import Foundation
import PropertyBased
import Testing
import UniformTypeIdentifiers

@testable import DefAIkeImagePipeline

// Design Property 8: complete validation precedes inference.
//
// The design states it as: for any input and Resource Budget, pixel inference can begin
// only after the required image data has completely decoded and all declared/decoded
// dimension, pixel-count, memory, and storage checks pass; malformed data yields
// `decoding-error`, a hard-limit breach yields `resource-limit`, and an unpreprocessable
// accepted decode yields `preprocessing-error`, with no inference in every failure case.
//
// Quantified here as one property over every generated case, in two halves:
//
//   * outcome — the generated arm's outcome class fixes exactly one Analysis Error and
//     exactly one stage that reports it, and the three failure classes are not
//     interchangeable: malformed or incompletely decodable input never reports a
//     resource limit, a hard-limit breach never reports a decoding failure, and an
//     accepted decode the bound contract cannot be applied to reports neither of them;
//   * ordering — inference is entered only in a run whose validation returned a
//     ``ValidatedImage`` *and* whose preprocessing completed, both strictly earlier in
//     the recorded event sequence. In every failure arm inference was entered zero
//     times.
//
// Every case also runs a **control**: one real supported container, a coherent contract,
// and a budget whose limits every measurement fits, asserting that validation accepted,
// preprocessing completed, and inference was entered — each exactly once, in that order.
// The ordering half is a nonoccurrence claim, which passes when nothing happens for the
// wrong reason, so the control is what proves the recorder would have seen an inference
// call had one been made. It runs on every generated case rather than in a separate test,
// so a change that silently disconnects the analyzer fails 100 times instead of once.
//
// ## What is real here and what is not
//
// The Input Validator and the Preprocessor are the real adapters over real Image I/O,
// Core Graphics, and Accelerate, because Requirements 3.1 through 3.4 and 3.11 are claims
// about what those two actually do: whether a decode completed, whether a measurement was
// bounded before the allocation it precedes, and whether the bound contract could be
// applied at all. Only the Pixel Analyzer is a double, because it is the thing that must
// not be reached.
//
// `InputValidationTests` pins individual decode outcomes and individual budget breaches
// with one example each. This file quantifies the boundary statement over generated
// containers, dimensions, truncation points, budgets, and contracts, and it is the only
// file here that asserts what does and does not happen *across* the validation,
// preprocessing, and inference stages together.
//
// Scope: the two unsupported-input errors and their short-circuit are Property 3's, and
// no arm here produces either one. The exact pre-orientation quality record is Property
// 9's, the totality of the metadata state-action map is Property 10's, and resize and
// crop geometry is Property 12's. Two arms below refuse an accepted decode through the
// contract's working color space, and what they assert is only the error category, the
// stage, and the absence of inference — never which metadata state selects which action,
// and never that a particular working space is the right one to bind.
//
// **No value in this file is an approved release value.** The Preprocessing Contract's
// metadata actions, geometry rules, and working space, and the Resource Budget's limits,
// are synthetic arguments that exist so a port taking a signed artifact can be called at
// all. Several are deliberately incoherent, which is the point of the arm that uses them.
// Nothing here may be copied into a shipping artifact.

extension Tag {
    /// Design Property 8.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property8CompleteValidationPrecedesInference: Self
}

@Suite(
    "Property 8: complete validation precedes inference",
    .tags(.property8CompleteValidationPrecedesInference)
)
struct CompleteValidationPrecedesInferencePropertyTests {
    /// Runs at the library default of 100 generated cases with shrinking, which is the
    /// minimum the design requires; `PropertyToolchainWiringTests` pins that default.
    ///
    /// **Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.11**
    @Test("Inference is entered only after a complete in-budget decode and an applied contract")
    func inferenceIsEnteredOnlyAfterCompleteValidation() async {
        let witness = ValidationVariationWitness()

        await propertyCheck(input: ValidationShape.generator) { shape in
            witness.record(shape)
            let scenario = ValidationScenario(shape: shape)

            await scenario.checkGeneratedArmReachesItsOutcome()
            await scenario.checkAcceptedControlEntersInference()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - Host encoder inventory

/// The supported containers this host can actually produce.
///
/// A decode claim only means something against real encoded bytes, so a container whose
/// encoder is missing is dropped rather than replaced by a synthetic stand-in. HEIF has no
/// Image I/O encoder even where HEIC does, which is why the set is discovered instead of
/// assumed.
///
/// Computed once. Encoding a probe image per generated case to answer the same question
/// 100 times would put host capability detection inside the measured property.
private enum EncodableSupportedContainer {
    static let identifiers: [String] = [
        "public.jpeg",
        "public.png",
        "public.heic",
        "public.heif",
    ].filter { identifier in
        guard let type = UTType(identifier) else { return false }
        return EncodedImageFixture.canEncode(type)
    }
}

// MARK: - Outcome classes and arms

/// What Requirements 3.2, 3.3, 3.4, and 3.11 divide every validated input into.
///
/// This is the ground truth the assertions read, not a restatement of how the adapters
/// decide. Each class fixes one Analysis Error, so an arm is compared against the
/// requirement rather than against the code under test.
private enum OutcomeClass: String, Hashable, Sendable, CaseIterable {
    /// Requirements 3.1 and 3.2: a complete decode within the budget, accepted for
    /// preprocessing, reaching inference.
    case acceptedForInference
    /// Requirement 3.3: malformed, or not completely decodable.
    case malformedInput
    /// Requirement 3.4: a declared or decoded measurement the bound budget does not
    /// admit.
    case hardLimitBreach
    /// Requirement 3.11: an accepted decode the bound contract cannot be applied to.
    case unapplicableContract

    /// The single Analysis Error this class produces, or `nil` when the input is
    /// analyzable.
    var requiredError: AnalysisError? {
        switch self {
        case .acceptedForInference: nil
        case .malformedInput: .decodingError
        case .hardLimitBreach: .resourceLimit
        case .unapplicableContract: .preprocessingError
        }
    }

    /// Whether a run in this class may enter inference at all.
    var permitsInference: Bool { self == .acceptedForInference }

    /// Whether validation in this class returns a ``ValidatedImage``.
    ///
    /// True for the contract class as well as the accepted class: Requirement 3.11's
    /// antecedent is an input that *was* accepted, so an arm that failed earlier would not
    /// be testing it.
    var acceptsTheDecode: Bool {
        self == .acceptedForInference || self == .unapplicableContract
    }
}

/// One generated situation, and the outcome the requirements fix for it.
///
/// Thirteen arms rather than four, because a class with one member asserts one example a
/// hundred times over. Each arm drives a different check in the adapters' ordered list —
/// the retained copy's size, the extension's encoded-input ceiling, the declared pixel
/// count, the decode's memory cost, the post-decode re-check, the container's readability,
/// the decode's completeness, and the contract's applicability — and every one of them
/// must produce its class's single error.
private enum ValidationArm: String, Hashable, Sendable, CaseIterable {
    // MARK: Requirements 3.1 and 3.2

    /// A real supported container under a budget whose every limit the measurements fit.
    case acceptedWithinBudget
    /// The same, with the decoded-pixel ceiling set to exactly what the decode produced.
    ///
    /// A hard limit is a ceiling, not an exclusive bound, so a decode that exactly fills
    /// it is still "within the active Resource Budget" under Requirement 3.2.
    case acceptedAtExactPixelCeiling

    // MARK: Requirement 3.3

    /// A real JPEG whose image data is truncated, so nothing short of completing the
    /// decode detects it.
    case truncatedContainer
    /// Content that is not a readable container of any kind.
    case unreadableContent
    /// A retained encoded copy that was never finalized, so its bytes cannot be read
    /// completely.
    case unreadableRetainedCopy

    // MARK: Requirement 3.4

    /// The decoded-pixel ceiling one pixel below what the decode produced.
    ///
    /// The adjacent arm to ``acceptedAtExactPixelCeiling``: together they place the
    /// accept/refuse boundary at the ceiling itself, measured rather than assumed.
    case pixelCeilingOneBelowDecoded
    /// A memory ceiling below the decode's cost, so the breach is detectable before the
    /// allocation it precedes.
    case decodeMemoryOverCeiling
    /// A temporary-storage ceiling below the retained encoded copy.
    case encodedCopyOverStorageCeiling
    /// A Share Extension budget whose encoded-input ceiling the retained copy exceeds.
    case encodedInputOverExtensionCeiling
    /// A budget that defines no decoded-pixel ceiling, so the pixel count cannot be
    /// bounded by an approved number.
    case pixelCeilingNotDefined
    /// A decoded-pixel ceiling expressed in a unit that cannot bound a pixel count.
    case pixelCeilingInWrongUnit

    // MARK: Requirement 3.11

    /// A contract naming a working color space this build cannot resolve.
    case workingSpaceUnresolvable
    /// A contract pinning the working space to ICC bytes the resolved space does not
    /// carry.
    case workingSpaceProfileMismatch

    var outcomeClass: OutcomeClass {
        switch self {
        case .acceptedWithinBudget, .acceptedAtExactPixelCeiling:
            .acceptedForInference
        case .truncatedContainer, .unreadableContent, .unreadableRetainedCopy:
            .malformedInput
        case .pixelCeilingOneBelowDecoded, .decodeMemoryOverCeiling,
             .encodedCopyOverStorageCeiling, .encodedInputOverExtensionCeiling,
             .pixelCeilingNotDefined, .pixelCeilingInWrongUnit:
            .hardLimitBreach
        case .workingSpaceUnresolvable, .workingSpaceProfileMismatch:
            .unapplicableContract
        }
    }

    /// The stage that must report this arm's failure, or `nil` when it succeeds.
    ///
    /// Asserted alongside the category because the two carry different information: the
    /// category is what a user is shown, and the stage is where the pipeline actually
    /// stopped. An arm that produced the right category from the wrong stage would mean a
    /// check moved, which is exactly what Requirement 3.4's ordering forbids.
    var requiredStage: AnalysisStage? {
        switch outcomeClass {
        case .acceptedForInference:
            nil
        case .unapplicableContract:
            .preprocessing
        case .hardLimitBreach:
            .inputValidation
        case .malformedInput:
            // Unreadable content is refused while the container is being classified;
            // an incomplete decode and an unreadable retained copy are refused by the
            // decode itself.
            self == .unreadableContent ? .mediaClassification : .inputValidation
        }
    }

    /// Whether this arm needs a probe run to learn what the decode actually produces.
    var needsDecodedPixelCountProbe: Bool {
        self == .acceptedAtExactPixelCeiling || self == .pixelCeilingOneBelowDecoded
    }
}

// MARK: - Generated shape

/// One generated case, as plain data.
///
/// The generator produces data only. Bytes, artifacts, and the pipeline are built inside
/// the property body, where a construction that unexpectedly fails is recorded as an issue
/// rather than thrown: `propertyCheck` discards an error thrown by its body, so a refusal
/// that escaped as a throw would pass vacuously.
///
/// ## How the baseline varies
///
/// A property whose input is one constant with an arm swapped in asserts thirteen examples
/// a hundred times over, so every dimension the assertions depend on is generated:
///
///   * the arm, and with it the outcome class;
///   * the container, over every supported one this host can encode, because "completely
///     decoded" is a per-format claim;
///   * width and height independently, so a container is never square or a fixed size by
///     construction, and so the probe-derived ceilings land on a different number each
///     case;
///   * where a truncated container is cut;
///   * the byte count an unreadable retained copy declares;
///   * both ingest routes, because Requirement 3.1 applies to a selected item from either
///     one;
///   * the preservation basis, so a failing session's recorded byte status varies;
///   * the control's container and its own dimensions, independently of the arm's;
///   * every synthetic identifier, from ``seed``.
///
/// Provider content-type hints are deliberately absent: a hint must never reach a
/// classification, which is Property 3's claim and is quantified there.
///
/// ``ValidationVariationWitness`` checks after the run that this actually happened.
private struct ValidationShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic session and artifact identifier, so the whole reference set
    /// varies together and stays coherent without a cross-reference table.
    ///
    /// Used only in identifier strings. No schema version is derived from it: a seeded
    /// version can shrink onto the `0.0.0` development stand-in, which the artifact schema
    /// rejects, and the refusal would surface as a construction failure in an unrelated
    /// arm.
    let seed: Int

    let armIndex: Int

    /// Dimensions of the arm's encoded image.
    let width: Int
    let height: Int

    let containerIndex: Int
    let route: InputRoute
    let basisIndex: Int

    /// Where ``ValidationArm/truncatedContainer`` cuts the JPEG, as a percentage.
    let truncationPercent: Int

    /// The byte count ``ValidationArm/unreadableRetainedCopy`` declares for a copy that
    /// was never finalized.
    let unreadableDeclaredByteCount: Int

    /// The control's own container and dimensions, generated separately so the control
    /// never coincides with the arm's by construction.
    let controlIndex: Int
    let controlWidth: Int
    let controlHeight: Int

    var arm: ValidationArm {
        ValidationArm.allCases[armIndex % ValidationArm.allCases.count]
    }

    var containerIdentifier: String {
        EncodableSupportedContainer.identifiers[
            containerIndex % EncodableSupportedContainer.identifiers.count
        ]
    }

    var controlIdentifier: String {
        EncodableSupportedContainer.identifiers[
            controlIndex % EncodableSupportedContainer.identifiers.count
        ]
    }

    var basis: PreservationBasis {
        PreservationBasis.allCases[basisIndex % PreservationBasis.allCases.count]
    }

    /// The truncation point as a fraction, always strictly inside the container.
    var truncationFraction: Double { Double(truncationPercent) / 100 }

    var description: String {
        """
        seed \(seed), arm \(arm.rawValue), class \(arm.outcomeClass.rawValue), \
        \(containerIdentifier) \(width)x\(height), route \(route.rawValue), \
        basis \(basis.rawValue), truncation \(truncationPercent)%, \
        unreadable declares \(unreadableDeclaredByteCount) byte(s), \
        control \(controlIdentifier) \(controlWidth)x\(controlHeight)
        """
    }

    // MARK: Generators

    static var generator: Generator<ValidationShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.int(in: 0...199),
            dimensions,
            Gen.int(in: 0...199),
            Gen.bool,
            Gen.int(in: 0...199),
            Gen.int(in: 10...70),
            Gen.int(in: 1...65_536),
            Gen.int(in: 0...199),
            dimensions
        )
        .map { raw in
            ValidationShape(
                seed: raw.0,
                armIndex: raw.1,
                width: raw.2.0,
                height: raw.2.1,
                containerIndex: raw.3,
                route: raw.4 ? .photosPicker : .shareExtension,
                basisIndex: raw.5,
                truncationPercent: raw.6,
                unreadableDeclaredByteCount: raw.7,
                controlIndex: raw.8,
                controlWidth: raw.9.0,
                controlHeight: raw.9.1
            )
        }
        .eraseToAny()
    }

    /// Width and height, drawn independently.
    ///
    /// Bounded so the outcome depends on the check the arm is about. Every generated image
    /// is at least 8 by 8, so a ceiling set from a measurement is always positive; and
    /// small enough that no generated dimension reaches a limit the arm did not set, so an
    /// accepted arm is never refused by an unrelated check and a resource arm is never
    /// refused by the wrong one.
    private static var dimensions: Generator<(Int, Int), AnySequence<Any>> {
        zip(Gen.int(in: 8...48), Gen.int(in: 8...48)).eraseToAny()
    }
}

// MARK: - Recorded events

/// The events of one run this property watches.
///
/// Entry and completion are separate for validation and preprocessing, because the claim
/// is about a boundary: "inference begins only after the decode has *completed*" is not
/// the same statement as "after the decode was attempted", and only the pair can tell
/// them apart. Inference has one event because being entered at all is what the failure
/// arms forbid.
private enum PipelineEvent: String, Hashable, Sendable, CaseIterable {
    /// The validator was called.
    case validationStarted
    /// The validator returned a ``ValidatedImage``.
    ///
    /// The structural form of Requirement 3.2's "marked as accepted for preprocessing":
    /// that value exists only after all image data the bound contract requires has decoded
    /// and every declared, decoded, pixel-count, memory, and storage check has passed, and
    /// no other path in the module can construct one.
    case validationAccepted
    /// The Preprocessor was called.
    case preprocessingStarted
    /// The Preprocessor returned a model input.
    case preprocessingCompleted
    /// The Pixel Analyzer was called. The event every failure arm forbids.
    case inferenceStarted

    /// The order a completed run must record.
    static let completeRun: [PipelineEvent] = [
        .validationStarted, .validationAccepted, .preprocessingStarted,
        .preprocessingCompleted, .inferenceStarted,
    ]
}

/// An ordered, thread-safe log of one run's events.
///
/// Ordered rather than a set of booleans because the claim is about precedence: reading the
/// sequence is what lets the property say that inference came after a completed decode,
/// and what makes a failure message say where a run actually got to.
private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PipelineEvent] = []

    func record(_ event: PipelineEvent) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }

    var events: [PipelineEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func count(of event: PipelineEvent) -> Int {
        events.filter { $0 == event }.count
    }

    /// Whether `event` appears strictly before the first ``PipelineEvent/inferenceStarted``.
    ///
    /// `false` when inference was never entered, so a caller has to establish that
    /// separately; this answers only the precedence question.
    func precedesInference(_ event: PipelineEvent) -> Bool {
        let recorded = events
        guard let inference = recorded.firstIndex(of: .inferenceStarted) else { return false }
        return recorded.prefix(inference).contains(event)
    }
}

// MARK: - The pipeline under test

/// Records the preprocessing call and its completion around the real adapter.
///
/// A decorator rather than a stand-in: Requirement 3.11 is a claim about what the real
/// Preprocessor does with an accepted decode it cannot apply the bound contract to, so
/// replacing it would leave the two contract arms asserting nothing about production
/// behavior. The decorator adds two events and changes no result.
private struct RecordingContractPreprocessor: ImagePreprocessing {
    let recorder: EventRecorder
    let underlying: ContractImagePreprocessor

    func prepare(
        _ image: ValidatedImage,
        contract: PreprocessingContract,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ModelImageInput {
        recorder.record(.preprocessingStarted)
        let prepared = try await underlying.prepare(image, contract: contract, budget: budget)
        recorder.record(.preprocessingCompleted)
        return prepared
    }
}

/// Records the inference call and returns one finite logit.
///
/// The only double in the pipeline, because inference is the thing that must not be
/// reached. It records before doing anything else, so a nonoccurrence assertion is about
/// the call rather than about its result, and it decides no policy: one fixed
/// representable value, carrying no boundary, mapping, or calibrated meaning.
private struct RecordingPixelAnalyzer: PixelAnalyzing {
    let recorder: EventRecorder

    func infer(
        _ input: ModelImageInput,
        model: BoundCoreMLModel
    ) async throws(AnalysisFault) -> RawLogit {
        recorder.record(.inferenceStarted)
        // Force-unwrap is sound: the literal is finite, which is the only condition
        // `RawLogit` rejects.
        return RawLogit(0.25)!
    }
}

/// One session's worth of work: the real validator, the real preprocessor, a recording
/// analyzer.
///
/// The order is the design's, and it stops at inference. Calibration, the provenance lane,
/// and evidence joining are deliberately absent: they are downstream of the boundary this
/// property is about, their nonoccurrence after a refused input is Property 3's claim, and
/// wiring them would require synthesizing a Calibration Policy and a Provenance Policy
/// whose every boundary, budget, and trust answer is an unresolved external decision.
private struct ValidationPipeline {
    let recorder = EventRecorder()
    let store = InMemoryEncodedAssetStore()
    let decodedImages = DecodedImageStore()
    let modelInputs = PreparedModelInputStore()
    private let quality = InputQualityLedger()
    private let validator: ImageIOInputValidator
    private let preprocessor: RecordingContractPreprocessor
    private let analyzer: RecordingPixelAnalyzer

    private let contract: PreprocessingContract
    private let budget: ResourceBudget
    private let model: BoundCoreMLModel

    init(artifacts: SyntheticValidationArtifacts) {
        self.contract = artifacts.contract
        self.budget = artifacts.budget
        self.model = artifacts.model
        self.validator = ImageIOInputValidator(
            encodedAssets: store,
            decodedImages: decodedImages,
            quality: quality
        )
        self.preprocessor = RecordingContractPreprocessor(
            recorder: recorder,
            underlying: ContractImagePreprocessor(
                encodedAssets: store,
                decodedImages: decodedImages,
                modelInputs: modelInputs
            )
        )
        self.analyzer = RecordingPixelAnalyzer(recorder: recorder)
    }

    /// Runs one session to its terminal outcome.
    ///
    /// Returns rather than throws, so the caller records an issue instead of letting a
    /// fault escape the property body.
    ///
    /// ``PipelineEvent/validationAccepted`` is recorded here rather than inside the
    /// adapter, at the one point where a ``ValidatedImage`` exists. That is the observable
    /// form of the acceptance: the event cannot happen for a run whose validation threw.
    func run(_ asset: ImportedEncodedAsset) async -> Result<RawLogit, AnalysisFault> {
        recorder.record(.validationStarted)
        let validated: ValidatedImage
        do {
            validated = try await validator.validate(asset, contract: contract, budget: budget)
        } catch {
            return .failure(error)
        }
        recorder.record(.validationAccepted)

        do {
            let input = try await preprocessor.prepare(
                validated,
                contract: contract,
                budget: budget
            )
            return .success(try await analyzer.infer(input, model: model))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Scenario

/// One generated shape, the artifacts built from it, and the two runs it performs.
private struct ValidationScenario {
    let shape: ValidationShape

    // MARK: The generated arm

    /// The arm reaches exactly its class's outcome, and only an accepted decode with an
    /// applied contract reaches inference.
    func checkGeneratedArmReachesItsOutcome() async {
        let arm = shape.arm
        let contract = self.contract(for: arm)

        // The arm's encoded bytes, when it has any. The unreadable-copy arm names an
        // object that was never finalized, so it has none by construction.
        var bytes: [UInt8]?
        if arm != .unreadableRetainedCopy {
            guard let produced = encodedBytes(for: arm) else {
                Issue.record("this host could not produce \(arm.rawValue) bytes [\(shape)]")
                return
            }
            bytes = produced
        }

        // The two ceiling arms take their limit from what the decode actually produces,
        // not from the generated dimensions. An encoder that adjusted a dimension would
        // otherwise move the boundary these arms are placed at, and the arm would still
        // pass while testing something else.
        var measuredPixelCount: UInt64?
        if arm.needsDecodedPixelCountProbe {
            guard let bytes else {
                Issue.record("a probe arm must have bytes [\(shape)]")
                return
            }
            guard let measured = await probeDecodedPixelCount(bytes, contract: contract) else {
                return
            }
            measuredPixelCount = measured
        }

        guard let budget = budget(for: arm, decodedPixelCount: measuredPixelCount) else {
            Issue.record("could not build the budget for \(arm.rawValue) [\(shape)]")
            return
        }

        let pipeline = ValidationPipeline(
            artifacts: SyntheticValidationArtifacts(
                seed: shape.seed,
                contract: contract,
                budget: budget
            )
        )

        let asset: ImportedEncodedAsset
        do {
            if let bytes {
                asset = try await IngestFixture.asset(
                    bytes: bytes,
                    in: pipeline.store,
                    sessionID: session("arm"),
                    route: shape.route,
                    preservationBasis: shape.basis
                )
            } else {
                asset = try await IngestFixture.assetNamingUnfinalizedObject(
                    in: pipeline.store,
                    declaredByteCount: UInt64(shape.unreadableDeclaredByteCount),
                    sessionID: session("arm")
                )
            }
        } catch {
            Issue.record("building the arm's session failed: \(error) [\(shape)]")
            return
        }

        let outcome = await pipeline.run(asset)
        let recorder = pipeline.recorder

        // The run started. Without this, every nonoccurrence assertion below would also
        // hold for a pipeline that was never invoked.
        #expect(
            recorder.count(of: .validationStarted) == 1,
            "the pipeline must have started [\(shape)]"
        )

        // The precedence claim, asserted on every arm and not only on the failing ones:
        // wherever inference was entered, a completed decode and a completed
        // preprocessing came first (Requirement 3.1).
        checkInferenceIsPrecededByCompleteValidation(recorder)

        switch arm.outcomeClass {
        case .acceptedForInference:
            await checkAcceptedArmReachesInference(outcome, pipeline: pipeline)
        case .malformedInput, .hardLimitBreach:
            await checkRefusedBeforeAcceptance(outcome, pipeline: pipeline)
        case .unapplicableContract:
            await checkAcceptedDecodeRefusedByContract(outcome, pipeline: pipeline)
        }
    }

    /// Requirement 3.1: inference is never entered before a complete decode and a
    /// completed preprocessing.
    ///
    /// Vacuously true when inference was not entered, which is why the arms below also
    /// assert its count directly. Stated separately because it is the one claim that holds
    /// for every arm at once.
    private func checkInferenceIsPrecededByCompleteValidation(_ recorder: EventRecorder) {
        guard recorder.count(of: .inferenceStarted) > 0 else { return }
        #expect(
            recorder.precedesInference(.validationAccepted),
            """
            inference was entered without an accepted decode before it; \
            events: \(recorder.events.map(\.rawValue)) [\(shape)]
            """
        )
        #expect(
            recorder.precedesInference(.preprocessingCompleted),
            """
            inference was entered before preprocessing completed; \
            events: \(recorder.events.map(\.rawValue)) [\(shape)]
            """
        )
    }

    /// Requirements 3.1 and 3.2: a complete decode within the budget is accepted, and the
    /// whole ordered run happens exactly once.
    private func checkAcceptedArmReachesInference(
        _ outcome: Result<RawLogit, AnalysisFault>,
        pipeline: ValidationPipeline
    ) async {
        guard case .success = outcome else {
            Issue.record(
                """
                a complete in-budget decode must reach inference; \
                got \(outcome) [\(shape)]
                """
            )
            return
        }
        checkCompleteRunHappenedOnce(pipeline.recorder)
        // One decoded image and one prepared buffer, both owned by this session.
        #expect(await pipeline.decodedImages.retainedImageCount == 1, "[\(shape)]")
        #expect(await pipeline.modelInputs.retainedInputCount == 1, "[\(shape)]")
    }

    /// Requirements 3.3 and 3.4: the input is refused before it is ever accepted, with
    /// exactly the class's error, and neither preprocessing nor inference is entered.
    private func checkRefusedBeforeAcceptance(
        _ outcome: Result<RawLogit, AnalysisFault>,
        pipeline: ValidationPipeline
    ) async {
        let recorder = pipeline.recorder
        checkExactFailure(outcome)

        // Requirement 3.4's "without full-resolution preprocessing or pixel inference",
        // and Requirement 3.3's "without pixel inference".
        #expect(
            recorder.events == [.validationStarted],
            """
            only validation may run for \(shape.arm.rawValue); \
            events: \(recorder.events.map(\.rawValue)) [\(shape)]
            """
        )
        #expect(recorder.count(of: .validationAccepted) == 0, "[\(shape)]")
        #expect(recorder.count(of: .preprocessingStarted) == 0, "[\(shape)]")
        #expect(recorder.count(of: .inferenceStarted) == 0, "[\(shape)]")

        // A refusal that precedes acceptance leaves nothing retained. A breach found
        // before the decode must not have allocated, and a decode that did not complete
        // has nothing to retain.
        #expect(await pipeline.decodedImages.retainedImageCount == 0, "[\(shape)]")
        #expect(await pipeline.modelInputs.retainedInputCount == 0, "[\(shape)]")
    }

    /// Requirement 3.11: an accepted decode the bound contract cannot be applied to is
    /// `preprocessing-error`, and inference is not entered.
    private func checkAcceptedDecodeRefusedByContract(
        _ outcome: Result<RawLogit, AnalysisFault>,
        pipeline: ValidationPipeline
    ) async {
        let recorder = pipeline.recorder
        checkExactFailure(outcome)

        // The antecedent: this arm is only about an input that *was* accepted. An arm that
        // failed in validation would produce the same nonoccurrence below while testing
        // nothing Requirement 3.11 says.
        #expect(
            recorder.count(of: .validationAccepted) == 1,
            """
            the contract arm needs an accepted decode; \
            events: \(recorder.events.map(\.rawValue)) [\(shape)]
            """
        )
        #expect(recorder.count(of: .preprocessingStarted) == 1, "[\(shape)]")
        #expect(
            recorder.count(of: .preprocessingCompleted) == 0,
            "preprocessing must not report completion [\(shape)]"
        )
        #expect(recorder.count(of: .inferenceStarted) == 0, "[\(shape)]")

        // The decode was accepted, so its image is retained; no buffer was produced.
        #expect(await pipeline.decodedImages.retainedImageCount == 1, "[\(shape)]")
        #expect(await pipeline.modelInputs.retainedInputCount == 0, "[\(shape)]")
    }

    /// The failure carries exactly the class's error at exactly the arm's stage, is not
    /// one of the other two classes' errors, and is not cancellation.
    private func checkExactFailure(_ outcome: Result<RawLogit, AnalysisFault>) {
        let arm = shape.arm
        guard let required = arm.outcomeClass.requiredError, let stage = arm.requiredStage else {
            Issue.record("a failing arm must fix one error and one stage [\(shape)]")
            return
        }
        guard case .failure(let fault) = outcome else {
            Issue.record("\(arm.rawValue) must not reach inference [\(shape)]")
            return
        }

        #expect(fault == .analysis(required, stage: stage), "[\(shape)]")
        #expect(fault.analysisError == required, "[\(shape)]")
        // Cancellation is a separate terminal outcome and must never stand in for a
        // refused input (Requirement 11.17).
        #expect(fault.isCancelled == false, "[\(shape)]")

        // The three failure classes are not interchangeable: malformed input never reports
        // a resource limit, a breach never reports a decoding failure, and an
        // unpreprocessable decode reports neither.
        for other in OutcomeClass.allCases where other != arm.outcomeClass {
            guard let otherError = other.requiredError, otherError != required else { continue }
            #expect(
                fault.analysisError != otherError,
                "\(arm.rawValue) must not report \(otherError.rawValue) [\(shape)]"
            )
        }
    }

    // MARK: The control

    /// One real supported container, a coherent contract, and a budget every measurement
    /// fits, through the same pipeline, reaching inference.
    ///
    /// This is the non-vacuity half. Every assertion above is a claim that a recorder saw
    /// no inference call, and a recorder that is not wired to an analyzer also sees none.
    /// Running an input that must pass, through a pipeline built the same way, on every
    /// generated case, is what distinguishes "inference did not happen" from "inference
    /// could not have happened".
    func checkAcceptedControlEntersInference() async {
        guard !EncodableSupportedContainer.identifiers.isEmpty else {
            Issue.record("this host can encode no supported container [\(shape)]")
            return
        }
        guard let bytes = encode(
            identifier: shape.controlIdentifier,
            width: shape.controlWidth,
            height: shape.controlHeight
        ) else {
            Issue.record("this host could not encode \(shape.controlIdentifier) [\(shape)]")
            return
        }

        let pipeline = ValidationPipeline(
            artifacts: SyntheticValidationArtifacts(
                seed: shape.seed,
                contract: coherentContract(),
                budget: ResourceFixture.budget(id: "budget-p8-control-\(shape.seed)")
            )
        )

        let asset: ImportedEncodedAsset
        do {
            asset = try await IngestFixture.asset(
                bytes: bytes,
                in: pipeline.store,
                sessionID: session("control"),
                route: shape.route,
                preservationBasis: shape.basis
            )
        } catch {
            Issue.record("building the control session failed: \(error) [\(shape)]")
            return
        }

        let outcome = await pipeline.run(asset)
        guard case .success = outcome else {
            Issue.record(
                """
                the control \(shape.controlIdentifier) must reach inference; \
                got \(outcome) [\(shape)]
                """
            )
            return
        }
        checkCompleteRunHappenedOnce(pipeline.recorder)
        #expect(await pipeline.modelInputs.retainedInputCount == 1, "[\(shape)]")
    }

    /// Every watched event happened exactly once, in the design's causal order.
    private func checkCompleteRunHappenedOnce(_ recorder: EventRecorder) {
        let events = recorder.events
        for event in PipelineEvent.allCases {
            #expect(
                recorder.count(of: event) == 1,
                "\(event.rawValue) must happen once; events: \(events.map(\.rawValue)) [\(shape)]"
            )
        }
        #expect(
            events == PipelineEvent.completeRun,
            "event order: \(events.map(\.rawValue)) [\(shape)]"
        )
    }

    // MARK: Bytes

    /// The arm's encoded bytes, or `nil` when this host could not produce them.
    private func encodedBytes(for arm: ValidationArm) -> [UInt8]? {
        switch arm {
        case .truncatedContainer:
            EncodedImageFixture.truncatedJPEG(fraction: shape.truncationFraction)
        case .unreadableContent:
            EncodedImageFixture.unidentifiableBytes
        case .unreadableRetainedCopy:
            nil
        case .acceptedWithinBudget, .acceptedAtExactPixelCeiling,
             .pixelCeilingOneBelowDecoded, .decodeMemoryOverCeiling,
             .encodedCopyOverStorageCeiling, .encodedInputOverExtensionCeiling,
             .pixelCeilingNotDefined, .pixelCeilingInWrongUnit,
             .workingSpaceUnresolvable, .workingSpaceProfileMismatch:
            encode(identifier: shape.containerIdentifier, width: shape.width, height: shape.height)
        }
    }

    private func encode(identifier: String, width: Int, height: Int) -> [UInt8]? {
        guard let type = UTType(identifier) else { return nil }
        return EncodedImageFixture.encode(
            EncodedImageFixture.gradient(width: width, height: height),
            as: type
        )
    }

    // MARK: The probe

    /// What the decode actually produces, measured through a throwaway pipeline under a
    /// budget every measurement fits.
    ///
    /// Its recorder and stores are discarded: the probe exists only so the two ceiling
    /// arms can be placed at a measured boundary rather than at an assumed one. Records an
    /// issue and returns `nil` when the probe itself does not accept the bytes, because
    /// that means the arm cannot be set up at all.
    private func probeDecodedPixelCount(
        _ bytes: [UInt8],
        contract: PreprocessingContract
    ) async -> UInt64? {
        let store = InMemoryEncodedAssetStore()
        let probe = ImageIOInputValidator(
            encodedAssets: store,
            decodedImages: DecodedImageStore(),
            quality: InputQualityLedger()
        )
        do {
            let asset = try await IngestFixture.asset(
                bytes: bytes,
                in: store,
                sessionID: session("probe"),
                route: shape.route,
                preservationBasis: shape.basis
            )
            let validated = try await probe.validate(
                asset,
                contract: contract,
                budget: ResourceFixture.budget(id: "budget-p8-probe-\(shape.seed)")
            )
            return validated.dimensions.pixelCount
        } catch {
            Issue.record("the ceiling probe could not decode the container: \(error) [\(shape)]")
            return nil
        }
    }

    // MARK: Contracts

    /// The contract the arm binds.
    ///
    /// Coherent for every arm except the two that are about a contract this build cannot
    /// apply. Both of those stay applicable through validation, which reads only the
    /// contract's identity and supported containers, and are refused by the Preprocessor —
    /// which is exactly the situation Requirement 3.11 names.
    private func contract(for arm: ValidationArm) -> PreprocessingContract {
        switch arm {
        case .workingSpaceUnresolvable:
            // A name outside the module's closed working-space table. Not a near miss of a
            // real one: the point is that no resolution exists, so nothing can be
            // substituted for it.
            PreprocessingFixture.contract(
                id: "preprocessing-p8-\(shape.seed)",
                workingSpace: "synthetic-unresolvable-working-space-\(shape.seed)"
            )
        case .workingSpaceProfileMismatch:
            // A resolvable space pinned to ICC bytes it does not carry.
            PreprocessingFixture.contract(
                id: "preprocessing-p8-\(shape.seed)",
                workingSpaceProfileDigest: Fixture.digest(
                    of: Array("not-the-profile-bytes-\(shape.seed)".utf8)
                )
            )
        default:
            coherentContract()
        }
    }

    private func coherentContract() -> PreprocessingContract {
        PreprocessingFixture.contract(id: "preprocessing-p8-\(shape.seed)")
    }

    // MARK: Budgets

    /// The budget the arm binds.
    ///
    /// Every limit other than the one the arm is about stays at the fixture's generous
    /// synthetic value, so the arm's outcome is decided by the check it names. `1` is used
    /// where a ceiling must simply be below a measurement: every generated image is at
    /// least 8 by 8 and every encoded container is more than one byte, so the breach does
    /// not depend on the generated size.
    private func budget(
        for arm: ValidationArm,
        decodedPixelCount: UInt64?
    ) -> ResourceBudget? {
        let id = "budget-p8-\(arm.rawValue)-\(shape.seed)"
        switch arm {
        case .acceptedAtExactPixelCeiling:
            guard let decodedPixelCount else { return nil }
            return ResourceFixture.budget(
                id: id,
                overrides: [
                    .decodedPixelCount: ResourceFixture.numeric(
                        Decimal(decodedPixelCount),
                        .pixels
                    )
                ]
            )
        case .pixelCeilingOneBelowDecoded:
            guard let decodedPixelCount, decodedPixelCount > 1 else { return nil }
            return ResourceFixture.budget(
                id: id,
                overrides: [
                    .decodedPixelCount: ResourceFixture.numeric(
                        Decimal(decodedPixelCount - 1),
                        .pixels
                    )
                ]
            )
        case .decodeMemoryOverCeiling:
            return ResourceFixture.budget(
                id: id,
                overrides: [.peakResidentMemory: ResourceFixture.numeric(1, .bytes)]
            )
        case .encodedCopyOverStorageCeiling:
            return ResourceFixture.budget(
                id: id,
                overrides: [.temporaryStorage: ResourceFixture.numeric(1, .bytes)]
            )
        case .encodedInputOverExtensionCeiling:
            // The encoded-input ceiling belongs to the Share Extension budget, so the
            // budget that carries it is the one that is checked against it.
            return ResourceFixture.budget(
                for: .shareExtension,
                id: id,
                overrides: [.encodedInputSize: ResourceFixture.numeric(1, .bytes)]
            )
        case .pixelCeilingNotDefined:
            // A Share Extension budget defines no decoded-pixel ceiling, because the
            // extension runs no decode. Handing one to validation means the pixel count
            // cannot be bounded by an approved number, and an unbounded decode is not a
            // permitted fallback.
            return ResourceFixture.budget(for: .shareExtension, id: id)
        case .pixelCeilingInWrongUnit:
            // The schema pairs a metric with a numeric limit but does not pin the unit, so
            // a pixel ceiling expressed in milliseconds is representable. Comparing
            // magnitudes across units would accept or reject by accident.
            return ResourceFixture.budget(
                id: id,
                overrides: [
                    .decodedPixelCount: ResourceFixture.numeric(1_000_000, .milliseconds)
                ]
            )
        case .acceptedWithinBudget, .truncatedContainer, .unreadableContent,
             .unreadableRetainedCopy, .workingSpaceUnresolvable,
             .workingSpaceProfileMismatch:
            return ResourceFixture.budget(id: id)
        }
    }

    // MARK: Identifiers

    private func session(_ suffix: String) -> AnalysisSessionID {
        guard let id = AnalysisSessionID("session-p8-\(shape.seed)-\(suffix)") else {
            preconditionFailure("a generated session identifier must be canonical")
        }
        return id
    }
}

// MARK: - Synthetic artifacts

/// The three artifacts the pipeline needs in order to be called at all.
///
/// **No number, action, unit pairing, or limit reachable from this type is an approved
/// release value.** The Preprocessing Contract's metadata actions, geometry rules, and
/// working space, and the Resource Budget's measured limits, are unresolved external
/// decisions. They exist so ports that take signed artifacts can be invoked, and no
/// assertion in this file claims any of them is correct.
///
/// Built per run so two sessions never share a store or a bound model, and so the
/// identifiers a failure reports name the case that produced it.
private struct SyntheticValidationArtifacts {
    let contract: PreprocessingContract
    let budget: ResourceBudget
    let model: BoundCoreMLModel

    init(seed: Int, contract: PreprocessingContract, budget: ResourceBudget) {
        self.contract = contract
        self.budget = budget
        self.model = Self.model(seed: seed, contract: contract)
    }

    /// A bound model carrying the one permitted pixel identity.
    ///
    /// Bound before the session runs, matching a session that snapshots its verified
    /// bundle when the input is accepted, so model load is not an event this property has
    /// to watch. It is an argument to a call that must not happen; nothing here asserts
    /// anything about the model.
    private static func model(
        seed: Int,
        contract: PreprocessingContract
    ) -> BoundCoreMLModel {
        guard let bundleID = ModelBundleID("bundle-p8-\(seed)") else {
            preconditionFailure("the synthetic bundle identifier must be canonical")
        }
        do {
            guard let model = BoundCoreMLModel(
                bundleID: bundleID,
                modelIdentity: RequiredPixelModel.identity,
                coreMLModelVersion: Fixture.artifactID("coreml-p8-\(seed)"),
                inputContract: contract.modelInput,
                outputContract: try ModelOutputContract(
                    featureName: try ArtifactText(
                        validating: ModelOutputContract.requiredFeatureName
                    ),
                    elementType: .float32,
                    isPositiveGoing: true
                ),
                model: LoadedModelToken(rawValue: 1)
            ) else {
                preconditionFailure("only the required pixel-model identity is bindable")
            }
            return model
        } catch {
            preconditionFailure("the synthetic output contract must be schema-valid: \(error)")
        }
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator actually produced, so the property cannot pass by generating
/// one fixed situation a hundred times.
///
/// It also proves the run happened at all. `propertyCheck` discards an error thrown by its
/// body, so a body that failed before its first assertion — a construction that threw, a
/// generator that produced nothing usable — would report a passing test in milliseconds
/// with every arm skipped. A witness that counts cases outside the body is the only thing
/// that catches that.
///
/// The thresholds are below what 100 uniform draws produce, so this witnesses variation
/// rather than pinning a distribution. Arm coverage is asserted as a count rather than as
/// set equality on purpose: with thirteen arms drawn uniformly, one arm is missed in about
/// one run in two hundred, and a coverage assertion that fails that often would train a
/// reader to ignore it. Every outcome *class* is asserted exactly, because four classes
/// over 100 draws makes a miss vanishingly unlikely, and the accepted class is in any case
/// exercised unconditionally by the control on every case.
private final class ValidationVariationWitness: @unchecked Sendable {
    /// How many of the thirteen arms must appear. Three may be missing before this fails,
    /// which no uniform 100-draw run reaches in practice.
    private static let minimumArmCount = 10

    private let lock = NSLock()
    private var arms = Set<ValidationArm>()
    private var classes = Set<OutcomeClass>()
    private var containers = Set<String>()
    private var dimensions = Set<Int>()
    private var routes = Set<InputRoute>()
    private var bases = Set<PreservationBasis>()
    private var truncationPercents = Set<Int>()
    private var declaredByteCounts = Set<Int>()
    private var seeds = Set<Int>()
    private var cases = 0

    func record(_ shape: ValidationShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        arms.insert(shape.arm)
        classes.insert(shape.arm.outcomeClass)
        containers.formUnion([shape.containerIdentifier, shape.controlIdentifier])
        dimensions.formUnion([shape.width, shape.height, shape.controlWidth, shape.controlHeight])
        routes.insert(shape.route)
        bases.insert(shape.basis)
        truncationPercents.insert(shape.truncationPercent)
        declaredByteCounts.insert(shape.unreadableDeclaredByteCount)
        seeds.insert(shape.seed)
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases")
        #expect(
            classes == Set(OutcomeClass.allCases),
            "generated outcome classes: \(classes.map(\.rawValue).sorted())"
        )
        #expect(
            arms.count >= Self.minimumArmCount,
            "generated arms: \(arms.map(\.rawValue).sorted())"
        )
        #expect(
            containers == Set(EncodableSupportedContainer.identifiers),
            "generated containers: \(containers.sorted())"
        )
        #expect(dimensions.count >= 20, "generated dimensions: \(dimensions.count)")
        #expect(routes == Set(InputRoute.allCases), "both ingest routes are generated")
        #expect(
            bases == Set(PreservationBasis.allCases),
            "generated preservation bases: \(bases.map(\.rawValue).sorted())"
        )
        #expect(
            truncationPercents.count >= 15,
            "generated truncation points: \(truncationPercents.count)"
        )
        #expect(
            declaredByteCounts.count >= 15,
            "generated declared byte counts: \(declaredByteCounts.count)"
        )
        #expect(seeds.count >= 50, "generated seeds: \(seeds.count)")
    }
}
