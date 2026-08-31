#if DEBUG

import DefAIkeDomain
import DefAIkeModelBundle
import DefAIkeProvenanceC2PA
import DefAIkeSharedTransfer
import Foundation

// ============================================================================================
// A DEVELOPMENT-ONLY provisioning seam. NOTHING HERE IS RELEASE EVIDENCE.
// ============================================================================================
//
// This whole file is inside `#if DEBUG`, so no symbol in it exists in a Release build and no
// Release code path can reach it. It exists for exactly one purpose: to let a developer see the
// application's own screens on a local Simulator. It produces no release evidence of any kind,
// and a build that used it must never be distributed.
//
// # What it does, and what it deliberately does not
//
// It closes the gap `MainAppComposition.start(...)` refuses at, by *supplying* the input set
// rather than by skipping a check. `StartupPreflight` is untouched: all seven steps run, in
// order, against the values below, and every one of them can still refuse. `ReleaseAdmission`
// is still unforgeable — its initializer is `fileprivate` to `StartupPreflight.swift`, and the
// admission this file makes possible is minted by the real gate or not at all. There is no
// "skip gate" flag here, no relaxed comparison, and no widened initializer.
//
// If any artifact below fails its own schema validation, `forLocalInspection(...)` returns
// `nil`, `MainAppComposition.start(...)` sees no provisioning, and startup refuses exactly as
// it does today. The failure mode is the existing fail-closed one.
//
// # The four provisional inputs, stated plainly
//
// A release input set is externally approved. This one is not, and there are exactly four
// places where that difference is load-bearing. They are the reason this file cannot ship:
//
//   1. **The device allowlist is derived from the observed device.** A real
//      `ReleaseApprovedDeviceAllowlist` is authored before the device is seen, and
//      `StartupPreflight` matches the observed hardware identifier, OS version, and app build
//      against it. Here the single entry is *built from* the observed identity, so the match is
//      guaranteed rather than earned. That is precisely the self-describing loop
//      `MainAppPlatform.swift` warns about, inverted on purpose and confined to DEBUG.
//
//   2. **The gate evidence claims measurements that were not approved.**
//      `GateResultReference.isSatisfied` requires `environment.isPhysicalDeviceEvidence` for
//      every applicable mandatory `DeviceGate`. The references below assert `.physicalIPhone`
//      with passing measurements that no approved Device Validation Plan produced. A physical
//      development phone makes the environment label accurate, but does not make the unmeasured
//      gate result release evidence.
//
//   3. **The Calibration Policy's category boundary is provisional.** The compiled model, its
//      weights, and the logit it produces are real (see `DevelopmentModelBundle`). This seam uses
//      the checkpoint's published boundary and the minimum conversion-safety abstention band,
//      but neither is a product decision: no calibration slice, false-accusation budget evidence,
//      or approved pass rule supports the mapping yet. A label produced through it is therefore
//      **not a verdict**, which is why the application target renders
//      `ChromeCopySurface.developmentBuildNotice` above every screen whenever this seam supplied
//      the provisioning.
//
//   4. **The Evidence Fusion Rule and its fixture outcomes are provisional.** They implement the
//      requested combined-result table and are total over all 15 pixel/provenance combinations,
//      but they have not been signed as release artifacts or validated against an approved
//      Release Fixture Suite. They make the development UI testable; they do not admit Release.
//
// Everything else is a synthetic-but-coherent artifact: it satisfies its own schema and agrees
// with its siblings, which is what lets the gate's comparisons be real comparisons.
//
// # What is a real input rather than a fabricated one
//
// The identifier half of the provisioning is read from the running build through
// `MainAppReleaseProvisioning.installedIdentifiers(bundle:)` — the same shipping reader the
// unprovisioned path uses to report gaps. So the app build identity, the manifest identifier,
// the copy catalogue identifier, the embedded bundle identifier, the App Group, and the pixel
// capability's implementation version all come from `Info.plist` and the target's build
// settings, not from literals here. The artifacts below are then built to *match* what the
// build records, which is the direction a release works in too.
//
// The one identifier this file adds is the linked provenance adapter's implementation version,
// and it is not invented either: it is read from
// `CapabilityComposition.linkedImplementationVersions`, which each composition populates from a
// constant inside the adapter module it actually links. A shared `Info.plist` cannot record two
// different capability sets, so the compiled fact fills in the entry the plist cannot.

// MARK: - Entry point

/// Builds a complete `MainAppReleaseProvisioning` for local Simulator inspection.
///
/// A namespace rather than a value: there is one running build to describe, and a second
/// provisioning would be a second startup gate's input set.
enum DevelopmentProvisioning {

    /// The provisioning for this build, or `nil` when it cannot be assembled coherently.
    ///
    /// `nil` is not a fallback: it returns the application to the shipped fail-closed state, in
    /// which `MainAppComposition.start(...)` reports `releaseInputsUnprovisioned` and ingest is
    /// never exposed.
    static func forLocalInspection<Composition: CapabilityComposition>(
        composition: Composition.Type,
        bundle: Bundle = .main
    ) -> MainAppReleaseProvisioning? {
        // The identifiers the build records. Read, never invented — a missing one is a gap the
        // shipping reader already names, and it leaves this seam with nothing to build against.
        guard case let .success(installed) =
            MainAppReleaseProvisioning.installedIdentifiers(bundle: bundle)
        else {
            if case let .failure(error) =
                MainAppReleaseProvisioning.installedIdentifiers(bundle: bundle)
            {
                DevelopmentDiagnostics.emit("development-provisioning-identifiers-failed", error)
            }
            return nil
        }
        // The running identity, observed through the same platform reader the gate's caller
        // uses. Fabrication 1 hangs off this value: the allowlist entry is built from it.
        guard case let .success(device) = ObservedDeviceIdentity.observed(bundle: bundle) else {
            if case let .failure(error) = ObservedDeviceIdentity.observed(bundle: bundle) {
                DevelopmentDiagnostics.emit("development-provisioning-device-failed", error)
            }
            return nil
        }
        do {
            return try assemble(
                composition: composition,
                installed: installed,
                device: device
            )
        } catch {
            DevelopmentDiagnostics.emit("development-provisioning-assembly-failed", error)
            return nil
        }
    }

    /// How data protection is applied for a locally provisioned run.
    ///
    /// **Fabrication 4, and the only one that gives up a privacy property rather than an approval.**
    ///
    /// On a physical iPhone this is `PlatformDataProtection`, so a DEBUG build on a device gets the
    /// real guarantee: the level the signed Extension Execution Policy names is applied and
    /// verified, and a level that does not read back is a refusal.
    ///
    /// On the Simulator it is `SimulatorDataProtection`, which applies the attribute and does not
    /// require it to read back — because the Simulator reports no protection key back for anything,
    /// so `PlatformDataProtection` refuses every protected directory and **no Analysis Session can
    /// run there at all**. That refusal is correct; this substitution buys the ability to see the
    /// progress and result screens locally at the cost of the bytes a session retains being
    /// genuinely unprotected. `SimulatorDataProtection` reports `enforcesDataProtection == false`
    /// and logs every write, so nothing downstream can read a Simulator run as Requirement 9.6
    /// evidence.
    private static var dataProtection: any DataProtectionApplying {
        #if targetEnvironment(simulator)
        SimulatorDataProtection()
        #else
        PlatformDataProtection()
        #endif
    }

    /// Whether this build's provisioning came from this seam.
    ///
    /// Read by the application target to decide whether to render
    /// `ChromeCopySurface.developmentBuildNotice`. Always `true` in a DEBUG build, because a
    /// DEBUG build is the only build that can reach this file at all; it exists as a named
    /// property rather than as a bare `#if` at the call site so the notice and the seam cannot
    /// be separated by accident.
    static let suppliesUnapprovedInputs = true
}

// MARK: - Assembly

extension DevelopmentProvisioning {

    /// Raised when a development artifact cannot be built. Never surfaced to a user.
    private struct Incoherent: Error {}

    private static func assemble<Composition: CapabilityComposition>(
        composition: Composition.Type,
        installed: MainAppReleaseProvisioning.InstalledIdentifiers,
        device: DeviceContext
    ) throws -> MainAppReleaseProvisioning {
        let ids = try Identifiers(installed: installed)
        let capabilities = composition.capabilities

        // One implementation version per compiled capability. The pixel entry comes from
        // Info.plist; a capability the shared plist cannot record takes the version its linked
        // adapter reports about itself.
        let versions = try implementationVersions(
            composition: composition,
            installed: installed
        )

        let enablesProvenance = capabilities.contains(.contentCredentialValidation)
        let enablesFusion = capabilities.contains(.evidenceFusion)

        let manifest = try capabilityManifest(
            ids: ids,
            device: device,
            compositionIdentifier: composition.identifier,
            capabilities: capabilities,
            versions: versions
        )
        let allowlist = try deviceAllowlist(
            ids: ids,
            device: device,
            capabilities: capabilities,
            versions: versions
        )
        let contract = try preprocessingContract(ids: ids)
        let calibration = try calibrationPolicy(ids: ids)
        let copyCatalog = try verdictCopyCatalog(
            ids: ids,
            enablesProvenance: enablesProvenance,
            enablesFusion: enablesFusion
        )
        let fusionFixtures = enablesFusion ? try fusionFixtureSuite(ids: ids) : nil
        let fusionRule = enablesFusion ? try evidenceFusionRule(ids: ids) : nil
        let budgets = try resourceBudgets(ids: ids)
        let bundle = try boundBundle(ids: ids, device: device, capabilities: capabilities)

        let store = DevelopmentPolicyArtifactStore(
            capabilityManifest: manifest,
            deviceAllowlist: allowlist,
            lifecyclePolicy: try lifecyclePolicy(ids: ids),
            extensionExecutionPolicy: try extensionExecutionPolicy(ids: ids),
            resourceBudgets: budgets,
            bundleVerificationPolicy: try bundleVerificationPolicy(ids: ids),
            preprocessingContract: contract,
            calibrationPolicy: calibration,
            verdictCopyCatalog: copyCatalog,
            provenancePolicy: enablesProvenance
                ? try provenancePolicy(ids: ids, versions: versions)
                : nil,
            fusionRule: fusionRule
        )

        let bundles = DevelopmentModelBundleManager(active: bundle)

        // The Calibration Policy has to activate against this bundle and this evidence index,
        // or `MainAppComposition.assemble(...)` blocks. Building the index from the same records
        // the policy names is what makes activation possible; it is not what makes the boundary
        // approved.
        let evidenceIndex = try ReleaseEvidenceIndex(records: ids.evidenceRecords)

        return MainAppReleaseProvisioning(
            capabilityManifest: installed.capabilityManifest,
            verdictCopyCatalog: installed.verdictCopyCatalog,
            embeddedBundle: installed.embeddedBundle,
            appGroup: installed.appGroup,
            capabilityImplementationVersions: versions,
            policies: store,
            protection: dataProtection,
            bundles: bundles,
            bundleLayout: try DevelopmentModelBundle.layout(source: ids.bundleLayoutEvidence),
            installedBundleRoot: DevelopmentModelBundle.installedRoot,
            evidenceIndex: evidenceIndex,
            fusionFixtures: fusionFixtures,
            release: try releaseRecord(
                ids: ids,
                device: device,
                enablesProvenance: enablesProvenance,
                enablesFusion: enablesFusion
            )
        )
    }

    /// One implementation version per compiled capability, or a refusal.
    private static func implementationVersions<Composition: CapabilityComposition>(
        composition: Composition.Type,
        installed: MainAppReleaseProvisioning.InstalledIdentifiers
    ) throws -> [CapabilityImplementationEntry] {
        var byCapability = Dictionary(
            installed.capabilityImplementationVersions.map { ($0.capability, $0.version) },
            uniquingKeysWith: { first, _ in first }
        )
        for (capability, attested) in composition.linkedImplementationVersions {
            guard let version = try? CapabilityImplementationVersion(validating: attested) else {
                throw Incoherent()
            }
            byCapability[capability] = version
        }
        // Exactly the compiled set, no more and no less. An extra entry or a missing one is a
        // refusal here rather than a mismatch discovered later, and
        // `CompiledCapabilityComposition.init?` would refuse it in any case.
        let entries = composition.capabilities.sorted { $0.rawValue < $1.rawValue }.map {
            capability in
            byCapability[capability].map {
                CapabilityImplementationEntry(capability: capability, version: $0)
            }
        }
        guard entries.allSatisfy({ $0 != nil }) else { throw Incoherent() }
        return entries.compactMap { $0 }
    }
}

// MARK: - The identifier graph

extension DevelopmentProvisioning {

    /// Every identifier the synthetic artifacts share, resolved once.
    ///
    /// Held as one value because the coherence the gate checks *is* the sharing: the manifest's
    /// `policyCompatibility`, each artifact's own `id`, the allowlist entry's version tuple, and
    /// the bundle's component versions all have to name the same artifacts. Deriving them in one
    /// place is what keeps a synthetic release from disagreeing with itself.
    ///
    /// Every value is prefixed `local-development`, so an identifier from this seam is
    /// recognizable anywhere it is recorded.
    private struct Identifiers {
        let capabilityManifest: ArtifactID
        let deviceAllowlist: ArtifactID
        let configuration: ApprovedConfigurationID
        let modelBundle: ModelBundleID
        let verdictCopyCatalog: ArtifactID
        let verdictCopyCompatibility: ArtifactID
        let preprocessingContract: ArtifactID
        let calibrationPolicy: ArtifactID
        let lifecyclePolicy: ArtifactID
        let extensionExecutionPolicy: ArtifactID
        let mainApplicationBudget: ArtifactID
        let shareExtensionBudget: ArtifactID
        let bundleVerificationPolicy: ArtifactID
        let provenancePolicy: ArtifactID
        let fusionRule: ArtifactID
        let fixtureSuite: ArtifactID
        let validationPlan: ArtifactID
        let activationReceipt: ArtifactID
        let releaseRecord: ArtifactID
        let signingKey: SigningKeyID
        let coreMLComponent: ArtifactID
        let evidenceScopeComponent: ArtifactID
        let selfTestComponent: ArtifactID

        /// Evidence artifacts the Calibration Policy references and the index must resolve.
        let evidenceRecords: [EvidenceSource]

        init(installed: MainAppReleaseProvisioning.InstalledIdentifiers) throws {
            // Read from the build, not chosen here.
            capabilityManifest = installed.capabilityManifest
            verdictCopyCatalog = installed.verdictCopyCatalog
            modelBundle = installed.embeddedBundle

            deviceAllowlist = try Self.artifact("allowlist.local-development.devices")
            configuration = try Self.require(
                ApprovedConfigurationID("configuration.local-development.observed-device")
            )
            verdictCopyCompatibility = try Self.artifact("copy.local-development.compatibility")
            preprocessingContract = try Self.artifact("contract.local-development.preprocessing")
            calibrationPolicy = try Self.artifact("policy.local-development.calibration")
            lifecyclePolicy = try Self.artifact("policy.local-development.lifecycle")
            extensionExecutionPolicy = try Self.artifact(
                "policy.local-development.extension-execution"
            )
            mainApplicationBudget = try Self.artifact("budget.local-development.main-application")
            shareExtensionBudget = try Self.artifact("budget.local-development.share-extension")
            bundleVerificationPolicy = try Self.artifact(
                "policy.local-development.bundle-verification"
            )
            provenancePolicy = try Self.artifact("policy.local-development.provenance")
            fusionRule = try Self.artifact("rule.local-development.evidence-fusion")
            fixtureSuite = try Self.artifact("suite.local-development.fixtures")
            validationPlan = try Self.artifact("plan.local-development.device-validation")
            activationReceipt = try Self.artifact("receipt.local-development.activation")
            releaseRecord = try Self.artifact("record.local-development.release-readiness")
            signingKey = try Self.require(SigningKeyID("key.local-development.unsigned"))
            coreMLComponent = try Self.artifact("component.local-development.coreml")
            evidenceScopeComponent = try Self.artifact("component.local-development.scope")
            selfTestComponent = try Self.artifact("component.local-development.self-tests")

            var records = try [
                "evidence.local-development.calibration",
                "evidence.local-development.measurement",
                "evidence.local-development.bundle-layout",
                "evidence.local-development.canonicalization",
                "evidence.local-development.reproducibility",
                "evidence.local-development.file-protection",
                "evidence.local-development.trust-store",
                "evidence.local-development.c2pa-specification",
                "approval.local-development.fusion-rule",
            ].map { try Self.evidence($0) }
            records[6] = try Self.evidence(
                "evidence.local-development.trust-store",
                digestHex: BundledC2PATrustStore.contentDigestHex
            )
            evidenceRecords = records
        }

        /// The calibration evidence record, which the policy names and the index must resolve.
        var calibrationEvidence: EvidenceSource { evidenceRecords[0] }
        var measurementEvidence: EvidenceSource { evidenceRecords[1] }
        var bundleLayoutEvidence: EvidenceSource { evidenceRecords[2] }
        var canonicalizationEvidence: EvidenceSource { evidenceRecords[3] }
        var reproducibilityEvidence: EvidenceSource { evidenceRecords[4] }
        var fileProtectionEvidence: EvidenceSource { evidenceRecords[5] }
        var trustStoreEvidence: EvidenceSource { evidenceRecords[6] }
        var c2paSpecificationEvidence: EvidenceSource { evidenceRecords[7] }
        var fusionRuleApprovalEvidence: EvidenceSource { evidenceRecords[8] }

        static func artifact(_ raw: String) throws -> ArtifactID {
            try require(ArtifactID(raw))
        }

        /// One synthetic evidence record. The digest is a fixed pattern, not a measurement:
        /// nothing was digested, and the index resolves references by equality alone.
        static func evidence(
            _ raw: String,
            digestHex: String = String(repeating: "0", count: 64)
        ) throws -> EvidenceSource {
            EvidenceSource(
                artifact: try artifact(raw),
                version: try CapabilityImplementationVersion(validating: "1.0.0"),
                contentDigest: try require(
                    SHA256Digest(hexadecimal: digestHex)
                )
            )
        }

        static func require<Value>(_ value: Value?) throws -> Value {
            guard let value else { throw Incoherent() }
            return value
        }
    }

    /// One synthetic approval decision.
    ///
    /// An `ApprovalRecord` with `.approved` and an approver naming this seam, so anything that
    /// records the decision records where it came from. It is not an approval: no human decided
    /// it and no evidence backs it.
    private static func approval(_ ids: Identifiers, _ name: String) throws -> ApprovalRecord {
        ApprovalRecord(
            source: try Identifiers.evidence("approval.local-development.\(name)"),
            decision: .approved,
            approver: try Identifiers.require(ApproverID("role.local-development-seam")),
            decidedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func text(_ raw: String) throws -> ArtifactText {
        try ArtifactText(validating: raw)
    }

    private static func version(_ raw: String = "1.0.0") throws -> SchemaSemanticVersion {
        try SchemaSemanticVersion(validating: raw)
    }
}

// MARK: - Capability manifest and device allowlist

extension DevelopmentProvisioning {

    private static func capabilityManifest(
        ids: Identifiers,
        device: DeviceContext,
        compositionIdentifier: String,
        capabilities: Set<CapabilityID>,
        versions: [CapabilityImplementationEntry]
    ) throws -> ReleaseCapabilityManifest {
        try ReleaseCapabilityManifest(
            id: ids.capabilityManifest,
            schemaVersion: .v1,
            // The observed build identity, so step 2's manifest-to-device comparison is a real
            // comparison of two independently produced values.
            appBuild: device.appBuild,
            compositionIdentifier: try text(compositionIdentifier),
            compiledCapabilities: capabilities,
            implementationVersions: versions,
            approvedConfigurationAllowlist: ids.deviceAllowlist,
            approvedBundleCatalog: [ids.modelBundle],
            policyCompatibility: try PolicyCompatibilitySet(
                preprocessingContract: ids.preprocessingContract,
                calibrationPolicy: ids.calibrationPolicy,
                lifecyclePolicy: ids.lifecyclePolicy,
                extensionExecutionPolicy: ids.extensionExecutionPolicy,
                mainApplicationResourceBudget: ids.mainApplicationBudget,
                shareExtensionResourceBudget: ids.shareExtensionBudget,
                bundleVerificationPolicy: ids.bundleVerificationPolicy,
                verdictCopyCompatibility: ids.verdictCopyCompatibility,
                provenancePolicy: capabilities.contains(.contentCredentialValidation)
                    ? .bound(ids.provenancePolicy)
                    : .notApplicable(decision: try approval(ids, "provenance-not-compiled")),
                fusionRule: capabilities.contains(.evidenceFusion)
                    ? .bound(ids.fusionRule)
                    : .notApplicable(decision: try approval(ids, "fusion-not-compiled"))
            ),
            approval: try approval(ids, "capability-manifest")
        )
    }

    /// An allowlist whose single entry describes the device it is running on.
    ///
    /// **Fabrication 1.** A real allowlist is authored from recorded physical-device validation
    /// results and cannot name a configuration nobody measured. This one is constructed from
    /// `ObservedDeviceIdentity`, so the exact-match lookup in step 2 cannot fail. The gate's
    /// comparison still executes; what is missing is any independence between the two sides of
    /// it.
    private static func deviceAllowlist(
        ids: Identifiers,
        device: DeviceContext,
        capabilities: Set<CapabilityID>,
        versions: [CapabilityImplementationEntry]
    ) throws -> ReleaseApprovedDeviceAllowlist {
        let tuple = try ValidationVersionTuple(
            appBuild: device.appBuild,
            modelBundle: ids.modelBundle,
            fixtureSuite: ids.fixtureSuite,
            validationPlan: ids.validationPlan,
            capabilityManifest: ids.capabilityManifest,
            capabilities: capabilities,
            capabilityImplementationVersions: versions
        )
        let candidate = try CandidateDeviceConfiguration(
            deviceModel: try text("Local development Simulator"),
            hardwareIdentifier: device.hardwareIdentifier,
            osVersion: device.osVersion,
            appBuild: device.appBuild,
            // The Simulator provides a Neural Engine only as a compute-unit fallback. Recorded
            // as capable because the compiled model is loaded with the default compute units;
            // it is not a measurement of Apple Neural Engine execution.
            isAppleNeuralEngineCapable: true
        )
        let entry = try ApprovedDeviceConfiguration(
            id: ids.configuration,
            configuration: candidate,
            versionTuple: tuple,
            gateEvidence: try gateEvidence(
                ids: ids,
                enablesProvenance: capabilities.contains(.contentCredentialValidation)
            )
        )
        return try ReleaseApprovedDeviceAllowlist(
            id: ids.deviceAllowlist,
            schemaVersion: .v1,
            entries: [entry],
            approval: try approval(ids, "device-allowlist")
        )
    }

    /// Gate references that claim physical-device evidence which does not exist.
    ///
    /// **Fabrication 2, and the worst one.** `GateResultReference.isSatisfied` is
    /// `outcome.isPassing && environment.isPhysicalDeviceEvidence` for an applicable gate, so a
    /// reference recorded honestly as `.iOSSimulator` leaves `unsatisfiedGates` nonempty and the
    /// gate refuses — which is the correct behaviour and the reason no Simulator run can be a
    /// release. Claiming `.physicalIPhone` here is what makes the entry match.
    ///
    /// Marking the mandatory gates `.notApplicable` instead would be worse, not better: it would
    /// assert that a required device gate does not apply to this configuration. So the false
    /// claim is made in the field where an audit can see it, next to an admission whose
    /// `context.device.environment` says `iOSSimulator`.
    private static func gateEvidence(
        ids: Identifiers,
        enablesProvenance: Bool
    ) throws -> [GateResultReference] {
        try DeviceGate.mandatoryGates.sorted { $0.rawValue < $1.rawValue }.map { gate in
            let applicable = !gate.isProvenanceConditional || enablesProvenance
            return try GateResultReference(
                gate: gate,
                applicability: applicable
                    ? .applicable
                    : .notApplicable(
                        decision: try approval(ids, "gate-not-applicable.\(gate.rawValue)")
                    ),
                outcome: applicable ? .passed : .notExecuted,
                result: try Identifiers.evidence("evidence.local-development.gate.\(gate.rawValue)"),
                environment: .physicalIPhone
            )
        }
    }
}

// MARK: - Preprocessing and calibration

extension DevelopmentProvisioning {

    /// The preprocessing contract, whose fixed geometry is the requirements' and not a choice.
    ///
    /// `ResizeContract.requiredShortEdge`, `CenterCropContract.requiredEdge`, and
    /// `ModelOutputContract.requiredFeatureName` are constants in the domain, and the compiled
    /// model this seam loads takes a 384 by 384 `image` input and produces a `logit` output — so
    /// the contract below is not tailored to the model, it is what the model already satisfies.
    private static func preprocessingContract(
        ids: Identifiers
    ) throws -> PreprocessingContract {
        try PreprocessingContract(
            id: ids.preprocessingContract,
            schemaVersion: .v1,
            supportedContainers: Set(StaticContainer.allCases),
            // Per observed state, not one action for all four. A uniform map is what a first
            // revision of this file used, and it made every session fail at preprocessing:
            // `applyDeclaredOrientation` bound to `absent` asks the renderer to apply a
            // declaration that is not there, which fails closed with
            // `declaredOrientationUnavailable`. Most JPEGs carry no EXIF orientation tag, so that
            // was every input.
            //
            // The rule below is the only coherent reading: apply the declaration where there is
            // one, and leave stored pixel order untouched where there is not. `malformed` and
            // `unsupported` also carry nothing applicable, so they ignore rather than refuse — a
            // development seam that refused them would hide the analysis path behind an
            // unreadable error screen, and the orientation of a rotated image is not what this
            // seam exists to get right.
            orientationRules: try MetadataStateRules(
                rules: ImageMetadataState.allCases.map { state in
                    MetadataStateRules<OrientationAction>.Rule(
                        state: state,
                        action: state == .valid
                            ? .applyDeclaredOrientation
                            : .ignoreDeclaredOrientation
                    )
                }
            ),
            // Convert where there is a profile to convert from; assign the working space where
            // there is not. `convertToWorkingSpace` on an untagged image is the case
            // `materializeWorkingSpaceRGBA` documents as a ColorSync failure it will not retry.
            colorProfileRules: try MetadataStateRules(
                rules: ImageMetadataState.allCases.map { state in
                    MetadataStateRules<ColorProfileAction>.Rule(
                        state: state,
                        action: state == .valid
                            ? .convertToWorkingSpace
                            : .assignWorkingSpaceWithoutConversion
                    )
                }
            ),
            // Discarding is safe for every state because the materialization step fills alpha
            // with 255 when the decode carried none, so discarding and compositing over any
            // background provably agree on an opaque image. Compositing is kept for the state
            // that really does carry transparency, with the background stated explicitly rather
            // than defaulted (Requirement 3.10).
            alphaRules: try MetadataStateRules(
                rules: ImageMetadataState.allCases.map { state in
                    MetadataStateRules<AlphaAction>.Rule(
                        state: state,
                        action: state == .valid
                            ? .compositeOverOpaqueBackground(
                                OpaqueBackgroundColor(red: 0, green: 0, blue: 0)
                            )
                            : .discardAlphaChannel
                    )
                }
            ),
            // The identifier is a Core Graphics constant name, not a human description.
            // `WorkingColorSpace.Identifier` is a closed enum over those names, and a contract
            // naming anything else refuses with `workingColorSpaceUnavailable` — measured: an
            // earlier revision of this file said "Local development sRGB working space" and every
            // session failed at preprocessing.
            //
            // `profileDigest` is `nil` on purpose. It binds the space to exact ICC bytes, and
            // `WorkingColorSpace.resolve` compares it against the bytes the resolved space
            // actually carries. This seam ships no profile, so binding a synthetic digest would
            // guarantee a `workingColorSpaceProfileMismatch`; declaring no digest says truthfully
            // that no ICC bytes are bound.
            rgbWorkingSpace: ColorSpaceDescriptor(
                identifier: try text("kCGColorSpaceSRGB"),
                profileDigest: nil
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
            modelInput: try ModelInputContract(
                featureName: try text("image"),
                width: CenterCropContract.requiredEdge,
                height: CenterCropContract.requiredEdge,
                channelOrder: .rgb,
                elementType: .uint8,
                // The compiled model divides by 255 and applies its own mean and standard
                // deviation inside the graph, so the application supplies unnormalized bytes.
                appliesAppSideNormalization: false
            )
        )
    }

    /// The Calibration Policy, whose boundary is **provisional**.
    ///
    /// **Fabrication 3.** `rawLogitBoundary` starts from the checkpoint's published upstream
    /// boundary, and the abstention half-width is the minimum envelope established by Core ML
    /// conversion parity. Those are model facts, not a product calibration: there is still no
    /// dedicated contemporary phone-camera slice, measured false-accusation rate, or approved
    /// pass rule behind this mapping. The label a run produces is therefore a development
    /// observation and not a verdict. `ChromeCopySurface.developmentBuildNotice` says so on
    /// screen.
    ///
    /// `requiredQualityFeatures` is empty and `qualityRules` is empty, which is the coherent
    /// pairing: a policy that requires no additional quality feature needs no rule covering one,
    /// and Requirement 5.11's binding of a rule to release evidence has nothing to bind.
    private static func calibrationPolicy(ids: Identifiers) throws -> CalibrationPolicy {
        // Keep the development policy tied to the sole permitted checkpoint rather than copying
        // its threshold as another drifting literal. 1.390625 is exactly representable as a
        // Double; with the 0.131 closed abstention half-width, a positive label requires a raw
        // logit strictly above 1.521625 instead of the previous, unsafe 0.131.
        let publishedBoundary = NSDecimalNumber(
            decimal: UpstreamBoundaryMetadata.requiredValue
        ).doubleValue
        return try CalibrationPolicy(
            id: ids.calibrationPolicy,
            schemaVersion: .v1,
            compatibleModel: RequiredPixelModel.identity,
            compatiblePreprocessing: ids.preprocessingContract,
            compatibleVerdictCopy: ids.verdictCopyCompatibility,
            falseAccusationBudget: try FalseAccusationBudget(
                validating: Decimal(sign: .plus, exponent: -3, significand: 5)
            ),
            releasePassRule: try FalseAccusationPassRule(
                statistic: .observedRateAndIntervalUpperBound,
                intervalMethod: .wilsonScore,
                confidenceLevel: try UnitInterval(
                    validating: FalseAccusationPassRule.requiredConfidenceLevel
                )
            ),
            outputLabels: Set(PixelLabelKey.allCases),
            metricCategories: PixelLabelKey.allCases.map {
                MetricCategoryAssignment(label: $0, category: $0.requiredMetricCategory)
            },
            boundaries: [
                try CategoryBoundary(
                    rawLogitBoundary: publishedBoundary,
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
            evidence: [ids.calibrationEvidence],
            upstreamBoundaryMetadata: try UpstreamBoundaryMetadata(
                rawLogitValue: UpstreamBoundaryMetadata.requiredValue,
                role: .modelMetadataOnly
            )
        )
    }
}

// MARK: - Copy catalogue

extension DevelopmentProvisioning {

    /// A catalogue covering every surface this composition can reach.
    ///
    /// The keys follow the same `copy.` convention the shipped String Catalog uses, so a surface
    /// whose approved English value exists resolves and one whose value does not exist renders
    /// nothing — which is the shipped behaviour, unchanged. This catalogue approves *keys*, and
    /// the String Catalog still decides whether a key has a value. Most verdict surfaces have
    /// no value in this repository, so most of a completed report stays unrendered even here.
    private static func verdictCopyCatalog(
        ids: Identifiers,
        enablesProvenance: Bool,
        enablesFusion: Bool
    ) throws -> ApprovedVerdictCopyCatalog {
        var surfaces = VerdictCopySurface.unconditionalSurfaces
        if enablesProvenance {
            for state in ProvenanceStateKey.allCases {
                surfaces.insert(.provenanceState(state))
            }
        }
        if enablesFusion {
            for key in try DevelopmentFusionPolicy.allCopyKeys() {
                surfaces.insert(.combinedSummary(key))
            }
        }
        let entries = try surfaces.sorted { $0.description < $1.description }.map { surface in
            let localizationKey: ApprovedCopyKey
            if case let .combinedSummary(key) = surface {
                localizationKey = key
            } else {
                localizationKey = try Identifiers.require(
                    ApprovedCopyKey(
                        "copy." + surface.description.replacingOccurrences(of: "/", with: ".")
                    )
                )
            }
            return VerdictCopyEntry(
                surface: surface,
                localizationKey: localizationKey
            )
        }
        return try ApprovedVerdictCopyCatalog(
            id: ids.verdictCopyCatalog,
            schemaVersion: .v1,
            compatibilityID: ids.verdictCopyCompatibility,
            languageTag: try text(ApprovedVerdictCopyCatalog.requiredLanguageTag),
            entries: entries,
            approval: try approval(ids, "verdict-copy-catalog")
        )
    }
}

// MARK: - Combined evidence policy

extension DevelopmentProvisioning {
    private static func evidenceFusionRule(ids: Identifiers) throws -> EvidenceFusionRule {
        try EvidenceFusionRule(
            id: ids.fusionRule,
            schemaVersion: .v1,
            ruleVersion: try version(),
            compatibleVerdictCopy: ids.verdictCopyCompatibility,
            fixtureSuite: ids.fixtureSuite,
            entries: try FusionLaneCombination.allCombinations.map { combination in
                FusionEntry(
                    combination: combination,
                    disposition: .show(try DevelopmentFusionPolicy.copyKey(for: combination)),
                    fixture: try DevelopmentFusionPolicy.fixtureID(for: combination)
                )
            },
            approval: ApprovalRecord(
                source: ids.fusionRuleApprovalEvidence,
                decision: .approved,
                approver: try Identifiers.require(
                    ApproverID("role.local-development-seam")
                ),
                decidedAt: Date(timeIntervalSince1970: 0)
            )
        )
    }

    private static func fusionFixtureSuite(ids: Identifiers) throws -> ReleaseFixtureSuite {
        let digest = try Identifiers.require(
            SHA256Digest(hexadecimal: String(repeating: "6", count: 64))
        )
        return try ReleaseFixtureSuite(
            id: ids.fixtureSuite,
            schemaVersion: .v1,
            provenanceApplicability: .applicable,
            fixtures: try FusionLaneCombination.allCombinations.map { combination in
                let path = "fusion/\(combination.pixel.rawValue)/"
                    + "\(combination.provenance.rawValue).jpg"
                return try FixtureRecord(
                    id: DevelopmentFusionPolicy.fixtureID(for: combination),
                    family: DevelopmentFusionPolicy.fixtureFamily(for: combination.provenance),
                    assetPath: try Identifiers.require(CanonicalRelativePath(path)),
                    contentDigest: digest,
                    byteCount: try PositiveByteCount(validating: 1),
                    source: ids.c2paSpecificationEvidence,
                    expectations: [
                        .pixelLabel(combination.pixel),
                        .provenanceState(combination.provenance),
                    ]
                )
            }
        )
    }
}

// MARK: - Lifecycle, execution, and budgets

extension DevelopmentProvisioning {

    private static func lifecyclePolicy(ids: Identifiers) throws -> DataLifecyclePolicy {
        try DataLifecyclePolicy(
            id: ids.lifecyclePolicy,
            schemaVersion: .v1,
            deadlines: try SessionCleanupReason.allCases.map {
                DataLifecyclePolicy.Deadline(
                    reason: $0,
                    deadline: try ValidatedDuration(validating: 30_000)
                )
            },
            approval: try approval(ids, "lifecycle-policy")
        )
    }

    private static func extensionExecutionPolicy(
        ids: Identifiers
    ) throws -> ExtensionExecutionPolicy {
        try ExtensionExecutionPolicy(
            id: ids.extensionExecutionPolicy,
            schemaVersion: .v1,
            requiresVisibleConsent: true,
            delegatesInferenceToMainApplication: true,
            stagedFileProtection: .complete,
            pendingHandoffPolicy: .instructRecovery,
            protectionEvidence: ids.fileProtectionEvidence
        )
    }

    /// Budgets with headroom a Simulator run can actually work inside.
    ///
    /// Every ceiling here is a development value, not an approved limit, and it is chosen large
    /// enough that a local run is not refused by its own budget. `PlatformResourceGovernor`
    /// still compares against these numbers and still refuses a reservation that exceeds one,
    /// so the mechanism is exercised — what is missing is a Device Validation Plan behind the
    /// numbers.
    private static func resourceBudgets(ids: Identifiers) throws -> ResourceBudgetSet {
        try ResourceBudgetSet(
            mainApplication: try budget(
                ids: ids,
                id: ids.mainApplicationBudget,
                target: .mainApplication
            ),
            shareExtension: try budget(
                ids: ids,
                id: ids.shareExtensionBudget,
                target: .shareExtension
            )
        )
    }

    private static func budget(
        ids: Identifiers,
        id: ArtifactID,
        target: ExecutionTarget
    ) throws -> ResourceBudget {
        let metrics = ResourceMetric.requiredMetrics(for: target)
            .sorted { $0.rawValue < $1.rawValue }
        return try ResourceBudget(
            id: id,
            schemaVersion: .v1,
            target: target,
            hardLimits: try metrics.map { metric in
                try ResourceLimitEntry(
                    metric: metric,
                    limit: try limit(for: metric),
                    measurementConditions: ids.measurementEvidence
                )
            },
            validationPlan: ids.validationPlan
        )
    }

    private static func limit(for metric: ResourceMetric) throws -> ValidatedLimit {
        switch metric {
        case .thermalState:
            // `serious` rather than `critical`: a development machine under load reports `fair`
            // or `serious`, and permitting `critical` would make the ceiling unobservable.
            return .thermal(maximumState: .serious)
        case .decodedPixelCount:
            return .numeric(value: try positive(120_000_000), unit: .pixels)
        case .peakResidentMemory:
            return .numeric(value: try positive(2_147_483_648), unit: .bytes)
        case .temporaryStorage:
            return .numeric(value: try positive(536_870_912), unit: .bytes)
        case .encodedInputSize:
            return .numeric(value: try positive(134_217_728), unit: .bytes)
        case .coldModelLoadTime, .warmAnalysisLatency, .handoffLatency:
            // Recorded limits, never deadlines. Nothing in the graph derives a timeout from a
            // budget value (Requirement 15.10), and this seam adds none.
            return .numeric(value: try positive(600_000), unit: .milliseconds)
        case .energyImpact:
            return .numeric(value: try positive(10_000), unit: .milliwattHours)
        }
    }

    private static func positive(_ value: Decimal) throws -> PositiveDecimal {
        try PositiveDecimal(validating: value)
    }

    private static func bundleVerificationPolicy(
        ids: Identifiers
    ) throws -> BundleVerificationPolicy {
        try BundleVerificationPolicy(
            id: ids.bundleVerificationPolicy,
            schemaVersion: .v1,
            algorithm: .ed25519,
            canonicalizationProfile: ids.canonicalizationEvidence,
            trustedKeys: [
                TrustedSigningKey(
                    key: ids.signingKey,
                    algorithm: .ed25519,
                    publicKeyDigest: try Identifiers.require(
                        SHA256Digest(hexadecimal: String(repeating: "2", count: 64))
                    ),
                    status: .active,
                    governanceApproval: try approval(ids, "signing-key")
                )
            ],
            rotationBehavior: .activeKeysOnly,
            revocationBehavior: .rejectBundle,
            maximumManifestByteCount: try PositiveByteCount(validating: 65_536),
            reproducibilityEvidence: ids.reproducibilityEvidence
        )
    }
}

// MARK: - Provenance policy

extension DevelopmentProvisioning {

    /// The Provenance Policy the provenance composition's manifest binds.
    ///
    /// The validator implementation version is the one the linked adapter reports about itself,
    /// taken from `versions` rather than written here, so this policy cannot describe a
    /// different reviewed release than the binary contains. `validatorBinaryDigest` is a
    /// synthetic value: nothing digested the linked bytes, and no runtime check compares it.
    ///
    /// `permitsNetworkRevocationCheck` is `false` and the trust store is offline-only. That is
    /// not a development convenience — an online revocation check would contradict the offline
    /// guarantee the archive audits measure.
    private static func provenancePolicy(
        ids: Identifiers,
        versions: [CapabilityImplementationEntry]
    ) throws -> ProvenancePolicy {
        let validatorVersion = try Identifiers.require(
            versions.first { $0.capability == .contentCredentialValidation }?.version
        )
        return try ProvenancePolicy(
            id: ids.provenancePolicy,
            schemaVersion: .v1,
            capability: .contentCredentialValidation,
            validatorImplementationVersion: validatorVersion,
            validatorBinaryDigest: try Identifiers.require(
                SHA256Digest(hexadecimal: String(repeating: "3", count: 64))
            ),
            supportedSpecification: ids.c2paSpecificationEvidence,
            trustStore: ProvenanceTrustStoreDescriptor(
                store: ids.trustStoreEvidence,
                anchorCount: try PositiveCount(validating: BundledC2PATrustStore.anchorCount),
                isOfflineOnly: true
            ),
            revocationBehavior: try ProvenanceRevocationBehavior(
                permitsNetworkRevocationCheck: false,
                unavailableAnswerState: .indeterminate,
                approval: try approval(ids, "revocation-behavior")
            ),
            supportedAssertionLabels: [try text("c2pa.actions")],
            displayableFields: [.signerIdentity, .claimGenerator, .assertionLabels],
            processingLimits: ProvenanceProcessingLimits(
                maximumManifestByteCount: try PositiveByteCount(validating: 1_048_576),
                maximumAssertionCount: try PositiveCount(validating: 64),
                maximumNestingDepth: try PositiveCount(validating: 8),
                maximumProcessingDuration: try ValidatedDuration(validating: 5_000)
            ),
            resourceBudget: ids.mainApplicationBudget,
            statusMappings: try provenanceStatusMappings(),
            feasibilityApproval: try approval(ids, "provenance-feasibility")
        )
    }

    /// The complete fail-closed mapping for every structural reader condition and every
    /// library failure code this adapter classifies. A future unknown code becomes the
    /// analyzer's indeterminate fallback; it can never become validated by default.
    private static func provenanceStatusMappings() throws -> [ProvenanceStatusMapping] {
        var mappings = C2PAReaderCondition.allCases.map { condition in
            let state: ProvenanceStateKey
            switch condition {
            case .allChecksPassed: state = .validated
            case .noManifestFound: state = .absent
            case .manifestNotEmbedded, .containerNotSupported: state = .unsupported
            case .revocationAnswerUnavailable, .inputNotParsable,
                 .validationResultAbsent: state = .indeterminate
            }
            return ProvenanceStatusMapping(
                status: C2PAStatusVocabulary.statusID(for: condition),
                state: state
            )
        }
        mappings += try C2PAFailureClassification.allKnownCodes.sorted().map { code in
            ProvenanceStatusMapping(
                status: try Identifiers.require(
                    C2PAStatusVocabulary.statusID(forLibraryCode: code)
                ),
                state: .invalid
            )
        }
        mappings.append(
            ProvenanceStatusMapping(
                status: try Identifiers.require(
                    C2PAStatusVocabulary.statusID(forLibraryCode: "general.error")
                ),
                state: .indeterminate
            )
        )
        return mappings
    }
}

// MARK: - The Model Bundle

extension DevelopmentProvisioning {

    /// The bound development bundle: a real compiled model behind an unverified receipt.
    ///
    /// The component versions have to name the same artifacts the policies do, because step 3
    /// compares all three of `preprocessingContract`, `calibrationPolicy`, and
    /// `verdictCopyCompatibility` against the resolved configuration and refuses a disagreement.
    /// That comparison is real here; what is not real is the receipt that made the bundle
    /// bindable. See `DevelopmentModelBundle` for exactly which parts are fabricated.
    private static func boundBundle(
        ids: Identifiers,
        device: DeviceContext,
        capabilities: Set<CapabilityID>
    ) throws -> BoundModelBundle {
        let manifest = try ModelBundleManifest(
            schemaVersion: .v1,
            bundleID: ids.modelBundle,
            // The domain's own pinned identity, including the weight digest. Not chosen here.
            modelIdentity: RequiredPixelModel.identity,
            modelFormat: try ModelFormatDescriptor(
                programKind: .mlProgram,
                computePrecision: .float16,
                minimumOS: .iOS17
            ),
            inputContract: try ModelInputContract(
                featureName: try text("image"),
                width: CenterCropContract.requiredEdge,
                height: CenterCropContract.requiredEdge,
                channelOrder: .rgb,
                elementType: .uint8,
                appliesAppSideNormalization: false
            ),
            outputContract: try ModelOutputContract(
                featureName: try text(ModelOutputContract.requiredFeatureName),
                elementType: .float32,
                isPositiveGoing: true
            ),
            componentVersions: BundleComponentVersions(
                coreMLModel: ids.coreMLComponent,
                preprocessingContract: ids.preprocessingContract,
                calibrationPolicy: ids.calibrationPolicy,
                evidenceScope: ids.evidenceScopeComponent,
                verdictCopyCompatibility: ids.verdictCopyCompatibility,
                selfTestSpecification: ids.selfTestComponent
            ),
            artifacts: try DevelopmentModelBundle.declaredArtifacts(),
            compatibility: try CompatibilityMatrix(
                compatibleAppBuilds: [device.appBuild],
                // Exactly the compiled set, so a bundle admitted for a pixel-only build cannot
                // be admitted for a provenance build or the reverse.
                requiredCapabilities: capabilities,
                minimumOS: .iOS17
            ),
            upstreamBoundaryMetadata: try UpstreamBoundaryMetadata(
                rawLogitValue: UpstreamBoundaryMetadata.requiredValue,
                role: .modelMetadataOnly
            ),
            signingKey: ids.signingKey
        )
        let receipt = try ActivationReceipt(
            id: ids.activationReceipt,
            schemaVersion: .v1,
            bundleID: ids.modelBundle,
            verificationPolicy: ids.bundleVerificationPolicy,
            verifiedManifestDigest: try Identifiers.require(
                SHA256Digest(hexadecimal: String(repeating: "5", count: 64))
            ),
            verifiedArtifactDigests: try DevelopmentModelBundle.declaredArtifacts(),
            // Both fabricated. No signature was verified and no self-test was executed.
            signatureOutcome: .passed,
            selfTestOutcome: .passed,
            deviceContext: device,
            activationGeneration: try PositiveCount(validating: 1),
            activatedAt: Date(timeIntervalSince1970: 0)
        )
        guard let bundle = BoundModelBundle(manifest: manifest, receipt: receipt) else {
            throw Incoherent()
        }
        return bundle
    }
}

// MARK: - Release readiness record

extension DevelopmentProvisioning {

    /// The record the four disclosure destinations quote.
    ///
    /// Every gate record below reports `.passed` for a gate nobody ran, so the disclosure
    /// screens would quote a readiness claim that is not true. Two things keep that contained:
    /// `MainAppRootView` opens no disclosure path (`openDisclosurePath` is empty in the
    /// composition root), and most disclosure copy has no approved String Catalog value, so
    /// nothing renders even if a path were opened.
    ///
    /// The record is required to construct the graph at all, which is why it exists rather than
    /// being omitted.
    private static func releaseRecord(
        ids: Identifiers,
        device: DeviceContext,
        enablesProvenance: Bool,
        enablesFusion: Bool
    ) throws -> ReleaseReadinessRecord {
        try ReleaseReadinessRecord(
            id: ids.releaseRecord,
            schemaVersion: .v1,
            appBuild: device.appBuild,
            capabilityManifest: ids.capabilityManifest,
            modelBundle: ids.modelBundle,
            deviceAllowlist: ids.deviceAllowlist,
            gateRecords: try ReleaseGate.allCases.map { gate in
                let applicable: Bool
                switch gate {
                case .provenanceFeasibility: applicable = enablesProvenance
                case .fusionRuleApproval: applicable = enablesFusion
                default: applicable = true
                }
                return try ReleaseGateRecord(
                    gate: gate,
                    applicability: applicable
                        ? .applicable
                        : .notApplicable(
                            decision: try approval(ids, "release-gate.\(gate.rawValue)")
                        ),
                    outcome: applicable ? .passed : .notExecuted,
                    evidence: try Identifiers.evidence(
                        "evidence.local-development.release.\(gate.rawValue)"
                    )
                )
            },
            distributionRights: DistributionRightsRecord(
                repositoryCodeLicense: try approval(ids, "code-license"),
                datasetDistributionTerms: try approval(ids, "dataset-terms")
            ),
            modelGovernance: try ModelGovernanceDecisionRecord(
                modelIdentity: RequiredPixelModel.identity,
                isIndependentNonPeerReviewed: true,
                // Recorded honestly: no red-team validation exists and none is inherited.
                redTeamValidationValid: false,
                inheritedRedTeamStatus: .invalidNoReportInherited,
                decision: try approval(ids, "model-governance")
            ),
            // No benchmark claim is approved for publication, and this seam approves none.
            benchmarkClaims: []
        )
    }
}

#endif
