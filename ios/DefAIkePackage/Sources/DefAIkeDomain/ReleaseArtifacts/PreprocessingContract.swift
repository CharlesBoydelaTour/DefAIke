import Foundation

// The signed Preprocessing Contract.
//
// Requirement 3.7 requires deterministic handling for valid, absent, malformed, and
// unsupported orientation, embedded color-profile, and alpha states, and Requirement
// 3.8 requires the Preprocessor to apply the handling the contract assigns to the
// observed state. ``MetadataStateRules`` makes an incomplete map unrepresentable, so
// "no rule for this state" cannot become an implicit fallback.
//
// Which action each state gets is decision D10 and stays unresolved here. This file
// fixes only the closed vocabulary of actions the implementation can perform, plus
// the geometry the requirements already fix: bilinear short edge 440, a 384-by-384
// center crop, unsigned 8-bit RGB input, and no app-side normalization.

// MARK: - Containers and metadata states

/// A static image container DefAIke accepts.
///
/// Anything else is `unsupported-static-format`; animated or multi-frame content is
/// `unsupported-media` (Requirements 1.11 through 1.14).
public enum StaticContainer: String, Codable, Sendable, Hashable, CaseIterable {
    case jpeg
    case png
    case heic
    case heif
}

/// The observed condition of one image metadata field.
///
/// Every contract rule map must cover all four states exactly once (Requirement 3.7).
public enum ImageMetadataState: String, Codable, Sendable, Hashable, CaseIterable {
    /// Present and well formed.
    case valid
    /// Not present.
    case absent
    /// Present but not parseable.
    case malformed
    /// Present and parseable, but outside what the contract supports.
    case unsupported
}

/// A total map from every metadata state to exactly one action.
///
/// Encoded as a bounded entry list rather than a dictionary so a duplicate state is
/// a detectable schema fault instead of a silently overwritten entry, and validated
/// for exact coverage so no state is left to a default.
public struct MetadataStateRules<Action: Hashable & Codable & Sendable>: Hashable, Codable, Sendable {
    /// One state and the single action the contract assigns to it.
    public struct Rule: Hashable, Codable, Sendable {
        public let state: ImageMetadataState
        public let action: Action

        public init(state: ImageMetadataState, action: Action) {
            self.state = state
            self.action = action
        }
    }

    public let rules: [Rule]

    /// Creates a total rule map, or throws when coverage is not exact.
    public init(rules: [Rule]) throws {
        try ArtifactSchemaValidation.requireExactCoverage(
            rules.map(\.state.rawValue),
            required: Set(ImageMetadataState.allCases.map(\.rawValue)),
            field: "metadataStateRules"
        )
        self.rules = rules
    }

    /// The single action for `state`. Total by construction.
    public func action(for state: ImageMetadataState) -> Action {
        // Safe: the initializer proved every state appears exactly once.
        rules.first { $0.state == state }!.action
    }

    public init(from decoder: any Decoder) throws {
        let decoded = try decoder.singleValueContainer().decode([Rule].self)
        self = try ArtifactSchemaValidation.decoding(at: decoder.codingPath) {
            try MetadataStateRules(rules: decoded)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rules)
    }
}

// MARK: - Metadata actions

/// What the Preprocessor does about orientation metadata.
///
/// `rejectAsPreprocessingError` is the only fail-closed option and exists so a
/// contract can refuse a state instead of guessing (Requirement 3.11).
public enum OrientationAction: String, Codable, Sendable, Hashable, CaseIterable {
    /// Rotate and flip the pixels to match the declared orientation.
    case applyDeclaredOrientation = "apply-declared-orientation"
    /// Leave stored pixel order untouched.
    case ignoreDeclaredOrientation = "ignore-declared-orientation"
    /// Refuse the input.
    case rejectAsPreprocessingError = "reject-as-preprocessing-error"
}

/// What the Preprocessor does about an embedded color profile.
public enum ColorProfileAction: String, Codable, Sendable, Hashable, CaseIterable {
    /// Color-manage from the embedded profile into the contract working space.
    case convertToWorkingSpace = "convert-to-working-space"
    /// Reinterpret the samples as already being in the working space.
    case assignWorkingSpaceWithoutConversion = "assign-working-space-without-conversion"
    /// Refuse the input.
    case rejectAsPreprocessingError = "reject-as-preprocessing-error"
}

/// What the Preprocessor does about an alpha channel.
///
/// Compositing carries its background color explicitly: an opaque background is a
/// release decision that changes pixels, so it is never defaulted to white or black.
public enum AlphaAction: Hashable, Codable, Sendable {
    /// Composite over the given opaque background.
    case compositeOverOpaqueBackground(OpaqueBackgroundColor)
    /// Discard the alpha channel and keep the color channels unchanged.
    case discardAlphaChannel
    /// Refuse the input.
    case rejectAsPreprocessingError
}

/// An explicit opaque background color in 8-bit RGB.
public struct OpaqueBackgroundColor: Hashable, Codable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

// MARK: - Working color space

/// The explicit three-channel RGB working space the contract decodes into.
///
/// Named so that a device-parity failure points at one color space rather than at
/// "whatever Core Graphics chose". The optional profile digest binds the space to
/// exact ICC bytes when the release ships a profile.
public struct ColorSpaceDescriptor: Hashable, Codable, Sendable {
    /// Identifier of the color space, for example a ColorSync profile name.
    public let identifier: ArtifactText

    /// Digest of the ICC profile bytes, when the contract ships a profile.
    public let profileDigest: SHA256Digest?

    public init(identifier: ArtifactText, profileDigest: SHA256Digest?) {
        self.identifier = identifier
        self.profileDigest = profileDigest
    }
}

// MARK: - Geometry

/// Interpolation used for the aspect-preserving resize.
///
/// Requirement 4.4 fixes bilinear interpolation. The vocabulary has one case so a
/// contract cannot select anything else.
public enum ResizeInterpolation: String, Codable, Sendable, Hashable, CaseIterable {
    case bilinear
}

/// How a fractional target edge length becomes an integer.
public enum RoundingRule: String, Codable, Sendable, Hashable, CaseIterable {
    case floor
    case ceiling
    case halfUp = "half-up"
    case halfDown = "half-down"
    case halfToEven = "half-to-even"
}

/// How the sampler treats coordinates outside the source image.
public enum SampleEdgeRule: String, Codable, Sendable, Hashable, CaseIterable {
    case clampToEdge = "clamp-to-edge"
    case mirror
    case reflect
}

/// Where a sample coordinate sits inside a pixel.
///
/// This is the `align_corners`-style choice that silently changes resampled output
/// between frameworks, so the contract states it.
public enum PixelCenterConvention: String, Codable, Sendable, Hashable, CaseIterable {
    case halfPixelCenters = "half-pixel-centers"
    case integerPixelCenters = "integer-pixel-centers"
}

/// The deterministic aspect-preserving resize step.
public struct ResizeContract: Hashable, Codable, Sendable {
    /// Short-edge length the requirements fix (Requirement 4.4).
    public static let requiredShortEdge = 440

    public let interpolation: ResizeInterpolation
    public let targetShortEdge: Int
    public let rounding: RoundingRule
    public let edgeRule: SampleEdgeRule
    public let pixelCenterConvention: PixelCenterConvention

    public init(
        interpolation: ResizeInterpolation,
        targetShortEdge: Int,
        rounding: RoundingRule,
        edgeRule: SampleEdgeRule,
        pixelCenterConvention: PixelCenterConvention
    ) throws {
        guard targetShortEdge == Self.requiredShortEdge else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "resize.targetShortEdge",
                expected: "\(Self.requiredShortEdge)",
                found: "\(targetShortEdge)"
            )
        }
        self.interpolation = interpolation
        self.targetShortEdge = targetShortEdge
        self.rounding = rounding
        self.edgeRule = edgeRule
        self.pixelCenterConvention = pixelCenterConvention
    }

    private enum CodingKeys: String, CodingKey {
        case interpolation, targetShortEdge, rounding, edgeRule, pixelCenterConvention
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let interpolation = try container.decode(ResizeInterpolation.self, forKey: .interpolation)
        let targetShortEdge = try container.decode(Int.self, forKey: .targetShortEdge)
        let rounding = try container.decode(RoundingRule.self, forKey: .rounding)
        let edgeRule = try container.decode(SampleEdgeRule.self, forKey: .edgeRule)
        let convention = try container.decode(
            PixelCenterConvention.self,
            forKey: .pixelCenterConvention
        )
        self = try ArtifactSchemaValidation.decoding(at: decoder.codingPath) {
            try ResizeContract(
                interpolation: interpolation,
                targetShortEdge: targetShortEdge,
                rounding: rounding,
                edgeRule: edgeRule,
                pixelCenterConvention: convention
            )
        }
    }
}

/// How the center crop resolves an odd difference between resized and crop size.
public enum CropOffsetRule: String, Codable, Sendable, Hashable, CaseIterable {
    case floorHalfDifference = "floor-half-difference"
    case ceilingHalfDifference = "ceiling-half-difference"
}

/// The deterministic center-crop step.
public struct CenterCropContract: Hashable, Codable, Sendable {
    /// Crop edge length the requirements fix (Requirement 4.5).
    public static let requiredEdge = 384

    public let width: Int
    public let height: Int
    public let offsetRule: CropOffsetRule

    public init(width: Int, height: Int, offsetRule: CropOffsetRule) throws {
        for (field, value) in [("crop.width", width), ("crop.height", height)] {
            guard value == Self.requiredEdge else {
                throw ArtifactSchemaError.fixedValueMismatch(
                    field: field,
                    expected: "\(Self.requiredEdge)",
                    found: "\(value)"
                )
            }
        }
        self.width = width
        self.height = height
        self.offsetRule = offsetRule
    }

    private enum CodingKeys: String, CodingKey {
        case width, height, offsetRule
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        let offsetRule = try container.decode(CropOffsetRule.self, forKey: .offsetRule)
        self = try ArtifactSchemaValidation.decoding(at: decoder.codingPath) {
            try CenterCropContract(width: width, height: height, offsetRule: offsetRule)
        }
    }
}

// MARK: - Model input and output contracts

/// Channel order of the model input buffer.
public enum ModelChannelOrder: String, Codable, Sendable, Hashable, CaseIterable {
    case rgb
}

/// Element type of the model input buffer.
public enum ModelElementType: String, Codable, Sendable, Hashable, CaseIterable {
    case uint8
    case float16
    case float32
}

/// The Core ML input the Preprocessor produces.
///
/// Requirements 4.6 through 4.8: unsigned 8-bit three-channel RGB, with `1/255`
/// scaling and mean and standard-deviation normalization performed by the model
/// graph. A contract that claims app-side normalization is rejected, because that
/// would double-normalize and silently invalidate every parity measurement.
public struct ModelInputContract: Hashable, Codable, Sendable {
    public let featureName: ArtifactText
    public let width: Int
    public let height: Int
    public let channelOrder: ModelChannelOrder
    public let elementType: ModelElementType

    /// Always false: normalization belongs to the model graph.
    public let appliesAppSideNormalization: Bool

    public init(
        featureName: ArtifactText,
        width: Int,
        height: Int,
        channelOrder: ModelChannelOrder,
        elementType: ModelElementType,
        appliesAppSideNormalization: Bool
    ) throws {
        for (field, value) in [("modelInput.width", width), ("modelInput.height", height)] {
            guard value == CenterCropContract.requiredEdge else {
                throw ArtifactSchemaError.fixedValueMismatch(
                    field: field,
                    expected: "\(CenterCropContract.requiredEdge)",
                    found: "\(value)"
                )
            }
        }
        guard elementType == .uint8 else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "modelInput.elementType",
                expected: ModelElementType.uint8.rawValue,
                found: elementType.rawValue
            )
        }
        guard !appliesAppSideNormalization else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "modelInput.appliesAppSideNormalization",
                value: "true",
                reason: "the model graph scales by 1/255 and normalizes RGB"
            )
        }
        self.featureName = featureName
        self.width = width
        self.height = height
        self.channelOrder = channelOrder
        self.elementType = elementType
        self.appliesAppSideNormalization = appliesAppSideNormalization
    }

    private enum CodingKeys: String, CodingKey {
        case featureName, width, height, channelOrder, elementType, appliesAppSideNormalization
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let featureName = try container.decode(ArtifactText.self, forKey: .featureName)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        let channelOrder = try container.decode(ModelChannelOrder.self, forKey: .channelOrder)
        let elementType = try container.decode(ModelElementType.self, forKey: .elementType)
        let normalizes = try container.decode(Bool.self, forKey: .appliesAppSideNormalization)
        self = try ArtifactSchemaValidation.decoding(at: decoder.codingPath) {
            try ModelInputContract(
                featureName: featureName,
                width: width,
                height: height,
                channelOrder: channelOrder,
                elementType: elementType,
                appliesAppSideNormalization: normalizes
            )
        }
    }
}

/// The single scalar the model emits.
///
/// Requirement 4.9 fixes one finite positive-going raw logit named `logit`. Anything
/// missing, misnamed, nonscalar, nonnumeric, or nonfinite at runtime is
/// `invalid-output-error`; this contract states what the runtime must find.
public struct ModelOutputContract: Hashable, Codable, Sendable {
    /// The feature name the requirements fix.
    public static let requiredFeatureName = "logit"

    public let featureName: ArtifactText
    public let elementType: ModelElementType

    /// Whether a larger value means more evidence of synthesis. Always true.
    public let isPositiveGoing: Bool

    public init(
        featureName: ArtifactText,
        elementType: ModelElementType,
        isPositiveGoing: Bool
    ) throws {
        guard featureName.value == Self.requiredFeatureName else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "modelOutput.featureName",
                expected: Self.requiredFeatureName,
                found: featureName.value
            )
        }
        guard elementType != .uint8 else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "modelOutput.elementType",
                value: elementType.rawValue,
                reason: "a raw logit is a floating-point scalar"
            )
        }
        guard isPositiveGoing else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "modelOutput.isPositiveGoing",
                expected: "true",
                found: "false"
            )
        }
        self.featureName = featureName
        self.elementType = elementType
        self.isPositiveGoing = isPositiveGoing
    }

    private enum CodingKeys: String, CodingKey {
        case featureName, elementType, isPositiveGoing
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let featureName = try container.decode(ArtifactText.self, forKey: .featureName)
        let elementType = try container.decode(ModelElementType.self, forKey: .elementType)
        let positiveGoing = try container.decode(Bool.self, forKey: .isPositiveGoing)
        self = try ArtifactSchemaValidation.decoding(at: decoder.codingPath) {
            try ModelOutputContract(
                featureName: featureName,
                elementType: elementType,
                isPositiveGoing: positiveGoing
            )
        }
    }
}

// MARK: - Contract

/// The versioned contract that fixes every preprocessing decision for a session.
public struct PreprocessingContract: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion
    public let supportedContainers: Set<StaticContainer>
    public let orientationRules: MetadataStateRules<OrientationAction>
    public let colorProfileRules: MetadataStateRules<ColorProfileAction>
    public let alphaRules: MetadataStateRules<AlphaAction>
    public let rgbWorkingSpace: ColorSpaceDescriptor
    public let resize: ResizeContract
    public let crop: CenterCropContract
    public let modelInput: ModelInputContract

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        supportedContainers: Set<StaticContainer>,
        orientationRules: MetadataStateRules<OrientationAction>,
        colorProfileRules: MetadataStateRules<ColorProfileAction>,
        alphaRules: MetadataStateRules<AlphaAction>,
        rgbWorkingSpace: ColorSpaceDescriptor,
        resize: ResizeContract,
        crop: CenterCropContract,
        modelInput: ModelInputContract
    ) throws {
        // Version 1 accepts exactly the four Supported Static Image containers; a
        // contract cannot narrow or widen the scope the requirements fix.
        guard supportedContainers == Set(StaticContainer.allCases) else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "supportedContainers",
                expected: "\(StaticContainer.allCases.map(\.rawValue).sorted())",
                found: "\(supportedContainers.map(\.rawValue).sorted())"
            )
        }
        guard modelInput.width == crop.width, modelInput.height == crop.height else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "modelInput",
                expected: "\(crop.width)x\(crop.height) crop output",
                found: "\(modelInput.width)x\(modelInput.height)"
            )
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.supportedContainers = supportedContainers
        self.orientationRules = orientationRules
        self.colorProfileRules = colorProfileRules
        self.alphaRules = alphaRules
        self.rgbWorkingSpace = rgbWorkingSpace
        self.resize = resize
        self.crop = crop
        self.modelInput = modelInput
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, supportedContainers, orientationRules, colorProfileRules
        case alphaRules, rgbWorkingSpace, resize, crop, modelInput
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(ArtifactID.self, forKey: .id)
        let schemaVersion = try container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion)
        let containers = try container.decode(Set<StaticContainer>.self, forKey: .supportedContainers)
        let orientation = try container.decode(
            MetadataStateRules<OrientationAction>.self,
            forKey: .orientationRules
        )
        let colorProfile = try container.decode(
            MetadataStateRules<ColorProfileAction>.self,
            forKey: .colorProfileRules
        )
        let alpha = try container.decode(MetadataStateRules<AlphaAction>.self, forKey: .alphaRules)
        let workingSpace = try container.decode(ColorSpaceDescriptor.self, forKey: .rgbWorkingSpace)
        let resize = try container.decode(ResizeContract.self, forKey: .resize)
        let crop = try container.decode(CenterCropContract.self, forKey: .crop)
        let modelInput = try container.decode(ModelInputContract.self, forKey: .modelInput)
        self = try ArtifactSchemaValidation.decoding(at: decoder.codingPath) {
            try PreprocessingContract(
                id: id,
                schemaVersion: schemaVersion,
                supportedContainers: containers,
                orientationRules: orientation,
                colorProfileRules: colorProfile,
                alphaRules: alpha,
                rgbWorkingSpace: workingSpace,
                resize: resize,
                crop: crop,
                modelInput: modelInput
            )
        }
    }
}
