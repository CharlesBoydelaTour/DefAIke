import Testing

@testable import DefAIkeDomain

/// Confirms the domain test target is wired to the domain module.
///
/// Domain behavior tests arrive with tasks 1.2, 1.3, 1.4, and 1.5.
@Suite("DefAIkeDomain module wiring")
struct ModuleWiringTests {
    @Test("Module marker identifies the domain core")
    func moduleMarker() {
        #expect(DefAIkeDomainModule.name == "DefAIkeDomain")
    }
}
