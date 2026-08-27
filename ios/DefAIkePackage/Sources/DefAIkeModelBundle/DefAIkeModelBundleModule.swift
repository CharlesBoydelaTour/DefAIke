/// Boundary marker for Model Bundle integrity and activation.
///
/// Responsibility: bounded manifest parsing, path canonicalization, artifact
/// tree digests, signature verification through the injected approved Bundle
/// Verification Policy, model identity and compatibility checks, release
/// self-tests, verification receipts, atomic activation, and offline rollback.
///
/// Dependency rule: `DefAIkeDomain` only. Signature algorithms, trusted keys,
/// rotation, and revocation rules arrive as approved artifacts; this module
/// declares no cryptographic or trust default of its own. Remote Model Updates
/// stay disabled: no network client belongs here (Requirements 10.19–10.21).
///
/// In place, steps 1 through 6 of the fixed verification order, each producing a
/// value the next step consumes and none of them constructible from outside:
///
/// | Step | Type | What its existence means |
/// |---|---|---|
/// | 1–3 | ``VerifiedBundleArtifactTree`` | The bytes are the signed bytes |
/// | 4–5 | ``CompatibleBundleCandidate`` | This build may run them, and the self-test artifacts are complete |
/// | 6 | ``SelfTestedBundleCandidate`` | The self-tests ran offline and agreed |
/// | 7 | `BoundModelBundle` | A receipt was persisted and the active pointer was replaced |
///
/// ``ModelBundleManifestParser`` and ``ModelBundleIntegrityVerifier`` cover the
/// first three; ``ModelBundleCompatibilityVerifier`` covers identity, component
/// compatibility, and self-test completeness; ``ReleaseSelfTestRunner`` covers
/// offline execution under the active approved budget; ``ModelBundleActivator``
/// covers the receipt, the atomic commit, and the `ModelBundleManaging`
/// conformance, and is the module's only stateful type. The immutable Analysis
/// Session binding (6.4) arrives with that task.
public enum DefAIkeModelBundleModule: Sendable {
    /// Stable module identifier used by module-boundary and release-audit checks.
    public static let name = "DefAIkeModelBundle"
}
