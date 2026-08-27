import DefAIkeDomain
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import DefAIkeImagePipeline

// Task 5.10: the image pipeline exercised through real Image I/O, with real encoded
// containers, from ingest to the bound model input.
//
// Every other file in this target isolates one thing. `ContainerClassificationTests`
// classifies bytes, `MetadataObservationTests` observes declarations,
// `ContractMetadataTransformTests` renders a decoded image, `ResizeGeometryTests` and
// `BilinearResampleTests` do geometry and sampling, and the five property files quantify
// Properties 3, 8, 9, 10, and 12 over generated inputs. This file does the one thing none
// of them does: it puts a **real encoded container** in at the top and reads the **bound
// model input** out at the bottom, with the real `ImageIOInputValidator`, the real
// `ContractImagePreprocessor`, the real `InputQualityLedger`, and the real decoded-image
// and prepared-input stores in between, and it walks the container, metadata, colour,
// alpha, aspect-ratio, and dimension families the task names.
//
// ## The comparison rule this file obeys, and what it costs
//
// The task says to compare decoded metadata, RGB samples, resized output, crop geometry,
// and model-input bytes **only against preapproved tolerances and expected artifacts**.
// Task 14.1 states the governing rule for the fixture catalogue: fail on missing assets
// rather than generating expected evidence from the implementation under test.
//
// So this file never records what the pipeline produced and then enshrines it as the
// expectation. That would pass forever regardless of correctness. Instead every assertion
// here is one of exactly two kinds, and the kind is named at each test:
//
//   * **Self-evident.** A claim whose expected value is fixed by the requirement text, by
//     the encoder's own input, or by an equality between two runs — a real JPEG decodes,
//     `min(width, height)` is the short edge, the resized short edge is 440, the crop is
//     384 by 384, the model input is `384 * 384 * 3` bytes, two byte-identical inputs
//     produce the same bytes, two different bound actions produce different bytes. No
//     approved artifact is needed to know any of those, so they are asserted directly.
//   * **Needs an approved artifact.** An absolute sample value, an exact expected byte
//     sequence for a resized or cropped image, a numeric tolerance, or parity against a
//     reference implementation. Those are wired to the approved-evidence seam below and
//     are **not performed** when the artifact is absent: the absence is recorded and
//     reported by name. Nothing substitutes a produced value for a missing expected one.
//
// ``RealFrameworkApprovedComparisonTests`` reports which comparisons this build could
// ground and which it could not, and ``ApprovedComparator`` is checked separately to
// prove it refuses a missing asset and a digest mismatch rather than completing them.
//
// ## What this host can and cannot express
//
// Measured on the development host, not assumed:
//
//   * JPEG, PNG, HEIC, HEICS, animated GIF, APNG, TIFF, BMP, static GIF, and PDF all
//     encode. **HEIF does not**: Image I/O offers no `public.heif` encoder even though it
//     offers `public.heic`. The HEIF half of Requirement 13.4's HEIC/HEIF family is
//     therefore unreachable from an encoder here and needs an approved fixture asset,
//     which this build does not carry.
//   * Image I/O normalizes orientation while writing, so an out-of-range or self-
//     contradictory declaration cannot be produced by any encoder. Real containers reach
//     this pipeline with only the `absent` and `valid` orientation, profile, and alpha
//     states. The `malformed` and `unsupported` states are `MetadataObservationTests`'
//     and Property 10's, reached from directly constructed declarations, and are not
//     restated here.
//   * Image I/O's HEIC writer always emits an orientation, so a real HEIC cannot present
//     the `absent` orientation state on this host. A hand-assembled PNG can, which is why
//     ``RawPNG`` exists.
//
// ## Host results are not device evidence
//
// Requirement 13.9 compares screenshot geometry, orientation, colour handling, encoding,
// crop output, and raw logit against an approved reference **on a physical iPhone**, and
// Requirement 13.6 does the same for preprocessing output. Nothing in this file is that.
// These are macOS host results from a development toolchain; the iOS deployment target is
// 17.0 and only the iOS 26.5 SDK and runtime exist here, so runtime behaviour at the
// supported minimum is not observed at all. A host or simulator result can never satisfy
// a physical-device gate, and no test here claims otherwise.
//
// **No value in this file is an approved release value.** The Preprocessing Contract's
// metadata actions, working space, and geometry rules, and the Resource Budget's limits,
// are synthetic arguments that exist so a port taking a signed artifact can be called at
// all. The 440 short edge and the 384 crop are requirement constants and are read from
// the types that own them. Nothing here may be copied into a shipping artifact.

// MARK: - The approved-evidence seam

/// The five comparisons task 5.10 names.
///
/// Each one is asked of ``ApprovedImagePipelineEvidenceReading`` before it is attempted,
/// so the question "is there an approved expected value for this?" is answered in one
/// place rather than assumed at each assertion.
enum ApprovedComparisonKind: String, CaseIterable, Sendable, CustomStringConvertible {
    case decodedMetadata = "decoded-metadata"
    case rgbSamples = "rgb-samples"
    case resizedOutput = "resized-output"
    case cropGeometry = "crop-geometry"
    case modelInputBytes = "model-input-bytes"

    var description: String { rawValue }

    /// The Device Validation Plan comparison this kind would be bounded by, or `nil` when
    /// the plan's metric vocabulary has no entry for it.
    ///
    /// Two of the five have no metric, and that is a finding rather than an omission here:
    /// ``ComparisonMetric`` is a closed vocabulary in the domain, and a comparison with no
    /// metric has nothing for Requirement 13.3's "declare the metric and the numeric
    /// tolerance before validation begins" to attach to.
    var planMetric: ComparisonMetric? {
        switch self {
        case .decodedMetadata: nil
        case .rgbSamples, .resizedOutput, .modelInputBytes: .preprocessingOutput
        case .cropGeometry: .screenshotGeometry
        }
    }
}

/// Why a catalogued asset's bytes could not be reached.
///
/// Structural outcomes only, and no absolute path. How each becomes a finding belongs to
/// the comparator.
enum ApprovedAssetFault: Error, Equatable, Sendable {
    /// Nothing exists at that path.
    case assetMissing
    /// The entry exists but its bytes could not be read.
    case assetUnreadable
    /// No approved suite is delivered to this target at all.
    case suiteAbsent
}

/// What this build could find for one comparison.
enum ApprovedGrounding: Sendable, CustomStringConvertible {
    /// An approved fixture record and the plan comparison that bounds it.
    case grounded(fixture: FixtureRecord, comparison: ComparisonSpecification)

    /// No approved expected value exists, for the stated reason.
    case notGrounded(reason: String)

    var description: String {
        switch self {
        case .grounded(let fixture, let comparison):
            "grounded on \(fixture.id.rawValue) under \(comparison.metric.rawValue)"
        case .notGrounded(let reason):
            "not grounded: \(reason)"
        }
    }

    var isGrounded: Bool {
        if case .grounded = self { return true }
        return false
    }
}

/// Reads the immutable approved fixture evidence this build carries, if any.
///
/// Read-only by construction, and that is the point of the task rather than an incidental
/// restriction. There is no member that creates, writes, renders, converts, or derives an
/// asset, and none that produces an expected result. A comparison whose approved value is
/// absent therefore has exactly one outcome available to it — a recorded absence or a
/// failure — because nothing behind this protocol can manufacture the value that would
/// make it pass.
protocol ApprovedImagePipelineEvidenceReading: Sendable {
    /// The approved expected value and tolerance for one comparison on one family.
    func grounding(
        for kind: ApprovedComparisonKind,
        family: FixtureFamily
    ) -> ApprovedGrounding

    /// The bytes of one catalogued asset, or why they could not be reached.
    func assetBytes(at path: CanonicalRelativePath) -> Result<[UInt8], ApprovedAssetFault>
}

/// The approved fixture evidence delivered alongside this test target.
///
/// The suite and the plan are signed release artifacts, so they are read rather than
/// built: this type looks for them at one documented location under the package root and
/// reports their absence when they are not there. It writes nothing and creates nothing,
/// so a run in which the artifacts are missing produces recorded absences, never a
/// generated baseline.
///
/// When the artifacts do land, every comparison below starts comparing without a test
/// edit, and a suite that decodes but whose asset is missing or whose declared digest
/// disagrees with the bytes is a **failure** rather than a skip — see
/// ``ApprovedComparator``.
struct DeliveredApprovedEvidence: ApprovedImagePipelineEvidenceReading {
    /// Where an approved suite would be delivered, relative to the package root.
    ///
    /// A lookup path, not an expected value. Nothing in this target writes here.
    static let suiteDirectoryName = "Fixtures/release-fixture-suite"
    static let suiteManifestName = "suite.canonical.json"
    static let planManifestName = "device-validation-plan.canonical.json"

    /// The package root, derived from this file's own location.
    ///
    /// `Tests/DefAIkeImagePipelineTests/<this file>` sits three levels below it. Derived
    /// rather than configured so the lookup cannot be pointed somewhere else by an
    /// environment that a release audit would not see.
    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var suiteDirectory: URL {
        packageRoot.appendingPathComponent(suiteDirectoryName, isDirectory: true)
    }

    /// The decoded suite and plan, or `nil` when either is absent or does not decode.
    ///
    /// A manifest that exists but does not decode is reported as an absence *with that
    /// reason*, so the two situations are distinguishable in the report and neither one
    /// silently becomes a passing comparison.
    let delivered: Delivered?

    struct Delivered: Sendable {
        let suite: ReleaseFixtureSuite
        let plan: DeviceValidationPlan
    }

    /// The reason nothing was delivered, when nothing was.
    let absenceReason: String

    init() {
        let directory = Self.suiteDirectory
        let suiteURL = directory.appendingPathComponent(Self.suiteManifestName)
        let planURL = directory.appendingPathComponent(Self.planManifestName)
        guard let suiteData = try? Data(contentsOf: suiteURL) else {
            delivered = nil
            absenceReason = """
                no approved Release Fixture Suite is delivered at \
                \(Self.suiteDirectoryName)/\(Self.suiteManifestName)
                """
            return
        }
        guard let planData = try? Data(contentsOf: planURL) else {
            delivered = nil
            absenceReason = """
                a suite manifest exists but no approved Device Validation Plan is \
                delivered at \(Self.suiteDirectoryName)/\(Self.planManifestName), so no \
                comparison has a declared metric or tolerance
                """
            return
        }
        let decoder = JSONDecoder()
        guard let suite = try? decoder.decode(ReleaseFixtureSuite.self, from: suiteData),
              let plan = try? decoder.decode(DeviceValidationPlan.self, from: planData)
        else {
            delivered = nil
            absenceReason = """
                the delivered suite or plan manifest does not decode against this build's \
                artifact schema, so nothing approved is available to compare against
                """
            return
        }
        delivered = Delivered(suite: suite, plan: plan)
        absenceReason = ""
    }

    func grounding(
        for kind: ApprovedComparisonKind,
        family: FixtureFamily
    ) -> ApprovedGrounding {
        guard let metric = kind.planMetric else {
            return .notGrounded(
                reason: """
                    the Device Validation Plan's comparison vocabulary has no metric for \
                    \(kind), so no approved tolerance can be declared for it
                    """
            )
        }
        guard let delivered else {
            return .notGrounded(reason: absenceReason)
        }
        guard let comparison = delivered.plan.comparison(for: metric) else {
            return .notGrounded(
                reason: """
                    the delivered plan declares no \(metric.rawValue) comparison, so \
                    \(kind) has no approved tolerance
                    """
            )
        }
        let candidates = delivered.suite.fixtures(in: family).filter { fixture in
            fixture.expectations.contains { expectation in
                if case .preprocessingOutputDigest = expectation { return true }
                return false
            }
        }
        guard let fixture = candidates.first else {
            return .notGrounded(
                reason: """
                    the delivered suite catalogues no \(family.rawValue) fixture with an \
                    approved preprocessing-output expectation
                    """
            )
        }
        return .grounded(fixture: fixture, comparison: comparison)
    }

    func assetBytes(at path: CanonicalRelativePath) -> Result<[UInt8], ApprovedAssetFault> {
        guard delivered != nil else { return .failure(.suiteAbsent) }
        let url = Self.suiteDirectory.appendingPathComponent(path.rawValue)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            return .failure(.assetMissing)
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.assetUnreadable)
        }
        return .success([UInt8](data))
    }
}

// MARK: - The comparator

/// The outcome of comparing one produced value against one approved expected value.
enum ApprovedComparisonOutcome: Equatable, Sendable, CustomStringConvertible {
    /// The produced value matched the approved expected value.
    case agreed

    /// The produced value did not match. A release finding.
    case disagreed(detail: String)

    /// The comparison could not be performed and must not be treated as passing.
    case failedClosed(reason: String)

    /// No approved expected value exists, so nothing was compared.
    case notPerformed(reason: String)

    var description: String {
        switch self {
        case .agreed: "agreed"
        case .disagreed(let detail): "disagreed: \(detail)"
        case .failedClosed(let reason): "failed closed: \(reason)"
        case .notPerformed(let reason): "not performed: \(reason)"
        }
    }
}

/// Compares produced preprocessing output against one approved fixture's expected result.
///
/// Deliberately small. Task 14.2 owns the nonshipping parity **runners** that drive whole
/// families against a bound plan; this is only the minimum that lets the five comparisons
/// above be honest, and it computes no expected value of its own.
///
/// The order of the checks is the point:
///
///   1. The asset has to exist, and a missing one is ``failedClosed`` — never skipped and
///      never completed from the produced bytes.
///   2. The asset's bytes have to hash to the digest the catalogue declares, so a mutated
///      asset is a finding rather than a new baseline.
///   3. The fixture has to declare a preprocessing-output expectation, because a fixture
///      with no expectation for the comparison being run tests nothing.
///   4. Only then is the produced value compared, and only against the declared digest.
///
/// The comparison is over digests under an exact tolerance. A non-exact declared tolerance
/// is ``failedClosed`` rather than approximated: a digest has no metric on it, so there is
/// nothing for a nonzero tolerance to bound, and inventing one would be inventing an
/// approved value.
enum ApprovedComparator {
    static func compare(
        producedPreprocessingOutput produced: [UInt8],
        against grounding: ApprovedGrounding,
        reading evidence: some ApprovedImagePipelineEvidenceReading
    ) -> ApprovedComparisonOutcome {
        let fixture: FixtureRecord
        let comparison: ComparisonSpecification
        switch grounding {
        case .notGrounded(let reason):
            // The only outcome available with no approved expected value. There is
            // deliberately no branch here that could derive one from `produced`.
            return .notPerformed(reason: reason)
        case .grounded(let groundedFixture, let groundedComparison):
            fixture = groundedFixture
            comparison = groundedComparison
        }
        let assetBytes: [UInt8]
        switch evidence.assetBytes(at: fixture.assetPath) {
        case .success(let bytes):
            assetBytes = bytes
        case .failure(let fault):
            return .failedClosed(
                reason: """
                    the catalogued asset for \(fixture.id.rawValue) could not be read \
                    (\(fault)); an absent asset is a finding, not a comparison to skip
                    """
            )
        }
        guard Fixture.digest(of: assetBytes) == fixture.contentDigest else {
            return .failedClosed(
                reason: """
                    the asset for \(fixture.id.rawValue) does not hash to its catalogued \
                    content digest, so it is not the bytes the expectations were approved \
                    over
                    """
            )
        }
        guard UInt64(assetBytes.count) == fixture.byteCount.value else {
            return .failedClosed(
                reason: """
                    the asset for \(fixture.id.rawValue) is \(assetBytes.count) bytes, not \
                    the catalogued \(fixture.byteCount.value)
                    """
            )
        }
        var expected: DefAIkeDomain.SHA256Digest?
        for expectation in fixture.expectations {
            if case .preprocessingOutputDigest(let digest) = expectation { expected = digest }
        }
        guard let expected else {
            return .failedClosed(
                reason: """
                    \(fixture.id.rawValue) declares no approved preprocessing-output \
                    expectation, so there is nothing approved to compare against
                    """
            )
        }
        guard let tolerance = comparison.tolerance, tolerance.kind == .exact else {
            return .failedClosed(
                reason: """
                    the declared \(comparison.metric.rawValue) tolerance is not exact, and \
                    a digest comparison has no metric a nonzero tolerance could bound
                    """
            )
        }
        let producedDigest = Fixture.digest(of: produced)
        guard producedDigest == expected else {
            return .disagreed(
                detail: """
                    produced preprocessing output does not match the approved digest for \
                    \(fixture.id.rawValue)
                    """
            )
        }
        return .agreed
    }
}

// MARK: - The real pipeline harness

/// One Analysis Session's worth of the real pipeline: ingest store, validator,
/// preprocessor, quality ledger, and both adapter-owned stores.
///
/// Every collaborator except the encoded-asset store is the shipping adapter. The store is
/// ``InMemoryEncodedAssetStore``, which is a real streaming store with a real SHA-256 —
/// byte identity and not-finalized behaviour actually hold — and it keeps these tests off
/// a protected file-system container, which is where the other test targets' data-
/// protection flakes come from.
private struct RealPipeline {
    let store = InMemoryEncodedAssetStore()
    let decodedImages = DecodedImageStore()
    let modelInputs = PreparedModelInputStore()
    let quality = InputQualityLedger()
    let contract: PreprocessingContract
    let budget: ResourceBudget
    let validator: ImageIOInputValidator
    let preprocessor: ContractImagePreprocessor

    init(
        contract: PreprocessingContract = PreprocessingFixture.contract(),
        budget: ResourceBudget = ResourceFixture.budget()
    ) {
        self.contract = contract
        self.budget = budget
        validator = ImageIOInputValidator(
            encodedAssets: store,
            decodedImages: decodedImages,
            quality: quality
        )
        preprocessor = ContractImagePreprocessor(
            encodedAssets: store,
            decodedImages: decodedImages,
            modelInputs: modelInputs
        )
    }

    /// The whole chain: ingest, validate, prepare.
    func run(
        _ bytes: [UInt8],
        sessionID: AnalysisSessionID = Fixture.sessionID(),
        route: InputRoute = .photosPicker
    ) async throws -> Result<Prepared, AnalysisFault> {
        let asset = try await IngestFixture.asset(
            bytes: bytes,
            in: store,
            sessionID: sessionID,
            route: route
        )
        do {
            let validated = try await validator.validate(
                asset,
                contract: contract,
                budget: budget
            )
            let input = try await preprocessor.prepare(
                validated,
                contract: contract,
                budget: budget
            )
            guard let prepared = await modelInputs.preparedInput(for: input.buffer) else {
                return .failure(.analysis(.preprocessingError, stage: .preprocessing))
            }
            return .success(Prepared(validated: validated, input: input, bytes: prepared.bytes))
        } catch {
            return .failure(error)
        }
    }

    /// The chain's output, with the measurements taken along the way.
    struct Prepared: Sendable {
        let validated: ValidatedImage
        let input: ModelImageInput
        /// Tightly packed, row-major, three bytes a pixel, exactly as produced.
        let bytes: [UInt8]
    }

    /// The observed metadata for `bytes`, read the way the preprocessor reads it.
    ///
    /// Uses the real reader and the real inspector over the real container, so what is
    /// asserted is what the pipeline saw rather than what a fixture claimed.
    static func observedMetadata(of bytes: [UInt8]) -> ObservedImageMetadata? {
        guard let source = EncodedImageSource(bytes: bytes),
              let image = source.decodeCompleteImage(at: 0)
        else {
            return nil
        }
        return ImageMetadataInspector.observe(
            properties: source.metadataDeclarations(at: 0),
            image: image
        )
    }
}

/// Bytes the model input must hold: the requirement's own crop edge, three channels.
private var boundModelInputByteCount: Int {
    CenterCropContract.requiredEdge * CenterCropContract.requiredEdge * 3
}

private func analysisError(
    _ result: Result<RealPipeline.Prepared, AnalysisFault>
) -> AnalysisError? {
    guard case .failure(let fault) = result else { return nil }
    return fault.analysisError
}

// MARK: - Real container families

extension Tag {
    /// Task 5.10: real-framework image pipeline integration.
    @Tag static var realFrameworkImagePipeline: Self
}

/// Real encoded containers through the real validator and preprocessor.
///
/// Host Image I/O, Core Graphics, ColorSync, and Accelerate results are development
/// checks. They are never physical-device release evidence for any pixel-level claim
/// (Requirements 13.6 and 13.9).
@Suite(
    "Real-framework image pipeline: container families",
    .tags(.realFrameworkImagePipeline)
)
struct RealFrameworkContainerFamilyTests {
    /// A lossless container over `image`, so a byte comparison between two bound contracts
    /// compares the transform rather than an encoder's noise.
    private func png(_ image: CGImage) throws -> [UInt8] {
        try #require(DeclaringImageFixture.encode(image, as: .png, properties: [:]))
    }

    /// The container each Version 1 static container is encoded as.
    static func utType(for container: StaticContainer) -> UTType {
        switch container {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .heif: .heif
        }
    }

    /// Containers this host has an Image I/O encoder for. Measured, not assumed.
    static let encodable = StaticContainer.allCases.filter {
        EncodedImageFixture.canEncode(utType(for: $0))
    }

    /// Containers this host cannot encode, so no real container can be produced for them.
    static let unencodable = StaticContainer.allCases.filter {
        !EncodedImageFixture.canEncode(utType(for: $0))
    }

    /// Every Supported Static Image container this host can encode, end to end.
    ///
    /// Self-evident assertions only: the container is classified as itself, the recorded
    /// pre-orientation pair is the pair the encoder was handed, the short edge is
    /// `min(width, height)` of that unswapped pair, and the produced model input is the
    /// bound crop's shape and byte count. Requirements 3.1, 3.2, 3.5, 3.6, 4.3, 4.5, 4.6.
    ///
    /// Absolute sample values are deliberately absent: they need an approved expected
    /// artifact, and `RealFrameworkApprovedComparisonTests` reports that none exists. The
    /// containers this list leaves out are named and accounted for by
    /// ``unencodableContainersAreNamedAndUnfixtured()`` rather than passed over.
    @Test(
        "Every supported container this host can encode decodes and produces the bound input",
        arguments: RealFrameworkContainerFamilyTests.encodable
    )
    func supportedContainerRunsEndToEnd(container: StaticContainer) async throws {
        let type = Self.utType(for: container)
        let source = EncodedImageFixture.gradient(width: 60, height: 44)
        let bytes = try #require(EncodedImageFixture.encode(source, as: type))

        let pipeline = RealPipeline()
        let prepared = try await pipeline.run(bytes).get()

        #expect(prepared.validated.container == container)
        #expect(prepared.validated.dimensions.width == 60)
        #expect(prepared.validated.dimensions.height == 44)
        #expect(prepared.validated.dimensions.shortEdge == 44)
        #expect(prepared.validated.quality.decodedWidthBeforeOrientation == 60)
        #expect(prepared.validated.quality.decodedHeightBeforeOrientation == 44)
        #expect(prepared.validated.quality.shortEdgeBeforeOrientation == 44)

        #expect(prepared.input.edge == CenterCropContract.requiredEdge)
        #expect(prepared.input.channelOrder == .rgb)
        #expect(prepared.input.elementType == .uint8)
        #expect(prepared.bytes.count == boundModelInputByteCount)

        // The real ledger recorded the same unswapped pair the port reports.
        let record = try #require(
            await pipeline.quality.qualityRecord(for: prepared.validated.sessionID)
        )
        #expect(record.decodedWidthBeforeOrientation == 60)
        #expect(record.decodedHeightBeforeOrientation == 44)
    }

    /// The containers this host cannot produce, named rather than skipped in silence.
    ///
    /// Requirement 13.4 requires a HEIC/HEIF fixture family, and Image I/O on this host
    /// offers a `public.heic` encoder but no `public.heif` one. So the HEIF half is
    /// reachable only from an approved fixture asset, and this build carries none: the
    /// container matrix above therefore has a hole, and this test is where it is recorded.
    ///
    /// Both halves are asserted deliberately as tripwires. If a HEIF encoder appears, or an
    /// approved HEIF fixture is delivered, this test fails and the matrix above has to be
    /// extended — which is the point. A silent skip would keep the hole invisible forever.
    @Test("Containers this host cannot encode are named, and none of them is fixtured")
    func unencodableContainersAreNamedAndUnfixtured() {
        #expect(
            Self.unencodable == [.heif],
            """
            the set of containers this host cannot encode has changed to \
            \(Self.unencodable.map(\.rawValue)); extend the container matrix
            """
        )
        let evidence = DeliveredApprovedEvidence()
        for kind in ApprovedComparisonKind.allCases {
            let grounding = evidence.grounding(for: kind, family: .heifContainer)
            #expect(
                grounding.isGrounded == false,
                """
                an approved HEIF fixture is now delivered for \(kind); the container \
                matrix must compare against it instead of reporting its absence
                """
            )
        }
    }

    /// Requirement 2.14 through the whole pipeline, not just through validation.
    ///
    /// `InputValidationTests` already pins that byte-identical input through either route
    /// *validates* identically. What is new here is that it also *prepares* identically:
    /// the requirement is about the accepted decoded input's dimensions and RGB sample
    /// values, and the model input is where those samples end up. Self-evident, because
    /// the expected value is the other run rather than a stored artifact.
    @Test("Byte-identical input through either route produces identical model-input bytes")
    func routeParityReachesTheModelInput() async throws {
        let bytes = try png(EncodedImageFixture.gradient(width: 70, height: 52))

        let viaPicker = RealPipeline()
        let viaShare = RealPipeline()
        let picked = try await viaPicker.run(
            bytes,
            sessionID: Fixture.sessionID("session-picker"),
            route: .photosPicker
        ).get()
        let shared = try await viaShare.run(
            bytes,
            sessionID: Fixture.sessionID("session-share"),
            route: .shareExtension
        ).get()

        #expect(picked.validated.dimensions == shared.validated.dimensions)
        #expect(picked.validated.container == shared.validated.container)
        #expect(Fixture.digest(of: picked.bytes) == Fixture.digest(of: shared.bytes))
        #expect(picked.bytes.count == boundModelInputByteCount)
        // Different sessions, so the equality is about the bytes and not about a shared
        // cache entry.
        #expect(picked.validated.sessionID != shared.validated.sessionID)
    }

    /// The whole chain is a function of the encoded bytes and the bound contract.
    ///
    /// Two independent pipelines over the same container, so nothing is shared between the
    /// runs but the input. Self-evident.
    @Test("The same container through two independent pipelines produces the same bytes")
    func theChainIsDeterministic() async throws {
        let bytes = try png(EncodedImageFixture.gradient(width: 91, height: 63))
        let first = try await RealPipeline().run(bytes).get()
        let second = try await RealPipeline().run(bytes).get()
        #expect(Fixture.digest(of: first.bytes) == Fixture.digest(of: second.bytes))
        #expect(first.bytes.count == boundModelInputByteCount)
    }

    /// A real unsupported or unreadable container leaves nothing behind in either store.
    ///
    /// Property 3 already quantifies the classification and the nonoccurrence of the
    /// downstream stages, with recording doubles in place of the adapters. This asserts the
    /// remaining integration fact those doubles cannot: with the **real** decoded-image and
    /// prepared-input stores in the chain, a refused input retains no decoded image and no
    /// prepared buffer. Requirements 1.11 through 1.14, 3.3, and 3.12.
    @Test(
        "A refused real container retains no decoded image and no prepared model input",
        arguments: RefusedContainer.allCases
    )
    func refusedContainersLeaveNoResidue(kind: RefusedContainer) async throws {
        let bytes = try #require(
            kind.bytes(),
            "this host cannot encode the \(kind) container"
        )
        let pipeline = RealPipeline()
        let result = try await pipeline.run(bytes)

        #expect(analysisError(result) == kind.expectedError)
        #expect(await pipeline.decodedImages.retainedImageCount == 0)
        #expect(await pipeline.modelInputs.retainedInputCount == 0)

        // The control. "Nothing was retained" passes when nothing happened for the wrong
        // reason, so one accepted container goes through the same two stores on every case
        // to prove they would have held something had the input been accepted.
        let control = RealPipeline()
        let accepted = try await control.run(
            try png(EncodedImageFixture.gradient(width: 52, height: 48))
        ).get()
        #expect(accepted.bytes.count == boundModelInputByteCount)
        #expect(await control.decodedImages.retainedImageCount == 1)
        #expect(await control.modelInputs.retainedInputCount == 1)
    }

    /// Real containers the pipeline must refuse, and the one error each produces.
    ///
    /// The expected error for each is fixed by the requirement text and already pinned per
    /// container by `ContainerClassificationTests`; it is restated here only so the residue
    /// assertion is not made about an input that failed for an unrelated reason.
    enum RefusedContainer: CaseIterable, Sendable, CustomStringConvertible {
        case animatedGIF
        case animatedPNG
        case heicSequence
        case truncatedJPEG
        case singleFrameTIFF
        case unidentifiableBytes

        var description: String {
            switch self {
            case .animatedGIF: "animated GIF"
            case .animatedPNG: "animated PNG"
            case .heicSequence: "HEIC sequence"
            case .truncatedJPEG: "truncated JPEG"
            case .singleFrameTIFF: "single-frame TIFF"
            case .unidentifiableBytes: "unidentifiable bytes"
            }
        }

        var expectedError: AnalysisError {
            switch self {
            case .animatedGIF, .animatedPNG, .heicSequence: .unsupportedMedia
            case .singleFrameTIFF: .unsupportedStaticFormat
            case .truncatedJPEG, .unidentifiableBytes: .decodingError
            }
        }

        func bytes() -> [UInt8]? {
            let image = EncodedImageFixture.gradient(width: 40, height: 24)
            switch self {
            case .animatedGIF:
                return EncodedImageFixture.encode(image, as: .gif, frameCount: 3)
            case .animatedPNG:
                return EncodedImageFixture.encode(image, as: .png, frameCount: 3)
            case .heicSequence:
                guard let heics = UTType("public.heics") else { return nil }
                return EncodedImageFixture.encode(image, as: heics, frameCount: 3)
            case .truncatedJPEG:
                return EncodedImageFixture.truncatedJPEG(fraction: 0.4)
            case .singleFrameTIFF:
                return EncodedImageFixture.encode(image, as: .tiff)
            case .unidentifiableBytes:
                return EncodedImageFixture.unidentifiableBytes
            }
        }
    }
}

// MARK: - Metadata families

/// Real containers whose declarations drive the contract's metadata actions.
@Suite(
    "Real-framework image pipeline: metadata families",
    .tags(.realFrameworkImagePipeline)
)
struct RealFrameworkMetadataFamilyTests {
    private func png(_ image: CGImage) throws -> [UInt8] {
        try #require(DeclaringImageFixture.encode(image, as: .png, properties: [:]))
    }

    /// A contract that applies the declared orientation in every observed state.
    private func applying() -> PreprocessingContract {
        PreprocessingFixture.contract(
            id: "preprocessing-apply-orientation",
            orientation: .applyDeclaredOrientation
        )
    }

    /// A contract that ignores the declared orientation in every observed state.
    private func ignoring() -> PreprocessingContract {
        PreprocessingFixture.contract(
            id: "preprocessing-ignore-orientation",
            orientation: .ignoreDeclaredOrientation
        )
    }

    /// Requirements 3.5, 3.6, 3.7, 3.8, and 4.4 on one real container per orientation.
    ///
    /// Three self-evident claims, and no absolute sample value:
    ///
    ///   * The pre-orientation record is the **stored** pair whatever the container
    ///     declares. Image I/O returns stored pixels and stored dimensions, so the encoder's
    ///     own 62-by-40 input is the expected value.
    ///   * Under `.topLeft` the two bound orientation actions agree byte for byte, because
    ///     the declared transform is the identity.
    ///   * Under every other value they disagree, because each of the remaining seven
    ///     permutes a source that is asymmetric in both axes. Four of them additionally
    ///     exchange the axes, which changes the resized long edge and therefore the crop.
    @Test(
        "A real container's declared orientation reaches the geometry but not the record",
        arguments: ExifOrientation.allCases
    )
    func declaredOrientationDrivesTheGeometryOnly(orientation: ExifOrientation) async throws {
        let bytes = try #require(
            DeclaringImageFixture.jpeg(orientation: orientation.rawValue, width: 62, height: 40)
        )
        let observed = try #require(RealPipeline.observedMetadata(of: bytes))
        #expect(observed.orientation == .valid)
        #expect(observed.declaredOrientation == orientation)

        let applied = try await RealPipeline(contract: applying()).run(bytes).get()
        let ignored = try await RealPipeline(contract: ignoring()).run(bytes).get()

        // Requirement 3.5's record is the decoded pair before orientation is applied, so
        // it is the same under both actions and is never swapped by the declaration.
        for prepared in [applied, ignored] {
            #expect(prepared.validated.dimensions.width == 62)
            #expect(prepared.validated.dimensions.height == 40)
            #expect(prepared.validated.dimensions.shortEdge == 40)
            #expect(prepared.bytes.count == boundModelInputByteCount)
        }

        // Compared by digest rather than element by element: the arrays are 442,368 bytes
        // each, and a failed inequality on the raw arrays would print both of them.
        let appliedDigest = Fixture.digest(of: applied.bytes)
        let ignoredDigest = Fixture.digest(of: ignored.bytes)
        if orientation == .topLeft {
            #expect(appliedDigest == ignoredDigest)
        } else {
            #expect(
                appliedDigest != ignoredDigest,
                "orientation \(orientation.rawValue) must permute the pixels"
            )
        }
    }

    /// A hand-assembled PNG declaring nothing at all still runs.
    ///
    /// `absent` is the only other state a real container reaches on this host, and getting
    /// both fields into it at once needs a container no encoder here writes: Image I/O
    /// writes a profile for any source carrying a named colour space, and its HEIC writer
    /// always writes an orientation. ``RawPNG`` is the one container that declares neither.
    @Test("A container declaring no orientation and no profile runs under an absent-state action")
    func absentDeclarationsRunUnderTheirBoundAction() async throws {
        let bytes = RawPNG.withoutColorChunks(width: 58, height: 46)
        let observed = try #require(RealPipeline.observedMetadata(of: bytes))
        #expect(observed.orientation == .absent)
        #expect(observed.colorProfile == .absent)
        #expect(observed.alpha == .absent)
        #expect(observed.carriesAlphaChannel == false)

        // An absent embedded profile has nothing to convert from, so the action bound to
        // that state here is assignment. Which action a release binds is decision D10 and
        // is asserted nowhere.
        let contract = PreprocessingFixture.contract(
            id: "preprocessing-absent-declarations",
            orientation: .ignoreDeclaredOrientation,
            colorProfileRules: PreprocessingFixture.rules([
                .valid: .convertToWorkingSpace,
                .absent: .assignWorkingSpaceWithoutConversion,
                .malformed: .rejectAsPreprocessingError,
                .unsupported: .rejectAsPreprocessingError,
            ])
        )
        let prepared = try await RealPipeline(contract: contract).run(bytes).get()
        #expect(prepared.validated.container == .png)
        #expect(prepared.validated.dimensions.shortEdge == 46)
        #expect(prepared.bytes.count == boundModelInputByteCount)
    }

    /// A real wide-gamut container, and the two profile actions that disagree on it.
    ///
    /// Self-evident: converting Display P3 samples into an sRGB working space and
    /// relabelling them as sRGB samples are different operations, so they cannot produce
    /// the same bytes for a source with saturated colour. Which of the two a release binds
    /// is decision D10. The absolute converted sample values need an approved expected
    /// artifact and are not asserted.
    @Test("A real Display P3 container converts and assigns to different model-input bytes")
    func wideGamutConversionAndAssignmentDisagree() async throws {
        let wide = SourceImageFixture.interleaved32(
            width: 66,
            height: 48,
            pixels: saturatedPixels(width: 66, height: 48),
            space: SourceImageFixture.displayP3,
            alpha: .noneSkipLast
        )
        let bytes = try png(wide)

        let observed = try #require(RealPipeline.observedMetadata(of: bytes))
        #expect(
            observed.colorProfile == .valid,
            "Image I/O's PNG writer embeds the source's Display P3 profile"
        )

        let converted = try await RealPipeline(
            contract: PreprocessingFixture.contract(
                id: "preprocessing-convert-profile",
                colorProfile: .convertToWorkingSpace
            )
        ).run(bytes).get()
        let assigned = try await RealPipeline(
            contract: PreprocessingFixture.contract(
                id: "preprocessing-assign-profile",
                colorProfile: .assignWorkingSpaceWithoutConversion
            )
        ).run(bytes).get()

        #expect(converted.bytes.count == boundModelInputByteCount)
        #expect(assigned.bytes.count == boundModelInputByteCount)
        #expect(
            Fixture.digest(of: converted.bytes) != Fixture.digest(of: assigned.bytes),
            "converting Display P3 into sRGB must not agree with relabelling it as sRGB"
        )
    }

    /// Saturated colours that are nonetheless inside the sRGB gamut.
    ///
    /// Both halves of that matter. A desaturated source converts almost to itself, so the
    /// disagreement above would be a rounding artefact rather than a colour-management
    /// fact. A *fully* saturated source is worse: Display P3's primaries lie outside sRGB,
    /// so converting `(255, 0, 0)` clips straight back to `(255, 0, 0)` and the two actions
    /// agree exactly — measured on this host, not assumed. Three saturated but in-gamut
    /// triples separate them across most of the buffer.
    private func saturatedPixels(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let triples: [(UInt8, UInt8, UInt8)] = [(210, 70, 55), (60, 200, 90), (70, 80, 205)]
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let triple = triples[(x / 8 + y / 8) % triples.count]
                pixels[offset] = triple.0
                pixels[offset + 1] = triple.1
                pixels[offset + 2] = triple.2
            }
        }
        return pixels
    }

    /// A real container with an alpha channel, and the three alpha actions that disagree.
    ///
    /// Self-evident: discarding alpha keeps the unpremultiplied colour channels, and
    /// compositing over black and over white move a partially transparent pixel in
    /// opposite directions, so no two of the three can produce the same bytes for a source
    /// whose alpha varies across the crop. Which action and which background a release
    /// binds is decision D10, and the absolute composited values need an approved artifact.
    @Test("A real alpha container discards and composites to three different model inputs")
    func alphaActionsDisagreeOnARealContainer() async throws {
        let bytes = try png(alphaGradient(width: 120, height: 80))
        let observed = try #require(RealPipeline.observedMetadata(of: bytes))
        #expect(observed.alpha == .valid)
        #expect(observed.carriesAlphaChannel)

        let discarded = try await run(
            alpha: .discardAlphaChannel,
            id: "alpha-discard",
            bytes: bytes
        )
        let overBlack = try await run(
            alpha: .compositeOverOpaqueBackground(
                OpaqueBackgroundColor(red: 0, green: 0, blue: 0)
            ),
            id: "alpha-black",
            bytes: bytes
        )
        let overWhite = try await run(
            alpha: .compositeOverOpaqueBackground(
                OpaqueBackgroundColor(red: 255, green: 255, blue: 255)
            ),
            id: "alpha-white",
            bytes: bytes
        )

        for produced in [discarded, overBlack, overWhite] {
            #expect(produced.count == boundModelInputByteCount)
        }
        let digests = [discarded, overBlack, overWhite].map(Fixture.digest(of:))
        #expect(Set(digests).count == 3, "the three bound alpha actions must not agree")
    }

    private func run(
        alpha: AlphaAction,
        id: String,
        bytes: [UInt8]
    ) async throws -> [UInt8] {
        try await RealPipeline(
            contract: PreprocessingFixture.contract(id: "preprocessing-\(id)", alpha: alpha)
        ).run(bytes).get().bytes
    }

    /// A premultiplied source whose alpha varies across the whole width.
    ///
    /// Premultiplied is what Image I/O's PNG writer accepts and what its reader hands back,
    /// so this is the layout a real transparent container actually presents.
    private func alphaGradient(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let alpha = UInt8((x * 255) / max(width - 1, 1))
                // Premultiplied: no channel may exceed its alpha.
                pixels[offset] = min(UInt8((x * 211) / max(width - 1, 1)), alpha)
                pixels[offset + 1] = min(UInt8((y * 197) / max(height - 1, 1)), alpha)
                pixels[offset + 2] = min(UInt8((x + y) % 151), alpha)
                pixels[offset + 3] = alpha
            }
        }
        return SourceImageFixture.interleaved32(
            width: width,
            height: height,
            pixels: pixels,
            space: SourceImageFixture.sRGB,
            alpha: .premultipliedLast
        )
    }

    /// A real single-channel container reaches the bound three-channel model input.
    ///
    /// Three self-evident claims, and the middle one is the strongest sample-level statement
    /// available here without an approved artifact:
    ///
    ///   * Converting one grey channel into the RGB working space is applicable and produces
    ///     the bound buffer.
    ///   * Every produced pixel is neutral. One input channel drives all three output
    ///     channels through the same transform, and the resize applies identical weights to
    ///     identical samples, so `red == green == blue` must hold for all 147,456 pixels. A
    ///     channel swap, a per-channel scale, or a stride error anywhere in the chain breaks
    ///     it, and no expected value has to be looked up to know it.
    ///   * *Relabelling* the grey channel as three RGB channels is not a reinterpretation,
    ///     so it is refused with `preprocessing-error` rather than approximated.
    ///
    /// Requirements 3.9, 3.11, 4.3, and 4.6. The source is tagged generic grey rather than
    /// device grey, because Image I/O writes no profile for a device space and the container
    /// would then present the `absent` profile state instead of the `valid` one — measured
    /// on this host, and the reason the fixture choice is spelled out.
    @Test("A real grayscale container converts into a neutral bound RGB input")
    func grayscaleContainerConvertsAndRefusesAssignment() async throws {
        let bytes = try png(SourceImageFixture.grayscale(width: 96, height: 60))
        let observed = try #require(RealPipeline.observedMetadata(of: bytes))
        #expect(observed.colorProfile == .valid)
        #expect(observed.carriesAlphaChannel == false)

        let converted = try await RealPipeline(
            contract: PreprocessingFixture.contract(
                id: "preprocessing-gray-convert",
                colorProfile: .convertToWorkingSpace
            )
        ).run(bytes).get()
        #expect(converted.validated.container == .png)
        #expect(converted.validated.dimensions.shortEdge == 60)
        #expect(converted.bytes.count == boundModelInputByteCount)

        var neutralPixelCount = 0
        var offset = 0
        while offset < converted.bytes.count {
            let red = converted.bytes[offset]
            let green = converted.bytes[offset + 1]
            let blue = converted.bytes[offset + 2]
            if red == green, green == blue { neutralPixelCount += 1 }
            offset += 3
        }
        #expect(neutralPixelCount == converted.bytes.count / 3)

        let assigned = try await RealPipeline(
            contract: PreprocessingFixture.contract(
                id: "preprocessing-gray-assign",
                colorProfile: .assignWorkingSpaceWithoutConversion
            )
        ).run(bytes)
        #expect(analysisError(assigned) == .preprocessingError)
    }
}

// MARK: - Geometry families

/// Real containers at the aspect ratios and dimension limits the task names.
@Suite(
    "Real-framework image pipeline: geometry families",
    .tags(.realFrameworkImagePipeline)
)
struct RealFrameworkGeometryFamilyTests {
    private func png(_ image: CGImage) throws -> [UInt8] {
        try #require(DeclaringImageFixture.encode(image, as: .png, properties: [:]))
    }

    /// An extreme aspect ratio still produces the bound crop.
    ///
    /// Self-evident, and it is the integration fact the geometry property test cannot
    /// state: the resized image is never materialized, so a ratio whose resized long edge
    /// runs to hundreds of thousands of pixels costs the pipeline only the decoded source,
    /// the rendered surface, and the 384-by-384 crop. The recorded short edge stays the
    /// source's, which is what the sub-440 abstention rule reads.
    @Test(
        "An extreme aspect ratio produces the bound crop and keeps the recorded short edge",
        arguments: [
            (width: 8_800, height: 4),
            (width: 4, height: 8_800),
            (width: 4_400, height: 20),
            (width: 20, height: 4_400),
        ]
    )
    func extremeAspectRatiosProduceTheBoundCrop(size: (width: Int, height: Int)) async throws {
        let bytes = try png(
            EncodedImageFixture.gradient(width: size.width, height: size.height)
        )
        let pipeline = RealPipeline()
        let prepared = try await pipeline.run(bytes).get()

        #expect(prepared.validated.dimensions.width == size.width)
        #expect(prepared.validated.dimensions.height == size.height)
        #expect(prepared.validated.dimensions.shortEdge == min(size.width, size.height))
        #expect(prepared.input.edge == CenterCropContract.requiredEdge)
        #expect(prepared.bytes.count == boundModelInputByteCount)

        // The same geometry the pipeline used, resolved independently from the oriented
        // dimensions. The bound orientation action here is to ignore the declaration, so
        // the oriented pair is the decoded pair.
        let geometry = try ResizeGeometry.resolve(
            source: prepared.validated.dimensions,
            resize: pipeline.contract.resize,
            crop: pipeline.contract.crop
        )
        #expect(geometry.resized.shortEdge == ResizeContract.requiredShortEdge)
        #expect(geometry.crop.size.width == CenterCropContract.requiredEdge)
        #expect(geometry.crop.size.height == CenterCropContract.requiredEdge)
        #expect(geometry.crop.isContained(in: geometry.resized))
    }

    /// Real containers at and around the recorded-short-edge boundary.
    ///
    /// The 439/440 pair is the boundary the sub-440 abstention rule reads, and 1 is the
    /// smallest decodable source. All three still produce the bound crop, because the
    /// resize sets the short edge to 440 whether that is a downscale or an upscale.
    /// Self-evident. Which outcome a short edge of 439 produces is the Calibration Policy's
    /// decision and is asserted nowhere here.
    @Test(
        "A real container at the recorded-short-edge boundary still produces the bound crop",
        arguments: [
            (width: 439, height: 900),
            (width: 440, height: 900),
            (width: 900, height: 439),
            (width: 440, height: 440),
            (width: 8, height: 8),
        ]
    )
    func dimensionBoundariesProduceTheBoundCrop(size: (width: Int, height: Int)) async throws {
        let bytes = try png(
            EncodedImageFixture.gradient(width: size.width, height: size.height)
        )
        let prepared = try await RealPipeline().run(bytes).get()

        #expect(prepared.validated.dimensions.shortEdge == min(size.width, size.height))
        #expect(prepared.input.edge == CenterCropContract.requiredEdge)
        #expect(prepared.bytes.count == boundModelInputByteCount)
    }

    /// A one-pixel container upscales to a uniform crop of exactly that pixel.
    ///
    /// The sharpest self-evident sample claim available without an approved artifact: every
    /// bilinear weight set sums to its denominator, and every tap on a single-sample source
    /// folds to that one sample under any edge rule, so all 147,456 pixels of the crop must
    /// be the source pixel exactly. A scaling or a normalization anywhere in the chain
    /// would move it, and a colour conversion into the same space cannot.
    @Test("A one-pixel container fills the bound crop with exactly that pixel")
    func onePixelContainerFillsTheCrop() async throws {
        let pixel: (red: UInt8, green: UInt8, blue: UInt8) = (37, 211, 94)
        let bytes = try png(
            SourceImageFixture.interleaved32(
                width: 1,
                height: 1,
                pixels: [pixel.red, pixel.green, pixel.blue, 0],
                space: SourceImageFixture.sRGB,
                alpha: .noneSkipLast
            )
        )
        let prepared = try await RealPipeline().run(bytes).get()

        #expect(prepared.validated.dimensions.width == 1)
        #expect(prepared.validated.dimensions.height == 1)
        #expect(prepared.bytes.count == boundModelInputByteCount)
        for offset in stride(from: 0, to: prepared.bytes.count, by: 3) {
            try #require(prepared.bytes[offset] == pixel.red, "red at byte \(offset)")
            try #require(prepared.bytes[offset + 1] == pixel.green, "green at byte \(offset)")
            try #require(prepared.bytes[offset + 2] == pixel.blue, "blue at byte \(offset)")
        }
    }

    /// A declared pixel count above the bound budget stops before the decode's allocation.
    ///
    /// `InputValidationTests` pins each budget breach on its own; what this adds is that a
    /// real container refused by the budget leaves neither store populated, which is the
    /// integration half. Requirement 3.4.
    @Test("A real container above the bound pixel budget retains nothing")
    func aBudgetRefusalRetainsNothing() async throws {
        let bytes = try png(EncodedImageFixture.gradient(width: 900, height: 700))
        let pipeline = RealPipeline(
            budget: ResourceFixture.budget(
                overrides: [.decodedPixelCount: ResourceFixture.numeric(1_000, .pixels)]
            )
        )
        let result = try await pipeline.run(bytes)

        #expect(analysisError(result) == .resourceLimit)
        #expect(await pipeline.decodedImages.retainedImageCount == 0)
        #expect(await pipeline.modelInputs.retainedInputCount == 0)
        // Requirement 3.14: the status established before the failure survives it.
        #expect(
            await pipeline.quality.bytePreservationStatus(for: Fixture.sessionID()) != nil
        )
    }
}

// MARK: - The approved-artifact report

/// Which of the five comparisons this build can ground in an approved artifact.
///
/// This suite performs no pixel comparison of its own. Its whole job is to make the
/// grounding question explicit and total, so a reader can tell from a test run which
/// claims rest on an approved expected value and which do not — and so the day an approved
/// suite is delivered, the comparisons start running without a test edit.
@Suite(
    "Real-framework image pipeline: approved-artifact grounding",
    .tags(.realFrameworkImagePipeline)
)
struct RealFrameworkApprovedComparisonTests {
    /// The fixture families task 5.10's containers and metadata map onto.
    private static let families: [FixtureFamily] = [
        .jpegContainer, .pngContainer, .heifContainer,
        .orientation, .colorSpace, .alpha, .aspectRatio, .physicalScreenshot,
    ]

    /// Every comparison is either grounded in an approved artifact or explicitly not
    /// performed, and never completed from the implementation under test.
    ///
    /// The outcome is required to be one of exactly two values for every kind and family.
    /// There is deliberately no third branch that would let a produced value stand in for a
    /// missing expected one, and the reasons are surfaced as comments so the run reports
    /// what is absent by name.
    @Test("Every named comparison is either grounded or explicitly not performed")
    func groundingIsTotalAndNeverSynthesized() async throws {
        let evidence = DeliveredApprovedEvidence()
        // One real produced value, so the comparator is called with something the pipeline
        // actually made rather than with a placeholder. It is never used as an expectation.
        let produced = try await RealPipeline().run(
            try #require(
                DeclaringImageFixture.encode(
                    EncodedImageFixture.gradient(width: 60, height: 44),
                    as: .png,
                    properties: [:]
                )
            )
        ).get().bytes
        #expect(produced.count == boundModelInputByteCount)

        var grounded: [String] = []
        var notPerformed: [String] = []

        for kind in ApprovedComparisonKind.allCases {
            for family in Self.families {
                let grounding = evidence.grounding(for: kind, family: family)
                let outcome = ApprovedComparator.compare(
                    producedPreprocessingOutput: produced,
                    against: grounding,
                    reading: evidence
                )
                let label = "\(kind) on \(family.rawValue)"
                switch outcome {
                case .agreed:
                    grounded.append("\(label): agreed")
                case .disagreed(let detail):
                    // A real finding, not a skip: the artifact existed and disagreed.
                    Issue.record(
                        Comment(rawValue: "\(label) disagreed with its artifact: \(detail)")
                    )
                case .failedClosed(let reason):
                    // The artifact was claimed but unusable. Also a finding.
                    Issue.record(Comment(rawValue: "\(label) failed closed: \(reason)"))
                case .notPerformed(let reason):
                    notPerformed.append("\(label): \(reason)")
                }
            }
        }

        let total = ApprovedComparisonKind.allCases.count * Self.families.count
        // Totality: every pair produced one of the two permitted outcomes. A third
        // outcome would mean something was neither compared nor recorded as absent.
        #expect(grounded.count + notPerformed.count == total)

        if !notPerformed.isEmpty {
            print(
                """
                Task 5.10: \(notPerformed.count) of \(total) named comparisons were not \
                performed for want of an approved expected artifact or tolerance:
                \(notPerformed.map { "  - \($0)" }.joined(separator: "\n"))
                """
            )
        }
        if !grounded.isEmpty {
            print(
                """
                Task 5.10: \(grounded.count) of \(total) named comparisons ran against an \
                approved artifact:
                \(grounded.map { "  - \($0)" }.joined(separator: "\n"))
                """
            )
        }
    }

    /// The two comparisons whose metric the plan's vocabulary cannot express at all.
    ///
    /// `decodedMetadata` has no ``ComparisonMetric``, so Requirement 13.3's "declare the
    /// metric and the numeric tolerance before validation begins" has nothing to attach to.
    /// This is asserted rather than described, so a later widening of the vocabulary shows
    /// up here instead of being noticed by nobody.
    @Test("A comparison with no declared plan metric can never be grounded")
    func aComparisonWithNoMetricIsNeverGrounded() {
        let evidence = DeliveredApprovedEvidence()
        #expect(ApprovedComparisonKind.decodedMetadata.planMetric == nil)
        for family in Self.families {
            let grounding = evidence.grounding(for: .decodedMetadata, family: family)
            #expect(grounding.isGrounded == false, "\(family.rawValue): \(grounding)")
        }
    }

    /// This build carries no approved fixture suite, and says so rather than proceeding.
    ///
    /// Asserted as a fact about the delivered artifacts rather than left implicit: a run
    /// that reported nothing would be indistinguishable from a run in which every
    /// comparison was grounded and passed.
    @Test("The absence of an approved fixture suite is reported, not worked around")
    func absenceIsReported() throws {
        let evidence = DeliveredApprovedEvidence()
        guard let delivered = evidence.delivered else {
            #expect(evidence.absenceReason.isEmpty == false)
            print("Task 5.10: approved fixture evidence is absent — \(evidence.absenceReason)")
            let anyPath = try #require(CanonicalRelativePath("fixtures/any.png"))
            #expect(evidence.assetBytes(at: anyPath) == .failure(.suiteAbsent))
            return
        }
        // An approved suite is delivered. Then it must be complete enough to compare
        // against: the model-parity family alone is 96 references under Requirement 13.4,
        // and a partial suite is a release finding rather than a passing run.
        #expect(
            delivered.suite.hasCompleteModelParityCoverage,
            """
            a delivered suite must account for all \
            \(ReleaseFixtureSuite.requiredModelParityFixtureCount) model-parity \
            references; found \(delivered.suite.fixtures(in: .modelParity).count)
            """
        )
        #expect(
            delivered.suite.missingFamilies.isEmpty,
            "\(delivered.suite.missingFamilies.map(\.rawValue).sorted())"
        )
    }
}

// MARK: - The comparator's own fail-closed behaviour

/// The comparator refuses rather than completes.
///
/// Every value in this suite is constructed **in the test**, on both sides of the
/// comparison, and no pipeline output is involved. What is being tested is the comparator,
/// not the image pipeline: that a missing asset, a mutated asset, a byte-count
/// disagreement, a fixture with no declared expectation, and a non-exact tolerance each
/// produce a refusal, and that only a genuine digest match produces agreement.
///
/// It exists because the grounded branch above is unreachable in this build. A comparator
/// that has never been exercised is a comparator that will silently pass the first time an
/// approved artifact lands.
@Suite(
    "Real-framework image pipeline: comparator fail-closed behaviour",
    .tags(.realFrameworkImagePipeline)
)
struct ApprovedComparatorTests {
    /// Two byte sequences, both fixed here, so neither side is derived from the other.
    private static let assetBytes: [UInt8] = [0x01, 0x02, 0x03, 0x04]
    private static let expectedOutputBytes: [UInt8] = [0x10, 0x20, 0x30]
    private static let differentOutputBytes: [UInt8] = [0x10, 0x20, 0x31]

    /// A store that holds exactly the assets it was handed.
    private struct StubEvidence: ApprovedImagePipelineEvidenceReading {
        var assets: [String: [UInt8]] = [:]
        var groundingOverride: ApprovedGrounding?

        func grounding(
            for kind: ApprovedComparisonKind,
            family: FixtureFamily
        ) -> ApprovedGrounding {
            groundingOverride ?? .notGrounded(reason: "stub")
        }

        func assetBytes(at path: CanonicalRelativePath) -> Result<[UInt8], ApprovedAssetFault> {
            guard let bytes = assets[path.rawValue] else { return .failure(.assetMissing) }
            return .success(bytes)
        }
    }

    private static func path(_ raw: String) -> CanonicalRelativePath {
        guard let path = CanonicalRelativePath(raw) else {
            preconditionFailure("test path is not canonical: \(raw)")
        }
        return path
    }

    private static func fixtureID(_ raw: String) -> FixtureID {
        guard let id = FixtureID(raw) else {
            preconditionFailure("test fixture identifier is not canonical: \(raw)")
        }
        return id
    }

    /// A fixture record over ``assetBytes``, declaring `expectations`.
    ///
    /// The content digest is over the asset bytes stated above, which is what a catalogue
    /// entry is: a claim about fixed bytes. It is not derived from any pipeline output.
    private static func record(
        assetPath: String = "fixtures/asset.bin",
        byteCount: UInt64 = UInt64(assetBytes.count),
        contentDigest: DefAIkeDomain.SHA256Digest? = nil,
        expectations: [FixtureExpectation]
    ) throws -> FixtureRecord {
        try FixtureRecord(
            id: fixtureID("fixture-0001"),
            family: .pngContainer,
            assetPath: path(assetPath),
            contentDigest: contentDigest ?? Fixture.digest(of: assetBytes),
            byteCount: try PositiveByteCount(validating: byteCount),
            source: Fixture.evidence("approved-fixture-source"),
            expectations: expectations
        )
    }

    /// An exact numeric comparison, which is the only kind a digest match can be bounded by.
    private static func exactComparison() throws -> ComparisonSpecification {
        try ComparisonSpecification(
            metric: .preprocessingOutput,
            reference: Fixture.evidence("approved-preprocessing-reference"),
            tolerance: try NumericTolerance(
                kind: .exact,
                value: try NonNegativeDecimal(validating: 0)
            ),
            requiredAgreement: nil
        )
    }

    private static func looseComparison() throws -> ComparisonSpecification {
        try ComparisonSpecification(
            metric: .preprocessingOutput,
            reference: Fixture.evidence("approved-preprocessing-reference"),
            tolerance: try NumericTolerance(
                kind: .absolute,
                value: try NonNegativeDecimal(validating: 1)
            ),
            requiredAgreement: nil
        )
    }

    @Test("An absent grounding is reported as not performed, never as agreement")
    func absentGroundingIsNotAgreement() {
        let outcome = ApprovedComparator.compare(
            producedPreprocessingOutput: Self.expectedOutputBytes,
            against: .notGrounded(reason: "no approved suite is delivered"),
            reading: StubEvidence()
        )
        #expect(outcome == .notPerformed(reason: "no approved suite is delivered"))
    }

    @Test("A catalogued asset that is missing fails closed rather than being generated")
    func missingAssetFailsClosed() throws {
        let fixture = try Self.record(
            expectations: [.preprocessingOutputDigest(Fixture.digest(of: Self.expectedOutputBytes))]
        )
        let outcome = ApprovedComparator.compare(
            producedPreprocessingOutput: Self.expectedOutputBytes,
            against: .grounded(fixture: fixture, comparison: try Self.exactComparison()),
            reading: StubEvidence()
        )
        guard case .failedClosed(let reason) = outcome else {
            Issue.record(Comment(rawValue: "expected a closed failure, got \(outcome)"))
            return
        }
        #expect(reason.contains("assetMissing"))
    }

    @Test("An asset that does not hash to its catalogued digest fails closed")
    func mutatedAssetFailsClosed() throws {
        let fixture = try Self.record(
            contentDigest: Fixture.digest(of: [0xFF, 0xFE]),
            expectations: [.preprocessingOutputDigest(Fixture.digest(of: Self.expectedOutputBytes))]
        )
        let outcome = ApprovedComparator.compare(
            producedPreprocessingOutput: Self.expectedOutputBytes,
            against: .grounded(fixture: fixture, comparison: try Self.exactComparison()),
            reading: StubEvidence(assets: ["fixtures/asset.bin": Self.assetBytes])
        )
        guard case .failedClosed(let reason) = outcome else {
            Issue.record(Comment(rawValue: "expected a closed failure, got \(outcome)"))
            return
        }
        #expect(reason.contains("content digest"))
    }

    @Test("An asset whose length is not the catalogued byte count fails closed")
    func wrongByteCountFailsClosed() throws {
        let fixture = try Self.record(
            byteCount: UInt64(Self.assetBytes.count + 1),
            expectations: [.preprocessingOutputDigest(Fixture.digest(of: Self.expectedOutputBytes))]
        )
        let outcome = ApprovedComparator.compare(
            producedPreprocessingOutput: Self.expectedOutputBytes,
            against: .grounded(fixture: fixture, comparison: try Self.exactComparison()),
            reading: StubEvidence(assets: ["fixtures/asset.bin": Self.assetBytes])
        )
        guard case .failedClosed = outcome else {
            Issue.record(Comment(rawValue: "expected a closed failure, got \(outcome)"))
            return
        }
    }

    @Test("A fixture with no preprocessing-output expectation fails closed")
    func missingExpectationFailsClosed() throws {
        let fixture = try Self.record(expectations: [.analysisError(.decodingError)])
        let outcome = ApprovedComparator.compare(
            producedPreprocessingOutput: Self.expectedOutputBytes,
            against: .grounded(fixture: fixture, comparison: try Self.exactComparison()),
            reading: StubEvidence(assets: ["fixtures/asset.bin": Self.assetBytes])
        )
        guard case .failedClosed(let reason) = outcome else {
            Issue.record(Comment(rawValue: "expected a closed failure, got \(outcome)"))
            return
        }
        #expect(reason.contains("no approved preprocessing-output expectation"))
    }

    @Test("A non-exact declared tolerance fails closed rather than being approximated")
    func nonExactToleranceFailsClosed() throws {
        let fixture = try Self.record(
            expectations: [.preprocessingOutputDigest(Fixture.digest(of: Self.expectedOutputBytes))]
        )
        let outcome = ApprovedComparator.compare(
            producedPreprocessingOutput: Self.expectedOutputBytes,
            against: .grounded(fixture: fixture, comparison: try Self.looseComparison()),
            reading: StubEvidence(assets: ["fixtures/asset.bin": Self.assetBytes])
        )
        guard case .failedClosed(let reason) = outcome else {
            Issue.record(Comment(rawValue: "expected a closed failure, got \(outcome)"))
            return
        }
        #expect(reason.contains("not exact"))
    }

    @Test("A produced value that does not match the approved digest is a disagreement")
    func aMismatchIsADisagreement() throws {
        let fixture = try Self.record(
            expectations: [.preprocessingOutputDigest(Fixture.digest(of: Self.expectedOutputBytes))]
        )
        let outcome = ApprovedComparator.compare(
            producedPreprocessingOutput: Self.differentOutputBytes,
            against: .grounded(fixture: fixture, comparison: try Self.exactComparison()),
            reading: StubEvidence(assets: ["fixtures/asset.bin": Self.assetBytes])
        )
        guard case .disagreed = outcome else {
            Issue.record(Comment(rawValue: "expected a disagreement, got \(outcome)"))
            return
        }
    }

    @Test("Only a genuine digest match under an exact tolerance agrees")
    func aMatchAgrees() throws {
        let fixture = try Self.record(
            expectations: [.preprocessingOutputDigest(Fixture.digest(of: Self.expectedOutputBytes))]
        )
        let outcome = ApprovedComparator.compare(
            producedPreprocessingOutput: Self.expectedOutputBytes,
            against: .grounded(fixture: fixture, comparison: try Self.exactComparison()),
            reading: StubEvidence(assets: ["fixtures/asset.bin": Self.assetBytes])
        )
        #expect(outcome == .agreed)
    }
}
