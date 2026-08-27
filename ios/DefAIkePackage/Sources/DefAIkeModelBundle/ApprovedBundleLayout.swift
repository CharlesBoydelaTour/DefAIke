import DefAIkeDomain

// Which declared artifact plays which release role.
//
// A signed manifest declares a canonical path, a kind, a byte count, and a digest for
// every artifact (Requirement 10.5). It deliberately does not say which of those
// artifacts *is* the compiled Core ML model, which file inside it holds the weights the
// model identity pins, or which artifact carries the release self-test specification and
// its fixture catalogue. Steps 4 and 5 of the verification order need all four, and a
// path spelled into this file — `artifacts/model.mlmodelc`, say — would be exactly the
// compiled-in release value this module is not allowed to hold.
//
// So the role-to-path correspondence arrives as an approved release input, in the same
// shape and for the same reason as ``ApprovedCanonicalizationProfile``: a build that has
// not been told which artifact is the model cannot verify a candidate, instead of
// verifying against a layout this module guessed.

/// A release role one declared bundle artifact plays.
///
/// Closed on purpose. A finding names the role rather than the path when the path is a
/// build-supplied value, so an audit reads "the compiled model is not a directory tree"
/// instead of a bare string.
public enum BundleArtifactRole: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    /// The compiled Core ML model directory.
    case compiledModel = "compiled-model"

    /// The weight blob inside the compiled model, whose digest the model identity pins.
    case modelWeightBlob = "model-weight-blob"

    /// The release self-test specification (Requirement 10.9).
    case selfTestSpecification = "self-test-specification"

    /// The fixture catalogue the self-test specification draws its cases from.
    case fixtureCatalog = "fixture-catalog"

    /// The directory the catalogued fixture assets live under.
    case fixtureRoot = "fixture-root"

    /// The artifact kind this role requires.
    public var requiredKind: ArtifactDigestRecord.Kind {
        switch self {
        case .compiledModel, .fixtureRoot: .directoryTree
        case .selfTestSpecification, .fixtureCatalog: .file
        // Not a declared artifact in its own right: a member of the compiled model
        // tree, whose bytes the tree digest already pins.
        case .modelWeightBlob: .file
        }
    }

    /// Whether the manifest declares an artifact for this role directly.
    ///
    /// The weight blob is the one role that is not separately declared. Its bytes are
    /// covered by the compiled model's tree digest, so declaring it again would make the
    /// same bytes carry two digest records — which manifest parsing already refuses.
    public var isSeparatelyDeclared: Bool { self != .modelWeightBlob }

    public var description: String { rawValue }
}

/// The approved statement binding each release role to a canonical path in the bundle.
///
/// Presence is not approval: the record carries the decision that authorized it, and
/// verification refuses a layout whose decision is a rejection.
public struct ApprovedBundleLayout: Hashable, Sendable {
    /// The immutable record this layout was read from.
    public let source: EvidenceSource

    /// The compiled Core ML model directory, relative to the bundle root.
    public let compiledModel: CanonicalRelativePath

    /// The weight blob, relative to the bundle root. Strictly inside ``compiledModel``.
    public let modelWeightBlob: CanonicalRelativePath

    /// The release self-test specification file.
    public let selfTestSpecification: CanonicalRelativePath

    /// The fixture catalogue file.
    public let fixtureCatalog: CanonicalRelativePath

    /// The directory the catalogue's asset paths are relative to.
    public let fixtureRoot: CanonicalRelativePath

    /// The decision that recorded this correspondence.
    public let approval: ApprovalRecord

    /// Creates a layout, or `nil` when the paths cannot describe one bundle.
    ///
    /// Rejects a layout that names a reserved root file, that repeats a path across two
    /// roles, that puts the weight blob outside the compiled model, or in which two
    /// separately declared roles contain one another. Manifest parsing already refuses
    /// overlapping declared artifacts, so a layout that assumes containment could never
    /// resolve against a valid manifest; catching it here names the layout as the cause.
    public init?(
        source: EvidenceSource,
        compiledModel: CanonicalRelativePath,
        modelWeightBlob: CanonicalRelativePath,
        selfTestSpecification: CanonicalRelativePath,
        fixtureCatalog: CanonicalRelativePath,
        fixtureRoot: CanonicalRelativePath,
        approval: ApprovalRecord
    ) {
        let all = [
            compiledModel, modelWeightBlob, selfTestSpecification, fixtureCatalog, fixtureRoot,
        ]
        guard Set(all.map(\.rawValue)).count == all.count else { return nil }
        guard all.allSatisfy({ !ReservedBundleFile.names.contains($0.rawValue) }) else {
            return nil
        }
        guard Self.contains(compiledModel, modelWeightBlob) else { return nil }

        // Every separately declared role has to be disjoint from every other one, in
        // both directions.
        let declared = [compiledModel, selfTestSpecification, fixtureCatalog, fixtureRoot]
        for outer in declared {
            for inner in declared where inner != outer {
                guard !Self.contains(outer, inner) else { return nil }
            }
        }

        self.source = source
        self.compiledModel = compiledModel
        self.modelWeightBlob = modelWeightBlob
        self.selfTestSpecification = selfTestSpecification
        self.fixtureCatalog = fixtureCatalog
        self.fixtureRoot = fixtureRoot
        self.approval = approval
    }

    /// The path this layout assigns to one role.
    public func path(for role: BundleArtifactRole) -> CanonicalRelativePath {
        switch role {
        case .compiledModel: compiledModel
        case .modelWeightBlob: modelWeightBlob
        case .selfTestSpecification: selfTestSpecification
        case .fixtureCatalog: fixtureCatalog
        case .fixtureRoot: fixtureRoot
        }
    }

    /// Roles the manifest must declare as artifacts, in a stable order.
    public static var separatelyDeclaredRoles: [BundleArtifactRole] {
        BundleArtifactRole.allCases.filter(\.isSeparatelyDeclared)
    }

    /// The bundle-relative path of one catalogued fixture asset, or `nil` when the
    /// catalogue's suite-relative path cannot be placed under the fixture root.
    ///
    /// Returns `nil` rather than a joined string when the result is not canonical, so a
    /// catalogue cannot reach outside the fixture tree by way of a path this module
    /// assembled.
    public func fixtureAssetPath(
        suiteRelative path: CanonicalRelativePath
    ) -> CanonicalRelativePath? {
        CanonicalRelativePath("\(fixtureRoot.rawValue)/\(path.rawValue)")
    }

    /// Whether `inner` lies strictly inside the directory `outer`.
    private static func contains(
        _ outer: CanonicalRelativePath,
        _ inner: CanonicalRelativePath
    ) -> Bool {
        inner.rawValue.hasPrefix(outer.rawValue + "/")
    }
}
