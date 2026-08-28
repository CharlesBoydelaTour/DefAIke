import DefAIkeDomain
import DefAIkeProvenanceAPI
import DefAIkeProvenanceC2PA

/// The application's capability composition.
///
/// DefAIke ships one app. It compiles both Version 1 evidence capabilities — pixel analysis
/// and Content Credential validation — so one install carries both source lanes, and the
/// Evidence Report's two cards describe two things the same binary can do rather than two
/// things two different downloads could do.
///
/// # What replaced the two-archive split, and what that cost
///
/// This composition supersedes a pair of them: a pixel-only build that did not link
/// `DefAIkeProvenanceC2PA` at all, and a pixel-plus-provenance build that did. Under that
/// arrangement "the installed release cannot validate Content Credentials" was a fact about
/// the linked bytes, checkable from outside the source with `nm` on a shipped archive.
///
/// It is no longer. This build links the adapter, so keeping the validator inactive is now the
/// job of `ProvenanceLaneProvider.resolve(linksValidator:analyzer:policy:manifest:)`, the
/// signed Release Capability Manifest, and the startup gate — code and artifacts rather than
/// absence. That is a weaker kind of evidence and is recorded here as such rather than
/// glossed: what an auditor can still verify from the outside is that the *Share Extension*
/// links no validator, which is what keeps this composition's positive linkage measurement
/// non-vacuous now that no second application archive supplies the negative case.
///
/// Requirements 6.2 and 6.3 permit this. They put capability selection in the Release
/// Process, and 6.3's pixel-analysis-only release is a release whose provenance lane is
/// marked unavailable — which this composition reports, honestly, and does today. Neither
/// requirement asks for a second signed archive; that was a design choice, and this is a
/// different one.
///
/// # Linking is not enabling
///
/// Compiling the adapter does not enable the capability for distribution. The Provenance
/// Feasibility Gate (implementation feasibility, supported-iPhone feasibility, correctness
/// fixtures, resource limits, security and dependency review, and physical-device validation)
/// must pass, and the startup preflight must find an exact match between this composition,
/// the signed Release Capability Manifest, and the version-bound allowlist entry.
enum CompiledCapabilityComposition: CapabilityComposition {
    static let identifier = "pixel-plus-provenance"
    static let linksProvenanceValidator = true

    /// Pixel analysis plus Content Credential validation, which is what this build compiles.
    ///
    /// Compiling a capability is not enabling it: the signed manifest decides that, and the
    /// gate requires set equality in both directions.
    static let capabilities: Set<CapabilityID> = [
        .pixelAnalysis,
        .contentCredentialValidation,
    ]

    /// Anchors the linked conditional adapter. Read by the archive-composition audit, which
    /// uses it to prove the shipped archive contains the reviewed validator it claims.
    static let provenanceAdapterModule = DefAIkeProvenanceC2PAModule.name

    /// The reviewed validator release this build links.
    static let reviewedValidatorVersion = DefAIkeProvenanceC2PAModule.reviewedValidatorVersion

    /// `nil`, and honestly so.
    ///
    /// `C2PAProvenanceValidator` deliberately does not conform to `ProvenanceAnalyzing`, and
    /// its own documentation says why: `analyze(_:policy:)` returns a `ProvenanceEvidence`
    /// unconditionally, so a conformance would have to resolve a
    /// `ProvenanceFeasibilityFinding` by *selecting* a state, and no signed artifact in the
    /// current schema says which state answers an unresolved condition. `ProvenancePolicy`
    /// maps statuses, not faults.
    ///
    /// So this composition supplies no analyzer, and that is fail-closed rather than a gap
    /// left open. `ProvenanceLaneProvider.resolve(...)` reports
    /// `UnavailableReason.validatorEnablementUnapproved` for exactly this shape — linked,
    /// enabled by the manifest, no analyzer — which is the one reason that misstates neither
    /// the module graph nor the manifest. Nothing here fabricates a validated, absent, or
    /// indeterminate state to make the lane appear to work, and nothing reports the linked
    /// adapter as uncompiled to borrow a reason that was true only of the deleted pixel-only
    /// build.
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
    /// `content-credential-validation` version before the startup gate compares anything
    /// against the signed manifest. A build provisioned as a validator release it does not
    /// link is refused with `CompositionInconsistency.linkedImplementationVersionMismatch`,
    /// so a provenance-enabled manifest naming a different adapter release cannot be
    /// satisfied by this archive — which is what "requires the exact approved adapter
    /// version" means at the archive level.
    ///
    /// What this does *not* establish, stated plainly because the gap is real: the constant
    /// is the version the adapter's author reviewed, so it attests which release the *source*
    /// was written against, not which binary the linker consumed. Nothing in a Swift target
    /// can read its own resolved dependency graph. The coupling from this constant to the
    /// pinned and resolved dependency is enforced outside the binary, over `Package.swift`,
    /// `Package.resolved`, and this file, by `ios/Scripts/check-capability-composition.py`;
    /// and the digest coupling to reviewed *bytes* is the signed Provenance Policy's
    /// `validatorBinaryDigest`, which no installed artifact supplies yet.
    static let linkedImplementationVersions: [CapabilityID: String] = [
        .contentCredentialValidation: DefAIkeProvenanceC2PAModule.reviewedValidatorVersion,
    ]
}

/// What still has to be approved before the linked validator can supply a provenance lane.
///
/// Recorded as values in the same style as the presentation layer's gap vocabularies, so a
/// release audit can enumerate what is owed instead of reading it out of a comment. Both are
/// external approvals rather than code that has not been written: neither can be resolved by
/// this repository, which is why the merged app still reports an unavailable provenance lane.
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
