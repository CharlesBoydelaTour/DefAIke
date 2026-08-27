// The validation and preprocessing ports.
//
// Both adapters live in `DefAIkeImagePipeline` and use Image I/O, Core Graphics,
// ColorSync, and Accelerate. Neither framework appears in these signatures: the ports
// exchange geometry, container classification, quality measurements, and opaque
// tokens, so the total-metadata-map, geometry, and short-circuit properties run
// without decoding a real image (Properties 3, 8, 9, 10, and 12).

/// Pre-orientation decoded pixel dimensions.
///
/// These are the actual decoded values recorded **before** orientation metadata is
/// applied, which is what Requirements 3.5 and 3.6 fix. Orientation is applied later
/// by the Preprocessing Contract; a record whose dimensions were swapped by
/// orientation handling would silently change the short edge and therefore the
/// sub-440 abstention decision.
public struct PixelDimensions: Hashable, Sendable {
    public let width: Int
    public let height: Int

    /// Creates dimensions, or `nil` when either value is not positive.
    public init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
    }

    /// Exactly `min(width, height)` of the unswapped values (Requirement 3.6).
    public var shortEdge: Int { min(width, height) }

    /// Exactly `max(width, height)` of the unswapped values.
    public var longEdge: Int { max(width, height) }

    /// Total pixel count, in a width wide enough that the product cannot overflow.
    ///
    /// `Int` multiplication of two attacker-influenced declared dimensions is exactly
    /// the overflow Requirement 3.3 requires rejecting before allocation, so the
    /// product is computed in `UInt64` and never in `Int`.
    public var pixelCount: UInt64 { UInt64(width) * UInt64(height) }
}

/// One image that decoded completely and passed every bounded check.
///
/// A value of this type is the proof Requirement 3.1 asks for: it exists only after
/// all image data the bound Preprocessing Contract requires has decoded successfully
/// and every declared-dimension, pixel-count, memory, and storage check has passed.
/// Inference cannot begin without one, so "complete validation precedes inference" is
/// structural rather than an ordering convention (Property 8).
public struct ValidatedImage: Hashable, Sendable {
    public let sessionID: AnalysisSessionID

    /// The retained encoded bytes this image decoded from. Still the identical
    /// sequence the Provenance Analyzer inspects (Requirements 2.12 and 2.13).
    public let source: EncodedAssetHandle

    /// The actual container, established by sniffing content rather than by trusting
    /// a name or a provider hint (Requirement 3.1).
    public let container: StaticContainer

    /// Actual decoded dimensions before orientation metadata is applied.
    public let dimensions: PixelDimensions

    /// The decoded image held by the image pipeline adapter.
    public let decodedImage: DecodedImageToken

    /// The Preprocessing Contract version that governed the decode.
    public let preprocessingContractID: ArtifactID

    /// Release-validated quality features beyond the dimensions, if any.
    ///
    /// Empty until an approved Calibration Policy defines a feature and binds it to
    /// release evidence (Requirement 5.11).
    public let additionalQualityFeatures: [QualityFeatureID: ValidatedQualityValue]

    public init(
        sessionID: AnalysisSessionID,
        source: EncodedAssetHandle,
        container: StaticContainer,
        dimensions: PixelDimensions,
        decodedImage: DecodedImageToken,
        preprocessingContractID: ArtifactID,
        additionalQualityFeatures: [QualityFeatureID: ValidatedQualityValue] = [:]
    ) {
        self.sessionID = sessionID
        self.source = source
        self.container = container
        self.dimensions = dimensions
        self.decodedImage = decodedImage
        self.preprocessingContractID = preprocessingContractID
        self.additionalQualityFeatures = additionalQualityFeatures
    }

    /// The Input Quality Record for this image.
    ///
    /// Derived rather than stored, so the record's dimensions and short edge cannot
    /// disagree with the dimensions that were actually measured. The force-unwrap is
    /// sound: ``PixelDimensions`` guarantees both values are positive and both are
    /// present, which are the only conditions ``InputQualityRecord`` rejects.
    public var quality: InputQualityRecord {
        InputQualityRecord(
            decodedWidthBeforeOrientation: dimensions.width,
            decodedHeightBeforeOrientation: dimensions.height,
            validatedFeatures: additionalQualityFeatures
        )!
    }
}

/// The 384x384 unsigned 8-bit RGB buffer handed to Core ML.
///
/// The buffer itself stays in the image pipeline adapter; the domain carries its
/// geometry, element type, and the contract that produced it. `appliesAppSideNormalization`
/// is absent by construction: normalization belongs to the model graph, and
/// ``ModelInputContract`` already rejects a contract that claims otherwise
/// (Requirements 4.6 through 4.8).
public struct ModelImageInput: Hashable, Sendable {
    public let sessionID: AnalysisSessionID

    /// The prepared buffer held by the image pipeline adapter.
    public let buffer: ModelInputToken

    /// Edge length of the square crop. Always ``CenterCropContract/requiredEdge``.
    public let edge: Int

    public let channelOrder: ModelChannelOrder
    public let elementType: ModelElementType

    /// The Preprocessing Contract version that produced this buffer.
    public let preprocessingContractID: ArtifactID

    /// Creates a model input, or `nil` when it does not match the fixed contract.
    ///
    /// Only an exactly 384x384 unsigned 8-bit RGB buffer is representable. An
    /// approximated size, a float buffer, or a channel order the contract does not
    /// name cannot reach inference and be silently measured as parity (Requirements
    /// 4.5 through 4.8).
    public init?(
        sessionID: AnalysisSessionID,
        buffer: ModelInputToken,
        edge: Int,
        channelOrder: ModelChannelOrder,
        elementType: ModelElementType,
        preprocessingContractID: ArtifactID
    ) {
        guard edge == CenterCropContract.requiredEdge else { return nil }
        guard elementType == .uint8 else { return nil }
        self.sessionID = sessionID
        self.buffer = buffer
        self.edge = edge
        self.channelOrder = channelOrder
        self.elementType = elementType
        self.preprocessingContractID = preprocessingContractID
    }

    /// Creates a model input matching a validated contract's fixed shape.
    ///
    /// The preferred path: the contract has already proved the edge, element type, and
    /// normalization rule, so the two cannot disagree.
    public init(
        sessionID: AnalysisSessionID,
        buffer: ModelInputToken,
        contract: ModelInputContract,
        preprocessingContractID: ArtifactID
    ) {
        self.sessionID = sessionID
        self.buffer = buffer
        self.edge = contract.width
        self.channelOrder = contract.channelOrder
        self.elementType = contract.elementType
        self.preprocessingContractID = preprocessingContractID
    }

    /// Number of bytes the buffer holds: `edge * edge * 3` for unsigned 8-bit RGB.
    public var byteCount: UInt64 { UInt64(edge) * UInt64(edge) * 3 }
}

/// Classifies the actual container and completes every required decode.
///
/// The adapter sniffs content with Uniform Type Identifiers and Image I/O rather than
/// trusting a file name or a provider hint, separates animated, video, and audio media
/// from unsupported static containers into the two exact errors, checks encoded size,
/// declared dimensions, overflow, decoded dimensions, pixel count, memory, and storage
/// before any unsafe allocation, and only then decodes.
///
/// Faults it can report, all before any preprocessing, provenance, or inference work:
/// `unsupported-media`, `unsupported-static-format`, `decoding-error`, and
/// `resource-limit` (Requirements 1.11 through 1.14, 2.15, 2.16, and 3.1 through 3.4).
public protocol InputValidating: Sendable {
    func validate(
        _ asset: ImportedEncodedAsset,
        contract: PreprocessingContract,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ValidatedImage
}

/// Applies the bound Preprocessing Contract exactly, or fails.
///
/// Orientation, embedded-profile, and alpha handling are total contract lookups with
/// no implicit fallback; resize makes the short edge exactly 440 under the contract's
/// rounding and bilinear edge rules; the center crop is exactly 384x384 under the
/// contract's offset rule; the output is unsigned 8-bit RGB with no app-side channel
/// normalization.
///
/// Any inability to apply the exact bound action is
/// `.analysis(.preprocessingError, stage: .preprocessing)`. There is no best-effort
/// path and no approximation (Requirements 3.7 through 3.11 and 4.3 through 4.8).
public protocol ImagePreprocessing: Sendable {
    func prepare(
        _ image: ValidatedImage,
        contract: PreprocessingContract,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ModelImageInput
}
