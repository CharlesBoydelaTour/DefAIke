import Foundation

@testable import DefAIkeDomain

// Valid sample artifacts for schema tests.
//
// Every sample is structurally valid and deliberately synthetic. None of these values is
// an approved device, budget, deadline, boundary, trust rule, key, legal conclusion, or
// governance decision: tests mutate one field at a time and assert that the schema
// rejects the mutation.

enum Sample {
    // MARK: Identifiers and scalars

    static func artifact(_ value: String = "artifact.sample") -> ArtifactID {
        ArtifactID(value)!
    }

    static func appBuild(_ value: String = "build.sample") -> AppBuildID {
        AppBuildID(value)!
    }

    static func bundle(_ value: String = "bundle.sample") -> ModelBundleID {
        ModelBundleID(value)!
    }

    static func configuration(_ value: String = "configuration.sample") -> ApprovedConfigurationID {
        ApprovedConfigurationID(value)!
    }

    static func hardware(_ value: String = "iPhone17.1") -> DeviceHardwareID {
        DeviceHardwareID(value)!
    }

    static func signingKey(_ value: String = "key.sample") -> SigningKeyID {
        SigningKeyID(value)!
    }

    static func fixture(_ value: String = "fixture.sample") -> FixtureID {
        FixtureID(value)!
    }

    static func selfTestCase(_ value: String = "self-test.sample") -> SelfTestCaseID {
        SelfTestCaseID(value)!
    }

    static func slice(_ value: String = "slice.sample") -> ReleaseSliceID {
        ReleaseSliceID(value)!
    }

    static func qualityFeature(_ value: String = "quality.short-edge") -> QualityFeatureID {
        QualityFeatureID(value)!
    }

    static func copyKey(_ value: String = "copy.sample") -> ApprovedCopyKey {
        ApprovedCopyKey(value)!
    }

    static func approver(_ value: String = "role.release-owner") -> ApproverID {
        ApproverID(value)!
    }

    static func validatorStatus(_ value: String = "status.signature-valid")
        -> ProvenanceValidatorStatusID
    {
        ProvenanceValidatorStatusID(value)!
    }

    static func digest(_ character: Character = "a") -> SHA256Digest {
        SHA256Digest(hexadecimal: String(repeating: character, count: 64))!
    }

    static func path(_ value: String = "artifacts/model.mlmodelc") -> CanonicalRelativePath {
        CanonicalRelativePath(value)!
    }

    static func text(_ value: String = "Sample text") -> ArtifactText {
        try! ArtifactText(validating: value)
    }

    static func version(_ value: String = "1.0.0") -> SchemaSemanticVersion {
        try! SchemaSemanticVersion(validating: value)
    }

    static func platform(_ value: String = "17.0.0") -> PlatformVersion {
        try! PlatformVersion(validating: value)
    }

    static func duration(milliseconds: UInt64 = 30_000) -> ValidatedDuration {
        try! ValidatedDuration(validating: milliseconds)
    }

    static func count(_ value: Int = 5) -> PositiveCount {
        try! PositiveCount(validating: value)
    }

    static func nonNegative(_ value: Int) -> NonNegativeCount {
        try! NonNegativeCount(validating: value)
    }

    static func byteCount(_ value: UInt64 = 1024) -> PositiveByteCount {
        try! PositiveByteCount(validating: value)
    }

    static func positiveDecimal(_ value: Decimal = 100) -> PositiveDecimal {
        try! PositiveDecimal(validating: value)
    }

    static func nonNegativeDecimal(_ value: Decimal = 0) -> NonNegativeDecimal {
        try! NonNegativeDecimal(validating: value)
    }

    static func ratio(_ value: Decimal) -> UnitInterval {
        try! UnitInterval(validating: value)
    }

    // MARK: Evidence and approvals

    static func evidence(_ identifier: String = "evidence.sample") -> EvidenceSource {
        EvidenceSource(
            artifact: artifact(identifier),
            version: version(),
            contentDigest: digest()
        )
    }

    static func approval(
        _ decision: ApprovalDecision = .approved,
        identifier: String = "approval.sample"
    ) -> ApprovalRecord {
        ApprovalRecord(
            source: evidence(identifier),
            decision: decision,
            approver: approver(),
            decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    static func notApplicable(_ decision: ApprovalDecision = .approved) -> GateApplicability {
        .notApplicable(decision: approval(decision))
    }

    // MARK: Preprocessing

    static func orientationRules(
        _ action: OrientationAction = .applyDeclaredOrientation
    ) throws -> MetadataStateRules<OrientationAction> {
        try MetadataStateRules(
            rules: ImageMetadataState.allCases.map {
                MetadataStateRules<OrientationAction>.Rule(state: $0, action: action)
            }
        )
    }

    static func colorRules() throws -> MetadataStateRules<ColorProfileAction> {
        try MetadataStateRules(
            rules: ImageMetadataState.allCases.map {
                MetadataStateRules<ColorProfileAction>.Rule(
                    state: $0,
                    action: .convertToWorkingSpace
                )
            }
        )
    }

    static func alphaRules() throws -> MetadataStateRules<AlphaAction> {
        try MetadataStateRules(
            rules: ImageMetadataState.allCases.map {
                MetadataStateRules<AlphaAction>.Rule(
                    state: $0,
                    action: .compositeOverOpaqueBackground(
                        OpaqueBackgroundColor(red: 0, green: 0, blue: 0)
                    )
                )
            }
        )
    }

    static func resize(targetShortEdge: Int = ResizeContract.requiredShortEdge) throws
        -> ResizeContract
    {
        try ResizeContract(
            interpolation: .bilinear,
            targetShortEdge: targetShortEdge,
            rounding: .halfUp,
            edgeRule: .clampToEdge,
            pixelCenterConvention: .halfPixelCenters
        )
    }

    static func crop(
        width: Int = CenterCropContract.requiredEdge,
        height: Int = CenterCropContract.requiredEdge
    ) throws -> CenterCropContract {
        try CenterCropContract(width: width, height: height, offsetRule: .floorHalfDifference)
    }

    static func modelInput(
        elementType: ModelElementType = .uint8,
        appliesAppSideNormalization: Bool = false
    ) throws -> ModelInputContract {
        try ModelInputContract(
            featureName: text("image"),
            width: CenterCropContract.requiredEdge,
            height: CenterCropContract.requiredEdge,
            channelOrder: .rgb,
            elementType: elementType,
            appliesAppSideNormalization: appliesAppSideNormalization
        )
    }

    static func modelOutput(featureName: String = ModelOutputContract.requiredFeatureName) throws
        -> ModelOutputContract
    {
        try ModelOutputContract(
            featureName: text(featureName),
            elementType: .float32,
            isPositiveGoing: true
        )
    }

    static func preprocessingContract(
        supportedContainers: Set<StaticContainer> = Set(StaticContainer.allCases)
    ) throws -> PreprocessingContract {
        try PreprocessingContract(
            id: artifact("contract.preprocessing"),
            schemaVersion: .v1,
            supportedContainers: supportedContainers,
            orientationRules: orientationRules(),
            colorProfileRules: colorRules(),
            alphaRules: alphaRules(),
            rgbWorkingSpace: ColorSpaceDescriptor(
                identifier: text("Sample RGB working space"),
                profileDigest: digest("b")
            ),
            resize: resize(),
            crop: crop(),
            modelInput: modelInput()
        )
    }

    // MARK: Calibration

    static func budget(_ rate: Decimal = Decimal(sign: .plus, exponent: -3, significand: 5))
        throws -> FalseAccusationBudget
    {
        try FalseAccusationBudget(validating: rate)
    }

    static func passRule(
        statistic: BudgetPassStatistic = .observedRateAndIntervalUpperBound,
        intervalMethod: ConfidenceIntervalMethod = .wilsonScore
    ) throws -> FalseAccusationPassRule {
        try FalseAccusationPassRule(
            statistic: statistic,
            intervalMethod: intervalMethod,
            confidenceLevel: ratio(FalseAccusationPassRule.requiredConfidenceLevel)
        )
    }

    static func boundary(
        position: Double = 2.5,
        halfWidth: Double = CategoryBoundary.minimumAbstentionHalfWidth,
        lower: PixelLabelKey = .noStrongSignalDetected,
        upper: PixelLabelKey = .signalsConsistentWithAIGeneration
    ) throws -> CategoryBoundary {
        try CategoryBoundary(
            rawLogitBoundary: position,
            abstentionHalfWidth: halfWidth,
            lowerDecision: lower,
            upperDecision: upper
        )
    }

    static func metricCategories() -> [MetricCategoryAssignment] {
        PixelLabelKey.allCases.map {
            MetricCategoryAssignment(label: $0, category: $0.requiredMetricCategory)
        }
    }

    static func upstreamMetadata(
        value: Decimal = UpstreamBoundaryMetadata.requiredValue,
        role: UpstreamBoundaryRole = .modelMetadataOnly
    ) throws -> UpstreamBoundaryMetadata {
        try UpstreamBoundaryMetadata(rawLogitValue: value, role: role)
    }

    static func qualityRule(
        identifier: String = "rule.quality",
        feature: QualityFeatureID = Sample.qualityFeature(),
        condition: QualityCondition = .valueMissing,
        outcome: QualityRuleOutcome = .insufficientSignal,
        evidenceRecords: [EvidenceSource] = [evidence("evidence.quality")]
    ) throws -> QualityDecisionRule {
        try QualityDecisionRule(
            id: artifact(identifier),
            feature: feature,
            condition: condition,
            outcome: outcome,
            evidence: evidenceRecords
        )
    }

    static func calibrationPolicy(
        identifier: String = "policy.calibration",
        minimumShortEdge: Int = CalibrationPolicy.requiredMinimumShortEdge,
        belowMinimumShortEdgeLabel: PixelLabelKey = .notEnoughSignal,
        uncoveredBehavior: UncoveredQualityInputBehavior = .calibrationInputError,
        metricCategories: [MetricCategoryAssignment] = Sample.metricCategories(),
        boundaries: [CategoryBoundary]? = nil,
        qualityRules: [QualityDecisionRule] = [],
        requiredQualityFeatures: Set<QualityFeatureID> = [Sample.qualityFeature()],
        compatibleModel: ModelIdentity = RequiredPixelModel.identity,
        compatiblePreprocessing: String = "contract.preprocessing",
        compatibleVerdictCopy: String = "copy.compatibility",
        budget declaredBudget: FalseAccusationBudget? = nil,
        passRule declaredPassRule: FalseAccusationPassRule? = nil,
        evidenceRecords: [EvidenceSource] = [evidence("evidence.calibration")]
    ) throws -> CalibrationPolicy {
        try CalibrationPolicy(
            id: artifact(identifier),
            schemaVersion: .v1,
            compatibleModel: compatibleModel,
            compatiblePreprocessing: artifact(compatiblePreprocessing),
            compatibleVerdictCopy: artifact(compatibleVerdictCopy),
            falseAccusationBudget: try declaredBudget ?? budget(),
            releasePassRule: try declaredPassRule ?? passRule(),
            outputLabels: Set(PixelLabelKey.allCases),
            metricCategories: metricCategories,
            boundaries: try boundaries ?? [boundary()],
            minimumShortEdge: minimumShortEdge,
            belowMinimumShortEdgeLabel: belowMinimumShortEdgeLabel,
            requiredQualityFeatures: requiredQualityFeatures,
            qualityRules: qualityRules,
            uncoveredQualityInputBehavior: uncoveredBehavior,
            evidence: evidenceRecords,
            upstreamBoundaryMetadata: upstreamMetadata()
        )
    }

    static func outcomeCounts() throws -> SliceOutcomeCounts {
        try SliceOutcomeCounts(
            eligibleRealImages: nonNegative(100),
            eligibleSyntheticImages: nonNegative(80),
            realPositiveLabels: nonNegative(1),
            realNonPositiveLabels: nonNegative(85),
            realInsufficientLabels: nonNegative(14),
            syntheticPositiveLabels: nonNegative(60),
            syntheticNonPositiveLabels: nonNegative(10),
            syntheticInsufficientLabels: nonNegative(10),
            errorCount: nonNegative(0)
        )
    }

    static func interval(
        method: ConfidenceIntervalMethod = .wilsonScore,
        level: Decimal = FalseAccusationPassRule.requiredConfidenceLevel,
        lower: Decimal = 0,
        upper: Decimal = Decimal(sign: .plus, exponent: -2, significand: 1)
    ) throws -> ConfidenceIntervalResult {
        try ConfidenceIntervalResult(
            method: method,
            confidenceLevel: ratio(level),
            lowerBound: ratio(lower),
            upperBound: ratio(upper)
        )
    }

    // MARK: Provenance and fusion

    static func revocationBehavior(
        unavailableAnswerState: ProvenanceStateKey = .indeterminate,
        permitsNetwork: Bool = false
    ) throws -> ProvenanceRevocationBehavior {
        try ProvenanceRevocationBehavior(
            permitsNetworkRevocationCheck: permitsNetwork,
            unavailableAnswerState: unavailableAnswerState,
            approval: approval()
        )
    }

    /// The reviewed validator version the samples pin. A synthetic value.
    static let sampleValidatorVersion = "0.0.12"

    static func provenancePolicy(
        capability: CapabilityID = .contentCredentialValidation,
        validatorImplementationVersion: String = Sample.sampleValidatorVersion,
        resourceBudget: String = "budget.main-application",
        feasibility: ApprovalDecision = .approved
    ) throws -> ProvenancePolicy {
        try ProvenancePolicy(
            id: artifact("policy.provenance"),
            schemaVersion: .v1,
            capability: capability,
            validatorImplementationVersion: version(validatorImplementationVersion),
            validatorBinaryDigest: digest("c"),
            supportedSpecification: evidence("evidence.c2pa-spec"),
            trustStore: ProvenanceTrustStoreDescriptor(
                store: evidence("evidence.trust-store"),
                anchorCount: count(3),
                isOfflineOnly: true
            ),
            revocationBehavior: revocationBehavior(),
            supportedAssertionLabels: [text("c2pa.actions")],
            displayableFields: [.signerIdentity, .bindingStatus],
            processingLimits: ProvenanceProcessingLimits(
                maximumManifestByteCount: byteCount(1_048_576),
                maximumAssertionCount: count(64),
                maximumNestingDepth: count(8),
                maximumProcessingDuration: duration(milliseconds: 5_000)
            ),
            resourceBudget: artifact(resourceBudget),
            statusMappings: [
                ProvenanceStatusMapping(status: validatorStatus(), state: .validated)
            ],
            feasibilityApproval: approval(feasibility, identifier: "approval.feasibility")
        )
    }

    static func fusionEntries(
        dropping dropped: FusionLaneCombination? = nil,
        duplicating duplicated: FusionLaneCombination? = nil
    ) -> [FusionEntry] {
        var entries = FusionLaneCombination.allCombinations
            .filter { $0 != dropped }
            .map {
                FusionEntry(
                    combination: $0,
                    disposition: .show(copyKey("copy.fusion.\($0.pixel.rawValue)")),
                    fixture: fixture("fixture.fusion")
                )
            }
        if let duplicated {
            entries.append(
                FusionEntry(
                    combination: duplicated,
                    disposition: .omit,
                    fixture: fixture("fixture.fusion.duplicate")
                )
            )
        }
        return entries
    }

    static func fusionRule(
        entries: [FusionEntry] = Sample.fusionEntries(),
        compatibleVerdictCopy: String = "copy.compatibility"
    ) throws -> EvidenceFusionRule {
        try EvidenceFusionRule(
            id: artifact("rule.fusion"),
            schemaVersion: .v1,
            ruleVersion: version(),
            compatibleVerdictCopy: artifact(compatibleVerdictCopy),
            fixtureSuite: artifact("suite.fixtures"),
            entries: entries,
            approval: approval()
        )
    }

    // MARK: Lifecycle and resources

    static func lifecyclePolicy(
        reasons: [SessionCleanupReason] = SessionCleanupReason.allCases
    ) throws -> DataLifecyclePolicy {
        try DataLifecyclePolicy(
            id: artifact("policy.lifecycle"),
            schemaVersion: .v1,
            deadlines: reasons.map {
                DataLifecyclePolicy.Deadline(reason: $0, deadline: duration())
            },
            approval: approval()
        )
    }

    static func extensionExecutionPolicy(
        consent: Bool = true,
        delegates: Bool = true,
        pending: PendingHandoffPolicy = .instructRecovery
    ) throws -> ExtensionExecutionPolicy {
        try ExtensionExecutionPolicy(
            id: artifact("policy.extension-execution"),
            schemaVersion: .v1,
            requiresVisibleConsent: consent,
            delegatesInferenceToMainApplication: delegates,
            stagedFileProtection: .complete,
            pendingHandoffPolicy: pending,
            protectionEvidence: evidence("evidence.file-protection")
        )
    }

    static func limit(for metric: ResourceMetric) throws -> ValidatedLimit {
        metric.isCategorical
            ? .thermal(maximumState: .fair)
            : .numeric(value: positiveDecimal(), unit: unit(for: metric))
    }

    static func unit(for metric: ResourceMetric) -> ResourceLimitUnit {
        switch metric {
        case .decodedPixelCount: .pixels
        case .peakResidentMemory, .temporaryStorage, .encodedInputSize: .bytes
        case .coldModelLoadTime, .warmAnalysisLatency, .handoffLatency: .milliseconds
        case .energyImpact: .milliwattHours
        case .thermalState: .milliseconds
        }
    }

    static func resourceBudget(
        target: ExecutionTarget,
        identifier: String? = nil,
        metrics: Set<ResourceMetric>? = nil,
        validationPlan: String = "plan.device-validation"
    ) throws -> ResourceBudget {
        let resolved = metrics ?? ResourceMetric.requiredMetrics(for: target)
        return try ResourceBudget(
            id: artifact(identifier ?? "budget.\(target.rawValue)"),
            schemaVersion: .v1,
            target: target,
            hardLimits: try resolved.sorted { $0.rawValue < $1.rawValue }.map {
                try ResourceLimitEntry(
                    metric: $0,
                    limit: limit(for: $0),
                    measurementConditions: evidence("evidence.measurement")
                )
            },
            validationPlan: artifact(validationPlan)
        )
    }

    static func budgetSet(
        mainApplicationPlan: String = "plan.device-validation",
        shareExtensionPlan: String = "plan.device-validation"
    ) throws -> ResourceBudgetSet {
        try ResourceBudgetSet(
            mainApplication: resourceBudget(
                target: .mainApplication,
                validationPlan: mainApplicationPlan
            ),
            shareExtension: resourceBudget(
                target: .shareExtension,
                validationPlan: shareExtensionPlan
            )
        )
    }

    // MARK: Bundle

    static func modelFormat(
        programKind: ModelProgramKind = .mlProgram,
        precision: ModelComputePrecision = .float16,
        minimumOS: PlatformVersion = .iOS17
    ) throws -> ModelFormatDescriptor {
        try ModelFormatDescriptor(
            programKind: programKind,
            computePrecision: precision,
            minimumOS: minimumOS
        )
    }

    static func componentVersions() -> BundleComponentVersions {
        BundleComponentVersions(
            coreMLModel: artifact("component.coreml"),
            preprocessingContract: artifact("contract.preprocessing"),
            calibrationPolicy: artifact("policy.calibration"),
            evidenceScope: artifact("component.scope"),
            verdictCopyCompatibility: artifact("copy.compatibility"),
            selfTestSpecification: artifact("component.self-tests")
        )
    }

    static func compatibilityMatrix(
        capabilities: Set<CapabilityID> = [.pixelAnalysis]
    ) throws -> CompatibilityMatrix {
        try CompatibilityMatrix(
            compatibleAppBuilds: [appBuild()],
            requiredCapabilities: capabilities,
            minimumOS: .iOS17
        )
    }

    static func digestRecord(
        path pathValue: String = "artifacts/model.mlmodelc",
        byteCount: UInt64 = 4096,
        kind: ArtifactDigestRecord.Kind = .directoryTree
    ) -> ArtifactDigestRecord {
        ArtifactDigestRecord(
            path: path(pathValue),
            kind: kind,
            byteCount: byteCount,
            digest: digest("d")
        )
    }

    static func manifest(
        modelIdentity: ModelIdentity = RequiredPixelModel.identity,
        artifacts: [ArtifactDigestRecord] = [Sample.digestRecord()]
    ) throws -> ModelBundleManifest {
        try ModelBundleManifest(
            schemaVersion: .v1,
            bundleID: bundle(),
            modelIdentity: modelIdentity,
            modelFormat: modelFormat(),
            inputContract: modelInput(),
            outputContract: modelOutput(),
            componentVersions: componentVersions(),
            artifacts: artifacts,
            compatibility: compatibilityMatrix(),
            upstreamBoundaryMetadata: upstreamMetadata(),
            signingKey: signingKey()
        )
    }

    static func trustedKey(
        status: SigningKeyStatus = .active,
        algorithm: SignatureAlgorithm = .ed25519
    ) -> TrustedSigningKey {
        TrustedSigningKey(
            key: signingKey(),
            algorithm: algorithm,
            publicKeyDigest: digest("e"),
            status: status,
            governanceApproval: approval()
        )
    }

    static func verificationPolicy(
        trustedKeys: [TrustedSigningKey] = [Sample.trustedKey()],
        revocationBehavior: KeyRevocationBehavior = .rejectBundle
    ) throws -> BundleVerificationPolicy {
        try BundleVerificationPolicy(
            id: artifact("policy.bundle-verification"),
            schemaVersion: .v1,
            algorithm: .ed25519,
            canonicalizationProfile: evidence("evidence.canonicalization"),
            trustedKeys: trustedKeys,
            rotationBehavior: .activeKeysOnly,
            revocationBehavior: revocationBehavior,
            maximumManifestByteCount: byteCount(65_536),
            reproducibilityEvidence: evidence("evidence.reproducibility")
        )
    }

    static func deviceContext(
        environment: ExecutionEnvironment = .physicalIPhone
    ) -> DeviceContext {
        DeviceContext(
            hardwareIdentifier: hardware(),
            osVersion: platform(),
            appBuild: appBuild(),
            environment: environment
        )
    }

    static func activationReceipt(
        signatureOutcome: GateOutcome = .passed,
        selfTestOutcome: GateOutcome = .passed
    ) throws -> ActivationReceipt {
        try ActivationReceipt(
            id: artifact("receipt.activation"),
            schemaVersion: .v1,
            bundleID: bundle(),
            verificationPolicy: artifact("policy.bundle-verification"),
            verifiedManifestDigest: digest("f"),
            verifiedArtifactDigests: [digestRecord()],
            signatureOutcome: signatureOutcome,
            selfTestOutcome: selfTestOutcome,
            deviceContext: deviceContext(),
            activationGeneration: count(1),
            activatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    // MARK: Capability manifest

    static func policyCompatibility(
        provenance: ConditionalArtifactBinding<ArtifactID> = .notApplicable(
            decision: Sample.approval()
        ),
        fusion: ConditionalArtifactBinding<ArtifactID> = .notApplicable(
            decision: Sample.approval()
        )
    ) throws -> PolicyCompatibilitySet {
        try PolicyCompatibilitySet(
            preprocessingContract: artifact("contract.preprocessing"),
            calibrationPolicy: artifact("policy.calibration"),
            lifecyclePolicy: artifact("policy.lifecycle"),
            extensionExecutionPolicy: artifact("policy.extension-execution"),
            mainApplicationResourceBudget: artifact("budget.main-application"),
            shareExtensionResourceBudget: artifact("budget.share-extension"),
            bundleVerificationPolicy: artifact("policy.bundle-verification"),
            verdictCopyCompatibility: artifact("copy.compatibility"),
            provenancePolicy: provenance,
            fusionRule: fusion
        )
    }

    static func capabilityManifest(
        capabilities: Set<CapabilityID> = [.pixelAnalysis],
        policyCompatibility: PolicyCompatibilitySet? = nil,
        implementationVersions: [CapabilityImplementationEntry]? = nil
    ) throws -> ReleaseCapabilityManifest {
        try ReleaseCapabilityManifest(
            id: artifact("manifest.capability"),
            schemaVersion: .v1,
            appBuild: appBuild(),
            compositionIdentifier: text("pixel-only"),
            compiledCapabilities: capabilities,
            implementationVersions: implementationVersions
                ?? capabilities.sorted { $0.rawValue < $1.rawValue }.map {
                    CapabilityImplementationEntry(capability: $0, version: version())
                },
            approvedConfigurationAllowlist: artifact("allowlist.devices"),
            approvedBundleCatalog: [bundle()],
            policyCompatibility: try policyCompatibility ?? self.policyCompatibility(),
            approval: approval()
        )
    }

    // MARK: Devices

    static func candidate(
        osVersion: PlatformVersion = .iOS17,
        appleNeuralEngineCapable: Bool = true
    ) throws -> CandidateDeviceConfiguration {
        try CandidateDeviceConfiguration(
            deviceModel: text("Sample iPhone"),
            hardwareIdentifier: hardware(),
            osVersion: osVersion,
            appBuild: appBuild(),
            isAppleNeuralEngineCapable: appleNeuralEngineCapable
        )
    }

    static func versionTuple(
        capabilities: Set<CapabilityID> = [.pixelAnalysis]
    ) throws -> ValidationVersionTuple {
        try ValidationVersionTuple(
            appBuild: appBuild(),
            modelBundle: bundle(),
            fixtureSuite: artifact("suite.fixtures"),
            validationPlan: artifact("plan.device-validation"),
            capabilityManifest: artifact("manifest.capability"),
            capabilities: capabilities,
            capabilityImplementationVersions: capabilities.sorted { $0.rawValue < $1.rawValue }
                .map { CapabilityImplementationEntry(capability: $0, version: version()) }
        )
    }

    static func gateReferences(
        provenanceEnabled: Bool = false,
        failing: Set<DeviceGate> = [],
        gates: Set<DeviceGate> = DeviceGate.mandatoryGates
    ) throws -> [GateResultReference] {
        try gates.sorted { $0.rawValue < $1.rawValue }.map { gate in
            let applicable = !gate.isProvenanceConditional || provenanceEnabled
            return try GateResultReference(
                gate: gate,
                applicability: applicable ? .applicable : notApplicable(),
                outcome: applicable ? (failing.contains(gate) ? .failed : .passed) : .notExecuted,
                result: evidence("evidence.device.\(gate.rawValue)"),
                environment: .physicalIPhone
            )
        }
    }

    static func approvedConfiguration(
        provenanceEnabled: Bool = false,
        failing: Set<DeviceGate> = []
    ) throws -> ApprovedDeviceConfiguration {
        let capabilities: Set<CapabilityID> = provenanceEnabled
            ? [.pixelAnalysis, .contentCredentialValidation]
            : [.pixelAnalysis]
        return try ApprovedDeviceConfiguration(
            id: configuration(),
            configuration: candidate(),
            versionTuple: versionTuple(capabilities: capabilities),
            gateEvidence: gateReferences(provenanceEnabled: provenanceEnabled, failing: failing)
        )
    }

    static func allowlist(
        entries: [ApprovedDeviceConfiguration]
    ) throws -> ReleaseApprovedDeviceAllowlist {
        try ReleaseApprovedDeviceAllowlist(
            id: artifact("allowlist.devices"),
            schemaVersion: .v1,
            entries: entries,
            approval: approval()
        )
    }

    // MARK: Release readiness

    static func gateRecords(
        provenanceApplicable: Bool = false,
        fusionApplicable: Bool = false,
        overrides: [ReleaseGate: GateOutcome] = [:],
        gates: [ReleaseGate] = ReleaseGate.allCases
    ) throws -> [ReleaseGateRecord] {
        try gates.map { gate in
            let applicable: Bool
            switch gate {
            case .provenanceFeasibility: applicable = provenanceApplicable
            case .fusionRuleApproval: applicable = fusionApplicable
            default: applicable = true
            }
            return try ReleaseGateRecord(
                gate: gate,
                applicability: applicable ? .applicable : notApplicable(),
                outcome: applicable ? (overrides[gate] ?? .passed) : .notExecuted,
                evidence: evidence("evidence.release.\(gate.rawValue)")
            )
        }
    }

    static func distributionRights(
        code: ApprovalDecision = .approved,
        data: ApprovalDecision = .approved
    ) -> DistributionRightsRecord {
        DistributionRightsRecord(
            repositoryCodeLicense: approval(code, identifier: "approval.code-license"),
            datasetDistributionTerms: approval(data, identifier: "approval.dataset-terms")
        )
    }

    static func governance(
        decision: ApprovalDecision = .approved
    ) throws -> ModelGovernanceDecisionRecord {
        try ModelGovernanceDecisionRecord(
            modelIdentity: RequiredPixelModel.identity,
            isIndependentNonPeerReviewed: true,
            redTeamValidationValid: false,
            inheritedRedTeamStatus: .invalidNoReportInherited,
            decision: approval(decision, identifier: "approval.governance")
        )
    }

    static func releaseRecord(
        provenanceApplicable: Bool = false,
        fusionApplicable: Bool = false,
        overrides: [ReleaseGate: GateOutcome] = [:],
        gateRecords: [ReleaseGateRecord]? = nil
    ) throws -> ReleaseReadinessRecord {
        try ReleaseReadinessRecord(
            id: artifact("record.release-readiness"),
            schemaVersion: .v1,
            appBuild: appBuild(),
            capabilityManifest: artifact("manifest.capability"),
            modelBundle: bundle(),
            deviceAllowlist: artifact("allowlist.devices"),
            gateRecords: try gateRecords
                ?? self.gateRecords(
                    provenanceApplicable: provenanceApplicable,
                    fusionApplicable: fusionApplicable,
                    overrides: overrides
                ),
            distributionRights: distributionRights(),
            modelGovernance: governance(),
            benchmarkClaims: []
        )
    }

    // MARK: Fixtures, copy, matrices

    static func fixtureRecord(
        family: FixtureFamily = .modelParity,
        identifier: String = "fixture.sample",
        assetPath: String = "fixtures/sample.jpg",
        expectations: [FixtureExpectation]? = nil
    ) throws -> FixtureRecord {
        let resolved: [FixtureExpectation] = expectations
            ?? (family.isProvenanceConditional
                ? [.provenanceState(.validated)]
                : [.pixelLabel(.noStrongSignalDetected)])
        return try FixtureRecord(
            id: fixture(identifier),
            family: family,
            assetPath: path(assetPath),
            contentDigest: digest("1"),
            byteCount: byteCount(),
            source: evidence("evidence.fixture"),
            expectations: resolved
        )
    }

    static func fixtureSuite(
        provenanceApplicability: GateApplicability = Sample.notApplicable(),
        fixtures: [FixtureRecord]? = nil
    ) throws -> ReleaseFixtureSuite {
        try ReleaseFixtureSuite(
            id: artifact("suite.fixtures"),
            schemaVersion: .v1,
            provenanceApplicability: provenanceApplicability,
            fixtures: try fixtures ?? [fixtureRecord()]
        )
    }

    static func copyEntries(
        surfaces: Set<VerdictCopySurface> = VerdictCopySurface.unconditionalSurfaces
    ) -> [VerdictCopyEntry] {
        surfaces.sorted { $0.description < $1.description }.map {
            VerdictCopyEntry(
                surface: $0,
                localizationKey: copyKey("copy.\($0.description.replacingOccurrences(of: "/", with: "."))")
            )
        }
    }

    static func copyCatalog(
        languageTag: String = ApprovedVerdictCopyCatalog.requiredLanguageTag,
        entries: [VerdictCopyEntry]? = nil,
        compatibilityID: String = "copy.compatibility"
    ) throws -> ApprovedVerdictCopyCatalog {
        try ApprovedVerdictCopyCatalog(
            id: artifact("catalog.verdict-copy"),
            schemaVersion: .v1,
            compatibilityID: artifact(compatibilityID),
            languageTag: text(languageTag),
            entries: entries ?? copyEntries(),
            approval: approval()
        )
    }

    static func accessibilityMatrix(
        workflows: [AccessibilityWorkflow] = AccessibilityWorkflow.allCases,
        failing: Bool = false,
        manualWithoutApproval: Bool = false
    ) throws -> AccessibilityGateMatrix {
        let configurations = [configuration()]
        let versions = [PlatformVersion.iOS17.majorVersion]
        var accessibilityCells: [AccessibilityResultCell] = []
        for workflow in workflows {
            for condition in AssistiveCondition.allCases {
                for version in versions {
                    for entry in configurations {
                        accessibilityCells.append(
                            try AccessibilityResultCell(
                                workflow: workflow,
                                condition: condition,
                                osMajorVersion: version,
                                configuration: entry,
                                outcome: failing ? .failed : .passed,
                                execution: manualWithoutApproval
                                    ? .manual(importedEvidence: approval(.rejected))
                                    : .automated,
                                evidence: evidence("evidence.accessibility")
                            )
                        )
                    }
                }
            }
        }
        var localizationCells: [LocalizationResultCell] = []
        for workflow in workflows {
            for variant in LocalizationTestVariant.allCases {
                for version in versions {
                    for entry in configurations {
                        localizationCells.append(
                            try LocalizationResultCell(
                                workflow: workflow,
                                variant: variant,
                                osMajorVersion: version,
                                configuration: entry,
                                outcome: failing ? .failed : .passed,
                                execution: .automated,
                                evidence: evidence("evidence.localization")
                            )
                        )
                    }
                }
            }
        }
        return try AccessibilityGateMatrix(
            id: artifact("matrix.accessibility"),
            schemaVersion: .v1,
            configurations: configurations,
            supportedMajorVersions: versions,
            accessibilityCells: accessibilityCells,
            localizationCells: localizationCells
        )
    }
}
