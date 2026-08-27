/// Boundary marker for application orchestration.
///
/// Responsibility: the `AnalysisCoordinator` actor that owns Analysis Session
/// state, immutable artifact binding, ordered stage execution, evidence-lane
/// joining, cancellation, resource arbitration, and the single terminal commit.
/// Also hosts the Evidence Coordinator.
///
/// Dependency rule: `DefAIkeDomain` and `DefAIkeProvenanceAPI` only. The
/// coordinator drives adapters through domain ports and never imports a
/// framework adapter module directly.
///
/// Present: ``AnalysisCoordinator`` — the actor that owns one Analysis Session's
/// state, runs the ordered stages, resolves both evidence lanes under the
/// release-approved ``ApprovedEvidenceBranchExecution``, and commits exactly one
/// terminal outcome through the write-once ``TerminalCommitSlot`` (task 10.1);
/// ``CausalFaultArbitration``, which decides which of several faults a session
/// reports by causal stage order rather than by arrival order; the Resource
/// Controller and its enforcement vocabulary; progress derivation; the Evidence
/// Coordinator and its lane join; ``PhotosIngestCoordinator`` and
/// ``ShareHandoffIngestCoordinator`` — the two routes' ingest rules, which decide
/// whether a session exists and what a pending handoff becomes (tasks 4.2 and
/// 4.5); and ``SessionTerminalCleanup``, which binds a committed terminal outcome
/// to the approved cleanup deadline that outcome selects (task 10.3).
///
/// Startup cleanup is deliberately not here. `StartupPreflight` runs it through
/// the same cleanup port and refuses to produce a `ReleaseAdmission` when it
/// fails, which is what keeps both ingest routes closed after a failed startup
/// cleanup; a second entry point would be a second cleanup path.
///
/// Cooperative cancellation and stale-callback suppression build on the identity
/// and single-commit seam this module already exposes: a request claims the
/// terminal slot with `cancelled` in one synchronous step, cancels the session's
/// structured task and every registered framework hook, and thereafter every late
/// framework result is refused by ``AnalysisSessionIdentity`` through
/// ``FrameworkResultAdmission`` (task 10.5).
public enum DefAIkeApplicationModule: Sendable {
    /// Stable module identifier used by module-boundary and release-audit checks.
    public static let name = "DefAIkeApplication"
}
