import DefAIkeDomain
import DefAIkeModelBundle

// The attribution and license notices a Model Bundle carries (Requirement 14.5).
//
// Requirement 14.5 requires the notices for the Lowq checkpoint and every bundled
// dependency to be *included* in each distributed application and Model Bundle. Two things
// follow, and they are the whole shape of this file:
//
//   * The notice **text** is an approved document. It is never written here, never
//     templated, and never summarized: a notice is staged content this build copies and
//     digests, and its approved source record travels with it. There is no placeholder body
//     and no code path that continues without one.
//   * The checkpoint notice is **structurally required**. It is a separate non-optional
//     field rather than an entry in a list that something then has to check for, so a
//     notice set with no Lowq attribution is not representable.
//
// What this file does not decide: whether the dependency list is *complete*. Which
// dependencies a build actually bundles is an archive and dependency audit, and that is
// task 14.6's Software Bill of Materials and forbidden-SDK work, not this one's. An audit
// reconciles the two; a set that lists three dependencies when the archive links four is a
// finding there, and nothing here can paper over it by inferring a fourth notice.

// MARK: - What one notice refers to

/// One approved notice document and where its text is staged.
///
/// The path is relative to the approved notice root, which is also where it lands in the
/// bundle: the staging area mirrors the bundle layout, so nothing relocates a notice.
public struct BundleNoticeReference: Hashable, Codable, Sendable {
    /// The immutable document this notice text was read from.
    public let source: EvidenceSource

    /// Path of the notice text, relative to the approved notice root.
    public let rootRelativePath: CanonicalRelativePath

    public init(source: EvidenceSource, rootRelativePath: CanonicalRelativePath) {
        self.source = source
        self.rootRelativePath = rootRelativePath
    }
}

/// The approved attribution and license notice for the Lowq checkpoint.
public struct ApprovedCheckpointNotice: Hashable, Codable, Sendable {
    /// The checkpoint this notice attributes. Exactly the required pixel model's.
    public let checkpoint: ModelCheckpointIdentifier

    public let notice: BundleNoticeReference

    /// Creates the checkpoint notice, refusing one for any other checkpoint.
    ///
    /// Requirement 14.5 names the Lowq checkpoint specifically, and Requirement 10.2 fixes
    /// which checkpoint a Version 1 bundle carries. A notice for a different checkpoint
    /// would be attribution for a model the bundle does not hold.
    public init(
        checkpoint: ModelCheckpointIdentifier,
        notice: BundleNoticeReference
    ) throws(BundleBuildError) {
        guard checkpoint == RequiredPixelModel.identity.checkpointIdentifier else {
            throw BundleBuildError.checkpointNoticeSubjectMismatch(checkpoint)
        }
        self.checkpoint = checkpoint
        self.notice = notice
    }

    private enum CodingKeys: String, CodingKey {
        case checkpoint, notice
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                checkpoint: container.decode(ModelCheckpointIdentifier.self, forKey: .checkpoint),
                notice: container.decode(BundleNoticeReference.self, forKey: .notice)
            )
        } catch let error as BundleBuildError {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: error.description,
                    underlyingError: error
                )
            )
        }
    }
}

/// The approved attribution and license notice for one bundled dependency.
public struct ApprovedDependencyNotice: Hashable, Codable, Sendable {
    /// The dependency this notice attributes.
    public let subject: ArtifactID

    public let notice: BundleNoticeReference

    public init(subject: ArtifactID, notice: BundleNoticeReference) {
        self.subject = subject
        self.notice = notice
    }
}

// MARK: - The approved set

/// Every notice a Model Bundle must carry, as one approved decision.
///
/// Construction is the completeness gate this record can enforce on its own: the set carries
/// an approval rather than merely existing, it names the required checkpoint, and it names
/// each dependency and each staged path once. Whether the dependency list matches the
/// archive is task 14.6's audit.
public struct ApprovedBundleNoticeSet: Hashable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// The Lowq checkpoint notice. Required, so its absence is unrepresentable.
    public let checkpointNotice: ApprovedCheckpointNotice

    /// One notice per bundled dependency, ordered by the UTF-8 bytes of the subject.
    ///
    /// Ordered here rather than by the caller, so two builds from the same approved set emit
    /// the same notice index bytes regardless of the order the entries were supplied in.
    public let dependencyNotices: [ApprovedDependencyNotice]

    /// The decision that approved this set. Presence is not approval.
    public let approval: ApprovalRecord

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        checkpointNotice: ApprovedCheckpointNotice,
        dependencyNotices: [ApprovedDependencyNotice],
        approval: ApprovalRecord
    ) throws(BundleBuildError) {
        guard approval.isApproved else {
            throw BundleBuildError.noticeSetNotApproved(id)
        }
        var seenSubjects = Set<String>()
        for entry in dependencyNotices {
            guard seenSubjects.insert(entry.subject.rawValue).inserted else {
                throw BundleBuildError.duplicateNoticeSubject(entry.subject)
            }
        }
        var seenPaths = Set<String>()
        for reference in [checkpointNotice.notice] + dependencyNotices.map(\.notice) {
            guard seenPaths.insert(reference.rootRelativePath.rawValue).inserted else {
                throw BundleBuildError.duplicateNoticePath(reference.rootRelativePath)
            }
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.checkpointNotice = checkpointNotice
        self.dependencyNotices = dependencyNotices.sorted {
            $0.subject.rawValue.utf8.lexicographicallyPrecedes($1.subject.rawValue.utf8)
        }
        self.approval = approval
    }

    /// Every notice reference in the set, checkpoint first then dependencies in order.
    public var allNotices: [BundleNoticeReference] {
        [checkpointNotice.notice] + dependencyNotices.map(\.notice)
    }
}

// MARK: - What the bundle carries

/// Which notice one index entry is for.
public enum BundleNoticeSubject: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The Lowq checkpoint (Requirement 14.5).
    case lowqCheckpoint(ModelCheckpointIdentifier)

    /// One bundled dependency.
    case dependency(ArtifactID)

    public var description: String {
        switch self {
        case let .lowqCheckpoint(checkpoint): "checkpoint \(checkpoint.rawValue)"
        case let .dependency(subject): "dependency \(subject.rawValue)"
        }
    }
}

/// One notice as the produced bundle records it.
///
/// Carries the measurement rather than the text: the text is in the bundle at `path`, and
/// this entry says which subject it attributes, which approved document it came from, and
/// what its bytes measure to — so an audit can tell an omitted or substituted notice from a
/// present one without reading the prose.
public struct IndexedBundleNotice: Hashable, Codable, Sendable {
    public let subject: BundleNoticeSubject

    /// The immutable document the text was read from.
    public let source: EvidenceSource

    /// Bundle-relative path of the notice text.
    public let path: CanonicalRelativePath

    public let byteCount: UInt64
    public let contentDigest: SHA256Digest

    public init(
        subject: BundleNoticeSubject,
        source: EvidenceSource,
        path: CanonicalRelativePath,
        byteCount: UInt64,
        contentDigest: SHA256Digest
    ) {
        self.subject = subject
        self.source = source
        self.path = path
        self.byteCount = byteCount
        self.contentDigest = contentDigest
    }
}

/// The notice index a produced bundle declares as an artifact.
///
/// Deliberately carries `approvalSource` — the immutable record that approved the notice set
/// — and not the decision itself. A bundle that restated its own approval would be carrying
/// a claim to have been approved; naming the record instead leaves the decision where it was
/// made and still lets an audit follow the reference.
public struct BundleNoticeIndex: Hashable, Codable, Sendable {
    /// The approved notice set this index was written from.
    public let id: ArtifactID

    public let schemaVersion: ArtifactSchemaVersion

    /// The directory the notice texts live under, relative to the bundle root.
    public let noticeRoot: CanonicalRelativePath

    /// Every notice, ordered by the UTF-8 bytes of its bundle-relative path.
    public let notices: [IndexedBundleNotice]

    /// The record that approved the notice set. A reference, never a decision.
    public let approvalSource: EvidenceSource

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        noticeRoot: CanonicalRelativePath,
        notices: [IndexedBundleNotice],
        approvalSource: EvidenceSource
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.noticeRoot = noticeRoot
        self.notices = notices.sorted {
            $0.path.rawValue.utf8.lexicographicallyPrecedes($1.path.rawValue.utf8)
        }
        self.approvalSource = approvalSource
    }
}
