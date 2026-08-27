import DefAIkeDomain
import Foundation

@testable import DefAIkeModelBundle
@testable import DefAIkeReleaseValidation

// Synthetic approved inputs, staged content, and doubles for Initial Model Bundle creation.
//
// Nothing here is an approved release input. The policies, identifiers, notices, fixtures,
// and paths are synthetic: each test builds one structurally complete bundle, changes exactly
// one thing, and asserts what the builder or the runtime verifier does about it.
//
// Three choices are what make these doubles able to prove anything, and each one is load
// bearing:
//
//   * **The measurement seam is the runtime's own code.** `StagedMeasuringSeam` computes
//     nothing. It calls ``StreamingSHA256`` and ``BundleTreeDigest`` from
//     `DefAIkeModelBundle` — reachable here only because this file is `@testable` — so the
//     digests a build declares are produced by the exact implementation the verifier
//     re-derives them with. A second implementation in the tests would let the two agree on a
//     rule neither of them is actually following.
//   * **The materializer copies, it does not decide.** `MaterializedBundle` places the plan's
//     bytes at the plan's paths and nothing else. It has no digest, no ordering, and no
//     canonicalization logic, so a passing verification is evidence about the *builder's*
//     output rather than about the materializer's cleverness.
//   * **The signature stand-in binds key material to message bytes.** It is not cryptography
//     and not a release key, but altering a signed manifest really does break it, so a
//     signature check here is byte-sensitive rather than nominal.

// MARK: - Identifiers and approved scalars

extension Sample {
    static func signingKey(_ value: String = "key.release") -> SigningKeyID {
        SigningKeyID(value)!
    }

    static func selfTestCaseID(_ value: String = "self-test.sample") -> SelfTestCaseID {
        SelfTestCaseID(value)!
    }

    static func qualityFeature(_ value: String = "quality.short-edge") -> QualityFeatureID {
        QualityFeatureID(value)!
    }

    static func duration(milliseconds: UInt64 = 30_000) -> ValidatedDuration {
        try! ValidatedDuration(validating: milliseconds)
    }

    /// The one checkpoint identity Requirement 10.2 permits.
    static var requiredCheckpoint: ModelCheckpointIdentifier {
        RequiredPixelModel.identity.checkpointIdentifier
    }

    static func checkpoint(_ value: String) -> ModelCheckpointIdentifier {
        ModelCheckpointIdentifier(value)!
    }
}

// MARK: - Approved contracts and policies

extension Sample {
    static func modelInput(featureName: String = "image") -> ModelInputContract {
        try! ModelInputContract(
            featureName: text(featureName),
            width: CenterCropContract.requiredEdge,
            height: CenterCropContract.requiredEdge,
            channelOrder: .rgb,
            elementType: .uint8,
            appliesAppSideNormalization: false
        )
    }

    static func modelOutput() -> ModelOutputContract {
        try! ModelOutputContract(
            featureName: text(ModelOutputContract.requiredFeatureName),
            elementType: .float32,
            isPositiveGoing: true
        )
    }

    static func preprocessingContract(
        identifier: String = "contract.preprocessing",
        modelInputFeatureName: String = "image"
    ) throws -> PreprocessingContract {
        try PreprocessingContract(
            id: artifact(identifier),
            schemaVersion: .v1,
            supportedContainers: Set(StaticContainer.allCases),
            orientationRules: try MetadataStateRules(
                rules: ImageMetadataState.allCases.map {
                    MetadataStateRules<OrientationAction>.Rule(
                        state: $0,
                        action: .applyDeclaredOrientation
                    )
                }
            ),
            colorProfileRules: try MetadataStateRules(
                rules: ImageMetadataState.allCases.map {
                    MetadataStateRules<ColorProfileAction>.Rule(
                        state: $0,
                        action: .convertToWorkingSpace
                    )
                }
            ),
            alphaRules: try MetadataStateRules(
                rules: ImageMetadataState.allCases.map {
                    MetadataStateRules<AlphaAction>.Rule(
                        state: $0,
                        action: .compositeOverOpaqueBackground(
                            OpaqueBackgroundColor(red: 0, green: 0, blue: 0)
                        )
                    )
                }
            ),
            rgbWorkingSpace: ColorSpaceDescriptor(
                identifier: text("Sample RGB working space"),
                profileDigest: digest(0xB1)
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
            modelInput: modelInput(featureName: modelInputFeatureName)
        )
    }

    static func calibrationPolicy(
        identifier: String = "policy.calibration"
    ) throws -> CalibrationPolicy {
        try CalibrationPolicy(
            id: artifact(identifier),
            schemaVersion: .v1,
            compatibleModel: RequiredPixelModel.identity,
            compatiblePreprocessing: artifact("contract.preprocessing"),
            compatibleVerdictCopy: artifact("copy.compatibility"),
            falseAccusationBudget: try FalseAccusationBudget(
                validating: Decimal(sign: .plus, exponent: -3, significand: 5)
            ),
            releasePassRule: try FalseAccusationPassRule(
                statistic: .observedRateAndIntervalUpperBound,
                intervalMethod: .wilsonScore,
                confidenceLevel: ratio(FalseAccusationPassRule.requiredConfidenceLevel)
            ),
            outputLabels: Set(PixelLabelKey.allCases),
            metricCategories: PixelLabelKey.allCases.map {
                MetricCategoryAssignment(label: $0, category: $0.requiredMetricCategory)
            },
            boundaries: [
                try CategoryBoundary(
                    rawLogitBoundary: 2.5,
                    abstentionHalfWidth: CategoryBoundary.minimumAbstentionHalfWidth,
                    lowerDecision: .noStrongSignalDetected,
                    upperDecision: .signalsConsistentWithAIGeneration
                )
            ],
            minimumShortEdge: CalibrationPolicy.requiredMinimumShortEdge,
            belowMinimumShortEdgeLabel: .notEnoughSignal,
            requiredQualityFeatures: [qualityFeature()],
            qualityRules: [],
            uncoveredQualityInputBehavior: .calibrationInputError,
            evidence: [evidence("evidence.calibration")],
            upstreamBoundaryMetadata: upstreamMetadata()
        )
    }

    static func upstreamMetadata() -> UpstreamBoundaryMetadata {
        try! UpstreamBoundaryMetadata(
            rawLogitValue: UpstreamBoundaryMetadata.requiredValue,
            role: .modelMetadataOnly
        )
    }

    static func lifecyclePolicy() throws -> DataLifecyclePolicy {
        try DataLifecyclePolicy(
            id: artifact("policy.lifecycle"),
            schemaVersion: .v1,
            deadlines: SessionCleanupReason.allCases.map {
                DataLifecyclePolicy.Deadline(reason: $0, deadline: duration())
            },
            approval: approval()
        )
    }

    static func extensionExecutionPolicy() throws -> ExtensionExecutionPolicy {
        try ExtensionExecutionPolicy(
            id: artifact("policy.extension-execution"),
            schemaVersion: .v1,
            requiresVisibleConsent: true,
            delegatesInferenceToMainApplication: true,
            stagedFileProtection: .complete,
            pendingHandoffPolicy: .instructRecovery,
            protectionEvidence: evidence("evidence.file-protection")
        )
    }

    static func resourceBudget(target: ExecutionTarget) throws -> ResourceBudget {
        try ResourceBudget(
            id: artifact("budget.\(target.rawValue)"),
            schemaVersion: .v1,
            target: target,
            hardLimits: try ResourceMetric.requiredMetrics(for: target)
                .sorted { $0.rawValue < $1.rawValue }
                .map { metric in
                    try ResourceLimitEntry(
                        metric: metric,
                        limit: limit(for: metric),
                        measurementConditions: evidence("evidence.measurement")
                    )
                },
            validationPlan: artifact("plan.device-validation")
        )
    }

    static func budgetSet() throws -> ResourceBudgetSet {
        try ResourceBudgetSet(
            mainApplication: try resourceBudget(target: .mainApplication),
            shareExtension: try resourceBudget(target: .shareExtension)
        )
    }

    static func copyCatalog() throws -> ApprovedVerdictCopyCatalog {
        try ApprovedVerdictCopyCatalog(
            id: artifact("catalog.verdict-copy"),
            schemaVersion: .v1,
            compatibilityID: artifact("copy.compatibility"),
            languageTag: text(ApprovedVerdictCopyCatalog.requiredLanguageTag),
            entries: VerdictCopySurface.unconditionalSurfaces
                .sorted { $0.description < $1.description }
                .map { surface in
                    VerdictCopyEntry(
                        surface: surface,
                        localizationKey: copyKey(
                            "copy."
                                + surface.description.replacingOccurrences(of: "/", with: ".")
                        )
                    )
                },
            approval: approval()
        )
    }

    static func capabilityManifest(
        catalog: [ModelBundleID]? = nil
    ) throws -> ReleaseCapabilityManifest {
        try ReleaseCapabilityManifest(
            id: artifact("manifest.capability"),
            schemaVersion: .v1,
            appBuild: appBuild(),
            compositionIdentifier: text("pixel-only"),
            compiledCapabilities: [.pixelAnalysis],
            implementationVersions: [
                CapabilityImplementationEntry(
                    capability: .pixelAnalysis,
                    version: try CapabilityImplementationVersion(validating: "1.0.0")
                )
            ],
            approvedConfigurationAllowlist: artifact("allowlist.devices"),
            approvedBundleCatalog: catalog ?? [bundle(), rollbackBundle()],
            policyCompatibility: try PolicyCompatibilitySet(
                preprocessingContract: artifact("contract.preprocessing"),
                calibrationPolicy: artifact("policy.calibration"),
                lifecyclePolicy: artifact("policy.lifecycle"),
                extensionExecutionPolicy: artifact("policy.extension-execution"),
                mainApplicationResourceBudget: artifact("budget.main-application"),
                shareExtensionResourceBudget: artifact("budget.share-extension"),
                bundleVerificationPolicy: artifact("policy.bundle-verification"),
                verdictCopyCompatibility: artifact("copy.compatibility"),
                provenancePolicy: .notApplicable(decision: approval()),
                fusionRule: .notApplicable(decision: approval())
            ),
            approval: approval()
        )
    }

    /// The prior bundle a rollback demonstration names. Synthetic, and supplied rather than
    /// inferred: which bundle a release rolls back to is a release decision.
    static func rollbackBundle() -> ModelBundleID {
        ModelBundleID("bundle.prior")!
    }

    static func canonicalizationProfileSource() -> EvidenceSource {
        evidence("evidence.canonicalization")
    }

    static func verificationPolicy(
        algorithm: SignatureAlgorithm = .ed25519,
        trustedKeys: [TrustedSigningKey]? = nil,
        manifestByteCeiling: UInt64 = 262_144
    ) throws -> BundleVerificationPolicy {
        try BundleVerificationPolicy(
            id: artifact("policy.bundle-verification"),
            schemaVersion: .v1,
            algorithm: algorithm,
            canonicalizationProfile: canonicalizationProfileSource(),
            trustedKeys: trustedKeys ?? [
                TrustedSigningKey(
                    key: signingKey(),
                    algorithm: algorithm,
                    publicKeyDigest: StreamingSHA256.digest(of: releaseKeyMaterial),
                    status: .active,
                    governanceApproval: approval(identifier: "approval.key-governance")
                )
            ],
            rotationBehavior: .activeKeysOnly,
            revocationBehavior: .rejectBundle,
            maximumManifestByteCount: byteCount(manifestByteCeiling),
            reproducibilityEvidence: evidence("evidence.reproducibility")
        )
    }

    static func canonicalization(
        construction: BundleTreeDigestConstruction = .sortedKindTaggedRecords,
        decision: ApprovalDecision = .approved
    ) -> ApprovedCanonicalizationProfile {
        ApprovedCanonicalizationProfile(
            profile: canonicalizationProfileSource(),
            construction: construction,
            approval: approval(decision, identifier: "approval.canonicalization")
        )
    }

    static func releaseConfiguration(
        policy: BundleVerificationPolicy? = nil,
        bundleCatalog: [ModelBundleID]? = nil
    ) throws -> ReleaseConfiguration {
        try ReleaseConfiguration(
            capabilityManifest: try capabilityManifest(catalog: bundleCatalog),
            lifecyclePolicy: try lifecyclePolicy(),
            extensionExecutionPolicy: try extensionExecutionPolicy(),
            resourceBudgets: try budgetSet(),
            bundleVerificationPolicy: try policy ?? verificationPolicy(),
            preprocessingContract: try preprocessingContract(),
            calibrationPolicy: try calibrationPolicy(),
            verdictCopyCatalog: try copyCatalog(),
            provenancePolicy: nil,
            fusionRule: nil
        )
    }

    static func evidenceScope() -> EvidenceScope {
        EvidenceScope.version1(id: artifact("scope.evidence"))
    }

    static func compatibilityMatrix(
        appBuilds: Set<AppBuildID>? = nil,
        capabilities: Set<CapabilityID> = [.pixelAnalysis],
        minimumOS: PlatformVersion = .iOS17
    ) throws -> CompatibilityMatrix {
        try CompatibilityMatrix(
            compatibleAppBuilds: appBuilds ?? [appBuild()],
            requiredCapabilities: capabilities,
            minimumOS: minimumOS
        )
    }

    static func releaseContext(
        appBuild build: AppBuildID? = nil,
        osVersion: PlatformVersion = .iOS17
    ) -> ReleaseContext {
        ReleaseContext(
            device: DeviceContext(
                hardwareIdentifier: hardware(),
                osVersion: osVersion,
                appBuild: build ?? appBuild(),
                environment: .physicalIPhone
            ),
            approvedConfiguration: ApprovedConfigurationID("configuration.sample")!,
            capabilityManifestID: artifact("manifest.capability"),
            compiledCapabilities: [.pixelAnalysis]
        )!
    }
}

// MARK: - The synthetic staged release

/// Where the sample release stages each artifact, mirroring the bundle layout.
///
/// One place, so the layout a build is given and the content a build measures cannot drift
/// apart in the fixtures and hide a mismatch the tests should be catching.
enum StagedLayout {
    static let artifactsRoot = "artifacts"
    static let compiledModel = "artifacts/model.mlmodelc"
    static let weightBlob = "artifacts/model.mlmodelc/weights/weight.bin"
    static let selfTestSpecification = "artifacts/self-tests.canonical.json"
    static let fixtureCatalog = "artifacts/fixture-catalog.canonical.json"
    static let fixtureRoot = "artifacts/fixtures"
    static let noticeIndex = "artifacts/notices.canonical.json"
    static let noticeRoot = "artifacts/notices"

    static let checkpointNoticePath = "checkpoint-lowq.txt"
    static let dependencyNoticePath = "dependency-property-based.txt"
    static let fixtureAssetPath = "parity-000.png"

    static func layout(
        compiledModel model: String = compiledModel,
        weightBlob blob: String? = nil,
        selfTestSpecification specification: String = selfTestSpecification,
        fixtureCatalog catalog: String = fixtureCatalog,
        fixtureRoot fixtures: String = fixtureRoot,
        decision: ApprovalDecision = .approved
    ) -> ApprovedBundleLayout {
        ApprovedBundleLayout(
            source: Sample.evidence("evidence.bundle-layout"),
            compiledModel: Sample.path(model),
            modelWeightBlob: Sample.path(blob ?? "\(model)/weights/weight.bin"),
            selfTestSpecification: Sample.path(specification),
            fixtureCatalog: Sample.path(catalog),
            fixtureRoot: Sample.path(fixtures),
            approval: Sample.approval(decision, identifier: "approval.bundle-layout")
        )!
    }
}

/// Synthetic public key material. Not a release key and not a private key: the signature
/// stand-in below derives a detached signature from it and the message bytes.
let releaseKeyMaterial = Array("sample-release-public-key-material".utf8)

/// One staged artifact set: files by canonical path, plus the directories that hold them.
struct StagedContent {
    var files: [String: [UInt8]] = [:]
    var directories: Set<String> = []

    mutating func addFile(_ path: String, bytes: [UInt8]) {
        files[path] = bytes
        addAncestors(of: path)
    }

    mutating func addFile(_ path: String, text: String) {
        addFile(path, bytes: Array(text.utf8))
    }

    mutating func addDirectory(_ path: String) {
        directories.insert(path)
        addAncestors(of: path)
    }

    private mutating func addAncestors(of path: String) {
        var components = path.split(separator: "/").map(String.init)
        components.removeLast()
        while !components.isEmpty {
            directories.insert(components.joined(separator: "/"))
            components.removeLast()
        }
    }

    /// Every entry strictly inside `root`, as a relative path and its bytes when it is a file.
    func members(under root: String) -> [(relativePath: String, bytes: [UInt8]?)] {
        let prefix = root + "/"
        var found: [(String, [UInt8]?)] = []
        for (path, bytes) in files where path.hasPrefix(prefix) {
            found.append((String(path.dropFirst(prefix.count)), bytes))
        }
        for path in directories where path.hasPrefix(prefix) {
            found.append((String(path.dropFirst(prefix.count)), nil))
        }
        return found
    }

    /// The complete staged content of the sample release.
    ///
    /// The weight blob is synthetic, and deliberately so: Requirement 10.4 pins the approved
    /// blob's SHA-256, that blob is not in this repository, and no substitute can be
    /// manufactured. Every test that runs the runtime verifier over this content therefore
    /// stops at the weight measurement, which is the documented ceiling rather than a gap.
    static func sample(
        fixtureAssetBytes: [UInt8]? = nil,
        omitCheckpointNotice: Bool = false,
        omitWeightBlob: Bool = false
    ) -> StagedContent {
        var staged = StagedContent()
        staged.addDirectory(StagedLayout.compiledModel)
        staged.addFile("\(StagedLayout.compiledModel)/coremldata.bin", text: "core-ml-data")
        staged.addFile("\(StagedLayout.compiledModel)/model.mil", text: "mil-program")
        if !omitWeightBlob {
            staged.addDirectory("\(StagedLayout.compiledModel)/weights")
            staged.addFile(StagedLayout.weightBlob, text: "synthetic-weight-blob")
        }
        staged.addDirectory(StagedLayout.fixtureRoot)
        staged.addFile(
            "\(StagedLayout.fixtureRoot)/\(StagedLayout.fixtureAssetPath)",
            bytes: fixtureAssetBytes ?? sampleFixtureBytes
        )
        staged.addDirectory(StagedLayout.noticeRoot)
        if !omitCheckpointNotice {
            staged.addFile(
                "\(StagedLayout.noticeRoot)/\(StagedLayout.checkpointNoticePath)",
                text: "Approved checkpoint attribution notice text."
            )
        }
        staged.addFile(
            "\(StagedLayout.noticeRoot)/\(StagedLayout.dependencyNoticePath)",
            text: "Approved dependency license notice text."
        )
        return staged
    }

    /// Bytes of the one catalogued fixture asset.
    static let sampleFixtureBytes = Array("synthetic-parity-fixture-asset".utf8)
}

// MARK: - The measurement seam

/// Measures staged content using `DefAIkeModelBundle`'s own digest implementation.
///
/// This is the seam an approved release host would supply. Here it delegates to
/// ``StreamingSHA256`` and ``BundleTreeDigest``, so the values a build declares are produced
/// by exactly the code the verifier re-derives them with. Nothing in
/// `DefAIkeReleaseValidation` computes a digest, which is why this delegation is the whole
/// implementation rather than a shortcut.
struct StagedMeasuringSeam: BundleArtifactMeasuring {
    var staged: StagedContent
    var unsupportedConstructions: Set<BundleTreeDigestConstruction> = []
    var unreadablePaths: Set<String> = []
    var isUnavailable = false

    func measureStagedFile(
        at path: CanonicalRelativePath
    ) throws(BundleMeasurementFault) -> BundleArtifactMeasurement {
        if isUnavailable { throw BundleMeasurementFault.storeUnavailable }
        if unreadablePaths.contains(path.rawValue) {
            throw BundleMeasurementFault.artifactUnreadable
        }
        if staged.directories.contains(path.rawValue) {
            throw BundleMeasurementFault.notAFile
        }
        guard let bytes = staged.files[path.rawValue] else {
            throw BundleMeasurementFault.artifactMissing
        }
        return BundleArtifactMeasurement(
            byteCount: UInt64(bytes.count),
            digest: StreamingSHA256.digest(of: bytes)
        )
    }

    func measureStagedDirectoryTree(
        at path: CanonicalRelativePath,
        construction: BundleTreeDigestConstruction
    ) throws(BundleMeasurementFault) -> BundleArtifactMeasurement {
        if isUnavailable { throw BundleMeasurementFault.storeUnavailable }
        if unsupportedConstructions.contains(construction) {
            throw BundleMeasurementFault.constructionUnsupported
        }
        guard staged.directories.contains(path.rawValue) else {
            throw BundleMeasurementFault.notADirectoryTree
        }
        var members: [BundleTreeDigest.Member] = []
        var total: UInt64 = 0
        for member in staged.members(under: path.rawValue) {
            guard let bytes = member.bytes else {
                members.append(.directory(relativePath: member.relativePath))
                continue
            }
            total += UInt64(bytes.count)
            members.append(
                .file(
                    relativePath: member.relativePath,
                    byteCount: UInt64(bytes.count),
                    digest: StreamingSHA256.digest(of: bytes)
                )
            )
        }
        guard !members.isEmpty else { throw BundleMeasurementFault.artifactMissing }
        return BundleArtifactMeasurement(
            byteCount: total,
            digest: BundleTreeDigest.digest(of: members, construction: construction)
        )
    }

    func measureGeneratedFile(_ bytes: [UInt8]) -> BundleArtifactMeasurement {
        BundleArtifactMeasurement(
            byteCount: UInt64(bytes.count),
            digest: StreamingSHA256.digest(of: bytes)
        )
    }
}

// MARK: - The key-governance record

/// Reports one designated signing key, or refuses.
///
/// The seam offers nothing to choose among, and this double keeps it that way: it holds one
/// designation and either returns it or throws.
struct FakeKeyGovernance: ReleaseKeyGovernanceReading {
    var designation: DesignatedReleaseSigningKey?
    var fault: KeyGovernanceFault?

    static func approving(
        key: SigningKeyID = Sample.signingKey(),
        decision: ApprovalDecision = .approved
    ) -> FakeKeyGovernance {
        FakeKeyGovernance(
            designation: DesignatedReleaseSigningKey(
                key: key,
                governance: Sample.approval(decision, identifier: "approval.key-governance")
            )
        )
    }

    func designatedSigningKey(
        forBundle bundle: ModelBundleID
    ) throws(KeyGovernanceFault) -> DesignatedReleaseSigningKey {
        if let fault { throw fault }
        guard let designation else { throw KeyGovernanceFault.noDesignatedKey }
        return designation
    }
}

// MARK: - Approved notices

extension Sample {
    static func noticeSet(
        identifier: String = "notices.bundle",
        checkpoint: ModelCheckpointIdentifier? = nil,
        checkpointPath: String = StagedLayout.checkpointNoticePath,
        dependencies: [ApprovedDependencyNotice]? = nil,
        decision: ApprovalDecision = .approved
    ) throws -> ApprovedBundleNoticeSet {
        try ApprovedBundleNoticeSet(
            id: artifact(identifier),
            schemaVersion: .v1,
            checkpointNotice: try ApprovedCheckpointNotice(
                checkpoint: checkpoint ?? requiredCheckpoint,
                notice: BundleNoticeReference(
                    source: evidence("evidence.notice.checkpoint"),
                    rootRelativePath: path(checkpointPath)
                )
            ),
            dependencyNotices: dependencies ?? [
                ApprovedDependencyNotice(
                    subject: artifact("dependency.swift-property-based"),
                    notice: BundleNoticeReference(
                        source: evidence("evidence.notice.property-based"),
                        rootRelativePath: path(StagedLayout.dependencyNoticePath)
                    )
                )
            ],
            approval: approval(decision, identifier: "approval.notices")
        )
    }
}

// MARK: - Approved self-test artifacts

extension Sample {
    static func fixtureSuite(
        identifier: String = "suite.fixtures",
        assetPath: String = StagedLayout.fixtureAssetPath,
        assetBytes: [UInt8]? = nil
    ) throws -> ReleaseFixtureSuite {
        let bytes = assetBytes ?? StagedContent.sampleFixtureBytes
        return try ReleaseFixtureSuite(
            id: artifact(identifier),
            schemaVersion: .v1,
            provenanceApplicability: notApplicable(),
            fixtures: [
                try FixtureRecord(
                    id: fixture("fixture.parity.000"),
                    family: .modelParity,
                    assetPath: path(assetPath),
                    contentDigest: StreamingSHA256.digest(of: bytes),
                    byteCount: byteCount(UInt64(bytes.count)),
                    source: evidence("evidence.fixture"),
                    expectations: [
                        .rawLogit(value: 1.5, tolerance: nonNegativeDecimal()),
                        .pixelLabel(.noStrongSignalDetected),
                    ]
                )
            ]
        )
    }

    static func selfTestSpecification(
        identifier: String = "spec.self-tests",
        fixtureSuite suite: String = "suite.fixtures"
    ) throws -> ReleaseSelfTestSpecification {
        try ReleaseSelfTestSpecification(
            id: artifact(identifier),
            schemaVersion: .v1,
            fixtureSuite: artifact(suite),
            cases: [
                try SelfTestCase(
                    id: selfTestCaseID("self-test.parity.000"),
                    fixture: fixture("fixture.parity.000"),
                    expectations: [.pixelLabel(.noStrongSignalDetected)]
                )
            ]
        )
    }
}

// MARK: - The complete sample request

/// Builds sample build requests. Every parameter exists so exactly one approved input can be
/// changed at a time; the defaults describe the most complete bundle synthetic content can
/// produce.
enum SampleBuildRequest {
    static func standard(
        bundleID: ModelBundleID? = nil,
        policy: BundleVerificationPolicy? = nil,
        canonicalization: ApprovedCanonicalizationProfile? = nil,
        layout: ApprovedBundleLayout? = nil,
        notices: ApprovedBundleNoticeSet? = nil,
        noticeIndexPath: String = StagedLayout.noticeIndex,
        noticeRoot: String = StagedLayout.noticeRoot,
        fixtureCatalog: ReleaseFixtureSuite? = nil,
        selfTestSpecification: ReleaseSelfTestSpecification? = nil,
        compatibility: CompatibilityMatrix? = nil
    ) throws -> InitialModelBundleBuildRequest {
        InitialModelBundleBuildRequest(
            bundleID: bundleID ?? Sample.bundle(),
            manifestSchemaVersion: .v1,
            configuration: try Sample.releaseConfiguration(policy: policy),
            evidenceScope: Sample.evidenceScope(),
            layout: layout ?? StagedLayout.layout(),
            canonicalization: canonicalization ?? Sample.canonicalization(),
            compatibility: try compatibility ?? Sample.compatibilityMatrix(),
            outputContract: Sample.modelOutput(),
            coreMLModelVersion: Sample.artifact("component.core-ml-model"),
            selfTestSpecification: try selfTestSpecification ?? Sample.selfTestSpecification(),
            fixtureCatalog: try fixtureCatalog ?? Sample.fixtureSuite(),
            notices: try notices ?? Sample.noticeSet(),
            noticeIndexPath: Sample.path(noticeIndexPath),
            noticeRoot: Sample.path(noticeRoot)
        )
    }
}

// MARK: - The signature stand-in

/// A deterministic stand-in for one approved signature algorithm.
///
/// Not cryptography and not a release key: the "signature" is
/// `sha256(keyMaterial || message)`. That is enough to make a signature check byte-sensitive
/// — altering a signed manifest breaks it — without embedding a real signing key or asserting
/// anything about a real algorithm.
struct SampleSignatures: BundleSignatureVerifying {
    var material: [String: [UInt8]] = [Sample.signingKey().rawValue: releaseKeyMaterial]
    var supportedAlgorithms: Set<SignatureAlgorithm> = Set(SignatureAlgorithm.allCases)

    static func signature(over message: [UInt8], keyMaterial: [UInt8]) -> [UInt8] {
        StreamingSHA256.digest(of: keyMaterial + message).bytes
    }

    func publicKeyMaterial(for key: SigningKeyID) -> [UInt8]? {
        material[key.rawValue]
    }

    func verify(
        signature: [UInt8],
        over message: [UInt8],
        using algorithm: SignatureAlgorithm,
        publicKeyMaterial: [UInt8]
    ) -> SignatureCheckOutcome {
        guard supportedAlgorithms.contains(algorithm) else { return .algorithmUnsupported }
        return signature == Self.signature(over: message, keyMaterial: publicKeyMaterial)
            ? .verified
            : .notVerified
    }
}

// MARK: - Materializing a produced bundle

/// The produced bundle as a readable tree, plus the approved inputs verification needs.
///
/// `MaterializedBundle` copies the plan's bytes to the plan's paths and adds the detached
/// signature. It computes no digest and imposes no ordering: everything the verifier checks
/// came from the builder, so a passing verification is evidence about the builder.
struct MaterializedBundle: ModelBundleContentReading {
    var files: [String: [UInt8]] = [:]
    var directories: Set<String> = []
    var reportedByteCounts: [String: UInt64] = [:]
    var unreadablePaths: Set<String> = []
    var extraEntries: [BundleTreeEntry] = []
    var enumerationFault: BundleContentFault?

    func entries(in bundle: ModelBundleID) throws(BundleContentFault) -> [BundleTreeEntry] {
        if let enumerationFault { throw enumerationFault }
        var found = directories.map { BundleTreeEntry(rawPath: $0, kind: .directory) }
        for (path, bytes) in files {
            found.append(
                BundleTreeEntry(
                    rawPath: path,
                    kind: .file(byteCount: reportedByteCounts[path] ?? UInt64(bytes.count))
                )
            )
        }
        return found + extraEntries
    }

    func readFile(
        at path: CanonicalRelativePath,
        in bundle: ModelBundleID,
        chunkByteCount: Int,
        into sink: (ArraySlice<UInt8>) -> BundleReadDisposition
    ) throws(BundleContentFault) {
        guard !unreadablePaths.contains(path.rawValue) else {
            throw BundleContentFault.entryUnreadable
        }
        guard let bytes = files[path.rawValue] else { throw BundleContentFault.entryMissing }
        guard chunkByteCount > 0 else { return }
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkByteCount, bytes.count)
            if sink(bytes[offset..<end]) == .stop { return }
            offset = end
        }
    }

    // MARK: Mutation, for tests that perturb exactly one artifact

    /// Replaces one file's bytes and the size the enumeration reports, as an edit would.
    mutating func replaceBytes(at path: String, with bytes: [UInt8]) {
        files[path] = bytes
        reportedByteCounts[path] = nil
    }

    mutating func removeFile(at path: String) {
        files[path] = nil
        reportedByteCounts[path] = nil
    }

    mutating func addUndeclaredFile(at path: String, text: String) {
        files[path] = Array(text.utf8)
    }
}

/// One produced bundle, signed, together with everything the runtime verifiers need.
struct ProducedBundle {
    var built: UnsignedInitialModelBundle
    var request: InitialModelBundleBuildRequest
    var tree: MaterializedBundle
    var signatures: SampleSignatures
    var context: ReleaseContext

    /// The runtime integrity verifier over this bundle.
    var integrityVerifier: ModelBundleIntegrityVerifier {
        ModelBundleIntegrityVerifier(
            content: tree,
            signatures: signatures,
            policy: request.configuration.bundleVerificationPolicy,
            canonicalization: request.canonicalization
        )
    }

    /// The runtime compatibility verifier over this bundle.
    var compatibilityVerifier: ModelBundleCompatibilityVerifier {
        ModelBundleCompatibilityVerifier(
            content: tree,
            configuration: request.configuration,
            evidenceScope: request.evidenceScope,
            layout: request.layout
        )
    }

    func recorder(bundles: any ModelBundleManaging = FakeBundleManager()) -> BundleReleaseEvidenceRecorder {
        BundleReleaseEvidenceRecorder(
            integrity: integrityVerifier,
            compatibility: compatibilityVerifier,
            bundles: bundles
        )
    }

    /// What the runtime verifiers say about this bundle, recorded.
    func verification() -> ProducedBundleVerification {
        recorder().verify(built.bundleID, for: context)
    }

    /// The finding the runtime produced, or `nil` when every check passed.
    func finding() -> ModelBundleVerificationError? {
        verification().finding
    }

    /// The finding a bundle built from synthetic staged content is expected to stop at.
    var approvedWeightBlobCeiling: ModelBundleVerificationError {
        .modelWeightDigestMismatch(request.layout.modelWeightBlob)
    }
}

/// Builds and materializes the sample release end to end.
enum SampleRelease {
    /// Builds one bundle from approved records without materializing it.
    static func build(
        request: InitialModelBundleBuildRequest? = nil,
        staged: StagedContent? = nil,
        measurements: StagedMeasuringSeam? = nil,
        keyGovernance: FakeKeyGovernance = .approving()
    ) throws -> UnsignedInitialModelBundle {
        let resolved = try request ?? SampleBuildRequest.standard()
        let seam = measurements ?? StagedMeasuringSeam(staged: staged ?? .sample())
        return try InitialModelBundleBuilder(
            measurements: seam,
            keyGovernance: keyGovernance
        ).build(resolved)
    }

    /// Builds one bundle, writes its planned tree, and signs its manifest.
    ///
    /// Signing happens here rather than in the module under test, which is the division the
    /// module is built around: it emits a signing request, and an approved step outside it
    /// produces the signature.
    static func produce(
        request: InitialModelBundleBuildRequest? = nil,
        staged: StagedContent? = nil,
        keyMaterial: [UInt8] = releaseKeyMaterial,
        signatures: SampleSignatures = SampleSignatures(),
        context: ReleaseContext? = nil
    ) throws -> ProducedBundle {
        let resolved = try request ?? SampleBuildRequest.standard()
        let content = staged ?? .sample()
        let built = try build(request: resolved, staged: content)
        return ProducedBundle(
            built: built,
            request: resolved,
            tree: materialized(built, staged: content, keyMaterial: keyMaterial),
            signatures: signatures,
            context: context ?? Sample.releaseContext()
        )
    }

    /// Writes one planned tree into a readable bundle and places the detached signature.
    static func materialized(
        _ built: UnsignedInitialModelBundle,
        staged: StagedContent,
        keyMaterial: [UInt8] = releaseKeyMaterial
    ) -> MaterializedBundle {
        var tree = MaterializedBundle()
        for entry in built.tree.entries {
            switch entry.content {
            case .directory:
                tree.directories.insert(entry.path.rawValue)
            case let .generatedFile(bytes):
                tree.files[entry.path.rawValue] = bytes
            case .stagedDirectoryTree:
                tree.directories.insert(entry.path.rawValue)
                let prefix = entry.path.rawValue + "/"
                for (path, bytes) in staged.files where path.hasPrefix(prefix) {
                    tree.files[path] = bytes
                }
                for path in staged.directories where path.hasPrefix(prefix) {
                    tree.directories.insert(path)
                }
            }
        }
        tree.files[built.signingRequest.signaturePath.rawValue] = SampleSignatures.signature(
            over: built.signingRequest.message,
            keyMaterial: keyMaterial
        )
        return tree
    }
}

// MARK: - The bundle-manager double

/// Records which ``ModelBundleManaging`` members a recorder called, in order.
final class PortCallLog: @unchecked Sendable {
    private(set) var calls: [String] = []

    func record(_ call: String) {
        calls.append(call)
    }
}

/// A bounded ``ModelBundleManaging`` double.
///
/// The port, not the activator: the recorder depends on the port, so a test can exercise a
/// completed activation and a completed rollback even though no synthetic bundle can reach
/// step 7 through the real verification path.
struct FakeBundleManager: ModelBundleManaging {
    var activated: BoundModelBundle?
    var rolledBack: BoundModelBundle?
    var activationFault: AnalysisFault = .analysis(.modelLoadError, stage: .modelLoad)
    var rollbackFault: AnalysisFault = .analysis(.modelLoadError, stage: .modelLoad)
    let log = PortCallLog()

    func verifiedActiveBundle(
        for context: ReleaseContext
    ) throws(AnalysisFault) -> BoundModelBundle {
        log.record("verifiedActiveBundle")
        guard let activated else { throw activationFault }
        return activated
    }

    func activateLocalCandidate(
        _ id: ModelBundleID,
        context: ReleaseContext
    ) async throws(AnalysisFault) -> BoundModelBundle {
        log.record("activate(\(id.rawValue))")
        guard let activated else { throw activationFault }
        return activated
    }

    func rollback(
        to id: ModelBundleID,
        context: ReleaseContext
    ) async throws(AnalysisFault) -> BoundModelBundle {
        log.record("rollback(\(id.rawValue))")
        guard let rolledBack else { throw rollbackFault }
        return rolledBack
    }
}

extension Sample {
    /// A bindable receipt for one bundle, and the bound bundle it authorizes.
    ///
    /// Built through the domain's public initializers: a ``BoundModelBundle`` exists only for
    /// a receipt whose signature and self-test both passed, which is exactly the property the
    /// evidence recorder reads off it.
    static func boundBundle(
        manifest: ModelBundleManifest,
        receiptIdentifier: String = "receipt.sample",
        generation: Int = 1
    ) throws -> BoundModelBundle {
        let receipt = try ActivationReceipt(
            id: artifact(receiptIdentifier),
            schemaVersion: .v1,
            bundleID: manifest.bundleID,
            verificationPolicy: artifact("policy.bundle-verification"),
            verifiedManifestDigest: digest(0xD1),
            verifiedArtifactDigests: manifest.artifacts,
            signatureOutcome: .passed,
            selfTestOutcome: .passed,
            deviceContext: DeviceContext(
                hardwareIdentifier: hardware(),
                osVersion: .iOS17,
                appBuild: appBuild(),
                environment: .physicalIPhone
            ),
            activationGeneration: try PositiveCount(validating: generation),
            activatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        guard let bound = BoundModelBundle(manifest: manifest, receipt: receipt) else {
            throw BoundBundleUnavailable()
        }
        return bound
    }

    struct BoundBundleUnavailable: Error {}
}
