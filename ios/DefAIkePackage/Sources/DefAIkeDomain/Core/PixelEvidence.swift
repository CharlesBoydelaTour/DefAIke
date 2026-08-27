// The pixel source lane's three outcomes.

/// The calibrated, quality-aware interpretation of one pixel-model logit.
///
/// Exactly three outcomes exist for Version 1 (Requirement 5.2), and they are the
/// only pixel results representable anywhere in the domain. There is no fourth
/// case, no probability, no confidence level, and no numeric score: a raw logit
/// never reaches a report, and calibration is the only path from a logit to one of
/// these values.
///
/// Pixel Evidence is probabilistic evidence, not proof. The user-facing wording for
/// each case comes from Approved Verdict Copy resolved by key, so a label's meaning
/// cannot be changed by editing this enum.
public enum PixelEvidence: String, Codable, Sendable, CaseIterable {
    /// Positive pixel label: signals consistent with AI generation.
    case signalsConsistentWithAIGeneration
    /// Non-positive pixel label: no strong model signal. Not an authenticity claim.
    case noStrongSignalDetected
    /// Insufficient evidence outcome: not enough usable pixel signal.
    case notEnoughSignal
}
