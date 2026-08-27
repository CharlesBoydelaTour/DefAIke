import DefAIkeDomain
import DefAIkeModelBundle

// The two things Initial Model Bundle creation reaches out for, and nothing else.
//
// Building a bundle is otherwise a pure function of approved inputs: the validated
// ``ReleaseConfiguration`` a build binds, the approved layout, the approved compatibility
// record, the approved self-test specification and fixture catalogue, and the approved
// notice set. Two things are deliberately not in that list, and both arrive through a seam
// with no default implementation:
//
//   * **Measurement.** The deterministic directory-tree digest is a Bundle Verification
//     Policy rule, named by ``ApprovedCanonicalizationProfile`` and implemented once — in
//     `DefAIkeModelBundle`, for verification. A second implementation here would be a
//     second authority on what a signed digest means, and the two would drift. So this
//     module computes no digest at all. It is told what the bytes measure to, and the
//     runtime verifier is the only arbiter of whether that measurement was right: a
//     mistaken seam produces a bundle the runtime refuses, which is exactly the
//     fail-closed direction.
//   * **Key governance.** Which key signs a release is an approved decision with an
//     approval record behind it. This module is handed the designated key's *identity* and
//     that record. It cannot enumerate keys, cannot rank them, cannot reach key material,
//     and cannot sign.
//
// Deliberately absent from both seams: any member that writes, any member that returns
// private key material, any member that produces a signature, and any member that records
// an approval. ``InitialModelBundleBuilder`` emits a signing *request*; nothing in this
// module can satisfy one.

// MARK: - Measuring staged and generated artifacts

/// What one artifact's bytes measure to.
///
/// The pair a manifest declares per artifact, and the pair the runtime verifier
/// independently measures when it reads the produced bundle.
public struct BundleArtifactMeasurement: Hashable, Sendable {
    public let byteCount: UInt64
    public let digest: SHA256Digest

    public init(byteCount: UInt64, digest: SHA256Digest) {
        self.byteCount = byteCount
        self.digest = digest
    }
}

/// Why a staged artifact could not be measured.
///
/// Structural outcomes only, with no framework error and no absolute path. Which build
/// finding each becomes depends on the role that was being measured, so the mapping belongs
/// to the builder rather than to the seam.
public enum BundleMeasurementFault: Error, Equatable, Sendable {
    /// Nothing is staged at that path.
    case artifactMissing
    /// The path is staged but its bytes could not be read.
    case artifactUnreadable
    /// A file was expected and something else is staged there.
    case notAFile
    /// A directory tree was expected and something else is staged there.
    case notADirectoryTree
    /// The staged tree holds a symbolic link, which a verified artifact tree cannot.
    case symbolicLinkPresent
    /// The seam does not implement the tree-digest construction it was asked for.
    ///
    /// Separate from every other fault so a build that cannot execute the approved
    /// canonicalization rule fails with that finding rather than looking like missing
    /// content — and so it can never look like a successful measurement.
    case constructionUnsupported
    /// The staging area itself is unavailable.
    case storeUnavailable
}

/// Measures staged bundle content under the approved canonicalization construction.
///
/// The staging area mirrors the bundle layout: a staged artifact is measured at the same
/// canonical path it will occupy in the produced bundle. Nothing here relocates, renames,
/// or rewrites content, and nothing here chooses a construction — the construction is
/// passed in, taken from the approved binding the build was given.
///
/// Deliberately absent: any member that creates, writes, moves, or deletes anything; any
/// member that resolves a symbolic link rather than refusing it; and any member that
/// reports a digest for content it did not read.
public protocol BundleArtifactMeasuring: Sendable {
    /// Measures one staged file.
    func measureStagedFile(
        at path: CanonicalRelativePath
    ) throws(BundleMeasurementFault) -> BundleArtifactMeasurement

    /// Measures one staged directory tree under `construction`.
    ///
    /// An implementation that does not implement `construction` returns
    /// ``BundleMeasurementFault/constructionUnsupported``. It must never substitute
    /// another construction.
    func measureStagedDirectoryTree(
        at path: CanonicalRelativePath,
        construction: BundleTreeDigestConstruction
    ) throws(BundleMeasurementFault) -> BundleArtifactMeasurement

    /// Measures bytes the builder generated and will place in the bundle.
    ///
    /// Non-failing: the bytes are in hand, so there is nothing to be unavailable. Kept on
    /// the same seam as the staged measurements so this module has exactly one place a
    /// digest can come from.
    func measureGeneratedFile(_ bytes: [UInt8]) -> BundleArtifactMeasurement
}

// MARK: - Reading the approved key-governance decision

/// The release signing key an approved key-governance record designates.
///
/// Carries the identity and the decision, and nothing else. No key material, no algorithm,
/// no signature: the algorithm is the active Bundle Verification Policy's
/// ``BundleVerificationPolicy/algorithm`` and is read from there, and signing happens
/// outside this module entirely.
///
/// Presence is not approval, so the record travels with the identity and a build refuses a
/// designation whose decision is a rejection.
public struct DesignatedReleaseSigningKey: Hashable, Sendable {
    /// The key the governance record designates for this bundle.
    public let key: SigningKeyID

    /// The key-governance decision that designated it.
    public let governance: ApprovalRecord

    public init(key: SigningKeyID, governance: ApprovalRecord) {
        self.key = key
        self.governance = governance
    }
}

/// Why the approved key-governance record could not be read.
public enum KeyGovernanceFault: Error, Equatable, Sendable {
    /// The record designates no signing key for that bundle. A build cannot pick one.
    case noDesignatedKey
    /// The record itself is unavailable.
    case recordUnavailable
}

/// Reports the signing key an approved key-governance record designates.
///
/// One member, returning one key. That shape is the point: there is no `trustedKeys`, no
/// `availableKeys`, and no `preferredKey`, so a build has nothing to choose among and no
/// way to prefer one key over another. Whether the designated key is *trusted* is a Bundle
/// Verification Policy question the runtime verifier answers over the produced bundle;
/// this seam answers only "which key did governance designate".
///
/// Deliberately absent: any member returning public or private key material, any member
/// that signs or requests a signature, any member that lists or ranks keys, and any member
/// that records, mints, or amends an approval.
public protocol ReleaseKeyGovernanceReading: Sendable {
    /// The key the approved record designates for one bundle.
    func designatedSigningKey(
        forBundle bundle: ModelBundleID
    ) throws(KeyGovernanceFault) -> DesignatedReleaseSigningKey
}
