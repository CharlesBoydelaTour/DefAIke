/// Boundary marker for the pure domain core.
///
/// Responsibility: `Sendable` value types, session state machines, policy and
/// release-artifact schemas, identifiers and digests, the closed `AnalysisError`
/// vocabulary, calibration and fusion lookup, progress derivation, and the
/// application port protocols that adapters implement.
///
/// Dependency rule: no target dependencies. Foundation only, and only where
/// unavoidable. This module must never import SwiftUI, UIKit, PhotosUI,
/// CoreTransferable, ImageIO, CoreGraphics, Accelerate, CoreML, or any
/// provenance library.
///
/// Populated by tasks 1.2 (core values), 1.3 (artifact schemas), and 1.4 (ports).
public enum DefAIkeDomainModule: Sendable {
    /// Stable module identifier used by module-boundary and release-audit checks.
    public static let name = "DefAIkeDomain"
}
