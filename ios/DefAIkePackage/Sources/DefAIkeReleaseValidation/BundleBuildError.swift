import DefAIkeDomain
import DefAIkeModelBundle

// Why an Initial Model Bundle could not be produced.
//
// Deliberately narrow, and the narrowness is the design. `ModelBundleVerificationError`
// already says why a bundle is *unacceptable*, and that vocabulary is not restated here:
// a second copy of any verification rule would let this module bless something the runtime
// refuses, or refuse something the runtime accepts, and either way the tool would stop
// being a statement about what the app will do.
//
// So every case below says one thing only: **the builder could not emit**. Content it was
// told to include is not staged; two artifacts would land on one path; a value it must
// record is not encodable; the approved key-governance record designates nothing, or
// designates under a rejection. None of them is a judgement about a bundle's fitness, and
// there is no case that could be resolved by inventing a value.
//
// Two rules shape the set:
//
//   * No case means "emitted with a warning". A build either produces an
//     ``UnsignedInitialModelBundle`` or produces one of these findings.
//   * No case can be resolved by generating something. There is no "notice text absent,
//     will be written on first run" and no "digest unavailable, will be filled in later":
//     the alternative to staged approved content is a finding.

/// Why an Initial Model Bundle build did not produce an artifact tree.
public enum BundleBuildError: Error, Equatable, Sendable, CustomStringConvertible {
    // MARK: Approved notices (Requirement 14.5)

    /// The notice set carries a rejection rather than an approval. Presence is not approval.
    case noticeSetNotApproved(ArtifactID)

    /// The checkpoint notice names a checkpoint other than the sole permitted pixel model,
    /// so the release would ship attribution for a model it does not carry
    /// (Requirements 10.2 and 14.5).
    case checkpointNoticeSubjectMismatch(ModelCheckpointIdentifier)

    /// Two dependency notices name the same subject, so "the notice for this dependency" is
    /// ambiguous.
    case duplicateNoticeSubject(ArtifactID)

    /// Two notices are staged at the same path inside the notice root, so one would
    /// overwrite the other.
    case duplicateNoticePath(CanonicalRelativePath)

    /// A notice's root-relative path does not place it inside the approved notice root as a
    /// canonical path.
    case noticePathNotResolvable(CanonicalRelativePath)

    // MARK: Approved paths

    /// An approved path names a reserved bundle root file. The manifest and its signature
    /// are not declarable artifacts.
    case pathIsReservedBundleFile(CanonicalRelativePath)

    /// Two artifacts this build must emit resolve to the same path.
    case duplicateArtifactPath(CanonicalRelativePath)

    /// One artifact path lies inside another, so the same bytes would carry two digest
    /// records. Refused here rather than left to the runtime so the finding names the
    /// approved input that caused it.
    case overlappingArtifactPaths(outer: CanonicalRelativePath, inner: CanonicalRelativePath)

    // MARK: Measuring staged content

    /// Staged content a declared artifact needs could not be measured.
    ///
    /// Carries the role and the structural fault, so absent content, unreadable content, a
    /// wrong entry kind, a symbolic link, and an unimplemented canonicalization
    /// construction stay distinguishable in a build log.
    case stagedArtifactNotMeasurable(
        role: BundleBuildArtifactRole,
        path: CanonicalRelativePath,
        fault: BundleMeasurementFault
    )

    // MARK: Encoding

    /// A value this build must record could not be encoded to canonical bytes.
    case artifactNotEncodable(role: BundleBuildArtifactRole, fault: CanonicalEncodingFault)

    /// The manifest this build assembled violates the signed-artifact schema.
    ///
    /// The domain's validating initializer is the one that refuses it, so a build cannot
    /// emit a manifest a runtime parse would then reject for schema reasons.
    case manifestRejectedBySchema(ArtifactSchemaError)

    // MARK: Approved key governance

    /// The approved record designates no signing key for this bundle, and a build does not
    /// pick one.
    case noDesignatedSigningKey(ModelBundleID)

    /// The approved key-governance record is unavailable, so no signing request can name a
    /// designated key.
    case keyGovernanceRecordUnavailable(ModelBundleID)

    /// The record designating the signing key carries a rejection rather than an approval.
    case designatedSigningKeyNotApproved(SigningKeyID)

    public var description: String {
        switch self {
        case let .noticeSetNotApproved(notices):
            return "the bundle notice set \(notices.rawValue) is not approved"
        case let .checkpointNoticeSubjectMismatch(checkpoint):
            return """
                the checkpoint notice names \(checkpoint.rawValue); the sole permitted pixel \
                model is \(RequiredPixelModel.checkpointIdentifier)
                """
        case let .duplicateNoticeSubject(subject):
            return "the notice set names dependency \(subject.rawValue) more than once"
        case let .duplicateNoticePath(path):
            return "two notices are staged at \"\(path.rawValue)\""
        case let .noticePathNotResolvable(path):
            return """
                notice path \"\(path.rawValue)\" cannot be placed under the approved notice \
                root as a canonical path
                """
        case let .pathIsReservedBundleFile(path):
            return "\"\(path.rawValue)\" is a reserved bundle root file and cannot be declared"
        case let .duplicateArtifactPath(path):
            return "two artifacts of this build resolve to \"\(path.rawValue)\""
        case let .overlappingArtifactPaths(outer, inner):
            return """
                artifact \"\(inner.rawValue)\" lies inside artifact \"\(outer.rawValue)\"; the \
                same bytes cannot carry two digest records
                """
        case let .stagedArtifactNotMeasurable(role, path, fault):
            return """
                the \(role) staged at \"\(path.rawValue)\" could not be measured: \
                \(Self.text(for: fault))
                """
        case let .artifactNotEncodable(role, fault):
            return "the \(role) could not be encoded canonically: \(Self.text(for: fault))"
        case let .manifestRejectedBySchema(error):
            return "the assembled manifest violates its schema: \(error.description)"
        case let .noDesignatedSigningKey(bundle):
            return """
                the approved key-governance record designates no signing key for bundle \
                \(bundle.rawValue)
                """
        case let .keyGovernanceRecordUnavailable(bundle):
            return """
                the approved key-governance record for bundle \(bundle.rawValue) is \
                unavailable
                """
        case let .designatedSigningKeyNotApproved(key):
            return "the record designating signing key \(key.rawValue) is not an approval"
        }
    }

    private static func text(for fault: BundleMeasurementFault) -> String {
        switch fault {
        case .artifactMissing: "nothing is staged there"
        case .artifactUnreadable: "its bytes could not be read"
        case .notAFile: "it is not a regular file"
        case .notADirectoryTree: "it is not a directory tree"
        case .symbolicLinkPresent: "it holds a symbolic link"
        case .constructionUnsupported: "the approved tree-digest construction is not implemented"
        case .storeUnavailable: "the staging area is unavailable"
        }
    }

    private static func text(for fault: CanonicalEncodingFault) -> String {
        switch fault {
        case .notEncodable: "the value could not be encoded to JSON"
        case let .notWellFormed(offset): "the encoded bytes are malformed at byte \(offset)"
        case let .tooDeep(maximum): "the encoded value nests deeper than \(maximum) levels"
        }
    }
}

/// Which artifact of a build one finding is about.
///
/// Named rather than described so a build finding cites the artifact an operator can go and
/// look at. Wider than ``BundleArtifactRole``, which covers only the five roles bundle
/// *verification* resolves: a build also emits the manifest, the notice index, and the
/// notice tree, and a finding about one of those has to be able to say so.
public enum BundleBuildArtifactRole: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    case manifest
    case compiledModel = "compiled-model"
    case selfTestSpecification = "self-test-specification"
    case fixtureCatalog = "fixture-catalog"
    case fixtureRoot = "fixture-root"
    case noticeIndex = "notice-index"
    case noticeRoot = "notice-root"
    case noticeText = "notice-text"

    public var description: String { rawValue }
}
