import DefAIkeDomain

// The Evidence Coordinator.
//
// One job: turn two independently resolved source lanes into one immutable Evidence
// Report, or refuse. It is a value with a pure function rather than an actor, because
// there is no state to protect — the lanes arrive as values through ``EvidenceLaneJoin``,
// and the session state machine and its single terminal commit belong to the
// `AnalysisCoordinator` actor. "Constructed once" is therefore a property of the caller
// committing once, not of a latch here that could be read twice.
//
// What this file may not do is as important as what it does:
//
//   * it never runs an analyzer, so neither lane can be recomputed at join time;
//   * it never rewrites a lane, so `absent`, `unavailable`, and the Insufficient Evidence
//     Outcome reach the report exactly as they resolved, still three distinct values, and
//     neither becomes a positive or non-positive finding;
//   * it never resolves an apparent contradiction. The classifier may attach one approved
//     explanatory key beside both unchanged lanes and can do nothing else; and
//   * it performs no fusion. A Combined Summary arrives already resolved by
//     `EvidenceFusing`, and this file only checks that it belongs to the rule the session
//     was bound to before carrying it beside the lanes (Requirement 7.13).

/// Why an Evidence Report could not be constructed from two resolved lanes.
///
/// Not an ``AnalysisError``, and never presented to a user. Every case is an incoherent
/// release configuration — a lane or a summary attributed to an artifact version the
/// session was not bound to — which a correctly composed build cannot reach, in the same
/// class as a failed startup preflight rather than a runtime evidence outcome. The
/// coordinator refuses instead of emitting a report that would misattribute evidence, and
/// how a refusal is arbitrated into a terminal outcome is the session state machine's
/// decision, not this file's.
public enum EvidenceJoinFault: Error, Hashable, Sendable {
    /// An available provenance lane in a session bound to no Provenance Policy, an
    /// unavailable lane in a session bound to one, or a state attributed to a different
    /// policy version than the session's.
    case provenanceLaneNotBoundToSession(expected: ArtifactID?, found: ArtifactID?)

    /// A Combined Summary from a rule the session was not bound to, or a summary in a
    /// session with no bound rule at all.
    case combinedSummaryNotBoundToSession(expected: ArtifactID?, found: ArtifactID)

    /// The lane combination is not representable in a report: a Combined Summary or a
    /// notice beside an unavailable provenance lane, or an unreadable schema version.
    case reportNotRepresentable
}

/// Joins one Pixel Evidence value and one provenance lane into an Evidence Report.
///
/// Holds only the immutable session values a report needs beyond the lanes themselves,
/// bound once when the input was accepted: the session binding, the evidence scope, and
/// the release's apparent-inconsistency classifier if it has one. It holds no port, no
/// analyzer, and no lane, so it cannot become a channel between the two branches.
public struct EvidenceCoordinator: Sendable {
    /// The immutable snapshot this session was bound to.
    public let binding: AnalysisSessionBinding

    /// What the evidence covers and does not cover.
    public let scope: EvidenceScope

    /// The release's classifier, or `nil` when this release declared none.
    ///
    /// `nil` means no apparent-inconsistency notice is ever attached. Both source lanes
    /// still appear in full, which is the mandatory half of Requirement 7.8.
    public let inconsistencyClassifier: ApparentInconsistencyClassifier?

    /// Binds a coordinator to one session, or fails when its inputs disagree.
    ///
    /// Returns `nil` when a classifier's copy catalogue is not the one this session's
    /// Model Bundle and capability set are compatible with (Requirement 8.1). A notice
    /// drawn from incompatible copy is not approved copy for this session, and preferring
    /// either side would be the silent substitution the compatibility identifier exists to
    /// prevent.
    public init?(
        binding: AnalysisSessionBinding,
        scope: EvidenceScope,
        inconsistencyClassifier: ApparentInconsistencyClassifier?
    ) {
        if let inconsistencyClassifier {
            guard inconsistencyClassifier.copyCompatibilityID
                == binding.verdictCopyCompatibilityID
            else { return nil }
        }
        self.binding = binding
        self.scope = scope
        self.inconsistencyClassifier = inconsistencyClassifier
    }

    /// Constructs the report for one completed session.
    ///
    /// Takes ``ResolvedEvidenceLanes``, so a session with an outstanding lane has no value
    /// to call this with: "only after both required lanes resolve" is enforced by the
    /// parameter type rather than by a check that could be skipped.
    ///
    /// `combinedSummary` is already resolved when it arrives. Fusion is a separate pure
    /// lookup behind `EvidenceFusing`; this checks only that a summary belongs to the rule
    /// the session was bound to, then carries it beside both lanes without letting it touch
    /// either (Requirements 7.1, 7.8, and 7.13).
    public func report(
        lanes: ResolvedEvidenceLanes,
        combinedSummary: CombinedSummary?,
        bytePreservationStatus: BytePreservationStatus,
        inputQuality: InputQualityRecord,
        onDeviceProcessing: Bool
    ) throws(EvidenceJoinFault) -> EvidenceReport {
        try checkProvenanceAttribution(lanes.provenance)
        try checkSummaryAttribution(combinedSummary)

        // The only value this file adds to the two lanes, and it is additive: an approved
        // key beside them, or nothing.
        let notice = inconsistencyClassifier?.notice(for: lanes)

        guard let report = EvidenceReport(
            binding: binding,
            pixel: lanes.pixel,
            provenance: lanes.provenance,
            combinedSummary: combinedSummary,
            apparentInconsistency: notice,
            bytePreservationStatus: bytePreservationStatus,
            inputQuality: inputQuality,
            onDeviceProcessing: onDeviceProcessing,
            scope: scope
        ) else {
            throw .reportNotRepresentable
        }
        return report
    }

    // MARK: - Attribution

    /// Requires the provenance lane to describe the composition the session was bound to.
    ///
    /// One direction is hard and the other is not, and the asymmetry is deliberate.
    ///
    /// **An available lane in a session bound to no policy is refused.** Every enabled state
    /// except `absent` names the Provenance Policy that mapped it, so a finding in an
    /// unbound session would be attributed to nothing. Where an enabled state names a
    /// policy, that name must be the bound one; `absent` names none, because "no Content
    /// Credential was found" carries no policy-dependent detail.
    ///
    /// **An unavailable lane in a session bound to a policy is permitted**, and this used to
    /// be refused. The refusal rested on an implication that no longer holds: while the
    /// pixel-only build linked no validator, a manifest that enabled the capability meant a
    /// linked adapter, and `ProvenanceLaneProvider`'s enabled path always returns an
    /// available lane because `ProvenanceAnalyzing.analyze` cannot fail. Enabled therefore
    /// implied available, and the biconditional was free.
    ///
    /// The single application composition links the validator unconditionally, which adds a
    /// break in that chain: the manifest can enable the capability and name a policy while
    /// no approved decision supplies an analyzer, which is
    /// `UnavailableReason.validatorEnablementUnapproved`. Keeping the old refusal would end
    /// every Analysis Session in that configuration with an `evidenceJoining` fault, so the
    /// app would report an Analysis Error instead of a completed report with an honest
    /// unavailable lane — a worse outcome than the one the rule was written to prevent.
    ///
    /// Nothing is discarded by permitting it. The binding records which signed policy
    /// version governs the session, a configuration fact; the lane records what the session
    /// produced, an outcome. An audit that reads both sees the release enabled provenance
    /// under that policy *and* that the lane produced nothing, with the reason attached.
    /// Deriving the binding from the lane instead would make the same signed release record
    /// different bindings depending on whether an analyzer happened to exist, which is the
    /// version-attribution property the binding exists to hold still.
    private func checkProvenanceAttribution(
        _ lane: ProvenanceLane
    ) throws(EvidenceJoinFault) {
        switch lane {
        case .unavailable:
            // Permitted whether or not the session bound a policy. The lane's own reason is
            // the record of why nothing was produced, and `EvidenceReport` separately
            // refuses a Combined Summary or an inconsistency notice beside an unavailable
            // lane, so an unavailable lane still cannot contribute to an interpretation.
            break
        case .available(let evidence):
            guard let bound = binding.provenancePolicyID else {
                throw .provenanceLaneNotBoundToSession(
                    expected: nil,
                    found: evidence.attributedPolicyID
                )
            }
            if let attributed = evidence.attributedPolicyID, attributed != bound {
                throw .provenanceLaneNotBoundToSession(expected: bound, found: attributed)
            }
        }
    }

    /// Requires a Combined Summary to come from the rule the session was bound to.
    ///
    /// The fusion port already refuses a mismatched rule, and this refuses one again on the
    /// way into the report. That is not redundancy for its own sake: the fuser is injected,
    /// and a report is the record an audit reads, so the value that records a rule version
    /// is checked where it is written rather than only where it was produced.
    private func checkSummaryAttribution(
        _ summary: CombinedSummary?
    ) throws(EvidenceJoinFault) {
        guard let summary else { return }
        guard summary.fusionRuleID == binding.fusionRuleID else {
            throw .combinedSummaryNotBoundToSession(
                expected: binding.fusionRuleID,
                found: summary.fusionRuleID
            )
        }
    }
}

extension ProvenanceEvidence {
    /// The Provenance Policy version this state was mapped by, or `nil` when the state
    /// names none.
    ///
    /// Only `absent` names none. Exhaustive with no `default`, so a sixth enabled state
    /// would be a compile error here rather than a silently unattributed finding.
    var attributedPolicyID: ArtifactID? {
        switch self {
        case .validated(let summary): summary.provenancePolicyID
        case .invalid(let summary): summary.provenancePolicyID
        case .absent: nil
        case .unsupported(let summary): summary.provenancePolicyID
        case .indeterminate(let summary): summary.provenancePolicyID
        }
    }
}
