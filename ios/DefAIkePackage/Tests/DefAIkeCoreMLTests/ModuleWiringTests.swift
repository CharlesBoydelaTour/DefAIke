import Testing

@testable import DefAIkeCoreML

/// Confirms the Core ML test target is wired to its module.
///
/// The load, execution, and output-mapping tests live alongside this file. The
/// generated-input version of the output rules is Property 14 (task 6.8), and
/// inspecting a real model description, running a real prediction, and comparing
/// against parity fixtures need a compiled model (task 6.11).
@Suite("DefAIkeCoreML module wiring")
struct ModuleWiringTests {
    @Test("Module marker identifies the Core ML pixel analyzer")
    func moduleMarker() {
        #expect(DefAIkeCoreMLModule.name == "DefAIkeCoreML")
    }
}
