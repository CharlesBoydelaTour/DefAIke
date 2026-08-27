import DefAIkeDomain

/// A candidate Model Bundle whose manifest, release signature, and complete artifact
/// tree have all been verified locally.
///
/// Constructible only inside this module, and only by a verification run that reached
/// the end without a finding, so "the tree was checked" is carried by the type rather
/// than asserted alongside it.
///
/// What this value does **not** claim: nothing about model identity beyond what the
/// manifest declares, nothing about compatibility with the running build, nothing
/// about release self-tests, and nothing about activation. Those are separate steps
/// and separate values; an integrity-verified bundle is not yet a bindable one
/// (Requirements 10.8, 10.11, and 10.12).
public struct VerifiedBundleArtifactTree: Hashable, Sendable {
    public let bundleID: ModelBundleID

    /// The manifest as parsed from the exact bytes the signature covers.
    public let manifest: ModelBundleManifest

    /// Digest of those exact bytes.
    public let manifestDigest: SHA256Digest

    /// Every declared artifact as actually observed, ordered by canonical path.
    ///
    /// Each record's byte count and digest are what streaming measured, and each
    /// equals what the manifest declared — otherwise this value would not exist. The
    /// deterministic ordering is what lets an activation receipt record a complete
    /// digest inventory that two runs over the same tree produce identically.
    public let verifiedArtifacts: [ArtifactDigestRecord]

    /// The Bundle Verification Policy version that supplied the algorithm, the
    /// trusted keys, and the rotation and revocation rules for this run.
    public let verificationPolicyID: ArtifactID

    /// The trusted key the manifest signature verified under.
    public let signingKey: SigningKeyID

    init(
        bundleID: ModelBundleID,
        manifest: ModelBundleManifest,
        manifestDigest: SHA256Digest,
        verifiedArtifacts: [ArtifactDigestRecord],
        verificationPolicyID: ArtifactID,
        signingKey: SigningKeyID
    ) {
        self.bundleID = bundleID
        self.manifest = manifest
        self.manifestDigest = manifestDigest
        self.verifiedArtifacts = verifiedArtifacts
        self.verificationPolicyID = verificationPolicyID
        self.signingKey = signingKey
    }

    /// The verified record for one declared path, or `nil` when it is not declared.
    public func verifiedArtifact(at path: CanonicalRelativePath) -> ArtifactDigestRecord? {
        verifiedArtifacts.first { $0.path == path }
    }
}
