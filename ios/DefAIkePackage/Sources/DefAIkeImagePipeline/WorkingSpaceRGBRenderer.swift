import Accelerate
import DefAIkeDomain
import CoreGraphics

// The metadata, RGB, color-space, and alpha half of the Preprocessor.
//
// This is steps 1 through 3 of the design's preprocessing list: apply the contract's
// orientation rule, decode into the contract's explicit three-channel RGB working space,
// and apply its embedded-profile and alpha-compositing rules. The deterministic resize
// and the 384-by-384 crop are steps 4 through 6 and are not here.
//
// Why native Image I/O, Core Graphics/ColorSync, and Accelerate rather than `UIImage`
// convenience rendering: a convenience renderer decides orientation, color conversion,
// interpolation, and alpha behavior on your behalf, and each of those decisions changes
// the samples the model sees. The whole point of a signed Preprocessing Contract is that
// those decisions are release values, so every one of them is spelled out here and any
// inability to perform the exact bound one returns `preprocessing-error`
// (Requirement 3.11).
//
// ## Order of operations, and why it is not the order the design lists
//
// The design lists orientation before the color-space conversion. This renderer converts
// first, then orients, then resolves alpha. The observable result is identical, and the
// reason is worth stating because "it looked equivalent" is not an argument:
//
//   * A color conversion is a per-pixel function: the sample at a coordinate depends
//     only on the sample that was at that coordinate.
//   * An orientation is a coordinate permutation: it moves samples without reading or
//     changing them.
//
// A per-pixel function composed with a permutation commutes exactly, in either order,
// for every input — there is no rounding, clamping, or neighbourhood term to disagree
// about. Converting first buys one concrete thing: the permutation then runs on a single
// known layout (unpremultiplied 8-bit RGBA in the working space) instead of on whichever
// of the dozen layouts Image I/O decoded into, which removes an entire class of
// layout-specific rotation code and the parity bugs that come with it.
//
// Alpha resolution is also per-pixel, so it commutes with orientation too. It is last
// for a different reason: the contract states its opaque background as three 8-bit
// channels with no color space of its own, so the only space those channels can mean is
// the contract's working space, and compositing therefore has to happen after the samples
// are in it.
//
// ## What is deliberately not decided here
//
// The contract schema binds no rendering intent, so out-of-gamut mapping during a
// conversion is left to the intent each ICC profile declares
// (``CGColorRenderingIntent/defaultIntent``). That is the profile's own decision rather
// than one this file makes up, but it is an unbound value: if release parity measurement
// shows the intent matters, it belongs in the contract, not in this comment.

/// Renders one completely decoded image into the contract's working-space
/// three-channel RGB, applying the bound orientation, embedded-profile, and alpha
/// actions.
struct WorkingSpaceRGBRenderer {
    /// The Analysis Session-bound contract. Every choice below comes from it.
    let contract: PreprocessingContract

    /// The active Resource Budget. Every allocation below is bounded by it.
    let budget: ResourceBudget

    /// Interleaved channels in the working buffer the transform operates on.
    ///
    /// Four: three color channels plus alpha, so one code path covers images with and
    /// without transparency and the "no alpha channel" case is a fully opaque alpha
    /// channel rather than a separate set of operations that could disagree.
    private static let workingChannelCount = 4

    /// Interleaved channels in the rendered result.
    ///
    /// Three, which is Requirement 4.3's three-channel RGB.
    static let renderedChannelCount = 3

    /// The rendered working-space RGB image.
    ///
    /// Tightly packed, row-major, three bytes per pixel in the contract's working color
    /// space, at the dimensions the bound orientation action produces. This is the input
    /// the deterministic resize consumes.
    ///
    /// Throws exactly one ``AnalysisFault``: `preprocessing-error` for any inability to
    /// apply the bound contract, `resource-limit` for a budget refusal, or cancellation.
    func render(
        _ decoded: DecodedImage,
        metadata: ObservedImageMetadata
    ) throws(AnalysisFault) -> PixelSurface {
        do {
            return try apply(decoded, metadata: metadata)
        } catch {
            // The single conversion from "why" to "what the session reports".
            throw error.fault
        }
    }

    // MARK: - The transform

    private func apply(
        _ decoded: DecodedImage,
        metadata: ObservedImageMetadata
    ) throws(PreprocessingFailure) -> PixelSurface {
        try checkCancellation()

        // Every contract lookup happens before any pixel is touched, so a contract this
        // build cannot apply costs no allocation and no partial work.
        let actions = try MetadataActionBinding.bind(metadata, contract: contract)
        try refuseRejectedStates(actions, metadata: metadata)
        let workingSpace = try WorkingColorSpace.resolve(contract.rgbWorkingSpace)
        let orientation = try appliedOrientation(actions.orientation, metadata: metadata)
        let orientedDimensions = Self.orientedDimensions(
            decoded.dimensions,
            applying: orientation
        )
        try boundAllocations(
            decodedByteCount: decoded.decodedByteCount,
            source: decoded.dimensions,
            oriented: orientedDimensions
        )

        try checkCancellation()
        var surface = try materializeWorkingSpaceRGBA(
            decoded.image,
            workingSpace: workingSpace,
            action: actions.colorProfile,
            observedState: metadata.colorProfile
        )

        try checkCancellation()
        surface = try orient(surface, by: orientation)
        guard surface.dimensions == orientedDimensions else {
            throw .orientedGeometryMismatch(
                expected: orientedDimensions,
                produced: surface.dimensions
            )
        }

        try checkCancellation()
        return try resolveAlpha(surface, action: actions.alpha, metadata: metadata)
    }

    // MARK: - Refusing what the contract refuses

    /// Applies each `rejectAsPreprocessingError` action.
    ///
    /// Applying such an action *is* returning `preprocessing-error`: the vocabulary
    /// carries it so a release can refuse a metadata state outright instead of the
    /// implementation guessing at one. All three are checked before any of them acts, so
    /// which field is reported does not depend on the order the transform happens to run
    /// its steps in.
    private func refuseRejectedStates(
        _ actions: BoundMetadataActions,
        metadata: ObservedImageMetadata
    ) throws(PreprocessingFailure) {
        if actions.orientation == .rejectAsPreprocessingError {
            throw .actionRejectsObservedState(
                field: "orientationRules",
                state: metadata.orientation
            )
        }
        if actions.colorProfile == .rejectAsPreprocessingError {
            throw .actionRejectsObservedState(
                field: "colorProfileRules",
                state: metadata.colorProfile
            )
        }
        if case .rejectAsPreprocessingError = actions.alpha {
            throw .actionRejectsObservedState(field: "alphaRules", state: metadata.alpha)
        }
    }

    // MARK: - Orientation

    /// The orientation the bound action actually applies, or `nil` for none.
    ///
    /// `ignoreDeclaredOrientation` leaves stored pixel order untouched, which is `nil`.
    /// `applyDeclaredOrientation` needs a declared orientation to apply, and an absent,
    /// malformed, or unsupported declaration does not provide one: that combination is a
    /// contract asking for something the input does not carry, and it fails closed
    /// rather than quietly becoming the identity transform.
    private func appliedOrientation(
        _ action: OrientationAction,
        metadata: ObservedImageMetadata
    ) throws(PreprocessingFailure) -> ExifOrientation? {
        switch action {
        case .ignoreDeclaredOrientation:
            return nil
        case .applyDeclaredOrientation:
            guard let declared = metadata.declaredOrientation else {
                throw .declaredOrientationUnavailable(state: metadata.orientation)
            }
            return declared
        case .rejectAsPreprocessingError:
            // Already refused by `refuseRejectedStates`. Repeated rather than assumed,
            // because the alternative to an error here is proceeding with an input the
            // contract refused.
            throw .actionRejectsObservedState(
                field: "orientationRules",
                state: metadata.orientation
            )
        }
    }

    /// The dimensions `orientation` produces from `source`.
    ///
    /// Derived from ``ExifOrientation/exchangesAxes`` rather than from the step list, so
    /// the buffer size and the permutation are two independent statements about the same
    /// geometry and a disagreement between them is detectable
    /// (``PreprocessingFailure/orientedGeometryMismatch(expected:produced:)``).
    static func orientedDimensions(
        _ source: PixelDimensions,
        applying orientation: ExifOrientation?
    ) -> PixelDimensions {
        guard let orientation, orientation.exchangesAxes else { return source }
        // Safe: both edges of a `PixelDimensions` are positive, and exchanging them
        // preserves that.
        return PixelDimensions(width: source.height, height: source.width)!
    }

    /// Applies `orientation` as a sequence of Accelerate pixel permutations.
    ///
    /// Each step allocates its own tightly packed destination and the previous surface
    /// is released as soon as the next one replaces it, which is what keeps the peak to
    /// the two concurrent working buffers the budget check bounds.
    private func orient(
        _ surface: PixelSurface,
        by orientation: ExifOrientation?
    ) throws(PreprocessingFailure) -> PixelSurface {
        guard let orientation else { return surface }
        var current = surface
        for step in orientation.steps {
            current = try Self.permute(current, by: step)
        }
        return current
    }

    /// One permutation step.
    static func permute(
        _ source: PixelSurface,
        by step: PixelPermutationStep
    ) throws(PreprocessingFailure) -> PixelSurface {
        // The vImage permutations used below are the four-channel 8-bit ones, and the
        // background pointer they take is four bytes wide. Running them over a
        // three-channel surface would read past that pointer and index rows at the wrong
        // stride, so the channel count is a precondition the transform states rather than
        // one the call site is trusted to maintain.
        guard source.channelCount == Self.workingChannelCount else {
            throw .bufferUnavailable(
                width: source.width,
                height: source.height,
                channelCount: source.channelCount
            )
        }
        let width = step.exchangesAxes ? source.height : source.width
        let height = step.exchangesAxes ? source.width : source.height
        let destination = try PixelSurface.tightlyPacked(
            width: width,
            height: height,
            channelCount: source.channelCount
        )
        var input = source.buffer
        var output = destination.buffer

        // Only read by vImage for rotations that are not exact quarter turns, which this
        // table never produces. Stated explicitly so it is clear that no background
        // color is being invented: none of these operations samples outside the source.
        var unsampledBackground = [UInt8](repeating: 0, count: Self.workingChannelCount)

        let status: vImage_Error
        let operation: String
        switch step {
        case .rotateCounterclockwise(let quarterTurns):
            guard (1...3).contains(quarterTurns) else {
                throw .frameworkOperationFailed(
                    operation: "vImageRotate90_ARGB8888",
                    code: kvImageInvalidParameter
                )
            }
            operation = "vImageRotate90_ARGB8888"
            status = vImageRotate90_ARGB8888(
                &input,
                &output,
                UInt8(quarterTurns),
                &unsampledBackground,
                vImage_Flags(kvImageNoFlags)
            )
        case .reflectHorizontally:
            operation = "vImageHorizontalReflect_ARGB8888"
            status = vImageHorizontalReflect_ARGB8888(
                &input,
                &output,
                vImage_Flags(kvImageNoFlags)
            )
        case .reflectVertically:
            operation = "vImageVerticalReflect_ARGB8888"
            status = vImageVerticalReflect_ARGB8888(
                &input,
                &output,
                vImage_Flags(kvImageNoFlags)
            )
        }
        guard status == kvImageNoError else {
            throw .frameworkOperationFailed(operation: operation, code: status)
        }
        return destination
    }

    // MARK: - RGB and color space

    /// Produces unpremultiplied 8-bit RGBA in the contract's working color space.
    ///
    /// One `vImageBuffer_InitWithCGImage` call performs the whole of Requirement 4.3's
    /// "decode as three-channel RGB according to the contract": ColorSync supplies the
    /// color transform, vImage supplies the layout and bit-depth conversion, and the
    /// destination format states both ends explicitly. There is no drawing into a bitmap
    /// context, because a context's initial contents and blend behavior would silently
    /// composite transparency before the contract's alpha rule had been consulted.
    ///
    /// The destination alpha is unpremultiplied (`.last`). That matters for
    /// ``AlphaAction/discardAlphaChannel``, which keeps the color channels *unchanged*: a
    /// premultiplied destination would have already multiplied every channel by its
    /// alpha, so discarding alpha afterwards would darken every partially transparent
    /// pixel and there would be nothing left to recover the original samples from. vImage
    /// unpremultiplies a premultiplied source as part of this conversion, so both kinds
    /// of source arrive in the same known state.
    ///
    /// The two profile actions differ in exactly one field — the color space the
    /// destination format declares:
    ///
    ///   * ``ColorProfileAction/convertToWorkingSpace`` declares the contract's space, so
    ///     ColorSync builds a transform from the image's own profile into it.
    ///   * ``ColorProfileAction/assignWorkingSpaceWithoutConversion`` declares the
    ///     *source's* space, which makes the color transform the identity, and the
    ///     resulting samples are then relabelled as working-space samples. That is the
    ///     literal meaning of the action: reinterpret, do not convert.
    ///
    /// Assignment additionally requires the source's colorimetry to be three-channel
    /// RGB, because relabelling one grayscale channel or four CMYK channels as three RGB
    /// channels is not a reinterpretation, it is a conversion with the label removed.
    private func materializeWorkingSpaceRGBA(
        _ image: CGImage,
        workingSpace: WorkingColorSpace,
        action: ColorProfileAction,
        observedState: ImageMetadataState
    ) throws(PreprocessingFailure) -> PixelSurface {
        let declaredSpace = try formatColorSpace(
            for: action,
            image: image,
            workingSpace: workingSpace,
            observedState: observedState
        )
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: UInt32(8 * Self.workingChannelCount),
            colorSpace: Unmanaged.passUnretained(declaredSpace),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )
        var buffer = vImage_Buffer()
        // `format` holds an unmanaged reference to `declaredSpace`; the extended lifetime
        // is what makes that reference valid for the duration of the call rather than
        // until the optimizer decides the local is dead.
        let status = withExtendedLifetime(declaredSpace) {
            vImageBuffer_InitWithCGImage(
                &buffer,
                &format,
                nil,
                image,
                vImage_Flags(kvImageNoFlags)
            )
        }
        guard status == kvImageNoError else {
            // Covers a source Image I/O produced but ColorSync cannot convert from: an
            // untagged image under a converting contract, a component count the format
            // cannot express, an unreachable profile. None of them is retried with a
            // different format.
            throw .frameworkOperationFailed(
                operation: "vImageBuffer_InitWithCGImage",
                code: status
            )
        }
        return try PixelSurface.adopting(buffer, channelCount: Self.workingChannelCount)
    }

    /// The color space the destination format declares, which is the whole difference
    /// between converting and assigning.
    private func formatColorSpace(
        for action: ColorProfileAction,
        image: CGImage,
        workingSpace: WorkingColorSpace,
        observedState: ImageMetadataState
    ) throws(PreprocessingFailure) -> CGColorSpace {
        switch action {
        case .convertToWorkingSpace:
            return workingSpace.colorSpace
        case .assignWorkingSpaceWithoutConversion:
            guard let sourceSpace = image.colorSpace else {
                // No source colorimetry at all. There is nothing to convert from, so
                // declaring the working space *is* the assignment rather than a
                // substitute for one.
                return workingSpace.colorSpace
            }
            guard sourceSpace.model == .rgb else {
                throw .sourceSamplesNotAssignable(
                    reason: "source color space model \(sourceSpace.model.rawValue) is not RGB"
                )
            }
            guard sourceSpace.numberOfComponents == WorkingColorSpace.requiredComponentCount
            else {
                throw .sourceSamplesNotAssignable(
                    reason: """
                        source color space has \(sourceSpace.numberOfComponents) \
                        components, not \(WorkingColorSpace.requiredComponentCount)
                        """
                )
            }
            return sourceSpace
        case .rejectAsPreprocessingError:
            // Already refused by `refuseRejectedStates`; repeated rather than assumed.
            throw .actionRejectsObservedState(
                field: "colorProfileRules",
                state: observedState
            )
        }
    }

    // MARK: - Alpha

    /// Applies the bound alpha action and reduces the buffer to three channels.
    ///
    /// Both non-refusing actions run over the same unpremultiplied RGBA buffer, and both
    /// end at Requirement 4.3's three-channel RGB.
    ///
    /// When the decode carried no alpha channel the materialization step filled alpha
    /// with 255, so compositing over any background and discarding the channel produce
    /// provably identical results. Requirement 3.10 conditions the compositing behavior
    /// on transparency being present; expressing that as "the same code path over an
    /// opaque alpha channel" rather than as a skipped branch is what makes the two agree
    /// by construction instead of by inspection.
    private func resolveAlpha(
        _ surface: PixelSurface,
        action: AlphaAction,
        metadata: ObservedImageMetadata
    ) throws(PreprocessingFailure) -> PixelSurface {
        switch action {
        case .discardAlphaChannel:
            return try Self.dropAlphaChannel(surface)
        case .compositeOverOpaqueBackground(let background):
            return try Self.dropAlphaChannel(
                Self.composite(surface, over: background)
            )
        case .rejectAsPreprocessingError:
            // Already refused by `refuseRejectedStates`; repeated rather than assumed.
            throw .actionRejectsObservedState(field: "alphaRules", state: metadata.alpha)
        }
    }

    /// Composites unpremultiplied RGBA over one opaque background color.
    ///
    /// `vImageFlatten_RGBA8888` performs `channel * alpha + background * (1 - alpha)` in
    /// integer arithmetic, and it is told the source is not premultiplied because the
    /// materialization step guaranteed that. The background's alpha is 255: the contract
    /// calls it an *opaque* background, so a transparent one is not representable and
    /// cannot be smuggled in through the color value.
    static func composite(
        _ surface: PixelSurface,
        over background: OpaqueBackgroundColor
    ) throws(PreprocessingFailure) -> PixelSurface {
        let destination = try PixelSurface.tightlyPacked(
            width: surface.width,
            height: surface.height,
            channelCount: surface.channelCount
        )
        var input = surface.buffer
        var output = destination.buffer
        var color: [UInt8] = [background.red, background.green, background.blue, 255]
        let status = vImageFlatten_RGBA8888(
            &input,
            &output,
            &color,
            false,
            vImage_Flags(kvImageNoFlags)
        )
        guard status == kvImageNoError else {
            throw .frameworkOperationFailed(
                operation: "vImageFlatten_RGBA8888",
                code: status
            )
        }
        return destination
    }

    /// Drops the alpha byte, leaving the three color channels exactly as they were.
    ///
    /// The result is tightly packed, which is what makes it readable as one contiguous
    /// three-bytes-per-pixel sequence: vImage pads the rows of buffers it allocates
    /// itself, and a padded buffer read as if it were packed would shear the image by a
    /// few pixels per row — a corruption that survives resizing and looks like a
    /// plausible photograph.
    static func dropAlphaChannel(
        _ surface: PixelSurface
    ) throws(PreprocessingFailure) -> PixelSurface {
        let destination = try PixelSurface.tightlyPacked(
            width: surface.width,
            height: surface.height,
            channelCount: renderedChannelCount
        )
        var input = surface.buffer
        var output = destination.buffer
        let status = vImageConvert_RGBA8888toRGB888(
            &input,
            &output,
            vImage_Flags(kvImageNoFlags)
        )
        guard status == kvImageNoError else {
            throw .frameworkOperationFailed(
                operation: "vImageConvert_RGBA8888toRGB888",
                code: status
            )
        }
        return destination
    }

    // MARK: - Resource bounding

    /// Bounds every allocation the transform will make, before it makes any of them.
    ///
    /// The bound is the peak, not the total: at most two working RGBA buffers and one
    /// rendered RGB buffer are alive at once, because each step releases its input as
    /// soon as its output replaces it. The decoded image is included because it stays
    /// alive throughout — it is the transform's source — and a check that ignored it
    /// would under-count the very moment the budget exists to bound.
    ///
    /// Row padding is rounded up in the estimate. Requirement 3.4's ordering is the
    /// reason: a breach has to be detectable before the memory is taken, so the estimate
    /// must never be lower than the allocation it precedes.
    private func boundAllocations(
        decodedByteCount: UInt64,
        source: PixelDimensions,
        oriented: PixelDimensions
    ) throws(PreprocessingFailure) {
        let checks = ValidationResourceChecks(budget: budget)
        guard
            let sourceWorking = PixelSurface.estimatedAllocationByteCount(
                width: source.width,
                height: source.height,
                channelCount: Self.workingChannelCount
            ),
            let orientedWorking = PixelSurface.estimatedAllocationByteCount(
                width: oriented.width,
                height: oriented.height,
                channelCount: Self.workingChannelCount
            ),
            let rendered = PixelSurface.estimatedAllocationByteCount(
                width: oriented.width,
                height: oriented.height,
                channelCount: Self.renderedChannelCount
            ),
            let peak = Self.sum([decodedByteCount, sourceWorking, orientedWorking, rendered])
        else {
            // A cost that cannot be represented cannot be shown to fit any limit. That
            // is a fail-closed refusal, not an unbounded allowance.
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

    /// Fails closed on a cancelled session.
    ///
    /// Checked at every stage boundary. Neither vImage nor ColorSync is interruptible
    /// once entered, so the guarantee is that no cancelled session produces a rendered
    /// surface, not that an in-flight framework call stops early.
    private func checkCancellation() throws(PreprocessingFailure) {
        if Task.isCancelled {
            throw .cancelled
        }
    }
}
