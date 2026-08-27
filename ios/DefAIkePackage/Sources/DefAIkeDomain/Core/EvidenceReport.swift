// The Evidence Report: the only value a completed Analysis Session produces.

/// One fixed Version 1 evidence-scope statement.
///
/// The membership of this vocabulary is fixed by Requirement 8.10 and is not an
/// unresolved release value. Every report states the included scope and every
/// listed unsupported scope.
public enum AnalysisScopeStatement: String, Codable, Sendable, CaseIterable {
    /// Generation of the complete depicted image by an AI system.
    case wholeImageSynthesis
    case localizedEdit
    case composite
    case vaeReconstruction
    case video
    case audio
    case animatedMedia
    /// A static image format outside JPEG, PNG, and HEIC/HEIF.
    case additionalStaticFormat
    /// An ingest route outside the Photos picker and Share Extension.
    case additionalIngestRoute
    case multipleImages
}

/// What the evidence in a report does and does not cover.
public struct EvidenceScope: Hashable, Codable, Sendable {
    /// The scope every Version 1 report must state as covered.
    public static let requiredIncludedStatements: Set<AnalysisScopeStatement> = [
        .wholeImageSynthesis
    ]

    /// The scopes every Version 1 report must state as not covered.
    public static let requiredExcludedStatements: Set<AnalysisScopeStatement> = [
        .localizedEdit,
        .composite,
        .vaeReconstruction,
        .video,
        .audio,
        .animatedMedia,
        .additionalStaticFormat,
        .additionalIngestRoute,
        .multipleImages,
    ]

    /// The approved evidence-scope artifact version this scope came from.
    public let id: ArtifactID
    public let includedStatements: Set<AnalysisScopeStatement>
    public let excludedStatements: Set<AnalysisScopeStatement>

    /// Creates a scope, or `nil` when it would understate coverage limits.
    ///
    /// Rejects a scope that omits any required included or excluded statement, or
    /// that claims the same statement as both covered and not covered. A report
    /// therefore cannot be built with a scope that is missing a limitation.
    public init?(
        id: ArtifactID,
        includedStatements: Set<AnalysisScopeStatement>,
        excludedStatements: Set<AnalysisScopeStatement>
    ) {
        guard Self.requiredIncludedStatements.isSubset(of: includedStatements) else {
            return nil
        }
        guard Self.requiredExcludedStatements.isSubset(of: excludedStatements) else {
            return nil
        }
        guard includedStatements.isDisjoint(with: excludedStatements) else { return nil }
        self.id = id
        self.includedStatements = includedStatements
        self.excludedStatements = excludedStatements
    }

    /// The exact Version 1 scope, bound to an approved artifact version.
    public static func version1(id: ArtifactID) -> EvidenceScope {
        // Force-unwrap is sound: the arguments are the required sets themselves,
        // so the only rejection conditions cannot hold.
        EvidenceScope(
            id: id,
            includedStatements: requiredIncludedStatements,
            excludedStatements: requiredExcludedStatements
        )!
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let scope = EvidenceScope(
            id: try container.decode(ArtifactID.self, forKey: .id),
            includedStatements: try container.decode(
                Set<AnalysisScopeStatement>.self, forKey: .includedStatements),
            excludedStatements: try container.decode(
                Set<AnalysisScopeStatement>.self, forKey: .excludedStatements)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: CodingKeys.excludedStatements,
                in: container,
                debugDescription: """
                    An evidence scope must state every required covered and \
                    uncovered scope, and no scope in both.
                    """
            )
        }
        self = scope
    }
}

/// An optional fused interpretation of the two source lanes.
///
/// A summary exists only when a deterministic, release-approved, fixture-tested
/// Evidence Fusion Rule produced it, and it records that rule's version
/// (Requirement 7.11). Its wording is an Approved Verdict Copy key, never free-form
/// text, so a fusion table cannot introduce an unapproved claim.
public struct CombinedSummary: Hashable, Codable, Sendable {
    public let copyKey: ApprovedCopyKey
    /// The Evidence Fusion Rule version that produced this summary.
    public let fusionRuleID: ArtifactID

    public init(copyKey: ApprovedCopyKey, fusionRuleID: ArtifactID) {
        self.copyKey = copyKey
        self.fusionRuleID = fusionRuleID
    }
}

/// The immutable result of one successfully completed Analysis Session.
///
/// Structural guarantees:
///
/// * The two source lanes are separate immutable fields, so neither can suppress,
///   override, or rank the other (Requirements 7.1 and 7.8).
/// * There is no probability, confidence, percentage, score, raw logit, creation
///   history, or ranking field (Requirements 8.9 and 8.13).
/// * It is deliberately **not** `Codable`. A report is displayed while its session
///   is active and then discarded; there is no save, export, share, or history
///   surface, so the domain gives it no serialized form to leak through.
/// * An Analysis Error is a separate terminal outcome and is not representable
///   here: a report and an error never coexist (Requirement 11.18).
public struct EvidenceReport: Hashable, Sendable {
    /// The only schema version this build produces.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int

    /// The immutable snapshot this session was bound to.
    public let binding: AnalysisSessionBinding

    /// The pixel source lane.
    public let pixel: PixelEvidence

    /// The provenance source lane, including the unavailable state.
    public let provenance: ProvenanceLane

    /// Present only when an approved fusion rule produced a summary.
    public let combinedSummary: CombinedSummary?

    /// Approved copy identifying an apparent inconsistency between the two lanes,
    /// attached without suppressing, overriding, or ranking either lane.
    public let apparentInconsistency: ApprovedCopyKey?

    /// What is known about the preservation of the analyzed bytes.
    public let bytePreservationStatus: BytePreservationStatus

    /// The measured input facts recorded for this session.
    public let inputQuality: InputQualityRecord

    /// Whether all analysis for this session ran on the user's device.
    public let onDeviceProcessing: Bool

    /// What the evidence covers and does not cover.
    public let scope: EvidenceScope

    /// Creates a report, or `nil` when the lane combination is not representable.
    ///
    /// Rejects an unreadable schema version, and rejects a Combined Summary or an
    /// apparent-inconsistency notice alongside an unavailable provenance lane: with
    /// no provenance evidence there is nothing to fuse and nothing to be
    /// inconsistent with (Requirements 7.8 and 7.10).
    public init?(
        schemaVersion: Int = EvidenceReport.currentSchemaVersion,
        binding: AnalysisSessionBinding,
        pixel: PixelEvidence,
        provenance: ProvenanceLane,
        combinedSummary: CombinedSummary?,
        apparentInconsistency: ApprovedCopyKey?,
        bytePreservationStatus: BytePreservationStatus,
        inputQuality: InputQualityRecord,
        onDeviceProcessing: Bool,
        scope: EvidenceScope
    ) {
        guard schemaVersion == Self.currentSchemaVersion else { return nil }
        if !provenance.isAvailable {
            guard combinedSummary == nil, apparentInconsistency == nil else { return nil }
        }
        self.schemaVersion = schemaVersion
        self.binding = binding
        self.pixel = pixel
        self.provenance = provenance
        self.combinedSummary = combinedSummary
        self.apparentInconsistency = apparentInconsistency
        self.bytePreservationStatus = bytePreservationStatus
        self.inputQuality = inputQuality
        self.onDeviceProcessing = onDeviceProcessing
        self.scope = scope
    }
}
