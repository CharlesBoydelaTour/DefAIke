import Testing

@testable import DefAIkeModelBundle

/// Confirms the model-bundle test target is wired to its module.
///
/// Manifest, structural-scan, digest, signature, and artifact-tree tests are in the
/// sibling files. Self-test, activation, and rollback tests arrive with tasks 6.2 and
/// 6.3, and the numbered design properties with tasks 6.6 through 6.11.
@Suite("DefAIkeModelBundle module wiring")
struct ModuleWiringTests {
    @Test("Module marker identifies the model bundle manager")
    func moduleMarker() {
        #expect(DefAIkeModelBundleModule.name == "DefAIkeModelBundle")
    }
}
