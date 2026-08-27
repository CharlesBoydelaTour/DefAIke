import DefAIkeDomain

// The bilinear resample, written out rather than delegated.
//
// Every other pixel operation in this module is an Accelerate call, because vImage
// states exactly what it does: a quarter turn is a quarter turn, `vImageFlatten_RGBA8888`
// is documented as `channel * alpha + background * (1 - alpha)`, and
// `vImageConvert_RGBA8888toRGB888` drops one byte. Resampling is the one step where that
// stops being true. vImage's geometry functions do not expose a pixel-center convention
// and do not expose a boundary rule, and the contract carries both — precisely because
// they are the choices that "silently change resampled output between frameworks"
// (``PixelCenterConvention``). A framework call whose convention is not stated cannot be
// shown to apply the bound one, so using it would be an approximation dressed as an exact
// contract, and Requirement 3.11 admits no approximation.
//
// So the sampler is explicit, and it is exact integer arithmetic end to end:
//
//   * The source coordinate for each destination index is an exact rational
//     (``SampleCoordinate``), not a `Double`. A `Double` scale factor accumulates a
//     different error per index and makes the output depend on the order the
//     multiplications were emitted in.
//   * The four taps are combined over a common integer denominator, so there is exactly
//     one rounding in the whole operation: the final quantization back to 8 bits.
//   * Indices outside the source are folded by the contract's edge rule before any
//     memory is read, so no out-of-bounds access exists to be prevented by a clamp that
//     happened to also change a pixel.
//
// ## The one value that is not in the contract
//
// Quantizing the interpolated value back to 8 bits needs a rule, and the contract schema
// does not carry one. This sampler rounds to nearest and sends an exact half away from
// zero, which is the ordinary integer-bilinear convention; every sample is non-negative,
// so "away from zero" is "up". It is at most one least-significant bit from any other
// nearest-rounding choice, and the design compares samples against the reference
// implementation "under numeric tolerances declared before testing" rather than
// byte-exactly, which is the regime a one-bit quantization choice belongs to. It is
// nonetheless an unbound value: if release parity measurement shows it matters, it belongs
// in the contract, not in this comment.
//
// ## Why the crop is fused into the resample
//
// The design lists the resize (step 4) and the center crop (step 5) separately, and this
// file performs them as one pass over the crop's destination window. The output is
// byte-identical, and the reason is structural rather than empirical: a destination
// sample's value is a function of its own destination coordinate and the source alone —
// no destination sample reads another — so producing a subset of the destination samples
// produces exactly those samples. The crop is a subset of destination coordinates, and
// the mapping is driven by the *full* resized extent (``ResizeGeometry/resized``) rather
// than by the window's own size, which is what keeps the coordinates identical to the
// ones a full resize would use.
//
// What fusing buys is not speed. An extreme-aspect source resizes to a 440-by-N image,
// and N grows without bound as the aspect ratio does: a 10000-by-100 source resizes to
// 44000 by 440, whose intermediate buffer is 58 MB of pixels of which 384 columns are
// ever read. Allocating it would put a 58 MB peak between the two steps for no observable
// difference, and the Resource Budget would be entitled to refuse the analysis over it.

/// Samples a rendered surface into the bound contract's resized-and-cropped geometry.
enum BilinearResampler {
    /// One destination index's two source taps along one axis.
    ///
    /// Both indices are already folded into `0..<extent` by the contract's edge rule, so
    /// the inner loop reads memory without a bounds decision and without a branch that
    /// could differ between the two axes.
    struct AxisTap: Hashable, Sendable {
        let lowerIndex: Int
        let upperIndex: Int

        /// Weight of ``upperIndex``, over the axis denominator. In `0..<denominator`.
        let upperWeight: Int
    }

    /// Every destination index's taps along one axis, over one shared denominator.
    struct AxisPlan: Hashable, Sendable {
        let taps: [AxisTap]
        let denominator: Int
    }

    /// The full resize of `source` to `resized`.
    ///
    /// The same operation as ``sample(_:resized:window:convention:edgeRule:)`` over the
    /// whole destination, so it is not a second implementation: it exists because the
    /// resized image is a stated intermediate of the design's step list, and being able to
    /// materialize it is what makes the fused crop checkable against it rather than
    /// asserted to be equal.
    static func resize(
        _ source: PixelSurface,
        to resized: PixelDimensions,
        convention: PixelCenterConvention,
        edgeRule: SampleEdgeRule
    ) throws(PreprocessingFailure) -> PixelSurface {
        try sample(
            source,
            resized: resized,
            window: CropRectangle(x: 0, y: 0, size: resized),
            convention: convention,
            edgeRule: edgeRule
        )
    }

    /// The `window` sub-rectangle of the resize of `source` to `resized`.
    ///
    /// The result is tightly packed, `window.size`-shaped, and carries `source`'s channel
    /// count: the resample is per channel and channel-agnostic, so the same code produces
    /// the three-channel RGB the contract's model input requires and can be exercised on
    /// other channel counts without a separate path.
    static func sample(
        _ source: PixelSurface,
        resized: PixelDimensions,
        window: CropRectangle,
        convention: PixelCenterConvention,
        edgeRule: SampleEdgeRule
    ) throws(PreprocessingFailure) -> PixelSurface {
        guard window.isContained(in: resized) else {
            throw .cropNotWithinResizedImage(crop: window.size, resized: resized)
        }
        let horizontal = try axisPlan(
            destinationIndices: window.x..<window.maxX,
            sourceExtent: source.width,
            destinationExtent: resized.width,
            convention: convention,
            edgeRule: edgeRule
        )
        let vertical = try axisPlan(
            destinationIndices: window.y..<window.maxY,
            sourceExtent: source.height,
            destinationExtent: resized.height,
            convention: convention,
            edgeRule: edgeRule
        )
        // Proved before a single tap is combined: the largest intermediate the inner loop
        // forms is `511 * horizontal.denominator * vertical.denominator`, and a product
        // that does not fit is refused rather than wrapped. A wrapped intermediate would
        // produce a sample in range and completely wrong, which nothing downstream can
        // detect.
        guard combinedWeightBoundIsRepresentable(horizontal, vertical) else {
            throw .sampleCoordinateNotRepresentable(
                sourceExtent: source.width,
                destinationExtent: resized.width
            )
        }
        let destination = try PixelSurface.tightlyPacked(
            width: window.size.width,
            height: window.size.height,
            channelCount: source.channelCount
        )
        guard let sourceBase = source.buffer.data?.assumingMemoryBound(to: UInt8.self),
              let destinationBase = destination.buffer.data?.assumingMemoryBound(to: UInt8.self)
        else {
            // Unreachable: a surface owns its allocation. A fail-closed branch rather
            // than a force-unwrap, because the alternative to an error is a crash.
            throw .bufferUnavailable(
                width: window.size.width,
                height: window.size.height,
                channelCount: source.channelCount
            )
        }
        combine(
            sourceBase: sourceBase,
            sourceRowBytes: source.rowBytes,
            destinationBase: destinationBase,
            destinationRowBytes: destination.rowBytes,
            channelCount: source.channelCount,
            horizontal: horizontal,
            vertical: vertical
        )
        return destination
    }

    // MARK: - Planning

    /// The taps for every destination index in `destinationIndices`.
    ///
    /// The coordinate is computed from the *full* `destinationExtent`, so a window's taps
    /// are the same taps the corresponding columns of a full resize would use. The
    /// denominator is a property of the axis rather than of the index, and it is checked
    /// against every index rather than taken from the first: a per-index denominator would
    /// mean the weights of two neighbouring destination samples were on different scales.
    static func axisPlan(
        destinationIndices: Range<Int>,
        sourceExtent: Int,
        destinationExtent: Int,
        convention: PixelCenterConvention,
        edgeRule: SampleEdgeRule
    ) throws(PreprocessingFailure) -> AxisPlan {
        let notRepresentable = PreprocessingFailure.sampleCoordinateNotRepresentable(
            sourceExtent: sourceExtent,
            destinationExtent: destinationExtent
        )
        guard sourceExtent > 0, !destinationIndices.isEmpty else { throw notRepresentable }
        // Discharges ``SampleMapping/foldedIndex(_:extent:rule:)``'s precondition here,
        // where it can be a refusal, rather than inside the folding loop where it could
        // only be a trap.
        guard sourceExtent <= Int.max / 2 else { throw notRepresentable }
        var taps: [AxisTap] = []
        taps.reserveCapacity(destinationIndices.count)
        var denominator: Int?
        for index in destinationIndices {
            let coordinate = try SampleMapping.coordinate(
                forDestinationIndex: index,
                sourceExtent: sourceExtent,
                destinationExtent: destinationExtent,
                convention: convention
            )
            if let denominator, denominator != coordinate.denominator {
                throw notRepresentable
            }
            denominator = coordinate.denominator
            // Both taps go through the contract's edge rule, including the lower one: a
            // half-pixel-centered upscale puts the first destination sample's lower tap at
            // `-1` and the last destination sample's upper tap at the source extent.
            let (rawUpperIndex, overflow) = coordinate.lowerIndex.addingReportingOverflow(1)
            guard !overflow else { throw notRepresentable }
            taps.append(
                AxisTap(
                    lowerIndex: SampleMapping.foldedIndex(
                        coordinate.lowerIndex,
                        extent: sourceExtent,
                        rule: edgeRule
                    ),
                    upperIndex: SampleMapping.foldedIndex(
                        rawUpperIndex,
                        extent: sourceExtent,
                        rule: edgeRule
                    ),
                    upperWeight: coordinate.upperWeight
                )
            )
        }
        guard let denominator, denominator > 0 else { throw notRepresentable }
        return AxisPlan(taps: taps, denominator: denominator)
    }

    /// Whether the inner loop's largest intermediate fits in an `Int`.
    ///
    /// The intermediate is `2 * value + denominatorProduct` where `value` is at most
    /// `255 * denominatorProduct`, so the bound is `511 * denominatorProduct`.
    static func combinedWeightBoundIsRepresentable(
        _ horizontal: AxisPlan,
        _ vertical: AxisPlan
    ) -> Bool {
        let (product, productOverflow) = horizontal.denominator.multipliedReportingOverflow(
            by: vertical.denominator
        )
        guard !productOverflow else { return false }
        let (_, boundOverflow) = product.multipliedReportingOverflow(by: 511)
        return !boundOverflow
    }

    // MARK: - Combining

    /// Writes every destination sample from its four source taps.
    ///
    /// One rounding, at the end, per channel:
    ///
    /// ```text
    /// top    = (Dx - wx) * p00 + wx * p10
    /// bottom = (Dx - wx) * p01 + wx * p11
    /// value  = (Dy - wy) * top + wy * bottom          // scale Dx * Dy
    /// sample = (2 * value + Dx * Dy) / (2 * Dx * Dy)   // nearest, halves away from zero
    /// ```
    ///
    /// `value` is a non-negative integer no larger than `255 * Dx * Dy`, so the quotient
    /// lands in `0...255` by construction and there is no clamp deciding anything.
    private static func combine(
        sourceBase: UnsafePointer<UInt8>,
        sourceRowBytes: Int,
        destinationBase: UnsafeMutablePointer<UInt8>,
        destinationRowBytes: Int,
        channelCount: Int,
        horizontal: AxisPlan,
        vertical: AxisPlan
    ) {
        let horizontalDenominator = horizontal.denominator
        let verticalDenominator = vertical.denominator
        let scale = horizontalDenominator * verticalDenominator
        let doubledScale = 2 * scale
        for (row, verticalTap) in vertical.taps.enumerated() {
            let upperRowWeight = verticalTap.upperWeight
            let lowerRowWeight = verticalDenominator - upperRowWeight
            let lowerRow = sourceBase + verticalTap.lowerIndex * sourceRowBytes
            let upperRow = sourceBase + verticalTap.upperIndex * sourceRowBytes
            let destinationRow = destinationBase + row * destinationRowBytes
            for (column, horizontalTap) in horizontal.taps.enumerated() {
                let upperColumnWeight = horizontalTap.upperWeight
                let lowerColumnWeight = horizontalDenominator - upperColumnWeight
                let lowerColumn = horizontalTap.lowerIndex * channelCount
                let upperColumn = horizontalTap.upperIndex * channelCount
                let destinationOffset = column * channelCount
                for channel in 0..<channelCount {
                    let topLeft = Int(lowerRow[lowerColumn + channel])
                    let topRight = Int(lowerRow[upperColumn + channel])
                    let bottomLeft = Int(upperRow[lowerColumn + channel])
                    let bottomRight = Int(upperRow[upperColumn + channel])
                    let top = lowerColumnWeight * topLeft + upperColumnWeight * topRight
                    let bottom = lowerColumnWeight * bottomLeft + upperColumnWeight * bottomRight
                    let value = lowerRowWeight * top + upperRowWeight * bottom
                    destinationRow[destinationOffset + channel] = UInt8(
                        (2 * value + scale) / doubledScale
                    )
                }
            }
        }
    }
}
