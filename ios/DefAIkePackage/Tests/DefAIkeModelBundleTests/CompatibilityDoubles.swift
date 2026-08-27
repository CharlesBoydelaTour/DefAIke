import Foundation

@testable import DefAIkeDomain
@testable import DefAIkeModelBundle

// Doubles and synthetic candidates for model identity, compatibility, and release
// self-test verification.
//
// Nothing here is an approved release input. The policies, identifiers, fixtures, and
// expectations are synthetic: each test assembles one structurally valid candidate plus one
// coherent approved configuration, changes exactly one thing, and asserts which finding
// verification produces.
//
// One synthetic candidate can never pass every check, and that is deliberate rather than a
// gap. Requirement 10.4 pins the weight-blob digest to a specific SHA-256 value, so passing
// the weight measurement requires the actual approved 43 MB weight blob; no assembled
// fixture can fake it. Steps 4 and 5 are therefore exercised by asserting the exact finding
// each mutation produces, the weight check by asserting that an otherwise perfect candidate
// is still refused, and execution by constructing the post-compatibility value directly —
// which is possible here only because these tests are inside the module.

// MARK: - Approved configuration

extension Sample {
    static func fixtureID(_ value: String = "fixture.sample") -> FixtureID {
        FixtureID(value)!
    }

    static func selfTestCaseID(_ value: String = "self-test.sample") -> SelfTestCaseID {
        SelfTestCaseID(value)!
    }

    static func hardware(_ value: String = "iPhone17.1") -> DeviceHardwareID {
        DeviceHardwareID(value)!
    }

    static func copyKey(_ value: String) -> ApprovedCopyKey {
        ApprovedCopyKey(value)!
    }

    static func qualityFeature(_ value: String = "quality.short-edge") -> QualityFeatureID {
        QualityFeatureID(value)!
    }

    static func duration(milliseconds: UInt64 = 30_000) -> ValidatedDuration {
        try! ValidatedDuration(validating: milliseconds)
    }

    static func count(_ value: Int = 5) -> PositiveCount {
        try! PositiveCount(validating: value)
    }

    static func positiveDecimal(_ value: Decimal = 1_000_000_000) -> PositiveDecimal {
        try! PositiveDecimal(validating: value)
    }

    static func nonNegativeDecimal(_ value: Decimal = 0) -> NonNegativeDecimal {
        try! NonNegativeDecimal(validating: value)
    }

    static func ratio(_ value: Decimal) -> UnitInterval {
        try! UnitInterval(validating: value)
    }

    // MARK: Preprocessing and calibration

    /// A fixed-shape model input whose feature name a test can change.
    ///
    /// Named apart from ``Sample/modelInput()`` because the shape fields are fixed by the
    /// contract schema; the feature name is the only part a manifest and a bound
    /// Preprocessing Contract can legitimately disagree about.
    static func namedModelInput(featureName: String = "image") throws -> ModelInputContract {
        try ModelInputContract(
            featureName: text(featureName),
            width: CenterCropContract.requiredEdge,
            height: CenterCropContract.requiredEdge,
            channelOrder: .rgb,
            elementType: .uint8,
            appliesAppSideNormalization: false
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
                profileDigest: digest("b")
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
            modelInput: try namedModelInput(featureName: modelInputFeatureName)
        )
    }

    static func calibrationPolicy(
        identifier: String = "policy.calibration",
        compatiblePreprocessing: String = "contract.preprocessing",
        compatibleVerdictCopy: String = "copy.compatibility"
    ) throws -> CalibrationPolicy {
        try CalibrationPolicy(
            id: artifact(identifier),
            schemaVersion: .v1,
            compatibleModel: RequiredPixelModel.identity,
            compatiblePreprocessing: artifact(compatiblePreprocessing),
            compatibleVerdictCopy: artifact(compatibleVerdictCopy),
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

    // MARK: Lifecycle, resources, copy, capabilities

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

    static func limitUnit(for metric: ResourceMetric) -> ResourceLimitUnit {
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
        identifier: String? = nil
    ) throws -> ResourceBudget {
        try ResourceBudget(
            id: artifact(identifier ?? "budget.\(target.rawValue)"),
            schemaVersion: .v1,
            target: target,
            hardLimits: try ResourceMetric.requiredMetrics(for: target)
                .sorted { $0.rawValue < $1.rawValue }
                .map { metric in
                    try ResourceLimitEntry(
                        metric: metric,
                        limit: metric.isCategorical
                            ? .thermal(maximumState: .fair)
                            : .numeric(value: positiveDecimal(), unit: limitUnit(for: metric)),
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

    static func copyCatalog(compatibilityID: String = "copy.compatibility") throws
        -> ApprovedVerdictCopyCatalog
    {
        try ApprovedVerdictCopyCatalog(
            id: artifact("catalog.verdict-copy"),
            schemaVersion: .v1,
            compatibilityID: artifact(compatibilityID),
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
        identifier: String = "manifest.capability",
        catalog: [ModelBundleID]? = nil
    ) throws -> ReleaseCapabilityManifest {
        try ReleaseCapabilityManifest(
            id: artifact(identifier),
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
            approvedBundleCatalog: catalog ?? [bundle()],
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

    /// The validated policy join a build binds.
    ///
    /// Every reference resolves, so this is a configuration the domain itself accepts
    /// rather than a bag of identifiers a test asserted about.
    static func releaseConfiguration(
        verificationPolicy: BundleVerificationPolicy,
        capabilityManifestIdentifier: String = "manifest.capability",
        bundleCatalog: [ModelBundleID]? = nil,
        modelInputFeatureName: String = "image"
    ) throws -> ReleaseConfiguration {
        try ReleaseConfiguration(
            capabilityManifest: try capabilityManifest(
                identifier: capabilityManifestIdentifier,
                catalog: bundleCatalog
            ),
            lifecyclePolicy: try lifecyclePolicy(),
            extensionExecutionPolicy: try extensionExecutionPolicy(),
            resourceBudgets: try budgetSet(),
            bundleVerificationPolicy: verificationPolicy,
            preprocessingContract: try preprocessingContract(
                modelInputFeatureName: modelInputFeatureName
            ),
            calibrationPolicy: try calibrationPolicy(),
            verdictCopyCatalog: try copyCatalog(),
            provenancePolicy: nil,
            fusionRule: nil
        )
    }

    static func evidenceScope(_ identifier: String = "scope.evidence") -> EvidenceScope {
        EvidenceScope.version1(id: artifact(identifier))
    }

    static func releaseContext(
        appBuild build: AppBuildID = Sample.appBuild(),
        osVersion: PlatformVersion = .iOS17,
        capabilityManifestIdentifier: String = "manifest.capability",
        compiledCapabilities: Set<CapabilityID> = [.pixelAnalysis]
    ) -> ReleaseContext {
        ReleaseContext(
            device: DeviceContext(
                hardwareIdentifier: hardware(),
                osVersion: osVersion,
                appBuild: build,
                environment: .physicalIPhone
            ),
            approvedConfiguration: ApprovedConfigurationID("configuration.sample")!,
            capabilityManifestID: artifact(capabilityManifestIdentifier),
            compiledCapabilities: compiledCapabilities
        )!
    }

    // MARK: Bundle components matched to the configuration above

    /// Component versions that agree with ``releaseConfiguration(verificationPolicy:)``.
    static func compatibleComponentVersions(
        preprocessing: String = "contract.preprocessing",
        calibration: String = "policy.calibration",
        scope: String = "scope.evidence",
        copy: String = "copy.compatibility",
        selfTests: String = "spec.self-tests"
    ) -> BundleComponentVersions {
        BundleComponentVersions(
            coreMLModel: artifact("component.core-ml-model"),
            preprocessingContract: artifact(preprocessing),
            calibrationPolicy: artifact(calibration),
            evidenceScope: artifact(scope),
            verdictCopyCompatibility: artifact(copy),
            selfTestSpecification: artifact(selfTests)
        )
    }

    /// An approved layout for the standard candidate.
    ///
    /// The weight blob follows the compiled model unless a test names it, because a layout
    /// whose weight blob sits outside its compiled model is not constructible at all — that
    /// refusal is asserted directly rather than tripped over here.
    static func bundleLayout(
        compiledModel: String = CompatibleBundleAssembler.modelTreePath,
        weightBlob: String? = nil,
        selfTestSpecification: String = CompatibleBundleAssembler.selfTestsPath,
        fixtureCatalog: String = CompatibleBundleAssembler.fixtureCatalogPath,
        fixtureRoot: String = CompatibleBundleAssembler.fixtureRootPath,
        decision: ApprovalDecision = .approved
    ) -> ApprovedBundleLayout {
        ApprovedBundleLayout(
            source: evidence("evidence.bundle-layout"),
            compiledModel: path(compiledModel),
            modelWeightBlob: path(weightBlob ?? "\(compiledModel)/weights/weight.bin"),
            selfTestSpecification: path(selfTestSpecification),
            fixtureCatalog: path(fixtureCatalog),
            fixtureRoot: path(fixtureRoot),
            approval: approval(decision, identifier: "approval.bundle-layout")
        )!
    }
}

// MARK: - Self-test specification and fixture catalogue

/// One synthetic self-test case: a fixture, its bytes, and what it must produce.
struct SampleSelfTest {
    var caseID: SelfTestCaseID
    var fixtureID: FixtureID
    /// Path relative to the fixture root, as a catalogue entry declares it.
    var suiteRelativePath: String
    var bytes: [UInt8]
    var expectations: [SelfTestExpectation]
    /// What the catalogue claims, when a test wants it to disagree with the bytes.
    var declaredByteCount: UInt64?
    var declaredDigest: DefAIkeDomain.SHA256Digest?

    init(
        caseID: String = "self-test.sample",
        fixtureID: String = "fixture.sample",
        suiteRelativePath: String = "sample.jpg",
        bytes: [UInt8] = Array("fixture-bytes".utf8),
        expectations: [SelfTestExpectation] = [.pixelLabel(.noStrongSignalDetected)],
        declaredByteCount: UInt64? = nil,
        declaredDigest: DefAIkeDomain.SHA256Digest? = nil
    ) {
        self.caseID = Sample.selfTestCaseID(caseID)
        self.fixtureID = Sample.fixtureID(fixtureID)
        self.suiteRelativePath = suiteRelativePath
        self.bytes = bytes
        self.expectations = expectations
        self.declaredByteCount = declaredByteCount
        self.declaredDigest = declaredDigest
    }

    var effectiveByteCount: UInt64 { declaredByteCount ?? UInt64(bytes.count) }

    var effectiveDigest: DefAIkeDomain.SHA256Digest {
        declaredDigest ?? StreamingSHA256.digest(of: bytes)
    }

    func catalogueEntry() throws -> FixtureRecord {
        try FixtureRecord(
            id: fixtureID,
            family: .modelParity,
            assetPath: Sample.path(suiteRelativePath),
            contentDigest: effectiveDigest,
            byteCount: try PositiveByteCount(validating: effectiveByteCount),
            source: Sample.evidence("evidence.fixture"),
            expectations: [.pixelLabel(.noStrongSignalDetected)]
        )
    }

    func specificationCase() throws -> SelfTestCase {
        try SelfTestCase(id: caseID, fixture: fixtureID, expectations: expectations)
    }
}

// MARK: - Assembled compatible candidate

/// One candidate bundle carrying everything steps 4 through 6 need.
///
/// Layout mirrors the design's Model Bundle tree: a manifest and detached signature at the
/// root, a compiled model directory with a weight blob, the self-test specification, the
/// fixture catalogue, and a fixture directory holding the catalogued assets.
struct CompatibleCandidate {
    var integrity: AssembledBundle
    var configuration: ReleaseConfiguration
    var evidenceScope: EvidenceScope
    var layout: ApprovedBundleLayout
    var context: ReleaseContext
    var specification: ReleaseSelfTestSpecification
    var catalog: ReleaseFixtureSuite
    var selfTests: [SampleSelfTest]

    /// A reader that records every path the verifier streams, so a test can assert which
    /// fixture assets step 5 resolved rather than trusting that it resolved them.
    let reads = ReadRecorder()

    var verifier: ModelBundleCompatibilityVerifier {
        ModelBundleCompatibilityVerifier(
            content: RecordingBundleTree(tree: integrity.tree, recorder: reads),
            configuration: configuration,
            evidenceScope: evidenceScope,
            layout: layout
        )
    }

    /// Runs steps 1 through 3, then steps 4 and 5.
    func resolve() throws(ModelBundleVerificationError) -> CompatibleBundleCandidate {
        let tree = try integrity.verify()
        return try verifier.resolve(tree, for: context)
    }

    /// The finding steps 4 and 5 produced, or `nil` when they succeeded.
    ///
    /// A correct synthetic candidate reaches the weight measurement and stops there, so the
    /// signal that every other check passed is
    /// ``ModelBundleVerificationError/modelWeightDigestMismatch(_:)`` rather than `nil`.
    func compatibilityFinding() -> ModelBundleVerificationError? {
        do {
            _ = try resolve()
            return nil
        } catch {
            return error
        }
    }

    /// The finding a correct synthetic candidate is expected to stop at.
    var weightMeasurementFinding: ModelBundleVerificationError {
        .modelWeightDigestMismatch(layout.modelWeightBlob)
    }

    /// The plan a resolved candidate carries, assembled from the same inputs the bundle was
    /// built from.
    ///
    /// Used to drive the runner. It is not evidence that step 5 produces this value — the
    /// ``weightMeasurementFinding`` assertion and the recorded reads cover that — it is a
    /// starting point for testing what the runner does with a resolved plan.
    func plan() -> VerifiedSelfTestPlan {
        VerifiedSelfTestPlan(
            specification: specification,
            fixtureCatalog: catalog,
            cases: selfTests.map { test in
                VerifiedSelfTestCase(
                    id: test.caseID,
                    fixture: test.fixtureID,
                    assetPath: Sample.path(
                        "\(CompatibleBundleAssembler.fixtureRootPath)/\(test.suiteRelativePath)"
                    ),
                    byteCount: test.effectiveByteCount,
                    contentDigest: test.effectiveDigest,
                    expectations: test.expectations
                )
            }
        )
    }

    /// A candidate ready for the runner.
    func bindable() throws -> CompatibleBundleCandidate {
        CompatibleBundleCandidate(
            tree: try integrity.verify(),
            layout: layout,
            capabilityManifestID: configuration.capabilityManifest.id,
            appBuild: context.device.appBuild,
            measuredWeightDigest: RequiredPixelModel.identity.requiredWeightDigest,
            selfTests: plan()
        )
    }
}

/// Records the paths a verifier streamed, in order.
final class ReadRecorder: @unchecked Sendable {
    private(set) var paths: [String] = []

    func record(_ path: String) {
        paths.append(path)
    }

    /// Recorded paths under one directory, in read order.
    func paths(under root: String) -> [String] {
        paths.filter { $0.hasPrefix(root + "/") }
    }
}

/// Passes every call through to a tree while recording which paths were read.
struct RecordingBundleTree: ModelBundleContentReading {
    let tree: FakeBundleTree
    let recorder: ReadRecorder

    func entries(in bundle: ModelBundleID) throws(BundleContentFault) -> [BundleTreeEntry] {
        try tree.entries(in: bundle)
    }

    func readFile(
        at path: CanonicalRelativePath,
        in bundle: ModelBundleID,
        chunkByteCount: Int,
        into sink: (ArraySlice<UInt8>) -> BundleReadDisposition
    ) throws(BundleContentFault) {
        recorder.record(path.rawValue)
        try tree.readFile(
            at: path,
            in: bundle,
            chunkByteCount: chunkByteCount,
            into: sink
        )
    }
}

/// Assembles candidates whose declared artifacts cover every release role.
enum CompatibleBundleAssembler {
    static let artifactsRoot = "artifacts"
    static let modelTreePath = "artifacts/model.mlmodelc"
    static let weightBlobPath = "artifacts/model.mlmodelc/weights/weight.bin"
    static let selfTestsPath = "artifacts/self-tests.canonical.json"
    static let fixtureCatalogPath = "artifacts/fixture-catalog.canonical.json"
    static let fixtureRootPath = "artifacts/fixtures"

    /// Assembles one candidate plus a coherent approved configuration for it.
    ///
    /// Every parameter exists so exactly one thing can be changed at a time; the defaults
    /// describe a candidate that is compatible in every respect a synthetic fixture can be.
    static func standard(
        bundleID: ModelBundleID = Sample.bundle(),
        selfTests: [SampleSelfTest] = [SampleSelfTest()],
        specificationIdentifier: String = "spec.self-tests",
        catalogIdentifier: String = "suite.fixtures",
        specificationFixtureSuite: String? = nil,
        componentVersions: BundleComponentVersions? = nil,
        compatibleAppBuilds: Set<AppBuildID>? = nil,
        requiredCapabilities: Set<CapabilityID> = [.pixelAnalysis],
        bundleMinimumOS: PlatformVersion = .iOS17,
        manifestInputFeatureName: String = "image",
        configurationInputFeatureName: String = "image",
        bundleCatalog: [ModelBundleID]? = nil,
        capabilityManifestIdentifier: String = "manifest.capability",
        contextCapabilityManifestIdentifier: String? = nil,
        contextAppBuild: AppBuildID = Sample.appBuild(),
        contextOSVersion: PlatformVersion = .iOS17,
        contextCapabilities: Set<CapabilityID> = [.pixelAnalysis],
        evidenceScopeIdentifier: String = "scope.evidence",
        layout: ApprovedBundleLayout? = nil,
        manifestByteCeiling: UInt64 = 262_144,
        omitWeightBlob: Bool = false,
        selfTestsOverride: [UInt8]? = nil,
        catalogOverride: [UInt8]? = nil,
        treeOverrides: (inout FakeBundleTree) -> Void = { _ in }
    ) throws -> CompatibleCandidate {
        let specification = try ReleaseSelfTestSpecification(
            id: Sample.artifact(specificationIdentifier),
            schemaVersion: .v1,
            fixtureSuite: Sample.artifact(specificationFixtureSuite ?? catalogIdentifier),
            cases: try selfTests.map { try $0.specificationCase() }
        )
        let catalog = try ReleaseFixtureSuite(
            id: Sample.artifact(catalogIdentifier),
            schemaVersion: .v1,
            provenanceApplicability: .notApplicable(decision: Sample.approval()),
            fixtures: try selfTests.map { try $0.catalogueEntry() }
        )

        var tree = FakeBundleTree()
        tree.addDirectory(artifactsRoot)
        tree.addDirectory(modelTreePath)
        tree.addFile("\(modelTreePath)/coremldata.bin", text: "core-ml-data")
        if !omitWeightBlob {
            tree.addDirectory("\(modelTreePath)/weights")
            tree.addFile(weightBlobPath, text: "weight-blob")
        }
        tree.addFile(selfTestsPath, bytes: try selfTestsOverride ?? encode(specification))
        tree.addFile(fixtureCatalogPath, bytes: try catalogOverride ?? encode(catalog))
        tree.addDirectory(fixtureRootPath)
        for test in selfTests {
            tree.addFile("\(fixtureRootPath)/\(test.suiteRelativePath)", bytes: test.bytes)
        }
        treeOverrides(&tree)

        let declared = [
            BundleAssembler.treeRecord(modelTreePath, in: tree),
            BundleAssembler.fileRecord(selfTestsPath, in: tree),
            BundleAssembler.fileRecord(fixtureCatalogPath, in: tree),
            BundleAssembler.treeRecord(fixtureRootPath, in: tree),
        ]

        let manifest = try Sample.manifest(
            bundleID: bundleID,
            artifacts: declared,
            componentVersions: componentVersions
                ?? Sample.compatibleComponentVersions(
                    scope: evidenceScopeIdentifier,
                    selfTests: specificationIdentifier
                ),
            compatibility: try CompatibilityMatrix(
                compatibleAppBuilds: compatibleAppBuilds ?? [Sample.appBuild()],
                requiredCapabilities: requiredCapabilities,
                minimumOS: bundleMinimumOS
            ),
            inputContract: try Sample.namedModelInput(featureName: manifestInputFeatureName)
        )
        let manifestBytes = try BundleAssembler.encode(manifest)
        tree.addFile(ModelBundleManifest.manifestFileName, bytes: manifestBytes)

        let keyMaterial = Array("public-key-material".utf8)
        let signature = FakeSignatureVerifier.signature(
            over: manifestBytes,
            keyMaterial: keyMaterial
        )
        tree.addFile(ModelBundleManifest.signatureFileName, bytes: signature)

        let profile = Sample.evidence("evidence.canonicalization")
        let policy = try BundleVerificationPolicy(
            id: Sample.artifact("policy.bundle-verification"),
            schemaVersion: .v1,
            algorithm: .ed25519,
            canonicalizationProfile: profile,
            trustedKeys: [
                TrustedSigningKey(
                    key: Sample.signingKey(),
                    algorithm: .ed25519,
                    publicKeyDigest: StreamingSHA256.digest(of: keyMaterial),
                    status: .active,
                    governanceApproval: Sample.approval()
                )
            ],
            rotationBehavior: .activeKeysOnly,
            revocationBehavior: .rejectBundle,
            maximumManifestByteCount: Sample.byteCount(manifestByteCeiling),
            reproducibilityEvidence: Sample.evidence("evidence.reproducibility")
        )

        return CompatibleCandidate(
            integrity: AssembledBundle(
                tree: tree,
                manifest: manifest,
                manifestBytes: manifestBytes,
                policy: policy,
                canonicalization: ApprovedCanonicalizationProfile(
                    profile: profile,
                    construction: .sortedKindTaggedRecords,
                    approval: Sample.approval()
                ),
                signatures: FakeSignatureVerifier(
                    material: [Sample.signingKey().rawValue: keyMaterial]
                ),
                bundleID: bundleID
            ),
            configuration: try Sample.releaseConfiguration(
                verificationPolicy: policy,
                capabilityManifestIdentifier: capabilityManifestIdentifier,
                bundleCatalog: bundleCatalog ?? [bundleID],
                modelInputFeatureName: configurationInputFeatureName
            ),
            evidenceScope: Sample.evidenceScope(evidenceScopeIdentifier),
            layout: layout ?? Sample.bundleLayout(),
            context: Sample.releaseContext(
                appBuild: contextAppBuild,
                osVersion: contextOSVersion,
                capabilityManifestIdentifier: contextCapabilityManifestIdentifier
                    ?? capabilityManifestIdentifier,
                compiledCapabilities: contextCapabilities
            ),
            specification: specification,
            catalog: catalog,
            selfTests: selfTests
        )
    }

    /// Encodes one artifact to the canonical-JSON bytes a release would sign.
    static func encode<Value: Encodable>(_ value: Value) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Array(try encoder.encode(value))
    }
}

// MARK: - Execution doubles

/// A deterministic stand-in for the Core ML adapter task 6.5 builds.
///
/// Not Core ML and not a model: it returns whatever observation a test seeds for a fixture.
/// That is exactly what a self-test runner should be checkable against, because the runner's
/// job is comparing observations to declared expectations, not producing them.
final class FakeSelfTestExecutor: ReleaseSelfTestExecuting, @unchecked Sendable {
    /// Observation to report per fixture identifier. A fixture with no entry reports an
    /// empty observation, which is what "the run produced nothing" looks like.
    var observations: [String: SelfTestObservation] = [:]
    var loadFault: SelfTestExecutionFault?
    var runFaults: [String: SelfTestExecutionFault] = [:]

    private(set) var loadedContexts: [SelfTestExecutionContext] = []
    private(set) var runFixtures: [FixtureID] = []
    private(set) var suppliedDigests: [DefAIkeDomain.SHA256Digest] = []
    private(set) var unloadCount = 0
    private(set) var outstandingLoads = 0

    init(observations: [String: SelfTestObservation] = [:]) {
        self.observations = observations
    }

    func loadCandidate(
        _ context: SelfTestExecutionContext
    ) async throws(SelfTestExecutionFault) -> LoadedModelToken {
        if let loadFault { throw loadFault }
        loadedContexts.append(context)
        outstandingLoads += 1
        return LoadedModelToken(rawValue: UInt64(loadedContexts.count))
    }

    func run(
        _ payload: SelfTestFixturePayload,
        on model: LoadedModelToken,
        context: SelfTestExecutionContext
    ) async throws(SelfTestExecutionFault) -> SelfTestObservation {
        runFixtures.append(payload.fixture)
        suppliedDigests.append(payload.contentDigest)
        if let fault = runFaults[payload.fixture.rawValue] { throw fault }
        return observations[payload.fixture.rawValue] ?? SelfTestObservation()
    }

    func unload(_ model: LoadedModelToken) async {
        unloadCount += 1
        outstandingLoads -= 1
    }
}

/// Records what a runner asked of the resource port, in order.
final class ResourceCallLog: @unchecked Sendable {
    private(set) var reserved: [ResourceMetric] = []
    private(set) var released: [ResourceMetric] = []
    private(set) var observed: [ResourceMetric] = []

    func recordReserve(_ metric: ResourceMetric) { reserved.append(metric) }
    func recordRelease(_ metric: ResourceMetric) { released.append(metric) }
    func recordObserve(_ metric: ResourceMetric) { observed.append(metric) }
}

/// A resource controller whose answers a test dictates.
///
/// Deliberately has no way to relax a limit: like the port it conforms to, it can only
/// grant, refuse, or report. `refusedMetrics` makes a reservation fail; `breaching` and
/// `unmeasurable` shape what sampling reports.
struct StubResourceGovernor: ResourceGoverning {
    var target: ExecutionTarget = .mainApplication
    var refusedMetrics: Set<ResourceMetric> = []
    var breaching: Set<ResourceMetric> = []
    var unmeasurable: Set<ResourceMetric> = []
    /// Metrics whose reservation reports cancellation rather than a hard-limit breach.
    var cancelledMetrics: Set<ResourceMetric> = []
    var log = ResourceCallLog()

    func reserve(
        _ request: ResourceReservationRequest,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ResourceReservation {
        guard !cancelledMetrics.contains(request.metric) else { throw .cancelled }
        guard !refusedMetrics.contains(request.metric) else {
            throw .analysis(.resourceLimit, stage: request.stage)
        }
        log.recordReserve(request.metric)
        return ResourceReservation(
            token: ResourceReservationToken(rawValue: 1),
            request: request,
            budgetID: budget.id,
            target: target
        )
    }

    func release(_ reservation: ResourceReservation) async {
        log.recordRelease(reservation.request.metric)
    }

    func observe(
        _ metric: ResourceMetric,
        budget: ResourceBudget
    ) async -> ResourceObservation {
        log.recordObserve(metric)
        if breaching.contains(metric) { return .wouldBreachHardLimit(metric) }
        if unmeasurable.contains(metric) { return .notMeasurable(metric) }
        return .withinHardLimit(metric)
    }
}
