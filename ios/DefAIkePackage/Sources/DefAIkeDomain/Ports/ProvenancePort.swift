// The provenance port.
//
// `DefAIkeProvenanceAPI` declares this port so the application stays independent of a
// vendor API, and only `DefAIkeProvenanceC2PA` — linked into the
// pixel-plus-provenance composition alone — implements it. In a pixel-only build there
// is no implementation and no call: the coordinator holds `(any ProvenanceAnalyzing)?`
// and a `nil` analyzer *is* the unavailable lane
// (`.unavailable(.validatorNotCompiledIntoRelease)`). That is why disabled provenance
// code is never invoked and never linked, and why every pixel-only report omits the
// Combined Summary (Requirements 6.3, 6.4, 6.19, 6.20, and 7.10).

/// Validates Content Credentials in the exact retained encoded bytes, offline.
///
/// The port is deliberately **non-throwing**. Every outcome a validator can reach —
/// including a parser fault, an inconclusive result, and a missing offline revocation
/// answer — maps through the signed Provenance Policy into exactly one of the five
/// enabled states. A validator problem is therefore an evidence state chosen by an
/// approved mapping, never an `AnalysisError` that would end the session, and never
/// silently reported as `validated` (Requirements 6.9 through 6.18).
///
/// Conditions the policy cannot map — a crash, unbounded output, an ambiguous mapping,
/// or fixture disagreement — are Provenance Feasibility Gate failures handled before
/// distribution, not runtime outcomes.
public protocol ProvenanceAnalyzing: Sendable {
    /// Inspects `asset` before any byte-changing transformation and returns exactly one
    /// enabled provenance state.
    ///
    /// Takes the same ``ImportedEncodedAsset`` the Input Validator receives, so the
    /// identical retained byte sequence reaches both lanes (Requirements 2.13 and 6.6).
    /// It receives the asset immutably and has no access to the pixel lane, so it
    /// cannot change the raw logit, the execution status, or Pixel Evidence
    /// (Requirement 7.4).
    func analyze(
        _ asset: ImportedEncodedAsset,
        policy: ProvenancePolicy
    ) async -> ProvenanceEvidence
}
