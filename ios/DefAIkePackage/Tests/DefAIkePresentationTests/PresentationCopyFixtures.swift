import Foundation

@testable import DefAIkeDomain
@testable import DefAIkePresentation

// Synthetic, structurally valid inputs for the copy-binding tests.
//
// Nothing here is an approved value. No wording, capability decision, fusion mapping,
// device, budget, or governance conclusion is expressed: the catalogues carry
// localization *keys* only, and every approval record is a clearly synthetic stand-in.
// The tests build a coherent set and then mutate one field at a time to check that
// binding refuses.

enum CopyFixture {
    // MARK: - Scalars

    static func artifact(_ value: String) -> ArtifactID { ArtifactID(value)! }

    static func copyKey(_ value: String) -> ApprovedCopyKey { ApprovedCopyKey(value)! }

    static func digest(_ character: Character = "a") -> SHA256Digest {
        SHA256Digest(hexadecimal: String(repeating: character, count: 64))!
    }

    static func text(_ value: String) -> ArtifactText { try! ArtifactText(validating: value) }

    static func version(_ value: String = "1.0.0") -> SchemaSemanticVersion {
        try! SchemaSemanticVersion(validating: value)
    }

    static func evidence(_ identifier: String) -> EvidenceSource {
        EvidenceSource(
            artifact: artifact(identifier),
            version: version(),
            contentDigest: digest()
        )
    }

    static func approval(
        _ decision: ApprovalDecision = .approved,
        identifier: String = "approval.synthetic"
    ) -> ApprovalRecord {
        ApprovalRecord(
            source: evidence(identifier),
            decision: decision,
            approver: ApproverID("role.synthetic-reviewer")!,
            decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Fixed identifiers the coherent set agrees on

    static let compatibilityID = artifact("copy.compatibility.v1")
    static let capabilityManifestID = artifact("manifest.capability.synthetic")
    static let fusionRuleID = artifact("rule.fusion.synthetic")
    static let catalogID = artifact("catalog.verdict-copy.synthetic")

    /// The Combined Summary keys the synthetic fusion rule can produce.
    ///
    /// One per pixel label, so a rule covering all fifteen combinations reaches three
    /// summary surfaces. The mapping is arbitrary and synthetic; only its shape
    /// matters to these tests.
    static let summaryKeys: [PixelLabelKey: ApprovedCopyKey] = Dictionary(
        uniqueKeysWithValues: PixelLabelKey.allCases.map {
            ($0, copyKey("copy.summary.\($0.rawValue)"))
        }
    )

    // MARK: - Catalogue

    /// A localization key for one surface, derived from the surface's stable key.
    static func localizationKey(for surface: VerdictCopySurface) -> ApprovedCopyKey {
        copyKey("copy." + surface.description.replacingOccurrences(of: "/", with: "."))
    }

    /// Every surface a fully populated catalogue covers: the unconditional set, all
    /// five enabled provenance states, and one entry per synthetic summary key.
    static var allSurfaces: Set<VerdictCopySurface> {
        var surfaces = VerdictCopySurface.unconditionalSurfaces
        for state in ProvenanceStateKey.allCases {
            surfaces.insert(.provenanceState(state))
        }
        for key in summaryKeys.values {
            surfaces.insert(.combinedSummary(key))
        }
        return surfaces
    }

    static func entries(
        surfaces: Set<VerdictCopySurface>
    ) -> [VerdictCopyEntry] {
        surfaces
            .sorted { $0.description < $1.description }
            .map { VerdictCopyEntry(surface: $0, localizationKey: localizationKey(for: $0)) }
    }

    static func catalog(
        id: ArtifactID = catalogID,
        compatibilityID: ArtifactID = CopyFixture.compatibilityID,
        languageTag: String = ApprovedVerdictCopyCatalog.requiredLanguageTag,
        surfaces: Set<VerdictCopySurface>? = nil,
        approval decision: ApprovalDecision = .approved
    ) throws -> ApprovedVerdictCopyCatalog {
        try ApprovedVerdictCopyCatalog(
            id: id,
            schemaVersion: .v1,
            compatibilityID: compatibilityID,
            languageTag: text(languageTag),
            entries: entries(surfaces: surfaces ?? allSurfaces),
            approval: approval(decision)
        )
    }

    // MARK: - Capability manifest

    static func policyCompatibility(
        verdictCopyCompatibility: ArtifactID = CopyFixture.compatibilityID,
        provenanceEnabled: Bool,
        fusionEnabled: Bool
    ) throws -> PolicyCompatibilitySet {
        try PolicyCompatibilitySet(
            preprocessingContract: artifact("contract.preprocessing.synthetic"),
            calibrationPolicy: artifact("policy.calibration.synthetic"),
            lifecyclePolicy: artifact("policy.lifecycle.synthetic"),
            extensionExecutionPolicy: artifact("policy.extension-execution.synthetic"),
            mainApplicationResourceBudget: artifact("budget.main-application.synthetic"),
            shareExtensionResourceBudget: artifact("budget.share-extension.synthetic"),
            bundleVerificationPolicy: artifact("policy.bundle-verification.synthetic"),
            verdictCopyCompatibility: verdictCopyCompatibility,
            provenancePolicy: provenanceEnabled
                ? .bound(artifact("policy.provenance.synthetic"))
                : .notApplicable(decision: approval()),
            fusionRule: fusionEnabled
                ? .bound(fusionRuleID)
                : .notApplicable(decision: approval())
        )
    }

    static func capabilityManifest(
        id: ArtifactID = capabilityManifestID,
        provenanceEnabled: Bool = false,
        fusionEnabled: Bool = false,
        verdictCopyCompatibility: ArtifactID = CopyFixture.compatibilityID
    ) throws -> ReleaseCapabilityManifest {
        var capabilities: Set<CapabilityID> = [.pixelAnalysis]
        if provenanceEnabled { capabilities.insert(.contentCredentialValidation) }
        if fusionEnabled { capabilities.insert(.evidenceFusion) }

        return try ReleaseCapabilityManifest(
            id: id,
            schemaVersion: .v1,
            appBuild: AppBuildID("build.synthetic")!,
            compositionIdentifier: text(
                provenanceEnabled ? "pixel-plus-provenance" : "pixel-only"
            ),
            compiledCapabilities: capabilities,
            implementationVersions: capabilities
                .sorted { $0.rawValue < $1.rawValue }
                .map { CapabilityImplementationEntry(capability: $0, version: version()) },
            approvedConfigurationAllowlist: artifact("allowlist.devices.synthetic"),
            approvedBundleCatalog: [ModelBundleID("bundle.synthetic")!],
            policyCompatibility: policyCompatibility(
                verdictCopyCompatibility: verdictCopyCompatibility,
                provenanceEnabled: provenanceEnabled,
                fusionEnabled: fusionEnabled
            ),
            approval: approval()
        )
    }

    // MARK: - Fusion rule

    /// A complete fifteen-entry rule.
    ///
    /// `omitting` forces those combinations to explicit omission, which is how a valid
    /// rule reaches fewer summary surfaces.
    static func fusionRule(
        id: ArtifactID = fusionRuleID,
        compatibleVerdictCopy: ArtifactID = CopyFixture.compatibilityID,
        omitting omitted: Set<PixelLabelKey> = []
    ) throws -> EvidenceFusionRule {
        let entries = FusionLaneCombination.allCombinations.map { combination in
            FusionEntry(
                combination: combination,
                disposition: omitted.contains(combination.pixel)
                    ? .omit
                    : .show(summaryKeys[combination.pixel]!),
                fixture: FixtureID("fixture.fusion.synthetic")!
            )
        }
        return try EvidenceFusionRule(
            id: id,
            schemaVersion: .v1,
            ruleVersion: version(),
            compatibleVerdictCopy: compatibleVerdictCopy,
            fixtureSuite: artifact("suite.fixtures.synthetic"),
            entries: entries,
            approval: approval()
        )
    }

    // MARK: - Session binding

    static func integrity() -> VerifiedBundleIntegrity {
        VerifiedBundleIntegrity(
            status: .verified,
            activationReceiptID: artifact("receipt.activation.synthetic"),
            verificationPolicyID: artifact("policy.bundle-verification.synthetic"),
            verifiedManifestDigest: digest("b"),
            verifiedArtifactDigests: [
                ArtifactDigestRecord(
                    path: CanonicalRelativePath("artifacts/model.mlmodelc")!,
                    kind: .directoryTree,
                    byteCount: 4096,
                    digest: digest("c")
                )
            ]
        )!
    }

    static func sessionBinding(
        sessionID: String = "session.synthetic",
        capabilityManifestID: ArtifactID = CopyFixture.capabilityManifestID,
        verdictCopyCompatibilityID: ArtifactID = CopyFixture.compatibilityID,
        provenanceEnabled: Bool = false,
        fusionEnabled: Bool = false,
        fusionRuleID: ArtifactID? = nil
    ) -> AnalysisSessionBinding {
        AnalysisSessionBinding(
            sessionID: AnalysisSessionID(sessionID)!,
            appBuildID: AppBuildID("build.synthetic")!,
            deviceConfigurationID: ApprovedConfigurationID("configuration.synthetic")!,
            modelBundleID: ModelBundleID("bundle.synthetic")!,
            modelIdentity: ModelIdentity(
                checkpointIdentifier: ModelCheckpointIdentifier("checkpoint.synthetic")!,
                requiredWeightDigest: digest("d")
            ),
            coreMLModelVersion: artifact("component.coreml.synthetic"),
            modelBundleIntegrity: integrity(),
            preprocessingContractID: artifact("contract.preprocessing.synthetic"),
            calibrationPolicyID: artifact("policy.calibration.synthetic"),
            verdictCopyCompatibilityID: verdictCopyCompatibilityID,
            capabilityManifestID: capabilityManifestID,
            provenancePolicyID: provenanceEnabled
                ? artifact("policy.provenance.synthetic")
                : nil,
            fusionRuleID: fusionEnabled ? (fusionRuleID ?? CopyFixture.fusionRuleID) : nil,
            lifecyclePolicyID: artifact("policy.lifecycle.synthetic"),
            resourceBudgetID: artifact("budget.main-application.synthetic")
        )
    }

    // MARK: - Coherent bindings

    /// A pixel-only binding: no provenance, no fusion.
    static func pixelOnlyBinding() throws -> ApprovedCopyBinding {
        try ApprovedCopyBinding.bind(
            catalog: catalog(),
            session: sessionBinding(),
            capabilities: capabilityManifest(),
            fusionRule: nil
        )
    }

    /// A provenance-enabled binding with no fusion rule.
    static func provenanceBinding() throws -> ApprovedCopyBinding {
        try ApprovedCopyBinding.bind(
            catalog: catalog(),
            session: sessionBinding(provenanceEnabled: true),
            capabilities: capabilityManifest(provenanceEnabled: true),
            fusionRule: nil
        )
    }

    /// A provenance-enabled binding with a complete fusion rule.
    static func fusionBinding(
        omitting omitted: Set<PixelLabelKey> = []
    ) throws -> ApprovedCopyBinding {
        try ApprovedCopyBinding.bind(
            catalog: catalog(),
            session: sessionBinding(provenanceEnabled: true, fusionEnabled: true),
            capabilities: capabilityManifest(provenanceEnabled: true, fusionEnabled: true),
            fusionRule: fusionRule(omitting: omitted)
        )
    }
}
