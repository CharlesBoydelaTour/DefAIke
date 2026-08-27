// The fusion port.
//
// Fusion is a pure lookup over the 15 enabled lane combinations, and the lookup itself
// cannot fail: ``EvidenceFusionRule`` proves exact coverage of all 15 keys at
// construction, so ``EvidenceFusionRule/disposition(for:)`` is total. What can fail is
// applying a rule that is not the one this session was bound to, which is what
// ``FusionFault`` names.
//
// Two structural guarantees sit in the signature rather than in an implementation:
//
//   * the port takes ``ProvenanceEvidence``, not ``ProvenanceLane``, so an unavailable
//     lane cannot be passed at all and always omits the summary (Requirement 7.10); and
//   * it returns `CombinedSummary?`, so omission is an ordinary result rather than an
//     error, and a missing, invalid, or unapproved rule cannot block an otherwise
//     eligible release (Requirement 7.16).

/// Why a fusion rule could not be applied to this session.
///
/// Not an ``AnalysisError``: a rule mismatch is a release-configuration fault, and a
/// session with no Combined Summary is a complete, valid session. The coordinator
/// records the fault and omits the summary rather than failing the analysis.
public enum FusionFault: Error, Hashable, Sendable {
    /// The rule is not the version the session was bound to, or the session has no
    /// bound rule at all.
    case ruleNotBoundToSession(expected: ArtifactID?, found: ArtifactID)

    /// The rule's copy keys come from a catalogue the session's Model Bundle and
    /// capability set are not compatible with (Requirement 8.1).
    case incompatibleVerdictCopy(expected: ArtifactID, found: ArtifactID)
}

/// Resolves the optional Combined Summary for one pair of enabled lane states.
///
/// Neither source lane is passed mutably and neither is returned, so a summary cannot
/// suppress, override, or rank a card: the coordinator keeps both lanes and attaches
/// the summary beside them (Requirements 7.1 and 7.8).
public protocol EvidenceFusing: Sendable {
    /// Looks up the single deterministic disposition for `(pixel, provenance)`.
    ///
    /// Returns `nil` when the approved entry for that combination is explicit omission.
    /// Throws only when `rule` is not the rule `binding` names, or its copy catalogue is
    /// not compatible with the session's — checks that need the binding, which is why it
    /// is a parameter.
    func resolve(
        pixel: PixelEvidence,
        provenance: ProvenanceEvidence,
        rule: EvidenceFusionRule,
        binding: AnalysisSessionBinding
    ) throws(FusionFault) -> CombinedSummary?
}
