#if DEBUG

import DefAIkeDomain

/// The development Evidence Fusion Rule selected for the combined detector build.
///
/// The source lanes remain visible and unchanged. These keys only select a short summary
/// shown after both cards; they never rewrite a pixel or provenance result.
enum DevelopmentFusionPolicy {
    enum Summary: String, CaseIterable {
        case signsOfAIWithoutCredential = "signs-of-ai-without-credential"
        case signsOfAIWithUnresolvedCredential = "signs-of-ai-credential-unresolved"
        case mixedEvidence = "mixed-evidence"
        case noStrongAISignal = "no-strong-ai-signal"
        case noStrongAISignalWithCredential = "no-strong-ai-signal-with-credential"
        case validatedCredentialPixelInconclusive = "validated-credential-pixel-inconclusive"
        case inconclusive = "inconclusive"
    }

    static func summary(for combination: FusionLaneCombination) -> Summary {
        switch (combination.pixel, combination.provenance) {
        case (.signalsConsistentWithAIGeneration, .absent):
            .signsOfAIWithoutCredential
        case (.signalsConsistentWithAIGeneration, .validated):
            .mixedEvidence
        case (.signalsConsistentWithAIGeneration, _):
            .signsOfAIWithUnresolvedCredential
        case (.noStrongSignalDetected, .validated):
            .noStrongAISignalWithCredential
        case (.noStrongSignalDetected, _):
            .noStrongAISignal
        case (.notEnoughSignal, .validated):
            .validatedCredentialPixelInconclusive
        case (.notEnoughSignal, _):
            .inconclusive
        }
    }

    static func copyKey(for combination: FusionLaneCombination) throws -> ApprovedCopyKey {
        try key(for: summary(for: combination))
    }

    static func allCopyKeys() throws -> [ApprovedCopyKey] {
        try Summary.allCases.map(key(for:))
    }

    static func fixtureID(for combination: FusionLaneCombination) throws -> FixtureID {
        guard let id = FixtureID(
            "fixture.local-development.fusion.\(combination.pixel.rawValue)."
                + combination.provenance.rawValue
        ) else {
            throw DevelopmentFusionPolicyError.invalidFixtureIdentifier
        }
        return id
    }

    static func fixtureFamily(for state: ProvenanceStateKey) -> FixtureFamily {
        switch state {
        case .validated: .provenanceValidSigned
        case .invalid: .provenanceInvalid
        case .absent: .provenanceAbsent
        case .unsupported: .provenanceUnsupported
        case .indeterminate: .provenanceIndeterminate
        }
    }

    private static func key(for summary: Summary) throws -> ApprovedCopyKey {
        guard let key = ApprovedCopyKey("copy.combined-summary.\(summary.rawValue)") else {
            throw DevelopmentFusionPolicyError.invalidCopyKey
        }
        return key
    }
}

private enum DevelopmentFusionPolicyError: Error {
    case invalidCopyKey
    case invalidFixtureIdentifier
}

#endif
