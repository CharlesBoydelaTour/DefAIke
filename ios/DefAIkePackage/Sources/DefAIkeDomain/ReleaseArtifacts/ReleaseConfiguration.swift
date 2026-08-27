// The validated join of every policy artifact one build is bound to.
//
// Each artifact validates itself (task 1.3). That is not enough: a set of
// individually valid artifacts can still be incoherent. A capability manifest can
// name `policy.calibration` while the calibration policy it is handed identifies
// itself as something else; a calibration policy can declare compatibility with a
// preprocessing contract that is not the bound one; a provenance policy can be built
// against a validator version the manifest does not compile. Every one of those is a
// release that behaves differently from the one that was signed, and none of them is
// visible to per-artifact validation.
//
// ``ReleaseConfiguration`` is where the references are required to resolve. Its
// initializer is the only way to hold the set, so an incoherent set is not
// representable, and ``load(capabilityManifest:from:)`` derives every identifier from
// the signed manifest rather than from a constant — the manifest is the single root of
// the reference graph.
//
// Scope: this is the *policy* set a shipping build reads at startup, matching
// ``PolicyArtifactReading``. Model Bundle verification, device allowlisting, resource
// plan completeness, and release readiness are separate gates with their own tasks.
// This type deliberately makes no device, bundle, or distribution decision.

/// Every policy artifact one build is bound to, with its references resolved.
public struct ReleaseConfiguration: Hashable, Sendable {
    /// The signed statement of what this build is approved to do. Root of the graph.
    public let capabilityManifest: ReleaseCapabilityManifest

    public let lifecyclePolicy: DataLifecyclePolicy
    public let extensionExecutionPolicy: ExtensionExecutionPolicy
    public let resourceBudgets: ResourceBudgetSet
    public let bundleVerificationPolicy: BundleVerificationPolicy
    public let preprocessingContract: PreprocessingContract
    public let calibrationPolicy: CalibrationPolicy
    public let verdictCopyCatalog: ApprovedVerdictCopyCatalog

    /// The Provenance Policy, present exactly when the manifest binds one.
    ///
    /// `Optional` here is not "maybe absent": the *decision* lives in the manifest as
    /// a ``ConditionalArtifactBinding``, and the initializer requires this value to
    /// agree with it. A pixel-only build carries an approved not-applicable decision
    /// in the manifest and no policy here; a provenance build carries both.
    public let provenancePolicy: ProvenancePolicy?

    /// The Evidence Fusion Rule, present exactly when the manifest binds one.
    public let fusionRule: EvidenceFusionRule?

    public init(
        capabilityManifest: ReleaseCapabilityManifest,
        lifecyclePolicy: DataLifecyclePolicy,
        extensionExecutionPolicy: ExtensionExecutionPolicy,
        resourceBudgets: ResourceBudgetSet,
        bundleVerificationPolicy: BundleVerificationPolicy,
        preprocessingContract: PreprocessingContract,
        calibrationPolicy: CalibrationPolicy,
        verdictCopyCatalog: ApprovedVerdictCopyCatalog,
        provenancePolicy: ProvenancePolicy?,
        fusionRule: EvidenceFusionRule?
    ) throws {
        let compatibility = capabilityManifest.policyCompatibility

        // Every artifact is the one the manifest names.
        try ArtifactSchemaValidation.requireMatchingReference(
            lifecyclePolicy.id,
            matches: compatibility.lifecyclePolicy,
            field: "configuration.lifecyclePolicy.id"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            extensionExecutionPolicy.id,
            matches: compatibility.extensionExecutionPolicy,
            field: "configuration.extensionExecutionPolicy.id"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            resourceBudgets.mainApplication.id,
            matches: compatibility.mainApplicationResourceBudget,
            field: "configuration.resourceBudgets.mainApplication.id"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            resourceBudgets.shareExtension.id,
            matches: compatibility.shareExtensionResourceBudget,
            field: "configuration.resourceBudgets.shareExtension.id"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            bundleVerificationPolicy.id,
            matches: compatibility.bundleVerificationPolicy,
            field: "configuration.bundleVerificationPolicy.id"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            preprocessingContract.id,
            matches: compatibility.preprocessingContract,
            field: "configuration.preprocessingContract.id"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            calibrationPolicy.id,
            matches: compatibility.calibrationPolicy,
            field: "configuration.calibrationPolicy.id"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            verdictCopyCatalog.compatibilityID,
            matches: compatibility.verdictCopyCompatibility,
            field: "configuration.verdictCopyCatalog.compatibilityID"
        )

        // Both targets' limits come from one Device Validation Plan (Requirement 11.1).
        try ArtifactSchemaValidation.requireMatchingReference(
            resourceBudgets.shareExtension.validationPlan,
            matches: resourceBudgets.mainApplication.validationPlan,
            field: "configuration.resourceBudgets.shareExtension.validationPlan"
        )

        // The calibration policy's own compatibility claims resolve to the bound
        // artifacts (Requirement 5.13).
        try ArtifactSchemaValidation.requireMatchingReference(
            calibrationPolicy.compatiblePreprocessing,
            matches: preprocessingContract.id,
            field: "configuration.calibrationPolicy.compatiblePreprocessing"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            calibrationPolicy.compatibleVerdictCopy,
            matches: verdictCopyCatalog.compatibilityID,
            field: "configuration.calibrationPolicy.compatibleVerdictCopy"
        )
        guard calibrationPolicy.compatibleModel == RequiredPixelModel.identity else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "configuration.calibrationPolicy.compatibleModel",
                expected: RequiredPixelModel.checkpointIdentifier,
                found: calibrationPolicy.compatibleModel.checkpointIdentifier.rawValue
            )
        }

        try Self.validateProvenance(
            provenancePolicy,
            manifest: capabilityManifest,
            compatibility: compatibility
        )
        try Self.validateFusion(
            fusionRule,
            compatibility: compatibility,
            verdictCopyCatalog: verdictCopyCatalog
        )

        self.capabilityManifest = capabilityManifest
        self.lifecyclePolicy = lifecyclePolicy
        self.extensionExecutionPolicy = extensionExecutionPolicy
        self.resourceBudgets = resourceBudgets
        self.bundleVerificationPolicy = bundleVerificationPolicy
        self.preprocessingContract = preprocessingContract
        self.calibrationPolicy = calibrationPolicy
        self.verdictCopyCatalog = verdictCopyCatalog
        self.provenancePolicy = provenancePolicy
        self.fusionRule = fusionRule
    }

    private static func validateProvenance(
        _ policy: ProvenancePolicy?,
        manifest: ReleaseCapabilityManifest,
        compatibility: PolicyCompatibilitySet
    ) throws {
        guard let bound = compatibility.provenancePolicy.boundReference else {
            guard policy == nil else {
                throw ArtifactSchemaError.forbiddenValue(
                    field: "configuration.provenancePolicy",
                    value: policy?.id.rawValue ?? "",
                    reason: "the manifest records an approved not-applicable decision"
                )
            }
            return
        }
        guard let policy else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: "configuration.provenancePolicy",
                keys: [bound.rawValue]
            )
        }
        try ArtifactSchemaValidation.requireMatchingReference(
            policy.id,
            matches: bound,
            field: "configuration.provenancePolicy.id"
        )
        // The reviewed validator version the policy was approved against is the one
        // the build compiles. A mismatch means the approved feasibility evidence
        // describes different code (Requirements 6.2 and 6.19).
        guard let compiled = manifest.implementationVersion(for: .contentCredentialValidation)
        else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: "configuration.capabilityManifest.implementationVersions",
                keys: [CapabilityID.contentCredentialValidation.rawValue]
            )
        }
        guard policy.validatorImplementationVersion == compiled else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "configuration.provenancePolicy.validatorImplementationVersion",
                expected: compiled.description,
                found: policy.validatorImplementationVersion.description
            )
        }
        // Provenance validation runs in the main application, so it is governed by
        // the main-application budget and never by the extension's.
        try ArtifactSchemaValidation.requireMatchingReference(
            policy.resourceBudget,
            matches: compatibility.mainApplicationResourceBudget,
            field: "configuration.provenancePolicy.resourceBudget"
        )
    }

    private static func validateFusion(
        _ rule: EvidenceFusionRule?,
        compatibility: PolicyCompatibilitySet,
        verdictCopyCatalog: ApprovedVerdictCopyCatalog
    ) throws {
        guard let bound = compatibility.fusionRule.boundReference else {
            guard rule == nil else {
                throw ArtifactSchemaError.forbiddenValue(
                    field: "configuration.fusionRule",
                    value: rule?.id.rawValue ?? "",
                    reason: "the manifest records an approved not-applicable decision"
                )
            }
            return
        }
        guard let rule else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: "configuration.fusionRule",
                keys: [bound.rawValue]
            )
        }
        try ArtifactSchemaValidation.requireMatchingReference(
            rule.id,
            matches: bound,
            field: "configuration.fusionRule.id"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            rule.compatibleVerdictCopy,
            matches: verdictCopyCatalog.compatibilityID,
            field: "configuration.fusionRule.compatibleVerdictCopy"
        )
    }
}

// MARK: - Artifact-supplied values

extension ReleaseConfiguration {
    /// The approved signature algorithm. There is no compiled-in alternative.
    public var signatureAlgorithm: SignatureAlgorithm { bundleVerificationPolicy.algorithm }

    /// The trusted key record for one identifier, or `nil` when the policy does not
    /// trust it. An unknown key is never assumed trustworthy.
    public func trustedKey(_ key: SigningKeyID) -> TrustedSigningKey? {
        bundleVerificationPolicy.trustedKey(key)
    }

    /// The approved cleanup deadline for one reason (Requirement 9.7).
    public func cleanupDeadline(for reason: SessionCleanupReason) -> ValidatedDuration {
        lifecyclePolicy.deadline(for: reason)
    }

    /// The approved hard limit for one metric on one target (Requirements 11.2, 11.3).
    ///
    /// `nil` only where the metric does not apply to that target, which the budget
    /// schema already fixes; it is never "no limit was decided".
    public func hardLimit(
        _ metric: ResourceMetric,
        for target: ExecutionTarget
    ) -> ValidatedLimit? {
        resourceBudgets.budget(for: target).limit(for: metric)
    }

    /// Decoding limits for a Model Bundle manifest under this configuration.
    ///
    /// The payload ceiling comes from the approved Bundle Verification Policy, so the
    /// bounded decode a manifest is subjected to is a release decision rather than a
    /// source-code constant (Requirement 10.8).
    public var manifestDecodingLimits: ArtifactEncodingLimits {
        ArtifactEncodingLimits(
            maximumByteCount: bundleVerificationPolicy.maximumManifestByteCount
        )
    }

    /// A decoder bounded by this configuration's approved manifest ceiling.
    public var manifestDecoder: BoundedArtifactDecoder {
        BoundedArtifactDecoder(manifestLimitsFrom: bundleVerificationPolicy)
    }

    /// Whether this configuration enables on-device Content Credential validation.
    ///
    /// True only when the manifest approves the capability *and* the policy it names
    /// resolved. Linking a validator is not approval to enable it.
    public var enablesProvenance: Bool {
        capabilityManifest.enablesProvenance && provenancePolicy != nil
    }

    /// Whether this configuration can produce a Combined Summary.
    public var enablesFusion: Bool {
        capabilityManifest.enablesFusion && fusionRule != nil
    }
}

// MARK: - Loading

extension ReleaseConfiguration {
    /// Reads every bound policy artifact through `reader` and validates the join.
    ///
    /// Two identifiers are named by the caller and every other one is derived from
    /// the signed manifest, so there is no path by which a build reads a policy its
    /// manifest does not name, and no absent artifact is replaced by a default: a
    /// missing one is ``ReleaseArtifactError/notFound(_:)`` and the load fails
    /// (Requirements 11.1, 14.1, and 14.15).
    ///
    /// The Approved Verdict Copy catalog needs its own identifier because the manifest
    /// carries the *compatibility* identifier a catalog must declare, not the catalog's
    /// artifact identifier. Supplying it here keeps locating the catalog separate from
    /// approving it: the join then requires the located catalog to declare exactly the
    /// compatibility identifier the manifest names (Requirement 8.1).
    ///
    /// The conditional artifacts are read only when the manifest binds them, so a
    /// pixel-only build does not require a Provenance Policy to exist anywhere.
    public static func load(
        capabilityManifest id: ArtifactID,
        verdictCopyCatalog catalogID: ArtifactID,
        from reader: some PolicyArtifactReading
    ) async throws(ReleaseArtifactError) -> ReleaseConfiguration {
        let manifest = try await reader.capabilityManifest(id)
        guard manifest.id == id else {
            throw .identifierMismatch(requested: id, found: manifest.id)
        }
        let compatibility = manifest.policyCompatibility

        let lifecycle = try await reader.lifecyclePolicy(compatibility.lifecyclePolicy)
        let extensionPolicy = try await reader.extensionExecutionPolicy(
            compatibility.extensionExecutionPolicy
        )
        let budgets = try await reader.resourceBudgets(
            mainApplication: compatibility.mainApplicationResourceBudget,
            shareExtension: compatibility.shareExtensionResourceBudget
        )
        let verification = try await reader.bundleVerificationPolicy(
            compatibility.bundleVerificationPolicy
        )
        let contract = try await reader.preprocessingContract(compatibility.preprocessingContract)
        let calibration = try await reader.calibrationPolicy(compatibility.calibrationPolicy)
        let copyCatalog = try await reader.verdictCopyCatalog(catalogID)
        guard copyCatalog.id == catalogID else {
            throw .identifierMismatch(requested: catalogID, found: copyCatalog.id)
        }

        var provenance: ProvenancePolicy?
        if let bound = compatibility.provenancePolicy.boundReference {
            provenance = try await reader.provenancePolicy(bound)
        }
        var fusion: EvidenceFusionRule?
        if let bound = compatibility.fusionRule.boundReference {
            fusion = try await reader.fusionRule(bound)
        }

        do {
            return try ReleaseConfiguration(
                capabilityManifest: manifest,
                lifecyclePolicy: lifecycle,
                extensionExecutionPolicy: extensionPolicy,
                resourceBudgets: budgets,
                bundleVerificationPolicy: verification,
                preprocessingContract: contract,
                calibrationPolicy: calibration,
                verdictCopyCatalog: copyCatalog,
                provenancePolicy: provenance,
                fusionRule: fusion
            )
        } catch let error as ArtifactSchemaError {
            throw .invalid(error)
        } catch {
            throw .storeUnavailable
        }
    }
}
