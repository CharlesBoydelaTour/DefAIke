#if DEBUG

import DefAIkeDomain
import DefAIkeModelBundle
import Foundation

// ============================================================================================
// The DEVELOPMENT Model Bundle: a real compiled model, an unverified wrapper around it.
// ============================================================================================
//
// `#if DEBUG` throughout. See `DevelopmentProvisioning.swift` for what this seam is and why
// nothing in it is release evidence.
//
// # The model is real
//
// The bundle described here points at `data/coreml/commfor-lowq-384.mlmodelc`, the compiled
// community-forensics low-quality detector the corpus tooling in this repository produces. It is
// the model the domain already pins: `RequiredPixelModel.checkpointIdentifier` names that
// checkpoint, `RequiredPixelModel.weightDigestHexadecimal` is the SHA-256 of that directory's
// `weights/weight.bin`, its input is a 384 by 384 `image` tensor matching
// `CenterCropContract.requiredEdge` and `ModelInputContract`, and its output is a single `logit`
// matching `ModelOutputContract.requiredFeatureName`. So the weights, the graph, and the logit a
// local run produces are the real ones, loaded by the real `CoreMLPixelModelLoader` through the
// real `BundleCompiledModelLocator`. Nothing about the inference is stubbed.
//
// # Why it is not bundled as a resource
//
// It is read from the repository working tree rather than copied into the app bundle, and that is
// a deliberate choice between two imperfect options:
//
//   * Adding a `resources:` entry to `ios/project.yml` would make the committed project spec
//     reference `data/`, which `.gitignore` excludes. Project generation, and then every build,
//     would depend on a path a fresh clone does not have — so the committed spec would describe
//     a project that cannot be generated. It would also copy 42 MB into every Debug and Release
//     build of both compositions.
//   * Reading it from the working tree keeps `data/` unreferenced by the Xcode project entirely,
//     costs nothing in a Release build, and is the approach this repository already takes for the
//     same artifact: `ApprovedCompiledPixelModel` in `DefAIkeCoreMLTests` locates it from
//     `#filePath` for exactly this reason.
//
// The cost is that this works only where the process can read the developer's working tree,
// which means the Simulator and nowhere else. On a physical device the location resolves to a
// path that does not exist, `BundleCompiledModelLocator` hands the loader a missing directory,
// and the session ends in `model-load-error` — a real Analysis Error on the error screen, which
// is the correct fail-closed outcome rather than a fallback model.
//
// # What is not real
//
// The *wrapper*. A `BoundModelBundle` is normally reachable only through
// `ModelBundleActivator`, which streams and compares artifact digests, verifies an Ed25519
// signature over a canonicalized manifest, executes the release self-test specification, and
// writes an activation receipt. None of that happens here: the receipt below reports `.passed`
// for a signature nobody checked and a self-test nobody ran, and the artifact digests are fixed
// patterns rather than measurements of the bytes on disk. `BoundModelBundle.init(manifest:
// receipt:)` accepts it because a passing receipt is what it requires, which is exactly why this
// file cannot ship.
//
// The one digest that is not fabricated is `ModelIdentity.requiredWeightDigest`, because it comes
// from `RequiredPixelModel` rather than from here. It is also not *checked* here — checking it is
// the activator's job — so its correctness is a property of the domain constant and of the file
// on disk, not of this seam.

/// The development Model Bundle and the layout that locates its compiled model.
enum DevelopmentModelBundle {

    /// The compiled model's path relative to ``installedRoot``.
    ///
    /// Split from the root so `ApprovedBundleLayout` and `ModelBundleManifest` can declare the
    /// same relative path the layout resolves, which is what `BundleCompiledModelLocator`
    /// requires: it refuses a layout naming a file the manifest never declared.
    static let compiledModelRelativePath = "coreml/commfor-lowq-384.mlmodelc"

    /// The weight blob inside the compiled model, whose digest `RequiredPixelModel` pins.
    static let weightBlobRelativePath = "coreml/commfor-lowq-384.mlmodelc/weights/weight.bin"

    /// Where the bundle's declared relative paths resolve against: the repository's `data`
    /// directory.
    ///
    /// Derived from this file's own location rather than from a working directory or a build
    /// setting, so it does not depend on how the process was launched. This file lives at
    /// `<repository>/ios/DefAIkeApp/Shared/`, so four levels up is the repository root.
    ///
    /// `#filePath` is a compile-time string, so this is a constant baked into a DEBUG binary and
    /// not a filesystem search. It performs no I/O and creates nothing.
    static let installedRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "data", directoryHint: .isDirectory)

    /// The approved-layout value naming each release role's path.
    ///
    /// Only the compiled model and its weight blob point at anything real. The self-test
    /// specification, the fixture catalogue, and the fixture root name paths this repository does
    /// not carry, because fixtures are nonshipping release evidence. Nothing in the startup path
    /// or the analysis path reads them, and a build that needed them would fail to find them
    /// rather than find a substitute.
    static func layout(source: EvidenceSource) throws -> ApprovedBundleLayout {
        guard let layout = ApprovedBundleLayout(
            source: source,
            compiledModel: try path(compiledModelRelativePath),
            modelWeightBlob: try path(weightBlobRelativePath),
            selfTestSpecification: try path("local-development/self-test-specification.json"),
            fixtureCatalog: try path("local-development/fixture-catalog.json"),
            fixtureRoot: try path("local-development/fixtures"),
            approval: try approval(source: source)
        ) else {
            throw LayoutUnavailable()
        }
        return layout
    }

    /// Raised when a development layout or bundle cannot be built. Never surfaced to a user.
    struct LayoutUnavailable: Error {}

    static func path(_ raw: String) throws -> CanonicalRelativePath {
        guard let value = CanonicalRelativePath(raw) else { throw LayoutUnavailable() }
        return value
    }

    /// The one declared artifact: the compiled model directory.
    ///
    /// Its digest is a fixed pattern rather than a measurement of the directory tree, and its
    /// byte count is nominal. Nothing in the startup or analysis path compares either against
    /// the bytes on disk — comparing them is `ModelBundleActivator`'s job, and that is the
    /// collaborator this seam does not have.
    static func declaredArtifacts() throws -> [ArtifactDigestRecord] {
        guard let digest = SHA256Digest(hexadecimal: String(repeating: "4", count: 64)) else {
            throw LayoutUnavailable()
        }
        return [
            ArtifactDigestRecord(
                path: try path(compiledModelRelativePath),
                kind: .directoryTree,
                byteCount: 1,
                digest: digest
            )
        ]
    }

    private static func approval(source: EvidenceSource) throws -> ApprovalRecord {
        guard let approver = ApproverID("role.local-development-seam") else {
            throw LayoutUnavailable()
        }
        return ApprovalRecord(
            source: source,
            decision: .approved,
            approver: approver,
            decidedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

// MARK: - The bundle manager

/// A `ModelBundleManaging` over one already-active development bundle.
///
/// It verifies nothing, and says so. `ModelBundleActivator` is the shipping implementation and it
/// needs four collaborators this repository has no adapter for — bundle content reading,
/// signature verification, a self-test executor, and an activation record store — which is
/// `UnprovisionedReleaseInput.modelBundleVerification`. This actor does not close that gap; it
/// stands in for it locally.
///
/// What it does keep is the compatibility check, because that one needs no missing collaborator:
/// `BoundModelBundle.isCompatible(with:)` is a comparison against the observed release context,
/// and an incompatible bundle is refused here exactly as `StubModelBundleManager` refuses one. So
/// a bundle whose compatibility matrix does not admit this build still produces
/// `model-load-error` rather than being activated.
actor DevelopmentModelBundleManager: ModelBundleManaging {
    private let bundle: BoundModelBundle

    init(active: BoundModelBundle) {
        self.bundle = active
    }

    func verifiedActiveBundle(
        for context: ReleaseContext
    ) throws(AnalysisFault) -> BoundModelBundle {
        guard bundle.isCompatible(with: context) else {
            throw .analysis(.modelLoadError, stage: .modelLoad)
        }
        return bundle
    }

    func activateLocalCandidate(
        _ id: ModelBundleID,
        context: ReleaseContext
    ) throws(AnalysisFault) -> BoundModelBundle {
        guard id == bundle.bundleID else {
            throw .analysis(.modelLoadError, stage: .modelLoad)
        }
        return try verifiedActiveBundle(for: context)
    }

    func rollback(
        to id: ModelBundleID,
        context: ReleaseContext
    ) throws(AnalysisFault) -> BoundModelBundle {
        // The identical path, matching the port's rule that a retained bundle is re-verified
        // exactly like a new one. There is only one bundle here, so a rollback to any other
        // identifier is a refusal.
        try activateLocalCandidate(id, context: context)
    }
}

// MARK: - The policy artifact store

/// A `PolicyArtifactReading` over one fixed set of synthetic artifacts.
///
/// Lookup is by exact identifier and there is no default, no fallback, and no synthesis: an
/// identifier this store was not built with is `ReleaseArtifactError.notFound`. That matters even
/// in a development seam, because it is what keeps the gate's reference graph a real graph — a
/// manifest naming a policy this store does not hold refuses at step 2 rather than resolving to
/// something plausible.
///
/// It replaces `UnprovisionedPolicyArtifactStore` for a local run and nothing else. It is not the
/// reader `UnprovisionedReleaseInput.policyArtifactStore` names: that one reads an embedded signed
/// artifact set and verifies it against the Bundle Verification Policy, and this one reads values
/// a DEBUG binary constructed in memory.
struct DevelopmentPolicyArtifactStore: PolicyArtifactReading {
    let capabilityManifestValue: ReleaseCapabilityManifest
    let deviceAllowlistValue: ReleaseApprovedDeviceAllowlist
    let lifecyclePolicyValue: DataLifecyclePolicy
    let extensionExecutionPolicyValue: ExtensionExecutionPolicy
    let resourceBudgetsValue: ResourceBudgetSet
    let bundleVerificationPolicyValue: BundleVerificationPolicy
    let preprocessingContractValue: PreprocessingContract
    let calibrationPolicyValue: CalibrationPolicy
    let verdictCopyCatalogValue: ApprovedVerdictCopyCatalog
    let provenancePolicyValue: ProvenancePolicy?
    let fusionRuleValue: EvidenceFusionRule?

    init(
        capabilityManifest: ReleaseCapabilityManifest,
        deviceAllowlist: ReleaseApprovedDeviceAllowlist,
        lifecyclePolicy: DataLifecyclePolicy,
        extensionExecutionPolicy: ExtensionExecutionPolicy,
        resourceBudgets: ResourceBudgetSet,
        bundleVerificationPolicy: BundleVerificationPolicy,
        preprocessingContract: PreprocessingContract,
        calibrationPolicy: CalibrationPolicy,
        verdictCopyCatalog: ApprovedVerdictCopyCatalog,
        provenancePolicy: ProvenancePolicy?,
        fusionRule: EvidenceFusionRule?
    ) {
        self.capabilityManifestValue = capabilityManifest
        self.deviceAllowlistValue = deviceAllowlist
        self.lifecyclePolicyValue = lifecyclePolicy
        self.extensionExecutionPolicyValue = extensionExecutionPolicy
        self.resourceBudgetsValue = resourceBudgets
        self.bundleVerificationPolicyValue = bundleVerificationPolicy
        self.preprocessingContractValue = preprocessingContract
        self.calibrationPolicyValue = calibrationPolicy
        self.verdictCopyCatalogValue = verdictCopyCatalog
        self.provenancePolicyValue = provenancePolicy
        self.fusionRuleValue = fusionRule
    }

    func capabilityManifest(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> ReleaseCapabilityManifest {
        try match(capabilityManifestValue, capabilityManifestValue.id, id)
    }

    func deviceAllowlist(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> ReleaseApprovedDeviceAllowlist {
        try match(deviceAllowlistValue, deviceAllowlistValue.id, id)
    }

    func lifecyclePolicy(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> DataLifecyclePolicy {
        try match(lifecyclePolicyValue, lifecyclePolicyValue.id, id)
    }

    func extensionExecutionPolicy(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> ExtensionExecutionPolicy {
        try match(extensionExecutionPolicyValue, extensionExecutionPolicyValue.id, id)
    }

    func resourceBudgets(
        mainApplication: ArtifactID,
        shareExtension: ArtifactID
    ) async throws(ReleaseArtifactError) -> ResourceBudgetSet {
        guard mainApplication == resourceBudgetsValue.mainApplication.id else {
            throw .notFound(mainApplication)
        }
        guard shareExtension == resourceBudgetsValue.shareExtension.id else {
            throw .notFound(shareExtension)
        }
        return resourceBudgetsValue
    }

    func bundleVerificationPolicy(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> BundleVerificationPolicy {
        try match(bundleVerificationPolicyValue, bundleVerificationPolicyValue.id, id)
    }

    func preprocessingContract(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> PreprocessingContract {
        try match(preprocessingContractValue, preprocessingContractValue.id, id)
    }

    func calibrationPolicy(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> CalibrationPolicy {
        try match(calibrationPolicyValue, calibrationPolicyValue.id, id)
    }

    func verdictCopyCatalog(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> ApprovedVerdictCopyCatalog {
        try match(verdictCopyCatalogValue, verdictCopyCatalogValue.id, id)
    }

    func provenancePolicy(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> ProvenancePolicy {
        guard let value = provenancePolicyValue, value.id == id else { throw .notFound(id) }
        return value
    }

    func fusionRule(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> EvidenceFusionRule {
        guard let value = fusionRuleValue, value.id == id else { throw .notFound(id) }
        return value
    }

    /// One artifact, or `notFound` for any other identifier.
    private func match<Value>(
        _ value: Value,
        _ held: ArtifactID,
        _ requested: ArtifactID
    ) throws(ReleaseArtifactError) -> Value {
        guard held == requested else { throw .notFound(requested) }
        return value
    }
}

#endif
