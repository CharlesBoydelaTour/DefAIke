import DefAIkeDomain

// The immutable join of the two evidence source lanes.
//
// Requirements 7.1, 7.4, and 7.5 describe one structure from three directions: the
// report carries distinct immutable lane fields, the provenance analyzer produces its
// state without changing the raw logit, execution status, or Pixel Evidence, and the
// pixel analyzer produces its logit and status without changing the provenance state.
// Requirement 7.13 keeps both fields even when a Combined Summary exists.
//
// None of that is a convention here. The join is a value type whose stored properties
// are all `let`, so:
//
//   * an analyzer cannot be handed mutable access to a lane, because there is no
//     reference to hand out and no mutating member to call. The coordinator owns the
//     join; an analyzer's entire contribution is one value of its own lane's type,
//     returned from a port that cannot see the other lane at all
//     (`ProvenanceAnalyzing.analyze` takes an asset and a policy;
//     `PixelCalibrating.classify` takes a logit, a quality record, and a policy);
//   * each writer names exactly one lane, so a call that resolves provenance has no
//     parameter through which Pixel Evidence could arrive, and vice versa; and
//   * recording a lane returns a *new* join. The earlier value still exists and is
//     unchanged, which is what makes noninterference observable in a test rather than
//     asserted in a comment.
//
// Each lane resolves exactly once. A second write for an already-resolved lane is
// refused rather than applied, so a duplicate or late callback cannot overwrite a lane
// that already holds a result — the one remaining path by which one branch could have
// changed the other's answer.
//
// Both lanes are required. A pixel-only composition still resolves its provenance lane:
// `ProvenanceLaneProvider` returns `.unavailable(reason)` without invoking anything, so
// "provenance is unavailable" is a resolved lane rather than a missing one. That is why
// ``ResolvedEvidenceLanes`` needs no optional provenance field and why an Evidence
// Report cannot be constructed from a half-finished session.

/// One of the two evidence source lanes an Evidence Report carries.
///
/// Names a lane; it does not carry that lane's value. Used to say which lane a session
/// is still waiting on without implying anything about the result.
public enum EvidenceSourceLane: String, Hashable, Sendable, CaseIterable {
    case pixel
    case provenance
}

/// Both source lanes of one session, each resolved exactly once.
///
/// The only input from which an Evidence Report can be built. Requirements 7.6 and 7.7
/// are structural consequences of that: `provenance` keeps whichever of the five enabled
/// states or the unavailable state was resolved, and `pixel` keeps whichever of the three
/// labels was resolved, so `absent`, `unavailable`, and the Insufficient Evidence Outcome
/// stay three distinct values. Nothing here can widen one into the other, replace one
/// with a non-positive or positive finding, or add an authenticity claim: there is no
/// field for a claim and no member that rewrites a lane.
public struct ResolvedEvidenceLanes: Hashable, Sendable {
    /// The pixel source lane.
    public let pixel: PixelEvidence

    /// The provenance source lane, including the unavailable state.
    public let provenance: ProvenanceLane

    /// Joins two independently resolved lanes.
    ///
    /// Deliberately unvalidated: every pair of a pixel label and a provenance lane state
    /// is a legitimate session outcome, including pairs that look contradictory.
    /// Requirement 7.8 requires an apparent inconsistency to be *retained* and named, so
    /// rejecting a combination here would suppress exactly the case that must survive.
    public init(pixel: PixelEvidence, provenance: ProvenanceLane) {
        self.pixel = pixel
        self.provenance = provenance
    }
}

/// The two source lanes of one session as they resolve, in either order.
///
/// A value, not a mailbox. Recording a lane produces a new join, so a branch that
/// resolved earlier cannot observe or be affected by a branch that resolves later.
public struct EvidenceLaneJoin: Hashable, Sendable {
    /// A session with neither lane resolved.
    public static let unresolved = EvidenceLaneJoin()

    /// The pixel source lane, or `nil` while it is unresolved.
    public let pixel: PixelEvidence?

    /// The provenance source lane, or `nil` while it is unresolved.
    public let provenance: ProvenanceLane?

    /// Creates a join with neither lane resolved.
    public init() {
        self.pixel = nil
        self.provenance = nil
    }

    private init(pixel: PixelEvidence?, provenance: ProvenanceLane?) {
        self.pixel = pixel
        self.provenance = provenance
    }

    /// Records the pixel source lane, or refuses when it is already resolved.
    ///
    /// `nil` rather than an overwrite or a silently ignored write: a second pixel result
    /// for the same session is a duplicate or late callback, and applying it would give
    /// one branch a way to change an answer the join already holds. The caller learns the
    /// write was refused instead of quietly proceeding on a lane it did not set.
    ///
    /// Takes only Pixel Evidence. There is no parameter through which this call could
    /// read or replace the provenance lane.
    public func resolving(pixel: PixelEvidence) -> EvidenceLaneJoin? {
        guard self.pixel == nil else { return nil }
        return EvidenceLaneJoin(pixel: pixel, provenance: provenance)
    }

    /// Records the provenance source lane, or refuses when it is already resolved.
    ///
    /// Accepts the unavailable state as an ordinary resolution, because a pixel-only
    /// composition resolves this lane without running a validator (Requirements 6.4 and
    /// 6.20). Takes only a ``ProvenanceLane``, so it cannot reach Pixel Evidence.
    public func resolving(provenance: ProvenanceLane) -> EvidenceLaneJoin? {
        guard self.provenance == nil else { return nil }
        return EvidenceLaneJoin(pixel: pixel, provenance: provenance)
    }

    /// The lanes this session is still waiting on.
    ///
    /// Empty exactly when both lanes have resolved. Names the pending lane rather than a
    /// count, so a caller reporting progress does not have to guess which branch is
    /// outstanding.
    public var unresolvedLanes: Set<EvidenceSourceLane> {
        var pending: Set<EvidenceSourceLane> = []
        if pixel == nil { pending.insert(.pixel) }
        if provenance == nil { pending.insert(.provenance) }
        return pending
    }

    /// Whether both required lanes have resolved.
    public var isComplete: Bool { unresolvedLanes.isEmpty }

    /// Both lanes, or `nil` while either is unresolved.
    ///
    /// The only way to obtain the value an Evidence Report is built from, which is how
    /// "construct a report only after both required lanes resolve" holds at the type
    /// level: an incomplete session has nothing to pass to the coordinator.
    public var resolvedLanes: ResolvedEvidenceLanes? {
        guard let pixel, let provenance else { return nil }
        return ResolvedEvidenceLanes(pixel: pixel, provenance: provenance)
    }
}
