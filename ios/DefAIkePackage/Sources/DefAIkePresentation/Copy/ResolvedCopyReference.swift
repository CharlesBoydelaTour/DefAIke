import DefAIkeDomain

// The only value a successful copy lookup produces.
//
// A resolved reference is an *address*, not a sentence. It names the surface, the
// stable String Catalog localization key that surface's approved English value lives
// under, and the exact catalogue version that supplied the mapping. It deliberately
// carries no display text, because at this task the English String Catalog does not
// exist yet (spec task 11.5 adds it) and because the domain's rule is that copy
// lives in the catalogue while the code carries keys.
//
// The type exists so a presentation field can be typed as "approved copy for a known
// surface" rather than as `String`. Every user-facing sentence in the app reaches the
// view through one of these, so there is no field a free-form claim could be written
// into.

/// One resolved Approved Verdict Copy address.
///
/// Constructible only by ``ApprovedCopyBinding``: the initializer is internal, so a
/// reference cannot be fabricated for an unbound catalogue, an unreachable surface,
/// or a key the catalogue never approved.
public struct ResolvedCopyReference: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The surface this copy is approved for.
    public let surface: VerdictCopySurface

    /// The stable String Catalog key the approved English value lives under.
    ///
    /// Not display text and not a fallback. Rendering goes through the English
    /// String Catalog; a lookup that finds no value there is a release-validation
    /// failure, never a reason to show this key to a user.
    public let localizationKey: ApprovedCopyKey

    /// The catalogue version that approved this mapping.
    public let catalogID: ArtifactID

    /// The compatibility identifier the catalogue, the session-bound Model Bundle,
    /// and the capability manifest all agreed on (Requirement 8.1).
    public let compatibilityID: ArtifactID

    init(
        surface: VerdictCopySurface,
        localizationKey: ApprovedCopyKey,
        catalogID: ArtifactID,
        compatibilityID: ArtifactID
    ) {
        self.surface = surface
        self.localizationKey = localizationKey
        self.catalogID = catalogID
        self.compatibilityID = compatibilityID
    }
}
