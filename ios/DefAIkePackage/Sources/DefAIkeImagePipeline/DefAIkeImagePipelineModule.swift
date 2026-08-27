/// Boundary marker for the image validation and preprocessing adapter.
///
/// Responsibility: Uniform Type Identifier and Image I/O container sniffing,
/// complete decode within the active Resource Budget, pre-orientation quality
/// records, contract-total orientation/color-profile/alpha handling, bilinear
/// short-edge-440 resize, 384×384 center crop, and UInt8 RGB model-input
/// production. No app-side channel normalization.
///
/// Dependency rule: `DefAIkeDomain` plus Apple imaging frameworks
/// (ImageIO, CoreGraphics, ColorSync, Accelerate). Never Core ML or provenance.
///
/// Present: container classification and complete decode validation
/// (``ImageIOInputValidator``, task 5.1), the exact pre-orientation quality record and
/// the session-isolated failure snapshot it survives into (``InputQualityLedger``,
/// task 5.2), the contract-total metadata, RGB, color-space, and alpha half of the
/// Preprocessor (``ImageMetadataInspector``, ``MetadataActionBinding``,
/// ``WorkingColorSpace``, ``WorkingSpaceRGBRenderer``, task 5.3), and the deterministic
/// resize, the centered crop, the ``ImagePreprocessing`` conformance, and model-input
/// production (``ResizeGeometry``, ``BilinearResampler``, ``ModelInputProduction``,
/// ``ContractImagePreprocessor``, ``PreparedModelInputStore``, task 5.4).
///
/// The failure snapshot a preprocessing fault is presented in is taken from
/// ``InputQualityLedger`` by the coordinator that commits the terminal outcome, not by
/// the preprocessing adapter: the ledger already holds the pre-orientation dimensions
/// and Byte Preservation Status the snapshot preserves (Requirement 3.14), so the
/// adapter carries no ledger and cannot record a second, disagreeing copy.
public enum DefAIkeImagePipelineModule: Sendable {
    /// Stable module identifier used by module-boundary and release-audit checks.
    public static let name = "DefAIkeImagePipeline"
}
