import DefAIkeDomain
import DefAIkeProvenanceAPI
import DefAIkeProvenanceC2PA

/// Pixel-plus-provenance composition.
///
/// Compiled into `DefAIkeApp-PixelPlusProvenance` only, which is the sole build output that
/// links `DefAIkeProvenanceC2PA`.
///
/// Linking the adapter does not enable the capability for distribution. The Provenance
/// Feasibility Gate (implementation feasibility, supported-iPhone feasibility, correctness
/// fixtures, resource limits, security and dependency review, and physical-device validation)
/// must pass, and the startup preflight must find an exact match between this composition, the
/// signed Release Capability Manifest, and the version-bound allowlist entry.
enum CompiledCapabilityComposition: CapabilityComposition {
    static let identifier = "pixel-plus-provenance"
    static let linksProvenanceValidator = true

    /// Pixel analysis plus Content Credential validation, which is what this build compiles.
    ///
    /// Compiling the capability is not enabling it: the signed manifest decides that, and the
    /// gate requires set equality in both directions.
    static let capabilities: Set<CapabilityID> = [
        .pixelAnalysis,
        .contentCredentialValidation,
    ]

    /// Anchors the linked conditional adapter, proving it is absent from the pixel-only
    /// composition. Read by the archive-composition audit.
    static let provenanceAdapterModule = DefAIkeProvenanceC2PAModule.name

    /// The reviewed validator release this build links.
    static let reviewedValidatorVersion = DefAIkeProvenanceC2PAModule.reviewedValidatorVersion

    /// `nil`, and honestly so.
    ///
    /// `C2PAProvenanceValidator` deliberately does not conform to `ProvenanceAnalyzing`, and its
    /// own documentation says why: `analyze(_:policy:)` returns a `ProvenanceEvidence`
    /// unconditionally, so a conformance would have to resolve a `ProvenanceFeasibilityFinding`
    /// by *selecting* a state, and no signed artifact in the current schema says which state
    /// answers an unresolved condition. `ProvenancePolicy` maps statuses, not faults.
    ///
    /// So this composition supplies no analyzer. That is fail-closed rather than a gap left
    /// open: `ProvenanceLaneProvider.resolve(analyzer:policy:manifest:)` treats a `nil` analyzer
    /// as the pixel-only lane whatever the manifest enables, so a provenance-enabled manifest
    /// paired with this build fails the preflight's linkage check instead of shipping a lane
    /// that cannot answer. Nothing here fabricates a validated, absent, or indeterminate state
    /// to make the lane appear to work.
    ///
    /// Two approved decisions have to land before this returns a validator, and both are
    /// recorded in `UnresolvedProvenanceEnablement`.
    static func provenanceAnalyzer(
        store: any EphemeralFileStoring,
        policy: ProvenancePolicy?
    ) -> (any ProvenanceAnalyzing)? {
        nil
    }

    /// The adapter-version pin, read out of the linked module.
    ///
    /// One entry, and the value is not a literal: it is
    /// `DefAIkeProvenanceC2PAModule.reviewedValidatorVersion`, which is
    /// `C2PALibraryReader.reviewedImplementationVersion`, which is the version
    /// `DefAIkePackage/Package.swift` exact-pins `c2pa-swift` to. So the expression only
    /// resolves in a build that links the adapter, and its value changes if and only if the
    /// reviewed release the adapter is written against changes.
    ///
    /// `compiledComposition(implementationVersions:)` compares this against the provisioned
    /// `content-credential-validation` version before the startup gate compares anything against
    /// the signed manifest. A build provisioned as a validator release it does not link is
    /// refused with `CompositionInconsistency.linkedImplementationVersionMismatch`, so a
    /// provenance-enabled manifest naming a different adapter release cannot be satisfied by
    /// this archive — which is what "requires the exact approved adapter version" means at the
    /// archive level.
    ///
    /// What this does *not* establish, stated plainly because the gap is real: the constant is
    /// the version the adapter's author reviewed, so it attests which release the *source* was
    /// written against, not which binary the linker consumed. Nothing in a Swift target can read
    /// its own resolved dependency graph. The coupling from this constant to the pinned and
    /// resolved dependency is enforced outside the binary, over `Package.swift`,
    /// `Package.resolved`, and this file, by `ios/Scripts/check-capability-composition.py`; and
    /// the digest coupling to reviewed *bytes* is the signed Provenance Policy's
    /// `validatorBinaryDigest`, which no installed artifact supplies yet.
    static let linkedImplementationVersions: [CapabilityID: String] = [
        .contentCredentialValidation: DefAIkeProvenanceC2PAModule.reviewedValidatorVersion,
    ]
}

/// What still has to be approved before the linked validator can supply a provenance lane.
///
/// Recorded as values in the same style as the presentation layer's gap vocabularies, so a
/// release audit can enumerate what is owed instead of reading it out of a comment.
enum UnresolvedProvenanceEnablement: String, Hashable, Sendable, CaseIterable {
    /// No approved mapping from a `ProvenanceFeasibilityFinding` to one of the five enabled
    /// states, so the adapter cannot conform to `ProvenanceAnalyzing` without choosing one.
    case feasibilityFindingStateMapping = "feasibility-finding-state-mapping"

    /// No approved offline trust store is installed.
    ///
    /// `C2PAValidatorConfiguration` requires trust material whose descriptor is the store the
    /// signed policy names. The reviewed `c2pa-swift` 0.0.12 release additionally refuses
    /// configuration with synthetic anchors, so every real read reports that the validator is
    /// not configurable and the manifest-reading path stays unreachable until an approved
    /// offline trust store exists.
    case approvedOfflineTrustStore = "approved-offline-trust-store"
}
