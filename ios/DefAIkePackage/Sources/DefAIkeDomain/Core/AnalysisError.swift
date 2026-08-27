// The closed Analysis Error vocabulary.

/// A terminal, non-evidence outcome category.
///
/// Exactly these ten categories exist, and the raw values are the exact strings the
/// requirements name. An Analysis Error never coexists with an Evidence Report, is
/// never rendered in either evidence card, and is distinct from the three pixel
/// labels, the five enabled provenance states, the unavailable provenance state, a
/// Combined Summary, and the cancelled terminal state (Requirement 11.17).
///
/// Two failure kinds are deliberately outside this set, because adding them would
/// invent a user-facing evidence-error category the requirements do not define:
///
/// * A provider retrieval that fails before DefAIke holds any bytes is a
///   recoverable ingest-attempt failure and starts no session.
/// * A failed mandatory startup gate, including startup privacy cleanup, is a
///   fail-closed preflight blocker that keeps ingest unavailable.
public enum AnalysisError: String, Codable, Sendable, CaseIterable {
    /// The provider or container is animated, video, or audio.
    case unsupportedMedia = "unsupported-media"
    /// A non-animated static container outside JPEG, PNG, and HEIC/HEIF.
    case unsupportedStaticFormat = "unsupported-static-format"
    /// The container is malformed, truncated, or not completely decodable.
    case decodingError = "decoding-error"
    /// Continuing would exceed a hard limit in the active target's Resource Budget.
    case resourceLimit = "resource-limit"
    /// The bound Preprocessing Contract cannot be applied. There is no fallback.
    case preprocessingError = "preprocessing-error"
    /// No verified compatible bundle, or model load, compatibility, or a required
    /// self-test failed. The previously verified bundle stays unchanged.
    case modelLoadError = "model-load-error"
    /// Core ML prediction failed after a valid input was supplied.
    case inferenceError = "inference-error"
    /// The `logit` output is missing, misnamed, nonscalar, nonnumeric, or nonfinite.
    /// It is never mapped to a pixel label.
    case invalidOutputError = "invalid-output-error"
    /// A required quality input is missing or invalid and no explicit approved
    /// abstention rule covers the observed condition.
    case calibrationInputError = "calibration-input-error"
    /// A Share ticket, payload, status, schema, or build identity mismatch, or an
    /// incomplete claim, detected before any image or provenance work.
    case handoffError = "handoff-error"
}
