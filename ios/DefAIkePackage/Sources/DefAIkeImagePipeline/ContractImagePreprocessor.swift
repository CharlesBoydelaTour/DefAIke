import DefAIkeDomain

// The Image Preprocessing adapter: the whole of the design's six-step list, in order.
//
//   1-3. ``WorkingSpaceRGBRenderer`` applies the bound orientation, working-space, and
//        alpha actions and produces three-channel RGB.
//   4-5. ``ResizeGeometry`` and ``BilinearResampler`` make the short edge exactly the
//        contract's target under its rounding, pixel-center, and edge rules, and take the
//        contract's centered crop.
//   6.   The crop's tightly packed bytes become one ``PreparedModelInput`` behind a
//        ``ModelInputToken``, unsigned 8-bit and unnormalized.
//
// Steps 4 and 5 run as one pass over the crop window. ``BilinearResampler`` states why
// that is byte-identical to materializing the resized image first, and why materializing
// it would put an avoidable peak in front of the Resource Budget.
//
// ## What this adapter refuses
//
// Every refusal below is Requirement 3.11's single outcome — `preprocessing-error`,
// without pixel inference — and none of them has a second attempt:
//
//   * a contract identifier that is not the one the decode was validated under;
//   * a decoded-image token that names nothing, or names another session's pixels;
//   * a retained encoded representation that cannot be read, so the container's
//     declarations cannot be observed and the contract's metadata rules have no observed
//     state to be applied to;
//   * any geometry the contract's fields do not describe exactly;
//   * a produced buffer that is not the shape, element type, or channel order the bound
//     model input declares.
//
// A Resource Budget refusal stays `resource-limit` and cancellation stays outside the
// Analysis Error vocabulary, exactly as in the renderer.
//
// ## What it does not do
//
// No normalization of any kind. The bytes handed to the store are the crop's bytes: no
// `1/255`, no mean subtraction, no standard-deviation division. Requirements 4.7 and 4.8
// put all three in the model graph, ``ModelInputContract`` refuses a contract that claims
// otherwise, and there is deliberately no code path here that could apply them.
//
// It also does not release the decoded image, take a failure snapshot, or clear the
// quality ledger. Those are session-lifecycle decisions the coordinator makes: the ledger
// already holds the pre-orientation dimensions and the Byte Preservation Status this
// stage's failures have to preserve (Requirement 3.14), and a snapshot taken here would
// be taken again there.

/// Applies the bound Preprocessing Contract to one validated image, or fails.
public struct ContractImagePreprocessor: ImagePreprocessing {
    /// Where the retained encoded bytes live.
    ///
    /// Read again here rather than carried forward from validation, because the
    /// container's *declarations* are what the contract's metadata rules are decided from
    /// and only the encoded bytes carry them: once Core Graphics has produced a `CGImage`,
    /// every image has some color space and some alpha layout, so "the container declared
    /// nothing" is not recoverable from the decoded image
    /// (``EncodedImageSource/metadataDeclarations(at:)``).
    private let encodedAssets: any EphemeralFileStoring

    /// Where the validator retained the decoded image.
    private let decodedImages: DecodedImageStore

    /// Where the prepared buffer is retained for the Pixel Analyzer.
    private let modelInputs: PreparedModelInputStore

    /// The image index this build prepares.
    ///
    /// Always the first, and only reachable when the container holds exactly one image: a
    /// container with more than one is `unsupported-media` before validation returns.
    private static let primaryImageIndex = 0

    public init(
        encodedAssets: any EphemeralFileStoring,
        decodedImages: DecodedImageStore,
        modelInputs: PreparedModelInputStore
    ) {
        self.encodedAssets = encodedAssets
        self.decodedImages = decodedImages
        self.modelInputs = modelInputs
    }

    public func prepare(
        _ image: ValidatedImage,
        contract: PreprocessingContract,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ModelImageInput {
        let checks = ValidationResourceChecks(budget: budget)

        try checkCancellation()
        // The contract bound to the session must be the contract the decode was validated
        // under. Requirement 4.12 has the Evidence Report identify one Preprocessing
        // Contract version for the session, and preparing under a different one would
        // report a version that did not govern the pixels.
        guard image.preprocessingContractID == contract.id else {
            throw Self.preprocessingError
        }

        try checkCancellation()
        let decoded = try await resolveDecodedImage(image)

        try checkCancellation()
        // The encoded copy is read into memory, so its cost is bounded before the read
        // rather than after it — the same ordering Requirement 3.4 imposes on the decode.
        if let breach = checks.checkBytes(image.source.byteCount, against: .peakResidentMemory) {
            throw breach.fault(at: .preprocessing)
        }
        let metadata = try await observeMetadata(image, decoded: decoded)

        try checkCancellation()
        // Steps 1 through 3. The renderer bounds its own allocations against the same
        // budget and reports its own faults, so its result is already contract-exact
        // three-channel RGB at the oriented dimensions.
        let rendered = try WorkingSpaceRGBRenderer(contract: contract, budget: budget)
            .render(decoded, metadata: metadata)

        try checkCancellation()
        do {
            let geometry = try ResizeGeometry.resolve(
                source: rendered.dimensions,
                resize: contract.resize,
                crop: contract.crop
            )
            try boundSampling(
                decodedByteCount: decoded.decodedByteCount,
                rendered: rendered,
                crop: geometry.crop.size,
                checks: checks
            )
            try checkCancellationDuringSampling()
            // Steps 4 and 5, as one pass over the crop window.
            let cropped = try resample(rendered, geometry: geometry, resize: contract.resize)
            // Step 6.
            return try await produceModelInput(
                cropped,
                for: image,
                contract: contract
            )
        } catch {
            // The single conversion from "why" to "what the session reports", exactly as
            // in the renderer.
            throw error.fault
        }
    }

    // MARK: - The decoded image

    /// The decoded image `image` names, or a refusal.
    ///
    /// Two separate checks, because they are two different situations that must not be
    /// collapsed: a token that names nothing (the session ended, or cleanup ran), and a
    /// token that names pixels belonging to another session. The second is the one
    /// Requirement 3.15 cares about — preparing another session's pixels under this
    /// session's identity would attribute one image's evidence to a different input.
    private func resolveDecodedImage(
        _ image: ValidatedImage
    ) async throws(AnalysisFault) -> DecodedImage {
        guard let decoded = await decodedImages.image(for: image.decodedImage) else {
            throw Self.preprocessingError
        }
        guard decoded.sessionID == image.sessionID else {
            throw Self.preprocessingError
        }
        guard decoded.dimensions == image.dimensions else {
            // The recorded pre-orientation dimensions and the retained pixels describe
            // the same decode. A disagreement means one of them is not a measurement of
            // the other, and the sub-440 abstention rule reads the recorded pair.
            throw Self.preprocessingError
        }
        return decoded
    }

    // MARK: - The observed metadata

    /// The three metadata states the contract's rules are applied to.
    ///
    /// The declarations come from the retained encoded bytes and the layout facts from the
    /// decoded image, which is the split ``ImageMetadataInspector`` requires. A read
    /// failure is `preprocessing-error` rather than `decoding-error`: the decode already
    /// completed and was accepted, so what has failed is applying the contract to it,
    /// which is the category Requirement 3.11 names. A bounded-capacity refusal keeps
    /// `resource-limit`, because that is the budget speaking and not the contract.
    private func observeMetadata(
        _ image: ValidatedImage,
        decoded: DecodedImage
    ) async throws(AnalysisFault) -> ObservedImageMetadata {
        let bytes: [UInt8]
        do {
            bytes = try await encodedAssets.read(image.source.storageKey)
        } catch {
            // The store's typed throws make this exhaustive over ``EphemeralStoreError``:
            // a new store fault cannot arrive here as an unclassified default.
            switch error {
            case .capacityExceeded:
                throw AnalysisFault.analysis(.resourceLimit, stage: .preprocessing)
            case .notFound, .notFinalized, .keyAlreadyInUse, .alreadyFinalized,
                 .protectionUnavailable, .storeUnavailable:
                throw Self.preprocessingError
            }
        }
        guard let source = EncodedImageSource(bytes: bytes) else {
            // Validation opened these exact bytes, so this is unreachable. A fail-closed
            // branch rather than a force-unwrap: the alternative to a refusal is guessing
            // at declarations the container may not carry.
            throw Self.preprocessingError
        }
        return ImageMetadataInspector.observe(
            properties: source.metadataDeclarations(at: Self.primaryImageIndex),
            image: decoded.image
        )
    }

    // MARK: - Steps 4 and 5: the resample

    /// The crop window, resampled by the interpolation the contract names.
    ///
    /// An exhaustive switch on the contract's own field rather than a direct call to the
    /// bilinear sampler. ``ResizeInterpolation`` has one case today because Requirement 4.4
    /// fixes bilinear, and writing the dispatch out is what makes a second case a compile
    /// error here instead of an input that silently keeps being resampled bilinearly under
    /// a contract that asked for something else.
    private func resample(
        _ rendered: PixelSurface,
        geometry: ResizeGeometry,
        resize: ResizeContract
    ) throws(PreprocessingFailure) -> PixelSurface {
        switch resize.interpolation {
        case .bilinear:
            return try BilinearResampler.sample(
                rendered,
                resized: geometry.resized,
                window: geometry.crop,
                convention: resize.pixelCenterConvention,
                edgeRule: resize.edgeRule
            )
        }
    }

    // MARK: - Step 6: the model input

    /// Retains the crop as the bound contract's model input and names it with a token.
    ///
    /// ``ModelInputProduction`` decides whether the buffer is the one the contract
    /// declares; this function only retains it. The bytes are the crop's bytes: the whole
    /// of step 6 is a copy.
    private func produceModelInput(
        _ cropped: PixelSurface,
        for image: ValidatedImage,
        contract: PreprocessingContract
    ) async throws(PreprocessingFailure) -> ModelImageInput {
        let modelInput = contract.modelInput
        let bytes = try ModelInputProduction.bytes(from: cropped, modelInput: modelInput)
        guard let prepared = PreparedModelInput(
            sessionID: image.sessionID,
            edge: modelInput.width,
            channelOrder: modelInput.channelOrder,
            bytes: bytes
        ) else {
            // Unreachable: ``ModelInputProduction`` has already proved the length is
            // `edge * edge * 3` for a positive edge, which is the only thing the
            // initializer refuses. A fail-closed branch rather than a force-unwrap.
            throw .modelInputNotProducible(
                reason: "the packed crop is not \(modelInput.width) * \(modelInput.width) * 3 bytes"
            )
        }
        let token = await modelInputs.store(prepared)
        return ModelImageInput(
            sessionID: image.sessionID,
            buffer: token,
            contract: modelInput,
            preprocessingContractID: contract.id
        )
    }

    // MARK: - Resource bounding

    /// Bounds the allocations the sampling step will make, before it makes any of them.
    ///
    /// The peak at this point is the decoded image, which the store keeps alive as the
    /// transform's source, the rendered working-space RGB surface, and the crop the
    /// sampler is about to allocate. The resized image is deliberately absent: it is never
    /// materialized, which is the point of fusing the crop into the resample.
    ///
    /// Row padding is rounded up in the crop estimate for the same reason the renderer
    /// rounds its own up: a breach has to be detectable before the memory is taken, so the
    /// estimate must never be lower than the allocation it precedes (Requirement 3.4).
    private func boundSampling(
        decodedByteCount: UInt64,
        rendered: PixelSurface,
        crop: PixelDimensions,
        checks: ValidationResourceChecks
    ) throws(PreprocessingFailure) {
        guard
            let cropBytes = PixelSurface.estimatedAllocationByteCount(
                width: crop.width,
                height: crop.height,
                channelCount: rendered.channelCount
            ),
            let peak = Self.sum([decodedByteCount, rendered.allocatedByteCount, cropBytes])
        else {
            // A cost that cannot be represented cannot be shown to fit any limit. That is
            // a fail-closed refusal, not an unbounded allowance.
            throw .resourceBreach(.measurementOverflow(.peakResidentMemory))
        }
        if let breach = checks.checkBytes(peak, against: .peakResidentMemory) {
            throw .resourceBreach(breach)
        }
    }

    /// The sum of `values`, or `nil` on overflow.
    private static func sum(_ values: [UInt64]) -> UInt64? {
        var total: UInt64 = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    // MARK: - Cancellation

    private static let preprocessingError = AnalysisFault.analysis(
        .preprocessingError,
        stage: .preprocessing
    )

    /// Fails closed on a cancelled session.
    ///
    /// Cancellation is not an Analysis Error and must never be presented as one, which is
    /// why ``AnalysisFault`` keeps it separate (Requirements 11.14 and 15.7).
    private func checkCancellation() throws(AnalysisFault) {
        if Task.isCancelled {
            throw AnalysisFault.cancelled
        }
    }

    /// The same check, in the failure vocabulary the geometry and sampling steps throw.
    ///
    /// The sampler is one uninterruptible loop over the crop, so the guarantee is that no
    /// cancelled session produces a prepared buffer, not that an in-flight pass stops
    /// early.
    private func checkCancellationDuringSampling() throws(PreprocessingFailure) {
        if Task.isCancelled {
            throw .cancelled
        }
    }
}
