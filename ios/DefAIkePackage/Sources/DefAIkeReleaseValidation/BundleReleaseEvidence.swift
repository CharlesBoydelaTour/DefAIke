import DefAIkeDomain
import DefAIkeModelBundle

// Verifying a produced bundle and recording what happened
// (Requirements 10.8 through 10.13, 10.17, 14.13, and 14.16).
//
// Requirement 14.13 asks a release to *verify and record* six things: the release signature,
// the per-artifact digests, the compatibility result, the release self-test result, the
// atomic activation result, and the verified rollback result. Two properties make that
// recording worth anything, and both are structural here.
//
// **The checks are the runtime's, not a second set.** Every outcome below is derived from a
// value only `DefAIkeModelBundle` can produce:
//
//   | Recorded gate | Derived from | Why it cannot be faked |
//   |---|---|---|
//   | release signature | ``VerifiedBundleArtifactTree`` exists | constructible only by a run whose detached signature verified under a trusted key the active policy admitted |
//   | per-artifact digests | the same value | the same run stream-hashed every declared artifact and refused missing, extra, and mismatched content |
//   | compatibility | ``CompatibleBundleCandidate`` exists | constructible only by a run that resolved identity, format, contracts, components, build compatibility, and self-test completeness |
//   | release self-tests | ``BoundModelBundle`` exists | constructible only from a *bindable* ``ActivationReceipt``, whose `selfTestOutcome` passed |
//   | atomic activation | the same value | the receipt was persisted and the active pointer atomically replaced |
//   | verified rollback | a second ``BoundModelBundle`` from ``ModelBundleManaging/rollback(to:context:)`` | the identical verification path, with no shortcut for a prior bundle |
//
// There is no `outcome:` parameter anywhere in this file's public surface. A caller cannot
// hand in a ``GateOutcome``; every one is computed from whether a runtime value came back.
// That is what "generated, not asserted" means here: this module records, and it has no way
// to declare a gate passed.
//
// **Nothing here becomes a distribution decision.** Requirements 14.15 and 14.16 block a
// distribution when a mandatory record entry is missing or failing, and that judgement
// belongs to the Release Readiness Record. ``BundleActivationEvidence`` exposes which
// recorded gates are not passing and stops there — no `blocksDistribution`, no
// `isReleaseReady`, and no path by which a missing result becomes a pass.
//
// ## The reachable ceiling over synthetic content
//
// Requirement 10.4 pins the model weight-blob digest to one specific SHA-256 value, and the
// real blob is not in this repository. So a bundle built from synthetic staged content
// reaches a definite, nameable stopping point and no further:
//
//   * integrity verification **passes completely** — manifest, signature, and every declared
//     artifact digest, including the compiled model's tree digest; and
//   * compatibility verification passes every declarative check and then stops at the weight
//     measurement, which is deliberately the last thing it does.
//
// ``ProducedBundleVerification/stoppedAtApprovedWeightBlob`` is that ceiling as a value, so
// a caller and a test can name it instead of reading a green result that was never green.
// Reaching past it requires the approved weight blob; nothing in this module can substitute
// for one, and no field here can be set to pretend otherwise.

// MARK: - The six recorded gates

/// One Model Bundle gate a release records before distribution (Requirement 14.13).
///
/// Exactly the six the requirement enumerates, named so a release-readiness entry cites the
/// gate rather than describing it.
public enum BundleReleaseGate: String, Hashable, Sendable, CaseIterable, CustomStringConvertible {
    case releaseSignature = "release-signature"
    case perArtifactDigests = "per-artifact-digests"
    case compatibility
    case releaseSelfTests = "release-self-tests"
    case atomicActivation = "atomic-activation"
    case verifiedRollback = "verified-rollback"

    public var description: String { rawValue }
}

// MARK: - Verification record

/// What the runtime verifiers said about one produced bundle.
///
/// Constructible only inside this module, and only from what a verification run returned, so
/// no caller can record an outcome the runtime did not produce.
public struct ProducedBundleVerification: Equatable, Sendable {
    public let bundleID: ModelBundleID

    /// Whether the detached signature verified over the exact manifest bytes
    /// (Requirement 10.6).
    public let releaseSignature: GateOutcome

    /// Whether every declared artifact matched its declared byte count and digest, with no
    /// missing and no undeclared content (Requirement 10.5).
    public let perArtifactDigests: GateOutcome

    /// Whether this build may run the bundle, and whether its self-test artifacts are
    /// complete (Requirements 10.8 through 10.10).
    public let compatibility: GateOutcome

    /// The finding that refused the bundle, or `nil` when every check above passed.
    ///
    /// Kept in full because a release audit needs to know which step refused a candidate. It
    /// is never presented to a user: every finding reduces to `model-load-error` at the
    /// session boundary (Requirements 10.16 and 11.17).
    public let finding: ModelBundleVerificationError?

    /// Digest of the exact manifest bytes that were verified, when they were.
    public let verifiedManifestDigest: SHA256Digest?

    /// The complete digest inventory as streaming measured it, ordered by canonical path.
    ///
    /// Empty when integrity verification did not complete. Directly comparable to
    /// ``UnsignedInitialModelBundle/digestInventory``, which uses the same ordering.
    public let verifiedArtifactDigests: [ArtifactDigestRecord]

    /// The signing key the manifest signature verified under, when it did.
    public let signingKey: SigningKeyID?

    init(
        bundleID: ModelBundleID,
        releaseSignature: GateOutcome,
        perArtifactDigests: GateOutcome,
        compatibility: GateOutcome,
        finding: ModelBundleVerificationError?,
        verifiedManifestDigest: SHA256Digest?,
        verifiedArtifactDigests: [ArtifactDigestRecord],
        signingKey: SigningKeyID?
    ) {
        self.bundleID = bundleID
        self.releaseSignature = releaseSignature
        self.perArtifactDigests = perArtifactDigests
        self.compatibility = compatibility
        self.finding = finding
        self.verifiedManifestDigest = verifiedManifestDigest
        self.verifiedArtifactDigests = verifiedArtifactDigests
        self.signingKey = signingKey
    }

    /// Whether the only thing that refused this bundle was the approved weight blob.
    ///
    /// True exactly for ``ModelBundleVerificationError/modelWeightDigestMismatch(_:)``, which
    /// compatibility verification reaches last and only after every other check has passed.
    /// So this is the documented ceiling for any bundle assembled without the approved
    /// weight blob, and it is a distinct recorded fact rather than a pass: `compatibility`
    /// is still ``GateOutcome/failed`` when it is true.
    public var stoppedAtApprovedWeightBlob: Bool {
        guard case .modelWeightDigestMismatch = finding else { return false }
        return true
    }

    /// Whether every declarative check up to the weight measurement passed.
    ///
    /// True for a fully verified bundle and true at the ceiling. Useful for a build log that
    /// wants to say "everything a synthetic bundle can demonstrate, it demonstrated"; never a
    /// substitute for ``compatibility``.
    public var passedEveryCheckBeforeTheWeightBlob: Bool {
        releaseSignature.isPassing && perArtifactDigests.isPassing
            && (compatibility.isPassing || stoppedAtApprovedWeightBlob)
    }
}

// MARK: - Activation and rollback record

/// What one activation or rollback produced.
///
/// Projected from the ``BoundModelBundle`` the runtime returned. It records identities and a
/// generation; it carries no image data, no fixture bytes, and no session identity, for the
/// same reason the receipt it comes from does not (Requirement 9.11).
public struct BundleActivationObservation: Hashable, Sendable {
    public let bundleID: ModelBundleID

    /// The receipt that authorized this activation.
    public let receiptID: ArtifactID

    /// Monotonic across published activations, so two activations are distinguishable
    /// (Requirement 10.13).
    public let activationGeneration: PositiveCount

    /// The Bundle Verification Policy version the activation was verified under.
    public let verificationPolicyID: ArtifactID

    /// The six component versions activation replaced as one tuple (Requirement 10.13).
    public let componentVersions: BundleComponentVersions

    /// The integrity status the bound bundle carries. One value by construction: an
    /// unverified bundle cannot be bound at all.
    public let integrityStatus: ModelBundleIntegrityStatus

    init(_ bound: BoundModelBundle) {
        self.bundleID = bound.bundleID
        self.receiptID = bound.integrity.activationReceiptID
        self.activationGeneration = bound.activationGeneration
        self.verificationPolicyID = bound.integrity.verificationPolicyID
        self.componentVersions = bound.componentVersions
        self.integrityStatus = bound.integrity.status
    }
}

/// The complete Model Bundle evidence one release records before distribution
/// (Requirements 14.13 and 14.16).
///
/// Constructible only inside this module, and only from what the runtime returned.
public struct BundleActivationEvidence: Equatable, Sendable {
    /// The verification record the first three gates come from.
    public let verification: ProducedBundleVerification

    /// Whether the candidate's own release self-tests ran and agreed (Requirement 10.11).
    ///
    /// Read from the activation result rather than re-run. The activator runs the self-tests
    /// as step 6 of the one verification path and records the outcome in the receipt a
    /// ``BoundModelBundle`` is built from, so a bound bundle *is* a passing self-test result.
    /// Running them a second time here would produce a result no receipt describes.
    public let releaseSelfTests: GateOutcome

    /// Whether the receipt was persisted and the active pointer atomically replaced
    /// (Requirement 10.13).
    public let atomicActivation: GateOutcome

    /// Whether a rollback through the identical verification path succeeded
    /// (Requirement 10.17).
    public let verifiedRollback: GateOutcome

    /// The bundle rollback was attempted to. An approved input: this module does not choose
    /// which prior bundle a release demonstrates rollback with.
    public let rollbackTarget: ModelBundleID

    public let activated: BundleActivationObservation?
    public let rolledBack: BundleActivationObservation?

    /// The fault activation returned, when it returned one.
    ///
    /// Coarse on purpose. ``ModelBundleManaging`` speaks the closed ten-value vocabulary a
    /// session can see, so every refusal arrives as `model-load-error`. The precise finding
    /// for the earlier steps is in ``verification``, which is what makes the ceiling
    /// nameable.
    public let activationFault: AnalysisFault?

    /// The fault rollback returned, when it returned one.
    public let rollbackFault: AnalysisFault?

    init(
        verification: ProducedBundleVerification,
        releaseSelfTests: GateOutcome,
        atomicActivation: GateOutcome,
        verifiedRollback: GateOutcome,
        rollbackTarget: ModelBundleID,
        activated: BundleActivationObservation?,
        rolledBack: BundleActivationObservation?,
        activationFault: AnalysisFault?,
        rollbackFault: AnalysisFault?
    ) {
        self.verification = verification
        self.releaseSelfTests = releaseSelfTests
        self.atomicActivation = atomicActivation
        self.verifiedRollback = verifiedRollback
        self.rollbackTarget = rollbackTarget
        self.activated = activated
        self.rolledBack = rolledBack
        self.activationFault = activationFault
        self.rollbackFault = rollbackFault
    }

    public var bundleID: ModelBundleID { verification.bundleID }

    /// The recorded outcome of each of Requirement 14.13's six gates.
    public func outcome(of gate: BundleReleaseGate) -> GateOutcome {
        switch gate {
        case .releaseSignature: verification.releaseSignature
        case .perArtifactDigests: verification.perArtifactDigests
        case .compatibility: verification.compatibility
        case .releaseSelfTests: releaseSelfTests
        case .atomicActivation: atomicActivation
        case .verifiedRollback: verifiedRollback
        }
    }

    /// Every gate whose recorded outcome is not a pass, in a stable order.
    ///
    /// A projection, not a verdict. A missing result appears here exactly as a failing one
    /// does, because Requirement 14.15 treats them the same; what a release does about that
    /// is the Release Readiness Record's decision, and nothing here makes it.
    public var gatesWithoutAPassingResult: [BundleReleaseGate] {
        BundleReleaseGate.allCases.filter { !outcome(of: $0).isPassing }
    }

    /// Whether the recorded evidence stops exactly where the approved weight blob stops it.
    ///
    /// True when integrity passed completely and the only refusal was the weight measurement.
    /// Says nothing about the gates that never ran, which stay ``GateOutcome/notExecuted``.
    public var stoppedAtApprovedWeightBlob: Bool {
        verification.stoppedAtApprovedWeightBlob
    }
}

// MARK: - Recorder

/// Runs the runtime verification path over a produced bundle and records what happened.
///
/// Holds nothing but the injected runtime components, so it has no approved value of its own
/// and no state two runs could share. Every method returns a record rather than throwing:
/// refusal is the thing being recorded, and a recorder that threw would leave a release with
/// no entry for the gate that failed.
public struct BundleReleaseEvidenceRecorder: Sendable {
    private let integrity: ModelBundleIntegrityVerifier
    private let compatibility: ModelBundleCompatibilityVerifier
    private let bundles: any ModelBundleManaging

    /// Creates a recorder over the runtime's own verifiers and bundle manager.
    ///
    /// All three are required with no default, and all three are supplied rather than
    /// constructed here. That is what keeps this module free of approved values: the
    /// verifiers are already unconstructible without their policy, keys, layout, and
    /// configuration, and the guarantee is inherited rather than restated.
    public init(
        integrity: ModelBundleIntegrityVerifier,
        compatibility: ModelBundleCompatibilityVerifier,
        bundles: any ModelBundleManaging
    ) {
        self.integrity = integrity
        self.compatibility = compatibility
        self.bundles = bundles
    }

    /// Verifies one produced bundle with the runtime's own checks and records the result.
    ///
    /// Steps 1 through 5 of the fixed verification order, run by calling
    /// `DefAIkeModelBundle`'s verifiers in the order they are meant to be called. Nothing
    /// here reimplements a step, and nothing here continues past a refusal.
    public func verify(
        _ bundle: ModelBundleID,
        for context: ReleaseContext
    ) -> ProducedBundleVerification {
        let tree: VerifiedBundleArtifactTree
        do {
            tree = try integrity.verify(bundle)
        } catch {
            return Self.integrityRefused(bundle, finding: error)
        }
        do {
            _ = try compatibility.resolve(tree, for: context)
        } catch {
            return Self.record(tree, compatibility: .failed, finding: error)
        }
        return Self.record(tree, compatibility: .passed, finding: nil)
    }

    /// Verifies, activates, and rolls back, recording all six gates.
    ///
    /// The ordering is the content of this method:
    ///
    ///   1. Verification runs first, so the record names the exact step that refused a
    ///      candidate before the coarse port vocabulary takes over.
    ///   2. Activation runs the whole path again through ``ModelBundleManaging``. That
    ///      repetition is not waste — it is Requirement 10.13's atomic commit, which only
    ///      exists on the activation path, and step 7 has no separate entry point.
    ///   3. Rollback runs only when activation succeeded. A rollback with nothing active to
    ///      leave in place demonstrates nothing about Requirement 10.17, so it is recorded as
    ///      ``GateOutcome/notExecuted`` rather than as a failure of a gate that never ran.
    ///
    /// `rollbackTarget` is supplied. Which prior bundle a release demonstrates rollback with
    /// is a release decision, and inferring one — the same bundle, the previous generation,
    /// whatever is installed — would be this module deciding it.
    public func recordActivationEvidence(
        of bundle: ModelBundleID,
        rollingBackTo rollbackTarget: ModelBundleID,
        for context: ReleaseContext
    ) async -> BundleActivationEvidence {
        let verification = verify(bundle, for: context)

        let activated: BoundModelBundle?
        let activationFault: AnalysisFault?
        do {
            activated = try await bundles.activateLocalCandidate(bundle, context: context)
            activationFault = nil
        } catch {
            activated = nil
            activationFault = error
        }

        // Only a completed activation makes a rollback meaningful, and only a completed
        // activation is a self-test result: a `BoundModelBundle` exists solely for a bindable
        // receipt, whose self-test outcome passed.
        guard let activated else {
            return BundleActivationEvidence(
                verification: verification,
                releaseSelfTests: .notExecuted,
                atomicActivation: .failed,
                verifiedRollback: .notExecuted,
                rollbackTarget: rollbackTarget,
                activated: nil,
                rolledBack: nil,
                activationFault: activationFault,
                rollbackFault: nil
            )
        }

        let rolledBack: BoundModelBundle?
        let rollbackFault: AnalysisFault?
        do {
            rolledBack = try await bundles.rollback(to: rollbackTarget, context: context)
            rollbackFault = nil
        } catch {
            rolledBack = nil
            rollbackFault = error
        }

        return BundleActivationEvidence(
            verification: verification,
            releaseSelfTests: .passed,
            atomicActivation: .passed,
            verifiedRollback: rolledBack == nil ? .failed : .passed,
            rollbackTarget: rollbackTarget,
            activated: BundleActivationObservation(activated),
            rolledBack: rolledBack.map(BundleActivationObservation.init),
            activationFault: nil,
            rollbackFault: rollbackFault
        )
    }

    // MARK: - Attribution

    /// Records a completed integrity run, with whatever compatibility then said.
    ///
    /// A ``VerifiedBundleArtifactTree`` exists only for a candidate whose signature verified
    /// and whose every declared artifact matched, so both gates are passing here by the
    /// existence of the value rather than by a separate claim.
    private static func record(
        _ tree: VerifiedBundleArtifactTree,
        compatibility: GateOutcome,
        finding: ModelBundleVerificationError?
    ) -> ProducedBundleVerification {
        ProducedBundleVerification(
            bundleID: tree.bundleID,
            releaseSignature: .passed,
            perArtifactDigests: .passed,
            compatibility: compatibility,
            finding: finding,
            verifiedManifestDigest: tree.manifestDigest,
            verifiedArtifactDigests: tree.verifiedArtifacts,
            signingKey: tree.signingKey
        )
    }

    /// Attributes an integrity refusal to the gate it refused.
    ///
    /// The attribution reads the runtime's documented step order — the signature is verified
    /// over the manifest bytes before any declared artifact is hashed — so a digest finding
    /// implies the signature already verified, and a manifest or tree-reading finding implies
    /// neither gate got a result. It decides nothing: the outcome is failing or missing
    /// either way, and the default is ``GateOutcome/notExecuted``, never a pass.
    private static func integrityRefused(
        _ bundle: ModelBundleID,
        finding: ModelBundleVerificationError
    ) -> ProducedBundleVerification {
        let signature: GateOutcome
        let digests: GateOutcome
        switch finding {
        case .signingKeyNotTrusted, .signingKeyGovernanceNotApproved, .signingKeyRevoked,
             .retiredSigningKeyRejectedByRotationRule, .retiredSigningKeyWindowNotEstablishable,
             .signingKeyMaterialUnavailable, .signingKeyMaterialDigestMismatch,
             .signatureAlgorithmUnsupported, .manifestSignatureDidNotVerify, .signatureEmpty,
             .signatureTooLarge:
            signature = .failed
            digests = .notExecuted
        case .undeclaredTreeEntry, .declaredArtifactMissing, .declaredArtifactKindMismatch,
             .emptyDirectoryTreeArtifact, .artifactByteCountMismatch,
             .artifactReadExceededDeclaredBound, .artifactDigestMismatch, .artifactUnreadable:
            // Reached only after the signature verified, so that gate has a passing result
            // and this one does not.
            signature = .passed
            digests = .failed
        default:
            // Tree enumeration, reserved files, manifest parsing, and the canonicalization
            // binding all refuse the candidate before either gate produces a result.
            signature = .notExecuted
            digests = .notExecuted
        }
        return ProducedBundleVerification(
            bundleID: bundle,
            releaseSignature: signature,
            perArtifactDigests: digests,
            compatibility: .notExecuted,
            finding: finding,
            verifiedManifestDigest: nil,
            verifiedArtifactDigests: [],
            signingKey: nil
        )
    }
}
