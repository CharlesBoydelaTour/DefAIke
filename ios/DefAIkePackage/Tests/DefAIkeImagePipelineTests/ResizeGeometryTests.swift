import DefAIkeDomain
import Testing

@testable import DefAIkeImagePipeline

/// The integer geometry of the deterministic resize and the centered crop.
///
/// Requirements 4.4 and 4.5. Nothing here touches a pixel: the geometry is a pure function
/// of two positive source dimensions and four contract fields, and it is checked in
/// isolation because "exactly 440" and "exactly 384 by 384" are exact claims that a
/// floating-point scale factor cannot deliver.
///
/// Every expected long edge below is stated as a literal computed by hand from
/// `long * 440 / short`, not from a second copy of the implementation's arithmetic.
@Suite("Deterministic resize and crop geometry")
struct ResizeGeometryTests {
    // MARK: - Harness

    private func resize(
        rounding: RoundingRule = .halfUp,
        targetShortEdge: Int = ResizeContract.requiredShortEdge
    ) throws -> ResizeContract {
        try ResizeContract(
            interpolation: .bilinear,
            targetShortEdge: targetShortEdge,
            rounding: rounding,
            edgeRule: .clampToEdge,
            pixelCenterConvention: .halfPixelCenters
        )
    }

    private func crop(offsetRule: CropOffsetRule = .floorHalfDifference) throws -> CenterCropContract
    {
        try CenterCropContract(
            width: CenterCropContract.requiredEdge,
            height: CenterCropContract.requiredEdge,
            offsetRule: offsetRule
        )
    }

    private func dimensions(_ width: Int, _ height: Int) throws -> PixelDimensions {
        try #require(PixelDimensions(width: width, height: height))
    }

    private func geometry(
        _ width: Int,
        _ height: Int,
        rounding: RoundingRule = .halfUp,
        offsetRule: CropOffsetRule = .floorHalfDifference
    ) throws -> ResizeGeometry {
        try ResizeGeometry.resolve(
            source: try dimensions(width, height),
            resize: try resize(rounding: rounding),
            crop: try crop(offsetRule: offsetRule)
        )
    }

    // MARK: - The short edge is exactly the target

    @Test("The short edge is exactly 440 and the long edge scales with it")
    func shortEdgeIsExact() throws {
        // Landscape, portrait, square, and both an upscale and a downscale, because the
        // short edge is assigned rather than computed and that must hold in every one.
        let cases: [(width: Int, height: Int, resized: (Int, Int))] = [
            // 3000 * 440 / 2000 = 660 exactly.
            (3000, 2000, (660, 440)),
            (2000, 3000, (440, 660)),
            // Already at the target: nothing moves.
            (440, 440, (440, 440)),
            // Upscale from below the target: 8 * 440 / 6 = 586.666..., halves up to 587.
            (8, 6, (587, 440)),
            // Extreme aspect ratio: 10000 * 440 / 100 = 44000 exactly.
            (10_000, 100, (44_000, 440)),
        ]
        for testCase in cases {
            let resolved = try geometry(testCase.width, testCase.height)
            let expected = try dimensions(testCase.resized.0, testCase.resized.1)
            #expect(resolved.resized == expected, "\(testCase.width)x\(testCase.height)")
            #expect(resolved.resized.shortEdge == ResizeContract.requiredShortEdge)
        }
    }

    @Test("A square source resizes to the target on both axes")
    func squareSourceIsSquare() throws {
        for edge in [1, 7, 439, 440, 441, 1024] {
            let resolved = try geometry(edge, edge)
            #expect(resolved.resized.width == ResizeContract.requiredShortEdge, "edge \(edge)")
            #expect(resolved.resized.height == ResizeContract.requiredShortEdge, "edge \(edge)")
        }
    }

    @Test("The rounded long edge is within one pixel of the exact ratio")
    func aspectRatioIsPreserved() throws {
        // "Preserve aspect ratio" in integers means the long edge is the exact rational
        // `long * 440 / short` taken to an integer by the contract's rule. Stated as an
        // exact cross-multiplication so no floating-point division enters the assertion.
        for (width, height) in [(3000, 2000), (2000, 3000), (1234, 4321), (17, 5), (5, 17)] {
            let source = try dimensions(width, height)
            let resolved = try geometry(width, height)
            let exactNumerator = source.longEdge * ResizeContract.requiredShortEdge
            let scaled = resolved.resized.longEdge
            #expect(
                abs(scaled * source.shortEdge - exactNumerator) < source.shortEdge,
                "\(width)x\(height): \(scaled) is more than a pixel from the exact ratio"
            )
        }
    }

    // MARK: - The contract's rounding rule

    @Test("Every rounding rule is applied as the contract states it")
    func roundingRulesAreApplied() throws {
        // 881 * 440 / 880 is exactly 440.5, so the three half rules separate. The quotient
        // is 440, which is even, so half-to-even stays down.
        let tieEvenQuotient: [RoundingRule: Int] = [
            .floor: 440,
            .ceiling: 441,
            .halfUp: 441,
            .halfDown: 440,
            .halfToEven: 440,
        ]
        for (rule, expected) in tieEvenQuotient {
            let resolved = try geometry(881, 880, rounding: rule)
            #expect(resolved.resized.width == expected, "881x880 under \(rule.rawValue)")
        }

        // 883 * 440 / 880 is exactly 441.5, whose quotient 441 is odd, so half-to-even
        // goes up. Without both parities the rule is indistinguishable from half-down.
        let tieOddQuotient: [RoundingRule: Int] = [
            .floor: 441,
            .ceiling: 442,
            .halfUp: 442,
            .halfDown: 441,
            .halfToEven: 442,
        ]
        for (rule, expected) in tieOddQuotient {
            let resolved = try geometry(883, 880, rounding: rule)
            #expect(resolved.resized.width == expected, "883x880 under \(rule.rawValue)")
        }

        // 4 * 440 / 3 is 586.666..., which is above the midpoint, so every nearest rule
        // agrees and only flooring differs.
        let aboveMidpoint: [RoundingRule: Int] = [
            .floor: 586,
            .ceiling: 587,
            .halfUp: 587,
            .halfDown: 587,
            .halfToEven: 587,
        ]
        for (rule, expected) in aboveMidpoint {
            let resolved = try geometry(4, 3, rounding: rule)
            #expect(resolved.resized.width == expected, "4x3 under \(rule.rawValue)")
        }

        // 5 * 440 / 3 is 733.333..., below the midpoint, so only ceiling differs.
        let belowMidpoint: [RoundingRule: Int] = [
            .floor: 733,
            .ceiling: 734,
            .halfUp: 733,
            .halfDown: 733,
            .halfToEven: 733,
        ]
        for (rule, expected) in belowMidpoint {
            let resolved = try geometry(5, 3, rounding: rule)
            #expect(resolved.resized.width == expected, "5x3 under \(rule.rawValue)")
        }
    }

    @Test("An exact ratio is unchanged by the rounding rule")
    func exactRatioIgnoresRounding() throws {
        // 3000 * 440 / 2000 = 660 with no remainder, so no rule may move it. A ceiling
        // implemented as "always add one" would fail here and nowhere else.
        for rule in RoundingRule.allCases {
            let resolved = try geometry(3000, 2000, rounding: rule)
            #expect(resolved.resized.width == 660, "3000x2000 under \(rule.rawValue)")
        }
    }

    @Test("A scaled long edge that cannot be computed exactly is refused")
    func overflowingGeometryIsRefused() throws {
        // `Int.max * 440` does not fit. A wrapped product would name a small, plausible,
        // and entirely wrong target size.
        #expect(throws: PreprocessingFailure.self) {
            try ResizeGeometry.resolve(
                source: try #require(PixelDimensions(width: Int.max, height: 1)),
                resize: try resize(),
                crop: try crop()
            )
        }
    }

    // MARK: - The centered crop

    @Test("The crop is exactly 384 by 384 and lies inside the resized image")
    func cropIsExactAndContained() throws {
        for (width, height) in [(3000, 2000), (2000, 3000), (440, 440), (8, 6), (10_000, 100)] {
            let resolved = try geometry(width, height)
            #expect(resolved.crop.size.width == CenterCropContract.requiredEdge)
            #expect(resolved.crop.size.height == CenterCropContract.requiredEdge)
            #expect(
                resolved.crop.isContained(in: resolved.resized),
                "\(width)x\(height): crop at (\(resolved.crop.x), \(resolved.crop.y)) escapes"
            )
        }
    }

    @Test("The offset rule decides the odd leftover pixel and nothing else")
    func offsetRuleDecidesTheOddPixel() throws {
        // 881x880 halves up to 441x440. The short axis leaves 440 - 384 = 56, an even
        // difference both rules split at 28. The long axis leaves 441 - 384 = 57, and that
        // is the one pixel the rule exists for.
        let flooring = try geometry(881, 880, offsetRule: .floorHalfDifference)
        let expected = try dimensions(441, 440)
        #expect(flooring.resized == expected)
        #expect(flooring.crop.x == 28)
        #expect(flooring.crop.y == 28)

        let ceiling = try geometry(881, 880, offsetRule: .ceilingHalfDifference)
        #expect(ceiling.crop.x == 29)
        #expect(ceiling.crop.y == 28, "an even difference is not affected by the rule")
    }

    @Test("Offsets center the crop for every difference the two rules can see")
    func offsetsAreCentered() throws {
        let edge = CenterCropContract.requiredEdge
        for difference in [0, 1, 2, 3, 56, 57, 43_616] {
            let extent = edge + difference
            let flooring = ResizeGeometry.centeredOffset(
                extent: extent,
                crop: edge,
                rule: .floorHalfDifference
            )
            let ceiling = ResizeGeometry.centeredOffset(
                extent: extent,
                crop: edge,
                rule: .ceilingHalfDifference
            )
            #expect(flooring == difference / 2, "difference \(difference)")
            #expect(ceiling == difference - difference / 2, "difference \(difference)")
            // Both leave the crop inside the extent, and they differ by exactly the parity
            // of the difference.
            #expect(flooring >= 0 && flooring + edge <= extent)
            #expect(ceiling >= 0 && ceiling + edge <= extent)
            #expect(ceiling - flooring == difference % 2)
        }
    }

    @Test("A crop larger than the resized image is refused, not clipped")
    func oversizedCropIsRefused() throws {
        // Not reachable from a schema-valid contract, where the crop is 384 and the short
        // edge is 440. Checked directly because the two values arrive from separate
        // contract fields, and clipping would hand the model a buffer smaller than the
        // shape it declares.
        #expect(throws: PreprocessingFailure.self) {
            try ResizeGeometry.centeredCrop(
                in: try #require(PixelDimensions(width: 383, height: 440)),
                crop: try crop()
            )
        }
        #expect(throws: PreprocessingFailure.self) {
            try ResizeGeometry.centeredCrop(
                in: try #require(PixelDimensions(width: 440, height: 100)),
                crop: try crop()
            )
        }
    }

    // MARK: - Sample coordinates

    @Test("Half-pixel centers map a same-size axis to itself exactly")
    func halfPixelIdentity() throws {
        for index in 0..<6 {
            let coordinate = try SampleMapping.coordinate(
                forDestinationIndex: index,
                sourceExtent: 6,
                destinationExtent: 6,
                convention: .halfPixelCenters
            )
            #expect(coordinate.lowerIndex == index)
            #expect(coordinate.upperWeight == 0, "an identity resize has no fractional part")
        }
    }

    @Test("Half-pixel centers read half a pixel outside the source at each end")
    func halfPixelReachesOutside() throws {
        // A 2-to-4 upscale. The first destination sample's lower tap is -1 and the last
        // one's upper tap is 2, which is what the contract's edge rule resolves.
        let expected = [(-1, 6), (0, 2), (0, 6), (1, 2)]
        for (index, expectation) in expected.enumerated() {
            let coordinate = try SampleMapping.coordinate(
                forDestinationIndex: index,
                sourceExtent: 2,
                destinationExtent: 4,
                convention: .halfPixelCenters
            )
            #expect(coordinate.lowerIndex == expectation.0, "index \(index)")
            #expect(coordinate.upperWeight == expectation.1, "index \(index)")
            #expect(coordinate.denominator == 8)
        }
    }

    @Test("Integer pixel centers align the outermost samples")
    func integerPixelCentersAlignEnds() throws {
        // 2 to 4: coordinates 0, 1/3, 2/3, 1. The last destination sample lands exactly on
        // the last source sample, which is the whole difference from half-pixel centers.
        let expected = [(0, 0), (0, 1), (0, 2), (1, 0)]
        for (index, expectation) in expected.enumerated() {
            let coordinate = try SampleMapping.coordinate(
                forDestinationIndex: index,
                sourceExtent: 2,
                destinationExtent: 4,
                convention: .integerPixelCenters
            )
            #expect(coordinate.lowerIndex == expectation.0, "index \(index)")
            #expect(coordinate.upperWeight == expectation.1, "index \(index)")
            #expect(coordinate.denominator == 3)
        }
    }

    @Test("A single-sample destination or source reads coordinate zero")
    func degenerateExtentsReadZero() throws {
        let singleDestination = try SampleMapping.coordinate(
            forDestinationIndex: 0,
            sourceExtent: 9,
            destinationExtent: 1,
            convention: .integerPixelCenters
        )
        #expect(singleDestination.lowerIndex == 0)
        #expect(singleDestination.upperWeight == 0)

        for index in 0..<5 {
            let singleSource = try SampleMapping.coordinate(
                forDestinationIndex: index,
                sourceExtent: 1,
                destinationExtent: 5,
                convention: .integerPixelCenters
            )
            #expect(singleSource.lowerIndex == 0, "index \(index)")
            #expect(singleSource.upperWeight == 0, "index \(index)")
        }
    }

    @Test("A coordinate whose numerator overflows is refused")
    func overflowingCoordinateIsRefused() {
        #expect(throws: PreprocessingFailure.self) {
            try SampleMapping.coordinate(
                forDestinationIndex: 1,
                sourceExtent: Int.max,
                destinationExtent: 4,
                convention: .halfPixelCenters
            )
        }
    }

    @Test("An index outside the destination extent is refused")
    func outOfRangeDestinationIndexIsRefused() {
        for index in [-1, 4] {
            #expect(throws: PreprocessingFailure.self) {
                try SampleMapping.coordinate(
                    forDestinationIndex: index,
                    sourceExtent: 6,
                    destinationExtent: 4,
                    convention: .halfPixelCenters
                )
            }
        }
    }

    @Test("Floor division puts the tap below a negative coordinate")
    func floorDivisionFloors() {
        // Swift's `/` truncates toward zero, which for -2/8 would give tap 0 and a
        // negative weight. The tap has to be the index *below* the coordinate.
        #expect(SampleMapping.floorDivide(-2, by: 8) == (-1, 6))
        #expect(SampleMapping.floorDivide(0, by: 8) == (0, 0))
        #expect(SampleMapping.floorDivide(10, by: 8) == (1, 2))
        #expect(SampleMapping.floorDivide(-8, by: 8) == (-1, 0))
        #expect(SampleMapping.floorDivide(-9, by: 8) == (-2, 7))
    }

    // MARK: - Edge rules

    @Test("Every edge rule stays inside the source for every index")
    func foldingIsTotal() {
        for extent in [1, 2, 5] {
            for rule in SampleEdgeRule.allCases {
                for index in -12...12 {
                    let folded = SampleMapping.foldedIndex(index, extent: extent, rule: rule)
                    #expect(
                        folded >= 0 && folded < extent,
                        "\(rule.rawValue) sent \(index) to \(folded) for extent \(extent)"
                    )
                }
            }
        }
    }

    @Test("An index already inside the source is never moved")
    func insideIndicesAreIdentity() {
        for rule in SampleEdgeRule.allCases {
            for index in 0..<5 {
                #expect(SampleMapping.foldedIndex(index, extent: 5, rule: rule) == index)
            }
        }
    }

    @Test("Clamping and mirroring agree on the one-pixel overshoot bilinear produces")
    func clampAndMirrorAgreeAtOnePixel() {
        // Bilinear interpolation never reaches further than one sample outside the source,
        // and mirroring with the boundary sample repeated sends -1 to 0, which is where
        // clamping sends it. This is why the two rules are indistinguishable for this
        // resize and reflect is the one that actually reads a different sample.
        for extent in [1, 2, 4, 5, 440] {
            for index in [-1, extent] {
                #expect(
                    SampleMapping.foldedIndex(index, extent: extent, rule: .clampToEdge)
                        == SampleMapping.foldedIndex(index, extent: extent, rule: .mirror),
                    "extent \(extent), index \(index)"
                )
            }
        }
    }

    @Test("Each edge rule folds as its own definition states")
    func edgeRulesFoldAsDefined() {
        // Extent 4, samples a b c d.
        // clamp:   ... a a | a b c d | d d ...
        // mirror:  ... b a | a b c d | d c ...   (boundary sample repeated, period 8)
        // reflect: ... c b | a b c d | c b ...   (boundary sample not repeated, period 6)
        let indices = [-3, -2, -1, 0, 1, 2, 3, 4, 5, 6]
        #expect(
            indices.map { SampleMapping.foldedIndex($0, extent: 4, rule: .clampToEdge) }
                == [0, 0, 0, 0, 1, 2, 3, 3, 3, 3]
        )
        #expect(
            indices.map { SampleMapping.foldedIndex($0, extent: 4, rule: .mirror) }
                == [2, 1, 0, 0, 1, 2, 3, 3, 2, 1]
        )
        #expect(
            indices.map { SampleMapping.foldedIndex($0, extent: 4, rule: .reflect) }
                == [3, 2, 1, 0, 1, 2, 3, 2, 1, 0]
        )
    }

    @Test("A single-sample axis folds every index to that sample")
    func singleSampleAxisFolds() {
        // Reflection without a repeated boundary has no period at all here: there is one
        // sample and it is both boundaries.
        for rule in SampleEdgeRule.allCases {
            for index in -4...4 {
                #expect(
                    SampleMapping.foldedIndex(index, extent: 1, rule: rule) == 0,
                    "\(rule.rawValue) at index \(index)"
                )
            }
        }
    }
}
