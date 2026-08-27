import Testing

@testable import DefAIkeImagePipeline

/// Confirms the image-pipeline test target is wired to its module.
///
/// Real-framework decode, metadata, resize, and crop tests arrive with tasks 5.1
/// through 5.10. Host results are development checks only; physical-device parity
/// remains a separate release gate.
@Suite("DefAIkeImagePipeline module wiring")
struct ModuleWiringTests {
    @Test("Module marker identifies the image pipeline")
    func moduleMarker() {
        #expect(DefAIkeImagePipelineModule.name == "DefAIkeImagePipeline")
    }
}
