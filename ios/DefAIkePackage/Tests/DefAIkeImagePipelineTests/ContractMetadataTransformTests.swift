import Accelerate
import DefAIkeDomain
import CoreGraphics
import Foundation
import Testing

@testable import DefAIkeImagePipeline

/// Applying the bound contract's metadata, RGB, color-space, and alpha rules through the
/// real frameworks.
///
/// Requirements 3.7 through 3.11 and 4.3. Every transform below runs through ColorSync
/// and Accelerate against real pixels, because the whole risk this stage carries is that
/// a wrong conversion, rotation, or alpha decision produces a perfectly plausible image
/// that no later stage can detect.
@Suite("Contract metadata, RGB, color, and alpha")
struct ContractMetadataTransformTests {
    // MARK: - Harness

    /// Renders `image` under `contract` and `budget`.
    private func render(
        _ image: CGImage,
        contract: PreprocessingContract = PreprocessingFixture.contract(),
        budget: ResourceBudget = ResourceFixture.budget(),
        metadata: ObservedImageMetadata
    ) -> Result<PixelSurface, AnalysisFault> {
        let renderer = WorkingSpaceRGBRenderer(contract: contract, budget: budget)
        do {
            return .success(
                try renderer.render(DecodedImageFixture.of(image), metadata: metadata)
            )
        } catch {
            return .failure(error)
        }
    }

    /// Metadata stating one condition per field, with everything else absent.
    private func metadata(
        orientation: ImageMetadataState = .absent,
        declaredOrientation: ExifOrientation? = nil,
        colorProfile: ImageMetadataState = .valid,
        alpha: ImageMetadataState = .absent,
        carriesAlphaChannel: Bool = false
    ) -> ObservedImageMetadata {
        ObservedImageMetadata(
            orientation: orientation,
            declaredOrientation: declaredOrientation,
            colorProfile: colorProfile,
            alpha: alpha,
            carriesAlphaChannel: carriesAlphaChannel
        )
    }

    private func fault(_ result: Result<PixelSurface, AnalysisFault>) -> AnalysisFault? {
        guard case .failure(let fault) = result else { return nil }
        return fault
    }

    /// The color bytes of a 32-bit-per-pixel source, with the fourth byte dropped.
    private func colorBytes(of pixels: [UInt8]) -> [UInt8] {
        stride(from: 0, to: pixels.count, by: 4).flatMap { Array(pixels[$0..<($0 + 3)]) }
    }

    private static let preprocessingError = AnalysisFault.analysis(
        .preprocessingError,
        stage: .preprocessing
    )
    private static let resourceLimit = AnalysisFault.analysis(
        .resourceLimit,
        stage: .preprocessing
    )

    // MARK: - Contract totality and action selection

    @Test("A rule list binding a state more than once binds no action")
    func duplicateRuleBindsNothing() {
        // A dictionary lookup over the same data would silently take one of the two. That
        // is the failure mode this check exists for.
        let duplicated: [MetadataStateRules<OrientationAction>.Rule] = [
            .init(state: .valid, action: .applyDeclaredOrientation),
            .init(state: .valid, action: .ignoreDeclaredOrientation),
            .init(state: .absent, action: .ignoreDeclaredOrientation),
            .init(state: .malformed, action: .ignoreDeclaredOrientation),
            .init(state: .unsupported, action: .ignoreDeclaredOrientation),
        ]
        #expect(MetadataActionBinding.soleAction(for: .valid, in: duplicated) == nil)
        #expect(MetadataActionBinding.isTotal(duplicated) == false)
    }

    @Test("A rule list omitting a state binds no action for it")
    func missingRuleBindsNothing() {
        let incomplete: [MetadataStateRules<AlphaAction>.Rule] = [
            .init(state: .valid, action: .discardAlphaChannel),
            .init(state: .absent, action: .discardAlphaChannel),
        ]
        #expect(MetadataActionBinding.soleAction(for: .malformed, in: incomplete) == nil)
        #expect(MetadataActionBinding.soleAction(for: .valid, in: incomplete) != nil)
        #expect(
            MetadataActionBinding.isTotal(incomplete) == false,
            "totality is over all four states, not only the one this input presents"
        )
    }

    @Test("A total rule list binds exactly one action to every state")
    func totalRuleListBindsEveryState() {
        let rules = PreprocessingFixture.rules([
            ImageMetadataState.valid: ColorProfileAction.convertToWorkingSpace,
            .absent: .assignWorkingSpaceWithoutConversion,
            .malformed: .rejectAsPreprocessingError,
            .unsupported: .rejectAsPreprocessingError,
        ]).rules
        #expect(MetadataActionBinding.isTotal(rules))
        #expect(MetadataActionBinding.soleAction(for: .valid, in: rules) == .convertToWorkingSpace)
        #expect(
            MetadataActionBinding.soleAction(for: .absent, in: rules)
                == .assignWorkingSpaceWithoutConversion
        )
    }

    @Test("Binding selects the action for the observed state and no other")
    func bindingFollowsTheObservedState() throws {
        // Three different actions for three different states. If selection ever fell back
        // to a first entry or a nearest state, at least one of these would be wrong.
        let contract = PreprocessingFixture.contract(
            orientationRules: PreprocessingFixture.rules([
                ImageMetadataState.valid: OrientationAction.applyDeclaredOrientation,
                .absent: .ignoreDeclaredOrientation,
                .malformed: .rejectAsPreprocessingError,
                .unsupported: .ignoreDeclaredOrientation,
            ])
        )
        for (state, expected) in [
            (ImageMetadataState.valid, OrientationAction.applyDeclaredOrientation),
            (.absent, .ignoreDeclaredOrientation),
            (.malformed, .rejectAsPreprocessingError),
            (.unsupported, .ignoreDeclaredOrientation),
        ] {
            let bound = try MetadataActionBinding.bind(
                metadata(orientation: state, declaredOrientation: .topLeft),
                contract: contract
            )
            #expect(bound.orientation == expected)
        }
    }

    @Test("Every schema-valid contract binds all four states for all three fields")
    func schemaValidContractsAreTotal() {
        // The schema already makes a gap unrepresentable. This states the property the
        // adapter relies on, so a schema change that relaxed it would fail here rather
        // than turn into a silent implicit default at run time.
        let contract = PreprocessingFixture.contract()
        #expect(MetadataActionBinding.isTotal(contract.orientationRules.rules))
        #expect(MetadataActionBinding.isTotal(contract.colorProfileRules.rules))
        #expect(MetadataActionBinding.isTotal(contract.alphaRules.rules))
        for state in ImageMetadataState.allCases {
            #expect(contract.orientationRules.action(for: state) == .ignoreDeclaredOrientation)
            #expect(contract.colorProfileRules.action(for: state) == .convertToWorkingSpace)
            #expect(contract.alphaRules.action(for: state) == .discardAlphaChannel)
        }
    }

    // MARK: - Refusing a state the contract refuses

    @Test(
        "A contract that refuses the observed orientation state returns preprocessing-error",
        arguments: ImageMetadataState.allCases
    )
    func orientationRefusal(state: ImageMetadataState) {
        let contract = PreprocessingFixture.contract(
            orientation: .rejectAsPreprocessingError
        )
        let image = SourceImageFixture.interleaved32(
            width: 4,
            height: 3,
            pixels: SourceImageFixture.addressablePixels(width: 4, height: 3)
        )
        let result = render(
            image,
            contract: contract,
            metadata: metadata(orientation: state, declaredOrientation: .topLeft)
        )
        #expect(fault(result) == Self.preprocessingError)
    }

    @Test("A contract that refuses the observed profile state returns preprocessing-error")
    func colorProfileRefusal() {
        let contract = PreprocessingFixture.contract(
            colorProfile: .rejectAsPreprocessingError
        )
        let image = SourceImageFixture.interleaved32(
            width: 4,
            height: 3,
            pixels: SourceImageFixture.addressablePixels(width: 4, height: 3)
        )
        #expect(
            fault(render(image, contract: contract, metadata: metadata()))
                == Self.preprocessingError
        )
    }

    @Test("A contract that refuses the observed alpha state returns preprocessing-error")
    func alphaRefusal() {
        let contract = PreprocessingFixture.contract(alpha: .rejectAsPreprocessingError)
        let image = SourceImageFixture.interleaved32(
            width: 4,
            height: 3,
            pixels: SourceImageFixture.addressablePixels(width: 4, height: 3),
            alpha: .last
        )
        #expect(
            fault(
                render(
                    image,
                    contract: contract,
                    metadata: metadata(alpha: .valid, carriesAlphaChannel: true)
                )
            ) == Self.preprocessingError
        )
    }

    @Test("A refusal bound to a state the input does not present does not refuse it")
    func refusalIsScopedToTheObservedState() throws {
        // The whole point of a per-state map: refusing malformed orientation metadata
        // must not refuse an image whose orientation metadata is absent.
        let contract = PreprocessingFixture.contract(
            orientationRules: PreprocessingFixture.rules([
                ImageMetadataState.valid: OrientationAction.applyDeclaredOrientation,
                .absent: .ignoreDeclaredOrientation,
                .malformed: .rejectAsPreprocessingError,
                .unsupported: .rejectAsPreprocessingError,
            ])
        )
        let image = SourceImageFixture.interleaved32(
            width: 4,
            height: 3,
            pixels: SourceImageFixture.addressablePixels(width: 4, height: 3)
        )
        let rendered = try render(
            image,
            contract: contract,
            metadata: metadata(orientation: .absent)
        ).get()
        #expect(rendered.width == 4)
        #expect(rendered.height == 3)

        #expect(
            fault(render(image, contract: contract, metadata: metadata(orientation: .malformed)))
                == Self.preprocessingError
        )
    }

    // MARK: - Working color space

    @Test(
        "Every resolvable identifier names a three-channel RGB space",
        arguments: WorkingColorSpace.Identifier.allCases
    )
    func resolvableIdentifiers(identifier: WorkingColorSpace.Identifier) throws {
        let resolved = try WorkingColorSpace.resolve(
            ColorSpaceDescriptor(
                identifier: try ArtifactText(validating: identifier.rawValue),
                profileDigest: nil
            )
        )
        #expect(resolved.identifier == identifier.rawValue)
        #expect(resolved.colorSpace.model == .rgb)
        #expect(resolved.colorSpace.numberOfComponents == 3)
    }

    @Test(
        "An identifier outside the closed set resolves to nothing",
        arguments: [
            "Fixture RGB working space",
            "kcgcolorspacesrgb",
            "kCGColorSpace-sRGB",
            "sRGB IEC61966-2.1",
            "kCGColorSpaceGenericCMYK",
            "kCGColorSpaceExtendedSRGB",
        ]
    )
    func unresolvableIdentifiers(identifier: String) throws {
        // Case and profile-description spellings are rejected; ``ArtifactText`` already
        // rejects a non-canonical one before it gets here. An extended-range space is
        // rejected on purpose: its values outside [0, 1] are not representable in the
        // contract's unsigned 8-bit model input, so accepting it would mean clamping, which
        // changes pixels.
        let descriptor = ColorSpaceDescriptor(
            identifier: try ArtifactText(validating: identifier),
            profileDigest: nil
        )
        #expect(throws: PreprocessingFailure.self) {
            try WorkingColorSpace.resolve(descriptor)
        }
    }

    @Test("An unresolvable working space returns preprocessing-error, not a substitute")
    func unresolvableWorkingSpaceFailsClosed() {
        let contract = PreprocessingFixture.contract(workingSpace: "Fixture RGB working space")
        let image = SourceImageFixture.interleaved32(
            width: 4,
            height: 3,
            pixels: SourceImageFixture.addressablePixels(width: 4, height: 3)
        )
        #expect(
            fault(render(image, contract: contract, metadata: metadata()))
                == Self.preprocessingError
        )
    }

    @Test("A bound profile digest must match the resolved space's ICC bytes")
    func boundProfileDigestIsVerified() throws {
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let iccData = try #require(sRGB.copyICCData() as Data?)
        let matching = Fixture.digest(of: [UInt8](iccData))

        #expect(WorkingColorSpace.matchesProfile(sRGB, digest: matching))
        #expect(
            WorkingColorSpace.matchesProfile(sRGB, digest: Fixture.digest(of: [0x00])) == false,
            "a digest over other bytes is not agreement"
        )

        let bound = try WorkingColorSpace.resolve(
            ColorSpaceDescriptor(
                identifier: try ArtifactText(validating: "kCGColorSpaceSRGB"),
                profileDigest: matching
            )
        )
        #expect(bound.colorSpace.model == .rgb)
    }

    @Test("A working space whose ICC bytes differ from the bound digest fails closed")
    func mismatchedProfileDigestFailsClosed() throws {
        let contract = PreprocessingFixture.contract(
            workingSpace: "kCGColorSpaceSRGB",
            workingSpaceProfileDigest: Fixture.digest(of: Array("not the sRGB profile".utf8))
        )
        let image = SourceImageFixture.interleaved32(
            width: 4,
            height: 3,
            pixels: SourceImageFixture.addressablePixels(width: 4, height: 3)
        )
        #expect(
            fault(render(image, contract: contract, metadata: metadata()))
                == Self.preprocessingError
        )
    }

    // MARK: - Convert versus assign

    @Test("Converting a Display P3 source into sRGB changes the samples")
    func convertingChangesSamples() throws {
        let pixels: [UInt8] = [
            10, 20, 30, 0, 250, 4, 4, 0,
            4, 250, 4, 0, 4, 4, 250, 0,
        ]
        let image = SourceImageFixture.interleaved32(
            width: 2,
            height: 2,
            pixels: pixels,
            space: SourceImageFixture.displayP3
        )
        let rendered = try render(
            image,
            contract: PreprocessingFixture.contract(colorProfile: .convertToWorkingSpace),
            metadata: metadata()
        ).get()

        #expect(rendered.channelCount == 3)
        #expect(
            rendered.copyPackedBytes() != colorBytes(of: pixels),
            "a P3 primary is not the same sRGB triple, so a real conversion must move it"
        )
    }

    @Test("Assigning the working space leaves the samples byte-identical")
    func assigningPreservesSamples() throws {
        // This is the sharp test for "reinterpret, do not convert": the same source and
        // the same working space as the conversion above, and the bytes must come through
        // untouched.
        let pixels: [UInt8] = [
            10, 20, 30, 0, 250, 4, 4, 0,
            4, 250, 4, 0, 4, 4, 250, 0,
        ]
        let image = SourceImageFixture.interleaved32(
            width: 2,
            height: 2,
            pixels: pixels,
            space: SourceImageFixture.displayP3
        )
        let rendered = try render(
            image,
            contract: PreprocessingFixture.contract(
                colorProfile: .assignWorkingSpaceWithoutConversion
            ),
            metadata: metadata()
        ).get()

        #expect(rendered.copyPackedBytes() == colorBytes(of: pixels))
    }

    @Test("Converting into the source's own space is the identity")
    func convertingIntoTheSameSpaceIsIdentity() throws {
        let pixels = SourceImageFixture.addressablePixels(width: 3, height: 2)
        let image = SourceImageFixture.interleaved32(
            width: 3,
            height: 2,
            pixels: pixels,
            space: SourceImageFixture.sRGB
        )
        let rendered = try render(
            image,
            contract: PreprocessingFixture.contract(colorProfile: .convertToWorkingSpace),
            metadata: metadata()
        ).get()
        #expect(rendered.copyPackedBytes() == colorBytes(of: pixels))
    }

    @Test("A grayscale source converts into neutral RGB")
    func grayscaleConverts() throws {
        let image = SourceImageFixture.grayscale(width: 4, height: 2)
        let rendered = try render(
            image,
            contract: PreprocessingFixture.contract(colorProfile: .convertToWorkingSpace),
            metadata: metadata()
        ).get()

        #expect(rendered.channelCount == 3)
        for y in 0..<2 {
            for x in 0..<4 {
                let pixel = rendered.rgb(x: x, y: y)
                #expect(
                    pixel.red == pixel.green && pixel.green == pixel.blue,
                    "a neutral gray must stay neutral in any RGB working space"
                )
            }
        }
    }

    @Test("A grayscale source cannot be assigned an RGB working space")
    func grayscaleCannotBeAssigned() {
        // Relabelling one gray channel as three RGB channels is not a reinterpretation,
        // it is a conversion with the label removed. The contract said not to convert, so
        // the only honest answer is to refuse.
        let image = SourceImageFixture.grayscale(width: 4, height: 2)
        #expect(
            fault(
                render(
                    image,
                    contract: PreprocessingFixture.contract(
                        colorProfile: .assignWorkingSpaceWithoutConversion
                    ),
                    metadata: metadata()
                )
            ) == Self.preprocessingError
        )
    }

    @Test("A real HEIC or PNG container renders end to end from its own declarations")
    func realContainerRenders() throws {
        let bytes = RawPNG.withSRGBChunk(width: 12, height: 5)
        let source = try #require(EncodedImageSource(bytes: bytes))
        let declarations = source.metadataDeclarations(at: 0)
        let image = try #require(source.decodeCompleteImage(at: 0))
        let observed = ImageMetadataInspector.observe(properties: declarations, image: image)

        let rendered = try render(image, metadata: observed).get()

        #expect(rendered.width == 12)
        #expect(rendered.height == 5)
        #expect(rendered.channelCount == 3)
        #expect(rendered.copyPackedBytes().count == 12 * 5 * 3)
    }

    // MARK: - Alpha

    /// The composite one channel should produce, as an independent reference.
    private func expectedComposite(source: UInt8, alpha: UInt8, background: UInt8) -> Double {
        Double(source) * Double(alpha) / 255 + Double(background) * Double(255 - alpha) / 255
    }

    @Test("Compositing uses the contract's exact background color")
    func compositingUsesTheBoundBackground() throws {
        // A distinctive background, because white and black are the two values an
        // implementation is most likely to have hard-coded and a test against either would
        // not notice.
        let background = OpaqueBackgroundColor(red: 200, green: 100, blue: 50)
        let pixels: [UInt8] = [
            100, 100, 100, 0,  // fully transparent: must become exactly the background
            100, 100, 100, 255,  // fully opaque: must stay exactly the source
            100, 100, 100, 128,  // half: between the two
            40, 160, 240, 64,  // mostly background
        ]
        let image = SourceImageFixture.interleaved32(
            width: 4,
            height: 1,
            pixels: pixels,
            alpha: .last
        )
        let rendered = try render(
            image,
            contract: PreprocessingFixture.contract(
                alpha: .compositeOverOpaqueBackground(background)
            ),
            metadata: metadata(alpha: .valid, carriesAlphaChannel: true)
        ).get()

        let transparent = rendered.rgb(x: 0, y: 0)
        #expect(transparent.red == background.red)
        #expect(transparent.green == background.green)
        #expect(transparent.blue == background.blue)

        let opaque = rendered.rgb(x: 1, y: 0)
        #expect(opaque.red == 100 && opaque.green == 100 && opaque.blue == 100)

        // The two endpoints above are exact. The interior is checked against the
        // reference blend within one code value, because the remaining freedom is
        // Accelerate's internal fixed-point rounding rather than anything the contract
        // fixes.
        for (x, alpha, source) in [
            (2, UInt8(128), [UInt8(100), 100, 100]),
            (3, UInt8(64), [UInt8(40), 160, 240]),
        ] {
            let pixel = rendered.rgb(x: x, y: 0)
            for (channel, actual) in [pixel.red, pixel.green, pixel.blue].enumerated() {
                let expected = expectedComposite(
                    source: source[channel],
                    alpha: alpha,
                    background: [background.red, background.green, background.blue][channel]
                )
                #expect(
                    abs(Double(actual) - expected) <= 1,
                    "channel \(channel) at x=\(x): \(actual) is not within 1 of \(expected)"
                )
            }
        }
    }

    @Test("Discarding alpha keeps the color channels unchanged")
    func discardingAlphaKeepsColorChannels() throws {
        // The reason the working buffer is unpremultiplied. A premultiplied intermediate
        // would have multiplied every channel by its alpha already, so the low-alpha
        // pixels below would come out near black and there would be nothing left to
        // recover the stored samples from.
        let pixels: [UInt8] = [
            100, 150, 200, 0,
            100, 150, 200, 1,
            100, 150, 200, 128,
            100, 150, 200, 255,
        ]
        let image = SourceImageFixture.interleaved32(
            width: 4,
            height: 1,
            pixels: pixels,
            alpha: .last
        )
        let rendered = try render(
            image,
            contract: PreprocessingFixture.contract(alpha: .discardAlphaChannel),
            metadata: metadata(alpha: .valid, carriesAlphaChannel: true)
        ).get()

        #expect(rendered.copyPackedBytes() == colorBytes(of: pixels))
    }

    @Test("A premultiplied source is unpremultiplied before alpha is discarded")
    func premultipliedSourceIsUnpremultiplied() throws {
        // Stored premultiplied: colour 50 at alpha 128 encodes an original near 100.
        // Discarding alpha must recover the colour, not keep the premultiplied product.
        let image = SourceImageFixture.interleaved32(
            width: 2,
            height: 1,
            pixels: [50, 50, 50, 128, 25, 25, 25, 64],
            alpha: .premultipliedLast
        )
        let rendered = try render(
            image,
            contract: PreprocessingFixture.contract(alpha: .discardAlphaChannel),
            metadata: metadata(alpha: .valid, carriesAlphaChannel: true)
        ).get()

        for x in 0..<2 {
            let pixel = rendered.rgb(x: x, y: 0)
            for channel in [pixel.red, pixel.green, pixel.blue] {
                #expect(
                    abs(Int(channel) - 100) <= 1,
                    "a premultiplied 50 at alpha \(x == 0 ? 128 : 64) recovers to about 100"
                )
            }
        }
    }

    @Test("An alpha-first source is read in the right channel order")
    func alphaFirstSourceIsReordered() throws {
        // ARGB stored, RGB expected out. A packing read in the wrong order produces a
        // colour-shifted image that still looks like a photograph.
        let image = SourceImageFixture.interleaved32(
            width: 1,
            height: 1,
            pixels: [255, 10, 20, 30],
            alpha: .first
        )
        let rendered = try render(
            image,
            contract: PreprocessingFixture.contract(alpha: .discardAlphaChannel),
            metadata: metadata(alpha: .valid, carriesAlphaChannel: true)
        ).get()
        #expect(rendered.copyPackedBytes() == [10, 20, 30])
    }

    @Test("With no alpha channel, compositing and discarding agree exactly")
    func noAlphaChannelMakesBothActionsIdentity() throws {
        // Requirement 3.10 conditions compositing on transparency being present. Expressed
        // as a fully opaque alpha channel rather than a skipped branch, so the two actions
        // agree by construction instead of by inspection.
        let pixels = SourceImageFixture.addressablePixels(width: 5, height: 3)
        let image = SourceImageFixture.interleaved32(
            width: 5,
            height: 3,
            pixels: pixels,
            alpha: .noneSkipLast
        )
        let composited = try render(
            image,
            contract: PreprocessingFixture.contract(
                alpha: .compositeOverOpaqueBackground(
                    OpaqueBackgroundColor(red: 7, green: 200, blue: 33)
                )
            ),
            metadata: metadata()
        ).get()
        let discarded = try render(
            image,
            contract: PreprocessingFixture.contract(alpha: .discardAlphaChannel),
            metadata: metadata()
        ).get()

        #expect(composited.copyPackedBytes() == discarded.copyPackedBytes())
        #expect(
            discarded.copyPackedBytes() == colorBytes(of: pixels),
            "the fourth byte of a noneSkipLast source is padding, not opacity"
        )
    }

    // MARK: - Orientation geometry

    @Test(
        "Applying a declared orientation matches the reference coordinate mapping",
        arguments: ExifOrientation.allCases
    )
    func orientationMatchesTheReference(orientation: ExifOrientation) throws {
        // Non-square and non-symmetric, so a transpose, a mirror, and a rotation are all
        // distinguishable from one another and from the identity.
        let width = 5
        let height = 3
        let pixels = SourceImageFixture.addressablePixels(width: width, height: height)
        let image = SourceImageFixture.interleaved32(
            width: width,
            height: height,
            pixels: pixels
        )
        let rendered = try render(
            image,
            contract: PreprocessingFixture.contract(
                orientation: .applyDeclaredOrientation,
                // Assigned rather than converted, so the assertion is over exactly the
                // bytes that were written and no colour transform is in the way.
                colorProfile: .assignWorkingSpaceWithoutConversion
            ),
            metadata: metadata(orientation: .valid, declaredOrientation: orientation)
        ).get()

        let expectedSize = OrientationReference.displayedSize(
            orientation,
            width: width,
            height: height
        )
        #expect(rendered.width == expectedSize.width)
        #expect(rendered.height == expectedSize.height)

        for y in 0..<height {
            for x in 0..<width {
                let destination = OrientationReference.displayedCoordinate(
                    orientation,
                    x: x,
                    y: y,
                    width: width,
                    height: height
                )
                let source = (y * width + x) * 4
                let moved = rendered.rgb(x: destination.x, y: destination.y)
                #expect(
                    moved == (pixels[source], pixels[source + 1], pixels[source + 2]),
                    """
                    orientation \(orientation.rawValue): stored (\(x), \(y)) belongs at \
                    (\(destination.x), \(destination.y))
                    """
                )
            }
        }
    }

    @Test("A permutation refuses a surface that is not four-channel")
    func permutationRequiresTheWorkingChannelCount() throws {
        // The vImage permutations are the four-channel 8-bit ones and their background
        // pointer is four bytes wide. Run over three-channel data they would read past it
        // and stride rows wrongly, producing a sheared image rather than a failure.
        let threeChannel = try PixelSurface.tightlyPacked(width: 4, height: 3, channelCount: 3)
        #expect(throws: PreprocessingFailure.self) {
            try WorkingSpaceRGBRenderer.permute(threeChannel, by: .reflectHorizontally)
        }
        let fourChannel = try PixelSurface.tightlyPacked(width: 4, height: 3, channelCount: 4)
        let rotated = try WorkingSpaceRGBRenderer.permute(
            fourChannel,
            by: .rotateCounterclockwise(quarterTurns: 1)
        )
        #expect(rotated.width == 3)
        #expect(rotated.height == 4)
    }

    @Test(
        "A quarter-turn count outside 1 through 3 is refused",
        arguments: [0, 4, -1]
    )
    func invalidQuarterTurnCountIsRefused(quarterTurns: Int) throws {
        // Nothing in the orientation table produces such a count. The guard exists because
        // vImage takes the count as a byte, so a wrapped value would rotate the image by an
        // amount nobody asked for.
        let surface = try PixelSurface.tightlyPacked(width: 4, height: 3, channelCount: 4)
        #expect(throws: PreprocessingFailure.self) {
            try WorkingSpaceRGBRenderer.permute(
                surface,
                by: .rotateCounterclockwise(quarterTurns: quarterTurns)
            )
        }
    }

    @Test(
        "The axis-exchange rule agrees with the step list",
        arguments: ExifOrientation.allCases
    )
    func axisExchangeAgreesWithTheSteps(orientation: ExifOrientation) {
        // The buffer size comes from `exchangesAxes` and the permutation from `steps`.
        // They are stated separately so a disagreement is detectable; this is where it
        // would be detected.
        let exchangedBySteps = orientation.steps.filter(\.exchangesAxes).count % 2 == 1
        #expect(orientation.exchangesAxes == exchangedBySteps)
        #expect(orientation.steps.count <= 2)
    }

    @Test("Ignoring the declared orientation leaves stored pixel order untouched")
    func ignoringOrientationKeepsStoredOrder() throws {
        let pixels = SourceImageFixture.addressablePixels(width: 5, height: 3)
        let image = SourceImageFixture.interleaved32(width: 5, height: 3, pixels: pixels)
        let rendered = try render(
            image,
            contract: PreprocessingFixture.contract(
                orientation: .ignoreDeclaredOrientation,
                colorProfile: .assignWorkingSpaceWithoutConversion
            ),
            // A declared orientation is present and must be disregarded.
            metadata: metadata(orientation: .valid, declaredOrientation: .rightTop)
        ).get()

        #expect(rendered.width == 5)
        #expect(rendered.height == 3)
        #expect(rendered.copyPackedBytes() == colorBytes(of: pixels))
    }

    @Test(
        "Applying a declared orientation that does not exist fails closed",
        arguments: [ImageMetadataState.absent, .malformed, .unsupported]
    )
    func applyingAnAbsentOrientationFailsClosed(state: ImageMetadataState) {
        // The tempting reading is "no declaration means upright". That would silently
        // analyze a sideways image, so the contract asking for a declaration the input
        // does not carry is an error instead.
        let image = SourceImageFixture.interleaved32(
            width: 4,
            height: 3,
            pixels: SourceImageFixture.addressablePixels(width: 4, height: 3)
        )
        let result = render(
            image,
            contract: PreprocessingFixture.contract(orientation: .applyDeclaredOrientation),
            metadata: metadata(orientation: state)
        )
        #expect(fault(result) == Self.preprocessingError)
    }

    @Test("Orientation is applied after the colour conversion with the same result")
    func orientationCommutesWithConversion() throws {
        // The renderer converts before it orients, which the design lists the other way
        // round. A per-pixel function and a coordinate permutation commute exactly, and
        // this is that claim under test: rotating a converted image and converting a
        // rotated one produce the same bytes.
        let width = 4
        let height = 3
        let pixels = SourceImageFixture.addressablePixels(width: width, height: height)
        let image = SourceImageFixture.interleaved32(
            width: width,
            height: height,
            pixels: pixels,
            space: SourceImageFixture.displayP3
        )
        let contract = PreprocessingFixture.contract(
            orientation: .applyDeclaredOrientation,
            colorProfile: .convertToWorkingSpace
        )
        let convertedThenOriented = try render(
            image,
            contract: contract,
            metadata: metadata(orientation: .valid, declaredOrientation: .rightTop)
        ).get()

        // The other order, built by hand: convert with no orientation, then permute.
        let convertedOnly = try render(
            image,
            contract: PreprocessingFixture.contract(
                orientation: .ignoreDeclaredOrientation,
                colorProfile: .convertToWorkingSpace
            ),
            metadata: metadata(orientation: .valid, declaredOrientation: .rightTop)
        ).get()

        #expect(convertedThenOriented.width == height)
        #expect(convertedThenOriented.height == width)
        for y in 0..<height {
            for x in 0..<width {
                let destination = OrientationReference.displayedCoordinate(
                    .rightTop,
                    x: x,
                    y: y,
                    width: width,
                    height: height
                )
                #expect(
                    convertedThenOriented.rgb(x: destination.x, y: destination.y)
                        == convertedOnly.rgb(x: x, y: y)
                )
            }
        }
    }

    // MARK: - Output shape

    @Test("The rendered surface is tightly packed three-channel RGB")
    func renderedSurfaceIsPackedRGB() throws {
        // Tight packing is what makes the bytes readable as one contiguous sequence.
        // A width whose row is not a multiple of any natural alignment is used on purpose:
        // vImage would pad it, and a padded buffer read as packed shears the image.
        let width = 13
        let height = 7
        let rendered = try render(
            SourceImageFixture.interleaved32(
                width: width,
                height: height,
                pixels: SourceImageFixture.addressablePixels(width: width, height: height)
            ),
            metadata: metadata()
        ).get()

        #expect(rendered.channelCount == WorkingSpaceRGBRenderer.renderedChannelCount)
        #expect(rendered.isTightlyPacked)
        #expect(rendered.rowBytes == width * 3)
        #expect(rendered.copyPackedBytes().count == width * height * 3)
        #expect(rendered.dimensions == PixelDimensions(width: width, height: height))
    }

    // MARK: - Resource bounding

    @Test("An allocation above the memory budget returns resource-limit")
    func allocationOverBudget() {
        // `resource-limit`, not `preprocessing-error`: Requirement 3.4 gives a budget
        // refusal its own category, and reporting the contract as inapplicable would send
        // an audit looking for a contract defect.
        let budget = ResourceFixture.budget(
            overrides: [.peakResidentMemory: ResourceFixture.numeric(512, .bytes)]
        )
        let image = SourceImageFixture.interleaved32(
            width: 8,
            height: 6,
            pixels: SourceImageFixture.addressablePixels(width: 8, height: 6)
        )
        #expect(fault(render(image, budget: budget, metadata: metadata())) == Self.resourceLimit)
    }

    @Test("A memory limit in the wrong unit fails closed with resource-limit")
    func mismatchedMemoryUnitFailsClosed() {
        let budget = ResourceFixture.budget(
            overrides: [.peakResidentMemory: ResourceFixture.numeric(1_000_000, .milliseconds)]
        )
        let image = SourceImageFixture.interleaved32(
            width: 8,
            height: 6,
            pixels: SourceImageFixture.addressablePixels(width: 8, height: 6)
        )
        #expect(fault(render(image, budget: budget, metadata: metadata())) == Self.resourceLimit)
    }

    @Test("An inapplicable contract is reported before the budget is consulted")
    func contractIsCheckedBeforeTheBudget() {
        // Both would refuse this render. The contract is checked first, because a contract
        // this build cannot apply is a defect in the release configuration and should not
        // be reported as the device running out of room. A budget-only refusal keeps
        // `resource-limit`, which the two tests above establish.
        let budget = ResourceFixture.budget(
            overrides: [.peakResidentMemory: ResourceFixture.numeric(1, .bytes)]
        )
        let contract = PreprocessingFixture.contract(workingSpace: "kCGColorSpaceExtendedSRGB")
        let image = SourceImageFixture.interleaved32(
            width: 8,
            height: 6,
            pixels: SourceImageFixture.addressablePixels(width: 8, height: 6)
        )
        #expect(
            fault(render(image, contract: contract, budget: budget, metadata: metadata()))
                == Self.preprocessingError
        )
        // Same budget, applicable contract: now the budget is what refuses it.
        #expect(fault(render(image, budget: budget, metadata: metadata())) == Self.resourceLimit)
    }

    // MARK: - Cancellation

    @Test("A cancelled session returns cancelled rather than an error category")
    func cancellationIsNotAnError() async {
        // The image is built inside the task: a `CGImage` and a ``PixelSurface`` are
        // framework-owned memory that never crosses an isolation boundary, which is the
        // same rule the adapter itself follows. Only the fault comes back out.
        let task = Task { () -> AnalysisFault? in
            let image = SourceImageFixture.interleaved32(
                width: 8,
                height: 6,
                pixels: SourceImageFixture.addressablePixels(width: 8, height: 6)
            )
            guard case .failure(let fault) = self.render(image, metadata: self.metadata())
            else {
                return nil
            }
            return fault
        }
        task.cancel()

        guard let fault = await task.value else {
            // Losing the cancellation race is acceptable: the claim is that a cancelled
            // render never reports an Analysis Error, not that cancellation always wins.
            return
        }
        #expect(fault == .cancelled)
        #expect(fault.analysisError == nil)
    }

    // MARK: - Failure classification

    @Test("Only a budget refusal and cancellation escape the preprocessing-error category")
    func faultMapping() {
        let contractFailures: [PreprocessingFailure] = [
            .metadataRuleNotTotal(field: "alphaRules"),
            .actionRejectsObservedState(field: "alphaRules", state: .valid),
            .declaredOrientationUnavailable(state: .absent),
            .workingColorSpaceUnavailable(identifier: "x"),
            .workingColorSpaceNotThreeChannelRGB(identifier: "x"),
            .workingColorSpaceProfileMismatch(identifier: "x"),
            .sourceSamplesNotAssignable(reason: "x"),
            .frameworkOperationFailed(operation: "x", code: -1),
            .bufferUnavailable(width: 1, height: 1, channelCount: 3),
            .orientedGeometryMismatch(
                expected: PixelDimensions(width: 1, height: 2)!,
                produced: PixelDimensions(width: 2, height: 1)!
            ),
        ]
        for failure in contractFailures {
            #expect(failure.fault == Self.preprocessingError, "\(failure) must be one category")
        }
        #expect(
            PreprocessingFailure.resourceBreach(.exceeded(.peakResidentMemory)).fault
                == Self.resourceLimit
        )
        #expect(PreprocessingFailure.cancelled.fault == .cancelled)
        #expect(PreprocessingFailure.cancelled.fault.analysisError == nil)
    }
}
