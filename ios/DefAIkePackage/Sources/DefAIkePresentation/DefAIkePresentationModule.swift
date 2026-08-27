/// Boundary marker for presentation.
///
/// Responsibility: SwiftUI screens, accessibility semantics, the English String
/// Catalog, progress rendering, independent pixel and provenance result cards,
/// the optional Combined Summary, limitation and model-information cards, and
/// recovery actions.
///
/// Dependency rule: `DefAIkeDomain` plus SwiftUI. Presentation renders domain
/// state on the main actor and computes no evidence semantics. No probability,
/// confidence, history, save, export, copy, or share-result affordance may
/// appear in the view or accessibility hierarchy.
///
/// Populated by the presentation, accessibility, and approved-copy tasks.
public enum DefAIkePresentationModule: Sendable {
    /// Stable module identifier used by module-boundary and release-audit checks.
    public static let name = "DefAIkePresentation"
}
