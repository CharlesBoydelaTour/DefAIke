import DefAIkeDomain

// The limitations every completed report states, and the notice that keeps a
// contradiction visible.
//
// Requirement 8.10 requires every Evidence Report to include the Whole Image Synthesis
// scope and the listed unsupported scopes. Requirement 8.11 requires every report to
// state that false-positive and false-negative results can occur. Requirement 6.15
// requires the transformed-or-unknown byte-status limitation whenever the analyzed
// bytes are a platform-transformed copy or of unknown preservation history, and
// Requirement 8.12 requires the Byte Preservation Status itself to be exposed.
//
// "Every report" is the operative phrase, so none of these is optional here. Each is a
// non-optional stored property resolved at assembly time, which means a report cannot
// be built without them and a view cannot render one that lacks them. There is no
// `showLimitations` flag, no collapsed default, and no code path that skips a
// limitation for a particular label, state, or byte status.
//
// The structured evidence scope travels alongside the approved scope statement rather
// than instead of it. The statement is what a user reads; the structured value is what
// an audit reads, and the domain refuses to build one that omits a required covered or
// uncovered scope, so "the report states the whole scope" is checked before the report
// exists rather than by inspecting English.

/// The Byte Preservation Status and its approved limitation.
///
/// Both members are non-optional. Requirement 6.15 names the transformed and unknown
/// statuses specifically, and the approved surface exists for all three statuses, so
/// the limitation is resolved for whichever status was recorded. Attaching it
/// unconditionally is the structural form of the requirement: there is no status for
/// which the limitation could be dropped, because there is no code path that drops it.
///
/// Neither member can be upgraded. The status is the domain's own recorded value, and
/// this type has no initializer that takes a different one.
public struct BytePreservationDisclosure: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The preservation status recorded for the analyzed bytes (Requirement 8.12).
    public let status: BytePreservationStatus

    /// Approved copy stating what this status means for the evidence
    /// (Requirement 6.15).
    public let limitationCopy: ResolvedCopyReference

    /// Whether this status is one of the two Requirement 6.15 names explicitly.
    ///
    /// Reported rather than acted on: the limitation is attached either way, and this
    /// only lets an audit confirm that the two named statuses are covered.
    public var isNamedByTransformedOrUnknownRequirement: Bool {
        switch status {
        case .platformTransformedCopy, .unknown: true
        case .originalBytes: false
        }
    }

    init(status: BytePreservationStatus, limitationCopy: ResolvedCopyReference) {
        self.status = status
        self.limitationCopy = limitationCopy
    }
}

/// The apparent-inconsistency notice, answered for every report.
///
/// An enum rather than an optional, so "the report declared no contradiction" is a
/// stated answer instead of an absent value that a `??` could fill or a `guard` could
/// skip past. Requirement 7.8 keeps both source-lane results and identifies the
/// apparent inconsistency without suppressing, overriding, or ranking either lane;
/// keeping the notice here, beside the card pair, rather than inside one card is what
/// stops the identification from becoming a property of a single lane.
public enum ApparentInconsistencyNotice: Hashable, Sendable {
    /// The report declared no apparent inconsistency.
    ///
    /// Also the only reachable value when the provenance lane is unavailable: with no
    /// provenance evidence there is nothing for the pixel lane to be inconsistent with,
    /// and the domain refuses to build such a report at all.
    case none

    /// The report declared one, and this is the approved explanatory copy for it.
    case declared(ResolvedCopyReference)

    /// The approved reference, or `nil` when no notice was declared.
    ///
    /// A convenience for a view that renders a section conditionally. It is not a way
    /// to lose a declared notice: the case is what assembly recorded, and assembly maps
    /// the report's own declaration one-to-one.
    public var reference: ResolvedCopyReference? {
        switch self {
        case .none: nil
        case let .declared(reference): reference
        }
    }
}

/// The limitations stated in every completed Evidence Report.
///
/// Four non-optional members. There is no representable report that omits the scope,
/// the false-result statement, or the byte-status limitation.
public struct EvidenceLimitations: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The structured scope the session was bound to.
    ///
    /// The domain rejects a scope missing any required covered or uncovered statement,
    /// so this value cannot understate the limits (Requirement 8.10).
    public let scope: EvidenceScope

    /// Approved copy stating the evidence scope and the unsupported scopes
    /// (Requirement 8.10).
    public let scopeCopy: ResolvedCopyReference

    /// Approved copy stating that false-positive and false-negative results can occur
    /// (Requirement 8.11).
    public let falseResultCopy: ResolvedCopyReference

    /// The byte-status disclosure and its limitation (Requirements 6.15 and 8.12).
    public let bytePreservation: BytePreservationDisclosure

    /// The scopes this evidence covers, in the domain's declaration order.
    ///
    /// Ordered by the closed statement vocabulary rather than by anything derived from
    /// English, so the order is stable under localization and a view cannot reorder or
    /// drop a statement by sorting.
    public var coveredScopes: [AnalysisScopeStatement] {
        AnalysisScopeStatement.allCases.filter(scope.includedStatements.contains)
    }

    /// The scopes this evidence does not cover, in the domain's declaration order.
    public var uncoveredScopes: [AnalysisScopeStatement] {
        AnalysisScopeStatement.allCases.filter(scope.excludedStatements.contains)
    }

    /// Whether every scope statement Requirement 8.10 requires is stated.
    ///
    /// Always true for a constructible value, because the domain enforces it. Exposed
    /// so a release audit can assert it over a real report rather than trusting that
    /// the domain check ran.
    public var statesEveryRequiredScope: Bool {
        EvidenceScope.requiredIncludedStatements.isSubset(of: scope.includedStatements)
            && EvidenceScope.requiredExcludedStatements.isSubset(of: scope.excludedStatements)
    }

    init(
        scope: EvidenceScope,
        scopeCopy: ResolvedCopyReference,
        falseResultCopy: ResolvedCopyReference,
        bytePreservation: BytePreservationDisclosure
    ) {
        self.scope = scope
        self.scopeCopy = scopeCopy
        self.falseResultCopy = falseResultCopy
        self.bytePreservation = bytePreservation
    }
}

// MARK: - Assembly

extension EvidenceLimitations {
    /// Resolves every limitation for one report.
    ///
    /// No branch. Each of the three approved surfaces is resolved unconditionally, so
    /// there is no condition under which a limitation is skipped; a surface the bound
    /// catalogue does not cover is a fail-closed error rather than a quiet omission.
    static func assembling(
        scope: EvidenceScope,
        bytePreservationStatus: BytePreservationStatus,
        copy: ApprovedCopyBinding
    ) throws(PresentationCopyError) -> EvidenceLimitations {
        EvidenceLimitations(
            scope: scope,
            scopeCopy: try copy.reference(for: .evidenceScope),
            falseResultCopy: try copy.reference(for: .falseResultLimitation),
            bytePreservation: BytePreservationDisclosure(
                status: bytePreservationStatus,
                limitationCopy: try copy.reference(
                    for: .bytePreservationLimitation(bytePreservationStatus.statusKey)
                )
            )
        )
    }
}
