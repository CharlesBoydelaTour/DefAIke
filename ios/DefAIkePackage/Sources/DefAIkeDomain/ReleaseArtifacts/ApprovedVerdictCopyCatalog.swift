import Foundation

// The versioned Approved Verdict Copy catalog.
//
// Requirement 8.1 requires version-controlled copy, compatible with the session's Model
// Bundle, for every pixel label, provenance state, unavailable state, Combined Summary,
// warning, and Analysis Error. Requirement 8.18 makes Version 1 English, and Requirements
// 12.15 and 12.16 require layouts and semantics to survive localization test copy.
//
// The catalogue stores keys and approvals, never display text: English values live in a
// String Catalog so nothing in the domain can render an unapproved string, and no
// presentation decision can be made from the text itself. The final wording is decision
// D1 and stays unresolved.
//
// The surface vocabulary is closed, so the presentation layer can check that every
// reachable surface has an approved key rather than discovering a missing string at
// render time.

/// A user-facing surface that needs an approved copy key.
public enum VerdictCopySurface: Hashable, Codable, Sendable, CustomStringConvertible {
    /// One of the three fixed pixel labels.
    case pixelLabel(PixelLabelKey)
    /// The explanation accompanying one pixel label.
    case pixelExplanation(PixelLabelKey)
    /// One of the five enabled provenance states.
    case provenanceState(ProvenanceStateKey)
    /// The provenance lane when the capability is disabled (Requirement 8.8).
    case provenanceUnavailable
    /// A Combined Summary produced by an approved fusion rule.
    case combinedSummary(ApprovedCopyKey)
    /// The notice shown when the two lanes appear inconsistent (Requirement 7.8).
    case apparentInconsistency
    /// One Analysis Error category.
    case analysisError(AnalysisErrorKey)
    /// The recovery action offered for one Analysis Error category.
    case errorRecovery(AnalysisErrorKey)
    /// The transformed or unknown byte-status limitation (Requirement 6.15).
    case bytePreservationLimitation(BytePreservationStatusKey)
    /// The screenshot Content Credential explanation (Requirement 6.16).
    case screenshotProvenanceExplanation
    /// The fixed evidence-scope statement (Requirement 8.10).
    case evidenceScope
    /// The false-positive and false-negative statement (Requirement 8.11).
    case falseResultLimitation
    /// The in-application privacy explanation (Requirement 9.16).
    case privacyExplanation
    /// Model identity, limitations, and release-status information (Requirement 8.17).
    case modelInformation
    /// The externally supplied correction channel (Requirement 14.14).
    case correctionChannel

    /// Stable key identifying this surface.
    public var description: String {
        switch self {
        case let .pixelLabel(label): "pixel-label/\(label.rawValue)"
        case let .pixelExplanation(label): "pixel-explanation/\(label.rawValue)"
        case let .provenanceState(state): "provenance-state/\(state.rawValue)"
        case .provenanceUnavailable: "provenance-unavailable"
        case let .combinedSummary(key): "combined-summary/\(key.rawValue)"
        case .apparentInconsistency: "apparent-inconsistency"
        case let .analysisError(error): "analysis-error/\(error.rawValue)"
        case let .errorRecovery(error): "error-recovery/\(error.rawValue)"
        case let .bytePreservationLimitation(status): "byte-preservation-limitation/\(status.rawValue)"
        case .screenshotProvenanceExplanation: "screenshot-provenance-explanation"
        case .evidenceScope: "evidence-scope"
        case .falseResultLimitation: "false-result-limitation"
        case .privacyExplanation: "privacy-explanation"
        case .modelInformation: "model-information"
        case .correctionChannel: "correction-channel"
        }
    }

    /// Surfaces every release must have approved copy for, independent of the enabled
    /// capability set and of any fusion rule.
    ///
    /// Provenance-state and Combined Summary surfaces are excluded because they depend on
    /// the capability set and on which copy keys an approved fusion rule uses.
    public static var unconditionalSurfaces: Set<VerdictCopySurface> {
        var surfaces: Set<VerdictCopySurface> = [
            .provenanceUnavailable,
            .apparentInconsistency,
            .screenshotProvenanceExplanation,
            .evidenceScope,
            .falseResultLimitation,
            .privacyExplanation,
            .modelInformation,
            .correctionChannel,
        ]
        for label in PixelLabelKey.allCases {
            surfaces.insert(.pixelLabel(label))
            surfaces.insert(.pixelExplanation(label))
        }
        for error in AnalysisErrorKey.allCases {
            surfaces.insert(.analysisError(error))
            surfaces.insert(.errorRecovery(error))
        }
        for status in BytePreservationStatusKey.allCases {
            surfaces.insert(.bytePreservationLimitation(status))
        }
        return surfaces
    }
}

/// One surface and the localization key its approved English value lives under.
public struct VerdictCopyEntry: Hashable, Codable, Sendable {
    public let surface: VerdictCopySurface

    /// Stable localization key into the English String Catalog.
    public let localizationKey: ApprovedCopyKey

    public init(surface: VerdictCopySurface, localizationKey: ApprovedCopyKey) {
        self.surface = surface
        self.localizationKey = localizationKey
    }
}

/// The versioned catalogue that binds surfaces to approved localization keys.
public struct ApprovedVerdictCopyCatalog: Hashable, Codable, Sendable {
    /// The only user-facing language in Version 1 (Requirement 8.18).
    public static let requiredLanguageTag = "en"

    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// The compatibility identifier a Model Bundle and capability set must match
    /// (Requirement 8.1).
    public let compatibilityID: ArtifactID

    public let languageTag: ArtifactText

    /// One entry per surface, each surface and localization key exactly once.
    public let entries: [VerdictCopyEntry]

    /// The content approval for this catalogue.
    public let approval: ApprovalRecord

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        compatibilityID: ArtifactID,
        languageTag: ArtifactText,
        entries: [VerdictCopyEntry],
        approval: ApprovalRecord
    ) throws {
        guard languageTag.value == Self.requiredLanguageTag else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "copyCatalog.languageTag",
                expected: Self.requiredLanguageTag,
                found: languageTag.value
            )
        }
        try ArtifactSchemaValidation.requireUniqueKeys(
            entries.map(\.surface.description),
            field: "copyCatalog.entries"
        )
        try ArtifactSchemaValidation.requireUniqueKeys(
            entries.map(\.localizationKey.rawValue),
            field: "copyCatalog.localizationKeys"
        )
        self.id = id
        self.schemaVersion = schemaVersion
        self.compatibilityID = compatibilityID
        self.languageTag = languageTag
        self.entries = entries
        self.approval = approval
    }

    /// The localization key for one surface, or `nil` when the catalogue omits it.
    ///
    /// A missing key is a fail-closed presentation error: nothing substitutes a
    /// fallback string.
    public func localizationKey(for surface: VerdictCopySurface) -> ApprovedCopyKey? {
        entries.first { $0.surface == surface }?.localizationKey
    }

    /// Unconditionally required surfaces this catalogue does not cover.
    public var missingUnconditionalSurfaces: Set<VerdictCopySurface> {
        VerdictCopySurface.unconditionalSurfaces.subtracting(Set(entries.map(\.surface)))
    }

    /// Surfaces required once the enabled provenance states are reachable.
    public func missingProvenanceSurfaces(isProvenanceEnabled: Bool) -> Set<VerdictCopySurface> {
        guard isProvenanceEnabled else { return [] }
        let required = Set(ProvenanceStateKey.allCases.map(VerdictCopySurface.provenanceState))
        return required.subtracting(Set(entries.map(\.surface)))
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, compatibilityID, languageTag, entries, approval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                compatibilityID: container.decode(ArtifactID.self, forKey: .compatibilityID),
                languageTag: container.decode(ArtifactText.self, forKey: .languageTag),
                entries: container.decode([VerdictCopyEntry].self, forKey: .entries),
                approval: container.decode(ApprovalRecord.self, forKey: .approval)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}
