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
// # How it reaches the app bundle
//
// `ios/project.yml` names `../data/coreml/commfor-lowq-384.mlpackage` in the app target's
// resource phase, in the **Debug configuration only**, and Xcode's Core ML compiler turns it
// into `commfor-lowq-384.mlmodelc` at the bundle root. ``installedRoot`` resolves against that
// bundle.
//
// This was previously read from the repository working tree through `#filePath`, on the
// reasoning that `data/` is `.gitignore`d and a committed spec must not reference a path a fresh
// clone lacks. That reasoning had a false premise: `.gitignore` excludes the *compiled*
// `.mlmodelc` but explicitly tracks the `.mlpackage` it is built from, with the comment "the one
// heavy artifact we do track". A fresh clone has the model. What it lacked was a build step that
// put it anywhere the app could read.
//
// The old arrangement worked on the Simulator and nowhere else: a physical device cannot read the
// developer's working tree, so `BundleCompiledModelLocator` handed the loader a missing directory
// and every session on device ended in `model-load-error` — a correct fail-closed outcome, and a
// useless app. Compiling the tracked `.mlpackage` into the bundle costs nothing in git, works on
// both, and keeps a Release build model-free.
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
    ///
    /// A bare filename with no directory component, because that is where Xcode's Core ML
    /// compiler puts a compiled model: `commfor-lowq-384.mlpackage` in the target's resource
    /// phase becomes `commfor-lowq-384.mlmodelc` at the bundle root.
    static let compiledModelRelativePath = "commfor-lowq-384.mlmodelc"

    /// The weight blob inside the compiled model, whose digest `RequiredPixelModel` pins.
    static let weightBlobRelativePath = "commfor-lowq-384.mlmodelc/weights/weight.bin"

    /// Where the bundle's declared relative paths resolve against: this build's own resource
    /// directory.
    ///
    /// This used to be the repository's `data/` directory, derived from `#filePath`. That worked
    /// on the Simulator and nowhere else — a physical device cannot read the developer's working
    /// tree, so the locator handed the loader a missing directory and every session on device
    /// ended in `model-load-error`. Reading from the app's own bundle works on both, which is
    /// what makes a device build useful rather than merely installable.
    ///
    /// The model reaches the bundle because `ios/project.yml` names
    /// `../data/coreml/commfor-lowq-384.mlpackage` in this target's resource phase **in the
    /// Debug configuration only**. Xcode's Core ML compiler turns it into
    /// `commfor-lowq-384.mlmodelc` here. The `.mlpackage` is the form this repository already
    /// tracks in git, so nothing new is committed to make a device build work.
    ///
    /// Two consequences worth stating rather than discovering:
    ///
    ///   * **The bundled model is recompiled by whatever Xcode built it.** Measured with Xcode
    ///     26.6, the compiled `weights/weight.bin` is byte-identical to both
    ///     `data/coreml/commfor-lowq-384.mlmodelc`'s and
    ///     `RequiredPixelModel.weightDigestHexadecimal` — Core ML compilation rewrites the
    ///     graph, not the weight blob. That is a measurement of one toolchain rather than a
    ///     guarantee across versions, and it is not *checked* anywhere on this path: checking
    ///     the digest is `ModelBundleActivator`'s job and this seam does not have that
    ///     collaborator. Which is also why the digest in ``declaredArtifacts()`` stays a fixed
    ///     pattern rather than becoming a measurement — a measurement here would look like
    ///     verification.
    ///   * **A Release build carries no model**, by `EXCLUDED_SOURCE_FILE_NAMES`. An unapproved
    ///     model inside a Release archive would make the release audit's "no Core ML artifact"
    ///     observation read as Requirement 10.1 satisfied, when no signed Initial Model Bundle
    ///     exists. A Release build refuses at startup anyway, so it needs no model.
    ///
    /// `nil` is unreachable in practice — an iOS app bundle always has a resource URL — but the
    /// fallback is the bundle root rather than a force-unwrap, because a crash here would be a
    /// development seam taking down a build that has not even reached its startup gate.
    static let installedRoot: URL = Bundle.main.resourceURL ?? Bundle.main.bundleURL

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
