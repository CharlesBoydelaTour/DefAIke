import DefAIkeDomain
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import DefAIkeImagePipeline

/// Complete decode validation through the real port, with real Image I/O.
///
/// Requirements 1.11 through 1.14, 2.15, 2.16, and 3.1 through 3.4.
@Suite("Complete decode validation")
struct InputValidationTests {
    /// One validator over a fresh store and a fresh decoded-image registry.
    private struct Harness {
        let store = InMemoryEncodedAssetStore()
        let decodedImages = DecodedImageStore()
        let quality = InputQualityLedger()
        let contract: PreprocessingContract
        let budget: ResourceBudget
        let validator: ImageIOInputValidator

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
        }

        func validate(
            _ bytes: [UInt8],
            sessionID: AnalysisSessionID = Fixture.sessionID(),
            route: InputRoute = .photosPicker,
            contentTypeHint: String? = nil
        ) async throws -> Result<ValidatedImage, AnalysisFault> {
            let asset = try await IngestFixture.asset(
                bytes: bytes,
                in: store,
                sessionID: sessionID,
                route: route,
                contentTypeHint: contentTypeHint
            )
            return await validate(asset)
        }

        func validate(_ asset: ImportedEncodedAsset) async -> Result<ValidatedImage, AnalysisFault> {
            do {
                return .success(try await validator.validate(asset, contract: contract, budget: budget))
            } catch {
                return .failure(error)
            }
        }
    }

    /// The single error category a result carries, or `nil` when it succeeded or was
    /// cancelled.
    private func error(_ result: Result<ValidatedImage, AnalysisFault>) -> AnalysisError? {
        guard case .failure(let fault) = result else { return nil }
        return fault.analysisError
    }

    // MARK: - Accepting a supported image

    @Test(
        "A supported container decodes completely and yields a validated image",
        arguments: [UTType.jpeg, .png, .heic]
    )
    func acceptsSupportedContainers(type: UTType) async throws {
        try #require(
            EncodedImageFixture.canEncode(type),
            "this host cannot encode \(type.identifier)"
        )
        let bytes = try #require(EncodedImageFixture.supported(type))
        let harness = Harness()

        let validated = try await harness.validate(bytes).get()

        #expect(validated.dimensions.width == 40)
        #expect(validated.dimensions.height == 24)
        #expect(validated.dimensions.shortEdge == 24)
        #expect(validated.preprocessingContractID == harness.contract.id)
        #expect(validated.additionalQualityFeatures.isEmpty)
        #expect(
            ContainerClassifier.staticContainer(for: type) == validated.container,
            "the recorded container must be the one the content actually is"
        )
    }

    @Test("The pre-orientation quality record carries the unswapped decoded dimensions")
    func qualityRecordIsPreOrientation() async throws {
        // A landscape image: if orientation handling ever swapped the recorded values,
        // the short edge would change and with it the sub-440 abstention decision.
        let bytes = try #require(
            EncodedImageFixture.encode(
                EncodedImageFixture.gradient(width: 64, height: 20),
                as: .png
            )
        )
        let validated = try await Harness().validate(bytes).get()

        let quality = validated.quality
        #expect(quality.decodedWidthBeforeOrientation == 64)
        #expect(quality.decodedHeightBeforeOrientation == 20)
        #expect(quality.shortEdgeBeforeOrientation == 20)
    }

    @Test("The validated image names the identical retained bytes")
    func retainedBytesAreTheSameObject() async throws {
        let bytes = try #require(EncodedImageFixture.supported(.png))
        let harness = Harness()
        let asset = try await IngestFixture.asset(bytes: bytes, in: harness.store)

        let validated = try await harness.validate(asset).get()

        #expect(validated.source == asset.handle)
        #expect(validated.source.byteCount == UInt64(bytes.count))
        #expect(validated.source.sha256 == Fixture.digest(of: bytes))
        #expect(try await harness.store.read(validated.source.storageKey) == bytes)
    }

    @Test("A decoded image is retained under the session that owns it")
    func decodedImageIsRetainedPerSession() async throws {
        let bytes = try #require(EncodedImageFixture.supported(.png))
        let harness = Harness()
        let sessionID = Fixture.sessionID("session-retain")

        let validated = try await harness.validate(bytes, sessionID: sessionID).get()

        let decoded = try #require(await harness.decodedImages.image(for: validated.decodedImage))
        #expect(decoded.sessionID == sessionID)
        #expect(decoded.dimensions == validated.dimensions)
        #expect(decoded.image.width == 40)
        #expect(decoded.image.height == 24)
        #expect(decoded.decodedByteCount > 0)

        // Cleanup releases everything the session decoded, and is idempotent.
        #expect(await harness.decodedImages.releaseAll(for: sessionID) == 1)
        #expect(await harness.decodedImages.releaseAll(for: sessionID) == 0)
        #expect(await harness.decodedImages.image(for: validated.decodedImage) == nil)
        #expect(await harness.decodedImages.retainedImageCount == 0)
    }

    @Test("Byte-identical input through either route validates identically")
    func routesAgree() async throws {
        let bytes = try #require(EncodedImageFixture.supported(.jpeg))

        let photos = try await Harness().validate(bytes, route: .photosPicker).get()
        let share = try await Harness().validate(bytes, route: .shareExtension).get()

        #expect(photos.container == share.container)
        #expect(photos.dimensions == share.dimensions)
        #expect(photos.source.sha256 == share.source.sha256)
        #expect(photos.quality == share.quality)
    }

    // MARK: - Unsupported media and formats

    @Test("Animated, video, and audio content returns unsupported-media")
    func unsupportedMedia() async throws {
        let animated = try #require(
            EncodedImageFixture.encode(
                EncodedImageFixture.gradient(width: 12, height: 8),
                as: .gif,
                frameCount: 3
            )
        )
        let inputs: [[UInt8]] = [
            animated,
            EncodedImageFixture.isoBaseMedia(brand: "qt  "),
            EncodedImageFixture.riff(formType: "AVI "),
            EncodedImageFixture.riff(formType: "WAVE"),
            EncodedImageFixture.mp3Header,
        ]
        for bytes in inputs {
            let harness = Harness()
            let result = await harness.validate(try await IngestFixture.asset(
                bytes: bytes,
                in: harness.store
            ))
            #expect(error(result) == .unsupportedMedia)
            #expect(await harness.decodedImages.retainedImageCount == 0)
        }
    }

    @Test("An unsupported static container returns unsupported-static-format")
    func unsupportedStaticFormat() async throws {
        let tiff = try #require(EncodedImageFixture.supported(.tiff))
        let inputs: [[UInt8]] = [tiff, EncodedImageFixture.pdf()]
        for bytes in inputs {
            let harness = Harness()
            let result = await harness.validate(try await IngestFixture.asset(
                bytes: bytes,
                in: harness.store
            ))
            #expect(error(result) == .unsupportedStaticFormat)
            #expect(await harness.decodedImages.retainedImageCount == 0)
        }
    }

    @Test("An unsupported format fails at the media-classification stage")
    func unsupportedFormatReportsClassificationStage() async throws {
        let bytes = try #require(EncodedImageFixture.supported(.bmp))
        let result = try await Harness().validate(bytes)
        guard case .failure(let fault) = result else {
            Issue.record("a BMP must not validate")
            return
        }
        #expect(fault == .analysis(.unsupportedStaticFormat, stage: .mediaClassification))
    }

    @Test("A wrong content-type hint does not change the outcome")
    func hintDoesNotChangeTheOutcome() async throws {
        let jpeg = try #require(EncodedImageFixture.supported(.jpeg))
        let claimedMovie = try await Harness().validate(jpeg, contentTypeHint: "public.mpeg-4")
        #expect(try claimedMovie.get().container == .jpeg)

        let tiff = try #require(EncodedImageFixture.supported(.tiff))
        let claimedJPEG = try await Harness().validate(tiff, contentTypeHint: "public.jpeg")
        #expect(error(claimedJPEG) == .unsupportedStaticFormat)
    }

    // MARK: - Malformed and incomplete data

    @Test("Unidentifiable bytes return decoding-error")
    func unidentifiableBytes() async throws {
        let result = try await Harness().validate(EncodedImageFixture.unidentifiableBytes)
        #expect(error(result) == .decodingError)
    }

    @Test("A JPEG truncated past its image data returns decoding-error")
    func truncatedJPEG() async throws {
        // Image I/O still reports the container type and one image for a truncated JPEG,
        // so nothing short of completing the decode detects this.
        for fraction in [0.7, 0.5, 0.3, 0.1] {
            let harness = Harness()
            let result = try await harness.validate(
                EncodedImageFixture.truncatedJPEG(fraction: fraction)
            )
            #expect(
                error(result) == .decodingError,
                "a JPEG truncated to \(Int(fraction * 100))% must not validate"
            )
            #expect(await harness.decodedImages.retainedImageCount == 0)
        }
    }

    @Test("A truncated container fails at the input-validation stage")
    func truncationReportsValidationStage() async throws {
        let result = try await Harness().validate(EncodedImageFixture.truncatedJPEG(fraction: 0.3))
        guard case .failure(let fault) = result else {
            Issue.record("a truncated JPEG must not validate")
            return
        }
        #expect(fault == .analysis(.decodingError, stage: .inputValidation))
    }

    @Test("Bytes that were never finalized return decoding-error")
    func unfinalizedRetainedObject() async throws {
        // An incomplete copy is never readable through the store, and validation must
        // not treat "no readable bytes" as anything other than a failure.
        let harness = Harness()
        let asset = try await IngestFixture.assetNamingUnfinalizedObject(
            in: harness.store,
            declaredByteCount: 1024
        )
        #expect(error(await harness.validate(asset)) == .decodingError)
    }

    // MARK: - Resource limits

    @Test("A declared pixel count above the budget returns resource-limit")
    func declaredPixelCountOverBudget() async throws {
        let bytes = try #require(EncodedImageFixture.supported(.png))
        // 40 by 24 is 960 pixels. A 100-pixel ceiling is breached by the declaration
        // alone, before the decode allocates anything.
        let harness = Harness(
            budget: ResourceFixture.budget(
                overrides: [.decodedPixelCount: ResourceFixture.numeric(100, .pixels)]
            )
        )
        let result = try await harness.validate(bytes)
        #expect(error(result) == .resourceLimit)
        #expect(
            await harness.decodedImages.retainedImageCount == 0,
            "a breach found before the decode must not leave a decoded image behind"
        )
    }

    @Test("A pixel count exactly at the budget limit is accepted")
    func pixelCountAtLimitIsAccepted() async throws {
        let bytes = try #require(EncodedImageFixture.supported(.png))
        // A hard limit is a ceiling, not an exclusive bound: 960 pixels against a
        // 960-pixel limit does not exceed it.
        let harness = Harness(
            budget: ResourceFixture.budget(
                overrides: [.decodedPixelCount: ResourceFixture.numeric(960, .pixels)]
            )
        )
        #expect(try await harness.validate(bytes).get().dimensions.pixelCount == 960)
    }

    @Test("A decode memory cost above the budget returns resource-limit")
    func decodeMemoryOverBudget() async throws {
        let bytes = try #require(EncodedImageFixture.supported(.png))
        let harness = Harness(
            budget: ResourceFixture.budget(
                overrides: [.peakResidentMemory: ResourceFixture.numeric(512, .bytes)]
            )
        )
        #expect(error(try await harness.validate(bytes)) == .resourceLimit)
    }

    @Test("An encoded copy above the storage budget returns resource-limit")
    func encodedCopyOverStorageBudget() async throws {
        let bytes = try #require(EncodedImageFixture.supported(.jpeg))
        // Checked from the byte count ingest already measured, so the breach is found
        // before any of the bytes are read into memory.
        let harness = Harness(
            budget: ResourceFixture.budget(
                overrides: [.temporaryStorage: ResourceFixture.numeric(16, .bytes)]
            )
        )
        #expect(error(try await harness.validate(bytes)) == .resourceLimit)
    }

    @Test("A Share Extension budget's encoded-input ceiling is applied when present")
    func encodedInputSizeCeilingApplies() async throws {
        let bytes = try #require(EncodedImageFixture.supported(.jpeg))
        // The extension budget defines `encodedInputSize`; the main-application budget
        // correctly does not, and no value is invented for it.
        let harness = Harness(
            budget: ResourceFixture.budget(
                for: .shareExtension,
                overrides: [.encodedInputSize: ResourceFixture.numeric(8, .bytes)]
            )
        )
        #expect(error(try await harness.validate(bytes)) == .resourceLimit)
    }

    @Test("A missing decoded-pixel limit fails closed with resource-limit")
    func missingPixelLimitFailsClosed() async throws {
        let bytes = try #require(EncodedImageFixture.supported(.png))
        // A Share Extension budget defines no decoded-pixel ceiling because the
        // extension runs no decode. Handing one to validation means the pixel count
        // cannot be bounded by an approved number, and an unbounded decode is not a
        // permitted fallback.
        let harness = Harness(budget: ResourceFixture.budget(for: .shareExtension))
        #expect(error(try await harness.validate(bytes)) == .resourceLimit)
        #expect(await harness.decodedImages.retainedImageCount == 0)
    }

    @Test("A limit in the wrong unit fails closed with resource-limit")
    func mismatchedUnitFailsClosed() async throws {
        let bytes = try #require(EncodedImageFixture.supported(.png))
        // The schema pairs a metric with a numeric or categorical limit but does not
        // pin the unit, so a pixel ceiling expressed in milliseconds is representable.
        // Comparing magnitudes across units would silently accept or reject by accident.
        let harness = Harness(
            budget: ResourceFixture.budget(
                overrides: [
                    .decodedPixelCount: ResourceFixture.numeric(1_000_000, .milliseconds)
                ]
            )
        )
        #expect(error(try await harness.validate(bytes)) == .resourceLimit)
    }

    @Test("Each fail-closed condition is reported as its own reason")
    func breachReasonsAreDistinct() {
        // The reason is separate from the outcome on purpose: all four produce
        // `resource-limit`, and none of them may be downgraded to a warning, but a
        // missing limit and an exceeded one are different problems to diagnose.
        let coherent = ValidationResourceChecks(budget: ResourceFixture.budget())
        #expect(coherent.checkPixels(10, against: .decodedPixelCount) == nil)
        #expect(
            coherent.checkPixels(2_000_000_000, against: .decodedPixelCount)
                == .exceeded(.decodedPixelCount)
        )
        #expect(
            coherent.checkBytes(1, against: .encodedInputSize)
                == .limitNotDefined(.encodedInputSize)
        )
        #expect(coherent.definesLimit(for: .encodedInputSize) == false)
        #expect(coherent.definesLimit(for: .temporaryStorage))

        let wrongUnit = ValidationResourceChecks(
            budget: ResourceFixture.budget(
                overrides: [.decodedPixelCount: ResourceFixture.numeric(10, .bytes)]
            )
        )
        #expect(
            wrongUnit.checkPixels(1, against: .decodedPixelCount)
                == .limitUnitMismatch(.decodedPixelCount, expected: .pixels)
        )

        let categorical = ValidationResourceChecks(budget: ResourceFixture.budget())
        #expect(
            categorical.checkBytes(1, against: .thermalState)
                == .limitUnitMismatch(.thermalState, expected: .bytes)
        )

        #expect(
            ValidationResourceChecks.Breach.measurementOverflow(.peakResidentMemory)
                .fault(at: .inputValidation)
                == .analysis(.resourceLimit, stage: .inputValidation)
        )
    }

    // MARK: - Overflow

    @Test("An unrepresentable decode cost is a resource limit, not an accepted decode")
    func decodeCostOverflowIsBounded() {
        // 2^62 pixels at four 8-bit channels overflows `UInt64`. A cost that cannot be
        // represented cannot be compared to a limit, so it must not pass.
        #expect(
            ValidationResourceChecks.estimatedDecodedByteCount(
                pixelCount: UInt64(1) << 62,
                bitsPerComponent: 8
            ) == nil
        )
        #expect(
            ValidationResourceChecks.estimatedDecodedByteCount(
                pixelCount: UInt64(1) << 40,
                bitsPerComponent: 16
            ) == UInt64(1) << 43
        )
        #expect(
            ValidationResourceChecks.estimatedDecodedByteCount(
                pixelCount: 1_000,
                bitsPerComponent: nil
            ) == 4_000
        )
    }

    @Test("A declared 16-bit depth doubles the estimated decode cost")
    func depthWidensTheEstimate() {
        let eightBit = ValidationResourceChecks.estimatedDecodedByteCount(
            pixelCount: 100,
            bitsPerComponent: 8
        )
        let sixteenBit = ValidationResourceChecks.estimatedDecodedByteCount(
            pixelCount: 100,
            bitsPerComponent: 16
        )
        #expect(eightBit == 400)
        #expect(sixteenBit == 800)
    }

    // MARK: - Cancellation

    @Test("A cancelled session returns cancelled rather than an error category")
    func cancellationIsNotAnError() async throws {
        let bytes = try #require(EncodedImageFixture.supported(.png))
        let harness = Harness()
        let asset = try await IngestFixture.asset(bytes: bytes, in: harness.store)

        let task = Task {
            await harness.validate(asset)
        }
        task.cancel()
        let result = await task.value

        guard case .failure(let fault) = result else {
            // Losing the cancellation race is acceptable: the check is that a cancelled
            // validation never reports an Analysis Error, not that cancellation always
            // wins.
            return
        }
        #expect(fault == .cancelled)
        #expect(fault.analysisError == nil)
    }
}
