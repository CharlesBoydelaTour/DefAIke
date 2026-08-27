import DefAIkeDomain
import CoreGraphics

// The Input Validating adapter.
//
// The order of the steps below is the requirement, not an implementation preference:
//
//   1. Bound the encoded copy against the budget using the byte count ingest already
//      measured, before reading a single byte into memory.
//   2. Classify the actual container from content, and stop on animated, video, audio,
//      or unsupported-static content before any decode work
//      (Requirements 1.11 through 1.14, 2.15, and 2.16).
//   3. Read the declared dimensions and depth, reject an unusable declaration, and
//      bound the pixel count and the decode's memory cost — all before the allocating
//      call (Requirements 3.3 and 3.4).
//   4. Complete the decode (Requirement 3.1), record the dimensions it actually
//      produced (Requirements 3.5 and 3.6), then re-check those dimensions, the pixel
//      count, and the memory against the same limits.
//   5. Only then produce a ``ValidatedImage``.
//
// Step 4's recording sits between the decode and the re-check on purpose. Requirement
// 3.5 records at the moment an image is completely decoded, and Requirement 3.14
// requires a failure to preserve what was recorded before it — so a decode that
// completed and was then refused by the budget has to report its dimensions, which is
// only possible if the recording precedes the refusal.
//
// Step 5 is the point of the type: a ``ValidatedImage`` cannot be constructed by any
// other path in this module, so "complete validation precedes inference" is a
// structural property of the pipeline rather than a convention the coordinator has to
// maintain (Property 8, and the port's own documentation).
//
// Nothing here does evidence work. Every failure returns a fault carrying exactly one
// ``AnalysisError`` and the stage that found it, and no preprocessing, provenance,
// calibration, or inference call exists in this file to be reached early.

/// Classifies the actual container and completes the bound contract's decode.
public struct ImageIOInputValidator: InputValidating {
    /// Where the retained encoded bytes live. The identical object the Provenance
    /// Analyzer reads, addressed by the same key (Requirements 2.12 and 2.13).
    private let encodedAssets: any EphemeralFileStoring

    /// Where the decoded image is retained for the Preprocessor.
    private let decodedImages: DecodedImageStore

    /// Where this session's measured input facts are recorded.
    ///
    /// Not optional. Requirement 3.5's recording is mandatory, and an absent recorder
    /// would make it conditional on how the adapter happened to be constructed.
    private let quality: InputQualityLedger

    /// The image index this build validates.
    ///
    /// Always the first, and only reachable when the container holds exactly one
    /// image: a container with more than one is `unsupported-media` before this is
    /// used, so there is no multi-frame selection policy to get wrong.
    private static let primaryImageIndex = 0

    public init(
        encodedAssets: any EphemeralFileStoring,
        decodedImages: DecodedImageStore,
        quality: InputQualityLedger
    ) {
        self.encodedAssets = encodedAssets
        self.decodedImages = decodedImages
        self.quality = quality
    }

    public func validate(
        _ asset: ImportedEncodedAsset,
        contract: PreprocessingContract,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ValidatedImage {
        let checks = ValidationResourceChecks(budget: budget)

        try checkCancellation()
        // Opening the session is the first thing validation does, so the Byte
        // Preservation Status ingest established is recorded before the earliest failure
        // this adapter can report and is preserved in that failure's snapshot
        // (Requirement 3.14). Opening also discards every measurement from every earlier
        // session, so nothing a failed session recorded can reach this one
        // (Requirements 3.13 and 3.15).
        await quality.beginSession(for: asset)

        try boundEncodedCopy(asset, checks: checks)

        try checkCancellation()
        let bytes = try await readRetainedBytes(asset)

        try checkCancellation()
        // One reader for classification, the declared properties, and the decode. Each
        // reader holds its own copy of the encoded bytes, and that copy counts against
        // the same memory limit the checks below enforce.
        let source = EncodedImageSource(bytes: bytes)
        let classification = ContainerClassifier.classify(
            bytes: bytes,
            source: source,
            supportedContainers: contract.supportedContainers
        )
        guard let container = classification.supportedContainer else {
            // Every non-supported classification carries exactly one error, so this
            // is total: there is no path past it without a supported container.
            throw classification.fault ?? .analysis(.decodingError, stage: .mediaClassification)
        }
        guard let source else {
            // Unreachable: a supported container means Image I/O opened the bytes.
            // Kept as a fail-closed branch rather than a force-unwrap, because the
            // alternative to an error here is a crash on malformed input.
            throw AnalysisFault.analysis(.decodingError, stage: .inputValidation)
        }

        try checkCancellation()
        let declared = try boundDeclaredImage(source, checks: checks)

        try checkCancellation()
        let decoded = try completeDecode(source, declared: declared)

        // Requirement 3.5's recording point: the image has completely decoded, so the
        // actual pre-orientation dimensions exist. They are recorded as decoded — no
        // orientation is applied here, and the declared values checked above are never
        // substituted for them — and they are recorded before the post-decode budget
        // re-check below, which is a failure that must preserve them.
        await quality.record(completelyDecoded: decoded.dimensions, for: asset.sessionID)

        let decodedByteCount = try boundDecodedCost(decoded, checks: checks)

        // Image I/O is not forcibly interruptible once the decode has been entered, so
        // cancellation is checked again on the way out. The decoded image is dropped
        // here rather than retained: it has not been stored yet, so a cancelled session
        // leaves nothing for cleanup to find (Requirement 11.14).
        try checkCancellation()

        let token = await decodedImages.store(
            DecodedImage(
                sessionID: asset.sessionID,
                dimensions: decoded.dimensions,
                decodedByteCount: decodedByteCount,
                image: decoded.image
            )
        )
        return ValidatedImage(
            sessionID: asset.sessionID,
            source: asset.handle,
            container: container,
            dimensions: decoded.dimensions,
            decodedImage: token,
            preprocessingContractID: contract.id,
            // No approved Calibration Policy defines an additional quality feature
            // yet, and Requirement 5.11 requires release evidence before one may
            // change an outcome. Recording an unvalidated measurement here would put
            // it one policy edit away from doing so.
            additionalQualityFeatures: [:]
        )
    }

    // MARK: - Step 1: the encoded copy

    /// Bounds the retained encoded copy before any of it is read into memory.
    ///
    /// The byte count comes from the handle, which carries what the store measured
    /// while writing, so this check costs no allocation and happens before the one
    /// allocation whose size it bounds.
    ///
    /// Two limits, for two different reasons. ``ResourceMetric/temporaryStorage`` is
    /// required for both targets (Requirements 11.2 and 11.3) and bounds the retained
    /// copy as stored bytes. ``ResourceMetric/encodedInputSize`` is a Share Extension
    /// metric and is legitimately absent from a main-application budget, so it is
    /// applied only when the bound budget defines it; inventing a main-app value for it
    /// is exactly the kind of unapproved limit the design forbids.
    private func boundEncodedCopy(
        _ asset: ImportedEncodedAsset,
        checks: ValidationResourceChecks
    ) throws(AnalysisFault) {
        var metrics: [ResourceMetric] = [.temporaryStorage]
        if checks.definesLimit(for: .encodedInputSize) {
            metrics.append(.encodedInputSize)
        }
        for metric in metrics {
            if let breach = checks.checkBytes(asset.byteCount, against: metric) {
                throw breach.fault(at: .inputValidation)
            }
        }
    }

    /// Reads the retained encoded bytes.
    ///
    /// Store faults are not presentable, and the closed vocabulary has no storage
    /// category (see ``AnalysisError``), so each one is mapped to the outcome it
    /// actually produces for this session: a bounded-capacity refusal is a
    /// `resource-limit`, and anything else means the retained representation could not
    /// be read completely, which is `decoding-error` under Requirement 3.3. Neither
    /// mapping invents a category and neither continues to evidence work.
    private func readRetainedBytes(
        _ asset: ImportedEncodedAsset
    ) async throws(AnalysisFault) -> [UInt8] {
        do {
            return try await encodedAssets.read(asset.handle.storageKey)
        } catch {
            // The store's typed throws make this exhaustive over ``EphemeralStoreError``:
            // a new store fault cannot arrive here as an unclassified default.
            switch error {
            case .capacityExceeded:
                throw AnalysisFault.analysis(.resourceLimit, stage: .inputValidation)
            case .notFound, .notFinalized, .keyAlreadyInUse, .alreadyFinalized,
                 .protectionUnavailable, .storeUnavailable:
                throw AnalysisFault.analysis(.decodingError, stage: .inputValidation)
            }
        }
    }

    // MARK: - Step 3: the declaration

    /// What the container declares, once it has been proved usable and in budget.
    private struct BoundedDeclaration {
        let dimensions: PixelDimensions
        let bitsPerComponent: Int?
    }

    /// Reads the declared dimensions and bounds them before the allocating decode.
    ///
    /// An absent, non-numeric, non-positive, or unrepresentable declaration is
    /// `decoding-error`: a container that cannot state a usable size is malformed, and
    /// substituting a guess would hand an unbounded decode to the resource checks.
    /// A declaration that is usable but too large is `resource-limit`, which is the
    /// case Requirement 3.4 names first.
    private func boundDeclaredImage(
        _ source: EncodedImageSource,
        checks: ValidationResourceChecks
    ) throws(AnalysisFault) -> BoundedDeclaration {
        guard let declared = source.declaredProperties(at: Self.primaryImageIndex),
              let dimensions = PixelDimensions(width: declared.width, height: declared.height)
        else {
            throw AnalysisFault.analysis(.decodingError, stage: .inputValidation)
        }
        try bound(
            dimensions: dimensions,
            bitsPerComponent: declared.bitsPerComponent,
            actualByteCount: nil,
            checks: checks
        )
        return BoundedDeclaration(
            dimensions: dimensions,
            bitsPerComponent: declared.bitsPerComponent
        )
    }

    // MARK: - Step 4: the decode

    /// One completely decoded image and the dimensions it actually produced.
    ///
    /// No byte cost: measuring what the decode cost is the bounding step's job, and the
    /// two are separate so the recording that Requirement 3.5 places at "completely
    /// decoded" can happen between them.
    private struct CompletedDecode {
        let image: CGImage
        let dimensions: PixelDimensions
    }

    /// Completes the decode and measures the dimensions it actually produced.
    ///
    /// The declaration was checked, but a container's header is not evidence about its
    /// pixels: the decoded dimensions are measured from the decoded image, and a decoded
    /// size that disagrees with the declared size is treated as an incomplete decode
    /// rather than as a new measurement to accept. That disagreement is the observable
    /// form of "cannot be completely decoded" for a container whose header outlived its
    /// image data (Requirement 3.3), and it is why a container that fails here has no
    /// recorded dimension: the declared pair was never a measurement of any pixels.
    private func completeDecode(
        _ source: EncodedImageSource,
        declared: BoundedDeclaration
    ) throws(AnalysisFault) -> CompletedDecode {
        guard let image = source.decodeCompleteImage(at: Self.primaryImageIndex) else {
            throw AnalysisFault.analysis(.decodingError, stage: .inputValidation)
        }
        guard let dimensions = PixelDimensions(width: image.width, height: image.height),
              dimensions == declared.dimensions
        else {
            throw AnalysisFault.analysis(.decodingError, stage: .inputValidation)
        }
        return CompletedDecode(image: image, dimensions: dimensions)
    }

    /// Re-bounds what the decode actually cost and reports the measurement the decoded
    /// image is retained with.
    ///
    /// The same limits the declaration was checked against, applied to the produced
    /// pixels instead of to the header's claim about them.
    private func boundDecodedCost(
        _ decoded: CompletedDecode,
        checks: ValidationResourceChecks
    ) throws(AnalysisFault) -> UInt64 {
        let (rowBytes, rowOverflow) = UInt64(decoded.image.bytesPerRow)
            .multipliedReportingOverflow(by: UInt64(decoded.image.height))
        guard !rowOverflow, rowBytes > 0 else {
            throw AnalysisFault.analysis(.resourceLimit, stage: .inputValidation)
        }
        try bound(
            dimensions: decoded.dimensions,
            bitsPerComponent: decoded.image.bitsPerComponent,
            actualByteCount: rowBytes,
            checks: checks
        )
        return rowBytes
    }

    // MARK: - Shared bounding

    /// Bounds a pixel count and a decode's memory cost against the bound budget.
    ///
    /// One routine for both the pre-decode estimate and the post-decode measurement,
    /// so the two cannot be checked against different metrics or with different
    /// overflow behavior. `actualByteCount` is the measured cost when it exists; before
    /// the decode there is nothing to measure, so the over-estimate derived from the
    /// declared depth is used instead.
    private func bound(
        dimensions: PixelDimensions,
        bitsPerComponent: Int?,
        actualByteCount: UInt64?,
        checks: ValidationResourceChecks
    ) throws(AnalysisFault) {
        if let breach = checks.checkPixels(dimensions.pixelCount, against: .decodedPixelCount) {
            throw breach.fault(at: .inputValidation)
        }
        let byteCount: UInt64
        if let actualByteCount {
            byteCount = actualByteCount
        } else {
            guard let estimate = ValidationResourceChecks.estimatedDecodedByteCount(
                pixelCount: dimensions.pixelCount,
                bitsPerComponent: bitsPerComponent
            ) else {
                throw ValidationResourceChecks.Breach
                    .measurementOverflow(.peakResidentMemory)
                    .fault(at: .inputValidation)
            }
            byteCount = estimate
        }
        if let breach = checks.checkBytes(byteCount, against: .peakResidentMemory) {
            throw breach.fault(at: .inputValidation)
        }
    }

    // MARK: - Cancellation

    /// Fails closed on a cancelled session.
    ///
    /// Checked at every stage boundary. Cancellation is not an Analysis Error and must
    /// never be presented as one, which is why ``AnalysisFault`` keeps it separate
    /// (Requirements 11.14 and 15.7).
    private func checkCancellation() throws(AnalysisFault) {
        if Task.isCancelled {
            throw AnalysisFault.cancelled
        }
    }
}
