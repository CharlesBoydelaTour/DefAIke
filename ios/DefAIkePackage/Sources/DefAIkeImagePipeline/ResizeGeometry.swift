import DefAIkeDomain

// The integer geometry of the resize and the center crop.
//
// Steps 4 and 5 of the design's preprocessing list, with every number taken from the
// bound Preprocessing Contract: the short-edge target, the rounding rule that turns the
// exact long edge into an integer, the pixel-center convention that maps a destination
// index to a source coordinate, the edge rule that resolves a coordinate outside the
// source, and the offset rule that resolves an odd leftover pixel in the crop. Not one
// of them is written as a literal here.
//
// Why the geometry is a separate, framework-free, integer-only type:
//
//   * Every value is exact. A short edge of "exactly 440" and a crop of "exactly
//     384 by 384" are the requirement (Requirements 4.4 and 4.5), and a floating-point
//     scale factor cannot deliver either: `440.0 / 3.0 * 3.0` is not 440, and one
//     rounding of `long * 440 / short` in `Double` disagrees with the exact rational
//     answer for source dimensions that occur in ordinary photographs. So the long edge
//     is derived from `long * target` and `short` as an integer quotient and remainder,
//     and the contract's rounding rule is applied to that remainder.
//   * Every value is testable without pixels. The resampler is the only part that needs
//     a buffer; the geometry is a pure function of two positive integers and four
//     contract fields.
//
// Nothing here is approximated and nothing is clamped. A source whose scaled long edge
// cannot be computed without overflow, or whose resized short edge does not come out
// exactly at the contract's target, or whose resized image cannot contain the contract's
// crop, is a contract this build cannot apply exactly — which is `preprocessing-error`
// (Requirement 3.11), not a nearby geometry.

/// One rectangle in resized-image coordinates.
///
/// Origin is the top-left sample, and ``maxX`` and ``maxY`` are exclusive. Both edges of
/// ``size`` are positive because ``PixelDimensions`` guarantees it, so an empty rectangle
/// is unrepresentable.
struct CropRectangle: Hashable, Sendable {
    let x: Int
    let y: Int
    let size: PixelDimensions

    /// One past the last column this rectangle covers.
    var maxX: Int { x + size.width }

    /// One past the last row this rectangle covers.
    var maxY: Int { y + size.height }

    /// Whether this rectangle lies wholly inside `bounds`.
    func isContained(in bounds: PixelDimensions) -> Bool {
        x >= 0 && y >= 0 && maxX <= bounds.width && maxY <= bounds.height
    }
}

/// The resized dimensions and the crop rectangle the bound contract produces.
struct ResizeGeometry: Hashable, Sendable {
    /// Dimensions the resize reads from: the rendered, oriented image.
    let source: PixelDimensions

    /// Dimensions the resize produces. Its short edge is exactly the contract's target.
    let resized: PixelDimensions

    /// The center crop, in resized-image coordinates. Exactly the contract's crop size.
    let crop: CropRectangle

    /// Resolves the geometry, or throws when the bound contract cannot be applied
    /// exactly.
    ///
    /// The short edge is set to the contract's target and the long edge is derived from
    /// it, rather than both being derived from a single scale factor. That is what makes
    /// "the short edge equals 440" exact instead of "within a pixel of 440": the target
    /// is assigned, not computed, so no rounding can move it.
    ///
    /// Which axis is the short one is decided by the source, and a square source takes
    /// the `width <= height` branch. That branch choice is not observable for a square
    /// source: `long == short` makes the scaled long edge exactly the target under every
    /// rounding rule, so both axes come out at the target either way.
    static func resolve(
        source: PixelDimensions,
        resize: ResizeContract,
        crop: CenterCropContract
    ) throws(PreprocessingFailure) -> ResizeGeometry {
        let target = resize.targetShortEdge
        guard target > 0 else {
            throw .resizeGeometryNotRepresentable(source: source, targetShortEdge: target)
        }
        let scaledLongEdge = try scaledLongEdge(
            long: source.longEdge,
            short: source.shortEdge,
            target: target,
            rounding: resize.rounding,
            source: source
        )
        let resizedWidth = source.width <= source.height ? target : scaledLongEdge
        let resizedHeight = source.width <= source.height ? scaledLongEdge : target
        guard let resized = PixelDimensions(width: resizedWidth, height: resizedHeight) else {
            throw .resizeGeometryNotRepresentable(source: source, targetShortEdge: target)
        }
        // Requirement 4.4 says the short edge *equals* the target. The assignment above
        // is one statement of that and this check is a second, independent one; they can
        // only disagree if the rounded long edge came out below the target, which would
        // mean an aspect ratio was inverted somewhere and the crop would then be taken
        // from an image narrower than the crop itself.
        guard resized.shortEdge == target else {
            throw .resizedShortEdgeMismatch(expected: target, produced: resized.shortEdge)
        }
        return ResizeGeometry(
            source: source,
            resized: resized,
            crop: try centeredCrop(in: resized, crop: crop)
        )
    }

    /// The long edge after scaling, under the contract's rounding rule.
    ///
    /// The exact value is `long * target / short`, and it is computed as an integer
    /// quotient with its remainder so the rounding rule is applied to the exact
    /// remainder rather than to a floating-point approximation of it. Every quantity is
    /// positive, so "up" and "away from zero" coincide and the half rules need no sign
    /// handling.
    ///
    /// An overflowing product is refused rather than wrapped: a wrapped product would
    /// produce a small, plausible, and completely wrong target size.
    static func scaledLongEdge(
        long: Int,
        short: Int,
        target: Int,
        rounding: RoundingRule,
        source: PixelDimensions
    ) throws(PreprocessingFailure) -> Int {
        let notRepresentable = PreprocessingFailure.resizeGeometryNotRepresentable(
            source: source,
            targetShortEdge: target
        )
        guard short > 0, long > 0 else { throw notRepresentable }
        let (product, overflow) = long.multipliedReportingOverflow(by: target)
        guard !overflow else { throw notRepresentable }
        let quotient = product / short
        let remainder = product % short
        let roundsUp: Bool
        switch rounding {
        case .floor:
            roundsUp = false
        case .ceiling:
            roundsUp = remainder != 0
        case .halfUp:
            // A tie goes up: `2 * remainder == short` is exactly halfway.
            roundsUp = try doubled(remainder, or: notRepresentable) >= short
        case .halfDown:
            roundsUp = try doubled(remainder, or: notRepresentable) > short
        case .halfToEven:
            let doubledRemainder = try doubled(remainder, or: notRepresentable)
            if doubledRemainder == short {
                roundsUp = !quotient.isMultiple(of: 2)
            } else {
                roundsUp = doubledRemainder > short
            }
        }
        guard roundsUp else { return quotient }
        let (rounded, roundedOverflow) = quotient.addingReportingOverflow(1)
        guard !roundedOverflow else { throw notRepresentable }
        return rounded
    }

    /// `2 * value`, or throws when it does not fit.
    private static func doubled(
        _ value: Int,
        or failure: PreprocessingFailure
    ) throws(PreprocessingFailure) -> Int {
        let (doubled, overflow) = value.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw failure }
        return doubled
    }

    /// The crop rectangle the contract's offset rule places inside `resized`.
    ///
    /// The offset rule exists for one case: an odd difference between the resized edge
    /// and the crop edge, where "centered" names two different rectangles one pixel
    /// apart. Which one a release wants is a contract field, so both are implemented and
    /// neither is chosen here.
    ///
    /// A crop larger than the resized image is refused. With the target short edge at
    /// 440 and the crop at 384 the difference is always non-negative, so this is a
    /// structural check rather than an expected outcome — but the two values arrive from
    /// separate contract fields, and a contract that made them disagree would otherwise
    /// have its crop silently clipped.
    static func centeredCrop(
        in resized: PixelDimensions,
        crop: CenterCropContract
    ) throws(PreprocessingFailure) -> CropRectangle {
        guard let size = PixelDimensions(width: crop.width, height: crop.height) else {
            throw .contractGeometryNotApplicable(
                reason: "the bound crop is \(crop.width)x\(crop.height), which is not a positive size"
            )
        }
        guard size.width <= resized.width, size.height <= resized.height else {
            throw .cropNotWithinResizedImage(crop: size, resized: resized)
        }
        let rectangle = CropRectangle(
            x: centeredOffset(extent: resized.width, crop: size.width, rule: crop.offsetRule),
            y: centeredOffset(extent: resized.height, crop: size.height, rule: crop.offsetRule),
            size: size
        )
        // Independent of the offset arithmetic above, for the same reason the short-edge
        // check is independent of the assignment that produces it.
        guard rectangle.isContained(in: resized) else {
            throw .cropNotWithinResizedImage(crop: size, resized: resized)
        }
        return rectangle
    }

    /// The centered offset of a `crop`-long span inside an `extent`-long one.
    ///
    /// `extent >= crop`, so the difference is non-negative and both rules produce an
    /// offset in `0...difference`: flooring cannot go below zero and ceiling cannot push
    /// the span past the end, because `ceil(d / 2) <= d` for every `d >= 0`.
    static func centeredOffset(extent: Int, crop: Int, rule: CropOffsetRule) -> Int {
        let difference = extent - crop
        switch rule {
        case .floorHalfDifference:
            return difference / 2
        case .ceilingHalfDifference:
            return difference - difference / 2
        }
    }
}

// MARK: - Sample coordinates

/// Where one destination index reads from, as an exact rational coordinate.
///
/// The pair `(lowerIndex, upperWeight / denominator)` is the bilinear tap: the source
/// coordinate is `lowerIndex + upperWeight / denominator`, so `upperWeight` is the
/// weight of the sample at `lowerIndex + 1` and `denominator - upperWeight` the weight of
/// the sample at `lowerIndex`. Kept as integers rather than a `Double` so the whole
/// interpolation is exact integer arithmetic with one rounding at the end, instead of a
/// chain of roundings whose result depends on the order the multiplications happened in.
///
/// `lowerIndex` may be `-1` and `lowerIndex + 1` may be the source extent: a
/// half-pixel-centered upscale reads half a pixel outside the source at each end. That is
/// what the contract's edge rule resolves, and it is why the resampler folds indices
/// rather than clamping the coordinate.
struct SampleCoordinate: Hashable, Sendable {
    let lowerIndex: Int
    let upperWeight: Int
    let denominator: Int
}

/// The contract's mapping from destination index to source coordinate, and its edge rule.
///
/// Both are contract fields because both silently change resampled output between
/// frameworks and neither is recoverable from the result. `align_corners`-style
/// disagreement shifts every sample by a fraction of a pixel; an edge-rule disagreement
/// changes only the outermost taps, which is exactly the kind of difference that survives
/// as a plausible image.
enum SampleMapping {
    /// The source coordinate destination index `index` reads from.
    ///
    /// Throws when the exact numerator or denominator does not fit in an `Int`. Both
    /// conventions are stated as one rational rather than evaluated in floating point:
    ///
    ///   * ``PixelCenterConvention/halfPixelCenters`` treats a sample as the center of
    ///     its pixel, so the destination pixel's center maps to
    ///     `(index + 1/2) * source / destination - 1/2`. Written over the common
    ///     denominator `2 * destination`, the numerator is
    ///     `(2 * index + 1) * source - destination`.
    ///   * ``PixelCenterConvention/integerPixelCenters`` aligns the outermost samples of
    ///     the two images, so the mapping is `index * (source - 1) / (destination - 1)`.
    ///     A single-sample destination has no second point to align, so it reads
    ///     coordinate zero; a single-sample source likewise supplies coordinate zero for
    ///     every destination index.
    static func coordinate(
        forDestinationIndex index: Int,
        sourceExtent: Int,
        destinationExtent: Int,
        convention: PixelCenterConvention
    ) throws(PreprocessingFailure) -> SampleCoordinate {
        guard sourceExtent > 0, destinationExtent > 0, index >= 0, index < destinationExtent else {
            throw .sampleCoordinateNotRepresentable(
                sourceExtent: sourceExtent,
                destinationExtent: destinationExtent
            )
        }
        let numerator: Int
        let denominator: Int
        switch convention {
        case .halfPixelCenters:
            guard
                let doubledIndex = product(2, index),
                let offsetIndex = sum(doubledIndex, 1),
                let scaled = product(offsetIndex, sourceExtent),
                let shifted = difference(scaled, destinationExtent),
                let common = product(2, destinationExtent)
            else {
                throw .sampleCoordinateNotRepresentable(
                    sourceExtent: sourceExtent,
                    destinationExtent: destinationExtent
                )
            }
            numerator = shifted
            denominator = common
        case .integerPixelCenters:
            guard destinationExtent > 1 else {
                return SampleCoordinate(lowerIndex: 0, upperWeight: 0, denominator: 1)
            }
            guard let scaled = product(index, sourceExtent - 1) else {
                throw .sampleCoordinateNotRepresentable(
                    sourceExtent: sourceExtent,
                    destinationExtent: destinationExtent
                )
            }
            numerator = scaled
            denominator = destinationExtent - 1
        }
        let (lower, weight) = floorDivide(numerator, by: denominator)
        return SampleCoordinate(lowerIndex: lower, upperWeight: weight, denominator: denominator)
    }

    /// The source index `index` folds to under `rule`, for a source of `extent` samples.
    ///
    /// Total for every `Int` index, and never reads outside `0..<extent`. The three rules
    /// differ only outside the source, and for the one-sample overshoot bilinear
    /// interpolation actually produces, ``SampleEdgeRule/clampToEdge`` and
    /// ``SampleEdgeRule/mirror`` agree — mirroring with the edge sample repeated sends
    /// `-1` to `0`, which is where clamping sends it. ``SampleEdgeRule/reflect`` does not
    /// repeat the edge sample, so it sends `-1` to `1` and is the one rule that reads a
    /// different sample.
    ///
    /// The distinction between the two mirroring rules is the standard one — mirror
    /// repeats the boundary sample, reflect does not — but the contract schema names the
    /// rules without defining their sample semantics, so this is behavior this module
    /// states rather than a value it read.
    ///
    /// - Precondition: `extent > 0`, and `2 * extent` is representable. Both hold for
    ///   every surface this module allocates, because the resampler proves a much
    ///   tighter representability bound before it samples anything.
    static func foldedIndex(_ index: Int, extent: Int, rule: SampleEdgeRule) -> Int {
        precondition(extent > 0, "a source axis has at least one sample")
        if index >= 0 && index < extent { return index }
        switch rule {
        case .clampToEdge:
            return min(max(index, 0), extent - 1)
        case .mirror:
            // Period `2 * extent`: the sequence runs forward then backward with both
            // boundary samples repeated once.
            let period = 2 * extent
            let wrapped = wrap(index, period: period)
            return wrapped < extent ? wrapped : period - 1 - wrapped
        case .reflect:
            // Period `2 * extent - 2`: the boundary samples are not repeated, so a
            // single-sample axis has no period at all and every index is that sample.
            guard extent > 1 else { return 0 }
            let period = 2 * extent - 2
            let wrapped = wrap(index, period: period)
            return wrapped < extent ? wrapped : period - wrapped
        }
    }

    /// `index` reduced into `0..<period`.
    private static func wrap(_ index: Int, period: Int) -> Int {
        let remainder = index % period
        return remainder < 0 ? remainder + period : remainder
    }

    /// Floor division with a positive divisor, and the non-negative remainder.
    ///
    /// Swift's `/` truncates toward zero, which for a negative numerator would return the
    /// index *above* the coordinate and a negative weight. The bilinear tap needs the
    /// index below it and a weight in `0..<denominator`, so the quotient is floored
    /// explicitly.
    static func floorDivide(_ numerator: Int, by denominator: Int) -> (Int, Int) {
        precondition(denominator > 0, "a sample denominator is positive")
        var quotient = numerator / denominator
        if numerator % denominator != 0 && numerator < 0 {
            quotient -= 1
        }
        return (quotient, numerator - quotient * denominator)
    }

    private static func product(_ a: Int, _ b: Int) -> Int? {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? nil : value
    }

    private static func sum(_ a: Int, _ b: Int) -> Int? {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? nil : value
    }

    private static func difference(_ a: Int, _ b: Int) -> Int? {
        let (value, overflow) = a.subtractingReportingOverflow(b)
        return overflow ? nil : value
    }
}
