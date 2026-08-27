import DefAIkeDomain

// What the actual bytes turned out to be.
//
// Requirements 1.11 through 1.14, 2.15, and 2.16 divide everything DefAIke can be
// handed into exactly three outcomes: one of the four Supported Static Image
// containers, `unsupported-media`, or `unsupported-static-format`. Requirement 3.3
// adds a fourth for bytes that are not a readable container at all.
//
// The classification is a value rather than a thrown error so the decision and its
// mapping to a closed error category are separately inspectable, and so a test can
// assert the classification of a real container without also asserting the shape of
// a fault.

/// The actual media family of one retained encoded byte sequence.
///
/// Every case except ``supportedStatic(_:)`` maps to exactly one ``AnalysisError``,
/// and the mapping is total, so a classified input can never continue to
/// preprocessing, provenance, or inference without being a supported static image.
public enum MediaClassification: Hashable, Sendable {
    /// A single-frame image in one of the containers the bound contract supports.
    case supportedStatic(StaticContainer)

    /// Animated or multi-frame image content: an animated GIF, an APNG with more
    /// than one frame, a HEIC image sequence, a multi-page TIFF.
    ///
    /// The design's rule is the container's actual image count, not a declared loop
    /// count or frame delay: a single-frame GIF carries a loop count and a delay
    /// time too, and Requirement 1.13 classifies a *non-animated* unsupported
    /// static image as `unsupported-static-format` rather than as media.
    case animatedOrMultiFrame

    /// Video content.
    case video

    /// Audio content.
    case audio

    /// A single-frame static container outside the contract's supported set: TIFF,
    /// BMP, WebP, a static GIF, JPEG 2000, a camera raw, a PDF.
    case unsupportedStatic

    /// Bytes that are not a readable container: truncated before any frame exists,
    /// structurally invalid, or of no identifiable type.
    case malformed

    /// The supported container, or `nil` for every non-analyzable classification.
    public var supportedContainer: StaticContainer? {
        guard case .supportedStatic(let container) = self else { return nil }
        return container
    }

    /// The single Analysis Error this classification produces, or `nil` when the
    /// input is a supported static image and validation continues.
    ///
    /// Animated, video, and audio content share `unsupported-media` because
    /// Requirement 1.11 names the three together; the classification stays distinct
    /// so a diagnostic can say which one was found without widening the closed
    /// user-facing vocabulary.
    public var analysisError: AnalysisError? {
        switch self {
        case .supportedStatic: nil
        case .animatedOrMultiFrame, .video, .audio: .unsupportedMedia
        case .unsupportedStatic: .unsupportedStaticFormat
        case .malformed: .decodingError
        }
    }

    /// The fault this classification raises, or `nil` when validation continues.
    ///
    /// Container classification and the decode that follows it are separate stages
    /// (``AnalysisStage/mediaClassification`` and
    /// ``AnalysisStage/inputValidation``), so a malformed container found while
    /// classifying reports the stage that found it.
    public var fault: AnalysisFault? {
        guard let error = analysisError else { return nil }
        return .analysis(error, stage: .mediaClassification)
    }
}
