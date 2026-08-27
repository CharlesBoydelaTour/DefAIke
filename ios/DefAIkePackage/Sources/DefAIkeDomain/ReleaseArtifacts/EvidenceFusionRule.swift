import Foundation

// The optional Evidence Fusion Rule.
//
// Requirement 7.12 requires exactly one deterministic behavior, including explicit
// omission, for each of the 15 combinations of three pixel labels and five enabled
// provenance states. Requirement 7.15 invalidates a rule that lacks deterministic
// behavior or an approved fixture result for any combination, and Requirement 7.16
// permits a release with no Combined Summary at all.
//
// Whether any rule can pass is decision D4, and the 15 mappings themselves are
// unresolved. The schema fixes only the structure: a table is either complete over
// the exact 3 x 5 key space or it does not exist. There is no default branch and no
// free-form copy: a shown disposition names an Approved Verdict Copy key.
//
// The unavailable provenance lane is absent from the key space by construction
// (``ProvenanceStateKey`` has no unavailable case), so an unavailable lane cannot be
// looked up and always omits the summary (Requirement 7.10).

/// One enabled lane combination.
public struct FusionLaneCombination: Hashable, Codable, Sendable, CustomStringConvertible {
    public let pixel: PixelLabelKey
    public let provenance: ProvenanceStateKey

    public init(pixel: PixelLabelKey, provenance: ProvenanceStateKey) {
        self.pixel = pixel
        self.provenance = provenance
    }

    /// All 15 combinations the requirements enumerate.
    public static let allCombinations: [FusionLaneCombination] = PixelLabelKey.allCases
        .flatMap { pixel in
            ProvenanceStateKey.allCases.map { FusionLaneCombination(pixel: pixel, provenance: $0) }
        }

    /// The exact number of combinations a valid rule must cover.
    public static let requiredCombinationCount = allCombinations.count

    public var description: String { "\(pixel.rawValue)+\(provenance.rawValue)" }
}

/// What a rule does for one combination.
///
/// `omit` is an explicit decision to show no summary, which is why an incomplete
/// table cannot be read as "omit by default": omission has to be written down.
public enum FusionDisposition: Hashable, Codable, Sendable {
    /// Show no Combined Summary for this combination.
    case omit
    /// Show the summary addressed by this approved copy key.
    case show(ApprovedCopyKey)
}

/// One combination and its single disposition.
public struct FusionEntry: Hashable, Codable, Sendable {
    public let combination: FusionLaneCombination
    public let disposition: FusionDisposition

    /// Fixture that demonstrates this entry's approved behavior (Requirement 7.14).
    public let fixture: FixtureID

    public init(
        combination: FusionLaneCombination,
        disposition: FusionDisposition,
        fixture: FixtureID
    ) {
        self.combination = combination
        self.disposition = disposition
        self.fixture = fixture
    }
}

/// The versioned rule that may produce a Combined Summary.
public struct EvidenceFusionRule: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// The rule version shown alongside a displayed summary (Requirement 7.11).
    public let ruleVersion: SchemaSemanticVersion

    /// The Approved Verdict Copy catalog whose keys this rule uses.
    public let compatibleVerdictCopy: ArtifactID

    /// The fixture suite that demonstrated all 15 behaviors.
    public let fixtureSuite: ArtifactID

    /// Exactly one entry per combination, in no required order.
    public let entries: [FusionEntry]

    /// The release decision that approved this rule for use.
    public let approval: ApprovalRecord

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        ruleVersion: SchemaSemanticVersion,
        compatibleVerdictCopy: ArtifactID,
        fixtureSuite: ArtifactID,
        entries: [FusionEntry],
        approval: ApprovalRecord
    ) throws {
        try ArtifactSchemaValidation.requireExactCoverage(
            entries.map(\.combination.description),
            required: Set(FusionLaneCombination.allCombinations.map(\.description)),
            field: "fusionEntries"
        )
        self.id = id
        self.schemaVersion = schemaVersion
        self.ruleVersion = ruleVersion
        self.compatibleVerdictCopy = compatibleVerdictCopy
        self.fixtureSuite = fixtureSuite
        self.entries = entries
        self.approval = approval
    }

    /// The single disposition for an enabled lane combination. Total by construction.
    public func disposition(for combination: FusionLaneCombination) -> FusionDisposition {
        // Safe: the initializer proved every combination appears exactly once.
        entries.first { $0.combination == combination }!.disposition
    }

    /// Convenience lookup for one pixel label and one enabled provenance state.
    public func disposition(
        pixel: PixelLabelKey,
        provenance: ProvenanceStateKey
    ) -> FusionDisposition {
        disposition(for: FusionLaneCombination(pixel: pixel, provenance: provenance))
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, ruleVersion, compatibleVerdictCopy, fixtureSuite, entries, approval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                ruleVersion: container.decode(SchemaSemanticVersion.self, forKey: .ruleVersion),
                compatibleVerdictCopy: container.decode(
                    ArtifactID.self,
                    forKey: .compatibleVerdictCopy
                ),
                fixtureSuite: container.decode(ArtifactID.self, forKey: .fixtureSuite),
                entries: container.decode([FusionEntry].self, forKey: .entries),
                approval: container.decode(ApprovalRecord.self, forKey: .approval)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}
