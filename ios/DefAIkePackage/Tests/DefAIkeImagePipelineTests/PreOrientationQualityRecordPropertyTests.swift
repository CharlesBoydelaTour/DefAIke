import DefAIkeDomain
import CoreGraphics
import Foundation
import ImageIO
import PropertyBased
import Testing
import UniformTypeIdentifiers

@testable import DefAIkeImagePipeline

// Design Property 9: the pre-orientation quality record is exact.
//
// The design states it as: for any completely decoded image with positive
// pre-orientation dimensions, the Input Quality Record stores those original decoded
// width and height without orientation swapping, stores `min(width, height)` as the short
// edge, and preserves every recorded value plus Byte Preservation Status in a later
// failure snapshot.
//
// Quantified here as one property over every generated case, in three claims:
//
//   * unswapped — the recorded pair is the pair the decode produced, in that order.
//     Asserted against a decode of the same bytes taken outside the pipeline, and
//     sharpened on the containers whose declaration would exchange the axes: for those,
//     the recorded pair must not be the displayed pair, and the recorded width must not be
//     the displayed width. The declaration is read back out of the container first, so
//     "an orientation state that would transpose them" is a measured premise rather than a
//     name;
//   * exact short edge — `min` of the recorded pair, on the same case, including at the
//     439/440 neighbourhood the sub-440 abstention rule reads and on the square pairs
//     where both axes give the same answer;
//   * preserved — the same record and the Byte Preservation Status appear in the snapshot
//     of a failure that happens strictly later, with the failure produced by really
//     running preprocessing against a contract this build cannot apply rather than by
//     handing the ledger a fault it never earned.
//
// Every case also runs the record through a **completed** preprocessing on the same bytes
// and the same generated dimensions. That is the occurrence half: the preservation claim
// is about a run that got as far as preprocessing and then failed, and a harness whose
// preprocessing could never succeed would satisfy it for the wrong reason. It runs on
// every generated case rather than once, so a change that breaks the pipeline fails 100
// times instead of never.
//
// The transposing arms go one step further. When the bound action is
// `apply-declared-orientation`, the case renders the retained decode through the real
// renderer and asserts the rendered surface *is* the transposed pair — the axes really
// were exchanged downstream — while the record still holds the stored pair. Without that,
// "the record was not swapped" would also hold in a build where nothing swaps anything.
//
// ## What is real here and what is not
//
// The Input Validator and the Preprocessor are the real adapters over real Image I/O,
// Core Graphics, and Accelerate, and every container is real encoded bytes carrying a real
// declaration. Requirements 3.5, 3.6, and 3.14 are claims about what was actually decoded
// and what a failure actually reports, so a stand-in decode would leave nothing to
// measure. Nothing is doubled: there is no analyzer in this file, because inference is
// downstream of every claim here and its nonoccurrence is Property 8's.
//
// `InputQualityRecordTests` pins the record, the snapshot, and the retry isolation with
// one example each, and pins all eight orientations at one fixed 12-by-8 size. This file
// quantifies the same statement over generated dimensions, generated declarations
// including the absent and conflicting ones, generated ingest routes and preservation
// bases, and both orientation actions, and it is the only file here that asserts the
// recorded pair against an independent decode of the same bytes.
//
// Scope: the ordering of validation and inference is Property 8's, the totality of the
// metadata state-action map is Property 10's, and resize and crop geometry is Property
// 12's. Two contracts below are refused by the Preprocessor, and what this file asserts
// about them is only that the record survives the refusal — never which metadata state
// selects which action, and never that a particular working space is the right one to
// bind. The isolation between a failed session and the one that follows it is Property
// 11's; no assertion here reads a second session's slot.
//
// **No value in this file is an approved release value.** The Preprocessing Contract's
// metadata actions, geometry rules, and working space, and the Resource Budget's limits,
// are synthetic arguments that exist so a port taking a signed artifact can be called at
// all. Two are deliberately unapplicable, which is the point of the runs that use them.
// Nothing here may be copied into a shipping artifact.

extension Tag {
    /// Design Property 9.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property9PreOrientationQualityRecordIsExact: Self
}

@Suite(
    "Property 9: pre-orientation quality record is exact",
    .tags(.property9PreOrientationQualityRecordIsExact)
)
struct PreOrientationQualityRecordPropertyTests {
    /// Runs at the library default of 100 generated cases with shrinking, which is the
    /// minimum the design requires; `PropertyToolchainWiringTests` pins that default.
    ///
    /// **Validates: Requirements 3.5, 3.6, 3.14**
    @Test("The recorded pre-orientation pair is exact and survives a later failure")
    func recordedPairIsExactAndSurvivesALaterFailure() async {
        let witness = QualityRecordVariationWitness()

        await propertyCheck(input: QualityShape.generator) { shape in
            witness.record(shape)
            let scenario = QualityRecordScenario(shape: shape)

            guard let measured = await scenario.checkRecordIsTheExactDecodedPair() else { return }
            await scenario.checkRecordSurvivesALaterFailure(expecting: measured)
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - Orientation declaration catalogue

/// How one candidate container states — or fails to state — an orientation.
private enum OrientationDeclarationKind: Hashable, Sendable {
    /// A real JPEG declaring exactly one TIFF/EXIF orientation value.
    case exifJPEG(value: Int)
    /// A real JPEG whose top-level and TIFF declarations disagree, so it names two
    /// orientations and no single one can be applied.
    case conflictingJPEG(topLevel: Int, tiff: Int)
    /// An Image I/O PNG written with no properties at all.
    case encodedPNG
    /// A hand-assembled PNG with no EXIF block of any kind, so there is nothing to read
    /// rather than a value that happens to mean upright.
    case handAssembledPNG

    /// The bytes for this candidate at `width` by `height`, or `nil` when this host
    /// cannot produce them.
    func bytes(width: Int, height: Int) -> [UInt8]? {
        switch self {
        case .exifJPEG(let value):
            return DeclaringImageFixture.jpeg(orientation: value, width: width, height: height)
        case .conflictingJPEG(let topLevel, let tiff):
            return DeclaringImageFixture.encode(
                EncodedImageFixture.gradient(width: width, height: height),
                as: .jpeg,
                properties: [
                    kCGImagePropertyOrientation: topLevel,
                    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: tiff],
                ]
            )
        case .encodedPNG:
            return EncodedImageFixture.encode(
                EncodedImageFixture.gradient(width: width, height: height),
                as: .png
            )
        case .handAssembledPNG:
            return RawPNG.withoutColorChunks(width: width, height: height)
        }
    }

    var label: String {
        switch self {
        case .exifJPEG(let value): "jpeg declaring orientation \(value)"
        case .conflictingJPEG(let topLevel, let tiff): "jpeg declaring \(topLevel) and \(tiff)"
        case .encodedPNG: "encoded png declaring nothing"
        case .handAssembledPNG: "hand-assembled png with no exif block"
        }
    }
}

/// One container this host really produces, together with the orientation state it really
/// presents.
private struct OrientationArm: Hashable, Sendable {
    let kind: OrientationDeclarationKind

    /// The state ``ImageMetadataInspector`` observed for this container during discovery,
    /// and which every generated case re-checks before it asserts anything.
    let observedState: ImageMetadataState

    /// The single declared orientation, present only in the valid state.
    let declared: ExifOrientation?

    /// Whether applying this arm's declaration exchanges width and height.
    ///
    /// Read from the production type rather than restated, so the two cannot drift; the
    /// cases that use it also prove it against the real renderer.
    var exchangesAxes: Bool { declared?.exchangesAxes ?? false }

    /// Whether `apply-declared-orientation` is applicable to this arm at all.
    ///
    /// Only the valid state carries a declaration to apply; bound to any other state the
    /// action fails closed, which is correct behaviour and a different claim from this
    /// one.
    var permitsApplyingTheDeclaration: Bool { observedState == .valid }

    var label: String { "\(kind.label) → \(observedState.rawValue)" }
}

/// The orientation declarations this host can actually put into a container, discovered
/// rather than assumed.
///
/// Image I/O normalizes an out-of-range orientation to 1 while writing, and whether it
/// preserves two disagreeing declarations is a host detail, so a candidate is kept only
/// when the bytes it produced really present the intended state and really decode to the
/// probe's own pair. A candidate this host cannot express is dropped instead of being
/// replaced by a synthetic stand-in, because an orientation claim only means something
/// against a declaration a container really carries.
///
/// Computed once. Encoding and decoding a probe per generated case to answer the same
/// question 100 times would put host capability detection inside the measured property.
private enum OrientationCatalog {
    /// Probe dimensions. Deliberately non-square, so a candidate that silently swapped the
    /// axes while writing would fail discovery rather than be admitted.
    private static let probeWidth = 12
    private static let probeHeight = 8

    static let arms: [OrientationArm] = candidates.filter { candidate in
        guard let bytes = candidate.kind.bytes(width: probeWidth, height: probeHeight),
              let declarations = DeclaringImageFixture.declarations(of: bytes),
              let decoded = DeclaringImageFixture.decode(bytes),
              decoded.width == probeWidth,
              decoded.height == probeHeight
        else {
            return false
        }
        let observed = ImageMetadataInspector.observeOrientation(declarations)
        return observed.state == candidate.observedState && observed.declared == candidate.declared
    }

    /// The states the surviving arms present, which is what the witness holds the
    /// generator to.
    static let discoveredStates: Set<ImageMetadataState> = Set(arms.map(\.observedState))

    /// The transposing arms, which carry the sharpened half of the unswapped claim.
    static let transposingArms: [OrientationArm] = arms.filter(\.exchangesAxes)

    /// Everything worth trying, with the state each one is expected to present.
    private static var candidates: [OrientationArm] {
        var candidates: [OrientationArm] = ExifOrientation.allCases.map { orientation in
            OrientationArm(
                kind: .exifJPEG(value: orientation.rawValue),
                observedState: .valid,
                declared: orientation
            )
        }
        candidates += [
            OrientationArm(kind: .encodedPNG, observedState: .absent, declared: nil),
            OrientationArm(kind: .handAssembledPNG, observedState: .absent, declared: nil),
            OrientationArm(
                kind: .conflictingJPEG(topLevel: 1, tiff: 6),
                observedState: .malformed,
                declared: nil
            ),
            OrientationArm(
                kind: .conflictingJPEG(topLevel: 3, tiff: 8),
                observedState: .malformed,
                declared: nil
            ),
            // Integers outside 1 through 8 name no transform. Image I/O's own encoder
            // normalizes them while writing, so these are expected to be dropped on this
            // host; they are listed so the catalogue states what was tried.
            OrientationArm(kind: .exifJPEG(value: 0), observedState: .unsupported, declared: nil),
            OrientationArm(kind: .exifJPEG(value: 9), observedState: .unsupported, declared: nil),
        ]
        return candidates
    }
}

// MARK: - The later failure

/// Why the run that must preserve the record fails.
///
/// Both are contracts this build cannot apply to an input it has already accepted, which
/// is the situation Requirement 3.11 names and the one Requirement 3.14 then constrains:
/// the failure lands in preprocessing, strictly after the recording point, so a record
/// that did not survive it would be a record the presenter cannot report.
///
/// Neither refusal is about orientation. That is deliberate: the record has to survive a
/// failure that has nothing to do with the declaration it was recorded alongside.
private enum ContractRefusal: String, Hashable, Sendable, CaseIterable {
    /// A working color space outside the module's closed table, so no resolution exists.
    case workingSpaceUnresolvable
    /// A resolvable working space pinned to ICC bytes the resolved space does not carry.
    case workingSpaceProfileMismatch
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
/// A property whose input is one constant with a declaration swapped in asserts a handful
/// of examples a hundred times over, so every dimension the assertions depend on is
/// generated:
///
///   * the orientation arm, over every declaration this host can express, so the recorded
///     pair is checked under a transposing declaration, a non-transposing one, no
///     declaration at all, and — where the host allows it — two disagreeing ones;
///   * width and height independently, so a container is never square or a fixed size by
///     construction, portrait and landscape both occur, and the `min` in Requirement 3.6
///     is taken from each axis in turn rather than always from the same one;
///   * whether the contract applies the declared orientation, so the exchange really
///     happens downstream on the transposing arms;
///   * both ingest routes, because Requirement 3.5 applies to a selected item from either
///     one;
///   * the preservation basis, so the status the failure has to preserve varies;
///   * which unapplicable contract produces the later failure;
///   * which presentable Analysis Error the snapshot is additionally taken under;
///   * every synthetic identifier, from ``seed``.
///
/// ``QualityRecordVariationWitness`` checks after the run that this actually happened.
private struct QualityShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic session and artifact identifier, so the whole reference set
    /// varies together and stays coherent without a cross-reference table.
    ///
    /// Used only in identifier strings. No schema version is derived from it: a version
    /// whose every component can be zero can name the `0.0.0` development stand-in, which
    /// the artifact schema rejects, and the refusal would surface as a construction
    /// failure in an unrelated arm.
    let seed: Int

    let armIndex: Int

    /// Dimensions of the arm's encoded image.
    let width: Int
    let height: Int

    /// Whether the contract asks for the declared orientation to be applied. Honoured only
    /// on an arm that carries a declaration; every other arm ignores it, because binding
    /// it to a state with no declaration is a fail-closed refusal rather than this claim.
    let prefersApplyingOrientation: Bool

    let route: InputRoute
    let basisIndex: Int
    let refusalIndex: Int
    let presentableIndex: Int

    var arm: OrientationArm {
        OrientationCatalog.arms[armIndex % OrientationCatalog.arms.count]
    }

    var basis: PreservationBasis {
        PreservationBasis.allCases[basisIndex % PreservationBasis.allCases.count]
    }

    var refusal: ContractRefusal {
        ContractRefusal.allCases[refusalIndex % ContractRefusal.allCases.count]
    }

    /// The Analysis Error the snapshot is additionally taken under.
    var presentableFailure: (error: AnalysisError, stage: AnalysisStage) {
        Self.presentableFailures[presentableIndex % Self.presentableFailures.count]
    }

    /// The five failures Requirement 3.12 admits from validation and preprocessing, each
    /// paired with the stage that commits it. Requirement 3.14 applies to all of them.
    static let presentableFailures: [(error: AnalysisError, stage: AnalysisStage)] = [
        (.unsupportedMedia, .mediaClassification),
        (.unsupportedStaticFormat, .mediaClassification),
        (.decodingError, .inputValidation),
        (.resourceLimit, .inputValidation),
        (.preprocessingError, .preprocessing),
    ]

    /// The orientation action the coherent contract binds to the valid state.
    var orientationAction: OrientationAction {
        prefersApplyingOrientation && arm.permitsApplyingTheDeclaration
            ? .applyDeclaredOrientation
            : .ignoreDeclaredOrientation
    }

    var description: String {
        """
        seed \(seed), arm \(arm.label), \(width)x\(height), \
        action \(orientationAction.rawValue), \
        exchanges axes \(arm.exchangesAxes), route \(route.rawValue), \
        basis \(basis.rawValue), refusal \(refusal.rawValue), \
        snapshot under \(presentableFailure.error.rawValue)
        """
    }

    // MARK: Generators

    static var generator: Generator<QualityShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.int(in: 0...199),
            Gen.int(in: 8...48),
            Gen.int(in: 8...48),
            Gen.bool,
            Gen.bool,
            Gen.int(in: 0...199),
            Gen.int(in: 0...199),
            Gen.int(in: 0...199)
        )
        .map { raw in
            QualityShape(
                seed: raw.0,
                armIndex: raw.1,
                width: raw.2,
                height: raw.3,
                prefersApplyingOrientation: raw.4,
                route: raw.5 ? .photosPicker : .shareExtension,
                basisIndex: raw.6,
                refusalIndex: raw.7,
                presentableIndex: raw.8
            )
        }
        .eraseToAny()
    }
}

// MARK: - What was measured

/// The pair a decode outside the pipeline reported for the same bytes.
///
/// The reference the assertions compare against, rather than the generated width and
/// height. An encoder that adjusted a dimension would otherwise move what "exact" means
/// and every assertion would still pass while testing something else.
private struct MeasuredDecode {
    let width: Int
    let height: Int

    var shortEdge: Int { min(width, height) }
    var isSquare: Bool { width == height }

    /// The pair the declaration would produce if it were applied.
    var displayed: (width: Int, height: Int) { (height, width) }

    /// The record this decode must produce.
    var expectedRecord: InputQualityRecord? {
        InputQualityRecord(
            decodedWidthBeforeOrientation: width,
            decodedHeightBeforeOrientation: height
        )
    }
}

// MARK: - The pipeline under test

/// The real validator and the real preprocessor over one session's stores and ledger.
///
/// Both adapters are real because both requirements under test are about what they
/// actually do: what the decode produced, and what a refusal after that decode still
/// reports. There is no analyzer, because nothing here is a claim about inference.
///
/// Built per run so two runs never share a store or a ledger, and so the identifiers a
/// failure reports name the case that produced it.
private struct QualityPipeline {
    let store = InMemoryEncodedAssetStore()
    let decodedImages = DecodedImageStore()
    let modelInputs = PreparedModelInputStore()
    let quality = InputQualityLedger()
    let contract: PreprocessingContract
    let budget: ResourceBudget
    private let validator: ImageIOInputValidator
    private let preprocessor: ContractImagePreprocessor

    init(contract: PreprocessingContract, budget: ResourceBudget) {
        self.contract = contract
        self.budget = budget
        self.validator = ImageIOInputValidator(
            encodedAssets: store,
            decodedImages: decodedImages,
            quality: quality
        )
        self.preprocessor = ContractImagePreprocessor(
            encodedAssets: store,
            decodedImages: decodedImages,
            modelInputs: modelInputs
        )
    }

    /// Validates `asset`. Returns rather than throws, so the caller records an issue
    /// instead of letting a fault escape the property body.
    func validate(_ asset: ImportedEncodedAsset) async -> Result<ValidatedImage, AnalysisFault> {
        do {
            return .success(try await validator.validate(asset, contract: contract, budget: budget))
        } catch {
            return .failure(error)
        }
    }

    func preprocess(_ image: ValidatedImage) async -> Result<ModelImageInput, AnalysisFault> {
        do {
            return .success(try await preprocessor.prepare(image, contract: contract, budget: budget))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Scenario

/// One generated shape, the container it produces, and the two runs it performs.
private struct QualityRecordScenario {
    let shape: QualityShape

    // MARK: The recording run

    /// Requirements 3.5 and 3.6: the record is the decoded pair, unswapped, with `min` of
    /// that pair as the short edge — and preprocessing completes on the same input.
    ///
    /// Returns what the decode measured so the preservation run can hold the snapshot to
    /// the identical pair, or `nil` when the case could not be set up at all.
    func checkRecordIsTheExactDecodedPair() async -> MeasuredDecode? {
        guard !OrientationCatalog.arms.isEmpty else {
            Issue.record("this host can express no orientation declaration [\(shape)]")
            return nil
        }
        guard let bytes = shape.arm.kind.bytes(width: shape.width, height: shape.height) else {
            Issue.record("this host could not produce \(shape.arm.label) [\(shape)]")
            return nil
        }
        guard let measured = measureOutsideThePipeline(bytes) else { return nil }
        guard checkTheContainerReallyCarriesTheDeclaration(bytes) else { return nil }

        let pipeline = QualityPipeline(
            contract: coherentContract(),
            budget: ResourceFixture.budget(id: "budget-p9-record-\(shape.seed)")
        )
        guard let asset = await asset(bytes, in: pipeline, suffix: "record") else { return nil }

        let outcome = await pipeline.validate(asset)
        guard case .success(let validated) = outcome else {
            Issue.record(
                """
                a real \(shape.arm.label) container must validate; \
                got \(outcome) [\(shape)]
                """
            )
            return nil
        }

        // The decode the pipeline performed is the decode measured above. Without this the
        // assertions below would compare the record against a pair nobody produced.
        #expect(validated.dimensions.width == measured.width, "[\(shape)]")
        #expect(validated.dimensions.height == measured.height, "[\(shape)]")

        guard let record = await pipeline.quality.qualityRecord(for: asset.sessionID) else {
            Issue.record("a completed decode must have a quality record [\(shape)]")
            return nil
        }
        checkRecordMatches(measured, record: record, from: "the recording run")

        // The ledger's record and the validated image's derived record are one value, so
        // the presenter and the Calibration Policy cannot read different measurements.
        #expect(record == validated.quality, "[\(shape)]")
        // Empty until an approved Calibration Policy defines an additional quality feature
        // and binds it to release-validation evidence, so the record carries measurements
        // and nothing else.
        #expect(record.validatedFeatures.isEmpty, "[\(shape)]")

        await checkTheDeclarationWouldHaveExchangedTheAxes(validated, pipeline: pipeline)
        await checkPreprocessingCompletes(validated, pipeline: pipeline, record: record)
        return measured
    }

    /// The pair a decode of the same bytes reports outside the pipeline.
    private func measureOutsideThePipeline(_ bytes: [UInt8]) -> MeasuredDecode? {
        guard let decoded = DeclaringImageFixture.decode(bytes) else {
            Issue.record("this host could not decode \(shape.arm.label) [\(shape)]")
            return nil
        }
        guard decoded.width > 0, decoded.height > 0 else {
            Issue.record("a decode must report positive dimensions [\(shape)]")
            return nil
        }
        return MeasuredDecode(width: decoded.width, height: decoded.height)
    }

    /// The container really presents the state this arm was discovered with.
    ///
    /// The premise of the whole property. Were the declaration absent from the generated
    /// bytes, every assertion below would hold against an untagged image and prove
    /// nothing about orientation.
    private func checkTheContainerReallyCarriesTheDeclaration(_ bytes: [UInt8]) -> Bool {
        guard let declarations = DeclaringImageFixture.declarations(of: bytes) else {
            Issue.record("Image I/O read no declarations from \(shape.arm.label) [\(shape)]")
            return false
        }
        let observed = ImageMetadataInspector.observeOrientation(declarations)
        guard observed.state == shape.arm.observedState,
              observed.declared == shape.arm.declared
        else {
            Issue.record(
                """
                \(shape.arm.label) presented \(observed.state.rawValue) / \
                \(observed.declared.map { "\($0.rawValue)" } ?? "none") \
                at \(shape.width)x\(shape.height) [\(shape)]
                """
            )
            return false
        }
        return true
    }

    /// Requirement 3.5's "before orientation metadata is applied", asserted against the
    /// pair a record must hold.
    private func checkRecordMatches(
        _ measured: MeasuredDecode,
        record: InputQualityRecord,
        from source: String
    ) {
        // Requirement 3.5: the decoded pair, in the order it was decoded.
        #expect(
            record.decodedWidthBeforeOrientation == measured.width,
            "\(source) recorded the wrong width [\(shape)]"
        )
        #expect(
            record.decodedHeightBeforeOrientation == measured.height,
            "\(source) recorded the wrong height [\(shape)]"
        )
        // Requirement 3.6: exactly the lesser of the recorded pair. Taken from whichever
        // axis is smaller, which is why width and height are generated independently: a
        // short edge read from a fixed axis would pass on half the cases.
        #expect(
            record.shortEdgeBeforeOrientation == measured.shortEdge,
            "\(source) recorded the wrong short edge [\(shape)]"
        )
        // The record is not normalized to one orientation. A record that sorted the pair,
        // or forced it to landscape, would report the same width for a portrait and a
        // landscape decode and "before orientation is applied" would be unobservable.
        let recordedIsPortrait =
            (record.decodedWidthBeforeOrientation ?? 0) < (record.decodedHeightBeforeOrientation ?? 0)
        #expect(
            recordedIsPortrait == (measured.width < measured.height),
            "\(source) changed which axis is the longer one [\(shape)]"
        )

        // The sharpened half: a declaration that would exchange the axes did not. Vacuous
        // on a square decode, which is why the witness holds the generator to producing
        // non-square pairs.
        guard shape.arm.exchangesAxes, !measured.isSquare else { return }
        #expect(
            record.decodedWidthBeforeOrientation != measured.displayed.width,
            """
            \(source) recorded the displayed width \(measured.displayed.width) \
            rather than the decoded width \(measured.width) [\(shape)]
            """
        )
        #expect(
            record.decodedHeightBeforeOrientation != measured.displayed.height,
            "\(source) recorded the displayed height [\(shape)]"
        )
    }

    /// The declaration this case calls transposing really does transpose, in this build,
    /// on these pixels.
    ///
    /// Only checkable where the contract asks for the declaration to be applied: with
    /// `ignore-declared-orientation` bound, nothing is supposed to move. Run against the
    /// real renderer over the retained decode, so "the record was not swapped" is
    /// distinguished from "nothing in this build swaps anything".
    private func checkTheDeclarationWouldHaveExchangedTheAxes(
        _ validated: ValidatedImage,
        pipeline: QualityPipeline
    ) async {
        guard shape.arm.exchangesAxes, shape.orientationAction == .applyDeclaredOrientation else {
            return
        }
        guard let decoded = await pipeline.decodedImages.image(for: validated.decodedImage) else {
            Issue.record("an accepted decode must be retained [\(shape)]")
            return
        }
        guard let declarations = DeclaringImageFixture.declarations(
            of: (try? await pipeline.store.read(validated.source.storageKey)) ?? []
        ) else {
            Issue.record("the retained bytes must still carry their declarations [\(shape)]")
            return
        }
        let metadata = ImageMetadataInspector.observe(
            properties: declarations,
            image: decoded.image
        )
        let rendered: PixelSurface
        do {
            rendered = try WorkingSpaceRGBRenderer(
                contract: pipeline.contract,
                budget: pipeline.budget
            ).render(decoded, metadata: metadata)
        } catch {
            Issue.record("applying a valid declared orientation must render: \(error) [\(shape)]")
            return
        }
        #expect(
            rendered.dimensions.width == decoded.dimensions.height,
            "applying \(shape.arm.label) must exchange the axes [\(shape)]"
        )
        #expect(
            rendered.dimensions.height == decoded.dimensions.width,
            "applying \(shape.arm.label) must exchange the axes [\(shape)]"
        )
        // And the record still holds the stored pair, taken after the exchange has been
        // demonstrated on the very pixels this session decoded.
        let record = await pipeline.quality.qualityRecord(for: validated.sessionID)
        #expect(record?.decodedWidthBeforeOrientation == decoded.dimensions.width, "[\(shape)]")
        #expect(record?.decodedHeightBeforeOrientation == decoded.dimensions.height, "[\(shape)]")
    }

    /// The occurrence half: preprocessing completes on this input, and completing it does
    /// not disturb the record.
    ///
    /// The preservation claim below is about a run that reached preprocessing and then
    /// failed. A harness whose preprocessing could never succeed would satisfy it while
    /// proving nothing, so every case shows the same bytes and the same dimensions going
    /// all the way through.
    private func checkPreprocessingCompletes(
        _ validated: ValidatedImage,
        pipeline: QualityPipeline,
        record: InputQualityRecord
    ) async {
        let prepared = await pipeline.preprocess(validated)
        guard case .success = prepared else {
            Issue.record(
                """
                a coherent contract must prepare \(shape.arm.label) under \
                \(shape.orientationAction.rawValue); got \(prepared) [\(shape)]
                """
            )
            return
        }
        #expect(await pipeline.modelInputs.retainedInputCount == 1, "[\(shape)]")
        // Preprocessing is not a recording step. A record that changed here would mean the
        // pre-orientation measurement had been redefined by a later stage.
        #expect(
            await pipeline.quality.qualityRecord(for: validated.sessionID) == record,
            "preprocessing must not redefine the record [\(shape)]"
        )
    }

    // MARK: The preservation run

    /// Requirement 3.14: a failure strictly later than the recording point preserves every
    /// recorded dimension and the Byte Preservation Status.
    ///
    /// The failure is earned rather than asserted: the same bytes are validated under a
    /// contract this build cannot apply, so the decode is accepted and recorded and then
    /// preprocessing really refuses it. Handing the ledger a fault no run produced would
    /// test the ledger's arithmetic and not the requirement.
    func checkRecordSurvivesALaterFailure(expecting measured: MeasuredDecode) async {
        guard let bytes = shape.arm.kind.bytes(width: shape.width, height: shape.height) else {
            Issue.record("this host could not produce \(shape.arm.label) [\(shape)]")
            return
        }
        let pipeline = QualityPipeline(
            contract: unapplicableContract(),
            budget: ResourceFixture.budget(id: "budget-p9-failure-\(shape.seed)")
        )
        guard let asset = await asset(bytes, in: pipeline, suffix: "failure") else { return }

        let accepted = await pipeline.validate(asset)
        guard case .success(let validated) = accepted else {
            Issue.record(
                """
                an unapplicable working space must not fail validation; \
                got \(accepted) [\(shape)]
                """
            )
            return
        }
        guard let record = await pipeline.quality.qualityRecord(for: asset.sessionID) else {
            Issue.record("a completed decode must have a quality record [\(shape)]")
            return
        }
        // The recording point was reached, and it recorded the same pair the reference
        // decode measured. This is the "before the failure" half of Requirement 3.14.
        checkRecordMatches(measured, record: record, from: "the preservation run")
        #expect(record == measured.expectedRecord, "[\(shape)]")

        let prepared = await pipeline.preprocess(validated)
        guard case .failure(let fault) = prepared else {
            Issue.record(
                """
                \(shape.refusal.rawValue) must refuse an accepted decode; \
                got \(prepared) [\(shape)]
                """
            )
            return
        }
        // The failure is the one Requirement 3.11 fixes, at the stage that found it, and it
        // happened after the decode was accepted and recorded — which is what makes it a
        // *later* failure rather than a refusal that preceded the measurement.
        #expect(fault == .analysis(.preprocessingError, stage: .preprocessing), "[\(shape)]")
        #expect(await pipeline.decodedImages.retainedImageCount == 1, "[\(shape)]")
        #expect(await pipeline.modelInputs.retainedInputCount == 0, "[\(shape)]")

        await checkSnapshotPreserves(record, in: pipeline, for: asset, fault: fault)
        await checkEveryPresentableFailurePreserves(record, in: pipeline, for: asset)
    }

    /// The snapshot of the failure that really happened carries the record and the status.
    private func checkSnapshotPreserves(
        _ record: InputQualityRecord,
        in pipeline: QualityPipeline,
        for asset: ImportedEncodedAsset,
        fault: AnalysisFault
    ) async {
        guard let snapshot = await pipeline.quality.failureSnapshot(
            for: asset.sessionID,
            fault: fault
        ) else {
            Issue.record("a presentable failure must produce a snapshot [\(shape)]")
            return
        }
        #expect(snapshot.sessionID == asset.sessionID, "[\(shape)]")
        #expect(snapshot.error == .preprocessingError, "[\(shape)]")
        #expect(snapshot.stage == .preprocessing, "[\(shape)]")
        // Preserved, not re-derived: the snapshot and the live record are the same value,
        // so the presenter cannot report a measurement the validator never took.
        #expect(
            snapshot.inputQuality == record,
            "the failure must preserve the record it was taken after [\(shape)]"
        )
        // As recorded by ingest, so no failure reports a status the basis does not
        // support — in particular none may report original bytes for bytes whose history
        // was never established.
        #expect(snapshot.bytePreservationStatus == shape.basis.mostConservativeStatus, "[\(shape)]")
        #expect(shape.basis.supports(shape.basis.mostConservativeStatus), "[\(shape)]")
        // No evidence rides along. `AnalysisFailureSnapshot` has no field for a pixel
        // label, a provenance state, or a combined summary, so a preserved measurement can
        // never be read as a partial verdict.
        #expect(snapshot.inputQuality?.validatedFeatures.isEmpty == true, "[\(shape)]")
    }

    /// Requirement 3.14 names no particular error, so the same record has to survive every
    /// one the validation and preprocessing stages can present.
    ///
    /// The generated choice is asserted by name in the message; all five are checked, so a
    /// category-dependent snapshot could not hide behind a lucky draw.
    private func checkEveryPresentableFailurePreserves(
        _ record: InputQualityRecord,
        in pipeline: QualityPipeline,
        for asset: ImportedEncodedAsset
    ) async {
        for failure in QualityShape.presentableFailures {
            guard let snapshot = await pipeline.quality.failureSnapshot(
                for: asset.sessionID,
                fault: .analysis(failure.error, stage: failure.stage)
            ) else {
                Issue.record("\(failure.error.rawValue) must produce a snapshot [\(shape)]")
                continue
            }
            #expect(
                snapshot.inputQuality == record,
                "\(failure.error.rawValue) must preserve the record [\(shape)]"
            )
            #expect(
                snapshot.bytePreservationStatus == shape.basis.mostConservativeStatus,
                "\(failure.error.rawValue) must preserve the byte status [\(shape)]"
            )
            #expect(snapshot.error == failure.error, "[\(shape)]")
        }
        // Repeated reads return the same value: taking a snapshot does not consume the
        // measurement, so the generated failure and the loop above cannot have raced to
        // clear it.
        let generated = shape.presentableFailure
        let repeated = await pipeline.quality.failureSnapshot(
            for: asset.sessionID,
            fault: .analysis(generated.error, stage: generated.stage)
        )
        #expect(repeated?.inputQuality == record, "[\(shape)]")
    }

    // MARK: Sessions

    private func asset(
        _ bytes: [UInt8],
        in pipeline: QualityPipeline,
        suffix: String
    ) async -> ImportedEncodedAsset? {
        do {
            return try await IngestFixture.asset(
                bytes: bytes,
                in: pipeline.store,
                sessionID: session(suffix),
                route: shape.route,
                preservationBasis: shape.basis
            )
        } catch {
            Issue.record("building the \(suffix) session failed: \(error) [\(shape)]")
            return nil
        }
    }

    private func session(_ suffix: String) -> AnalysisSessionID {
        guard let id = AnalysisSessionID("session-p9-\(shape.seed)-\(suffix)") else {
            preconditionFailure("a generated session identifier must be canonical")
        }
        return id
    }

    // MARK: Contracts

    /// A contract this build can apply, binding the case's orientation action.
    ///
    /// Every state other than the valid one keeps `ignore-declared-orientation`, which is
    /// applicable everywhere: applying a declaration an input does not carry is a
    /// fail-closed refusal, and an arm refused there would never reach the recording point
    /// this property is about.
    private func coherentContract() -> PreprocessingContract {
        PreprocessingFixture.contract(
            id: "preprocessing-p9-\(shape.seed)",
            orientationRules: PreprocessingFixture.rules([
                ImageMetadataState.valid: shape.orientationAction,
                .absent: .ignoreDeclaredOrientation,
                .malformed: .ignoreDeclaredOrientation,
                .unsupported: .ignoreDeclaredOrientation,
            ])
        )
    }

    /// A contract that validates and then cannot be applied.
    ///
    /// Validation reads only the contract's identity and supported containers, so both
    /// refusals stay applicable through the decode and land in the Preprocessor — which is
    /// exactly where a failure has to land for Requirement 3.14's "recorded before the
    /// failure" to have any content.
    private func unapplicableContract() -> PreprocessingContract {
        switch shape.refusal {
        case .workingSpaceUnresolvable:
            // A name outside the module's closed working-space table. Not a near miss of a
            // real one: the point is that no resolution exists, so nothing can be
            // substituted for it.
            return PreprocessingFixture.contract(
                id: "preprocessing-p9-refused-\(shape.seed)",
                workingSpace: "synthetic-unresolvable-working-space-\(shape.seed)"
            )
        case .workingSpaceProfileMismatch:
            // A resolvable space pinned to ICC bytes it does not carry.
            return PreprocessingFixture.contract(
                id: "preprocessing-p9-refused-\(shape.seed)",
                workingSpaceProfileDigest: Fixture.digest(
                    of: Array("not-the-profile-bytes-\(shape.seed)".utf8)
                )
            )
        }
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator actually produced, so the property cannot pass by generating
/// one fixed container a hundred times.
///
/// It also proves the run happened at all. `propertyCheck` discards an error thrown by its
/// body, so a body that failed before its first assertion — a construction that threw, a
/// generator that produced nothing usable — would report a passing test in milliseconds
/// with every arm skipped. A witness that counts cases outside the body is the only thing
/// that catches that.
///
/// The thresholds are below what 100 uniform draws produce, so this witnesses variation
/// rather than pinning a distribution. Arm coverage is asserted as a count rather than as
/// set equality: with a dozen arms drawn uniformly, missing one happens often enough that
/// an exact assertion would train a reader to ignore it. The claims the property would be
/// vacuous without — a transposing declaration, a non-square pair, both orientations of
/// that pair — are asserted directly.
private final class QualityRecordVariationWitness: @unchecked Sendable {
    /// How many arms must appear. Three may be missing before this fails, which no uniform
    /// 100-draw run over the discovered catalogue reaches in practice.
    private static var minimumArmCount: Int { max(1, OrientationCatalog.arms.count - 3) }

    /// How many distinct transposing declarations must appear. Four exist; requiring two
    /// leaves enormous headroom while still failing a generator that stopped producing
    /// them.
    private static var minimumTransposingArmCount: Int {
        min(2, OrientationCatalog.transposingArms.count)
    }

    private let lock = NSLock()
    private var arms = Set<OrientationArm>()
    private var transposingArms = Set<OrientationArm>()
    private var states = Set<ImageMetadataState>()
    private var actions = Set<OrientationAction>()
    private var dimensions = Set<Int>()
    private var routes = Set<InputRoute>()
    private var bases = Set<PreservationBasis>()
    private var refusals = Set<ContractRefusal>()
    private var presentableErrors = Set<AnalysisError>()
    private var seeds = Set<Int>()
    private var portraitCases = 0
    private var landscapeCases = 0
    private var transposingNonSquareCases = 0
    private var cases = 0

    func record(_ shape: QualityShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        arms.insert(shape.arm)
        if shape.arm.exchangesAxes {
            transposingArms.insert(shape.arm)
            if shape.width != shape.height { transposingNonSquareCases += 1 }
        }
        states.insert(shape.arm.observedState)
        actions.insert(shape.orientationAction)
        dimensions.formUnion([shape.width, shape.height])
        routes.insert(shape.route)
        bases.insert(shape.basis)
        refusals.insert(shape.refusal)
        presentableErrors.insert(shape.presentableFailure.error)
        seeds.insert(shape.seed)
        if shape.width < shape.height { portraitCases += 1 }
        if shape.width > shape.height { landscapeCases += 1 }
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases")
        #expect(
            arms.count >= Self.minimumArmCount,
            "generated arms: \(arms.map(\.label).sorted())"
        )
        // Every state the host can express has to appear, or the record is only shown to be
        // exact for the declarations that happened to be drawn.
        #expect(
            states == OrientationCatalog.discoveredStates,
            "generated orientation states: \(states.map(\.rawValue).sorted())"
        )
        // The premise of the sharpened claim: a declaration that would exchange the axes
        // was really generated, on a pair where the exchange is observable.
        #expect(
            transposingArms.count >= Self.minimumTransposingArmCount,
            "generated transposing declarations: \(transposingArms.map(\.label).sorted())"
        )
        #expect(
            transposingNonSquareCases >= 10,
            "transposing cases on a non-square pair: \(transposingNonSquareCases)"
        )
        // Both actions, so the exchange is demonstrated downstream on some cases and
        // suppressed on others while the record stays the same either way.
        #expect(
            actions == Set(OrientationAction.allCases.filter { $0 != .rejectAsPreprocessingError }),
            "generated orientation actions: \(actions.map(\.rawValue).sorted())"
        )
        // Requirement 3.6's `min` is taken from each axis in turn rather than always from
        // the same one.
        #expect(portraitCases >= 20, "portrait cases: \(portraitCases)")
        #expect(landscapeCases >= 20, "landscape cases: \(landscapeCases)")
        #expect(dimensions.count >= 20, "generated dimensions: \(dimensions.count)")
        #expect(routes == Set(InputRoute.allCases), "both ingest routes are generated")
        #expect(
            bases == Set(PreservationBasis.allCases),
            "generated preservation bases: \(bases.map(\.rawValue).sorted())"
        )
        #expect(
            refusals == Set(ContractRefusal.allCases),
            "generated refusals: \(refusals.map(\.rawValue).sorted())"
        )
        #expect(
            presentableErrors.count == QualityShape.presentableFailures.count,
            "generated snapshot errors: \(presentableErrors.map(\.rawValue).sorted())"
        )
        #expect(seeds.count >= 50, "generated seeds: \(seeds.count)")
    }
}
