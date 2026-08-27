import Foundation

// The immutable Release Fixture Suite.
//
// Requirement 13.4 requires the existing 96 model-parity fixtures plus release-approved
// orientation, color-space, alpha, aspect-ratio, physical-screenshot, JPEG, PNG,
// HEIC/HEIF, malformed-input, Photos Picker, and Share Extension handoff fixtures.
// Requirement 13.5 adds the six provenance families when the capability is enabled.
//
// Every fixture carries a content digest, the approved source artifact it came from, and
// its expected results. Expected results are declared, never generated from the
// implementation under test, and a fixture whose asset is missing fails rather than being
// skipped. The count of catalogued model-parity fixtures is exposed as a constant for the
// runner that reconciles the catalogue against the 96 existing references.

/// A required fixture family.
public enum FixtureFamily: String, Codable, Sendable, Hashable, CaseIterable {
    case modelParity = "model-parity"
    case orientation
    case colorSpace = "color-space"
    case alpha
    case aspectRatio = "aspect-ratio"
    case physicalScreenshot = "physical-screenshot"
    case jpegContainer = "jpeg-container"
    case pngContainer = "png-container"
    case heifContainer = "heif-container"
    case malformedInput = "malformed-input"
    case photosPickerRoute = "photos-picker-route"
    case shareExtensionRoute = "share-extension-route"
    case provenanceValidSigned = "provenance-valid-signed"
    case provenanceTampered = "provenance-tampered"
    case provenanceInvalid = "provenance-invalid"
    case provenanceAbsent = "provenance-absent"
    case provenanceUnsupported = "provenance-unsupported"
    case provenanceIndeterminate = "provenance-indeterminate"

    /// Whether this family applies only when Provenance Capability is enabled.
    public var isProvenanceConditional: Bool {
        switch self {
        case .provenanceValidSigned, .provenanceTampered, .provenanceInvalid, .provenanceAbsent,
             .provenanceUnsupported, .provenanceIndeterminate:
            true
        default:
            false
        }
    }

    /// Families every release must populate, regardless of capability set.
    public static var unconditionalFamilies: Set<FixtureFamily> {
        Set(allCases.filter { !$0.isProvenanceConditional })
    }

    /// Families required only when provenance is enabled.
    public static var provenanceFamilies: Set<FixtureFamily> {
        Set(allCases.filter(\.isProvenanceConditional))
    }
}

/// One approved expected result for a fixture.
public enum FixtureExpectation: Hashable, Codable, Sendable {
    /// The calibrated label the fixture must produce.
    case pixelLabel(PixelLabelKey)
    /// The raw logit the fixture must produce, within the plan's tolerance.
    case rawLogit(value: Double, tolerance: NonNegativeDecimal)
    /// The digest of the expected preprocessing output bytes.
    case preprocessingOutputDigest(SHA256Digest)
    /// The digest of the encoded bytes the route must retain unchanged.
    case retainedBytesDigest(SHA256Digest)
    /// The preservation status the route must record.
    case bytePreservationStatus(BytePreservationStatusKey)
    /// The single provenance state the validator must report.
    case provenanceState(ProvenanceStateKey)
    /// The Analysis Error the session must terminate with.
    case analysisError(AnalysisErrorKey)
}

/// One immutable fixture and everything approved about it.
public struct FixtureRecord: Hashable, Codable, Sendable {
    public let id: FixtureID
    public let family: FixtureFamily

    /// Canonical path of the fixture asset inside its suite.
    public let assetPath: CanonicalRelativePath

    /// Digest of the fixture bytes, so a changed asset is a changed fixture.
    public let contentDigest: SHA256Digest
    public let byteCount: PositiveByteCount

    /// The approved artifact this fixture and its expectations came from.
    public let source: EvidenceSource

    /// Expected results. Never empty: a fixture with no expectation tests nothing.
    public let expectations: [FixtureExpectation]

    public init(
        id: FixtureID,
        family: FixtureFamily,
        assetPath: CanonicalRelativePath,
        contentDigest: SHA256Digest,
        byteCount: PositiveByteCount,
        source: EvidenceSource,
        expectations: [FixtureExpectation]
    ) throws {
        try ArtifactSchemaValidation.requireNonEmpty(expectations, field: "fixture.expectations")
        for expectation in expectations {
            if case let .rawLogit(value, _) = expectation {
                try ArtifactSchemaValidation.requireFinite(
                    value,
                    field: "fixture.expectations.rawLogit"
                )
            }
            if case .provenanceState = expectation, !family.isProvenanceConditional {
                throw ArtifactSchemaError.forbiddenValue(
                    field: "fixture.expectations",
                    value: "provenanceState",
                    reason: "only a provenance family fixture declares a provenance state"
                )
            }
        }
        if family.isProvenanceConditional {
            let declaresState = expectations.contains {
                if case .provenanceState = $0 { true } else { false }
            }
            guard declaresState else {
                throw ArtifactSchemaError.missingRequiredEntries(
                    field: "fixture.expectations",
                    keys: ["provenanceState"]
                )
            }
        }
        self.id = id
        self.family = family
        self.assetPath = assetPath
        self.contentDigest = contentDigest
        self.byteCount = byteCount
        self.source = source
        self.expectations = expectations
    }

    private enum CodingKeys: String, CodingKey {
        case id, family, assetPath, contentDigest, byteCount, source, expectations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(FixtureID.self, forKey: .id),
                family: container.decode(FixtureFamily.self, forKey: .family),
                assetPath: container.decode(CanonicalRelativePath.self, forKey: .assetPath),
                contentDigest: container.decode(SHA256Digest.self, forKey: .contentDigest),
                byteCount: container.decode(PositiveByteCount.self, forKey: .byteCount),
                source: container.decode(EvidenceSource.self, forKey: .source),
                expectations: container.decode([FixtureExpectation].self, forKey: .expectations)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// The versioned, immutable fixture suite a plan and bundle refer to.
public struct ReleaseFixtureSuite: Hashable, Codable, Sendable {
    /// Number of existing model-parity fixtures the catalogue must account for
    /// (Requirement 13.4).
    public static let requiredModelParityFixtureCount = 96

    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// Whether the provenance families apply to this release.
    public let provenanceApplicability: GateApplicability

    /// Every catalogued fixture, each identifier and asset path exactly once.
    public let fixtures: [FixtureRecord]

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        provenanceApplicability: GateApplicability,
        fixtures: [FixtureRecord]
    ) throws {
        try ArtifactSchemaValidation.requireNonEmpty(fixtures, field: "suite.fixtures")
        try ArtifactSchemaValidation.requireUniqueKeys(
            fixtures.map(\.id.rawValue),
            field: "suite.fixtures"
        )
        try ArtifactSchemaValidation.requireUniqueKeys(
            fixtures.map(\.assetPath.rawValue),
            field: "suite.fixtureAssetPaths"
        )
        if !provenanceApplicability.isApplicable {
            for fixture in fixtures where fixture.family.isProvenanceConditional {
                throw ArtifactSchemaError.forbiddenValue(
                    field: "suite.fixtures[\(fixture.id.rawValue)].family",
                    value: fixture.family.rawValue,
                    reason: "provenance fixtures need an applicable provenance decision"
                )
            }
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.provenanceApplicability = provenanceApplicability
        self.fixtures = fixtures
    }

    /// Fixtures in one family.
    public func fixtures(in family: FixtureFamily) -> [FixtureRecord] {
        fixtures.filter { $0.family == family }
    }

    /// Families this release must populate, given its provenance applicability.
    public var requiredFamilies: Set<FixtureFamily> {
        provenanceApplicability.isApplicable
            ? Set(FixtureFamily.allCases)
            : FixtureFamily.unconditionalFamilies
    }

    /// Required families with no catalogued fixture.
    public var missingFamilies: Set<FixtureFamily> {
        requiredFamilies.subtracting(Set(fixtures.map(\.family)))
    }

    /// Whether the model-parity family accounts for all 96 existing references.
    ///
    /// Reported rather than enforced in the initializer, so a runner can catalogue
    /// incrementally and still fail the release gate until the count is complete.
    public var hasCompleteModelParityCoverage: Bool {
        fixtures(in: .modelParity).count == Self.requiredModelParityFixtureCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, provenanceApplicability, fixtures
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                provenanceApplicability: container.decode(
                    GateApplicability.self,
                    forKey: .provenanceApplicability
                ),
                fixtures: container.decode([FixtureRecord].self, forKey: .fixtures)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}
