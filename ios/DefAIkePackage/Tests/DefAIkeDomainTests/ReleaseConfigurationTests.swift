import DefAIkeTestSupport
import Foundation
import Testing

@testable import DefAIkeDomain

// Tests for the validated join of a build's policy artifacts.
//
// Every artifact here is individually valid — that is the point. A set of valid
// artifacts can still describe two different releases: a manifest that names
// `policy.calibration` while the calibration policy it is handed identifies itself as
// something else, a calibration policy declaring compatibility with a preprocessing
// contract that is not the bound one, or a provenance policy approved against a
// validator version the build does not compile. Per-artifact validation cannot see any
// of those, so the shape of each test is: build a coherent set, break exactly one
// reference, and require the join to refuse it.
//
// Nothing here approves a device, a bundle, or a distribution. Those are separate
// gates with their own tasks.

@Suite("Release configuration consistency")
struct ReleaseConfigurationTests {
    // MARK: Coherent sets

    private func compatibility(
        preprocessing: String = "contract.preprocessing",
        calibration: String = "policy.calibration",
        lifecycle: String = "policy.lifecycle",
        extensionExecution: String = "policy.extension-execution",
        mainBudget: String = "budget.main-application",
        shareBudget: String = "budget.share-extension",
        verification: String = "policy.bundle-verification",
        verdictCopy: String = "copy.compatibility",
        provenance: ConditionalArtifactBinding<ArtifactID> = .notApplicable(
            decision: Sample.approval()
        ),
        fusion: ConditionalArtifactBinding<ArtifactID> = .notApplicable(
            decision: Sample.approval()
        )
    ) throws -> PolicyCompatibilitySet {
        try PolicyCompatibilitySet(
            preprocessingContract: Sample.artifact(preprocessing),
            calibrationPolicy: Sample.artifact(calibration),
            lifecyclePolicy: Sample.artifact(lifecycle),
            extensionExecutionPolicy: Sample.artifact(extensionExecution),
            mainApplicationResourceBudget: Sample.artifact(mainBudget),
            shareExtensionResourceBudget: Sample.artifact(shareBudget),
            bundleVerificationPolicy: Sample.artifact(verification),
            verdictCopyCompatibility: Sample.artifact(verdictCopy),
            provenancePolicy: provenance,
            fusionRule: fusion
        )
    }

    /// Builds a configuration, defaulting every artifact to its coherent sample.
    private func configuration(
        capabilities: Set<CapabilityID> = [.pixelAnalysis],
        compatibility overrides: PolicyCompatibilitySet? = nil,
        implementationVersions: [CapabilityImplementationEntry]? = nil,
        lifecyclePolicy: DataLifecyclePolicy? = nil,
        extensionExecutionPolicy: ExtensionExecutionPolicy? = nil,
        resourceBudgets: ResourceBudgetSet? = nil,
        bundleVerificationPolicy: BundleVerificationPolicy? = nil,
        preprocessingContract: PreprocessingContract? = nil,
        calibrationPolicy: CalibrationPolicy? = nil,
        verdictCopyCatalog: ApprovedVerdictCopyCatalog? = nil,
        provenancePolicy: ProvenancePolicy? = nil,
        fusionRule: EvidenceFusionRule? = nil
    ) throws -> ReleaseConfiguration {
        try ReleaseConfiguration(
            capabilityManifest: Sample.capabilityManifest(
                capabilities: capabilities,
                policyCompatibility: overrides ?? compatibility(),
                implementationVersions: implementationVersions
            ),
            lifecyclePolicy: lifecyclePolicy ?? Sample.lifecyclePolicy(),
            extensionExecutionPolicy: extensionExecutionPolicy
                ?? Sample.extensionExecutionPolicy(),
            resourceBudgets: resourceBudgets ?? Sample.budgetSet(),
            bundleVerificationPolicy: bundleVerificationPolicy ?? Sample.verificationPolicy(),
            preprocessingContract: preprocessingContract ?? Sample.preprocessingContract(),
            calibrationPolicy: calibrationPolicy ?? Sample.calibrationPolicy(),
            verdictCopyCatalog: verdictCopyCatalog ?? Sample.copyCatalog(),
            provenancePolicy: provenancePolicy,
            fusionRule: fusionRule
        )
    }

    /// The provenance-and-fusion composition, with every reference coherent.
    private func provenanceConfiguration(
        includeFusion: Bool = true,
        provenancePolicy: ProvenancePolicy? = nil,
        fusionRule: EvidenceFusionRule? = nil,
        verdictCopyCatalog: ApprovedVerdictCopyCatalog? = nil
    ) throws -> ReleaseConfiguration {
        var capabilities: Set<CapabilityID> = [.pixelAnalysis, .contentCredentialValidation]
        if includeFusion { capabilities.insert(.evidenceFusion) }
        return try configuration(
            capabilities: capabilities,
            compatibility: compatibility(
                provenance: .bound(Sample.artifact("policy.provenance")),
                fusion: includeFusion
                    ? .bound(Sample.artifact("rule.fusion"))
                    : .notApplicable(decision: Sample.approval())
            ),
            implementationVersions: capabilities.sorted { $0.rawValue < $1.rawValue }.map {
                CapabilityImplementationEntry(
                    capability: $0,
                    version: $0 == .contentCredentialValidation
                        ? Sample.version(Sample.sampleValidatorVersion)
                        : Sample.version()
                )
            },
            verdictCopyCatalog: verdictCopyCatalog,
            provenancePolicy: provenancePolicy ?? Sample.provenancePolicy(),
            fusionRule: includeFusion ? (fusionRule ?? Sample.fusionRule()) : nil
        )
    }

    @Test("A coherent pixel-only configuration is accepted and enables no provenance")
    func coherentPixelOnly() throws {
        let configuration = try configuration()
        #expect(!configuration.enablesProvenance)
        #expect(!configuration.enablesFusion)
        #expect(configuration.provenancePolicy == nil)
        #expect(configuration.fusionRule == nil)
    }

    @Test("A coherent provenance and fusion configuration is accepted")
    func coherentProvenanceAndFusion() throws {
        let configuration = try provenanceConfiguration()
        #expect(configuration.enablesProvenance)
        #expect(configuration.enablesFusion)
    }

    // MARK: One broken reference at a time

    private func mismatch(
        _ field: String,
        _ build: () throws -> ReleaseConfiguration,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            _ = try build()
            Issue.record(
                "expected \(field) to be refused as inconsistent",
                sourceLocation: sourceLocation
            )
        } catch let error as ArtifactSchemaError {
            guard case let .inconsistentReference(reported, _, _) = error else {
                Issue.record(
                    "expected an inconsistent reference for \(field), got \(error)",
                    sourceLocation: sourceLocation
                )
                return
            }
            #expect(reported == field, sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error for \(field): \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test("Every artifact must be the one the manifest names")
    func artifactIdentifiersMustResolve() throws {
        mismatch("configuration.lifecyclePolicy.id") {
            try configuration(compatibility: compatibility(lifecycle: "policy.other"))
        }
        mismatch("configuration.extensionExecutionPolicy.id") {
            try configuration(compatibility: compatibility(extensionExecution: "policy.other"))
        }
        mismatch("configuration.resourceBudgets.mainApplication.id") {
            try configuration(compatibility: compatibility(mainBudget: "budget.other"))
        }
        mismatch("configuration.resourceBudgets.shareExtension.id") {
            try configuration(compatibility: compatibility(shareBudget: "budget.other"))
        }
        mismatch("configuration.bundleVerificationPolicy.id") {
            try configuration(compatibility: compatibility(verification: "policy.other"))
        }
        mismatch("configuration.preprocessingContract.id") {
            try configuration(compatibility: compatibility(preprocessing: "contract.other"))
        }
        mismatch("configuration.calibrationPolicy.id") {
            try configuration(compatibility: compatibility(calibration: "policy.other"))
        }
    }

    @Test("The copy catalog must declare the compatibility identifier the manifest names")
    func copyCompatibilityMustResolve() {
        mismatch("configuration.verdictCopyCatalog.compatibilityID") {
            try configuration(
                verdictCopyCatalog: Sample.copyCatalog(compatibilityID: "copy.other")
            )
        }
    }

    @Test("Both target budgets must come from one Device Validation Plan")
    func budgetsShareOnePlan() {
        mismatch("configuration.resourceBudgets.shareExtension.validationPlan") {
            try configuration(
                resourceBudgets: Sample.budgetSet(shareExtensionPlan: "plan.other")
            )
        }
    }

    @Test("The calibration policy's compatibility claims must resolve to the bound artifacts")
    func calibrationCompatibilityMustResolve() {
        mismatch("configuration.calibrationPolicy.compatiblePreprocessing") {
            try configuration(
                calibrationPolicy: Sample.calibrationPolicy(
                    compatiblePreprocessing: "contract.other"
                )
            )
        }
        mismatch("configuration.calibrationPolicy.compatibleVerdictCopy") {
            try configuration(
                calibrationPolicy: Sample.calibrationPolicy(compatibleVerdictCopy: "copy.other")
            )
        }
    }

    @Test("A calibration policy for a different model cannot be bound")
    func calibrationModelMustMatch() throws {
        let otherModel = ModelIdentity(
            checkpointIdentifier: try #require(ModelCheckpointIdentifier("Other/model-2026-01")),
            requiredWeightDigest: Sample.digest("f")
        )
        mismatch("configuration.calibrationPolicy.compatibleModel") {
            try configuration(
                calibrationPolicy: Sample.calibrationPolicy(compatibleModel: otherModel)
            )
        }
    }

    // MARK: Conditional artifacts

    @Test("A pixel-only manifest cannot carry a live Provenance Policy")
    func pixelOnlyRejectsProvenancePolicy() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try configuration(provenancePolicy: Sample.provenancePolicy())
        }
        #expect(throws: ArtifactSchemaError.self) {
            try configuration(fusionRule: Sample.fusionRule())
        }
    }

    @Test("A provenance-enabled manifest cannot omit its Provenance Policy")
    func provenanceManifestRequiresPolicy() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try configuration(
                capabilities: [.pixelAnalysis, .contentCredentialValidation],
                compatibility: compatibility(
                    provenance: .bound(Sample.artifact("policy.provenance"))
                ),
                implementationVersions: [
                    CapabilityImplementationEntry(
                        capability: .pixelAnalysis,
                        version: Sample.version()
                    ),
                    CapabilityImplementationEntry(
                        capability: .contentCredentialValidation,
                        version: Sample.version(Sample.sampleValidatorVersion)
                    ),
                ],
                provenancePolicy: nil
            )
        }
    }

    @Test("The bound Provenance Policy must be the one the manifest names")
    func provenanceIdentifierMustResolve() {
        mismatch("configuration.provenancePolicy.id") {
            try configuration(
                capabilities: [.pixelAnalysis, .contentCredentialValidation],
                compatibility: compatibility(provenance: .bound(Sample.artifact("policy.other"))),
                implementationVersions: [
                    CapabilityImplementationEntry(
                        capability: .pixelAnalysis,
                        version: Sample.version()
                    ),
                    CapabilityImplementationEntry(
                        capability: .contentCredentialValidation,
                        version: Sample.version(Sample.sampleValidatorVersion)
                    ),
                ],
                provenancePolicy: Sample.provenancePolicy()
            )
        }
    }

    @Test("The approved validator version must be the compiled one")
    func validatorVersionMustMatch() {
        mismatch("configuration.provenancePolicy.validatorImplementationVersion") {
            try provenanceConfiguration(
                includeFusion: false,
                provenancePolicy: Sample.provenancePolicy(
                    validatorImplementationVersion: "0.0.13"
                )
            )
        }
    }

    @Test("Provenance validation is governed by the main-application budget")
    func provenanceBudgetMustBeMainApplication() {
        mismatch("configuration.provenancePolicy.resourceBudget") {
            try provenanceConfiguration(
                includeFusion: false,
                provenancePolicy: Sample.provenancePolicy(
                    resourceBudget: "budget.share-extension"
                )
            )
        }
    }

    @Test("The bound fusion rule must resolve and share the approved copy compatibility")
    func fusionMustResolve() {
        mismatch("configuration.fusionRule.compatibleVerdictCopy") {
            try provenanceConfiguration(
                fusionRule: Sample.fusionRule(compatibleVerdictCopy: "copy.other")
            )
        }
        // A manifest that binds a fusion rule cannot be handed none.
        #expect(throws: ArtifactSchemaError.self) {
            try configuration(
                capabilities: [.pixelAnalysis, .contentCredentialValidation, .evidenceFusion],
                compatibility: compatibility(
                    provenance: .bound(Sample.artifact("policy.provenance")),
                    fusion: .bound(Sample.artifact("rule.fusion"))
                ),
                implementationVersions: [
                    CapabilityImplementationEntry(
                        capability: .pixelAnalysis,
                        version: Sample.version()
                    ),
                    CapabilityImplementationEntry(
                        capability: .contentCredentialValidation,
                        version: Sample.version(Sample.sampleValidatorVersion)
                    ),
                    CapabilityImplementationEntry(
                        capability: .evidenceFusion,
                        version: Sample.version()
                    ),
                ],
                provenancePolicy: Sample.provenancePolicy(),
                fusionRule: nil
            )
        }
    }

    // MARK: Artifact-supplied values

    @Test("Every governed value is read from an artifact, never from a constant")
    func valuesComeFromArtifacts() throws {
        let configuration = try configuration()
        let verification = try Sample.verificationPolicy()
        let lifecycle = try Sample.lifecyclePolicy()
        let budgets = try Sample.budgetSet()

        #expect(configuration.signatureAlgorithm == verification.algorithm)
        #expect(configuration.trustedKey(Sample.signingKey()) == Sample.trustedKey())
        #expect(configuration.trustedKey(Sample.signingKey("key.unknown")) == nil)
        for reason in SessionCleanupReason.allCases {
            #expect(configuration.cleanupDeadline(for: reason) == lifecycle.deadline(for: reason))
        }
        for target in ExecutionTarget.allCases {
            for metric in ResourceMetric.requiredMetrics(for: target) {
                #expect(
                    configuration.hardLimit(metric, for: target)
                        == budgets.budget(for: target).limit(for: metric)
                )
            }
        }
        #expect(
            configuration.manifestDecodingLimits.maximumByteCount
                == verification.maximumManifestByteCount
        )
        #expect(
            configuration.manifestDecoder.limits.maximumByteCount
                == verification.maximumManifestByteCount
        )
    }
}

@Suite("Release configuration loading")
struct ReleaseConfigurationLoadingTests {
    private func store(
        recorder: PortCallRecorder? = nil,
        provenance: Bool = false
    ) async throws -> (InMemoryArtifactStore, ArtifactID) {
        let store = InMemoryArtifactStore(recorder: recorder)
        let capabilities: Set<CapabilityID> = provenance
            ? [.pixelAnalysis, .contentCredentialValidation]
            : [.pixelAnalysis]
        let manifest = try Sample.capabilityManifest(
            capabilities: capabilities,
            policyCompatibility: PolicyCompatibilitySet(
                preprocessingContract: Sample.artifact("contract.preprocessing"),
                calibrationPolicy: Sample.artifact("policy.calibration"),
                lifecyclePolicy: Sample.artifact("policy.lifecycle"),
                extensionExecutionPolicy: Sample.artifact("policy.extension-execution"),
                mainApplicationResourceBudget: Sample.artifact("budget.main-application"),
                shareExtensionResourceBudget: Sample.artifact("budget.share-extension"),
                bundleVerificationPolicy: Sample.artifact("policy.bundle-verification"),
                verdictCopyCompatibility: Sample.artifact("copy.compatibility"),
                provenancePolicy: provenance
                    ? .bound(Sample.artifact("policy.provenance"))
                    : .notApplicable(decision: Sample.approval()),
                fusionRule: .notApplicable(decision: Sample.approval())
            ),
            implementationVersions: capabilities.sorted { $0.rawValue < $1.rawValue }.map {
                CapabilityImplementationEntry(
                    capability: $0,
                    version: $0 == .contentCredentialValidation
                        ? Sample.version(Sample.sampleValidatorVersion)
                        : Sample.version()
                )
            }
        )
        await store.register(manifest)
        await store.register(try Sample.lifecyclePolicy())
        await store.register(try Sample.extensionExecutionPolicy())
        await store.register(try Sample.budgetSet())
        await store.register(try Sample.verificationPolicy())
        await store.register(try Sample.preprocessingContract())
        await store.register(try Sample.calibrationPolicy())
        await store.register(try Sample.copyCatalog())
        if provenance {
            await store.register(try Sample.provenancePolicy())
        }
        return (store, manifest.id)
    }

    @Test("A coherent store loads every bound policy from the manifest's references")
    func loadsCoherentSet() async throws {
        let (store, manifestID) = try await store()
        let configuration = try await ReleaseConfiguration.load(
            capabilityManifest: manifestID,
            verdictCopyCatalog: Sample.artifact("catalog.verdict-copy"),
            from: store
        )
        #expect(configuration.capabilityManifest.id == manifestID)
        #expect(configuration.lifecyclePolicy.id == Sample.artifact("policy.lifecycle"))
        #expect(!configuration.enablesProvenance)
    }

    @Test("A pixel-only build never reads a Provenance Policy")
    func pixelOnlyNeverReadsProvenance() async throws {
        let recorder = PortCallRecorder()
        let (store, manifestID) = try await store(recorder: recorder)
        _ = try await ReleaseConfiguration.load(
            capabilityManifest: manifestID,
            verdictCopyCatalog: Sample.artifact("catalog.verdict-copy"),
            from: store
        )
        #expect(!recorder.didCall(.readPolicyArtifact(Sample.artifact("policy.provenance"))))
        #expect(!recorder.didCall(.readPolicyArtifact(Sample.artifact("rule.fusion"))))
        #expect(recorder.didCall(.readPolicyArtifact(Sample.artifact("policy.lifecycle"))))
    }

    @Test("A provenance-enabled build reads the policy its manifest binds")
    func provenanceBuildReadsPolicy() async throws {
        let recorder = PortCallRecorder()
        let (store, manifestID) = try await store(recorder: recorder, provenance: true)
        let configuration = try await ReleaseConfiguration.load(
            capabilityManifest: manifestID,
            verdictCopyCatalog: Sample.artifact("catalog.verdict-copy"),
            from: store
        )
        #expect(configuration.enablesProvenance)
        #expect(recorder.didCall(.readPolicyArtifact(Sample.artifact("policy.provenance"))))
    }

    @Test("An absent policy blocks the load instead of being defaulted")
    func absentPolicyBlocksTheLoad() async throws {
        for absent in [
            "policy.lifecycle",
            "policy.extension-execution",
            "budget.main-application",
            "budget.share-extension",
            "policy.bundle-verification",
            "contract.preprocessing",
            "policy.calibration",
            "catalog.verdict-copy",
        ] {
            let (store, manifestID) = try await store()
            let identifier = Sample.artifact(absent)
            await store.forgetPolicyArtifact(identifier)
            await #expect(throws: ReleaseArtifactError.notFound(identifier)) {
                try await ReleaseConfiguration.load(
                    capabilityManifest: manifestID,
                    verdictCopyCatalog: Sample.artifact("catalog.verdict-copy"),
                    from: store
                )
            }
        }
    }

    @Test("An absent capability manifest blocks the load")
    func absentManifestBlocksTheLoad() async throws {
        let (store, manifestID) = try await store()
        await store.forgetPolicyArtifact(manifestID)
        await #expect(throws: ReleaseArtifactError.notFound(manifestID)) {
            try await ReleaseConfiguration.load(
                capabilityManifest: manifestID,
                verdictCopyCatalog: Sample.artifact("catalog.verdict-copy"),
                from: store
            )
        }
    }

    @Test("An incoherent store is reported as an invalid configuration")
    func incoherentStoreIsInvalid() async throws {
        let (store, manifestID) = try await store()
        await store.register(try Sample.copyCatalog(compatibilityID: "copy.other"))
        await #expect(
            throws: ReleaseArtifactError.invalid(
                .inconsistentReference(
                    field: "configuration.verdictCopyCatalog.compatibilityID",
                    expected: "copy.compatibility",
                    found: "copy.other"
                )
            )
        ) {
            try await ReleaseConfiguration.load(
                capabilityManifest: manifestID,
                verdictCopyCatalog: Sample.artifact("catalog.verdict-copy"),
                from: store
            )
        }
    }

    @Test("A copy catalog found under another identifier is a mismatch, not a substitute")
    func catalogIdentifierMismatch() async throws {
        let (store, manifestID) = try await store()
        let requested = Sample.artifact("catalog.other")
        await #expect(throws: ReleaseArtifactError.notFound(requested)) {
            try await ReleaseConfiguration.load(
                capabilityManifest: manifestID,
                verdictCopyCatalog: requested,
                from: store
            )
        }
    }
}
