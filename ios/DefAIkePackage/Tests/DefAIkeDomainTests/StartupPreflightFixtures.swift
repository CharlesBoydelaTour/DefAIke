import DefAIkeTestSupport
import Foundation
import Testing

@testable import DefAIkeDomain

// A coherent synthetic release, and one knob per thing that can go wrong.
//
// The shape every preflight test takes is: build a release whose artifacts, allowlist,
// bundle, and module graph all agree, change exactly one of them, and require the gate to
// refuse. That only works if the coherent baseline is genuinely coherent, so the builder
// derives as much as it can — the capability set follows from the provenance and fusion
// flags, the compiled composition follows from the manifest, and the allowlist entry
// follows from both — and exposes overrides for the single field a test means to break.
//
// None of these values is an approved device, budget, deadline, key, or decision. The
// hardware identifiers are synthetic, the deadlines are the sample duration, and every
// approval is a synthetic record whose decision the test sets explicitly.

/// A built scenario: the ports, the gate, and the pieces a test asserts against.
struct PreflightScenario {
    let preflight: StartupPreflight
    let policies: InMemoryArtifactStore
    let bundles: StubModelBundleManager
    let cleanup: FakeSessionDataDeleter
    let ephemeral: InMemoryEphemeralStore
    let recorder: PortCallRecorder
    let manifest: ReleaseCapabilityManifest
    let allowlist: ReleaseApprovedDeviceAllowlist
    let bundle: BoundModelBundle

    /// Runs the gate with this scenario's ports.
    func run() async throws(PreflightFailure) -> ReleaseAdmission {
        try await preflight.run(policies: policies, bundles: bundles, cleanup: cleanup)
    }
}

enum PreflightSample {
    /// The synthetic hardware identifier the baseline device and entry share.
    static let hardware = "iPhone17.1"

    /// A second synthetic identifier that is never listed, for exact-match tests.
    static let unlistedHardware = "iPhone17.2"

    // MARK: - Capability sets

    static func capabilities(
        provenance: Bool,
        fusion: Bool
    ) -> Set<CapabilityID> {
        var set: Set<CapabilityID> = [.pixelAnalysis]
        if provenance { set.insert(.contentCredentialValidation) }
        if fusion { set.insert(.evidenceFusion) }
        return set
    }

    /// One implementation version per capability, pinning the validator to the reviewed
    /// version the sample Provenance Policy declares.
    static func implementationVersions(
        for capabilities: Set<CapabilityID>
    ) -> [CapabilityImplementationEntry] {
        capabilities.sorted { $0.rawValue < $1.rawValue }.map {
            CapabilityImplementationEntry(
                capability: $0,
                version: $0 == .contentCredentialValidation
                    ? Sample.version(Sample.sampleValidatorVersion)
                    : Sample.version()
            )
        }
    }

    // MARK: - Values

    static func device(
        hardware hardwareIdentifier: String = PreflightSample.hardware,
        osVersion: PlatformVersion = .iOS17,
        appBuild: String = "build.sample",
        environment: ExecutionEnvironment = .physicalIPhone
    ) -> DeviceContext {
        DeviceContext(
            hardwareIdentifier: Sample.hardware(hardwareIdentifier),
            osVersion: osVersion,
            appBuild: Sample.appBuild(appBuild),
            environment: environment
        )
    }

    static func composition(
        identifier: String = "pixel-only",
        capabilities: Set<CapabilityID> = [.pixelAnalysis],
        implementationVersions: [CapabilityImplementationEntry]? = nil,
        linksValidator: Bool = false
    ) -> CompiledCapabilityComposition? {
        CompiledCapabilityComposition(
            compositionIdentifier: Sample.text(identifier),
            capabilities: capabilities,
            implementationVersions: implementationVersions
                ?? PreflightSample.implementationVersions(for: capabilities),
            linksContentCredentialValidator: linksValidator
        )
    }

    static func capabilityManifest(
        capabilities: Set<CapabilityID>,
        implementationVersions: [CapabilityImplementationEntry]? = nil,
        compositionIdentifier: String = "pixel-only",
        appBuild: String = "build.sample",
        approvedBundleCatalog: [String] = ["bundle.sample"],
        approval: ApprovalDecision = .approved
    ) throws -> ReleaseCapabilityManifest {
        try ReleaseCapabilityManifest(
            id: Sample.artifact("manifest.capability"),
            schemaVersion: .v1,
            appBuild: Sample.appBuild(appBuild),
            compositionIdentifier: Sample.text(compositionIdentifier),
            compiledCapabilities: capabilities,
            implementationVersions: implementationVersions
                ?? PreflightSample.implementationVersions(for: capabilities),
            approvedConfigurationAllowlist: Sample.artifact("allowlist.devices"),
            approvedBundleCatalog: approvedBundleCatalog.map { Sample.bundle($0) },
            policyCompatibility: Sample.policyCompatibility(
                provenance: capabilities.contains(.contentCredentialValidation)
                    ? .bound(Sample.artifact("policy.provenance"))
                    : .notApplicable(decision: Sample.approval()),
                fusion: capabilities.contains(.evidenceFusion)
                    ? .bound(Sample.artifact("rule.fusion"))
                    : .notApplicable(decision: Sample.approval())
            ),
            approval: Sample.approval(approval)
        )
    }

    static func candidate(
        hardware hardwareIdentifier: String = PreflightSample.hardware,
        osVersion: PlatformVersion = .iOS17,
        appBuild: String = "build.sample"
    ) throws -> CandidateDeviceConfiguration {
        try CandidateDeviceConfiguration(
            deviceModel: Sample.text("Synthetic iPhone"),
            hardwareIdentifier: Sample.hardware(hardwareIdentifier),
            osVersion: osVersion,
            appBuild: Sample.appBuild(appBuild),
            isAppleNeuralEngineCapable: true
        )
    }

    static func versionTuple(
        capabilities: Set<CapabilityID>,
        implementationVersions: [CapabilityImplementationEntry]? = nil,
        appBuild: String = "build.sample",
        modelBundle: String = "bundle.sample",
        fixtureSuite: String = "suite.fixtures",
        validationPlan: String = "plan.device-validation",
        capabilityManifest: String = "manifest.capability"
    ) throws -> ValidationVersionTuple {
        try ValidationVersionTuple(
            appBuild: Sample.appBuild(appBuild),
            modelBundle: Sample.bundle(modelBundle),
            fixtureSuite: Sample.artifact(fixtureSuite),
            validationPlan: Sample.artifact(validationPlan),
            capabilityManifest: Sample.artifact(capabilityManifest),
            capabilities: capabilities,
            capabilityImplementationVersions: implementationVersions
                ?? PreflightSample.implementationVersions(for: capabilities)
        )
    }

    /// One coherent allowlist entry for a capability set.
    static func entry(
        identifier: String = "configuration.sample",
        capabilities: Set<CapabilityID>,
        hardware hardwareIdentifier: String = PreflightSample.hardware,
        osVersion: PlatformVersion = .iOS17,
        appBuild: String = "build.sample",
        implementationVersions: [CapabilityImplementationEntry]? = nil,
        modelBundle: String = "bundle.sample",
        fixtureSuite: String = "suite.fixtures",
        validationPlan: String = "plan.device-validation",
        capabilityManifest: String = "manifest.capability",
        failing: Set<DeviceGate> = []
    ) throws -> ApprovedDeviceConfiguration {
        let provenanceEnabled = capabilities.contains(.contentCredentialValidation)
        return try ApprovedDeviceConfiguration(
            id: Sample.configuration(identifier),
            configuration: candidate(
                hardware: hardwareIdentifier,
                osVersion: osVersion,
                appBuild: appBuild
            ),
            versionTuple: versionTuple(
                capabilities: capabilities,
                implementationVersions: implementationVersions,
                appBuild: appBuild,
                modelBundle: modelBundle,
                fixtureSuite: fixtureSuite,
                validationPlan: validationPlan,
                capabilityManifest: capabilityManifest
            ),
            gateEvidence: Sample.gateReferences(
                provenanceEnabled: provenanceEnabled,
                failing: failing
            )
        )
    }

    static func allowlist(
        entries: [ApprovedDeviceConfiguration],
        approval: ApprovalDecision = .approved
    ) throws -> ReleaseApprovedDeviceAllowlist {
        try ReleaseApprovedDeviceAllowlist(
            id: Sample.artifact("allowlist.devices"),
            schemaVersion: .v1,
            entries: entries,
            approval: Sample.approval(approval)
        )
    }

    static func lifecyclePolicy(
        approval: ApprovalDecision = .approved
    ) throws -> DataLifecyclePolicy {
        try DataLifecyclePolicy(
            id: Sample.artifact("policy.lifecycle"),
            schemaVersion: .v1,
            deadlines: SessionCleanupReason.allCases.map {
                DataLifecyclePolicy.Deadline(reason: $0, deadline: Sample.duration())
            },
            approval: Sample.approval(approval)
        )
    }

    // MARK: - Bundle

    static func bundleManifest(
        bundleID: String = "bundle.sample",
        componentVersions: BundleComponentVersions? = nil,
        requiredCapabilities: Set<CapabilityID> = [.pixelAnalysis],
        compatibleAppBuilds: Set<String> = ["build.sample"]
    ) throws -> ModelBundleManifest {
        try ModelBundleManifest(
            schemaVersion: .v1,
            bundleID: Sample.bundle(bundleID),
            modelIdentity: RequiredPixelModel.identity,
            modelFormat: Sample.modelFormat(),
            inputContract: Sample.modelInput(),
            outputContract: Sample.modelOutput(),
            componentVersions: componentVersions ?? Sample.componentVersions(),
            artifacts: [Sample.digestRecord()],
            compatibility: CompatibilityMatrix(
                compatibleAppBuilds: Set(compatibleAppBuilds.map { Sample.appBuild($0) }),
                requiredCapabilities: requiredCapabilities,
                minimumOS: .iOS17
            ),
            upstreamBoundaryMetadata: Sample.upstreamMetadata(),
            signingKey: Sample.signingKey()
        )
    }

    static func receipt(
        bundleID: String = "bundle.sample",
        signature: GateOutcome = .passed,
        selfTest: GateOutcome = .passed
    ) throws -> ActivationReceipt {
        try ActivationReceipt(
            id: Sample.artifact("receipt.activation"),
            schemaVersion: .v1,
            bundleID: Sample.bundle(bundleID),
            verificationPolicy: Sample.artifact("policy.bundle-verification"),
            verifiedManifestDigest: Sample.digest("f"),
            verifiedArtifactDigests: [Sample.digestRecord()],
            signatureOutcome: signature,
            selfTestOutcome: selfTest,
            deviceContext: device(),
            activationGeneration: Sample.count(1),
            activatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    /// Raised when a fixture is asked for a bundle its receipt cannot bind.
    ///
    /// Every receipt these fixtures build passes both outcomes, so this is unreachable in
    /// practice. It exists so the fixture can throw rather than return an optional the
    /// caller has to unwrap at every use.
    struct UnbindableBundle: Error {}

    /// A verified, bindable bundle.
    static func boundBundle(
        bundleID: String = "bundle.sample",
        componentVersions: BundleComponentVersions? = nil,
        requiredCapabilities: Set<CapabilityID> = [.pixelAnalysis],
        compatibleAppBuilds: Set<String> = ["build.sample"]
    ) throws -> BoundModelBundle {
        guard let bundle = BoundModelBundle(
            manifest: try bundleManifest(
                bundleID: bundleID,
                componentVersions: componentVersions,
                requiredCapabilities: requiredCapabilities,
                compatibleAppBuilds: compatibleAppBuilds
            ),
            receipt: try receipt(bundleID: bundleID)
        ) else {
            throw UnbindableBundle()
        }
        return bundle
    }

    /// Component versions with exactly one reference pointed somewhere else.
    static func componentVersions(
        preprocessingContract: String = "contract.preprocessing",
        calibrationPolicy: String = "policy.calibration",
        verdictCopyCompatibility: String = "copy.compatibility"
    ) -> BundleComponentVersions {
        BundleComponentVersions(
            coreMLModel: Sample.artifact("component.coreml"),
            preprocessingContract: Sample.artifact(preprocessingContract),
            calibrationPolicy: Sample.artifact(calibrationPolicy),
            evidenceScope: Sample.artifact("component.scope"),
            verdictCopyCompatibility: Sample.artifact(verdictCopyCompatibility),
            selfTestSpecification: Sample.artifact("component.self-tests")
        )
    }

    // MARK: - Scenario assembly

    /// Builds a coherent release, applying only the overrides a test supplies.
    ///
    /// Whatever is not overridden is derived, so a test that changes one field cannot
    /// accidentally leave a second disagreement behind and pass for the wrong reason.
    static func scenario(
        provenance: Bool = false,
        fusion: Bool = false,
        device deviceContext: DeviceContext? = nil,
        composition compiledComposition: CompiledCapabilityComposition? = nil,
        manifest manifestOverride: ReleaseCapabilityManifest? = nil,
        allowlist allowlistOverride: ReleaseApprovedDeviceAllowlist? = nil,
        lifecyclePolicy lifecycleOverride: DataLifecyclePolicy? = nil,
        provenanceFeasibility: ApprovalDecision = .approved,
        bundle bundleOverride: BoundModelBundle? = nil,
        activateBundle: Bool = true,
        embeddedBundle: String = "bundle.sample",
        target: ExecutionTarget = .mainApplication,
        abandonedSessions: [AnalysisSessionID] = []
    ) async throws -> PreflightScenario {
        let capabilities = capabilities(provenance: provenance, fusion: fusion)
        let manifest = try manifestOverride
            ?? capabilityManifest(
                capabilities: capabilities,
                compositionIdentifier: provenance ? "pixel-plus-provenance" : "pixel-only"
            )
        let allowlist = try allowlistOverride
            ?? PreflightSample.allowlist(entries: [entry(capabilities: capabilities)])
        let composition = try #require(
            compiledComposition
                ?? composition(
                    identifier: provenance ? "pixel-plus-provenance" : "pixel-only",
                    capabilities: capabilities,
                    linksValidator: provenance
                )
        )
        let bundle = try bundleOverride ?? boundBundle()

        let recorder = PortCallRecorder()
        let store = InMemoryArtifactStore(recorder: recorder)
        await store.register(manifest)
        await store.register(allowlist)
        await store.register(try lifecycleOverride ?? lifecyclePolicy())
        await store.register(try Sample.extensionExecutionPolicy())
        await store.register(try Sample.budgetSet())
        await store.register(try Sample.verificationPolicy())
        await store.register(try Sample.preprocessingContract())
        await store.register(try Sample.calibrationPolicy())
        await store.register(try Sample.copyCatalog())
        if capabilities.contains(.contentCredentialValidation) {
            await store.register(try Sample.provenancePolicy(feasibility: provenanceFeasibility))
        }
        if capabilities.contains(.evidenceFusion) {
            await store.register(try Sample.fusionRule())
        }

        let bundles = StubModelBundleManager(recorder: recorder)
        if activateBundle {
            await bundles.installAndActivate(bundle)
        } else {
            await bundles.install(bundle)
        }

        let clock = VirtualSessionClock()
        let ephemeral = InMemoryEphemeralStore(clock: clock)
        for session in abandonedSessions {
            _ = try await ephemeral.writeComplete([0x01, 0x02], in: .session(session))
        }
        let cleanup = FakeSessionDataDeleter(
            store: ephemeral,
            clock: clock,
            recorder: recorder
        )

        return PreflightScenario(
            preflight: StartupPreflight(
                device: deviceContext ?? device(),
                composition: composition,
                capabilityManifest: Sample.artifact("manifest.capability"),
                verdictCopyCatalog: Sample.artifact("catalog.verdict-copy"),
                embeddedBundle: Sample.bundle(embeddedBundle),
                target: target
            ),
            policies: store,
            bundles: bundles,
            cleanup: cleanup,
            ephemeral: ephemeral,
            recorder: recorder,
            manifest: manifest,
            allowlist: allowlist,
            bundle: bundle
        )
    }
}
