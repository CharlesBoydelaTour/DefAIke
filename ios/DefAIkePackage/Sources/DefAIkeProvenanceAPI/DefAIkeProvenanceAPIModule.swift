/// Boundary marker for the vendor-independent provenance contract.
///
/// Responsibility: the normalized, bounded provenance input and output types, the
/// Provenance Policy mapping contract, and the unavailable-lane provider used by
/// the pixel-only composition. The ``ProvenanceAnalyzing`` port itself lives in
/// `DefAIkeDomain`, so an adapter depends on the domain rather than on this
/// module or on the orchestrator.
///
/// Dependency rule: `DefAIkeDomain` only. This module must not depend on
/// `c2pa-swift` or any other provenance implementation, so that the pixel-only
/// composition links no validator (Requirements 6.19 and 6.20).
public enum DefAIkeProvenanceAPIModule: Sendable {
    /// Stable module identifier used by module-boundary and release-audit checks.
    public static let name = "DefAIkeProvenanceAPI"
}
