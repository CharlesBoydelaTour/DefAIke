import DefAIkeDomain
import Foundation
import PropertyBased
import Testing
import UniformTypeIdentifiers

@testable import DefAIkeImagePipeline

// Design Property 3: unsupported input classification and short-circuit.
//
// The design states it as: for any input descriptor/container, animated media, video,
// or audio maps only to `unsupported-media`, and any nonanimated static container
// outside JPEG, PNG, and HEIC/HEIF maps only to `unsupported-static-format`; either
// result terminates before preprocessing, provenance, inference, calibration, or
// evidence construction.
//
// Quantified here as one property with two halves over every generated container:
//
//   * classification — the container's actual media family decides the outcome, and the
//     two unsupported errors are exact rather than interchangeable: an animated, video,
//     or audio container never produces `unsupported-static-format`, an unsupported
//     nonanimated still image never produces `unsupported-media`, and a container that
//     is in neither category produces neither error;
//   * short-circuit — when either unsupported error is produced, preprocessing,
//     provenance validation, inference, calibration, and report construction each ran
//     exactly zero times and no Evidence Report exists.
//
// Every case also runs a **control**: one real supported container through the same
// pipeline, asserting that all five downstream stages ran and a report was built. The
// nonoccurrence half is the kind of claim that passes when nothing happens for the wrong
// reason, so the control is what proves the recorder would have seen a call had one been
// made. It runs on every generated case rather than in a separate test, so a change that
// silently disconnects a stage fails 100 times instead of once.
//
// `ContainerClassificationTests` pins individual containers with one example each, and
// `InputValidationTests` pins the decode outcomes. This file quantifies the statement
// over generated containers, dimensions, frame counts, routes, provider hints, and
// preservation bases, and it is the only file here that asserts what happens *after*
// classification refuses an input.
//
// Scope: Properties 8, 9, 10, and 12 (complete validation before inference, the
// pre-orientation quality record, total metadata handling, and resize geometry) belong to
// their own tasks and files. `resource-limit` and the decode failures are asserted here
// only to the extent that they are *not* one of the two unsupported errors.
//
// **No value in this file is an approved release value.** The Preprocessing Contract, the
// Resource Budget, the Provenance Policy, the Calibration Policy, and the session binding
// are synthetic arguments that exist so a port taking a signed artifact can be called at
// all. Every downstream stage is a recording double; none of them decides anything.

extension Tag {
    /// Design Property 3.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property3UnsupportedInputShortCircuit: Self
}

@Suite(
    "Property 3: unsupported input classification and short-circuit",
    .tags(.property3UnsupportedInputShortCircuit)
)
struct UnsupportedInputShortCircuitPropertyTests {
    /// Runs at the library default of 100 generated cases with shrinking, which is the
    /// minimum the design requires; `PropertyToolchainWiringTests` pins that default.
    ///
    /// **Validates: Requirements 1.11, 1.12, 1.13, 1.14, 2.15, 2.16**
    @Test("Unsupported containers classify exactly and reach no evidence stage")
    func unsupportedContainersClassifyExactlyAndShortCircuit() async {
        let witness = ShortCircuitVariationWitness()

        await propertyCheck(input: ContainerShape.generator) { shape in
            witness.record(shape)
            let scenario = ShortCircuitScenario(shape: shape)

            await scenario.checkGeneratedContainerClassifiesAndShortCircuits()
            await scenario.checkSupportedControlReachesEveryStage()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - Host encoder inventory

/// The containers this host can actually produce.
///
/// Content sniffing only means something against real encoded bytes, so a family whose
/// encoder is missing is dropped from the generator rather than replaced by a synthetic
/// stand-in. HEIF has no Image I/O encoder even where HEIC does, which is why the
/// supported set is discovered instead of assumed.
///
/// Computed once. Encoding a probe image per generated case to answer the same question
/// 100 times would put host capability detection inside the measured property.
private enum HostContainers {
    /// Supported single-frame containers, paired with the classification each must reach.
    static let supported: [(identifier: String, container: StaticContainer)] = [
        ("public.jpeg", .jpeg),
        ("public.png", .png),
        ("public.heic", .heic),
        ("public.heif", .heif),
    ].filter { canEncode($0.0) }

    /// Containers a real multi-frame image can be encoded into.
    static let animatable: [String] = [
        "com.compuserve.gif",
        "public.png",
        "public.heics",
    ].filter { canEncode($0) }

    /// Real single-frame still-image containers outside the Version 1 supported set.
    static let unsupportedStill: [String] = [
        "public.tiff",
        "com.microsoft.bmp",
        "com.compuserve.gif",
    ].filter { canEncode($0) }

    private static func canEncode(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return EncodedImageFixture.canEncode(type)
    }
}

// MARK: - Generated shape

/// The media family a generated container actually belongs to.
///
/// This is the ground truth the requirements are written against — "animated media,
/// video, or audio", "a non-animated static image in a format other than JPEG, PNG, or
/// HEIC/HEIF" — not a restatement of how ``ContainerClassifier`` decides. The expected
/// outcome is read off the family, so the property compares the classifier against the
/// requirement rather than against itself.
private enum MediaFamily: String, Hashable, Sendable, CaseIterable {
    /// A real single-frame JPEG, PNG, HEIC, or HEIF.
    case supportedStatic
    /// A real multi-frame image: an animated GIF, an APNG, a HEIC image sequence.
    case animatedImage
    /// A video container.
    case videoContainer
    /// An audio container.
    case audioContainer
    /// A single-frame still-image container outside the supported set.
    case unsupportedStillImage
    /// Content that is not a readable container of any family.
    case unreadableContainer

    /// The single Analysis Error a container of this family must produce, or `nil` when
    /// the container is analyzable.
    ///
    /// ``unreadableContainer`` is `nil` here because Requirements 1.11 through 1.14 do
    /// not assign it either unsupported error; what the property asserts for it is that
    /// it produces *neither*, which ``ShortCircuitScenario`` handles separately.
    var requiredError: AnalysisError? {
        switch self {
        case .supportedStatic, .unreadableContainer: nil
        case .animatedImage, .videoContainer, .audioContainer: .unsupportedMedia
        case .unsupportedStillImage: .unsupportedStaticFormat
        }
    }

    /// Whether Requirements 1.12 and 1.14 require this family to stop before evidence
    /// work.
    var mustShortCircuit: Bool { requiredError != nil }
}

/// How one generated container's bytes are produced.
///
/// Real encoded content wherever an encoder exists. The header-only bodies are the
/// families Image I/O does not read at all, where the content signature table is the
/// authority and decides inside its 32-byte window: a header with nothing behind it is
/// the whole input that table was written for, and using one proves the classification
/// was reached before any decode (Requirement 1.11's "before preprocessing").
private struct ContainerBody: Sendable {
    enum Content: Sendable {
        /// Encode one frame into the named type.
        case singleFrame(typeIdentifier: String)
        /// Encode `frameCount` frames into the named type.
        case multiFrame(typeIdentifier: String)
        /// Use these leading bytes verbatim.
        case headerOnly([UInt8])
        /// A real one-page PDF, which Image I/O opens and reports a page count for.
        case pdfDocument
        /// The leading fraction of a real JPEG.
        case truncatedJPEG(keptFraction: Double)
    }

    /// Names the family member in a failure message. Not a file name, and never an input
    /// to a classification.
    let label: String
    let content: Content
}

/// Every container the generator can produce, indexed by family.
///
/// Each list is nonempty for every family the host supports, and the generator selects
/// within a family by modulus, so a family is exercised across all of its members over
/// 100 cases instead of collapsing onto one.
private enum ContainerCatalog {
    static let supported: [ContainerBody] = HostContainers.supported.map {
        ContainerBody(label: $0.identifier, content: .singleFrame(typeIdentifier: $0.identifier))
    }

    /// Real multi-frame images, always encoded with more than one frame.
    ///
    /// Real content, not a brand that names animation. An `ftyp hevc` header with nothing
    /// behind it is deliberately not here: the classifier's animation signal is the
    /// container's actual image count, and a header carries none, so such a header is
    /// reported by its format rather than as media. Adding it to this family would assert
    /// an animation finding that the bytes do not contain.
    static let animated: [ContainerBody] = HostContainers.animatable.map {
        ContainerBody(label: "animated \($0)", content: .multiFrame(typeIdentifier: $0))
    }

    /// Video containers, as their leading bytes.
    ///
    /// Image I/O reports nothing for any of these, so without content signatures a movie
    /// and a buffer of random bytes would produce the same answer and Requirement 1.11
    /// could not be met.
    static let video: [ContainerBody] = [
        ContainerBody(label: "ftyp qt", content: .headerOnly(EncodedImageFixture.isoBaseMedia(brand: "qt  "))),
        ContainerBody(label: "ftyp isom", content: .headerOnly(EncodedImageFixture.isoBaseMedia(brand: "isom"))),
        ContainerBody(label: "ftyp mp42", content: .headerOnly(EncodedImageFixture.isoBaseMedia(brand: "mp42"))),
        ContainerBody(label: "ftyp 3gp5", content: .headerOnly(EncodedImageFixture.isoBaseMedia(brand: "3gp5"))),
        ContainerBody(label: "ftyp 3g2a", content: .headerOnly(EncodedImageFixture.isoBaseMedia(brand: "3g2a"))),
        ContainerBody(label: "ftyp M4V", content: .headerOnly(EncodedImageFixture.isoBaseMedia(brand: "M4V "))),
        ContainerBody(label: "riff AVI", content: .headerOnly(EncodedImageFixture.riff(formType: "AVI "))),
        ContainerBody(label: "ebml", content: .headerOnly(EncodedImageFixture.ebmlHeader)),
        ContainerBody(label: "asf", content: .headerOnly(MediaHeaderFixture.advancedSystemsFormat)),
        ContainerBody(label: "mpeg program stream", content: .headerOnly(MediaHeaderFixture.mpegProgramStream)),
        ContainerBody(label: "mpeg sequence", content: .headerOnly(MediaHeaderFixture.mpegSequence)),
        ContainerBody(label: "flash video", content: .headerOnly(MediaHeaderFixture.flashVideo)),
    ]

    static let audio: [ContainerBody] = [
        ContainerBody(label: "riff WAVE", content: .headerOnly(EncodedImageFixture.riff(formType: "WAVE"))),
        ContainerBody(label: "ftyp M4A", content: .headerOnly(EncodedImageFixture.isoBaseMedia(brand: "M4A "))),
        ContainerBody(label: "mp3 frame sync", content: .headerOnly(EncodedImageFixture.mp3Header)),
        ContainerBody(label: "id3", content: .headerOnly(EncodedImageFixture.id3Header)),
        ContainerBody(label: "flac", content: .headerOnly(MediaHeaderFixture.flac)),
        ContainerBody(label: "ogg", content: .headerOnly(MediaHeaderFixture.ogg)),
        ContainerBody(label: "aiff", content: .headerOnly(MediaHeaderFixture.interchangeForm("AIFF"))),
        ContainerBody(label: "aifc", content: .headerOnly(MediaHeaderFixture.interchangeForm("AIFC"))),
    ]

    /// Unsupported nonanimated still containers.
    ///
    /// The header-only members are formats the requirements place outside the supported
    /// set whether or not this build happens to carry a decoder for them: AVIF shares its
    /// declared parent with HEIC, and accepting a format because no decoder disagreed
    /// would widen the Version 1 set past what calibration and parity evidence cover.
    static let unsupportedStill: [ContainerBody] =
        HostContainers.unsupportedStill.map {
            ContainerBody(label: $0, content: .singleFrame(typeIdentifier: $0))
        } + [
            ContainerBody(label: "pdf", content: .pdfDocument),
            ContainerBody(label: "ftyp avif", content: .headerOnly(EncodedImageFixture.isoBaseMedia(brand: "avif"))),
            ContainerBody(label: "photoshop", content: .headerOnly(MediaHeaderFixture.photoshop)),
            ContainerBody(label: "jpeg 2000 jp2", content: .headerOnly(MediaHeaderFixture.jpeg2000Container)),
            ContainerBody(label: "jpeg 2000 codestream", content: .headerOnly(MediaHeaderFixture.jpeg2000Codestream)),
        ]

    /// Content that is not a readable container.
    ///
    /// Present so "exact" means something: neither unsupported error may be a catch-all
    /// for input that is in neither of their two categories.
    static let unreadable: [ContainerBody] = [
        ContainerBody(label: "truncated jpeg 20%", content: .truncatedJPEG(keptFraction: 0.2)),
        ContainerBody(label: "truncated jpeg 45%", content: .truncatedJPEG(keptFraction: 0.45)),
        ContainerBody(label: "truncated jpeg 70%", content: .truncatedJPEG(keptFraction: 0.7)),
        ContainerBody(label: "ftyp mif1 header", content: .headerOnly(EncodedImageFixture.isoBaseMedia(brand: "mif1"))),
        ContainerBody(label: "ftyp heic header", content: .headerOnly(EncodedImageFixture.isoBaseMedia(brand: "heic"))),
        ContainerBody(label: "riff WEBP header", content: .headerOnly(EncodedImageFixture.riff(formType: "WEBP"))),
        ContainerBody(label: "openexr header", content: .headerOnly(MediaHeaderFixture.openEXR)),
        ContainerBody(label: "unidentifiable", content: .headerOnly(EncodedImageFixture.unidentifiableBytes)),
    ]

    static func bodies(for family: MediaFamily) -> [ContainerBody] {
        switch family {
        case .supportedStatic: supported
        case .animatedImage: animated
        case .videoContainer: video
        case .audioContainer: audio
        case .unsupportedStillImage: unsupportedStill
        case .unreadableContainer: unreadable
        }
    }

    /// Families the host can actually produce content for.
    static let availableFamilies: [MediaFamily] = MediaFamily.allCases.filter {
        !bodies(for: $0).isEmpty
    }
}

/// Container headers the shared image fixtures do not carry.
///
/// Kept here rather than added to `EncodedImageFixture`, which other suites in this
/// target read: a new family belongs to the file that needs it until a second file does.
private enum MediaHeaderFixture {
    static let advancedSystemsFormat: [UInt8] =
        [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11] + padding(24)
    static let mpegProgramStream: [UInt8] = [0x00, 0x00, 0x01, 0xBA] + padding(28)
    static let mpegSequence: [UInt8] = [0x00, 0x00, 0x01, 0xB3] + padding(28)
    static let flashVideo: [UInt8] = [0x46, 0x4C, 0x56, 0x01] + padding(28)
    static let flac: [UInt8] = Array("fLaC".utf8) + padding(28)
    static let ogg: [UInt8] = Array("OggS".utf8) + padding(28)
    static let photoshop: [UInt8] = [0x38, 0x42, 0x50, 0x53] + padding(28)
    static let jpeg2000Container: [UInt8] =
        [0x00, 0x00, 0x00, 0x0C] + Array("jP  ".utf8) + padding(24)
    static let jpeg2000Codestream: [UInt8] = [0xFF, 0x4F, 0xFF, 0x51] + padding(28)
    static let openEXR: [UInt8] = [0x76, 0x2F, 0x31, 0x01] + padding(28)

    /// An IFF-style `FORM` container carrying `kind`, with no payload.
    static func interchangeForm(_ kind: String) -> [UInt8] {
        precondition(kind.utf8.count == 4, "an interchange form type is four characters")
        var bytes = Array("FORM".utf8)
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x24])
        bytes.append(contentsOf: Array(kind.utf8))
        bytes.append(contentsOf: padding(24))
        return bytes
    }

    private static func padding(_ count: Int) -> [UInt8] {
        [UInt8](repeating: 0, count: count)
    }
}

/// One generated container and the session context it arrives in, as plain data.
///
/// The generator produces data only. Bytes, artifacts, and the pipeline are built inside
/// the property body, where a construction that unexpectedly fails is recorded as an
/// issue rather than thrown: `propertyCheck` discards an error thrown by its body, so a
/// refusal that escaped as a throw would pass vacuously.
///
/// ## How the baseline varies
///
/// A property whose input is one constant with a family swapped in asserts six examples a
/// hundred times over, so every dimension the assertions depend on is generated:
///
///   * the media family, and the member within it, so all twelve video headers, eight
///     audio headers, and eight unsupported still containers are reached;
///   * the encoded image's width and height independently, so a container is never
///     square or a fixed size by construction;
///   * the frame count of an animated container, over the multi-frame range;
///   * both ingest routes, because Requirements 2.15 and 2.16 apply to a selected item
///     from either one;
///   * the provider's declared content-type hint, including hints that contradict the
///     bytes in both directions, because a hint must never reach a classification;
///   * the preservation basis, so a failing session's recorded byte status varies;
///   * the control container and its own dimensions, independently of the generated one;
///   * every synthetic identifier, from ``seed``.
///
/// ``ShortCircuitVariationWitness`` checks after the run that this actually happened.
private struct ContainerShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic session and artifact identifier, so the whole reference set
    /// varies together and stays coherent without a cross-reference table.
    let seed: Int

    let familyIndex: Int
    let memberIndex: Int

    /// Dimensions of the generated container's image, when it encodes one.
    let width: Int
    let height: Int

    /// Frames an animated container carries. Always more than one.
    let frameCount: Int

    let route: InputRoute
    let hintIndex: Int
    let basisIndex: Int

    /// The control's own container and dimensions, generated separately so the control
    /// never coincides with the generated container by construction.
    let controlIndex: Int
    let controlWidth: Int
    let controlHeight: Int

    var family: MediaFamily {
        ContainerCatalog.availableFamilies[familyIndex % ContainerCatalog.availableFamilies.count]
    }

    var body: ContainerBody {
        let bodies = ContainerCatalog.bodies(for: family)
        return bodies[memberIndex % bodies.count]
    }

    var control: (identifier: String, container: StaticContainer) {
        HostContainers.supported[controlIndex % HostContainers.supported.count]
    }

    var basis: PreservationBasis {
        PreservationBasis.allCases[basisIndex % PreservationBasis.allCases.count]
    }

    /// The provider's declared type, or `nil` when it declared none.
    ///
    /// Drawn from a table that deliberately includes types contradicting the bytes in
    /// both directions: a movie identifier on a real JPEG, and a JPEG identifier on a
    /// movie header. A hint is retained for diagnostics and is attacker-influenced, so a
    /// classification that consulted it would both accept unsupported media and reject a
    /// supported image.
    var contentTypeHint: String? {
        Self.hints[hintIndex % Self.hints.count]
    }

    static let hints: [String?] = [
        nil,
        "public.jpeg",
        "public.png",
        "public.heic",
        "com.apple.quicktime-movie",
        "public.mpeg-4",
        "public.tiff",
        "public.mp3",
        "public.data",
    ]

    var description: String {
        """
        seed \(seed), family \(family.rawValue), member \(body.label), \
        \(width)x\(height), frames \(frameCount), route \(route.rawValue), \
        hint \(contentTypeHint ?? "none"), basis \(basis.rawValue), \
        control \(control.identifier) \(controlWidth)x\(controlHeight)
        """
    }

    // MARK: Generators

    static var generator: Generator<ContainerShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.int(in: 0...199),
            Gen.int(in: 0...199),
            dimensions,
            Gen.int(in: 2...4),
            Gen.bool,
            Gen.int(in: 0...199),
            Gen.int(in: 0...199),
            Gen.int(in: 0...199),
            dimensions
        )
        .map { raw in
            ContainerShape(
                seed: raw.0,
                familyIndex: raw.1,
                memberIndex: raw.2,
                width: raw.3.0,
                height: raw.3.1,
                frameCount: raw.4,
                route: raw.5 ? .photosPicker : .shareExtension,
                hintIndex: raw.6,
                basisIndex: raw.7,
                controlIndex: raw.8,
                controlWidth: raw.9.0,
                controlHeight: raw.9.1
            )
        }
        .eraseToAny()
    }

    /// Width and height, drawn independently.
    ///
    /// Bounded well below any generated limit: this property is about classification, and
    /// a dimension large enough to reach a budget check would make the outcome depend on
    /// a resource limit instead. Requirement 3.4's limits are Property 8's subject.
    private static var dimensions: Generator<(Int, Int), AnySequence<Any>> {
        zip(Gen.int(in: 8...48), Gen.int(in: 8...48)).eraseToAny()
    }
}

// MARK: - Recorded pipeline stages

/// The stages of one Analysis Session this property watches.
///
/// The five that Requirements 1.12, 1.14, and 2.16 forbid after either unsupported error,
/// plus input validation itself so a log can show that the pipeline started. Model load is
/// absent because the harness binds a model before the session runs, matching a session
/// that snapshots its bundle when the input is accepted.
private enum PipelineStage: String, Hashable, Sendable, CaseIterable {
    case inputValidation
    case preprocessing
    case provenanceValidation
    case inference
    case calibration
    case reportConstruction

    /// The stages that must not run once classification has refused the input.
    static let forbiddenAfterUnsupportedInput: [PipelineStage] = [
        .preprocessing, .provenanceValidation, .inference, .calibration, .reportConstruction,
    ]
}

/// An ordered, thread-safe log of the stages one pipeline run entered.
///
/// Ordered rather than a set of booleans because the claim is about a boundary: the
/// property asserts that nothing after classification ran, and reading the sequence is
/// what makes a failure message say where the run actually got to.
private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entered: [PipelineStage] = []

    func record(_ stage: PipelineStage) {
        lock.lock()
        entered.append(stage)
        lock.unlock()
    }

    var stages: [PipelineStage] {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    func count(of stage: PipelineStage) -> Int {
        stages.filter { $0 == stage }.count
    }
}

// MARK: - Recording doubles for the downstream stages

// Each double records its invocation before doing anything else, so a nonoccurrence
// assertion is about the call rather than about its result. None of them decides a
// policy: each returns one fixed representable value, which keeps the doubles free of the
// boundaries, mappings, and budgets that remain approved external inputs.

/// Records the preprocessing call and returns a contract-shaped model input.
private struct RecordingPreprocessor: ImagePreprocessing {
    let recorder: StageRecorder

    func prepare(
        _ image: ValidatedImage,
        contract: PreprocessingContract,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ModelImageInput {
        recorder.record(.preprocessing)
        return ModelImageInput(
            sessionID: image.sessionID,
            buffer: ModelInputToken(rawValue: 1),
            contract: contract.modelInput,
            preprocessingContractID: contract.id
        )
    }
}

/// Records the provenance call and returns the payload-free absent state.
///
/// `absent` is deliberate: it is the one enabled state that carries no policy-derived
/// detail, so the double cannot imply a trust, signer, or assertion decision.
private struct RecordingProvenanceAnalyzer: ProvenanceAnalyzing {
    let recorder: StageRecorder

    func analyze(
        _ asset: ImportedEncodedAsset,
        policy: ProvenancePolicy
    ) async -> ProvenanceEvidence {
        recorder.record(.provenanceValidation)
        return .absent
    }
}

/// Records the inference call and returns one finite logit.
private struct RecordingPixelAnalyzer: PixelAnalyzing {
    let recorder: StageRecorder

    func infer(
        _ input: ModelImageInput,
        model: BoundCoreMLModel
    ) async throws(AnalysisFault) -> RawLogit {
        recorder.record(.inference)
        // Force-unwrap is sound: the literal is finite, which is the only condition
        // `RawLogit` rejects.
        return RawLogit(0.25)!
    }
}

/// Records the calibration call and returns the non-positive label.
private struct RecordingCalibrator: PixelCalibrating {
    let recorder: StageRecorder

    func classify(
        _ logit: RawLogit,
        quality: InputQualityRecord,
        policy: CalibrationPolicy
    ) throws(AnalysisFault) -> PixelEvidence {
        recorder.record(.calibration)
        return .noStrongSignalDetected
    }
}

/// Records the report-construction call and builds one Evidence Report.
///
/// A local type rather than a port conformance: report construction belongs to the
/// Evidence Coordinator in the application module, which this module does not and must
/// not reach. What the property needs from it is that the stage is observably entered and
/// that a report either exists or does not.
private struct RecordingReportBuilder {
    let recorder: StageRecorder
    let binding: AnalysisSessionBinding
    let scope: EvidenceScope

    func construct(
        pixel: PixelEvidence,
        provenance: ProvenanceEvidence,
        preservation: BytePreservationStatus,
        quality: InputQualityRecord
    ) -> EvidenceReport? {
        recorder.record(.reportConstruction)
        return EvidenceReport(
            binding: binding,
            pixel: pixel,
            provenance: .available(provenance),
            // No approved Evidence Fusion Rule is bound, so no summary and no apparent
            // inconsistency notice may exist (Requirements 7.11 and 7.16).
            combinedSummary: nil,
            apparentInconsistency: nil,
            bytePreservationStatus: preservation,
            inputQuality: quality,
            onDeviceProcessing: true,
            scope: scope
        )
    }
}

// MARK: - The pipeline under test

/// One Analysis Session's worth of work: the real validator, then recording doubles.
///
/// The order is the design's: complete validation, then preprocessing, then the two
/// evidence lanes, then calibration, then evidence joining. Serial branch execution is one
/// of the two orders an approved execution policy may select, and the property's claim is
/// about a boundary that precedes both branches, so a serial harness cannot make the
/// nonoccurrence assertion easier to satisfy.
///
/// The provenance lane is wired with an analyzer present, which is the strictly harder
/// configuration: a pixel-only composition links no validator at all, so "provenance
/// validation did not happen" would hold there for a reason that has nothing to do with
/// classification.
private struct ShortCircuitPipeline {
    let recorder = StageRecorder()
    let store = InMemoryEncodedAssetStore()
    private let decodedImages = DecodedImageStore()
    private let quality = InputQualityLedger()
    private let validator: ImageIOInputValidator
    private let preprocessor: RecordingPreprocessor
    private let provenance: RecordingProvenanceAnalyzer
    private let analyzer: RecordingPixelAnalyzer
    private let calibrator: RecordingCalibrator
    private let reportBuilder: RecordingReportBuilder

    private let contract: PreprocessingContract
    private let budget: ResourceBudget
    private let provenancePolicy: ProvenancePolicy
    private let calibrationPolicy: CalibrationPolicy
    private let model: BoundCoreMLModel

    init(artifacts: SyntheticArtifacts) {
        self.contract = artifacts.contract
        self.budget = artifacts.budget
        self.provenancePolicy = artifacts.provenancePolicy
        self.calibrationPolicy = artifacts.calibrationPolicy
        self.model = artifacts.model
        self.validator = ImageIOInputValidator(
            encodedAssets: store,
            decodedImages: decodedImages,
            quality: quality
        )
        self.preprocessor = RecordingPreprocessor(recorder: recorder)
        self.provenance = RecordingProvenanceAnalyzer(recorder: recorder)
        self.analyzer = RecordingPixelAnalyzer(recorder: recorder)
        self.calibrator = RecordingCalibrator(recorder: recorder)
        self.reportBuilder = RecordingReportBuilder(
            recorder: recorder,
            binding: artifacts.binding,
            scope: artifacts.scope
        )
    }

    /// Runs one session to its terminal outcome.
    ///
    /// Returns rather than throws, so the caller records an issue instead of letting a
    /// fault escape the property body.
    func run(_ asset: ImportedEncodedAsset) async -> Result<EvidenceReport, AnalysisFault> {
        recorder.record(.inputValidation)
        let validated: ValidatedImage
        do {
            validated = try await validator.validate(asset, contract: contract, budget: budget)
        } catch {
            return .failure(error)
        }

        do {
            let input = try await preprocessor.prepare(
                validated,
                contract: contract,
                budget: budget
            )
            let lane = await provenance.analyze(asset, policy: provenancePolicy)
            let logit = try await analyzer.infer(input, model: model)
            let pixel = try calibrator.classify(
                logit,
                quality: validated.quality,
                policy: calibrationPolicy
            )
            guard let report = reportBuilder.construct(
                pixel: pixel,
                provenance: lane,
                preservation: asset.preservationStatus,
                quality: validated.quality
            ) else {
                return .failure(.analysis(.calibrationInputError, stage: .evidenceJoining))
            }
            return .success(report)
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Scenario

/// One generated shape, the artifacts built from it, and the two runs it performs.
private struct ShortCircuitScenario {
    let shape: ContainerShape

    /// The generated container's bytes, or `nil` when this host could not produce them.
    private func generatedBytes() -> [UInt8]? {
        bytes(for: shape.body, width: shape.width, height: shape.height)
    }

    private func bytes(for body: ContainerBody, width: Int, height: Int) -> [UInt8]? {
        switch body.content {
        case .singleFrame(let identifier):
            guard let type = UTType(identifier) else { return nil }
            return EncodedImageFixture.encode(
                EncodedImageFixture.gradient(width: width, height: height),
                as: type
            )
        case .multiFrame(let identifier):
            guard let type = UTType(identifier) else { return nil }
            return EncodedImageFixture.encode(
                EncodedImageFixture.gradient(width: width, height: height),
                as: type,
                frameCount: shape.frameCount
            )
        case .headerOnly(let header):
            return header
        case .pdfDocument:
            return EncodedImageFixture.pdf()
        case .truncatedJPEG(let fraction):
            return EncodedImageFixture.truncatedJPEG(fraction: fraction)
        }
    }

    private func session(_ suffix: String) -> AnalysisSessionID {
        guard let id = AnalysisSessionID("session-p3-\(shape.seed)-\(suffix)") else {
            preconditionFailure("a generated session identifier must be canonical")
        }
        return id
    }

    // MARK: The generated container

    /// The generated container reaches exactly its family's outcome, and an unsupported
    /// one reaches no evidence stage.
    func checkGeneratedContainerClassifiesAndShortCircuits() async {
        guard let bytes = generatedBytes() else {
            Issue.record("this host could not produce \(shape.body.label) [\(shape)]")
            return
        }

        let artifacts: SyntheticArtifacts
        let pipeline: ShortCircuitPipeline
        let asset: ImportedEncodedAsset
        do {
            artifacts = try SyntheticArtifacts(seed: shape.seed, sessionID: session("input"))
            pipeline = ShortCircuitPipeline(artifacts: artifacts)
            asset = try await IngestFixture.asset(
                bytes: bytes,
                in: pipeline.store,
                sessionID: session("input"),
                route: shape.route,
                preservationBasis: shape.basis,
                contentTypeHint: shape.contentTypeHint
            )
        } catch {
            Issue.record("building the generated session failed: \(error) [\(shape)]")
            return
        }

        let outcome = await pipeline.run(asset)
        let recorder = pipeline.recorder

        // The run started. Without this, every nonoccurrence assertion below would also
        // hold for a pipeline that was never invoked.
        #expect(
            recorder.count(of: .inputValidation) == 1,
            "the pipeline must have started [\(shape)]"
        )

        switch shape.family {
        case .supportedStatic:
            checkAnalyzableContainerCompletes(outcome, recorder: recorder)
        case .animatedImage, .videoContainer, .audioContainer, .unsupportedStillImage:
            checkUnsupportedContainerShortCircuits(outcome, recorder: recorder)
        case .unreadableContainer:
            checkUnreadableContainerIsNeitherUnsupportedError(outcome, recorder: recorder)
        }
    }

    /// Requirements 1.11, 1.13, 2.15: the family decides the error, and the two errors are
    /// not interchangeable. Requirements 1.12, 1.14, 2.16: nothing downstream runs.
    private func checkUnsupportedContainerShortCircuits(
        _ outcome: Result<EvidenceReport, AnalysisFault>,
        recorder: StageRecorder
    ) {
        guard let required = shape.family.requiredError else {
            Issue.record("an unsupported family must fix one error [\(shape)]")
            return
        }
        guard case .failure(let fault) = outcome else {
            Issue.record("\(shape.body.label) must not produce an Evidence Report [\(shape)]")
            return
        }

        // Exactly one closed error, detected while classifying the container, and not
        // cancellation: cancellation is a separate terminal outcome and must never stand
        // in for a refused input (Requirement 11.17).
        #expect(fault == .analysis(required, stage: .mediaClassification), "[\(shape)]")
        #expect(fault.analysisError == required, "[\(shape)]")
        #expect(fault.isCancelled == false, "[\(shape)]")

        // The exactness claim, stated in the direction each requirement makes it: media is
        // never reported as an unsupported static format, and an unsupported static format
        // is never reported as media.
        let other: AnalysisError = required == .unsupportedMedia
            ? .unsupportedStaticFormat
            : .unsupportedMedia
        #expect(
            fault.analysisError != other,
            "\(shape.body.label) must not report \(other.rawValue) [\(shape)]"
        )

        checkNoEvidenceWorkHappened(outcome, recorder: recorder)
    }

    /// A container in neither unsupported category produces neither unsupported error, and
    /// still reaches no evidence stage.
    private func checkUnreadableContainerIsNeitherUnsupportedError(
        _ outcome: Result<EvidenceReport, AnalysisFault>,
        recorder: StageRecorder
    ) {
        guard case .failure(let fault) = outcome else {
            Issue.record("\(shape.body.label) must not produce an Evidence Report [\(shape)]")
            return
        }
        #expect(
            fault.analysisError != .unsupportedMedia,
            "\(shape.body.label) is not media [\(shape)]"
        )
        #expect(
            fault.analysisError != .unsupportedStaticFormat,
            "\(shape.body.label) is malformed, not an unsupported format [\(shape)]"
        )
        checkNoEvidenceWorkHappened(outcome, recorder: recorder)
    }

    /// No preprocessing, provenance validation, inference, calibration, or report
    /// construction, and no Evidence Report.
    private func checkNoEvidenceWorkHappened(
        _ outcome: Result<EvidenceReport, AnalysisFault>,
        recorder: StageRecorder
    ) {
        for stage in PipelineStage.forbiddenAfterUnsupportedInput {
            #expect(
                recorder.count(of: stage) == 0,
                """
                \(stage.rawValue) ran for \(shape.body.label); \
                stages: \(recorder.stages.map(\.rawValue)) [\(shape)]
                """
            )
        }
        #expect(
            recorder.stages == [.inputValidation],
            "only validation may run [\(shape)]"
        )
        if case .success = outcome {
            Issue.record("a refused container produced a report [\(shape)]")
        }
    }

    /// A generated supported container completes: the classification is the container the
    /// bytes actually are, and the whole pipeline ran.
    private func checkAnalyzableContainerCompletes(
        _ outcome: Result<EvidenceReport, AnalysisFault>,
        recorder: StageRecorder
    ) {
        guard case .success(let report) = outcome else {
            Issue.record(
                """
                a real \(shape.body.label) must be analyzable; \
                got \(outcome) [\(shape)]
                """
            )
            return
        }
        #expect(report.pixel == .noStrongSignalDetected, "[\(shape)]")
        #expect(report.provenance.category == .absent, "[\(shape)]")
        checkEveryStageRanOnce(recorder: recorder)
    }

    // MARK: The control

    /// One real supported container through the same pipeline reaches every stage.
    ///
    /// This is the non-vacuity half. Every assertion above is a claim that a recorder saw
    /// nothing, and a recorder that is not wired to anything also sees nothing. Running a
    /// container that must pass, through a pipeline built the same way, on every generated
    /// case, is what distinguishes "the stages did not run" from "the stages could not have
    /// run".
    func checkSupportedControlReachesEveryStage() async {
        guard !HostContainers.supported.isEmpty else {
            Issue.record("this host can encode no supported container [\(shape)]")
            return
        }
        let control = shape.control
        guard let type = UTType(control.identifier),
              let bytes = EncodedImageFixture.encode(
                  EncodedImageFixture.gradient(
                      width: shape.controlWidth,
                      height: shape.controlHeight
                  ),
                  as: type
              )
        else {
            Issue.record("this host could not encode \(control.identifier) [\(shape)]")
            return
        }

        let pipeline: ShortCircuitPipeline
        let asset: ImportedEncodedAsset
        do {
            let artifacts = try SyntheticArtifacts(
                seed: shape.seed,
                sessionID: session("control")
            )
            pipeline = ShortCircuitPipeline(artifacts: artifacts)
            asset = try await IngestFixture.asset(
                bytes: bytes,
                in: pipeline.store,
                sessionID: session("control"),
                route: shape.route,
                preservationBasis: shape.basis,
                // The control carries a hint too, and it is as untrustworthy as any
                // other: a supported image whose provider claimed it was a movie must
                // still be analyzed.
                contentTypeHint: shape.contentTypeHint
            )
        } catch {
            Issue.record("building the control session failed: \(error) [\(shape)]")
            return
        }

        let outcome = await pipeline.run(asset)
        guard case .success(let report) = outcome else {
            Issue.record(
                """
                the control \(control.identifier) must reach a report; \
                got \(outcome) [\(shape)]
                """
            )
            return
        }

        #expect(report.inputQuality.decodedWidthBeforeOrientation == shape.controlWidth, "[\(shape)]")
        #expect(report.inputQuality.decodedHeightBeforeOrientation == shape.controlHeight, "[\(shape)]")
        #expect(report.bytePreservationStatus == shape.basis.mostConservativeStatus, "[\(shape)]")
        checkEveryStageRanOnce(recorder: pipeline.recorder)
    }

    /// Every watched stage ran exactly once, in the design's causal order.
    private func checkEveryStageRanOnce(recorder: StageRecorder) {
        let stages = recorder.stages
        for stage in PipelineStage.allCases {
            #expect(
                recorder.count(of: stage) == 1,
                "\(stage.rawValue) must run once; stages: \(stages.map(\.rawValue)) [\(shape)]"
            )
        }
        #expect(
            stages == [
                .inputValidation, .preprocessing, .provenanceValidation, .inference,
                .calibration, .reportConstruction,
            ],
            "stage order: \(stages.map(\.rawValue)) [\(shape)]"
        )
    }
}

// MARK: - Synthetic artifacts

/// Every artifact the pipeline needs in order to be called at all.
///
/// **No number, mapping, boundary, budget, limit, or approval in this type is an approved
/// release value.** Each one is an unresolved external decision: the Preprocessing
/// Contract's metadata actions and geometry rules, the Resource Budget's measured limits,
/// the Provenance Policy's trust and revocation answers, the Calibration Policy's budget
/// and boundaries, and every approval record. They exist so a port that takes a signed
/// artifact can be invoked, and no assertion in this file claims any of them is correct.
/// Nothing here may be copied into a shipping artifact.
///
/// Built per generated case so two sessions never share a store, ledger, or binding, and
/// so the identifiers a failure reports name the case that produced it.
private struct SyntheticArtifacts {
    let contract: PreprocessingContract
    let budget: ResourceBudget
    let provenancePolicy: ProvenancePolicy
    let calibrationPolicy: CalibrationPolicy
    let model: BoundCoreMLModel
    let binding: AnalysisSessionBinding
    let scope: EvidenceScope

    init(seed: Int, sessionID: AnalysisSessionID) throws {
        contract = PreprocessingFixture.contract(id: "preprocessing-p3-\(seed)")
        budget = ResourceFixture.budget(id: "budget-p3-\(seed)")
        provenancePolicy = try Self.provenance(seed: seed)
        calibrationPolicy = try Self.calibration(seed: seed, contract: contract)
        model = try Self.model(seed: seed, contract: contract)
        binding = try Self.binding(
            seed: seed,
            sessionID: sessionID,
            contract: contract,
            calibration: calibrationPolicy,
            provenance: provenancePolicy,
            budget: budget
        )
        scope = .version1(id: Fixture.artifactID("scope-p3-\(seed)"))
    }

    // MARK: Helpers

    /// A schema-valid version derived from `seed`.
    ///
    /// The major component is fixed at `1` rather than seeded, because a version whose
    /// every component can be zero can name `0.0.0`, which is the repository's local
    /// development stand-in and which ``SchemaSemanticVersion`` correctly refuses. That
    /// refusal is right — an approved artifact records a decided version — but here it
    /// would surface as a construction failure in whichever arm happened to draw a
    /// multiple of 1000, and shrinking would then drive the seed to 0 and report a
    /// classification failure that has nothing to do with classification. Pinning the
    /// major component to a positive value removes the placeholder from the range while
    /// leaving the minor component seeded, so the reference set still varies per case.
    private static func version(_ seed: Int) throws -> SchemaSemanticVersion {
        try SchemaSemanticVersion(validating: "1.\(seed % 1_000).0")
    }

    private static func approval(_ seed: Int, artifact: String) throws -> ApprovalRecord {
        guard let approver = ApproverID("synthetic-test-owner") else {
            preconditionFailure("the synthetic approver identifier must be canonical")
        }
        return ApprovalRecord(
            source: Fixture.evidence("\(artifact)-p3-\(seed)"),
            decision: .approved,
            approver: approver,
            decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func text(_ raw: String) throws -> ArtifactText {
        try ArtifactText(validating: raw)
    }

    // MARK: Provenance

    /// A schema-valid Provenance Policy, so the enabled provenance lane can be wired.
    ///
    /// Its trust store, revocation answer, and status mappings are synthetic. The point of
    /// having one at all is that the harness models the provenance-enabled composition,
    /// where "provenance validation did not happen" is a claim about the short-circuit
    /// rather than about a validator that was never linked.
    private static func provenance(seed: Int) throws -> ProvenancePolicy {
        guard let status = ProvenanceValidatorStatusID("status.synthetic-no-manifest") else {
            preconditionFailure("the synthetic validator status must be canonical")
        }
        return try ProvenancePolicy(
            id: Fixture.artifactID("provenance-p3-\(seed)"),
            schemaVersion: .v1,
            capability: .contentCredentialValidation,
            validatorImplementationVersion: try version(seed),
            validatorBinaryDigest: Fixture.digest(of: Array("validator-\(seed)".utf8)),
            supportedSpecification: Fixture.evidence("specification-p3-\(seed)"),
            trustStore: try ProvenanceTrustStoreDescriptor(
                store: Fixture.evidence("trust-store-p3-\(seed)"),
                anchorCount: try PositiveCount(validating: 1),
                isOfflineOnly: true
            ),
            revocationBehavior: try ProvenanceRevocationBehavior(
                permitsNetworkRevocationCheck: false,
                unavailableAnswerState: .indeterminate,
                approval: try approval(seed, artifact: "revocation")
            ),
            supportedAssertionLabels: [try text("synthetic.assertion")],
            displayableFields: [.bindingStatus],
            processingLimits: ProvenanceProcessingLimits(
                maximumManifestByteCount: try PositiveByteCount(validating: 65_536),
                maximumAssertionCount: try PositiveCount(validating: 8),
                maximumNestingDepth: try PositiveCount(validating: 4),
                maximumProcessingDuration: try ValidatedDuration(validating: 5_000)
            ),
            resourceBudget: Fixture.artifactID("budget-p3-\(seed)"),
            statusMappings: [ProvenanceStatusMapping(status: status, state: .absent)],
            feasibilityApproval: try approval(seed, artifact: "provenance-feasibility")
        )
    }

    // MARK: Calibration

    /// A schema-valid Calibration Policy, so the calibration port can be called.
    ///
    /// The budget rate, the boundary, and the abstention half-width are synthetic values
    /// inside the constraints the requirements fix; they are not the release decision, and
    /// no assertion here reads them.
    private static func calibration(
        seed: Int,
        contract: PreprocessingContract
    ) throws -> CalibrationPolicy {
        try CalibrationPolicy(
            id: Fixture.artifactID("calibration-p3-\(seed)"),
            schemaVersion: .v1,
            compatibleModel: RequiredPixelModel.identity,
            compatiblePreprocessing: contract.id,
            compatibleVerdictCopy: Fixture.artifactID("copy-compatibility-p3-\(seed)"),
            falseAccusationBudget: try FalseAccusationBudget(
                validating: Decimal(sign: .plus, exponent: -3, significand: 5)
            ),
            releasePassRule: try FalseAccusationPassRule(
                statistic: .intervalUpperBound,
                intervalMethod: .wilsonScore,
                confidenceLevel: try UnitInterval(
                    validating: FalseAccusationPassRule.requiredConfidenceLevel
                )
            ),
            outputLabels: Set(PixelLabelKey.allCases),
            metricCategories: PixelLabelKey.allCases.map {
                MetricCategoryAssignment(label: $0, category: $0.requiredMetricCategory)
            },
            boundaries: [
                try CategoryBoundary(
                    rawLogitBoundary: 1.5,
                    abstentionHalfWidth: CategoryBoundary.minimumAbstentionHalfWidth,
                    lowerDecision: .noStrongSignalDetected,
                    upperDecision: .signalsConsistentWithAIGeneration
                )
            ],
            minimumShortEdge: CalibrationPolicy.requiredMinimumShortEdge,
            belowMinimumShortEdgeLabel: .notEnoughSignal,
            requiredQualityFeatures: [],
            qualityRules: [],
            uncoveredQualityInputBehavior: .calibrationInputError,
            evidence: [Fixture.evidence("calibration-evidence-p3-\(seed)")],
            upstreamBoundaryMetadata: try UpstreamBoundaryMetadata(
                rawLogitValue: UpstreamBoundaryMetadata.requiredValue,
                role: .modelMetadataOnly
            )
        )
    }

    // MARK: Model and binding

    /// A bound model carrying the one permitted pixel identity.
    ///
    /// Bound before the session runs, matching a session that snapshots its verified
    /// bundle when the input is accepted, so model load is not a stage this property has to
    /// watch.
    private static func model(
        seed: Int,
        contract: PreprocessingContract
    ) throws -> BoundCoreMLModel {
        guard let bundleID = ModelBundleID("bundle-p3-\(seed)") else {
            preconditionFailure("the synthetic bundle identifier must be canonical")
        }
        guard let model = BoundCoreMLModel(
            bundleID: bundleID,
            modelIdentity: RequiredPixelModel.identity,
            coreMLModelVersion: Fixture.artifactID("coreml-p3-\(seed)"),
            inputContract: contract.modelInput,
            outputContract: try ModelOutputContract(
                featureName: try text(ModelOutputContract.requiredFeatureName),
                elementType: .float32,
                isPositiveGoing: true
            ),
            model: LoadedModelToken(rawValue: 1)
        ) else {
            preconditionFailure("only the required pixel-model identity is bindable")
        }
        return model
    }

    private static func binding(
        seed: Int,
        sessionID: AnalysisSessionID,
        contract: PreprocessingContract,
        calibration: CalibrationPolicy,
        provenance: ProvenancePolicy,
        budget: ResourceBudget
    ) throws -> AnalysisSessionBinding {
        guard let appBuild = AppBuildID("build-p3-\(seed)"),
              let configuration = ApprovedConfigurationID("configuration-p3-\(seed)"),
              let bundleID = ModelBundleID("bundle-p3-\(seed)"),
              let path = CanonicalRelativePath("model/synthetic.mlmodelc")
        else {
            preconditionFailure("the synthetic binding identifiers must be canonical")
        }
        guard let integrity = VerifiedBundleIntegrity(
            status: .verified,
            activationReceiptID: Fixture.artifactID("receipt-p3-\(seed)"),
            verificationPolicyID: Fixture.artifactID("bundle-verification-p3-\(seed)"),
            verifiedManifestDigest: Fixture.digest(of: Array("manifest-\(seed)".utf8)),
            verifiedArtifactDigests: [
                ArtifactDigestRecord(
                    path: path,
                    kind: .directoryTree,
                    byteCount: 1,
                    digest: Fixture.digest(of: Array("artifact-\(seed)".utf8))
                )
            ]
        ) else {
            preconditionFailure("a one-artifact digest inventory must be representable")
        }
        return AnalysisSessionBinding(
            sessionID: sessionID,
            appBuildID: appBuild,
            deviceConfigurationID: configuration,
            modelBundleID: bundleID,
            modelIdentity: RequiredPixelModel.identity,
            coreMLModelVersion: Fixture.artifactID("coreml-p3-\(seed)"),
            modelBundleIntegrity: integrity,
            preprocessingContractID: contract.id,
            calibrationPolicyID: calibration.id,
            verdictCopyCompatibilityID: calibration.compatibleVerdictCopy,
            capabilityManifestID: Fixture.artifactID("capability-manifest-p3-\(seed)"),
            provenancePolicyID: provenance.id,
            // No approved Evidence Fusion Rule is bound, so the Combined Summary is
            // omitted rather than defaulted (Requirement 7.16).
            fusionRuleID: nil,
            lifecyclePolicyID: Fixture.artifactID("lifecycle-p3-\(seed)"),
            resourceBudgetID: budget.id
        )
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator actually produced, so the property cannot pass by
/// generating one fixed container a hundred times.
///
/// It also proves the run happened at all. `propertyCheck` discards an error thrown by its
/// body, so a body that failed before its first assertion — a construction that threw, a
/// generator that produced nothing usable — would report a passing test in milliseconds
/// with every arm skipped. A witness that counts cases outside the body is the only thing
/// that catches that.
///
/// The thresholds are far below what 100 uniform draws produce, so this witnesses
/// variation rather than pinning a distribution.
private final class ShortCircuitVariationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var families = Set<MediaFamily>()
    private var members = Set<String>()
    private var dimensions = Set<Int>()
    private var frameCounts = Set<Int>()
    private var routes = Set<InputRoute>()
    private var hints = Set<String>()
    private var bases = Set<PreservationBasis>()
    private var controls = Set<String>()
    private var cases = 0

    func record(_ shape: ContainerShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        families.insert(shape.family)
        members.insert(shape.body.label)
        dimensions.formUnion([shape.width, shape.height, shape.controlWidth, shape.controlHeight])
        frameCounts.insert(shape.frameCount)
        routes.insert(shape.route)
        hints.insert(shape.contentTypeHint ?? "none")
        bases.insert(shape.basis)
        controls.insert(shape.control.identifier)
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases")
        #expect(
            families == Set(ContainerCatalog.availableFamilies),
            "generated families: \(families.map(\.rawValue).sorted())"
        )
        // Both unsupported categories have to appear, or the exactness claim is one-sided.
        #expect(families.contains(.unsupportedStillImage), "no unsupported static format")
        #expect(
            !families.isDisjoint(with: [.animatedImage, .videoContainer, .audioContainer]),
            "no unsupported media"
        )
        // The supported family is the control's occurrence half; the dedicated control run
        // makes it unconditional, and generating it too keeps the accepting path on the
        // same generated dimensions as the refused ones.
        #expect(families.contains(.supportedStatic), "no analyzable container")
        #expect(members.count >= 20, "generated family members: \(members.count)")
        #expect(dimensions.count >= 20, "generated dimensions: \(dimensions.count)")
        #expect(frameCounts == [2, 3, 4], "generated frame counts: \(frameCounts.sorted())")
        #expect(routes == Set(InputRoute.allCases), "both ingest routes are generated")
        #expect(
            hints.count == ContainerShape.hints.count,
            "generated provider hints: \(hints.count)"
        )
        #expect(
            bases == Set(PreservationBasis.allCases),
            "generated preservation bases: \(bases.map(\.rawValue).sorted())"
        )
        #expect(
            controls == Set(HostContainers.supported.map(\.identifier)),
            "generated control containers: \(controls.sorted())"
        )
    }
}
