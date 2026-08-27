import Testing

@testable import DefAIkeReleaseValidation

/// Confirms the release-validation test target is wired to its module.
///
/// Artifact-decoding, startup-gate, allowlist, and release-readiness tests arrive
/// with tasks 2.1 through 2.12.
@Suite("DefAIkeReleaseValidation module wiring")
struct ModuleWiringTests {
    @Test("Module marker identifies release tooling")
    func moduleMarker() {
        #expect(DefAIkeReleaseValidationModule.name == "DefAIkeReleaseValidation")
    }
}
