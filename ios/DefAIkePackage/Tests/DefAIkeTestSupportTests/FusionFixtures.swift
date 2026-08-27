import DefAIkeDomain
import DefAIkeTestSupport
import Foundation

/// Fusion rules and session bindings for the evidence-lane doubles.
///
/// **The mappings here are not approved fusion behavior.** Whether any Evidence Fusion
/// Rule can pass release approval is unresolved, and the 15 real dispositions are an
/// external decision backed by fixtures. These rules assign one uniform disposition so
/// that lookup, compatibility, and omission can be exercised without asserting anything
/// about what the approved table should say.
enum FusionFixture {
    /// The five enabled provenance states, each with a minimal payload.
    ///
    /// The unavailable lane is deliberately absent: it has no fusion key at all.
    static let allEnabledStates: [ProvenanceEvidence] = [
        .validated(
            ValidatedClaimSummary(
                provenancePolicyID: PortValue.artifactID("provenance-0001"),
                bindingStatus: .boundToInspectedBytes,
                signerFields: [],
                assertionFields: []
            )
        ),
        .invalid(
            InvaliditySummary(
                provenancePolicyID: PortValue.artifactID("provenance-0001"),
                category: .cryptographic,
                explanationKey: copyKey("copy.invalid")
            )
        ),
        .absent,
        .unsupported(
            UnsupportedFeatureSummary(
                provenancePolicyID: PortValue.artifactID("provenance-0001"),
                explanationKey: copyKey("copy.unsupported"),
                unsupportedFeatures: []
            )
        ),
        .indeterminate(
            IndeterminateSummary(
                provenancePolicyID: PortValue.artifactID("provenance-0001"),
                explanationKey: copyKey("copy.indeterminate")
            )
        ),
    ]

    /// A complete 15-entry rule.
    ///
    /// `showingKey` of `nil` makes every entry an explicit omission, which is a valid
    /// approved rule shape: omission has to be written down, never defaulted.
    static func rule(
        id: String = "fusion-0001",
        showingKey: String?,
        verdictCopyID: String = "copy-0001",
        fixtureSuiteID: String = "fixture-suite-0001"
    ) -> EvidenceFusionRule {
        do {
            let disposition: FusionDisposition = showingKey.map {
                .show(copyKey($0))
            } ?? .omit
            return try EvidenceFusionRule(
                id: PortValue.artifactID(id),
                schemaVersion: .v1,
                ruleVersion: try SchemaSemanticVersion(validating: "1.0.0"),
                compatibleVerdictCopy: PortValue.artifactID(verdictCopyID),
                fixtureSuite: PortValue.artifactID(fixtureSuiteID),
                entries: FusionLaneCombination.allCombinations.map { combination in
                    FusionEntry(
                        combination: combination,
                        disposition: disposition,
                        fixture: fixture("fixture.\(combination.description)")
                    )
                },
                approval: LifecycleFixture.approval()
            )
        } catch {
            preconditionFailure("the fusion rule fixture must be schema-valid: \(error)")
        }
    }

    /// A session binding, with the two conditional artifact references a test varies.
    static func binding(
        fusionRuleID: ArtifactID?,
        verdictCopyID: String = "copy-0001",
        provenancePolicyID: ArtifactID? = nil
    ) -> AnalysisSessionBinding {
        AnalysisSessionBinding(
            sessionID: PortValue.sessionID(),
            appBuildID: PortValue.appBuildID(),
            deviceConfigurationID: PortValue.configurationID(),
            modelBundleID: PortValue.bundleID(),
            modelIdentity: RequiredPixelModel.identity,
            coreMLModelVersion: PortValue.artifactID("coreml-model-0001"),
            modelBundleIntegrity: BundleFixture.requiredBoundBundle().integrity,
            preprocessingContractID: PortValue.artifactID("preprocessing-0001"),
            calibrationPolicyID: PortValue.artifactID("calibration-0001"),
            verdictCopyCompatibilityID: PortValue.artifactID(verdictCopyID),
            capabilityManifestID: PortValue.artifactID("capability-0001"),
            provenancePolicyID: provenancePolicyID,
            fusionRuleID: fusionRuleID,
            lifecyclePolicyID: PortValue.artifactID("lifecycle-0001"),
            resourceBudgetID: PortValue.artifactID("budget-main-application")
        )
    }

    static func copyKey(_ raw: String) -> ApprovedCopyKey {
        guard let key = ApprovedCopyKey(raw) else {
            preconditionFailure("copy key is not canonical: \(raw)")
        }
        return key
    }

    static func fixture(_ raw: String) -> FixtureID {
        guard let id = FixtureID(raw) else {
            preconditionFailure("fixture identifier is not canonical: \(raw)")
        }
        return id
    }
}
