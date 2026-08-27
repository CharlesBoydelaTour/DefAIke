import Testing

@testable import DefAIkePresentation

/// Confirms the presentation test target is wired to its module.
///
/// Copy-compatibility, accessibility, Dynamic Type, and prohibited-affordance
/// tests arrive with the presentation and accessibility tasks.
@Suite("DefAIkePresentation module wiring")
struct ModuleWiringTests {
    @Test("Module marker identifies presentation")
    func moduleMarker() {
        #expect(DefAIkePresentationModule.name == "DefAIkePresentation")
    }
}
