import DefAIkeDomain
import Testing

@testable import DefAIkeImagePipeline

/// The bilinear resample and the fused crop, over real buffers.
///
/// Requirements 4.4 and 4.5. Every expected sample below is a literal computed by hand from
/// the exact integer weights, not from a second copy of the sampler: the whole risk this
/// step carries is that a slightly wrong weight, convention, or boundary rule produces a
/// perfectly plausible image that no later stage can detect.
///
/// The worked example throughout is a 2-by-2 source upscaled to 4-by-4 with half-pixel
/// centers, which is small enough to state completely. Its per-axis weights over the
/// denominator 8 are:
///
/// ```text
/// destination 0 -> [8, 0]   (both taps fold to source 0 under clamping)
/// destination 1 -> [6, 2]
/// destination 2 -> [2, 6]
/// destination 3 -> [0, 8]
/// ```
@Suite("Bilinear resampling and the fused crop")
struct BilinearResampleTests {
    // MARK: - Harness

    /// A tightly packed surface over exactly `bytes`.
    private func surface(
        width: Int,
        height: Int,
        channelCount: Int,
        bytes: [UInt8]
    ) throws -> PixelSurface {
        try #require(bytes.count == width * height * channelCount, "the fixture must be packed")
        let surface = try PixelSurface.tightlyPacked(
            width: width,
            height: height,
            channelCount: channelCount
        )
        let base = try #require(surface.buffer.data?.assumingMemoryBound(to: UInt8.self))
        for index in bytes.indices { base[index] = bytes[index] }
        return surface
    }

    private func dimensions(_ width: Int, _ height: Int) throws -> PixelDimensions {
        try #require(PixelDimensions(width: width, height: height))
    }

    /// The worked example's 2-by-2 single-channel source.
    private func twoByTwo() throws -> PixelSurface {
        try surface(width: 2, height: 2, channelCount: 1, bytes: [0, 200, 100, 40])
    }

    /// A deterministic, non-flat pattern. Flat data would hide a wrong weight entirely.
    private func pattern(width: Int, height: Int, channelCount: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * channelCount)
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<channelCount {
                    bytes.append(UInt8((x * 29 + y * 61 + channel * 97) % 256))
                }
            }
        }
        return bytes
    }

    // MARK: - Identity

    @Test("A same-size resample returns the source unchanged")
    func identityResampleIsExact() throws {
        // The weights are all zero on the upper tap, so every destination sample is one
        // source sample. Any accumulated fractional error would show up here first.
        for convention in PixelCenterConvention.allCases {
            let bytes = pattern(width: 5, height: 4, channelCount: 3)
            let source = try surface(width: 5, height: 4, channelCount: 3, bytes: bytes)
            let resized = try BilinearResampler.resize(
                source,
                to: try dimensions(5, 4),
                convention: convention,
                edgeRule: .clampToEdge
            )
            #expect(resized.width == 5)
            #expect(resized.height == 4)
            #expect(resized.copyPackedBytes() == bytes, "\(convention.rawValue)")
        }
    }

    @Test("A flat image stays exactly flat under every convention and edge rule")
    func flatImageIsPreserved() throws {
        // The weights on each axis sum to the denominator, so a constant source gives back
        // the same constant with no rounding drift. This is also the sharpest available
        // check that nothing scales, offsets, or normalizes a sample: a `1/255` scaling or
        // a mean subtraction would move a flat 137 somewhere else.
        let bytes = [UInt8](repeating: 137, count: 6 * 7 * 3)
        for convention in PixelCenterConvention.allCases {
            for rule in SampleEdgeRule.allCases {
                let source = try surface(width: 6, height: 7, channelCount: 3, bytes: bytes)
                let resized = try BilinearResampler.resize(
                    source,
                    to: try dimensions(19, 4),
                    convention: convention,
                    edgeRule: rule
                )
                #expect(
                    resized.copyPackedBytes().allSatisfy { $0 == 137 },
                    "\(convention.rawValue) with \(rule.rawValue)"
                )
            }
        }
    }

    // MARK: - The worked example

    @Test("A 2-by-2 upscale produces the hand-computed 4-by-4")
    func upscaleMatchesHandComputedSamples() throws {
        let resized = try BilinearResampler.resize(
            try twoByTwo(),
            to: try dimensions(4, 4),
            convention: .halfPixelCenters,
            edgeRule: .clampToEdge
        )
        // Row 1 column 1 is 3760/64 = 58.75 and rounds to 59; row 2 column 2 is 5040/64 =
        // 78.75 and rounds to 79. Both are the single rounding the sampler performs.
        let expected: [UInt8] = [
            0, 50, 150, 200,
            25, 59, 126, 160,
            75, 76, 79, 80,
            100, 85, 55, 40,
        ]
        #expect(resized.copyPackedBytes() == expected)
    }

    @Test("Each channel is interpolated independently")
    func channelsDoNotMix() throws {
        // Channel 0 is the worked example. Channel 1 varies only down the rows, so its
        // column values must be constant. Channel 2 is constant, so it must not move at
        // all — a channel offset error would show there and nowhere else.
        let source = try surface(
            width: 2,
            height: 2,
            channelCount: 3,
            bytes: [
                0, 10, 77, 200, 10, 77,
                100, 250, 77, 40, 250, 77,
            ]
        )
        let resized = try BilinearResampler.resize(
            source,
            to: try dimensions(4, 4),
            convention: .halfPixelCenters,
            edgeRule: .clampToEdge
        )
        let bytes = resized.copyPackedBytes()
        let redChannel = stride(from: 0, to: bytes.count, by: 3).map { bytes[$0] }
        #expect(
            redChannel == [
                0, 50, 150, 200,
                25, 59, 126, 160,
                75, 76, 79, 80,
                100, 85, 55, 40,
            ]
        )
        // Vertical weights [8,0], [6,2], [2,6], [0,8] over 10 and 250 give exactly
        // 10, 70, 190, 250.
        let greenRows: [UInt8] = [10, 70, 190, 250]
        for row in 0..<4 {
            for column in 0..<4 {
                let offset = (row * 4 + column) * 3
                #expect(bytes[offset + 1] == greenRows[row], "green at (\(column), \(row))")
                #expect(bytes[offset + 2] == 77, "blue at (\(column), \(row))")
            }
        }
    }

    // MARK: - The contract's edge rule

    @Test("Reflect reads a different sample than clamp, and mirror does not")
    func edgeRuleChangesTheOutermostSamples() throws {
        // The first destination sample's lower tap is source index -1 on both axes, with
        // weight 2 of 8. Clamping folds it to 0, so all four taps land on the corner and
        // the sample is that corner's value, 0. Mirroring repeats the boundary sample and
        // folds -1 to 0 as well, so it agrees. Reflecting does not repeat the boundary: it
        // folds -1 to 1 on both axes, so the effective weights become 36, 12, 12, and 4
        // over the four source samples 0, 200, 100, and 40, giving 3760/64 = 58.75, which
        // rounds to 59.
        var samples: [SampleEdgeRule: UInt8] = [:]
        for rule in SampleEdgeRule.allCases {
            let resized = try BilinearResampler.resize(
                try twoByTwo(),
                to: try dimensions(4, 4),
                convention: .halfPixelCenters,
                edgeRule: rule
            )
            samples[rule] = resized.copyPackedBytes()[0]
        }
        #expect(samples[.clampToEdge] == 0)
        #expect(samples[.mirror] == 0)
        #expect(samples[.reflect] == 59)
    }

    @Test("The edge rule is irrelevant when no tap leaves the source")
    func edgeRuleDoesNotAffectInteriorSampling() throws {
        // A downscale with half-pixel centers never reaches outside, so all three rules
        // must produce identical bytes. A rule applied to an in-range index would break
        // this.
        let bytes = pattern(width: 11, height: 9, channelCount: 3)
        var results: [SampleEdgeRule: [UInt8]] = [:]
        for rule in SampleEdgeRule.allCases {
            let source = try surface(width: 11, height: 9, channelCount: 3, bytes: bytes)
            results[rule] = try BilinearResampler.resize(
                source,
                to: try dimensions(5, 4),
                convention: .halfPixelCenters,
                edgeRule: rule
            ).copyPackedBytes()
        }
        #expect(results[.clampToEdge] == results[.mirror])
        #expect(results[.clampToEdge] == results[.reflect])
    }

    // MARK: - The fused crop

    @Test("A sampled window is byte-identical to that window of the full resize")
    func windowEqualsSubRectangleOfFullResize() throws {
        // The claim that lets the resize and the crop run as one pass. Each destination
        // sample depends only on its own coordinate and the source, so producing a subset
        // of the destination samples produces exactly those samples.
        let bytes = pattern(width: 7, height: 5, channelCount: 3)
        let resized = try dimensions(13, 9)
        let window = CropRectangle(x: 3, y: 2, size: try dimensions(5, 4))

        let full = try BilinearResampler.resize(
            try surface(width: 7, height: 5, channelCount: 3, bytes: bytes),
            to: resized,
            convention: .halfPixelCenters,
            edgeRule: .clampToEdge
        )
        let windowed = try BilinearResampler.sample(
            try surface(width: 7, height: 5, channelCount: 3, bytes: bytes),
            resized: resized,
            window: window,
            convention: .halfPixelCenters,
            edgeRule: .clampToEdge
        )

        let fullBytes = full.copyPackedBytes()
        let windowedBytes = windowed.copyPackedBytes()
        #expect(windowed.width == 5)
        #expect(windowed.height == 4)
        for row in 0..<window.size.height {
            for column in 0..<window.size.width {
                for channel in 0..<3 {
                    let fullOffset =
                        ((row + window.y) * resized.width + column + window.x) * 3 + channel
                    let windowedOffset = (row * window.size.width + column) * 3 + channel
                    #expect(
                        windowedBytes[windowedOffset] == fullBytes[fullOffset],
                        "(\(column), \(row)) channel \(channel)"
                    )
                }
            }
        }
    }

    @Test("The window is taken at the contract's centered offset")
    func windowIsPlacedAtTheContractOffset() throws {
        // The whole geometry, end to end, on a source small enough to reason about: a
        // 6-by-8 source resizes to 440-by-587 under half-up rounding, and the crop is
        // 384-by-384 at (28, 101) when the leftover pixel floors.
        let bytes = pattern(width: 6, height: 8, channelCount: 3)
        let source = try surface(width: 6, height: 8, channelCount: 3, bytes: bytes)
        let geometry = try ResizeGeometry.resolve(
            source: source.dimensions,
            resize: try ResizeContract(
                interpolation: .bilinear,
                targetShortEdge: ResizeContract.requiredShortEdge,
                rounding: .halfUp,
                edgeRule: .clampToEdge,
                pixelCenterConvention: .halfPixelCenters
            ),
            crop: try CenterCropContract(
                width: CenterCropContract.requiredEdge,
                height: CenterCropContract.requiredEdge,
                offsetRule: .floorHalfDifference
            )
        )
        let expectedResized = try dimensions(440, 587)
        #expect(geometry.resized == expectedResized)
        #expect(geometry.crop.x == 28)
        #expect(geometry.crop.y == 101)

        let cropped = try BilinearResampler.sample(
            source,
            resized: geometry.resized,
            window: geometry.crop,
            convention: .halfPixelCenters,
            edgeRule: .clampToEdge
        )
        #expect(cropped.width == CenterCropContract.requiredEdge)
        #expect(cropped.height == CenterCropContract.requiredEdge)
        #expect(cropped.isTightlyPacked)
        #expect(cropped.copyPackedBytes().count == 384 * 384 * 3)
    }

    @Test("A window outside the resized image is refused")
    func windowOutsideTheResizedImageIsRefused() throws {
        let source = try surface(
            width: 4,
            height: 4,
            channelCount: 3,
            bytes: pattern(width: 4, height: 4, channelCount: 3)
        )
        let resized = try dimensions(8, 8)
        let outside = [
            CropRectangle(x: 5, y: 0, size: try dimensions(4, 4)),
            CropRectangle(x: 0, y: 5, size: try dimensions(4, 4)),
            CropRectangle(x: -1, y: 0, size: try dimensions(4, 4)),
            CropRectangle(x: 0, y: 0, size: try dimensions(9, 4)),
        ]
        for window in outside {
            #expect(throws: PreprocessingFailure.self) {
                try BilinearResampler.sample(
                    source,
                    resized: resized,
                    window: window,
                    convention: .halfPixelCenters,
                    edgeRule: .clampToEdge
                )
            }
        }
    }

    // MARK: - Refusals

    @Test("An axis plan whose weights are not representable is refused")
    func unrepresentableAxisPlanIsRefused() {
        // The folding rules need `2 * extent` and the interpolation needs the product of
        // the axis denominators. Neither is allowed to wrap: a wrapped weight produces a
        // sample that is in range and wrong.
        #expect(throws: PreprocessingFailure.self) {
            try BilinearResampler.axisPlan(
                destinationIndices: 0..<2,
                sourceExtent: Int.max,
                destinationExtent: 2,
                convention: .halfPixelCenters,
                edgeRule: .clampToEdge
            )
        }
        #expect(throws: PreprocessingFailure.self) {
            try BilinearResampler.axisPlan(
                destinationIndices: 0..<0,
                sourceExtent: 4,
                destinationExtent: 4,
                convention: .halfPixelCenters,
                edgeRule: .clampToEdge
            )
        }
    }

    @Test("An axis plan folds both taps with the contract's edge rule")
    func axisPlanFoldsBothTaps() throws {
        let clamped = try BilinearResampler.axisPlan(
            destinationIndices: 0..<4,
            sourceExtent: 2,
            destinationExtent: 4,
            convention: .halfPixelCenters,
            edgeRule: .clampToEdge
        )
        #expect(clamped.denominator == 8)
        #expect(clamped.taps.map(\.lowerIndex) == [0, 0, 0, 1])
        #expect(clamped.taps.map(\.upperIndex) == [0, 1, 1, 1])
        #expect(clamped.taps.map(\.upperWeight) == [6, 2, 6, 2])

        let reflected = try BilinearResampler.axisPlan(
            destinationIndices: 0..<4,
            sourceExtent: 2,
            destinationExtent: 4,
            convention: .halfPixelCenters,
            edgeRule: .reflect
        )
        // Reflection without a repeated boundary sends -1 to 1 and 2 to 0.
        #expect(reflected.taps.map(\.lowerIndex) == [1, 0, 0, 1])
        #expect(reflected.taps.map(\.upperIndex) == [0, 1, 1, 0])
    }

    @Test("The combined weight bound refuses a product that would wrap")
    func combinedWeightBoundIsChecked() throws {
        let small = BilinearResampler.AxisPlan(taps: [], denominator: 8)
        let huge = BilinearResampler.AxisPlan(taps: [], denominator: Int.max)
        #expect(BilinearResampler.combinedWeightBoundIsRepresentable(small, small))
        #expect(BilinearResampler.combinedWeightBoundIsRepresentable(small, huge) == false)
        #expect(BilinearResampler.combinedWeightBoundIsRepresentable(huge, huge) == false)
    }
}
