import Accelerate
import DefAIkeDomain
import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import DefAIkeImagePipeline

/// Producing the bound contract's model input, end to end through the real port.
///
/// Requirements 4.4 through 4.8. The validator and the preprocessor share one encoded-asset
/// store and one decoded-image registry here, because that is the arrangement a composition
/// uses and because the preprocessor reads the retained encoded bytes again for the
/// container's declarations.
///
/// Host Core Graphics, ColorSync, and Accelerate results are development checks. They are
/// not physical-device evidence for any pixel-level claim.
@Suite("Model input production")
struct ModelInputProductionTests {
    // MARK: - Harness

    private struct Harness {
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

        func validate(
            _ bytes: [UInt8],
            sessionID: AnalysisSessionID = Fixture.sessionID()
        ) async throws -> ValidatedImage {
            let asset = try await IngestFixture.asset(
                bytes: bytes,
                in: store,
                sessionID: sessionID
            )
            return try await validator.validate(asset, contract: contract, budget: budget)
        }

        func prepare(
            _ image: ValidatedImage,
            contract overrideContract: PreprocessingContract? = nil,
            budget overrideBudget: ResourceBudget? = nil
        ) async -> Result<ModelImageInput, AnalysisFault> {
            do {
                return .success(
                    try await preprocessor.prepare(
                        image,
                        contract: overrideContract ?? contract,
                        budget: overrideBudget ?? budget
                    )
                )
            } catch {
                return .failure(error)
            }
        }

        /// Validates and prepares in one step, which is the whole pipeline this task ends.
        func run(
            _ bytes: [UInt8],
            sessionID: AnalysisSessionID = Fixture.sessionID()
        ) async throws -> Result<ModelImageInput, AnalysisFault> {
            await prepare(try await validate(bytes, sessionID: sessionID))
        }
    }

    private func error(_ result: Result<ModelImageInput, AnalysisFault>) -> AnalysisError? {
        guard case .failure(let fault) = result else { return nil }
        return fault.analysisError
    }

    /// A lossless container over `image`, so a byte comparison between two contracts is a
    /// comparison of the transform rather than of an encoder's noise.
    private func png(_ image: CGImage) throws -> [UInt8] {
        try #require(DeclaringImageFixture.encode(image, as: .png, properties: [:]))
    }

    /// A solid-color container. Every bilinear weight set sums to its denominator, so a
    /// flat source must come out flat and at exactly the same value.
    private func solidColorPNG(
        width: Int,
        height: Int,
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            pixels[pixel * 4] = red
            pixels[pixel * 4 + 1] = green
            pixels[pixel * 4 + 2] = blue
        }
        return try png(
            SourceImageFixture.interleaved32(
                width: width,
                height: height,
                pixels: pixels,
                space: SourceImageFixture.sRGB,
                alpha: .noneSkipLast
            )
        )
    }

    private var expectedByteCount: Int {
        CenterCropContract.requiredEdge * CenterCropContract.requiredEdge * 3
    }

    // MARK: - The produced model input

    @Test("Preparing a validated image produces the bound 384-by-384 unsigned 8-bit RGB input")
    func producesTheBoundModelInput() async throws {
        let harness = Harness()
        let prepared = try await harness.run(
            try png(EncodedImageFixture.gradient(width: 60, height: 50))
        ).get()

        #expect(prepared.edge == CenterCropContract.requiredEdge)
        #expect(prepared.channelOrder == .rgb)
        #expect(prepared.elementType == .uint8)
        #expect(prepared.byteCount == UInt64(expectedByteCount))
        #expect(prepared.preprocessingContractID == harness.contract.id)
        #expect(prepared.sessionID == Fixture.sessionID())

        let retained = try #require(await harness.modelInputs.preparedInput(for: prepared.buffer))
        #expect(retained.edge == CenterCropContract.requiredEdge)
        #expect(retained.channelOrder == .rgb)
        #expect(retained.bytes.count == expectedByteCount)
        #expect(await harness.modelInputs.retainedInputCount == 1)
    }

    @Test("A flat source arrives at the model unchanged, with no app-side normalization")
    func noAppSideNormalizationIsApplied() async throws {
        // Requirements 4.6 through 4.8 leave the `1/255` scaling and the RGB mean and
        // standard-deviation normalization to the model graph. A flat source is the
        // sharpest available check that none of them happened here: scaling would collapse
        // 200 toward zero, mean subtraction would move it by roughly 116, and either would
        // be invisible in a gradient.
        let harness = Harness()
        let prepared = try await harness.run(
            try solidColorPNG(width: 60, height: 50, red: 10, green: 200, blue: 45)
        ).get()
        let bytes = try #require(
            await harness.modelInputs.preparedInput(for: prepared.buffer)
        ).bytes
        #expect(bytes.count == expectedByteCount)
        for pixel in stride(from: 0, to: bytes.count, by: 3) {
            try #require(bytes[pixel] == 10, "red at byte \(pixel)")
            try #require(bytes[pixel + 1] == 200, "green at byte \(pixel)")
            try #require(bytes[pixel + 2] == 45, "blue at byte \(pixel)")
        }
    }

    // MARK: - The contract's geometry fields reach the pixels

    @Test("The contract's rounding rule changes the produced bytes")
    func roundingRuleReachesThePixels() async throws {
        // 61 by 50 scales to 536.8 on the long axis, so flooring and ceiling disagree and
        // the resized image differs by one column. A contract field that never reached the
        // sampler would produce identical bytes here.
        let bytes = try png(EncodedImageFixture.gradient(width: 61, height: 50))
        var produced: [RoundingRule: [UInt8]] = [:]
        for rule in [RoundingRule.floor, .ceiling] {
            let harness = Harness(contract: PreprocessingFixture.contract(rounding: rule))
            let prepared = try await harness.run(bytes).get()
            produced[rule] = try #require(
                await harness.modelInputs.preparedInput(for: prepared.buffer)
            ).bytes
        }
        #expect(produced[.floor]?.count == expectedByteCount)
        #expect(produced[.floor] != produced[.ceiling])
    }

    @Test("The contract's crop offset rule changes the produced bytes")
    func cropOffsetRuleReachesThePixels() async throws {
        // 61 by 50 halves up to 537 by 440. The long axis leaves 537 - 384 = 153, an odd
        // difference, which is the one case the offset rule exists for.
        let bytes = try png(EncodedImageFixture.gradient(width: 61, height: 50))
        var produced: [CropOffsetRule: [UInt8]] = [:]
        for rule in CropOffsetRule.allCases {
            let harness = Harness(contract: PreprocessingFixture.contract(cropOffsetRule: rule))
            let prepared = try await harness.run(bytes).get()
            produced[rule] = try #require(
                await harness.modelInputs.preparedInput(for: prepared.buffer)
            ).bytes
        }
        #expect(produced[.floorHalfDifference] != produced[.ceilingHalfDifference])
    }

    @Test("The contract's pixel-center convention changes the produced bytes")
    func pixelCenterConventionReachesThePixels() async throws {
        let bytes = try png(EncodedImageFixture.gradient(width: 60, height: 50))
        var produced: [PixelCenterConvention: [UInt8]] = [:]
        for convention in PixelCenterConvention.allCases {
            let harness = Harness(
                contract: PreprocessingFixture.contract(pixelCenterConvention: convention)
            )
            let prepared = try await harness.run(bytes).get()
            produced[convention] = try #require(
                await harness.modelInputs.preparedInput(for: prepared.buffer)
            ).bytes
        }
        #expect(produced[.halfPixelCenters] != produced[.integerPixelCenters])
    }

    @Test("The contract's edge rule changes the produced bytes of an upscale")
    func edgeRuleReachesThePixels() async throws {
        // An upscale is required for the edge rule to be observable at all: with half-pixel
        // centers a downscale never samples outside the source, which the resampler tests
        // check directly.
        let bytes = try png(EncodedImageFixture.gradient(width: 8, height: 6))
        var produced: [SampleEdgeRule: [UInt8]] = [:]
        for rule in SampleEdgeRule.allCases {
            let harness = Harness(contract: PreprocessingFixture.contract(edgeRule: rule))
            let prepared = try await harness.run(bytes).get()
            produced[rule] = try #require(
                await harness.modelInputs.preparedInput(for: prepared.buffer)
            ).bytes
        }
        #expect(
            produced[.clampToEdge] == produced[.mirror],
            "mirroring repeats the boundary sample, so it agrees with clamping here"
        )
        #expect(produced[.clampToEdge] != produced[.reflect])
    }

    // MARK: - Refusals

    @Test("A contract other than the one the decode was validated under is refused")
    func mismatchedContractIsRefused() async throws {
        let harness = Harness()
        let validated = try await harness.validate(
            try png(EncodedImageFixture.gradient(width: 60, height: 50))
        )
        let other = PreprocessingFixture.contract(id: "preprocessing-0002")
        let result = await harness.prepare(validated, contract: other)
        #expect(error(result) == .preprocessingError)
        #expect(await harness.modelInputs.retainedInputCount == 0)
    }

    @Test("A decoded-image token that names nothing is refused")
    func releasedDecodedImageIsRefused() async throws {
        let harness = Harness()
        let validated = try await harness.validate(
            try png(EncodedImageFixture.gradient(width: 60, height: 50))
        )
        await harness.decodedImages.release(validated.decodedImage)
        #expect(error(await harness.prepare(validated)) == .preprocessingError)
    }

    @Test("A budget that cannot hold the crop refuses with a resource limit")
    func budgetRefusalKeepsItsOwnCategory() async throws {
        // A budget breach is not a contract failure: Requirement 3.4 gives it its own
        // category and the design's state machine a separate edge. The limit is set above
        // what the decode and the rendered surface cost and below what the 384-by-384 crop
        // adds, so validation and rendering both pass and the sampling bound is what
        // refuses.
        let harness = Harness()
        let validated = try await harness.validate(
            try png(EncodedImageFixture.gradient(width: 60, height: 50))
        )
        let tight = ResourceFixture.budget(
            overrides: [.peakResidentMemory: ResourceFixture.numeric(200_000, .bytes)]
        )
        let result = await harness.prepare(validated, budget: tight)
        #expect(error(result) == .resourceLimit)
        #expect(await harness.modelInputs.retainedInputCount == 0)
    }

    // MARK: - Retention and release

    @Test("Releasing a session's prepared inputs is complete and idempotent")
    func releaseIsIdempotent() async throws {
        let harness = Harness()
        let prepared = try await harness.run(
            try png(EncodedImageFixture.gradient(width: 60, height: 50))
        ).get()
        #expect(await harness.modelInputs.retainedInputCount == 1)

        #expect(await harness.modelInputs.releaseAll(for: Fixture.sessionID()) == 1)
        #expect(await harness.modelInputs.retainedInputCount == 0)
        #expect(await harness.modelInputs.preparedInput(for: prepared.buffer) == nil)
        #expect(
            await harness.modelInputs.releaseAll(for: Fixture.sessionID()) == 0,
            "a second release reports zero rather than failing"
        )
    }

    @Test("Another session's prepared input is not released or resolved by mistake")
    func releaseIsScopedToOneSession() async throws {
        let harness = Harness()
        let bytes = try png(EncodedImageFixture.gradient(width: 60, height: 50))
        let first = try await harness.run(bytes, sessionID: Fixture.sessionID("session-0001")).get()
        let second = try await harness.run(bytes, sessionID: Fixture.sessionID("session-0002")).get()
        #expect(first.buffer != second.buffer)

        #expect(await harness.modelInputs.releaseAll(for: Fixture.sessionID("session-0001")) == 1)
        #expect(await harness.modelInputs.preparedInput(for: first.buffer) == nil)
        #expect(await harness.modelInputs.preparedInput(for: second.buffer) != nil)
    }

    // MARK: - The buffer the contract declares

    @Test("The crop's bytes are handed over exactly as the crop produced them")
    func producedBytesAreTheSurfaceBytes() throws {
        let edge = CenterCropContract.requiredEdge
        let surface = try PixelSurface.tightlyPacked(
            width: edge,
            height: edge,
            channelCount: ModelInputProduction.channelCount
        )
        let base = try #require(surface.buffer.data?.assumingMemoryBound(to: UInt8.self))
        let count = edge * edge * ModelInputProduction.channelCount
        for index in 0..<count { base[index] = UInt8((index * 7) % 256) }

        let bytes = try ModelInputProduction.bytes(
            from: surface,
            modelInput: PreprocessingFixture.contract().modelInput
        )
        #expect(bytes.count == count)
        #expect(bytes == surface.copyPackedBytes())
        #expect(bytes.first == 0)
        #expect(bytes[1] == 7)
    }

    @Test("A buffer that is not the declared shape is refused rather than reshaped")
    func wrongShapedBufferIsRefused() throws {
        let modelInput = PreprocessingFixture.contract().modelInput
        let edge = CenterCropContract.requiredEdge

        // A channel count that is not three. The renderer never produces one, which is
        // exactly why the refusal is checked here rather than only through the port.
        let fourChannel = try PixelSurface.tightlyPacked(
            width: edge,
            height: edge,
            channelCount: 4
        )
        #expect(throws: PreprocessingFailure.self) {
            try ModelInputProduction.bytes(from: fourChannel, modelInput: modelInput)
        }

        // A square that is not the declared edge, and a non-square crop.
        for (width, height) in [(edge - 1, edge), (edge, edge + 1)] {
            let wrongSize = try PixelSurface.tightlyPacked(
                width: width,
                height: height,
                channelCount: ModelInputProduction.channelCount
            )
            #expect(throws: PreprocessingFailure.self) {
                try ModelInputProduction.bytes(from: wrongSize, modelInput: modelInput)
            }
        }
    }

    @Test("A padded buffer is refused rather than read at the wrong stride")
    func paddedBufferIsRefused() throws {
        // Read as if it were packed, a padded row shears the image by a few pixels a row.
        // That survives to the model and still looks like a photograph, so it is refused.
        // Adopting a 32-bit allocation as three channels is the reliable way to get a
        // stride wider than the packed one at the contract's fixed edge.
        var allocated = vImage_Buffer()
        let edge = CenterCropContract.requiredEdge
        let status = vImageBuffer_Init(
            &allocated,
            vImagePixelCount(edge),
            vImagePixelCount(edge),
            32,
            vImage_Flags(kvImageNoFlags)
        )
        try #require(status == kvImageNoError)
        let padded = try PixelSurface.adopting(
            allocated,
            channelCount: ModelInputProduction.channelCount
        )
        try #require(padded.isTightlyPacked == false, "this test needs a padded stride")
        #expect(throws: PreprocessingFailure.self) {
            try ModelInputProduction.bytes(
                from: padded,
                modelInput: PreprocessingFixture.contract().modelInput
            )
        }
    }

    @Test("A prepared input whose byte count is not the declared shape is unrepresentable")
    func preparedInputRejectsAWrongLength() {
        let edge = CenterCropContract.requiredEdge
        #expect(
            PreparedModelInput(
                sessionID: Fixture.sessionID(),
                edge: edge,
                channelOrder: .rgb,
                bytes: [UInt8](repeating: 0, count: edge * edge * 3)
            ) != nil
        )
        for count in [0, edge * edge * 3 - 1, edge * edge * 4] {
            #expect(
                PreparedModelInput(
                    sessionID: Fixture.sessionID(),
                    edge: edge,
                    channelOrder: .rgb,
                    bytes: [UInt8](repeating: 0, count: count)
                ) == nil,
                "\(count) bytes"
            )
        }
        #expect(
            PreparedModelInput(
                sessionID: Fixture.sessionID(),
                edge: 0,
                channelOrder: .rgb,
                bytes: []
            ) == nil
        )
    }
}
