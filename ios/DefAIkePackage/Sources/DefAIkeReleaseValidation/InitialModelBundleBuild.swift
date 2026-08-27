import DefAIkeDomain
import DefAIkeModelBundle

// What a build is asked for, and what it hands back.
//
// The request is entirely approved inputs. Nothing in it is a value this module chose, and
// the fields that could have been are deliberately absent: there is no signing key, no
// signature algorithm, no notice text, no component version this build invents, no schema
// version it assumes, and no canonicalization construction it picks. Six of the manifest's
// fields are *derived* rather than supplied, and each one is derived from an approved record
// rather than from a constant — see ``InitialModelBundleBuilder``.
//
// What a build hands back is an **unsigned** bundle: a complete, byte-exact description of
// the canonical artifact tree, the manifest bytes, the digest inventory, and a signing
// request. It is not a Model Bundle yet, and saying so is the point. A Model Bundle has a
// verifiable release signature over its manifest (Requirement 10.6), the signature is
// produced by an approved key under approved custody, and neither of those is reachable from
// here. So the build stops at the request, an external approved step signs, and
// ``BundleReleaseEvidenceRecorder`` reads the result back through the runtime's own
// verifiers.

// MARK: - Request

/// The approved inputs one Initial Model Bundle build is assembled from.
///
/// Every field is either an approved artifact, an approved decision, or an approved path.
/// The builder validates only what it needs in order to emit; it makes no fitness judgement,
/// because the runtime verifier makes all of those over the produced bundle.
public struct InitialModelBundleBuildRequest: Sendable {
    /// The bundle being built (Requirement 10.1).
    public let bundleID: ModelBundleID

    /// The schema version the manifest declares. An approved value: this build does not
    /// assume which schema revision a release publishes.
    public let manifestSchemaVersion: ArtifactSchemaVersion

    /// The validated policy join this release binds.
    ///
    /// The single source of four of the manifest's component versions, of the model input
    /// contract, and of the Bundle Verification Policy the signing request cites. Supplying
    /// them separately would let a bundle be built against one policy set and verified
    /// against another.
    public let configuration: ReleaseConfiguration

    /// The evidence scope this release states, whose version the bundle records
    /// (Requirement 10.7).
    public let evidenceScope: EvidenceScope

    /// The approved role-to-path binding. Also the staging layout: staged content is
    /// measured at the path it will occupy.
    public let layout: ApprovedBundleLayout

    /// The approved statement of which deterministic tree-digest construction the policy's
    /// canonicalization profile is.
    ///
    /// Read, never checked: whether this binding is approved and whether it matches the
    /// active policy are questions the runtime verifier answers over the produced bundle.
    /// Restating either here would be a second copy of a verification rule.
    public let canonicalization: ApprovedCanonicalizationProfile

    /// The approved compatibility record the manifest carries (Requirements 10.6 and 10.7).
    ///
    /// Which application builds, capabilities, and operating systems a bundle is compatible
    /// with is a release decision with no build-side counterpart, so it arrives whole.
    public let compatibility: CompatibilityMatrix

    /// The compiled model's output description (Requirement 4.9).
    ///
    /// A fact about the converted model, so it is supplied rather than derived. The manifest
    /// schema and the runtime verifier both constrain it.
    public let outputContract: ModelOutputContract

    /// The Core ML component version. The one component version with no build-side
    /// counterpart to derive it from, which is why compatibility verification checks the
    /// model by measuring its weight blob instead.
    public let coreMLModelVersion: ArtifactID

    /// The approved release self-test specification the bundle carries
    /// (Requirements 10.9 and 10.11).
    public let selfTestSpecification: ReleaseSelfTestSpecification

    /// The approved fixture catalogue the specification draws its cases from.
    public let fixtureCatalog: ReleaseFixtureSuite

    /// The approved attribution and license notices (Requirement 14.5).
    public let notices: ApprovedBundleNoticeSet

    /// Where the notice index is declared, relative to the bundle root.
    public let noticeIndexPath: CanonicalRelativePath

    /// The directory the notice texts live under, relative to the bundle root.
    public let noticeRoot: CanonicalRelativePath

    public init(
        bundleID: ModelBundleID,
        manifestSchemaVersion: ArtifactSchemaVersion,
        configuration: ReleaseConfiguration,
        evidenceScope: EvidenceScope,
        layout: ApprovedBundleLayout,
        canonicalization: ApprovedCanonicalizationProfile,
        compatibility: CompatibilityMatrix,
        outputContract: ModelOutputContract,
        coreMLModelVersion: ArtifactID,
        selfTestSpecification: ReleaseSelfTestSpecification,
        fixtureCatalog: ReleaseFixtureSuite,
        notices: ApprovedBundleNoticeSet,
        noticeIndexPath: CanonicalRelativePath,
        noticeRoot: CanonicalRelativePath
    ) {
        self.bundleID = bundleID
        self.manifestSchemaVersion = manifestSchemaVersion
        self.configuration = configuration
        self.evidenceScope = evidenceScope
        self.layout = layout
        self.canonicalization = canonicalization
        self.compatibility = compatibility
        self.outputContract = outputContract
        self.coreMLModelVersion = coreMLModelVersion
        self.selfTestSpecification = selfTestSpecification
        self.fixtureCatalog = fixtureCatalog
        self.notices = notices
        self.noticeIndexPath = noticeIndexPath
        self.noticeRoot = noticeRoot
    }
}

// MARK: - The canonical artifact tree

/// Where one planned entry's bytes come from.
///
/// Only three cases, and the absent fourth is the point: there is no `.rewritten`,
/// `.converted`, or `.generatedFromStaged` case. Content is either something the build
/// generated from approved records, something staged that it copies unchanged, or a
/// container directory.
public enum PlannedBundleContent: Hashable, Sendable {
    /// A container directory. Carries no bytes and no digest.
    case directory

    /// A file the build generated from approved records, with its exact bytes.
    case generatedFile(bytes: [UInt8])

    /// A staged directory tree, copied unchanged from the same canonical path.
    ///
    /// Its members are not enumerated here. They are covered by the tree digest the
    /// manifest declares, and the runtime verifier re-derives that digest from whatever the
    /// tree actually holds, so listing them would be a second inventory to keep in step.
    case stagedDirectoryTree
}

/// One entry of the canonical artifact tree a build describes.
public struct PlannedBundleEntry: Hashable, Sendable {
    /// Path relative to the bundle root.
    public let path: CanonicalRelativePath

    public let content: PlannedBundleContent

    /// What the entry's bytes measure to, or `nil` for a container directory.
    public let measurement: BundleArtifactMeasurement?

    /// Whether the manifest declares this entry as an artifact.
    ///
    /// False for container directories and for the manifest itself: the manifest is a
    /// reserved root file, and a manifest that declared itself would have to contain its own
    /// digest.
    public let isDeclaredArtifact: Bool

    init(
        path: CanonicalRelativePath,
        content: PlannedBundleContent,
        measurement: BundleArtifactMeasurement?,
        isDeclaredArtifact: Bool
    ) {
        self.path = path
        self.content = content
        self.measurement = measurement
        self.isDeclaredArtifact = isDeclaredArtifact
    }
}

/// The complete canonical artifact tree of one produced bundle.
///
/// Byte-exact and fully ordered, so two builds from the same approved inputs are comparable
/// as values rather than by inspection. It describes the tree; it does not write it. Writing
/// is an approved release step, for the same reason signing is, and this module holds no
/// member that could.
public struct CanonicalBundleTreePlan: Hashable, Sendable {
    /// Every entry, ordered by the UTF-8 bytes of its path.
    public let entries: [PlannedBundleEntry]

    init(entries: [PlannedBundleEntry]) {
        self.entries = entries.sorted {
            $0.path.rawValue.utf8.lexicographicallyPrecedes($1.path.rawValue.utf8)
        }
    }

    /// The planned entry at one path, or `nil` when the plan has none.
    public func entry(at path: CanonicalRelativePath) -> PlannedBundleEntry? {
        entries.first { $0.path == path }
    }

    /// Every entry the manifest declares as an artifact, in path order.
    public var declaredArtifacts: [PlannedBundleEntry] {
        entries.filter(\.isDeclaredArtifact)
    }
}

// MARK: - The signing request

/// What an approved signing step is asked to produce.
///
/// A request, and nothing more. It carries no key material, no signature, no approval
/// decision, and no outcome, and nothing in this module can satisfy it: there is no member
/// anywhere in `DefAIkeReleaseValidation` that signs, that reaches a key store, or that
/// records a governance decision.
///
/// The two fields that look like choices are not. `designatedKey` is the identity the
/// approved key-governance record named, read through
/// ``ReleaseKeyGovernanceReading/designatedSigningKey(forBundle:)`` from a seam that offers
/// nothing to choose among. `algorithm` is
/// ``BundleVerificationPolicy/algorithm`` read from the policy the build binds — the same
/// field the runtime verifier reads when it checks the resulting signature, so the two
/// cannot disagree.
public struct BundleSigningRequest: Hashable, Sendable {
    public let bundleID: ModelBundleID

    /// The exact bytes the detached signature must cover: the manifest, unchanged
    /// (Requirement 10.6).
    public let message: [UInt8]

    /// Digest of those bytes, so a signing step can confirm it signed the manifest this
    /// build produced rather than a manifest it was handed separately.
    public let messageDigest: SHA256Digest

    /// Where the detached signature belongs in the bundle.
    public let signaturePath: CanonicalRelativePath

    /// The key the approved key-governance record designates. Named, never chosen.
    public let designatedKey: SigningKeyID

    /// The algorithm the active Bundle Verification Policy names. Read, never chosen.
    public let algorithm: SignatureAlgorithm

    /// The immutable record that designated the key. A reference, never a decision.
    public let keyGovernanceSource: EvidenceSource

    /// The Bundle Verification Policy version the algorithm was read from.
    public let verificationPolicy: ArtifactID

    init(
        bundleID: ModelBundleID,
        message: [UInt8],
        messageDigest: SHA256Digest,
        signaturePath: CanonicalRelativePath,
        designatedKey: SigningKeyID,
        algorithm: SignatureAlgorithm,
        keyGovernanceSource: EvidenceSource,
        verificationPolicy: ArtifactID
    ) {
        self.bundleID = bundleID
        self.message = message
        self.messageDigest = messageDigest
        self.signaturePath = signaturePath
        self.designatedKey = designatedKey
        self.algorithm = algorithm
        self.keyGovernanceSource = keyGovernanceSource
        self.verificationPolicy = verificationPolicy
    }
}

// MARK: - What a build produces

/// One reproducibly built, not-yet-signed Initial Model Bundle.
///
/// Constructible only inside this module, and only by a build that reached the end without a
/// finding, so "these bytes are what the approved inputs determine" is carried by the type
/// rather than asserted next to it.
///
/// What it does **not** claim: that the bundle verifies. It has no signature yet, so it
/// cannot; and once signed, whether it verifies is answered by `DefAIkeModelBundle`'s own
/// verifiers and by nothing here (Requirement 10.8).
public struct UnsignedInitialModelBundle: Hashable, Sendable {
    public let bundleID: ModelBundleID

    /// The canonical artifact tree, byte-exact.
    public let tree: CanonicalBundleTreePlan

    /// The manifest as a value, for an audit that wants to read a field rather than bytes.
    public let manifest: ModelBundleManifest

    /// The exact manifest bytes. What the signature covers and what a runtime parse reads.
    public let manifestBytes: [UInt8]

    /// Every declared artifact's identity, kind, byte count, and digest, ordered by the
    /// UTF-8 bytes of the canonical path (Requirement 10.5).
    ///
    /// The same ordering ``VerifiedBundleArtifactTree/verifiedArtifacts`` uses, so a
    /// tool-produced inventory and a runtime-verified inventory are directly comparable.
    public let digestInventory: [ArtifactDigestRecord]

    /// The notice index this bundle carries (Requirement 14.5).
    public let noticeIndex: BundleNoticeIndex

    /// What an approved signing step is asked to produce.
    public let signingRequest: BundleSigningRequest

    init(
        bundleID: ModelBundleID,
        tree: CanonicalBundleTreePlan,
        manifest: ModelBundleManifest,
        manifestBytes: [UInt8],
        digestInventory: [ArtifactDigestRecord],
        noticeIndex: BundleNoticeIndex,
        signingRequest: BundleSigningRequest
    ) {
        self.bundleID = bundleID
        self.tree = tree
        self.manifest = manifest
        self.manifestBytes = manifestBytes
        self.digestInventory = digestInventory
        self.noticeIndex = noticeIndex
        self.signingRequest = signingRequest
    }

    /// Digest of the manifest bytes, as the signing request records it.
    public var manifestDigest: SHA256Digest { signingRequest.messageDigest }
}
