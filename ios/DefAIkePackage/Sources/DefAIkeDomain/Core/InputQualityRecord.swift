// Input Quality Record: the measured input facts a Calibration Policy consumes.

/// One validated Input Quality Record feature value.
///
/// Deliberately a closed, small vocabulary. Every additional quality condition
/// permitted to change a pixel outcome must be bound to release-validation
/// evidence (Requirement 5.11), and that evidence does not exist yet, so there is
/// no free-form or floating-point value shape here for an unvalidated feature to
/// arrive through. A value shape is added when an approved Calibration Policy
/// defines the feature that needs it.
///
/// No case represents a probability, confidence, likelihood, or score.
public enum ValidatedQualityValue: Hashable, Codable, Sendable {
    /// An exact measured count or length, such as a pixel dimension.
    case integer(Int)
    /// An exact measured condition.
    case boolean(Bool)

    private enum CodingKeys: String, CodingKey {
        case kind
        case integer
        case boolean
    }

    private enum Kind: String, Codable {
        case integer
        case boolean
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .integer:
            self = .integer(try container.decode(Int.self, forKey: .integer))
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .boolean))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .integer(let value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .integer)
        case .boolean(let value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .boolean)
        }
    }
}

/// The measured input facts recorded for one Analysis Session.
///
/// Dimensions are the actual decoded values recorded **before** orientation
/// metadata is applied, and the short edge is exactly `min(width, height)` of
/// those unswapped values (Requirements 3.5 and 3.6). Each field is optional
/// because a session can fail before the corresponding measurement exists; a
/// measurement that was taken before a failure is preserved in the failure
/// snapshot rather than discarded (Requirement 3.14).
///
/// The record holds no image bytes, no decoded pixels, and no derived score.
public struct InputQualityRecord: Hashable, Codable, Sendable {
    /// The only schema version this build reads or writes.
    public static let currentSchemaVersion = 1

    /// An empty record, for a session that has not decoded anything yet.
    public static let unmeasured = InputQualityRecord()

    public let schemaVersion: Int

    /// Actual decoded width before orientation metadata is applied.
    public let decodedWidthBeforeOrientation: Int?

    /// Actual decoded height before orientation metadata is applied.
    public let decodedHeightBeforeOrientation: Int?

    /// `min(width, height)` of the pre-orientation decoded dimensions.
    public let shortEdgeBeforeOrientation: Int?

    /// Additional release-validated features, keyed by feature identity.
    public let validatedFeatures: [QualityFeatureID: ValidatedQualityValue]

    /// Creates a record, or `nil` when the measurements are not self-consistent.
    ///
    /// Rejects a nonpositive dimension, a partially recorded dimension pair, and
    /// any short edge that is not exactly the lesser of the two recorded
    /// dimensions, so an inconsistent record cannot reach calibration and be
    /// mistaken for a measurement.
    public init?(
        schemaVersion: Int = InputQualityRecord.currentSchemaVersion,
        decodedWidthBeforeOrientation: Int?,
        decodedHeightBeforeOrientation: Int?,
        validatedFeatures: [QualityFeatureID: ValidatedQualityValue] = [:]
    ) {
        guard schemaVersion == Self.currentSchemaVersion else { return nil }
        switch (decodedWidthBeforeOrientation, decodedHeightBeforeOrientation) {
        case (nil, nil):
            self.shortEdgeBeforeOrientation = nil
        case (let width?, let height?):
            guard width > 0, height > 0 else { return nil }
            self.shortEdgeBeforeOrientation = min(width, height)
        default:
            // One dimension without the other cannot produce a short edge, and a
            // half-recorded pair is a measurement bug rather than a valid state.
            return nil
        }
        self.schemaVersion = schemaVersion
        self.decodedWidthBeforeOrientation = decodedWidthBeforeOrientation
        self.decodedHeightBeforeOrientation = decodedHeightBeforeOrientation
        self.validatedFeatures = validatedFeatures
    }

    private init() {
        self.schemaVersion = Self.currentSchemaVersion
        self.decodedWidthBeforeOrientation = nil
        self.decodedHeightBeforeOrientation = nil
        self.shortEdgeBeforeOrientation = nil
        self.validatedFeatures = [:]
    }

    /// Decodes a record and revalidates it.
    ///
    /// Fail-closed: an unreadable schema version or a short edge that disagrees
    /// with the recorded dimensions is a decoding error, never a repaired value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let width = try container.decodeIfPresent(
            Int.self, forKey: .decodedWidthBeforeOrientation)
        let height = try container.decodeIfPresent(
            Int.self, forKey: .decodedHeightBeforeOrientation)
        let shortEdge = try container.decodeIfPresent(
            Int.self, forKey: .shortEdgeBeforeOrientation)
        let features = try container.decodeIfPresent(
            [QualityFeatureID: ValidatedQualityValue].self, forKey: .validatedFeatures) ?? [:]

        guard let record = InputQualityRecord(
            schemaVersion: schemaVersion,
            decodedWidthBeforeOrientation: width,
            decodedHeightBeforeOrientation: height,
            validatedFeatures: features
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: CodingKeys.schemaVersion,
                in: container,
                debugDescription: """
                    Input Quality Record schema version \(schemaVersion) or its \
                    recorded dimensions are not valid for this build.
                    """
            )
        }
        guard record.shortEdgeBeforeOrientation == shortEdge else {
            throw DecodingError.dataCorruptedError(
                forKey: CodingKeys.shortEdgeBeforeOrientation,
                in: container,
                debugDescription: """
                    Recorded short edge does not equal the lesser of the recorded \
                    pre-orientation dimensions.
                    """
            )
        }
        self = record
    }
}
