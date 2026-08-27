import Foundation

// The signed Release Capability Manifest.
//
// A build's compiled capability set is a fact about its module graph. This manifest is
// the signed statement of what that build is *approved* to do, and startup preflight
// fails closed when the two disagree (Requirements 6.2, 6.3, 6.19, and 6.20).
//
// The schema enforces the three couplings the requirements make non-negotiable:
//
//   * pixel analysis is always present, because it is the required Version 1 evidence
//     capability;
//   * content-credential validation is bound to a Provenance Policy if and only if the
//     capability is compiled, so a pixel-only manifest cannot carry a live provenance
//     policy and a provenance manifest cannot omit one; and
//   * fusion requires provenance, because an unavailable provenance lane can never
//     support a Combined Summary.

/// One capability and the exact implementation version compiled for it.
public struct CapabilityImplementationEntry: Hashable, Codable, Sendable {
    public let capability: CapabilityID
    public let version: CapabilityImplementationVersion

    public init(capability: CapabilityID, version: CapabilityImplementationVersion) {
        self.capability = capability
        self.version = version
    }
}

/// Every policy version a build is compatible with.
///
/// The two conditional artifacts use ``ConditionalArtifactBinding`` rather than
/// `Optional`, so "no provenance policy" is a recorded decision instead of a missing
/// field.
public struct PolicyCompatibilitySet: Hashable, Codable, Sendable {
    public let preprocessingContract: ArtifactID
    public let calibrationPolicy: ArtifactID
    public let lifecyclePolicy: ArtifactID
    public let extensionExecutionPolicy: ArtifactID
    public let mainApplicationResourceBudget: ArtifactID
    public let shareExtensionResourceBudget: ArtifactID
    public let bundleVerificationPolicy: ArtifactID
    public let verdictCopyCompatibility: ArtifactID
    public let provenancePolicy: ConditionalArtifactBinding<ArtifactID>
    public let fusionRule: ConditionalArtifactBinding<ArtifactID>

    public init(
        preprocessingContract: ArtifactID,
        calibrationPolicy: ArtifactID,
        lifecyclePolicy: ArtifactID,
        extensionExecutionPolicy: ArtifactID,
        mainApplicationResourceBudget: ArtifactID,
        shareExtensionResourceBudget: ArtifactID,
        bundleVerificationPolicy: ArtifactID,
        verdictCopyCompatibility: ArtifactID,
        provenancePolicy: ConditionalArtifactBinding<ArtifactID>,
        fusionRule: ConditionalArtifactBinding<ArtifactID>
    ) throws {
        guard mainApplicationResourceBudget != shareExtensionResourceBudget else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "policyCompatibility.shareExtensionResourceBudget",
                value: shareExtensionResourceBudget.rawValue,
                reason: "the two targets need separately measured budgets"
            )
        }
        self.preprocessingContract = preprocessingContract
        self.calibrationPolicy = calibrationPolicy
        self.lifecyclePolicy = lifecyclePolicy
        self.extensionExecutionPolicy = extensionExecutionPolicy
        self.mainApplicationResourceBudget = mainApplicationResourceBudget
        self.shareExtensionResourceBudget = shareExtensionResourceBudget
        self.bundleVerificationPolicy = bundleVerificationPolicy
        self.verdictCopyCompatibility = verdictCopyCompatibility
        self.provenancePolicy = provenancePolicy
        self.fusionRule = fusionRule
    }

    private enum CodingKeys: String, CodingKey {
        case preprocessingContract, calibrationPolicy, lifecyclePolicy, extensionExecutionPolicy
        case mainApplicationResourceBudget, shareExtensionResourceBudget, bundleVerificationPolicy
        case verdictCopyCompatibility, provenancePolicy, fusionRule
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                preprocessingContract: container.decode(
                    ArtifactID.self,
                    forKey: .preprocessingContract
                ),
                calibrationPolicy: container.decode(ArtifactID.self, forKey: .calibrationPolicy),
                lifecyclePolicy: container.decode(ArtifactID.self, forKey: .lifecyclePolicy),
                extensionExecutionPolicy: container.decode(
                    ArtifactID.self,
                    forKey: .extensionExecutionPolicy
                ),
                mainApplicationResourceBudget: container.decode(
                    ArtifactID.self,
                    forKey: .mainApplicationResourceBudget
                ),
                shareExtensionResourceBudget: container.decode(
                    ArtifactID.self,
                    forKey: .shareExtensionResourceBudget
                ),
                bundleVerificationPolicy: container.decode(
                    ArtifactID.self,
                    forKey: .bundleVerificationPolicy
                ),
                verdictCopyCompatibility: container.decode(
                    ArtifactID.self,
                    forKey: .verdictCopyCompatibility
                ),
                provenancePolicy: container.decode(
                    ConditionalArtifactBinding<ArtifactID>.self,
                    forKey: .provenancePolicy
                ),
                fusionRule: container.decode(
                    ConditionalArtifactBinding<ArtifactID>.self,
                    forKey: .fusionRule
                )
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// The signed statement of what one application build is approved to do.
public struct ReleaseCapabilityManifest: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    public let appBuild: AppBuildID

    /// The build composition this manifest describes, matching the compiled
    /// composition identifier in the application target.
    public let compositionIdentifier: ArtifactText

    /// Capabilities compiled into this build. Always includes pixel analysis.
    public let compiledCapabilities: Set<CapabilityID>

    /// Exactly one implementation version per compiled capability.
    public let implementationVersions: [CapabilityImplementationEntry]

    /// The version-bound device allowlist this build is distributed against.
    public let approvedConfigurationAllowlist: ArtifactID

    /// Model Bundles this build may activate. Never empty.
    public let approvedBundleCatalog: [ModelBundleID]

    public let policyCompatibility: PolicyCompatibilitySet

    /// The release decision that approved this capability set.
    public let approval: ApprovalRecord

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        appBuild: AppBuildID,
        compositionIdentifier: ArtifactText,
        compiledCapabilities: Set<CapabilityID>,
        implementationVersions: [CapabilityImplementationEntry],
        approvedConfigurationAllowlist: ArtifactID,
        approvedBundleCatalog: [ModelBundleID],
        policyCompatibility: PolicyCompatibilitySet,
        approval: ApprovalRecord
    ) throws {
        guard compiledCapabilities.contains(.pixelAnalysis) else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: "compiledCapabilities",
                keys: [CapabilityID.pixelAnalysis.rawValue]
            )
        }
        try ArtifactSchemaValidation.requireExactCoverage(
            implementationVersions.map(\.capability.rawValue),
            required: Set(compiledCapabilities.map(\.rawValue)),
            field: "implementationVersions"
        )
        try ArtifactSchemaValidation.requireNonEmpty(
            approvedBundleCatalog,
            field: "approvedBundleCatalog"
        )
        try ArtifactSchemaValidation.requireUniqueKeys(
            approvedBundleCatalog.map(\.rawValue),
            field: "approvedBundleCatalog"
        )

        let validatesProvenance = compiledCapabilities.contains(.contentCredentialValidation)
        guard validatesProvenance == policyCompatibility.provenancePolicy.isBound else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "policyCompatibility.provenancePolicy",
                expected: validatesProvenance
                    ? "a bound Provenance Policy for a provenance-enabled build"
                    : "an approved not-applicable decision for a pixel-only build",
                found: policyCompatibility.provenancePolicy.isBound
                    ? "a bound Provenance Policy"
                    : "a not-applicable decision"
            )
        }

        let fusesEvidence = compiledCapabilities.contains(.evidenceFusion)
        guard fusesEvidence == policyCompatibility.fusionRule.isBound else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "policyCompatibility.fusionRule",
                expected: fusesEvidence
                    ? "a bound Evidence Fusion Rule"
                    : "an approved not-applicable decision",
                found: policyCompatibility.fusionRule.isBound
                    ? "a bound Evidence Fusion Rule"
                    : "a not-applicable decision"
            )
        }
        guard !fusesEvidence || validatesProvenance else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "compiledCapabilities",
                value: CapabilityID.evidenceFusion.rawValue,
                reason: "an unavailable provenance lane cannot support a Combined Summary"
            )
        }

        self.id = id
        self.schemaVersion = schemaVersion
        self.appBuild = appBuild
        self.compositionIdentifier = compositionIdentifier
        self.compiledCapabilities = compiledCapabilities
        self.implementationVersions = implementationVersions
        self.approvedConfigurationAllowlist = approvedConfigurationAllowlist
        self.approvedBundleCatalog = approvedBundleCatalog
        self.policyCompatibility = policyCompatibility
        self.approval = approval
    }

    /// Whether this manifest enables on-device Content Credential validation.
    public var enablesProvenance: Bool {
        compiledCapabilities.contains(.contentCredentialValidation)
    }

    /// Whether this manifest enables a Combined Summary.
    public var enablesFusion: Bool { compiledCapabilities.contains(.evidenceFusion) }

    /// The implementation version for one capability, or `nil` when not compiled.
    public func implementationVersion(
        for capability: CapabilityID
    ) -> CapabilityImplementationVersion? {
        implementationVersions.first { $0.capability == capability }?.version
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, appBuild, compositionIdentifier, compiledCapabilities
        case implementationVersions, approvedConfigurationAllowlist, approvedBundleCatalog
        case policyCompatibility, approval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                appBuild: container.decode(AppBuildID.self, forKey: .appBuild),
                compositionIdentifier: container.decode(
                    ArtifactText.self,
                    forKey: .compositionIdentifier
                ),
                compiledCapabilities: container.decode(
                    Set<CapabilityID>.self,
                    forKey: .compiledCapabilities
                ),
                implementationVersions: container.decode(
                    [CapabilityImplementationEntry].self,
                    forKey: .implementationVersions
                ),
                approvedConfigurationAllowlist: container.decode(
                    ArtifactID.self,
                    forKey: .approvedConfigurationAllowlist
                ),
                approvedBundleCatalog: container.decode(
                    [ModelBundleID].self,
                    forKey: .approvedBundleCatalog
                ),
                policyCompatibility: container.decode(
                    PolicyCompatibilitySet.self,
                    forKey: .policyCompatibility
                ),
                approval: container.decode(ApprovalRecord.self, forKey: .approval)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}
