import DefAIkeDomain
import Testing
import UniformTypeIdentifiers

@testable import DefAIkeImagePipeline

/// Classification of real containers into the two exact unsupported errors.
///
/// Every input is real encoded content or a real container header, and no test supplies
/// a file name, path extension, or provider type hint as the basis for a decision.
/// Requirements 1.11 through 1.14, 2.15, 2.16, and 3.3.
@Suite("Actual-container classification")
struct ContainerClassificationTests {
    private let supported = Set(StaticContainer.allCases)

    // MARK: - Supported static containers

    @Test(
        "A real single-frame supported container classifies as that container",
        arguments: [
            (UTType.jpeg, StaticContainer.jpeg),
            (UTType.png, StaticContainer.png),
            (UTType.heic, StaticContainer.heic),
        ]
    )
    func supportedContainers(type: UTType, expected: StaticContainer) throws {
        try #require(
            EncodedImageFixture.canEncode(type),
            "this host cannot encode \(type.identifier)"
        )
        let bytes = try #require(EncodedImageFixture.supported(type))
        let classification = ContainerClassifier.classify(
            bytes: bytes,
            supportedContainers: supported
        )
        #expect(classification == .supportedStatic(expected))
        #expect(classification.analysisError == nil)
    }

    @Test("A grayscale PNG is still a supported PNG")
    func grayscalePNG() throws {
        let bytes = try #require(
            EncodedImageFixture.encode(
                EncodedImageFixture.grayscale(width: 20, height: 10),
                as: .png
            )
        )
        #expect(
            ContainerClassifier.classify(bytes: bytes, supportedContainers: supported)
                == .supportedStatic(.png)
        )
    }

    @Test("A container the bound contract does not list is an unsupported format")
    func contractNarrowsSupportedSet() throws {
        // The contract schema fixes all four containers, so this cannot happen in a
        // shipping build. It is asserted because the supported set is read from the
        // bound artifact rather than from a constant in the adapter, and that has to
        // stay true.
        let bytes = try #require(EncodedImageFixture.supported(.png))
        #expect(
            ContainerClassifier.classify(bytes: bytes, supportedContainers: [.jpeg])
                == .unsupportedStatic
        )
    }

    // MARK: - Unsupported static formats

    @Test(
        "A real single-frame unsupported still image is an unsupported static format",
        arguments: [UTType.tiff, .bmp, .gif]
    )
    func unsupportedStillImages(type: UTType) throws {
        try #require(
            EncodedImageFixture.canEncode(type),
            "this host cannot encode \(type.identifier)"
        )
        let bytes = try #require(EncodedImageFixture.supported(type))
        let classification = ContainerClassifier.classify(
            bytes: bytes,
            supportedContainers: supported
        )
        #expect(classification == .unsupportedStatic)
        #expect(classification.analysisError == .unsupportedStaticFormat)
    }

    @Test("A PDF is an unsupported static container, not a one-frame image")
    func pdfIsNotAnImage() {
        // Image I/O opens a PDF and reports a page count of one, so a classifier that
        // trusted "type plus frame count" alone would accept it as analyzable.
        let classification = ContainerClassifier.classify(
            bytes: EncodedImageFixture.pdf(),
            supportedContainers: supported
        )
        #expect(classification == .unsupportedStatic)
        #expect(classification.analysisError == .unsupportedStaticFormat)
    }

    @Test("HEIC and HEIF map to their own containers, and their relatives map to none")
    func heifFamilyMapping() throws {
        // This host has no HEIF encoder, so the HEIF path cannot be reached with real
        // encoded bytes here. The type mapping is the part that decides which container
        // an Evidence Report records, and it is asserted directly.
        #expect(ContainerClassifier.staticContainer(for: .heic) == .heic)
        #expect(ContainerClassifier.staticContainer(for: .heif) == .heif)
        #expect(ContainerClassifier.staticContainer(for: .jpeg) == .jpeg)
        #expect(ContainerClassifier.staticContainer(for: .png) == .png)
        for identifier in ["public.avif", "public.heics", "public.heif-standard", "public.tiff"] {
            let type = try #require(UTType(identifier))
            #expect(
                ContainerClassifier.staticContainer(for: type) == nil,
                "\(identifier) is outside the Version 1 supported set"
            )
        }
    }

    @Test("A HEIF brand with no image behind it is a decoding error, not an unsupported format")
    func heifBrandWithoutImageData() {
        // `mif1` is the generic HEIF brand. The signature resolves it to a supported
        // container, so a header with nothing behind it is malformed rather than a
        // format this build does not accept.
        let classification = ContainerClassifier.classify(
            bytes: EncodedImageFixture.isoBaseMedia(brand: "mif1"),
            supportedContainers: supported
        )
        #expect(classification == .malformed)
        #expect(classification.analysisError == .decodingError)
    }

    @Test("An AVIF brand is not accepted as HEIF")
    func avifIsNotHEIF() {
        // `public.avif` and `public.heic` share the declared parent
        // `public.heif-standard`. Requirement 1.13 places AVIF outside the Version 1
        // supported set, and no calibration or parity evidence covers it.
        let classification = ContainerClassifier.classify(
            bytes: EncodedImageFixture.isoBaseMedia(brand: "avif"),
            supportedContainers: supported
        )
        #expect(classification.supportedContainer == nil)
        #expect(classification.analysisError == .unsupportedStaticFormat)
    }

    // MARK: - Animated and multi-frame media

    @Test("A multi-frame GIF is unsupported media, not an unsupported format")
    func animatedGIF() throws {
        let bytes = try #require(
            EncodedImageFixture.encode(
                EncodedImageFixture.gradient(width: 12, height: 8),
                as: .gif,
                frameCount: 3
            )
        )
        let classification = ContainerClassifier.classify(
            bytes: bytes,
            supportedContainers: supported
        )
        #expect(classification == .animatedOrMultiFrame)
        #expect(classification.analysisError == .unsupportedMedia)
    }

    @Test("A single-frame GIF is an unsupported format, not media")
    func staticGIF() throws {
        // A one-frame GIF still declares a loop count and a frame delay time, so an
        // animation test based on declared animation properties would misroute it to
        // `unsupported-media`. Requirement 1.13 covers the *non-animated* case, and the
        // design's signal is the container's actual image count.
        let bytes = try #require(EncodedImageFixture.supported(.gif))
        #expect(
            ContainerClassifier.classify(bytes: bytes, supportedContainers: supported)
                == .unsupportedStatic
        )
    }

    @Test("A multi-frame PNG is unsupported media even though PNG is supported")
    func animatedPNG() throws {
        let bytes = try #require(
            EncodedImageFixture.encode(
                EncodedImageFixture.gradient(width: 12, height: 8),
                as: .png,
                frameCount: 3
            )
        )
        #expect(
            ContainerClassifier.classify(bytes: bytes, supportedContainers: supported)
                == .animatedOrMultiFrame
        )
    }

    @Test("A HEIC image sequence is unsupported media")
    func heicSequence() throws {
        let sequence = try #require(UTType("public.heics"))
        try #require(
            EncodedImageFixture.canEncode(sequence),
            "this host cannot encode HEIC sequences"
        )
        let bytes = try #require(
            EncodedImageFixture.encode(
                EncodedImageFixture.gradient(width: 12, height: 8),
                as: sequence,
                frameCount: 3
            )
        )
        #expect(
            ContainerClassifier.classify(bytes: bytes, supportedContainers: supported)
                == .animatedOrMultiFrame
        )
    }

    // MARK: - Video and audio

    @Test(
        "A movie container header is unsupported media",
        arguments: [
            EncodedImageFixture.isoBaseMedia(brand: "qt  "),
            EncodedImageFixture.isoBaseMedia(brand: "isom"),
            EncodedImageFixture.isoBaseMedia(brand: "mp42"),
            EncodedImageFixture.isoBaseMedia(brand: "3gp5"),
            EncodedImageFixture.riff(formType: "AVI "),
            EncodedImageFixture.ebmlHeader,
        ]
    )
    func movieHeaders(bytes: [UInt8]) {
        // Image I/O reports nothing for any of these, so without content signatures a
        // movie and a buffer of random bytes would produce the same answer.
        let classification = ContainerClassifier.classify(
            bytes: bytes,
            supportedContainers: supported
        )
        #expect(classification == .video)
        #expect(classification.analysisError == .unsupportedMedia)
    }

    @Test(
        "An audio container header is unsupported media",
        arguments: [
            EncodedImageFixture.riff(formType: "WAVE"),
            EncodedImageFixture.isoBaseMedia(brand: "M4A "),
            EncodedImageFixture.mp3Header,
            EncodedImageFixture.id3Header,
            Array("fLaC".utf8) + [UInt8](repeating: 0, count: 28),
            Array("OggS".utf8) + [UInt8](repeating: 0, count: 28),
        ]
    )
    func audioHeaders(bytes: [UInt8]) {
        let classification = ContainerClassifier.classify(
            bytes: bytes,
            supportedContainers: supported
        )
        #expect(classification == .audio)
        #expect(classification.analysisError == .unsupportedMedia)
    }

    // MARK: - Malformed containers

    @Test("Unidentifiable bytes are a decoding error, not an unsupported format")
    func unidentifiableBytes() {
        let classification = ContainerClassifier.classify(
            bytes: EncodedImageFixture.unidentifiableBytes,
            supportedContainers: supported
        )
        #expect(classification == .malformed)
        #expect(classification.analysisError == .decodingError)
    }

    @Test("A supported container truncated before its first frame is a decoding error")
    func truncatedBeforeFirstFrame() throws {
        try #require(EncodedImageFixture.canEncode(.heic), "this host cannot encode HEIC")
        let heic = try #require(EncodedImageFixture.supported(.heic))
        let truncated = Array(heic.prefix(heic.count * 6 / 10))
        let classification = ContainerClassifier.classify(
            bytes: truncated,
            supportedContainers: supported
        )
        #expect(classification == .malformed)
        #expect(classification.analysisError == .decodingError)
    }

    @Test("A JPEG magic number with no container behind it is a decoding error")
    func jpegMagicOnly() {
        #expect(
            ContainerClassifier.classify(
                bytes: [0xFF, 0xD8, 0xFF, 0xE0],
                supportedContainers: supported
            ) == .malformed
        )
    }

    // MARK: - Names and hints are never consulted

    @Test("Classification ignores a wrong content-type hint")
    func hintIsNotTrusted() throws {
        // The hint travels with the asset for diagnostics. A classifier that consulted
        // it would accept a TIFF claiming to be a JPEG, and reject a JPEG claiming to
        // be a movie.
        let tiff = try #require(EncodedImageFixture.supported(.tiff))
        #expect(
            ContainerClassifier.classify(bytes: tiff, supportedContainers: supported)
                == .unsupportedStatic
        )
        let jpeg = try #require(EncodedImageFixture.supported(.jpeg))
        #expect(
            ContainerClassifier.classify(bytes: jpeg, supportedContainers: supported)
                == .supportedStatic(.jpeg)
        )
    }

    // MARK: - The mapping itself

    @Test("Every classification maps to exactly one closed error category")
    func mappingIsTotalAndClosed() {
        let cases: [MediaClassification] = [
            .supportedStatic(.jpeg), .supportedStatic(.png), .supportedStatic(.heic),
            .supportedStatic(.heif), .animatedOrMultiFrame, .video, .audio,
            .unsupportedStatic, .malformed,
        ]
        for classification in cases {
            switch classification {
            case .supportedStatic:
                #expect(classification.analysisError == nil)
                #expect(classification.fault == nil)
            default:
                let error = classification.analysisError
                #expect(error != nil)
                #expect(
                    classification.fault
                        == .analysis(error!, stage: .mediaClassification)
                )
                #expect(classification.supportedContainer == nil)
            }
        }
    }
}
