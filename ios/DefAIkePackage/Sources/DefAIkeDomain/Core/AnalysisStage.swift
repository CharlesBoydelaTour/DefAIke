// The closed stage vocabulary shared by progress reporting and failure snapshots.

/// A stage of one Analysis Session.
///
/// The vocabulary is closed so that progress and failure location cannot be
/// described by an invented or free-form stage name.
///
/// The design's causal error order over the stages that can commit an
/// `AnalysisError` is: handoff verification, media classification, input validation
/// and its resource checks, preprocessing and its resource checks, model load,
/// inference, output validation, calibration. Arbitrating concurrent results
/// against that order is the session coordinator's responsibility; this type only
/// names the stages.
///
/// ``provenanceValidation`` returns one of the five enabled provenance states
/// rather than an evidence verdict, and a validator fault becomes a release-gate
/// failure rather than a reassuring provenance state. Runtime resource control can
/// still end the whole session from either concurrent branch.
public enum AnalysisStage: String, Codable, Sendable, CaseIterable {
    /// Claiming a Share transfer and reverifying its bytes, digest, and status.
    case handoffVerification
    /// Sniffing the actual container and rejecting animated, video, and audio
    /// media and unsupported static containers.
    case mediaClassification
    /// Bounded declared-dimension checks and the complete decode the bound
    /// Preprocessing Contract requires.
    case inputValidation
    /// Contract orientation, color, alpha, resize, and crop work.
    case preprocessing
    /// Loading the bound Core ML model.
    case modelLoad
    /// Running prediction.
    case inference
    /// Validating the runtime feature result.
    case outputValidation
    /// Mapping a finite logit and the quality record to one pixel label.
    case calibration
    /// Validating Content Credentials, in a provenance-enabled composition only.
    case provenanceValidation
    /// Joining the two immutable source lanes and resolving optional fusion.
    case evidenceJoining
}
