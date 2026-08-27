import DefAIkeDomain
import DefAIkeProvenanceAPI
import DefAIkeTestSupport
import Foundation
import Testing

@testable import DefAIkeApplication

// A coherent synthetic release, and a coordinator wired to it.
//
// The coordinator owns an `AnalysisSessionBinder`, and a binder needs a `ReleaseAdmission`.
// That value's initializer is `fileprivate` in the domain precisely so only a passed
// `StartupPreflight` can produce one, so the fixtures below build a release whose
// artifacts, allowlist, bundle, and module graph all agree and then *run the real gate*.
// Bypassing it would bind sessions against an admission no build could hold, and every
// artifact-version check the binder makes — the approved catalogue, the matched entry's
// validated bundle, the component versions — would be untested.
//
// **No value in this file is an approved release input.** The hardware identifier, the
// deadlines, the resource limits, the calibration boundary, the copy keys, the trust store,
// and every approval record are synthetic placeholders for schema shape. Nothing here may
// be copied into a shipping artifact, and no test asserts that a value here is correct:
// the artifact schema tests do that against the schemas, and release validation does it
// against approved records. No signature is verified, no digest is streamed, no self-test
// is executed, and no compiled model is loaded.

// MARK: - Scalars

enum CoordinatorSample {

    // MARK: Identifiers

    static func artifact(_ raw: String) -> ArtifactID {
        guard let id = ArtifactID(raw) else {
            preconditionFailure("fixture artifact identifier is not canonical: \(raw)")
        }
        return id
    }

    static func copyKey(_ raw: String) -> ApprovedCopyKey {
        guard let key = ApprovedCopyKey(raw) else {
            preconditionFailure("fixture copy key is not canonical: \(raw)")
        }
        return key
    }

    static func fixtureID(_ raw: String) -> FixtureID {
        guard let id = FixtureID(raw) else {
            preconditionFailure("fixture identifier is not canonical: \(raw)")
        }
        return id
    }

    static func hardware(_ raw: String = "iPhone17.1") -> DeviceHardwareID {
        guard let id = DeviceHardwareID(raw) else {
            preconditionFailure("fixture hardware identifier is not canonical: \(raw)")
        }
        return id
    }

    static func signingKey(_ raw: String = "key.coordinator") -> SigningKeyID {
        guard let id = SigningKeyID(raw) else {
            preconditionFailure("fixture signing key identifier is not canonical: \(raw)")
        }
        return id
    }

    static func approver(_ raw: String = "role.release-owner") -> ApproverID {
        guard let id = ApproverID(raw) else {
            preconditionFailure("fixture approver identifier is not canonical: \(raw)")
        }
        return id
    }

    static func validatorStatus(
        _ raw: String = "status.signature-valid"
    ) -> ProvenanceValidatorStatusID {
        guard let id = ProvenanceValidatorStatusID(raw) else {
            preconditionFailure("fixture validator status is not canonical: \(raw)")
        }
        return id
    }

    static func path(_ raw: String = "artifacts/model.mlmodelc") -> CanonicalRelativePath {
        guard let value = CanonicalRelativePath(raw) else {
            preconditionFailure("fixture path is not canonical: \(raw)")
        }
        return value
    }

    // MARK: Wrapped values

    static func text(_ raw: String) -> ArtifactText {
        do {
            return try ArtifactText(validating: raw)
        } catch {
            preconditionFailure("fixture text is not schema-valid: \(error)")
        }
    }

    static func version(_ raw: String = "1.0.0") -> SchemaSemanticVersion {
        do {
            return try SchemaSemanticVersion(validating: raw)
        } catch {
            preconditionFailure("fixture version is not schema-valid: \(error)")
        }
    }

    static func count(_ value: Int) -> PositiveCount {
        do {
            return try PositiveCount(validating: value)
        } catch {
            preconditionFailure("\(value) is not a positive count: \(error)")
        }
    }

    static func byteCount(_ value: UInt64) -> PositiveByteCount {
        do {
            return try PositiveByteCount(validating: value)
        } catch {
            preconditionFailure("\(value) is not a positive byte count: \(error)")
        }
    }

    static func duration(_ milliseconds: UInt64 = 30_000) -> ValidatedDuration {
        do {
            return try ValidatedDuration(validating: milliseconds)
        } catch {
            preconditionFailure("\(milliseconds) ms is not a valid duration: \(error)")
        }
    }

    static func positive(_ value: Decimal) -> PositiveDecimal {
        do {
            return try PositiveDecimal(validating: value)
        } catch {
            preconditionFailure("\(value) is not a positive decimal: \(error)")
        }
    }

    static func ratio(_ value: Decimal) -> UnitInterval {
        do {
            return try UnitInterval(validating: value)
        } catch {
            preconditionFailure("\(value) is not in the unit interval: \(error)")
        }
    }

    static func digest(_ seed: String) -> DefAIkeDomain.SHA256Digest {
        TestSHA256.digest(ofUTF8: "coordinator-fixture-\(seed)")
    }

    static func evidence(_ identifier: String) -> EvidenceSource {
        EvidenceSource(
            artifact: artifact(identifier),
            version: version("0.1.0"),
            contentDigest: digest(identifier)
        )
    }

    static func approval(_ decision: ApprovalDecision = .approved) -> ApprovalRecord {
        ApprovalRecord(
            source: evidence("evidence.approval"),
            decision: decision,
            approver: approver(),
            decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

// MARK: - Artifact identifiers this release binds

extension CoordinatorSample {
    static let capabilityManifestID = "manifest.capability"
    static let allowlistID = "allowlist.devices"
    static let lifecyclePolicyID = "policy.lifecycle"
    static let extensionPolicyID = "policy.extension-execution"
    static let verificationPolicyID = "policy.bundle-verification"
    static let preprocessingContractID = "contract.preprocessing"
    static let calibrationPolicyID = "policy.calibration"
    static let copyCatalogID = "catalog.verdict-copy"
    static let copyCompatibilityID = "copy.compatibility"
    static let provenancePolicyID = "policy.provenance"
    static let fusionRuleID = "rule.fusion"
    static let mainBudgetID = "budget.main-application"
    static let extensionBudgetID = "budget.share-extension"
    static let validationPlanID = "plan.device-validation"
    static let fixtureSuiteID = "suite.fixtures"
    static let evidenceScopeID = "component.scope"
    static let coreMLComponentID = "component.coreml"
    static let bundleID = "bundle.coordinator"
    static let appBuildID = "build.coordinator"
    static let configurationID = "configuration.coordinator"

    /// The reviewed validator version the provenance policy and the manifest both pin.
    static let validatorVersion = "0.0.12"
}

// MARK: - Policy artifacts

extension CoordinatorSample {
    static func capabilities(provenance: Bool, fusion: Bool) -> Set<CapabilityID> {
        var set: Set<CapabilityID> = [.pixelAnalysis]
        if provenance { set.insert(.contentCredentialValidation) }
        if fusion { set.insert(.evidenceFusion) }
        return set
    }

    /// One implementation version per compiled capability, pinning the validator to the
    /// version the provenance policy declares.
    static func implementationVersions(
        for capabilities: Set<CapabilityID>
    ) -> [CapabilityImplementationEntry] {
        capabilities.sorted { $0.rawValue < $1.rawValue }.map {
            CapabilityImplementationEntry(
                capability: $0,
                version: $0 == .contentCredentialValidation
                    ? version(validatorVersion)
                    : version()
            )
        }
    }

    static func policyCompatibility(
        provenance: Bool,
        fusion: Bool
    ) -> PolicyCompatibilitySet {
        do {
            return try PolicyCompatibilitySet(
                preprocessingContract: artifact(preprocessingContractID),
                calibrationPolicy: artifact(calibrationPolicyID),
                lifecyclePolicy: artifact(lifecyclePolicyID),
                extensionExecutionPolicy: artifact(extensionPolicyID),
                mainApplicationResourceBudget: artifact(mainBudgetID),
                shareExtensionResourceBudget: artifact(extensionBudgetID),
                bundleVerificationPolicy: artifact(verificationPolicyID),
                verdictCopyCompatibility: artifact(copyCompatibilityID),
                provenancePolicy: provenance
                    ? .bound(artifact(provenancePolicyID))
                    : .notApplicable(decision: approval()),
                fusionRule: fusion
                    ? .bound(artifact(fusionRuleID))
                    : .notApplicable(decision: approval())
            )
        } catch {
            preconditionFailure("the policy compatibility fixture must be valid: \(error)")
        }
    }

    static func capabilityManifest(
        provenance: Bool,
        fusion: Bool
    ) -> ReleaseCapabilityManifest {
        let capabilities = capabilities(provenance: provenance, fusion: fusion)
        do {
            return try ReleaseCapabilityManifest(
                id: artifact(capabilityManifestID),
                schemaVersion: .v1,
                appBuild: Fixture.appBuild(appBuildID),
                compositionIdentifier: text(
                    provenance ? "pixel-plus-provenance" : "pixel-only"
                ),
                compiledCapabilities: capabilities,
                implementationVersions: implementationVersions(for: capabilities),
                approvedConfigurationAllowlist: artifact(allowlistID),
                approvedBundleCatalog: [Fixture.bundleID(bundleID)],
                policyCompatibility: policyCompatibility(
                    provenance: provenance,
                    fusion: fusion
                ),
                approval: approval()
            )
        } catch {
            preconditionFailure("the capability manifest fixture must be valid: \(error)")
        }
    }

    static func composition(provenance: Bool, fusion: Bool) -> CompiledCapabilityComposition {
        let capabilities = capabilities(provenance: provenance, fusion: fusion)
        guard let composition = CompiledCapabilityComposition(
            compositionIdentifier: text(provenance ? "pixel-plus-provenance" : "pixel-only"),
            capabilities: capabilities,
            implementationVersions: implementationVersions(for: capabilities),
            // A fact about the linked module graph, which the gate requires to agree with
            // the manifest in both directions.
            linksContentCredentialValidator: provenance
        ) else {
            preconditionFailure("the compiled composition fixture must be runnable")
        }
        return composition
    }

    static func lifecyclePolicy() -> DataLifecyclePolicy {
        do {
            return try DataLifecyclePolicy(
                id: artifact(lifecyclePolicyID),
                schemaVersion: .v1,
                deadlines: SessionCleanupReason.allCases.map {
                    DataLifecyclePolicy.Deadline(reason: $0, deadline: duration())
                },
                approval: approval()
            )
        } catch {
            preconditionFailure("the lifecycle policy fixture must be valid: \(error)")
        }
    }

    static func extensionExecutionPolicy() -> ExtensionExecutionPolicy {
        do {
            return try ExtensionExecutionPolicy(
                id: artifact(extensionPolicyID),
                schemaVersion: .v1,
                requiresVisibleConsent: true,
                delegatesInferenceToMainApplication: true,
                stagedFileProtection: .complete,
                pendingHandoffPolicy: .instructRecovery,
                protectionEvidence: evidence("evidence.file-protection")
            )
        } catch {
            preconditionFailure("the extension policy fixture must be valid: \(error)")
        }
    }

    static func verificationPolicy() -> BundleVerificationPolicy {
        do {
            return try BundleVerificationPolicy(
                id: artifact(verificationPolicyID),
                schemaVersion: .v1,
                algorithm: .ed25519,
                canonicalizationProfile: evidence("evidence.canonicalization"),
                trustedKeys: [
                    TrustedSigningKey(
                        key: signingKey(),
                        algorithm: .ed25519,
                        publicKeyDigest: digest("public-key"),
                        status: .active,
                        governanceApproval: approval()
                    )
                ],
                rotationBehavior: .activeKeysOnly,
                revocationBehavior: .rejectBundle,
                maximumManifestByteCount: byteCount(65_536),
                reproducibilityEvidence: evidence("evidence.reproducibility")
            )
        } catch {
            preconditionFailure("the verification policy fixture must be valid: \(error)")
        }
    }

    static func modelInputContract() -> ModelInputContract {
        do {
            return try ModelInputContract(
                featureName: text("image"),
                width: CenterCropContract.requiredEdge,
                height: CenterCropContract.requiredEdge,
                channelOrder: .rgb,
                elementType: .uint8,
                appliesAppSideNormalization: false
            )
        } catch {
            preconditionFailure("the model input fixture must be valid: \(error)")
        }
    }

    static func modelOutputContract() -> ModelOutputContract {
        do {
            return try ModelOutputContract(
                featureName: text(ModelOutputContract.requiredFeatureName),
                elementType: .float32,
                isPositiveGoing: true
            )
        } catch {
            preconditionFailure("the model output fixture must be valid: \(error)")
        }
    }

    static func preprocessingContract() -> PreprocessingContract {
        do {
            return try PreprocessingContract(
                id: artifact(preprocessingContractID),
                schemaVersion: .v1,
                supportedContainers: Set(StaticContainer.allCases),
                orientationRules: try MetadataStateRules(
                    rules: ImageMetadataState.allCases.map {
                        .init(state: $0, action: .applyDeclaredOrientation)
                    }
                ),
                colorProfileRules: try MetadataStateRules(
                    rules: ImageMetadataState.allCases.map {
                        .init(state: $0, action: .convertToWorkingSpace)
                    }
                ),
                alphaRules: try MetadataStateRules(
                    rules: ImageMetadataState.allCases.map {
                        .init(state: $0, action: .discardAlphaChannel)
                    }
                ),
                rgbWorkingSpace: ColorSpaceDescriptor(
                    identifier: text("Fixture RGB working space"),
                    profileDigest: digest("color-profile")
                ),
                resize: try ResizeContract(
                    interpolation: .bilinear,
                    targetShortEdge: ResizeContract.requiredShortEdge,
                    rounding: .halfUp,
                    edgeRule: .clampToEdge,
                    pixelCenterConvention: .halfPixelCenters
                ),
                crop: try CenterCropContract(
                    width: CenterCropContract.requiredEdge,
                    height: CenterCropContract.requiredEdge,
                    offsetRule: .floorHalfDifference
                ),
                modelInput: modelInputContract()
            )
        } catch {
            preconditionFailure("the preprocessing contract fixture must be valid: \(error)")
        }
    }

    static func calibrationPolicy() -> CalibrationPolicy {
        do {
            return try CalibrationPolicy(
                id: artifact(calibrationPolicyID),
                schemaVersion: .v1,
                compatibleModel: RequiredPixelModel.identity,
                compatiblePreprocessing: artifact(preprocessingContractID),
                compatibleVerdictCopy: artifact(copyCompatibilityID),
                falseAccusationBudget: try FalseAccusationBudget(
                    validating: Decimal(sign: .plus, exponent: -3, significand: 5)
                ),
                releasePassRule: try FalseAccusationPassRule(
                    statistic: .observedRateAndIntervalUpperBound,
                    intervalMethod: .wilsonScore,
                    confidenceLevel: ratio(
                        FalseAccusationPassRule.requiredConfidenceLevel
                    )
                ),
                outputLabels: Set(PixelLabelKey.allCases),
                metricCategories: PixelLabelKey.allCases.map {
                    MetricCategoryAssignment(label: $0, category: $0.requiredMetricCategory)
                },
                boundaries: [
                    try CategoryBoundary(
                        rawLogitBoundary: 0,
                        abstentionHalfWidth: CategoryBoundary.minimumAbstentionHalfWidth,
                        lowerDecision: .noStrongSignalDetected,
                        upperDecision: .signalsConsistentWithAIGeneration
                    )
                ],
                minimumShortEdge: CalibrationPolicy.requiredMinimumShortEdge,
                belowMinimumShortEdgeLabel: .notEnoughSignal,
                requiredQualityFeatures: [],
                qualityRules: [],
                uncoveredQualityInputBehavior: .calibrationInputError,
                evidence: [evidence("evidence.calibration")],
                upstreamBoundaryMetadata: upstreamMetadata()
            )
        } catch {
            preconditionFailure("the calibration policy fixture must be valid: \(error)")
        }
    }

    static func upstreamMetadata() -> UpstreamBoundaryMetadata {
        do {
            return try UpstreamBoundaryMetadata(
                rawLogitValue: UpstreamBoundaryMetadata.requiredValue,
                role: .modelMetadataOnly
            )
        } catch {
            preconditionFailure("the upstream metadata fixture must be valid: \(error)")
        }
    }

    /// A catalogue covering every unconditional surface, all five provenance states, and
    /// the Combined Summary keys the fusion fixture names.
    static func copyCatalog() -> ApprovedVerdictCopyCatalog {
        var surfaces = VerdictCopySurface.unconditionalSurfaces
        for state in ProvenanceStateKey.allCases {
            surfaces.insert(.provenanceState(state))
        }
        let entries = surfaces.sorted { $0.description < $1.description }.map { surface in
            VerdictCopyEntry(
                surface: surface,
                localizationKey: copyKey(
                    "copy.surface."
                        + surface.description.replacingOccurrences(of: "/", with: ".")
                )
            )
        }
        do {
            return try ApprovedVerdictCopyCatalog(
                id: artifact(copyCatalogID),
                schemaVersion: .v1,
                compatibilityID: artifact(copyCompatibilityID),
                languageTag: text(ApprovedVerdictCopyCatalog.requiredLanguageTag),
                entries: entries,
                approval: approval()
            )
        } catch {
            preconditionFailure("the copy catalogue fixture must be valid: \(error)")
        }
    }

    static func provenancePolicy() -> ProvenancePolicy {
        do {
            return try ProvenancePolicy(
                id: artifact(provenancePolicyID),
                schemaVersion: .v1,
                capability: .contentCredentialValidation,
                validatorImplementationVersion: version(validatorVersion),
                validatorBinaryDigest: digest("validator-binary"),
                supportedSpecification: evidence("evidence.c2pa-spec"),
                trustStore: try ProvenanceTrustStoreDescriptor(
                    store: evidence("evidence.trust-store"),
                    anchorCount: count(1),
                    isOfflineOnly: true
                ),
                revocationBehavior: try ProvenanceRevocationBehavior(
                    permitsNetworkRevocationCheck: false,
                    unavailableAnswerState: .indeterminate,
                    approval: approval()
                ),
                supportedAssertionLabels: [text("c2pa.actions")],
                displayableFields: [.signerIdentity],
                processingLimits: ProvenanceProcessingLimits(
                    maximumManifestByteCount: byteCount(1_048_576),
                    maximumAssertionCount: count(32),
                    maximumNestingDepth: count(4),
                    maximumProcessingDuration: duration(5_000)
                ),
                resourceBudget: artifact(mainBudgetID),
                statusMappings: [
                    ProvenanceStatusMapping(status: validatorStatus(), state: .validated)
                ],
                feasibilityApproval: approval()
            )
        } catch {
            preconditionFailure("the provenance policy fixture must be valid: \(error)")
        }
    }

    /// A rule with an entry for every one of the 15 enabled lane combinations.
    static func fusionRule(id: String = CoordinatorSample.fusionRuleID) -> EvidenceFusionRule {
        do {
            return try EvidenceFusionRule(
                id: artifact(id),
                schemaVersion: .v1,
                ruleVersion: version(),
                compatibleVerdictCopy: artifact(copyCompatibilityID),
                fixtureSuite: artifact(fixtureSuiteID),
                entries: FusionLaneCombination.allCombinations.map {
                    FusionEntry(
                        combination: $0,
                        disposition: .show(copyKey("copy.fusion.\($0.pixel.rawValue)")),
                        fixture: fixtureID("fixture.fusion")
                    )
                },
                approval: approval()
            )
        } catch {
            preconditionFailure("the fusion rule fixture must be valid: \(error)")
        }
    }

    static func budgetSet() -> ResourceBudgetSet {
        do {
            return try ResourceBudgetSet(
                mainApplication: budget(for: .mainApplication, id: mainBudgetID),
                shareExtension: budget(for: .shareExtension, id: extensionBudgetID)
            )
        } catch {
            preconditionFailure("the budget set fixture must be valid: \(error)")
        }
    }

    static func budget(for target: ExecutionTarget, id: String) -> ResourceBudget {
        do {
            return try ResourceBudget(
                id: artifact(id),
                schemaVersion: .v1,
                target: target,
                hardLimits: try ResourceMetric.requiredMetrics(for: target)
                    .sorted { $0.rawValue < $1.rawValue }
                    .map { metric in
                        try ResourceLimitEntry(
                            metric: metric,
                            limit: metric.isCategorical
                                ? .thermal(maximumState: .fair)
                                : .numeric(
                                    value: positive(1_000_000),
                                    unit: limitUnit(for: metric)
                                ),
                            measurementConditions: evidence(
                                "evidence.measurement.\(metric.rawValue)"
                            )
                        )
                    },
                validationPlan: artifact(validationPlanID)
            )
        } catch {
            preconditionFailure("the resource budget fixture must be valid: \(error)")
        }
    }

    /// A unit matching each metric's dimension. Only the pairing is meaningful here.
    static func limitUnit(for metric: ResourceMetric) -> ResourceLimitUnit {
        switch metric {
        case .decodedPixelCount: .pixels
        case .encodedInputSize, .peakResidentMemory, .temporaryStorage: .bytes
        case .coldModelLoadTime, .warmAnalysisLatency, .handoffLatency: .milliseconds
        case .energyImpact: .milliwattHours
        case .thermalState: .milliseconds
        }
    }
}

// MARK: - Device values

extension CoordinatorSample {
    static func deviceContext() -> DeviceContext {
        DeviceContext(
            hardwareIdentifier: hardware(),
            osVersion: .iOS17,
            appBuild: Fixture.appBuild(appBuildID),
            environment: .physicalIPhone
        )
    }

    static func candidate() -> CandidateDeviceConfiguration {
        do {
            return try CandidateDeviceConfiguration(
                deviceModel: text("Synthetic iPhone"),
                hardwareIdentifier: hardware(),
                osVersion: .iOS17,
                appBuild: Fixture.appBuild(appBuildID),
                isAppleNeuralEngineCapable: true
            )
        } catch {
            preconditionFailure("the candidate configuration fixture must be valid: \(error)")
        }
    }

    static func versionTuple(capabilities: Set<CapabilityID>) -> ValidationVersionTuple {
        do {
            return try ValidationVersionTuple(
                appBuild: Fixture.appBuild(appBuildID),
                modelBundle: Fixture.bundleID(bundleID),
                fixtureSuite: artifact(fixtureSuiteID),
                validationPlan: artifact(validationPlanID),
                capabilityManifest: artifact(capabilityManifestID),
                capabilities: capabilities,
                capabilityImplementationVersions: implementationVersions(for: capabilities)
            )
        } catch {
            preconditionFailure("the version tuple fixture must be valid: \(error)")
        }
    }

    static func gateEvidence(provenanceEnabled: Bool) -> [GateResultReference] {
        do {
            return try DeviceGate.mandatoryGates
                .sorted { $0.rawValue < $1.rawValue }
                .map { gate in
                    let applicable = !gate.isProvenanceConditional || provenanceEnabled
                    return try GateResultReference(
                        gate: gate,
                        applicability: applicable
                            ? .applicable
                            : .notApplicable(decision: approval()),
                        outcome: applicable ? .passed : .notExecuted,
                        result: evidence("evidence.device.\(gate.rawValue)"),
                        environment: .physicalIPhone
                    )
                }
        } catch {
            preconditionFailure("the gate evidence fixture must be valid: \(error)")
        }
    }

    static func allowlist(provenance: Bool, fusion: Bool) -> ReleaseApprovedDeviceAllowlist {
        let capabilities = capabilities(provenance: provenance, fusion: fusion)
        do {
            return try ReleaseApprovedDeviceAllowlist(
                id: artifact(allowlistID),
                schemaVersion: .v1,
                entries: [
                    try ApprovedDeviceConfiguration(
                        id: Fixture.configurationID(configurationID),
                        configuration: candidate(),
                        versionTuple: versionTuple(capabilities: capabilities),
                        gateEvidence: gateEvidence(provenanceEnabled: provenance)
                    )
                ],
                approval: approval()
            )
        } catch {
            preconditionFailure("the allowlist fixture must be valid: \(error)")
        }
    }
}

// MARK: - Model bundle

extension CoordinatorSample {
    static func componentVersions() -> BundleComponentVersions {
        BundleComponentVersions(
            coreMLModel: artifact(coreMLComponentID),
            preprocessingContract: artifact(preprocessingContractID),
            calibrationPolicy: artifact(calibrationPolicyID),
            evidenceScope: artifact(evidenceScopeID),
            verdictCopyCompatibility: artifact(copyCompatibilityID),
            selfTestSpecification: artifact("component.self-tests")
        )
    }

    static func digestRecord() -> ArtifactDigestRecord {
        ArtifactDigestRecord(
            path: path(),
            kind: .directoryTree,
            byteCount: 4_096,
            digest: digest("model-tree")
        )
    }

    static func bundleManifest(capabilities: Set<CapabilityID>) -> ModelBundleManifest {
        do {
            return try ModelBundleManifest(
                schemaVersion: .v1,
                bundleID: Fixture.bundleID(bundleID),
                modelIdentity: RequiredPixelModel.identity,
                modelFormat: try ModelFormatDescriptor(
                    programKind: .mlProgram,
                    computePrecision: .float16,
                    minimumOS: .iOS17
                ),
                inputContract: modelInputContract(),
                outputContract: modelOutputContract(),
                componentVersions: componentVersions(),
                artifacts: [digestRecord()],
                compatibility: try CompatibilityMatrix(
                    compatibleAppBuilds: [Fixture.appBuild(appBuildID)],
                    requiredCapabilities: capabilities,
                    minimumOS: .iOS17
                ),
                upstreamBoundaryMetadata: upstreamMetadata(),
                signingKey: signingKey()
            )
        } catch {
            preconditionFailure("the bundle manifest fixture must be valid: \(error)")
        }
    }

    /// A receipt whose signature and self-test outcomes both passed, which is the only kind
    /// `BoundModelBundle` accepts. No cryptography ran to produce it.
    static func activationReceipt(generation: Int = 1) -> ActivationReceipt {
        do {
            return try ActivationReceipt(
                id: artifact("receipt.activation.\(generation)"),
                schemaVersion: .v1,
                bundleID: Fixture.bundleID(bundleID),
                verificationPolicy: artifact(verificationPolicyID),
                verifiedManifestDigest: digest("manifest"),
                verifiedArtifactDigests: [digestRecord()],
                signatureOutcome: .passed,
                selfTestOutcome: .passed,
                deviceContext: deviceContext(),
                activationGeneration: count(generation),
                activatedAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
        } catch {
            preconditionFailure("the activation receipt fixture must be valid: \(error)")
        }
    }

    static func boundBundle(
        provenance: Bool = false,
        fusion: Bool = false,
        generation: Int = 1
    ) -> BoundModelBundle {
        guard let bundle = BoundModelBundle(
            manifest: bundleManifest(
                capabilities: capabilities(provenance: provenance, fusion: fusion)
            ),
            receipt: activationReceipt(generation: generation)
        ) else {
            preconditionFailure("the bound bundle fixture must be constructible")
        }
        return bundle
    }

    /// A loaded model matching the bundle's identity, so `requireBoundModel` accepts it.
    static func loadedModel(
        bundle: BoundModelBundle,
        token: UInt64 = 1
    ) -> BoundCoreMLModel {
        guard let model = BoundCoreMLModel(
            bundleID: bundle.bundleID,
            modelIdentity: bundle.modelIdentity,
            coreMLModelVersion: bundle.componentVersions.coreMLModel,
            inputContract: modelInputContract(),
            outputContract: modelOutputContract(),
            model: LoadedModelToken(rawValue: token)
        ) else {
            preconditionFailure("the loaded model fixture must be constructible")
        }
        return model
    }

    /// A loaded model carrying the required checkpoint identity but a different bundle
    /// version, which is what `requireBoundModel` must refuse.
    static func foreignLoadedModel(
        bundleID other: String,
        token: UInt64 = 9
    ) -> BoundCoreMLModel {
        guard let model = BoundCoreMLModel(
            bundleID: Fixture.bundleID(other),
            modelIdentity: RequiredPixelModel.identity,
            coreMLModelVersion: artifact(coreMLComponentID),
            inputContract: modelInputContract(),
            outputContract: modelOutputContract(),
            model: LoadedModelToken(rawValue: token)
        ) else {
            preconditionFailure("the foreign loaded model fixture must be constructible")
        }
        return model
    }
}

// MARK: - The admission

/// A release whose artifacts, allowlist, bundle, and module graph all agree, plus the
/// admission the real startup gate produced from it.
struct CoordinatorRelease {
    let admission: ReleaseAdmission
    let policies: InMemoryArtifactStore
    let bundles: StubModelBundleManager
    let ephemeral: InMemoryEphemeralStore
    let clock: VirtualSessionClock
    let deleter: FakeSessionDataDeleter
    let recorder: PortCallRecorder
    let bundle: BoundModelBundle
    let provenanceEnabled: Bool
    let fusionEnabled: Bool

    /// The Data Lifecycle Policy the admission validated, which terminal cleanup binds.
    var lifecyclePolicy: DataLifecyclePolicy { admission.configuration.lifecyclePolicy }

    /// The main-application Resource Budget this admission governs.
    var mainBudget: ResourceBudget { admission.configuration.resourceBudgets.mainApplication }

    /// Builds the release and runs the real seven-step startup gate over it.
    ///
    /// Every gate is genuinely evaluated: the operating-system floor, the manifest
    /// approval and composition match, the exact allowlist entry and its version tuple,
    /// the active bundle's catalogue membership and component versions, this target's
    /// budget and its validation plan, startup cleanup, and the module-graph comparison.
    static func build(
        provenance: Bool = false,
        fusion: Bool = false
    ) async throws -> CoordinatorRelease {
        let recorder = PortCallRecorder()
        let policies = InMemoryArtifactStore()
        await policies.register(
            CoordinatorSample.capabilityManifest(provenance: provenance, fusion: fusion)
        )
        await policies.register(
            CoordinatorSample.allowlist(provenance: provenance, fusion: fusion)
        )
        await policies.register(CoordinatorSample.lifecyclePolicy())
        await policies.register(CoordinatorSample.extensionExecutionPolicy())
        await policies.register(CoordinatorSample.budgetSet())
        await policies.register(CoordinatorSample.verificationPolicy())
        await policies.register(CoordinatorSample.preprocessingContract())
        await policies.register(CoordinatorSample.calibrationPolicy())
        await policies.register(CoordinatorSample.copyCatalog())
        if provenance { await policies.register(CoordinatorSample.provenancePolicy()) }
        if fusion { await policies.register(CoordinatorSample.fusionRule()) }

        let bundle = CoordinatorSample.boundBundle(provenance: provenance, fusion: fusion)
        let bundles = StubModelBundleManager(recorder: recorder)
        await bundles.installAndActivate(bundle)

        let clock = VirtualSessionClock()
        let ephemeral = InMemoryEphemeralStore(clock: clock)
        let deleter = FakeSessionDataDeleter(
            store: ephemeral,
            clock: clock,
            recorder: recorder
        )

        let preflight = StartupPreflight(
            device: CoordinatorSample.deviceContext(),
            composition: CoordinatorSample.composition(provenance: provenance, fusion: fusion),
            capabilityManifest: CoordinatorSample.artifact(
                CoordinatorSample.capabilityManifestID
            ),
            verdictCopyCatalog: CoordinatorSample.artifact(CoordinatorSample.copyCatalogID),
            embeddedBundle: Fixture.bundleID(CoordinatorSample.bundleID),
            target: .mainApplication
        )
        let admission = try await preflight.run(
            policies: policies,
            bundles: bundles,
            cleanup: deleter
        )
        // The gate reads artifacts, the active bundle, and the cleanup port on its way to an
        // admission. Those calls belong to startup, not to a session, so the log is cleared
        // here and every later assertion is about session work only.
        recorder.reset()
        return CoordinatorRelease(
            admission: admission,
            policies: policies,
            bundles: bundles,
            ephemeral: ephemeral,
            clock: clock,
            deleter: deleter,
            recorder: recorder,
            bundle: bundle,
            provenanceEnabled: provenance,
            fusionEnabled: fusion
        )
    }

    /// A binder over this release's admission and its active bundle.
    func binder() -> AnalysisSessionBinder {
        AnalysisSessionBinder(admission: admission, bundles: bundles)
    }

    /// An accepted ingest that the binder will bind and the stubs will accept.
    ///
    /// The bytes are written into the in-memory ephemeral store, so terminal cleanup has
    /// something real to remove and a receipt's removal count is meaningful.
    func acceptedIngest(
        sessionID raw: String = "session-0001",
        route: InputRoute = .photosPicker,
        byteSeed: UInt8 = 1
    ) async throws -> ImportedEncodedAsset {
        let sessionID = PortValue.sessionID(raw)
        let receipt = try await ephemeral.writeComplete(
            PortValue.bytes(count: 256, seed: byteSeed),
            in: .session(sessionID)
        )
        await deleter.registerLiveSession(sessionID)
        return PortValue.asset(route: route, receipt: receipt)
    }
}

// MARK: - Suspending a branch mid-flight

/// A rendezvous that holds a port call open until a test lets it go.
///
/// This is how a test creates the window the actor-isolation claims are about: with a
/// branch suspended inside a port, the coordinator's `analyze` is itself suspended, so the
/// test can reach the actor while a session is genuinely in flight and observe what a second
/// call does. Bounded so a wiring mistake fails an assertion instead of hanging the suite.
actor BranchGate {
    private var wasReached = false
    private var isOpen = false

    /// Called from inside the port. Suspends until ``openGate()``.
    func enter() async {
        wasReached = true
        var spins = 0
        while !isOpen, spins < 200_000 {
            spins += 1
            await Task.yield()
        }
    }

    /// Suspends until a port call has entered the gate.
    func waitUntilReached() async {
        var spins = 0
        while !wasReached, spins < 200_000 {
            spins += 1
            await Task.yield()
        }
    }

    /// Whether a port call reached the gate.
    func reached() -> Bool { wasReached }

    /// Lets the suspended port call finish.
    func openGate() { isOpen = true }
}

/// A ``PixelAnalyzing`` double that can be held open at the inference boundary.
///
/// Behaves exactly like the plain stub when no gate is supplied, so the harness has one
/// inference path rather than two.
final class GatedPixelAnalyzer: PixelAnalyzing, Sendable {
    private let outcome: StubOutcome<RawLogit>
    private let recorder: PortCallRecorder?
    private let gate: BranchGate?

    init(
        outcome: StubOutcome<RawLogit>,
        recorder: PortCallRecorder? = nil,
        gate: BranchGate? = nil
    ) {
        self.outcome = outcome
        self.recorder = recorder
        self.gate = gate
    }

    func infer(
        _ input: ModelImageInput,
        model: BoundCoreMLModel
    ) async throws(AnalysisFault) -> RawLogit {
        recorder?.record(.infer(input.sessionID))
        if let gate { await gate.enter() }
        return try outcome.resolve()
    }
}

/// An ``EvidenceFusing`` double that refuses every rule it is offered.
///
/// Stands in for the port refusing a rule the session was not bound to. The coordinator
/// always passes the *bound* rule, so a double that compared identifiers could never refuse;
/// what is being tested is what the coordinator does with a ``FusionFault``, which is to
/// omit the summary, record the fault, and still complete (Requirement 7.16).
final class RefusingEvidenceFuser: EvidenceFusing, Sendable {
    private let refusal: FusionFault
    private let recorder: PortCallRecorder?

    init(refusing refusal: FusionFault, recorder: PortCallRecorder? = nil) {
        self.refusal = refusal
        self.recorder = recorder
    }

    func resolve(
        pixel: PixelEvidence,
        provenance: ProvenanceEvidence,
        rule: EvidenceFusionRule,
        binding: AnalysisSessionBinding
    ) throws(FusionFault) -> CombinedSummary? {
        recorder?.record(.fuse)
        throw refusal
    }
}

// MARK: - The coordinator under test

/// A coordinator wired to one release, with every port programmable.
///
/// Ports default to the success path so a test states only the thing it is about, and each
/// records into one shared ``PortCallRecorder`` so nonoccurrence — "no inference after a
/// preprocessing failure", "no provenance analysis for a session that already failed" — is
/// asserted against a call log rather than inferred from a result.
struct CoordinatorHarness {
    let coordinator: AnalysisCoordinator
    let release: CoordinatorRelease
    let recorder: PortCallRecorder
    let binder: AnalysisSessionBinder

    /// Builds a harness over `release`.
    ///
    /// - Parameters:
    ///   - validated: What validation answers. Defaults to an accepted decode stamped with
    ///     the session and the bound contract.
    ///   - prepared: What preprocessing answers.
    ///   - model: What model loading answers.
    ///   - logit: What inference answers.
    ///   - evidence: What calibration answers.
    ///   - provenanceState: The state an enabled validator returns.
    ///   - fuser: The fusion port, or `nil` for a release that shows no summary. Defaults
    ///     to the real-rule lookup double whenever the release binds a rule.
    ///   - classifier: The apparent-inconsistency classifier, or `nil` for none.
    ///   - branchExecution: The approved execution policy. Defaults to serial under the
    ///     release's own validation plan.
    static func make(
        release: CoordinatorRelease,
        validated: StubOutcome<ValidatedImage>? = nil,
        prepared: StubOutcome<ModelImageInput>? = nil,
        model: StubOutcome<BoundCoreMLModel>? = nil,
        logit: StubOutcome<RawLogit>? = nil,
        evidence: StubOutcome<PixelEvidence>? = nil,
        provenanceState: ProvenanceEvidence = .absent,
        fuser: (any EvidenceFusing)? = nil,
        classifier: ApparentInconsistencyClassifier? = nil,
        branchExecution: ApprovedEvidenceBranchExecution? = nil,
        sessionID: String = "session-0001",
        gate: BranchGate? = nil
    ) -> CoordinatorHarness {
        let recorder = release.recorder
        let session = PortValue.sessionID(sessionID)
        let contractID = CoordinatorSample.artifact(CoordinatorSample.preprocessingContractID)
        let analyzer: (any ProvenanceAnalyzing)? = release.provenanceEnabled
            ? StubProvenanceAnalyzer(always: provenanceState, recorder: recorder)
            : nil
        let provider = ProvenanceLaneProvider.resolve(
            analyzer: analyzer,
            policy: release.admission.configuration.provenancePolicy,
            manifest: release.admission.configuration.capabilityManifest
        )
        let resolvedFuser: (any EvidenceFusing)? = fuser
            ?? (release.fusionEnabled ? StubEvidenceFuser(recorder: recorder) : nil)
        let binder = release.binder()
        let coordinator = AnalysisCoordinator(
            binder: binder,
            validator: StubInputValidator(
                outcome: validated
                    ?? StubOutcome(
                        always: PortValue.validatedImage(
                            sessionID: session,
                            preprocessingContractID: contractID
                        )
                    ),
                recorder: recorder
            ),
            preprocessor: StubImagePreprocessor(
                outcome: prepared
                    ?? StubOutcome(
                        always: PortValue.modelInput(
                            sessionID: session,
                            preprocessingContractID: contractID
                        )
                    ),
                recorder: recorder
            ),
            modelLoader: StubPixelModelLoader(
                outcome: model
                    ?? StubOutcome(
                        always: CoordinatorSample.loadedModel(bundle: release.bundle)
                    ),
                recorder: recorder
            ),
            analyzer: GatedPixelAnalyzer(
                outcome: logit ?? StubOutcome(always: PortValue.logit(1.5)),
                recorder: recorder,
                gate: gate
            ),
            calibrator: StubPixelCalibrator(
                outcome: evidence
                    ?? StubOutcome(always: .signalsConsistentWithAIGeneration),
                recorder: recorder
            ),
            provenance: provider,
            fuser: resolvedFuser,
            inconsistencyClassifier: classifier,
            cleanup: SessionTerminalCleanup(
                deleter: release.deleter,
                policy: release.lifecyclePolicy
            ),
            branchExecution: branchExecution
                ?? .serial(
                    validationPlan: CoordinatorSample.artifact(
                        CoordinatorSample.validationPlanID
                    )
                )
        )
        return CoordinatorHarness(
            coordinator: coordinator,
            release: release,
            recorder: recorder,
            binder: binder
        )
    }

    /// A pixel-only harness whose ports all succeed.
    static func pixelOnly(
        sessionID: String = "session-0001"
    ) async throws -> CoordinatorHarness {
        make(release: try await CoordinatorRelease.build(), sessionID: sessionID)
    }
}
