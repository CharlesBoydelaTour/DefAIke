/// Boundary marker for the Core ML pixel analyzer adapter.
///
/// Responsibility: loading only the session-bound `MLModel` with a configuration
/// that permits Apple Neural Engine execution, asynchronous prediction, runtime
/// feature-schema validation, and mapping load, execution, and output faults to
/// the exact `model-load-error`, `inference-error`, and `invalid-output-error`
/// categories. Emits one finite positive-going raw `logit` on success.
///
/// Dependency rule: `DefAIkeDomain` plus Core ML. Never PhotosUI, provenance,
/// or presentation. Permitting all compute units does not prove Apple Neural
/// Engine placement, latency, memory, energy, or thermal behavior; those remain
/// physical-device measurements.
///
/// `CoreMLPixelModelLoader` and `CoreMLPixelAnalyzer` implement the two ports;
/// `RuntimeSchemaCheck` and `ModelOutputCheck` are the pure decisions behind
/// them; `CoreMLModelRuntime` is the only type here that touches Core ML, and it
/// arrives through the `PixelModelRuntimeLoading` seam so the failure mapping is
/// testable without a compiled model. Parity, tolerance, and device behavior are
/// not established anywhere in this module.
public enum DefAIkeCoreMLModule: Sendable {
    /// Stable module identifier used by module-boundary and release-audit checks.
    public static let name = "DefAIkeCoreML"
}
