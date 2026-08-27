import DefAIkeDomain
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeImagePipeline

// Design Property 12: resize and crop geometry follows the bound contract.
//
// The design states it as: for any positive decoded dimensions accepted by the contract,
// aspect-preserving resize produces dimensions whose short edge is exactly 440 under the
// contract's rounding rule, and the subsequent center-crop rectangle is exactly 384×384,
// centered according to the contract, and wholly within the resized image.
//
// The method this task fixes is comparison against a reference integer geometry
// implementation, and ``GeometryReference`` below is that reference. It is written from
// Requirements 4.4 and 4.5 and from what the contract's rule vocabulary *names*, not from
// how ``ResizeGeometry`` computes anything. Three things keep the two independent:
//
//   * The reference performs no integer division and no remainder on the path that
//     produces an answer. The floor of the exact ratio is found by a bounded walk from a
//     floating-point seed and then established by exact multiplication, and the walk's
//     seed cannot decide the result because the defining inequality
//     `n * short <= long * target < (n + 1) * short` is checked exactly and its
//     neighbours are shown to fail it. ``ResizeGeometry`` instead forms a quotient and a
//     remainder with `/` and `%`.
//   * Nearest rounding is stated as a comparison of the two exact distances to the
//     neighbouring integers, with the tie rule applied only when they are equal.
//     ``ResizeGeometry`` instead compares a doubled remainder against the divisor. The two
//     agree only if both are right.
//   * The crop offset is stated as a relation between the two margins — the leading and
//     trailing margins differ by at most one pixel, and the rule fixes which side carries
//     the odd one — and the offset satisfying that relation is searched for and asserted
//     unique. ``ResizeGeometry`` instead evaluates `difference / 2`.
//
// A reference that shared the production formula would agree with it on every input,
// including the inputs where the formula is wrong. These three differences are the reason
// the comparison can fail.
//
// ## What is quantified, in five parts
//
//   * **Against the reference.** Every generated source is resolved under all five
//     rounding rules and both offset rules — ten geometries a case — and the resized
//     dimensions and the whole crop rectangle are compared field by field with the
//     reference's. The requirement's own constants are additionally asserted directly:
//     the short edge equals ``ResizeContract/requiredShortEdge`` and the crop is exactly
//     ``CenterCropContract/requiredEdge`` square and wholly inside the resized image.
//   * **Aspect ratio, as an exact statement.** `resizedWidth * sourceHeight` and
//     `resizedHeight * sourceWidth` differ by less than the source's short edge, which is
//     "the long edge is the exact rational `long * target / short` taken to an integer" in
//     a form no floating-point division enters; under the three nearest rules the bound
//     tightens to half of it. The short-to-long axis assignment is asserted separately, so
//     an implementation that preserved the ratio while exchanging the axes fails.
//   * **Relations between the rules.** Flooring never exceeds any nearest rule, no nearest
//     rule exceeds the ceiling, the ceiling is at most one above the floor, and the two
//     offset rules differ by exactly the parity of the leftover. Those hold whatever the
//     right answer is, so they bite on inputs where the reference and the production code
//     happen to agree.
//   * **Invariance.** The geometry is a function of the source, the target, the rounding
//     rule, and the crop rule alone: resolving the same source under every pixel-center
//     convention and every edge rule gives the identical geometry, and resolving twice
//     gives the identical geometry. Those two are why the sampling contract fields cannot
//     silently move a crop.
//   * **In pixels.** Integers are not the claim on their own — the crop is a rectangle of
//     an actual image. So on every case whose source and resized extent are small enough
//     to materialize, the *fused* crop ``ContractImagePreprocessor`` uses is compared byte
//     for byte against the sub-rectangle of a separately materialized full resize taken at
//     the **reference's** offset, and the same comparison is run one pixel to the side to
//     show it is not translation-invariant. On a further subset the crop is produced as
//     three-channel RGB and handed to ``ModelInputProduction``, so the geometry's crop is
//     shown to be the buffer the bound model input declares.
//
// ## What is real here and what is not
//
// ``ResizeGeometry``, ``BilinearResampler``, and ``ModelInputProduction`` are the real
// implementations from task 5.4, and the pixel arms allocate real buffers and really
// resample them. Nothing is doubled and nothing is reimplemented: the reference computes
// only geometry, and every pixel this file compares was produced by the module under test.
//
// No image is decoded. Requirements 4.4 and 4.5 are claims about two positive integers and
// four contract fields, and Image I/O appears nowhere in them; the surfaces are allocated
// and filled directly, so a generated dimension is the dimension the resampler sees rather
// than one an encoder was free to adjust. Every surface's dimensions are nonetheless read
// back off the surface before they are used in an expectation.
//
// `ResizeGeometryTests` and `BilinearResampleTests` pin the same statement with hand-
// computed examples: named tie cases under each rounding rule, one worked 881×880 offset,
// the overflow and oversized-crop refusals, and one fixed window placement. This file
// quantifies it over generated dimension families, over both orientations, over every
// rounding and offset rule on every case, and over the rounding neighbourhoods that
// separate the rules, and it is the only file here that compares against an independent
// reference rather than against literals.
//
// Scope: which rounding rule, edge rule, pixel-center convention, or offset rule a release
// should bind is decision D10 and is asserted nowhere — what is asserted is that whatever
// the contract names is what runs. The exactness of the pre-orientation record is Property
// 9's, the totality of the metadata state-action map is Property 10's, and the ordering of
// validation and inference is Property 8's. The refusals for an unrepresentable scaled
// edge and for a crop larger than the resized image are outside this property's antecedent
// — it quantifies over dimensions the contract accepts — and are pinned as examples in
// `ResizeGeometryTests`. Real containers, colour profiles, alpha, grayscale, wide gamut,
// and comparison against preapproved tolerances and expected artifacts belong to the
// Release Fixture Suite (task 5.10) and are not attempted here.
//
// **No value in this file is an approved release value.** The rounding rule, edge rule,
// pixel-center convention, and crop offset rule are synthetic arguments that exist so a
// port taking a signed artifact can be called at all; the 440 short edge and the 384 crop
// are the requirement constants and are read from the types that own them rather than
// restated. Nothing here may be copied into a shipping artifact.

extension Tag {
    /// Design Property 12.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property12ResizeAndCropGeometryFollowsTheBoundContract: Self
}

@Suite(
    "Property 12: Resize and crop geometry follows the bound contract",
    .tags(.property12ResizeAndCropGeometryFollowsTheBoundContract)
)
struct ResizeCropGeometryPropertyTests {
    /// Runs 200 generated cases with shrinking, above the design's floor of 100.
    ///
    /// The count is raised rather than left at the library default because of what the
    /// witness asserts about coverage. The rounding rules separate only in a specific
    /// neighbourhood of the exact ratio, and this file requires all six of its rounding
    /// classes — remainder zero, an exact tie, the two remainders adjacent to a tie, and
    /// the two remainders far from one — to have really been presented, plus both quotient
    /// parities at a tie, which is what makes half-to-even distinguishable from half-down.
    /// The narrowest of them — a remainder exactly one unit from a tie, which needs both the
    /// family that constructs it and one parity of a second parameter — is reached by about
    /// one case in eighteen, and at 100 uniform draws over nine families it is missed often
    /// enough that requiring it would fail runs for no reason but the draw.
    ///
    /// Two hundred cases makes the strong statement — every class, both tie parities, and
    /// every family really occurred — sound to assert rather than something to weaken into
    /// a floor, and it keeps the two pixel arms well above their own floors on every run.
    /// The runtime stays under the module's other property tests, which is itself evidence
    /// the body ran: a body whose work was skipped finishes in milliseconds.
    ///
    /// **Validates: Requirements 4.4, 4.5**
    @Test("Resized dimensions and the crop rectangle match an independent integer reference")
    func resizeAndCropGeometryFollowsTheBoundContract() async {
        let witness = GeometryVariationWitness()

        await propertyCheck(count: 200, input: GeometryShape.generator) { shape in
            witness.record(shape)
            let scenario = GeometryScenario(shape: shape, witness: witness)

            // The reference comparison first: it is the claim the task names, and the
            // pixel arms below take their expected crop location from the same reference.
            scenario.checkEveryRuleAgreesWithTheReference()
            scenario.checkRelationsBetweenTheRules()
            scenario.checkTheSamplingRulesCannotMoveTheGeometry()
            scenario.checkTheCropIsTheRectangleTheResampleReads()
            scenario.checkTheCropIsTheBoundModelInputBuffer()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - The independent reference

/// The resize and crop geometry Requirements 4.4 and 4.5 describe.
///
/// Written from the requirement text and from what the contract's rule names mean, and
/// deliberately not from ``ResizeGeometry``. The file header states the three structural
/// differences that make the comparison capable of failing; each one is restated at the
/// function it applies to.
///
/// Everything is `Int` arithmetic over overflow-checked products, and every function
/// returns `nil` rather than trapping when it cannot answer exactly. A `nil` is recorded as
/// an issue by the caller: a reference that quietly declined would make the comparison
/// vacuous, which is the failure mode this whole file is arranged against.
private enum GeometryReference {
    /// One resolved geometry, as plain integers.
    struct Resolved: Hashable {
        let resizedWidth: Int
        let resizedHeight: Int
        let cropX: Int
        let cropY: Int
        let cropEdge: Int
    }

    /// How far the walks may step from their floating-point seed before giving up.
    ///
    /// Every seed in this file is computed from values below `2^53`, so the seed is exact
    /// or one off. The limit exists so a future widening of the generated bounds surfaces
    /// as a recorded issue rather than as a loop.
    private static let walkLimit = 64

    /// The geometry for a source of `sourceWidth` by `sourceHeight`.
    ///
    /// The short edge is *assigned* the target and the long edge is derived from it, which
    /// is Requirement 4.4's own shape: "resize until the short edge equals 440 while
    /// preserving aspect ratio". Which axis receives which is decided by comparing the two
    /// source axes, and the equal case is written out rather than folded into one of the
    /// inequalities — a square source must come out square on both axes, and stating that
    /// separately is what checks the production code's claim that its branch choice is
    /// unobservable there.
    static func resolve(
        sourceWidth: Int,
        sourceHeight: Int,
        targetShortEdge: Int,
        rounding: RoundingRule,
        cropEdge: Int,
        offsetRule: CropOffsetRule
    ) -> Resolved? {
        guard sourceWidth > 0, sourceHeight > 0, targetShortEdge > 0, cropEdge > 0 else {
            return nil
        }
        let shortEdge = sourceWidth < sourceHeight ? sourceWidth : sourceHeight
        let longEdge = sourceWidth > sourceHeight ? sourceWidth : sourceHeight
        guard let exactNumerator = product(longEdge, targetShortEdge),
              let scaledLongEdge = rounded(
                  numerator: exactNumerator,
                  denominator: shortEdge,
                  rule: rounding
              )
        else {
            return nil
        }
        let resizedWidth: Int
        let resizedHeight: Int
        if sourceWidth < sourceHeight {
            resizedWidth = targetShortEdge
            resizedHeight = scaledLongEdge
        } else if sourceWidth > sourceHeight {
            resizedWidth = scaledLongEdge
            resizedHeight = targetShortEdge
        } else {
            resizedWidth = targetShortEdge
            resizedHeight = targetShortEdge
        }
        guard
            let cropX = centeredOffset(
                extent: resizedWidth,
                cropEdge: cropEdge,
                rule: offsetRule
            ),
            let cropY = centeredOffset(
                extent: resizedHeight,
                cropEdge: cropEdge,
                rule: offsetRule
            )
        else {
            return nil
        }
        return Resolved(
            resizedWidth: resizedWidth,
            resizedHeight: resizedHeight,
            cropX: cropX,
            cropY: cropY,
            cropEdge: cropEdge
        )
    }

    /// The exact rational `numerator / denominator` taken to an integer under `rule`.
    ///
    /// Nearest rounding is stated as a comparison of the two exact distances to the
    /// neighbouring integers rather than as a test on a remainder: `distanceDown` is how
    /// far the value lies above the lower neighbour and `distanceUp` how far below the
    /// upper one, both over the common denominator, so the nearer neighbour wins outright
    /// and the tie rule is consulted only when they are equal. That is the definition of
    /// each rule's name, and it is a different computation from doubling a remainder and
    /// comparing it with the divisor.
    static func rounded(numerator: Int, denominator: Int, rule: RoundingRule) -> Int? {
        guard denominator > 0, numerator >= 0 else { return nil }
        guard let lower = flooredQuotient(numerator: numerator, denominator: denominator),
              let atLower = product(lower, denominator)
        else {
            return nil
        }
        let isExact = atLower == numerator
        let upper = isExact ? lower : lower + 1
        switch rule {
        case .floor:
            return lower
        case .ceiling:
            return upper
        case .halfUp, .halfDown, .halfToEven:
            break
        }
        if isExact { return lower }
        guard let atUpper = product(upper, denominator) else { return nil }
        let distanceDown = numerator - atLower
        let distanceUp = atUpper - numerator
        if distanceDown < distanceUp { return lower }
        if distanceUp < distanceDown { return upper }
        switch rule {
        case .halfUp:
            return upper
        case .halfDown:
            return lower
        case .halfToEven:
            return lower.isMultiple(of: 2) ? lower : upper
        case .floor, .ceiling:
            return nil
        }
    }

    /// The unique integer `n` with `n * denominator <= numerator < (n + 1) * denominator`.
    ///
    /// Found by a bounded walk from a floating-point seed and then established exactly: the
    /// walk only stops at an `n` for which the lower product does not exceed the numerator
    /// *and* the next product does. No integer division or remainder is involved, so this
    /// cannot agree with an implementation that computes `numerator / denominator` merely
    /// by sharing its arithmetic, and a seed off by any bounded amount is corrected rather
    /// than believed.
    static func flooredQuotient(numerator: Int, denominator: Int) -> Int? {
        guard denominator > 0, numerator >= 0 else { return nil }
        var candidate = Int((Double(numerator) / Double(denominator)).rounded(.down))
        if candidate < 0 { candidate = 0 }
        for _ in 0...walkLimit {
            guard let atCandidate = product(candidate, denominator),
                  let atNext = product(candidate + 1, denominator)
            else {
                return nil
            }
            if atCandidate > numerator {
                candidate -= 1
                continue
            }
            if atNext <= numerator {
                candidate += 1
                continue
            }
            return candidate
        }
        return nil
    }

    /// The offset that centers a `cropEdge`-long span inside an `extent`-long one.
    ///
    /// "Centered" is stated as a relation between the two margins rather than as a formula:
    /// the leading margin and the trailing margin differ by at most one pixel, and the rule
    /// fixes which of them carries the odd one when the leftover is odd. The offset
    /// satisfying that relation is searched for in a small window around a floating-point
    /// seed and asserted to be the only one in that window, so the seed decides nothing and
    /// the answer is not `difference / 2` under another name.
    static func centeredOffset(extent: Int, cropEdge: Int, rule: CropOffsetRule) -> Int? {
        guard cropEdge > 0, extent >= cropEdge else { return nil }
        let difference = extent - cropEdge
        var seed = Int((Double(difference) / 2).rounded(.down))
        if seed < 0 { seed = 0 }
        if seed > difference { seed = difference }
        let lowestCandidate = max(0, seed - 3)
        let highestCandidate = min(difference, seed + 3)
        var satisfying: [Int] = []
        for candidate in lowestCandidate...highestCandidate
        where isCentered(candidate, difference: difference, rule: rule) {
            satisfying.append(candidate)
        }
        guard satisfying.count == 1 else { return nil }
        return satisfying[0]
    }

    /// Whether `offset` leaves margins the rule admits as centered.
    ///
    /// The leading margin is the offset itself and the trailing margin is what is left
    /// after the crop. Centered means they differ by at most one; the rule then says which
    /// side may be the larger, which is the only thing an odd leftover leaves open.
    static func isCentered(_ offset: Int, difference: Int, rule: CropOffsetRule) -> Bool {
        guard offset >= 0, offset <= difference else { return false }
        let leading = offset
        let trailing = difference - offset
        guard abs(leading - trailing) <= 1 else { return false }
        switch rule {
        case .floorHalfDifference:
            return leading <= trailing
        case .ceilingHalfDifference:
            return leading >= trailing
        }
    }

    /// `a * b`, or `nil` when it does not fit.
    static func product(_ a: Int, _ b: Int) -> Int? {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? nil : value
    }
}

// MARK: - Dimension families

/// How one generated case chooses its source dimensions.
///
/// Nine families rather than one uniform range, because the rounding rules are
/// indistinguishable almost everywhere. A uniform draw over a wide range essentially never
/// lands on an exact tie, so a property built on one would assert `floor` and `half-up`
/// agree a hundred times and never separate them. Three families construct the
/// neighbourhood of the tie directly, and ``RoundingClass`` then classifies what each case
/// actually presented so the witness reports measured coverage rather than intent.
///
/// Each family exists because it is the only reliable source of something the witness
/// requires. That is the same reason the identity short edge has a family of its own: a
/// situation reachable only through a narrow draw inside another family is a situation a
/// coverage assertion cannot honestly require.
private enum DimensionFamily: String, Hashable, Sendable, CaseIterable {
    /// A wide moderate range, so the property is not only about constructed corners.
    case general
    /// Both axes equal, where the short edge is assigned on the branch a square takes.
    case square
    /// Both axes tiny, so the resize is a large upscale and the short edge can be 1.
    case tiny
    /// Short edges immediately around the target, where the resize barely moves.
    case nearTarget
    /// A short edge exactly at the target, so the resize is the identity on that axis and
    /// the long axis scales by exactly one. Its own family rather than a value `nearTarget`
    /// might draw: it is one of the three situations the witness requires, and leaving it to
    /// a one-in-eleven draw inside another family would fail runs for no reason but the
    /// draw.
    case identityShortEdge
    /// A short edge that divides the target, so the exact ratio is an integer and no
    /// rounding rule may move it.
    case exactRatio
    /// A constructed exact tie: the scaled long edge is exactly `n + 1/2`, which is the
    /// only place `half-up`, `half-down`, and `half-to-even` disagree. Both parities of
    /// `n` occur, which is what makes `half-to-even` distinguishable from `half-down`.
    case exactTie
    /// A constructed remainder one unit either side of a tie, so the comparison the
    /// rounding rules make is exercised at its own boundary rather than a long way from
    /// it.
    case adjacentToTie
    /// A very large aspect ratio, where the resized long edge is orders of magnitude above
    /// the crop and the offset arithmetic is far from small numbers.
    case extremeAspect

    /// The source's short and long edge for this family.
    ///
    /// `primary` and `secondary` are the two generated parameters. Remainder and division
    /// are used freely here: this side *constructs inputs*, and nothing it computes is
    /// compared against production output. The expected answers come from
    /// ``GeometryReference`` alone.
    func edges(primary: Int, secondary: Int, targetShortEdge: Int) -> (short: Int, long: Int) {
        switch self {
        case .general:
            let short = 1 + primary % 1_200
            return (short, short + secondary % 3_000)
        case .square:
            let edge = 1 + primary % 4_000
            return (edge, edge)
        case .tiny:
            let short = 1 + primary % 16
            return (short, short + secondary % 16)
        case .nearTarget:
            let short = targetShortEdge - 5 + primary % 11
            return (short, short + secondary % 24)
        case .identityShortEdge:
            return (targetShortEdge, targetShortEdge + secondary % 3_000)
        case .exactRatio:
            let short = Self.targetDivisors[primary % Self.targetDivisors.count]
            return (short, short + secondary % 3_000)
        case .exactTie:
            // `short = 2 * target * t` and `long = t * u` for odd `u` makes the exact ratio
            // `long * target / short` equal `u / 2`, a half-integer, whose floor `(u - 1)/2`
            // is even for `u = 1 mod 4` and odd otherwise.
            let multiple = 1 + primary % 4
            let short = 2 * targetShortEdge * multiple
            let odd = 2 * targetShortEdge + 1 + 2 * (secondary % 560)
            return (short, multiple * odd)
        case .adjacentToTie:
            let short = Self.oddCoprimeShortEdges[primary % Self.oddCoprimeShortEdges.count]
            let doubledRemainder = secondary.isMultiple(of: 2) ? short - 1 : short + 1
            return (
                short,
                Self.longEdge(
                    forShortEdge: short,
                    doubledRemainder: doubledRemainder,
                    targetShortEdge: targetShortEdge
                )
            )
        case .extremeAspect:
            let short = 1 + primary % 4
            return (short, 100_000 + secondary % 3_900_000)
        }
    }

    /// Whether this family's sources can be materialized as pixel buffers.
    ///
    /// A statement about the family's bounds, not about a particular case: the case's own
    /// eligibility is decided from the dimensions and the resolved geometry it actually
    /// produced.
    var mayReachThePixelArms: Bool { self != .extremeAspect }

    /// The divisors of the target short edge, which make the exact ratio an integer.
    ///
    /// Stated as a filter over the candidates rather than as a list, so it stays correct if
    /// the requirement's constant is ever read from a different place.
    static let targetDivisors: [Int] = (1...ResizeContract.requiredShortEdge)
        .filter { ResizeContract.requiredShortEdge.isMultiple(of: $0) }

    /// Odd short edges coprime to the target, so a remainder adjacent to a tie exists.
    ///
    /// Odd, because a doubled remainder is even and can only be one away from an odd
    /// divisor. Coprime to the target, because that is what makes every remainder class
    /// reachable by some long edge, so the search below always terminates.
    static let oddCoprimeShortEdges: [Int] = (3...999).filter { candidate in
        candidate.isMultiple(of: 2) == false && greatestCommonDivisor(
            candidate,
            ResizeContract.requiredShortEdge
        ) == 1
    }

    /// The smallest long edge at or above `shortEdge` whose scaled remainder, doubled, is
    /// `doubledRemainder`.
    ///
    /// A search rather than a modular inverse, because the search is obviously right and
    /// bounded: multiplying by a value coprime to `shortEdge` permutes the residues, so
    /// every class appears among any `shortEdge` consecutive candidates.
    ///
    /// Falls back to one above the short edge if no candidate is found. That cannot happen
    /// for a coprime short edge, and if it ever did the case would simply land in another
    /// rounding class and ``GeometryVariationWitness`` would report the missing coverage
    /// rather than this returning something untrue.
    static func longEdge(
        forShortEdge shortEdge: Int,
        doubledRemainder: Int,
        targetShortEdge: Int
    ) -> Int {
        for candidate in shortEdge...(2 * shortEdge)
        where 2 * ((candidate * targetShortEdge) % shortEdge) == doubledRemainder {
            return candidate
        }
        return shortEdge + 1
    }

    static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var left = a
        var right = b
        while right != 0 {
            (left, right) = (right, left % right)
        }
        return left
    }
}

/// Where a generated source's exact ratio sits relative to the nearest tie.
///
/// Measured from the case rather than declared by its family, so the witness reports what
/// the run really presented. This is the only classification that says whether the five
/// rounding rules were separated at all: away from a tie every nearest rule agrees, and a
/// property that never reached one would be comparing `floor` with `ceiling` and nothing
/// else.
private enum RoundingClass: String, Hashable, Sendable, CaseIterable {
    /// The ratio is an integer, so no rule may move it.
    case exact
    /// Exactly halfway, where `half-up`, `half-down`, and `half-to-even` disagree.
    case tie
    /// One unit below a tie, the boundary of the comparison the rules make.
    case justBelowTie
    /// One unit above a tie.
    case justAboveTie
    /// Below the midpoint by more than one unit.
    case belowTie
    /// Above the midpoint by more than one unit.
    case aboveTie

    /// The class of `long * target / short`.
    ///
    /// Uses remainder arithmetic, which is fine here for the same reason the families do:
    /// this classifies a generated input for reporting, and no expectation is derived from
    /// it.
    static func of(shortEdge: Int, longEdge: Int, targetShortEdge: Int) -> RoundingClass {
        let remainder = (longEdge * targetShortEdge) % shortEdge
        let doubled = 2 * remainder
        if remainder == 0 { return .exact }
        if doubled == shortEdge { return .tie }
        if doubled == shortEdge - 1 { return .justBelowTie }
        if doubled == shortEdge + 1 { return .justAboveTie }
        return doubled < shortEdge ? .belowTie : .aboveTie
    }
}

// MARK: - Generated shape

/// One generated case, as plain data.
///
/// The generator produces data only. Contracts, surfaces, and geometries are built inside
/// the property body, where a construction that unexpectedly fails is recorded as an issue
/// rather than thrown: `propertyCheck` discards an error thrown by its body, so a refusal
/// that escaped as a throw would pass vacuously.
///
/// ## How the baseline varies
///
///   * the dimension family, over all nine, so the rounding neighbourhood is reached by
///     construction and the wide ranges are covered too;
///   * two family parameters independently, so a family is never one fixed pair;
///   * the orientation, so the short edge is taken from each axis in turn and an
///     implementation that exchanged them fails on half the cases rather than none;
///   * the rounding rule and the crop offset rule the pixel arms bind — every case
///     additionally compares *all* five rounding rules and both offset rules against the
///     reference, so those two only choose which contract the pixels are produced under;
///   * the pixel-center convention and the sample edge rule, which must not move the
///     geometry at all, and whose invariance is asserted per case;
///   * every synthetic identifier, from ``seed``.
///
/// ``GeometryVariationWitness`` checks after the run that this actually happened.
private struct GeometryShape: Sendable, CustomStringConvertible {
    /// Drives the synthetic contract identifiers, so two cases never share one.
    ///
    /// Used only in identifier strings. No schema version is derived from it: a version
    /// whose every component can be zero can name the `0.0.0` development stand-in, which
    /// the artifact schema rejects, and the refusal would surface as a construction failure
    /// in an unrelated arm.
    let seed: Int

    let familyIndex: Int
    let primary: Int
    let secondary: Int
    let portrait: Bool
    let roundingIndex: Int
    let offsetRuleIndex: Int
    let conventionIndex: Int
    let edgeRuleIndex: Int

    /// Selects which of the cases that can allocate buffers run the three-channel
    /// model-input arm.
    let channelIndex: Int

    var family: DimensionFamily {
        DimensionFamily.allCases[familyIndex % DimensionFamily.allCases.count]
    }

    var rounding: RoundingRule {
        RoundingRule.allCases[roundingIndex % RoundingRule.allCases.count]
    }

    var offsetRule: CropOffsetRule {
        CropOffsetRule.allCases[offsetRuleIndex % CropOffsetRule.allCases.count]
    }

    var convention: PixelCenterConvention {
        PixelCenterConvention.allCases[conventionIndex % PixelCenterConvention.allCases.count]
    }

    var edgeRule: SampleEdgeRule {
        SampleEdgeRule.allCases[edgeRuleIndex % SampleEdgeRule.allCases.count]
    }

    /// The requirement's fixed short-edge target, read from the type that owns it.
    var targetShortEdge: Int { ResizeContract.requiredShortEdge }

    /// The requirement's fixed crop edge, read from the type that owns it.
    var cropEdge: Int { CenterCropContract.requiredEdge }

    private var edges: (short: Int, long: Int) {
        family.edges(primary: primary, secondary: secondary, targetShortEdge: targetShortEdge)
    }

    /// The source dimensions, in the generated orientation.
    var sourceWidth: Int { portrait ? edges.short : edges.long }

    /// The source dimensions, in the generated orientation.
    var sourceHeight: Int { portrait ? edges.long : edges.short }

    /// Where this case's exact ratio sits relative to the nearest tie.
    var roundingClass: RoundingClass {
        RoundingClass.of(
            shortEdge: edges.short,
            longEdge: edges.long,
            targetShortEdge: targetShortEdge
        )
    }

    /// The floor of the exact ratio, whose parity decides `half-to-even` at a tie.
    var flooredRatioIsEven: Bool {
        ((edges.long * targetShortEdge) / edges.short).isMultiple(of: 2)
    }

    /// Whether this case may allocate pixel buffers at all.
    ///
    /// A bound on the source allocation, so an extreme aspect ratio is compared as integers
    /// only. The resized extent is bounded separately by the arm that materializes it.
    var mayAllocateSurfaces: Bool {
        family.mayReachThePixelArms
            && sourceWidth <= Self.largestAllocatedSourceEdge
            && sourceHeight <= Self.largestAllocatedSourceEdge
    }

    /// The largest source edge this file allocates a buffer for.
    ///
    /// A test-runtime bound, not a limit on anything the module accepts — the source is
    /// bounded by the Resource Budget in the adapter, and Requirement 3.4's checks are
    /// Property 8's subject. Every larger source is still compared as integers, which is
    /// where the geometry claim lives.
    static let largestAllocatedSourceEdge = 512

    /// Whether this case additionally runs the three-channel model-input arm.
    ///
    /// Half of the cases that can allocate buffers rather than all of them: a three-channel
    /// crop costs three times as much to resample, and half is enough to keep the arm's own
    /// floor far above what an unlucky draw produces.
    var prefersTheModelInputArm: Bool { channelIndex.isMultiple(of: 2) }

    var description: String {
        """
        seed \(seed), \(family.rawValue) \(sourceWidth)x\(sourceHeight) \
        (\(portrait ? "portrait" : "landscape")), \(roundingClass.rawValue), \
        rounding \(rounding.rawValue), offset \(offsetRule.rawValue), \
        \(convention.rawValue), \(edgeRule.rawValue)
        """
    }

    // MARK: Generators

    static var generator: Generator<GeometryShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.int(in: 0...199),
            Gen.int(in: 0...4_095),
            Gen.int(in: 0...4_095),
            Gen.bool,
            Gen.int(in: 0...199),
            Gen.int(in: 0...199),
            Gen.int(in: 0...199),
            Gen.int(in: 0...199),
            Gen.int(in: 0...199)
        )
        .map { raw in
            GeometryShape(
                seed: raw.0,
                familyIndex: raw.1,
                primary: raw.2,
                secondary: raw.3,
                portrait: raw.4,
                roundingIndex: raw.5,
                offsetRuleIndex: raw.6,
                conventionIndex: raw.7,
                edgeRuleIndex: raw.8,
                channelIndex: raw.9
            )
        }
        .eraseToAny()
    }
}

// MARK: - Contracts

/// The schema-valid contracts this file resolves geometry under.
///
/// Precomputed once for every combination of the four geometry rules, because a contract is
/// a function of the rules alone and constructing sixty of them per generated case would
/// put artifact validation inside the measured property.
///
/// Every contract goes through ``PreprocessingContract``'s own initializer, so the 440
/// short edge and the 384 crop in every geometry below came out of a schema-valid artifact
/// rather than out of a literal in a test.
private enum GeometryContracts {
    private struct Key: Hashable {
        let rounding: RoundingRule
        let offsetRule: CropOffsetRule
        let convention: PixelCenterConvention
        let edgeRule: SampleEdgeRule
    }

    private static let table: [Key: PreprocessingContract] = {
        var table: [Key: PreprocessingContract] = [:]
        for rounding in RoundingRule.allCases {
            for offsetRule in CropOffsetRule.allCases {
                for convention in PixelCenterConvention.allCases {
                    for edgeRule in SampleEdgeRule.allCases {
                        let key = Key(
                            rounding: rounding,
                            offsetRule: offsetRule,
                            convention: convention,
                            edgeRule: edgeRule
                        )
                        table[key] = PreprocessingFixture.contract(
                            id: [
                                "preprocessing-p12",
                                rounding.rawValue,
                                offsetRule.rawValue,
                                convention.rawValue,
                                edgeRule.rawValue,
                            ].joined(separator: "-"),
                            rounding: rounding,
                            edgeRule: edgeRule,
                            pixelCenterConvention: convention,
                            cropOffsetRule: offsetRule
                        )
                    }
                }
            }
        }
        return table
    }()

    static func contract(
        rounding: RoundingRule,
        offsetRule: CropOffsetRule,
        convention: PixelCenterConvention = .halfPixelCenters,
        edgeRule: SampleEdgeRule = .clampToEdge
    ) -> PreprocessingContract? {
        table[
            Key(
                rounding: rounding,
                offsetRule: offsetRule,
                convention: convention,
                edgeRule: edgeRule
            )
        ]
    }
}

// MARK: - Surfaces

/// Pixel buffers for the arms that check the crop in pixels.
private enum GeometrySurface {
    /// A tightly packed surface over a deterministic, non-flat pattern.
    ///
    /// Non-flat in both axes and in every channel, because a flat or a
    /// one-axis-only pattern is translation-invariant in the direction that matters and
    /// would make the off-by-one comparison below pass without meaning anything. The
    /// pattern's period is deliberately not a divisor of the crop edge.
    static func patterned(width: Int, height: Int, channelCount: Int) -> PixelSurface? {
        guard let surface = try? PixelSurface.tightlyPacked(
            width: width,
            height: height,
            channelCount: channelCount
        ) else {
            return nil
        }
        guard let base = surface.buffer.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<channelCount {
                    let offset = (y * width + x) * channelCount + channel
                    base[offset] = UInt8((x * 37 + y * 61 + channel * 97) % 251)
                }
            }
        }
        return surface
    }
}

// MARK: - Scenario

/// One generated shape and the five checks it performs.
private struct GeometryScenario {
    let shape: GeometryShape
    let witness: GeometryVariationWitness

    /// The largest resized long edge whose full resize this file materializes.
    ///
    /// A test-runtime bound, not a limit on anything the module accepts: a resized image is
    /// 440 by this, and the crop reads 384 columns of it whatever the rest costs.
    static let largestMaterializedLongEdge = 620

    // MARK: Against the reference

    /// Requirements 4.4 and 4.5, compared with ``GeometryReference`` under every rule.
    ///
    /// Ten geometries a case: five rounding rules against both crop offset rules. Resolving
    /// every rule rather than only the generated one makes rounding-rule coverage total per
    /// case instead of a property of the draw, and it costs nothing — the geometry is
    /// integer arithmetic over two numbers.
    func checkEveryRuleAgreesWithTheReference() {
        for rounding in RoundingRule.allCases {
            for offsetRule in CropOffsetRule.allCases {
                checkOneRuleAgreesWithTheReference(rounding: rounding, offsetRule: offsetRule)
            }
        }
    }

    private func checkOneRuleAgreesWithTheReference(
        rounding: RoundingRule,
        offsetRule: CropOffsetRule
    ) {
        guard let geometry = resolve(rounding: rounding, offsetRule: offsetRule) else { return }
        guard let expected = GeometryReference.resolve(
            sourceWidth: shape.sourceWidth,
            sourceHeight: shape.sourceHeight,
            targetShortEdge: shape.targetShortEdge,
            rounding: rounding,
            cropEdge: shape.cropEdge,
            offsetRule: offsetRule
        ) else {
            Issue.record(
                """
                the reference could not resolve \(rounding.rawValue) with \
                \(offsetRule.rawValue) [\(shape)]
                """
            )
            return
        }

        // The resized dimensions, field by field rather than as a pair, so a failure names
        // the axis.
        #expect(
            geometry.resized.width == expected.resizedWidth,
            "resized width under \(rounding.rawValue) [\(shape)]"
        )
        #expect(
            geometry.resized.height == expected.resizedHeight,
            "resized height under \(rounding.rawValue) [\(shape)]"
        )
        // Requirement 4.4's constant, asserted directly as well as through the reference.
        #expect(
            geometry.resized.shortEdge == shape.targetShortEdge,
            "the resized short edge must be exactly \(shape.targetShortEdge) [\(shape)]"
        )
        // The whole crop rectangle: both offsets and both edges.
        #expect(
            geometry.crop.x == expected.cropX,
            "crop x under \(rounding.rawValue)/\(offsetRule.rawValue) [\(shape)]"
        )
        #expect(
            geometry.crop.y == expected.cropY,
            "crop y under \(rounding.rawValue)/\(offsetRule.rawValue) [\(shape)]"
        )
        // Requirement 4.5's constant.
        #expect(geometry.crop.size.width == shape.cropEdge, "crop width [\(shape)]")
        #expect(geometry.crop.size.height == shape.cropEdge, "crop height [\(shape)]")
        // Wholly within the resized image, through the production predicate and again
        // through the four inequalities it stands for, so a predicate that always agreed
        // would not satisfy this on its own.
        #expect(geometry.crop.isContained(in: geometry.resized), "containment [\(shape)]")
        #expect(geometry.crop.x >= 0, "crop x is non-negative [\(shape)]")
        #expect(geometry.crop.y >= 0, "crop y is non-negative [\(shape)]")
        #expect(geometry.crop.maxX <= geometry.resized.width, "crop right edge [\(shape)]")
        #expect(geometry.crop.maxY <= geometry.resized.height, "crop bottom edge [\(shape)]")

        checkAspectRatioIsPreserved(geometry, rounding: rounding)
        checkTheShortAxisIsTheSourcesShortAxis(geometry)
        checkResolvingAgainGivesTheSameGeometry(
            geometry,
            rounding: rounding,
            offsetRule: offsetRule
        )
        witness.recordReferenceComparison(rounding: rounding, offsetRule: offsetRule)
        witness.recordCropLeftover(
            width: geometry.resized.width - shape.cropEdge,
            height: geometry.resized.height - shape.cropEdge
        )
        witness.recordResizedLongEdge(geometry.resized.longEdge)
    }

    /// "Preserving aspect ratio" (Requirement 4.4) as an exact integer statement.
    ///
    /// The resized long edge is the exact rational `long * target / short` taken to an
    /// integer, so the cross products of the two shapes differ by less than one source
    /// short edge — and by at most half of one under the three nearest rules. Written as a
    /// cross multiplication so no floating-point division enters the assertion, and stated
    /// symmetrically so the same expression covers both orientations.
    private func checkAspectRatioIsPreserved(_ geometry: ResizeGeometry, rounding: RoundingRule) {
        let source = geometry.source
        let widthTimesHeight = geometry.resized.width * source.height
        let heightTimesWidth = geometry.resized.height * source.width
        let gap = abs(widthTimesHeight - heightTimesWidth)
        #expect(
            gap < source.shortEdge,
            """
            \(geometry.resized.width)x\(geometry.resized.height) is more than a pixel from \
            the exact ratio under \(rounding.rawValue) [\(shape)]
            """
        )
        switch rounding {
        case .halfUp, .halfDown, .halfToEven:
            #expect(
                2 * gap <= source.shortEdge,
                """
                a nearest rule must land within half a pixel; \(rounding.rawValue) gave \
                \(geometry.resized.width)x\(geometry.resized.height) [\(shape)]
                """
            )
        case .floor, .ceiling:
            break
        }
    }

    /// The target lands on the axis that was short in the source.
    ///
    /// Preserving the ratio does not by itself forbid exchanging the axes — a transposed
    /// result has the same ratio read the other way. Stated as monotonicity so it holds for
    /// a source whose scaled long edge rounds down to the target as well: the ordering of
    /// the two source axes is never inverted, and a square source stays square.
    private func checkTheShortAxisIsTheSourcesShortAxis(_ geometry: ResizeGeometry) {
        let source = geometry.source
        if source.width <= source.height {
            #expect(
                geometry.resized.width <= geometry.resized.height,
                "a portrait or square source must not become landscape [\(shape)]"
            )
        }
        if source.width >= source.height {
            #expect(
                geometry.resized.height <= geometry.resized.width,
                "a landscape or square source must not become portrait [\(shape)]"
            )
        }
        if source.width == source.height {
            #expect(
                geometry.resized.width == shape.targetShortEdge
                    && geometry.resized.height == shape.targetShortEdge,
                "a square source must resize to the target on both axes [\(shape)]"
            )
            witness.recordSquareCheck()
        }
    }

    /// The same source and the same rules produce the identical geometry again.
    private func checkResolvingAgainGivesTheSameGeometry(
        _ geometry: ResizeGeometry,
        rounding: RoundingRule,
        offsetRule: CropOffsetRule
    ) {
        guard let again = resolve(rounding: rounding, offsetRule: offsetRule) else { return }
        #expect(again == geometry, "the geometry must be deterministic [\(shape)]")
    }

    // MARK: Relations between the rules

    /// Orderings that hold whatever the right answer is.
    ///
    /// These bite where the reference and the implementation agree by accident: a rule
    /// table wired to the wrong case survives a comparison against a reference wired the
    /// same way, but it cannot also keep flooring below every nearest rule, keep every
    /// nearest rule below the ceiling, keep the two within one pixel of each other, and
    /// keep the two offset rules exactly the leftover's parity apart.
    func checkRelationsBetweenTheRules() {
        var longEdges: [RoundingRule: Int] = [:]
        for rounding in RoundingRule.allCases {
            guard let geometry = resolve(rounding: rounding, offsetRule: shape.offsetRule) else {
                return
            }
            longEdges[rounding] = geometry.resized.longEdge
        }
        guard let floored = longEdges[.floor],
              let ceiled = longEdges[.ceiling],
              let halfUp = longEdges[.halfUp],
              let halfDown = longEdges[.halfDown],
              let halfToEven = longEdges[.halfToEven]
        else {
            Issue.record("every rounding rule must resolve [\(shape)]")
            return
        }
        #expect(floored <= halfDown, "floor above half-down [\(shape)]")
        #expect(halfDown <= halfUp, "half-down above half-up [\(shape)]")
        #expect(halfUp <= ceiled, "half-up above ceiling [\(shape)]")
        #expect(floored <= halfToEven, "floor above half-to-even [\(shape)]")
        #expect(halfToEven <= ceiled, "half-to-even above ceiling [\(shape)]")
        #expect(ceiled - floored <= 1, "the ceiling is more than one above the floor [\(shape)]")

        guard
            let flooringOffsets = resolve(
                rounding: shape.rounding,
                offsetRule: .floorHalfDifference
            ),
            let ceilingOffsets = resolve(
                rounding: shape.rounding,
                offsetRule: .ceilingHalfDifference
            )
        else {
            return
        }
        // The offset rule exists for one thing: an odd leftover. So the two rules differ by
        // exactly the leftover's parity on each axis, and by nothing else.
        #expect(
            flooringOffsets.resized == ceilingOffsets.resized,
            "the offset rule must not change the resized size [\(shape)]"
        )
        let horizontalLeftover = flooringOffsets.resized.width - shape.cropEdge
        let verticalLeftover = flooringOffsets.resized.height - shape.cropEdge
        #expect(
            ceilingOffsets.crop.x - flooringOffsets.crop.x == horizontalLeftover % 2,
            "the horizontal offsets must differ by the leftover's parity [\(shape)]"
        )
        #expect(
            ceilingOffsets.crop.y - flooringOffsets.crop.y == verticalLeftover % 2,
            "the vertical offsets must differ by the leftover's parity [\(shape)]"
        )
        witness.recordRuleRelationCheck()
    }

    // MARK: Invariance

    /// The sampling rules cannot move the geometry.
    ///
    /// The pixel-center convention and the edge rule decide where a sample reads from, not
    /// how large the resized image is or where the crop sits. Asserted because both arrive
    /// on the same contract as the rounding and offset rules, and a geometry that read one
    /// of them would make the crop depend on a sampling choice — which is exactly the kind
    /// of difference that survives as a plausible image.
    func checkTheSamplingRulesCannotMoveTheGeometry() {
        guard let baseline = resolve(
            rounding: shape.rounding,
            offsetRule: shape.offsetRule,
            convention: shape.convention,
            edgeRule: shape.edgeRule
        ) else {
            return
        }
        for convention in PixelCenterConvention.allCases {
            for edgeRule in SampleEdgeRule.allCases {
                guard let other = resolve(
                    rounding: shape.rounding,
                    offsetRule: shape.offsetRule,
                    convention: convention,
                    edgeRule: edgeRule
                ) else {
                    return
                }
                #expect(
                    other == baseline,
                    """
                    \(convention.rawValue) with \(edgeRule.rawValue) produced a different \
                    geometry [\(shape)]
                    """
                )
            }
        }
        witness.recordInvarianceCheck()
    }

    // MARK: In pixels

    /// The crop is the rectangle the resample actually reads.
    ///
    /// Integers alone do not settle Requirement 4.5: the crop is a rectangle of an image,
    /// and the pixels the model receives have to be the ones inside it. So the fused crop
    /// the preprocessor produces is compared byte for byte against the sub-rectangle of a
    /// separately materialized full resize, taken at the **reference's** offset rather than
    /// at the production geometry's. The full resize indexes its own array from its own
    /// origin, so there is no window offset on that side of the comparison for an error to
    /// hide in.
    ///
    /// The same comparison is then run one pixel to the side. Where the shifted rectangle
    /// gives different bytes — which it does unless the image is translation-invariant
    /// there — the equality above is a statement about *this* rectangle and not about any
    /// nearby one. ``GeometryVariationWitness`` holds the run to a floor of those, so the
    /// discriminating half cannot quietly stop happening.
    ///
    /// Runs on the cases whose source and resized extent are small enough to materialize.
    /// A full resize is bounded by its short edge at the target and its long edge by the
    /// aspect ratio, so an extreme ratio would allocate tens of megabytes to read 384
    /// columns of it; those cases are compared as integers only, which is what the whole
    /// separation of geometry from sampling is for.
    func checkTheCropIsTheRectangleTheResampleReads() {
        guard shape.mayAllocateSurfaces else { return }
        guard let geometry = resolve(
            rounding: shape.rounding,
            offsetRule: shape.offsetRule,
            convention: shape.convention,
            edgeRule: shape.edgeRule
        ) else {
            return
        }
        // The materialized resize is the cost that grows with the aspect ratio: its short
        // edge is the target and its long edge is unbounded. Capped a little above the crop
        // so a moderately non-square resize is still materialized, which is where the crop
        // offset is non-trivial on both axes.
        guard geometry.resized.longEdge <= Self.largestMaterializedLongEdge else { return }
        guard let expected = GeometryReference.resolve(
            sourceWidth: shape.sourceWidth,
            sourceHeight: shape.sourceHeight,
            targetShortEdge: shape.targetShortEdge,
            rounding: shape.rounding,
            cropEdge: shape.cropEdge,
            offsetRule: shape.offsetRule
        ) else {
            Issue.record("the reference could not resolve the pixel arm's geometry [\(shape)]")
            return
        }
        guard let source = GeometrySurface.patterned(
            width: shape.sourceWidth,
            height: shape.sourceHeight,
            channelCount: 1
        ) else {
            Issue.record("a \(shape.sourceWidth)x\(shape.sourceHeight) surface [\(shape)]")
            return
        }
        // Measured off the surface rather than taken from the generated pair, so an
        // allocation that came back at another size fails here instead of moving what the
        // expectation means.
        #expect(source.dimensions == geometry.source, "the surface's own dimensions [\(shape)]")

        let resized: PixelSurface
        let cropped: PixelSurface
        do {
            resized = try BilinearResampler.resize(
                source,
                to: geometry.resized,
                convention: shape.convention,
                edgeRule: shape.edgeRule
            )
            cropped = try BilinearResampler.sample(
                source,
                resized: geometry.resized,
                window: geometry.crop,
                convention: shape.convention,
                edgeRule: shape.edgeRule
            )
        } catch {
            Issue.record("the resample refused an accepted geometry: \(error) [\(shape)]")
            return
        }
        // The materialized resize really is the resolved size, so the sub-rectangle below
        // is taken from the image the geometry describes.
        #expect(resized.width == geometry.resized.width, "materialized resize width [\(shape)]")
        #expect(resized.height == geometry.resized.height, "materialized resize height [\(shape)]")
        #expect(cropped.width == shape.cropEdge, "the crop's own width [\(shape)]")
        #expect(cropped.height == shape.cropEdge, "the crop's own height [\(shape)]")

        let resizedBytes = resized.copyPackedBytes()
        let croppedBytes = cropped.copyPackedBytes()
        let atReferenceOffset = subRectangle(
            of: resizedBytes,
            width: resized.width,
            x: expected.cropX,
            y: expected.cropY,
            edge: shape.cropEdge
        )
        // Reported as the first disagreeing sample rather than as two 147,456-byte arrays,
        // so a failure names a coordinate instead of printing the crop twice. Computed once
        // and held: a `#expect` comment is evaluated eagerly, so calling the scan inside the
        // message would run it on every passing case as well.
        let disagreement = firstDisagreement(croppedBytes, atReferenceOffset)
        #expect(
            disagreement == nil,
            """
            the crop is not the resize's rectangle at the reference offset \
            (\(expected.cropX), \(expected.cropY)): \(describe(disagreement)) [\(shape)]
            """
        )
        witness.recordPixelComparison()
        checkAShiftedRectangleIsDifferent(
            croppedBytes: croppedBytes,
            resizedBytes: resizedBytes,
            resized: resized,
            expected: expected
        )
    }

    /// A rectangle one pixel to the side gives different bytes, where it can.
    ///
    /// Without this, "the crop equals the rectangle at the reference offset" would also
    /// hold for a picture in which every nearby rectangle is identical, and the offset
    /// assertion would be vacuous on exactly the inputs where it matters most.
    private func checkAShiftedRectangleIsDifferent(
        croppedBytes: [UInt8],
        resizedBytes: [UInt8],
        resized: PixelSurface,
        expected: GeometryReference.Resolved
    ) {
        let shifts = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for (horizontal, vertical) in shifts {
            let x = expected.cropX + horizontal
            let y = expected.cropY + vertical
            guard x >= 0, y >= 0,
                  x + shape.cropEdge <= resized.width,
                  y + shape.cropEdge <= resized.height
            else {
                continue
            }
            let shifted = subRectangle(
                of: resizedBytes,
                width: resized.width,
                x: x,
                y: y,
                edge: shape.cropEdge
            )
            if firstDisagreement(shifted, croppedBytes) != nil {
                witness.recordOffsetDiscrimination()
            }
        }
    }

    /// The first index at which two equal-length sample sequences differ, or `nil`.
    ///
    /// Used instead of `==` inside an expectation so a failure reports one coordinate. A
    /// length difference is reported at the first index past the shorter sequence, which
    /// cannot happen for two rectangles of the same edge and is refused rather than ignored.
    private func firstDisagreement(_ left: [UInt8], _ right: [UInt8]) -> Int? {
        guard left.count == right.count else { return min(left.count, right.count) }
        for index in left.indices where left[index] != right[index] { return index }
        return nil
    }

    /// One disagreement, as a coordinate and channel in the crop.
    private func describe(_ index: Int?, channelCount: Int = 1) -> String {
        guard let index else { return "no disagreement" }
        let sample = index / channelCount
        return """
            first at (\(sample % shape.cropEdge), \(sample / shape.cropEdge)) \
            channel \(index % channelCount)
            """
    }

    /// The bytes of the `edge`-square rectangle at `(x, y)` of a single-channel image.
    private func subRectangle(
        of bytes: [UInt8],
        width: Int,
        x: Int,
        y: Int,
        edge: Int
    ) -> [UInt8] {
        var rectangle: [UInt8] = []
        rectangle.reserveCapacity(edge * edge)
        for row in 0..<edge {
            let start = (y + row) * width + x
            rectangle.append(contentsOf: bytes[start..<(start + edge)])
        }
        return rectangle
    }

    /// The geometry's crop is the buffer the bound model input declares.
    ///
    /// Requirement 4.5's crop and Requirement 4.6's model input are the same 384 square,
    /// and the only thing that connects them is that the crop the geometry produced is
    /// accepted by ``ModelInputProduction`` unchanged: exactly `384 * 384 * 3` bytes,
    /// three-channel, tightly packed, with nothing reshaped or repacked on the way. A
    /// geometry that produced a nearby rectangle would be refused here rather than
    /// adjusted.
    ///
    /// Three channels rather than one, so the buffer really is the shape the contract
    /// declares; run on a subset because the crop costs three times as much to resample.
    func checkTheCropIsTheBoundModelInputBuffer() {
        guard shape.mayAllocateSurfaces, shape.prefersTheModelInputArm else { return }
        guard let contract = GeometryContracts.contract(
            rounding: shape.rounding,
            offsetRule: shape.offsetRule,
            convention: shape.convention,
            edgeRule: shape.edgeRule
        ) else {
            Issue.record("the contract table has no entry for this case [\(shape)]")
            return
        }
        guard let geometry = resolve(
            rounding: shape.rounding,
            offsetRule: shape.offsetRule,
            convention: shape.convention,
            edgeRule: shape.edgeRule
        ) else {
            return
        }
        guard let source = GeometrySurface.patterned(
            width: shape.sourceWidth,
            height: shape.sourceHeight,
            channelCount: ModelInputProduction.channelCount
        ) else {
            Issue.record("a three-channel \(shape.sourceWidth)x\(shape.sourceHeight) [\(shape)]")
            return
        }
        do {
            let cropped = try BilinearResampler.sample(
                source,
                resized: geometry.resized,
                window: geometry.crop,
                convention: shape.convention,
                edgeRule: shape.edgeRule
            )
            let bytes = try ModelInputProduction.bytes(
                from: cropped,
                modelInput: contract.modelInput
            )
            #expect(
                bytes.count
                    == shape.cropEdge * shape.cropEdge * ModelInputProduction.channelCount,
                "the model input is \(bytes.count) bytes [\(shape)]"
            )
            #expect(cropped.isTightlyPacked, "the crop must be tightly packed [\(shape)]")
            let disagreement = firstDisagreement(cropped.copyPackedBytes(), bytes)
            #expect(
                disagreement == nil,
                """
                step 6 must be a copy; \
                \(describe(disagreement, channelCount: ModelInputProduction.channelCount)) \
                [\(shape)]
                """
            )
            witness.recordModelInputCheck()
        } catch {
            Issue.record("the bound model input refused the crop: \(error) [\(shape)]")
        }
    }

    // MARK: Resolving

    /// The production geometry, or `nil` after recording why it could not be resolved.
    ///
    /// Every generated source is one the contract accepts — positive dimensions whose
    /// scaled long edge is representable — so a refusal here is a failure of the property
    /// rather than an expected outcome, and it is recorded as one. The refusal paths
    /// themselves are pinned as examples in `ResizeGeometryTests`.
    private func resolve(
        rounding: RoundingRule,
        offsetRule: CropOffsetRule,
        convention: PixelCenterConvention = .halfPixelCenters,
        edgeRule: SampleEdgeRule = .clampToEdge
    ) -> ResizeGeometry? {
        guard let contract = GeometryContracts.contract(
            rounding: rounding,
            offsetRule: offsetRule,
            convention: convention,
            edgeRule: edgeRule
        ) else {
            Issue.record("the contract table has no entry for this case [\(shape)]")
            return nil
        }
        guard let source = PixelDimensions(
            width: shape.sourceWidth,
            height: shape.sourceHeight
        ) else {
            Issue.record("generated dimensions must be positive [\(shape)]")
            return nil
        }
        do {
            return try ResizeGeometry.resolve(
                source: source,
                resize: contract.resize,
                crop: contract.crop
            )
        } catch {
            Issue.record(
                """
                an accepted \(shape.sourceWidth)x\(shape.sourceHeight) source was refused \
                under \(rounding.rawValue)/\(offsetRule.rawValue): \(error) [\(shape)]
                """
            )
            return nil
        }
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator produced and what the body actually asserted.
///
/// It also proves the run happened at all. `propertyCheck` swallows an error thrown by its
/// body — the library runs the body under `try?` and moves to the next case — so a body that
/// failed before its first assertion would report a passing test in milliseconds with every
/// arm skipped. A witness that counts *outside* the body is the only thing that catches
/// that.
///
/// A case count alone is not enough, and in this file it would be actively misleading:
/// ``record(_:)`` is the body's first statement, so `cases` reaches its total even if
/// everything after it threw. Nor is a completion count enough on its own, because
/// `completed == cases` passes vacuously at zero. So each class of assertion carries its own
/// counter and each unconditional counter is compared against `cases` rather than against a
/// constant. A body that threw after recording would leave every one of them at zero
/// against a `cases` of two hundred, which fails loudly instead of passing quietly.
///
/// The conditional counters — the two pixel arms and the off-by-one discrimination — carry
/// floors instead, because whether a case can allocate its buffers is a property of the
/// drawn dimensions rather than something the body decides. Each floor is stated with the
/// reason it is a floor.
private final class GeometryVariationWitness: @unchecked Sendable {
    private let lock = NSLock()

    // What was generated.
    private var families = Set<DimensionFamily>()
    private var roundingClasses = Set<RoundingClass>()
    private var tieFlooredParities = Set<Bool>()
    private var drawnRoundings = Set<RoundingRule>()
    private var drawnOffsetRules = Set<CropOffsetRule>()
    private var drawnConventions = Set<PixelCenterConvention>()
    private var drawnEdgeRules = Set<SampleEdgeRule>()
    private var orientations = Set<String>()
    private var sources = Set<String>()
    private var shortEdgeRelations = Set<String>()
    private var cases = 0

    // What was asserted.
    private var referenceComparisons = 0
    private var comparedRoundings = Set<RoundingRule>()
    private var comparedOffsetRules = Set<CropOffsetRule>()
    private var ruleRelationChecks = 0
    private var invarianceChecks = 0
    private var squareChecks = 0
    private var pixelComparisons = 0
    private var offsetDiscriminations = 0
    private var modelInputChecks = 0
    private var oddLeftovers = 0
    private var evenLeftovers = 0
    private var largestResizedLongEdge = 0

    func record(_ shape: GeometryShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        families.insert(shape.family)
        let roundingClass = shape.roundingClass
        roundingClasses.insert(roundingClass)
        if roundingClass == .tie { tieFlooredParities.insert(shape.flooredRatioIsEven) }
        drawnRoundings.insert(shape.rounding)
        drawnOffsetRules.insert(shape.offsetRule)
        drawnConventions.insert(shape.convention)
        drawnEdgeRules.insert(shape.edgeRule)
        let width = shape.sourceWidth
        let height = shape.sourceHeight
        if width == height {
            orientations.insert("square")
        } else {
            orientations.insert(width > height ? "landscape" : "portrait")
        }
        sources.insert("\(width)x\(height)")
        let shortEdge = min(width, height)
        if shortEdge < shape.targetShortEdge {
            shortEdgeRelations.insert("upscale")
        } else if shortEdge > shape.targetShortEdge {
            shortEdgeRelations.insert("downscale")
        } else {
            shortEdgeRelations.insert("identity")
        }
    }

    func recordReferenceComparison(rounding: RoundingRule, offsetRule: CropOffsetRule) {
        increment {
            referenceComparisons += 1
            comparedRoundings.insert(rounding)
            comparedOffsetRules.insert(offsetRule)
        }
    }

    func recordCropLeftover(width: Int, height: Int) {
        increment {
            for leftover in [width, height] {
                if leftover.isMultiple(of: 2) { evenLeftovers += 1 } else { oddLeftovers += 1 }
            }
        }
    }

    func recordResizedLongEdge(_ longEdge: Int) {
        increment { largestResizedLongEdge = max(largestResizedLongEdge, longEdge) }
    }

    func recordRuleRelationCheck() { increment { ruleRelationChecks += 1 } }
    func recordInvarianceCheck() { increment { invarianceChecks += 1 } }
    func recordSquareCheck() { increment { squareChecks += 1 } }
    func recordPixelComparison() { increment { pixelComparisons += 1 } }
    func recordOffsetDiscrimination() { increment { offsetDiscriminations += 1 } }
    func recordModelInputCheck() { increment { modelInputChecks += 1 } }

    private func increment(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body()
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases")

        // Every dimension family was drawn. Exact at this case count: nine families drawn
        // uniformly over two hundred cases miss one with vanishing probability, and a family
        // that stopped being reachable is a change to the generator rather than a bad draw.
        #expect(
            families == Set(DimensionFamily.allCases),
            """
            generated families: \(families.map(\.rawValue).sorted()); \
            expected \(DimensionFamily.allCases.count)
            """
        )
        // The rounding neighbourhood was really reached. This is the assertion the property
        // would be hollow without: away from a tie every nearest rule agrees, so a run that
        // never presented one compared `floor` with `ceiling` and nothing else. Three
        // families construct these classes directly, which is what makes exact equality
        // sound here rather than a floor.
        #expect(
            roundingClasses == Set(RoundingClass.allCases),
            "presented rounding classes: \(roundingClasses.map(\.rawValue).sorted())"
        )
        // Both parities of the floored ratio at a tie. Without both, `half-to-even` is
        // indistinguishable from `half-down`, and the rule table could be miswired between
        // them undetected.
        #expect(
            tieFlooredParities == [false, true],
            "tie parities: \(tieFlooredParities.map(String.init).sorted())"
        )
        // Every rule appeared as the drawn one, so the pixel arms and the invariance check
        // ran under all of them rather than under one.
        #expect(
            drawnRoundings == Set(RoundingRule.allCases),
            "drawn rounding rules: \(drawnRoundings.map(\.rawValue).sorted())"
        )
        #expect(
            drawnOffsetRules == Set(CropOffsetRule.allCases),
            "drawn offset rules: \(drawnOffsetRules.map(\.rawValue).sorted())"
        )
        #expect(
            drawnConventions == Set(PixelCenterConvention.allCases),
            "drawn conventions: \(drawnConventions.map(\.rawValue).sorted())"
        )
        #expect(
            drawnEdgeRules == Set(SampleEdgeRule.allCases),
            "drawn edge rules: \(drawnEdgeRules.map(\.rawValue).sorted())"
        )
        // Both orientations and the square case, so the short edge was taken from each axis
        // in turn and the equal-axes branch was really entered.
        #expect(
            orientations == ["landscape", "portrait", "square"],
            "generated orientations: \(orientations.sorted())"
        )
        // Upscales, downscales, and the identity resize. The short edge is *assigned* the
        // target, so a source below it, above it, and exactly at it are three different
        // situations for the long edge. The identity has a dimension family of its own so
        // this can be exact equality rather than a hope about the draw.
        #expect(
            shortEdgeRelations == ["downscale", "identity", "upscale"],
            "generated short-edge relations: \(shortEdgeRelations.sorted())"
        )
        #expect(sources.count >= cases / 2, "distinct sources: \(sources.count) of \(cases)")
        // An extreme aspect ratio was really presented, which is where the crop offset is a
        // large number rather than a small one.
        #expect(
            largestResizedLongEdge >= 100_000,
            "largest resized long edge: \(largestResizedLongEdge)"
        )

        // What was actually asserted. The unconditional counters are compared against
        // `cases` rather than a constant: they run on every case, so anything less means a
        // body returned early or threw, and zero against a non-zero `cases` is exactly the
        // silent-throw failure this witness exists to catch.
        #expect(
            referenceComparisons == cases * 10,
            """
            reference comparisons: \(referenceComparisons) of \(cases * 10) \
            (five rounding rules by two offset rules a case)
            """
        )
        #expect(
            comparedRoundings == Set(RoundingRule.allCases),
            "compared rounding rules: \(comparedRoundings.map(\.rawValue).sorted())"
        )
        #expect(
            comparedOffsetRules == Set(CropOffsetRule.allCases),
            "compared offset rules: \(comparedOffsetRules.map(\.rawValue).sorted())"
        )
        #expect(
            ruleRelationChecks == cases,
            "rule-relation checks: \(ruleRelationChecks) of \(cases)"
        )
        #expect(
            invarianceChecks == cases,
            "sampling-rule invariance checks: \(invarianceChecks) of \(cases)"
        )
        // Both leftover parities occurred. The odd one is the only reason the crop offset
        // rule exists, so a run that never produced one never separated the two rules on a
        // real geometry.
        #expect(oddLeftovers >= 1, "odd crop leftovers: \(oddLeftovers)")
        #expect(evenLeftovers >= 1, "even crop leftovers: \(evenLeftovers)")
        // A floor rather than a comparison against `cases`: a square source is one family
        // plus whatever the other families happen to produce, which is a property of the
        // draw. Twenty is well below what an even draw over nine families gives; measured at
        // about 300, which is ten per square case because every case resolves ten geometries.
        #expect(squareChecks >= 20, "square-source checks: \(squareChecks)")
        // Floors for the two pixel arms, for the same reason: whether a case can materialize
        // its resize depends on the dimensions it drew, which the generator does not control.
        // Both floors sit several standard deviations under what an even draw produces —
        // measured between 28 and 44, and between 19 and 30, of 200 across runs on this host
        // — so an unlucky draw passes while a run in which either arm stopped happening
        // fails. Neither is a coverage claim: it is the assertion that the arm ran.
        #expect(
            pixelComparisons >= cases / 25,
            "crop-versus-full-resize comparisons: \(pixelComparisons) of \(cases)"
        )
        #expect(
            modelInputChecks >= cases / 20,
            "model-input productions from the crop: \(modelInputChecks) of \(cases)"
        )
        // The off-by-one half really discriminated. Without it the byte comparison above
        // would be satisfied by any translation-invariant picture, and the offset assertion
        // would prove nothing on exactly those inputs.
        //
        // One per pixel comparison rather than the four shifts each one tries: a
        // single-sample source resizes to a constant image, where every rectangle really is
        // identical and asserting a difference would be asserting something false. Measured
        // at close to four per comparison, so the floor has room while still failing a run
        // where nothing discriminated.
        #expect(
            offsetDiscriminations >= pixelComparisons,
            """
            shifted rectangles that differed: \(offsetDiscriminations), \
            against \(pixelComparisons) pixel comparisons
            """
        )
    }
}
