import DefAIkeDomain
import Testing
import UniformTypeIdentifiers

@testable import DefAIkeImagePipeline

/// The exact pre-orientation quality record, the failure snapshot it survives into, and
/// the isolation between a failed session and the session that follows it.
///
/// Requirements 3.5, 3.6, 3.13, 3.14, and 3.15.
///
/// Two lifetimes are under test here and they pull in opposite directions. A measurement
/// has to outlive the *step* that took it, so a decode that completed and was then
/// refused still reports its dimensions (Requirement 3.14). A measurement must not
/// outlive its *session*, so the session after a failed one begins with none of its
/// predecessor's data (Requirements 3.13 and 3.15). A test that confused the two would
/// pass for the wrong reason, which is why every isolation assertion below is made under
/// the *old* session's identity as well as the new one's.
@Suite("Pre-orientation quality records and failure snapshots")
struct InputQualityRecordTests {

    // MARK: - Shared arrangements

    /// An accepted ingest for `sessionID`, carrying the status `basis` supports.
    ///
    /// The bytes are deliberately not an image. The ledger records a measurement it is
    /// handed rather than one it takes, so the tests that are about the record hand it one
    /// directly and never involve Image I/O; the tests that are about the pipeline go
    /// through the real validator further down.
    private static func asset(
        _ sessionID: String,
        basis: PreservationBasis = .providerDeclaredOriginalRepresentation,
        in store: InMemoryEncodedAssetStore
    ) async throws -> ImportedEncodedAsset {
        try await IngestFixture.asset(
            bytes: EncodedImageFixture.unidentifiableBytes,
            in: store,
            sessionID: Fixture.sessionID(sessionID),
            preservationBasis: basis
        )
    }

    /// One ledger with `sessionID` already open.
    private static func openLedger(
        _ sessionID: String,
        basis: PreservationBasis = .providerDeclaredOriginalRepresentation
    ) async throws -> (ledger: InputQualityLedger, asset: ImportedEncodedAsset) {
        let store = InMemoryEncodedAssetStore()
        let asset = try await asset(sessionID, basis: basis, in: store)
        let ledger = InputQualityLedger()
        await ledger.beginSession(for: asset)
        return (ledger, asset)
    }

    private static func dimensions(_ width: Int, _ height: Int) -> PixelDimensions {
        guard let dimensions = PixelDimensions(width: width, height: height) else {
            preconditionFailure("\(width) by \(height) is not a positive dimension pair")
        }
        return dimensions
    }

    /// The five failures Requirement 3.12 admits from validation and preprocessing, each
    /// paired with the stage that commits it.
    private static let presentableFailures: [(error: AnalysisError, stage: AnalysisStage)] = [
        (.unsupportedMedia, .mediaClassification),
        (.unsupportedStaticFormat, .mediaClassification),
        (.decodingError, .inputValidation),
        (.resourceLimit, .inputValidation),
        (.preprocessingError, .preprocessing),
    ]

    private static let decodeFault = AnalysisFault.analysis(
        .decodingError,
        stage: .inputValidation
    )

    // MARK: - The record is the decoded pair, exactly

    @Test(
        "A recorded decode stores the decoded pair unswapped, with the lesser value as the short edge",
        arguments: [
            (64, 20), (20, 64), (1, 1), (440, 440), (439, 440), (440, 439), (4_096, 7),
        ]
    )
    func recordIsTheExactDecodedPair(width: Int, height: Int) async throws {
        let (ledger, asset) = try await Self.openLedger("session-exact")

        await ledger.record(
            completelyDecoded: Self.dimensions(width, height),
            for: asset.sessionID
        )

        let record = try #require(await ledger.qualityRecord(for: asset.sessionID))
        #expect(record.decodedWidthBeforeOrientation == width)
        #expect(record.decodedHeightBeforeOrientation == height)
        // Exactly `min(width, height)` of the pair as recorded, which is what
        // Requirement 3.6 fixes. The 439/440 pairs are the boundary the sub-440
        // abstention rule reads: a short edge taken from the wrong axis would move an
        // input across it.
        #expect(record.shortEdgeBeforeOrientation == min(width, height))
        #expect(record.validatedFeatures.isEmpty)
    }

    @Test("Swapping the decoded pair swaps the record rather than normalizing it")
    func recordIsNotNormalizedToOneOrientation() async throws {
        // 20 by 64 and 64 by 20 are measurements of two different images. A record that
        // sorted the pair, or normalized it to landscape, would report the same width for
        // both and "before orientation is applied" would be unobservable.
        let portrait = try await Self.openLedger("session-portrait")
        let landscape = try await Self.openLedger("session-landscape")
        await portrait.ledger.record(
            completelyDecoded: Self.dimensions(20, 64),
            for: portrait.asset.sessionID
        )
        await landscape.ledger.record(
            completelyDecoded: Self.dimensions(64, 20),
            for: landscape.asset.sessionID
        )

        let portraitRecord = try #require(
            await portrait.ledger.qualityRecord(for: portrait.asset.sessionID)
        )
        let landscapeRecord = try #require(
            await landscape.ledger.qualityRecord(for: landscape.asset.sessionID)
        )
        #expect(portraitRecord.decodedWidthBeforeOrientation == 20)
        #expect(portraitRecord.decodedHeightBeforeOrientation == 64)
        #expect(landscapeRecord.decodedWidthBeforeOrientation == 64)
        #expect(landscapeRecord.decodedHeightBeforeOrientation == 20)
        #expect(portraitRecord != landscapeRecord)
        // The short edge is the same for both, because 20 is the lesser value either way.
        #expect(portraitRecord.shortEdgeBeforeOrientation == 20)
        #expect(landscapeRecord.shortEdgeBeforeOrientation == 20)
    }

    @Test("An unmeasured session reports no dimension rather than a zero or a placeholder")
    func unmeasuredDimensionsStayUnknown() async throws {
        let (ledger, asset) = try await Self.openLedger("session-unmeasured")

        #expect(await ledger.qualityRecord(for: asset.sessionID) == nil)
        // The byte status is known from ingest before validation begins, so it is
        // available for the earliest failure this pipeline can report.
        #expect(await ledger.bytePreservationStatus(for: asset.sessionID) == .originalBytes)

        let snapshot = try #require(
            await ledger.failureSnapshot(for: asset.sessionID, fault: Self.decodeFault)
        )
        // Unknown, not zero and not the container's declared size. A substituted zero
        // would read as a sub-440 short edge, and a substituted declaration would read as
        // a measurement of pixels nobody decoded — both are decisions the Calibration
        // Policy is entitled to make only from a real measurement.
        #expect(snapshot.inputQuality == nil)
        #expect(snapshot.bytePreservationStatus == .originalBytes)
    }

    @Test("The first complete decode is the record, and a second does not redefine it")
    func firstCompleteDecodeIsTheRecord() async throws {
        let (ledger, asset) = try await Self.openLedger("session-once")

        await ledger.record(completelyDecoded: Self.dimensions(900, 600), for: asset.sessionID)
        await ledger.record(completelyDecoded: Self.dimensions(100, 100), for: asset.sessionID)

        // One session decodes one image. Letting a second measurement redefine the record
        // would move a short edge an abstention decision may already have read.
        let record = try #require(await ledger.qualityRecord(for: asset.sessionID))
        #expect(record.decodedWidthBeforeOrientation == 900)
        #expect(record.decodedHeightBeforeOrientation == 600)
        #expect(record.shortEdgeBeforeOrientation == 600)
    }

    // MARK: - What a failure preserves

    @Test(
        "A measurement taken before a failure is preserved by it",
        arguments: [
            (AnalysisError.resourceLimit, AnalysisStage.inputValidation),
            (.preprocessingError, .preprocessing),
        ]
    )
    func measurementOutlivesTheStepThatTookIt(
        error: AnalysisError,
        stage: AnalysisStage
    ) async throws {
        // The two failures Requirement 3.14 names: a decode the budget refused after it
        // had completed, and an accepted decode the bound contract could not transform.
        // Both are detected after the recording point, so both have to report it.
        let (ledger, asset) = try await Self.openLedger(
            "session-refused",
            basis: .providerDeclaredTransformedRepresentation
        )
        await ledger.record(completelyDecoded: Self.dimensions(900, 600), for: asset.sessionID)

        let snapshot = try #require(
            await ledger.failureSnapshot(
                for: asset.sessionID,
                fault: .analysis(error, stage: stage)
            )
        )

        #expect(snapshot.sessionID == asset.sessionID)
        #expect(snapshot.error == error)
        #expect(snapshot.stage == stage)
        #expect(snapshot.bytePreservationStatus == .platformTransformedCopy)
        let preserved = try #require(snapshot.inputQuality)
        #expect(preserved.decodedWidthBeforeOrientation == 900)
        #expect(preserved.decodedHeightBeforeOrientation == 600)
        #expect(preserved.shortEdgeBeforeOrientation == 600)
        // Preserved, not re-derived: the snapshot and the live record are the same value.
        #expect(preserved == (await ledger.qualityRecord(for: asset.sessionID)))
    }

    @Test(
        "The recorded byte status survives every presentable failure unchanged",
        arguments: PreservationBasis.allCases
    )
    func byteStatusSurvivesEveryPresentableFailure(basis: PreservationBasis) async throws {
        let (ledger, asset) = try await Self.openLedger("session-status", basis: basis)

        for failure in Self.presentableFailures {
            let snapshot = try #require(
                await ledger.failureSnapshot(
                    for: asset.sessionID,
                    fault: .analysis(failure.error, stage: failure.stage)
                ),
                "\(failure.error.rawValue) must produce a snapshot"
            )
            let status = try #require(snapshot.bytePreservationStatus)
            // As recorded, so no failure can report a status the ingest basis does not
            // support — in particular none may report `originalBytes` for bytes whose
            // history was never established.
            #expect(status == basis.mostConservativeStatus)
            #expect(basis.supports(status))
        }
    }

    @Test("Cancellation has no snapshot, even when a measurement exists")
    func cancellationIsNotAFailureToSnapshot() async throws {
        let (ledger, asset) = try await Self.openLedger("session-cancelled")
        await ledger.record(completelyDecoded: Self.dimensions(900, 600), for: asset.sessionID)

        // Cancellation is not an Analysis Error and must never be presented as one, so
        // there is no category to snapshot.
        #expect(await ledger.failureSnapshot(for: asset.sessionID, fault: .cancelled) == nil)
        // It is also not a reason to forget what was measured: the record is still there
        // for a coordinator that has to decide which terminal outcome won.
        #expect(await ledger.qualityRecord(for: asset.sessionID) != nil)
    }

    @Test("Taking a snapshot does not consume the record")
    func snapshotIsRepeatable() async throws {
        let (ledger, asset) = try await Self.openLedger("session-repeat")
        await ledger.record(completelyDecoded: Self.dimensions(500, 700), for: asset.sessionID)

        let first = await ledger.failureSnapshot(for: asset.sessionID, fault: Self.decodeFault)
        let second = await ledger.failureSnapshot(for: asset.sessionID, fault: Self.decodeFault)

        #expect(first == second)
        #expect(first?.inputQuality?.shortEdgeBeforeOrientation == 500)
        #expect(await ledger.qualityRecord(for: asset.sessionID) != nil)
    }

    // MARK: - A new session is isolated from a failed one

    @Test("A new session inherits no dimension, no byte status, and no error category")
    func newSessionInheritsNothingFromAFailedOne() async throws {
        let store = InMemoryEncodedAssetStore()
        let ledger = InputQualityLedger()
        let failed = try await Self.asset("session-failed", in: store)
        await ledger.beginSession(for: failed)
        await ledger.record(completelyDecoded: Self.dimensions(900, 600), for: failed.sessionID)
        let failure = try #require(
            await ledger.failureSnapshot(for: failed.sessionID, fault: Self.decodeFault)
        )
        #expect(failure.inputQuality?.shortEdgeBeforeOrientation == 600)

        // The valid selection that follows. No restart and no reset call: opening the next
        // session is the whole of it (Requirement 3.13).
        let retry = try await Self.asset(
            "session-retry",
            basis: .preservationHistoryNotEstablished,
            in: store
        )
        await ledger.beginSession(for: retry)

        #expect(retry.sessionID != failed.sessionID)
        #expect(await ledger.openSessionID == retry.sessionID)
        // Nothing the failed session recorded is reachable under its own identity.
        #expect(await ledger.qualityRecord(for: failed.sessionID) == nil)
        #expect(await ledger.bytePreservationStatus(for: failed.sessionID) == nil)
        #expect(await ledger.failureSnapshot(for: failed.sessionID, fault: Self.decodeFault) == nil)
        // Nor under the new one: the new session has its own status and no measurement.
        #expect(await ledger.qualityRecord(for: retry.sessionID) == nil)
        #expect(await ledger.bytePreservationStatus(for: retry.sessionID) == .unknown)

        let fresh = try #require(
            await ledger.failureSnapshot(
                for: retry.sessionID,
                fault: .analysis(.preprocessingError, stage: .preprocessing)
            )
        )
        #expect(fresh.sessionID == retry.sessionID)
        #expect(fresh.inputQuality == nil)
        #expect(fresh.bytePreservationStatus == .unknown)
        // The category comes from the fault presented now, not from a stored field, which
        // is why there is no error category to inherit.
        #expect(fresh.error == .preprocessingError)
        #expect(fresh.error != failure.error)
    }

    @Test("A retry session records its own measurement")
    func retrySessionRecordsItsOwn() async throws {
        let store = InMemoryEncodedAssetStore()
        let ledger = InputQualityLedger()
        let failed = try await Self.asset("session-first", in: store)
        await ledger.beginSession(for: failed)
        await ledger.record(completelyDecoded: Self.dimensions(900, 600), for: failed.sessionID)

        let retry = try await Self.asset("session-second", in: store)
        await ledger.beginSession(for: retry)
        await ledger.record(completelyDecoded: Self.dimensions(120, 300), for: retry.sessionID)

        // Different dimensions on purpose: were the slot merged rather than replaced, the
        // retry would report the failed session's short edge of 600.
        let record = try #require(await ledger.qualityRecord(for: retry.sessionID))
        #expect(record.decodedWidthBeforeOrientation == 120)
        #expect(record.decodedHeightBeforeOrientation == 300)
        #expect(record.shortEdgeBeforeOrientation == 120)
    }

    @Test("A measurement arriving late from an ended session lands nowhere")
    func lateMeasurementFromAnEndedSessionIsDiscarded() async throws {
        let store = InMemoryEncodedAssetStore()
        let ledger = InputQualityLedger()
        let ended = try await Self.asset("session-ended", in: store)
        await ledger.beginSession(for: ended)

        let current = try await Self.asset("session-current", in: store)
        await ledger.beginSession(for: current)
        // A decode that was already under way when its session ended. Applying it would
        // put one session's pixels in another session's record.
        await ledger.record(completelyDecoded: Self.dimensions(900, 600), for: ended.sessionID)

        #expect(await ledger.qualityRecord(for: current.sessionID) == nil)
        #expect(await ledger.qualityRecord(for: ended.sessionID) == nil)
        #expect(await ledger.openSessionID == current.sessionID)
    }

    @Test("Discarding clears the ledger and is idempotent")
    func discardIsIdempotent() async throws {
        let (ledger, asset) = try await Self.openLedger("session-discard")
        await ledger.record(completelyDecoded: Self.dimensions(900, 600), for: asset.sessionID)

        await ledger.discard()
        await ledger.discard()

        #expect(await ledger.openSessionID == nil)
        #expect(await ledger.qualityRecord(for: asset.sessionID) == nil)
        #expect(await ledger.bytePreservationStatus(for: asset.sessionID) == nil)
        #expect(await ledger.failureSnapshot(for: asset.sessionID, fault: Self.decodeFault) == nil)
    }

    // MARK: - Through the real validator

    /// One validator over a fresh store, decoded-image registry, and ledger.
    private struct Harness {
        let store = InMemoryEncodedAssetStore()
        let decodedImages = DecodedImageStore()
        let quality = InputQualityLedger()
        let contract = PreprocessingFixture.contract()
        let budget = ResourceFixture.budget()
        let validator: ImageIOInputValidator

        init() {
            self.validator = ImageIOInputValidator(
                encodedAssets: store,
                decodedImages: decodedImages,
                quality: quality
            )
        }

        func validate(
            _ bytes: [UInt8],
            sessionID: AnalysisSessionID
        ) async throws -> Result<ValidatedImage, AnalysisFault> {
            let asset = try await IngestFixture.asset(
                bytes: bytes,
                in: store,
                sessionID: sessionID
            )
            do {
                return .success(
                    try await validator.validate(asset, contract: contract, budget: budget)
                )
            } catch {
                return .failure(error)
            }
        }
    }

    @Test(
        "A declared orientation does not swap the recorded decoded dimensions",
        arguments: ExifOrientation.allCases
    )
    func declaredOrientationDoesNotSwapTheRecord(orientation: ExifOrientation) async throws {
        // The container states where the stored image's first row and column belong, and
        // four of the eight values exchange the axes when that is applied. The record is
        // of what was *decoded*, so all eight must record the stored 12-by-8 pair and a
        // short edge of 8. Recording the displayed pair would move the short edge for half
        // of them, and with it the sub-440 abstention decision.
        let bytes = try #require(
            DeclaringImageFixture.jpeg(orientation: orientation.rawValue, width: 12, height: 8)
        )
        // The declaration has to actually be in the container, or this test would pass
        // against an untagged JPEG and prove nothing.
        let declarations = try #require(DeclaringImageFixture.declarations(of: bytes))
        let observed = ImageMetadataInspector.observeOrientation(declarations)
        #expect(observed.state == .valid)
        #expect(observed.declared == orientation)

        let harness = Harness()
        let sessionID = Fixture.sessionID("session-orientation-\(orientation.rawValue)")
        let validated = try await harness.validate(bytes, sessionID: sessionID).get()

        #expect(validated.dimensions.width == 12)
        #expect(validated.dimensions.height == 8)
        let record = try #require(await harness.quality.qualityRecord(for: sessionID))
        #expect(record.decodedWidthBeforeOrientation == 12)
        #expect(record.decodedHeightBeforeOrientation == 8)
        #expect(record.shortEdgeBeforeOrientation == 8)
        // The ledger's record and the validated image's derived record are one value, so
        // the presenter and the Calibration Policy cannot read different measurements.
        #expect(record == validated.quality)
    }

    @Test("A failed decode preserves the byte status and records no dimension")
    func failedDecodeKeepsByteStatusAndNoDimension() async throws {
        // A truncated JPEG: the container type is intact, so validation gets as far as the
        // decode and then cannot complete it. The declared pair was checked, but a header
        // is not a measurement of pixels, so there is nothing to preserve but the status.
        let harness = Harness()
        let sessionID = Fixture.sessionID("session-truncated")
        let result = try await harness.validate(
            EncodedImageFixture.truncatedJPEG(fraction: 0.3),
            sessionID: sessionID
        )

        guard case .failure(let fault) = result else {
            Issue.record("a truncated JPEG must not validate")
            return
        }
        #expect(fault.analysisError == .decodingError)

        let snapshot = try #require(
            await harness.quality.failureSnapshot(for: sessionID, fault: fault)
        )
        #expect(snapshot.sessionID == sessionID)
        #expect(snapshot.error == .decodingError)
        #expect(snapshot.bytePreservationStatus == .originalBytes)
        #expect(snapshot.inputQuality == nil)
        #expect(await harness.decodedImages.retainedImageCount == 0)
    }

    @Test("A valid selection after a failed session starts clean, with no restart")
    func retryAfterAFailedSessionIsIsolated() async throws {
        let harness = Harness()
        let failedID = Fixture.sessionID("session-failed-decode")
        let retryID = Fixture.sessionID("session-retry-decode")

        let failed = try await harness.validate(
            EncodedImageFixture.unidentifiableBytes,
            sessionID: failedID
        )
        guard case .failure(let fault) = failed else {
            Issue.record("unidentifiable bytes must not validate")
            return
        }
        #expect(await harness.quality.failureSnapshot(for: failedID, fault: fault) != nil)

        // The same validator and the same ledger, with nothing reset in between.
        let bytes = try #require(
            EncodedImageFixture.encode(
                EncodedImageFixture.gradient(width: 64, height: 20),
                as: .png
            )
        )
        let validated = try await harness.validate(bytes, sessionID: retryID).get()

        #expect(validated.sessionID == retryID)
        let record = try #require(await harness.quality.qualityRecord(for: retryID))
        #expect(record.decodedWidthBeforeOrientation == 64)
        #expect(record.decodedHeightBeforeOrientation == 20)
        #expect(record.shortEdgeBeforeOrientation == 20)
        // The failed session's identity now resolves to nothing at all.
        #expect(await harness.quality.qualityRecord(for: failedID) == nil)
        #expect(await harness.quality.bytePreservationStatus(for: failedID) == nil)
        #expect(await harness.quality.failureSnapshot(for: failedID, fault: fault) == nil)
        #expect(await harness.quality.openSessionID == retryID)
        // And the only decoded pixels in the process belong to the new session: the failed
        // one never reached the point where an image is retained.
        #expect(await harness.decodedImages.retainedImageCount == 1)
        let decoded = try #require(await harness.decodedImages.image(for: validated.decodedImage))
        #expect(decoded.sessionID == retryID)
    }
}
