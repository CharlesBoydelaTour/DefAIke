import Testing

@testable import DefAIkeApplication

/// Confirms the application test target is wired to its module.
///
/// Resource governance is covered by `ResourceControllerTests`, evidence joining by
/// `EvidenceCoordinatorTests` and `EvidenceLaneJoinTests`, progress by
/// `ProgressDerivationTests`, the two ingest routes by `PhotosIngestCoordinatorTests` and
/// `ShareHandoffIngestCoordinatorTests`, terminal cleanup's deadline selection by
/// `SessionTerminalCleanupTests`, and Analysis Session state, causal fault arbitration, the
/// single terminal commit, and retry isolation by `AnalysisCoordinatorTests`. Cooperative
/// cancellation, framework hooks, and stale-callback suppression are covered by
/// `SessionCancellationTests`.
@Suite("DefAIkeApplication module wiring")
struct ModuleWiringTests {
    @Test("Module marker identifies application orchestration")
    func moduleMarker() {
        #expect(DefAIkeApplicationModule.name == "DefAIkeApplication")
    }
}
