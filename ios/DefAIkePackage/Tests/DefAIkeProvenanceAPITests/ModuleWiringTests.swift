import Testing

@testable import DefAIkeProvenanceAPI

/// Confirms the provenance-API test target is wired to its module.
///
/// The contract's own behavior is covered by the normalized-contract, mapping, and
/// unavailable-lane suites, and quantified by the Property 19 capability-selection and
/// Property 20 mapping-exclusivity property files.
@Suite("DefAIkeProvenanceAPI module wiring")
struct ModuleWiringTests {
    @Test("Module marker identifies the provenance contract")
    func moduleMarker() {
        #expect(DefAIkeProvenanceAPIModule.name == "DefAIkeProvenanceAPI")
    }
}
