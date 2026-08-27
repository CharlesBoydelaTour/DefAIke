import DefAIkeDomain

// Version-bound Approved Verdict Copy lookup.
//
// Requirement 8.1 does not ask for a string table. It asks for copy that is
// *version-controlled* and *compatible with the Analysis-Session-bound Model Bundle*,
// covering every reachable label, provenance state, unavailable state, Combined
// Summary, warning, and Analysis Error. So binding happens once, up front, against
// three records that must agree - the signed Release Capability Manifest, the
// immutable session binding, and the catalogue - plus the active Evidence Fusion Rule
// when fusion is enabled.
//
// Everything expensive or refusable happens at bind time. After a binding exists,
// resolving a reachable surface cannot fail for a version reason, because a version
// disagreement was already refused. What resolution can still refuse is a surface
// this composition cannot reach and a copy key a component declared but the catalogue
// never approved.
//
// The two things this type will not do:
//
//   * fall back. There is no default key, no English literal, no rendered raw key,
//     and no generated sentence. An unresolvable surface throws.
//   * decide. It approves no wording, enables no capability, and selects no policy
//     version. It checks that records already agree and refuses when they do not.

/// A catalogue bound to one Analysis Session and capability composition.
///
/// Constructed only through ``bind(catalog:session:capabilities:fusionRule:)``, so an
/// unchecked or version-skewed binding does not exist.
public struct ApprovedCopyBinding: Hashable, Sendable {
    /// The catalogue version supplying every key.
    public let catalogID: ArtifactID

    /// The compatibility identifier all bound records agreed on.
    public let compatibilityID: ArtifactID

    /// The signed capability manifest this binding was checked against.
    public let capabilityManifestID: ArtifactID

    /// The session this binding belongs to. A binding is not reusable across
    /// sessions: a later activation or rollback cannot change an active session
    /// (Requirement 10.15), so copy is bound per session exactly as the bundle is.
    public let sessionID: AnalysisSessionID

    /// What this composition can reach, and therefore what may be resolved.
    public let reachableSurfaces: ReachableCopySurfaces

    /// Reachable surfaces only. Restricting the table, rather than filtering at
    /// lookup time, is what makes an unreachable surface unresolvable instead of
    /// conditionally hidden.
    private let keysBySurface: [VerdictCopySurface: ApprovedCopyKey]

    private init(
        catalogID: ArtifactID,
        compatibilityID: ArtifactID,
        capabilityManifestID: ArtifactID,
        sessionID: AnalysisSessionID,
        reachableSurfaces: ReachableCopySurfaces,
        keysBySurface: [VerdictCopySurface: ApprovedCopyKey]
    ) {
        self.catalogID = catalogID
        self.compatibilityID = compatibilityID
        self.capabilityManifestID = capabilityManifestID
        self.sessionID = sessionID
        self.reachableSurfaces = reachableSurfaces
        self.keysBySurface = keysBySurface
    }

    /// Binds `catalog` to one session, or refuses.
    ///
    /// `fusionRule` is the Evidence Fusion Rule the release binds, and must be
    /// supplied exactly when the manifest enables fusion. Requirement 7.16 permits a
    /// release with no Combined Summary at all, which is the `nil` case; it does not
    /// permit a release that claims fusion and cannot say which summaries exist.
    public static func bind(
        catalog: ApprovedVerdictCopyCatalog,
        session: AnalysisSessionBinding,
        capabilities: ReleaseCapabilityManifest,
        fusionRule: EvidenceFusionRule?
    ) throws(PresentationCopyError) -> ApprovedCopyBinding {
        // Requirement 8.18: English is the only Version 1 user-facing language. The
        // catalogue schema already enforces this, so reaching the throw means an
        // artifact was constructed by some path that bypassed the schema.
        guard catalog.languageTag.value == ApprovedVerdictCopyCatalog.requiredLanguageTag else {
            throw .unsupportedLanguage(
                expected: ApprovedVerdictCopyCatalog.requiredLanguageTag,
                found: catalog.languageTag.value
            )
        }

        // Presence of an approval record is not approval.
        guard catalog.approval.isApproved else {
            throw .unapprovedCatalog(
                catalog: catalog.id,
                decision: catalog.approval.decision
            )
        }

        // The session records which manifest it was bound to. Checking a different
        // manifest would let this binding read a capability set the session never
        // ran under.
        guard session.capabilityManifestID == capabilities.id else {
            throw .capabilityManifestMismatch(
                session: session.capabilityManifestID,
                supplied: capabilities.id
            )
        }

        // The session-bound Model Bundle's copy compatibility identifier is the
        // authority Requirement 8.1 names. Every other record is checked against it.
        let required = session.verdictCopyCompatibilityID
        let manifestCompatibility = capabilities.policyCompatibility.verdictCopyCompatibility
        guard manifestCompatibility == required else {
            throw .compatibilityMismatch(
                source: .capabilityManifest,
                expected: required,
                found: manifestCompatibility
            )
        }
        guard catalog.compatibilityID == required else {
            throw .compatibilityMismatch(
                source: .copyCatalog,
                expected: required,
                found: catalog.compatibilityID
            )
        }

        // Which surfaces are reachable depends on the enabled capability set, so the
        // manifest and the session have to agree about it before reachability is
        // computed. Disagreement is version skew, not a renderable state.
        guard capabilities.enablesProvenance == (session.provenancePolicyID != nil) else {
            throw .provenanceBindingMismatch(
                manifestEnablesProvenance: capabilities.enablesProvenance,
                sessionBindsPolicy: session.provenancePolicyID != nil
            )
        }
        guard capabilities.enablesFusion == (session.fusionRuleID != nil) else {
            throw .fusionBindingMismatch(
                manifestEnablesFusion: capabilities.enablesFusion,
                sessionBindsRule: session.fusionRuleID != nil
            )
        }

        try validateFusionInput(
            fusionRule,
            session: session,
            capabilities: capabilities,
            requiredCompatibility: required
        )

        let reachable = ReachableCopySurfaces(
            capabilities: capabilities,
            fusionRule: fusionRule
        )

        // Requirement 8.1: every reachable surface needs an approved entry. Checked
        // once here, so a session cannot reach its result screen and discover a gap.
        let missing = reachable.missingSurfaces(in: catalog)
        guard missing.isEmpty else {
            throw .missingSurfaces(missing)
        }

        var table: [VerdictCopySurface: ApprovedCopyKey] = [:]
        table.reserveCapacity(reachable.surfaces.count)
        for entry in catalog.entries where reachable.contains(entry.surface) {
            table[entry.surface] = entry.localizationKey
        }

        return ApprovedCopyBinding(
            catalogID: catalog.id,
            compatibilityID: required,
            capabilityManifestID: capabilities.id,
            sessionID: session.sessionID,
            reachableSurfaces: reachable,
            keysBySurface: table
        )
    }

    /// Checks that the supplied fusion rule is exactly the rule this release and
    /// session bind, and that it addresses the same approved copy.
    private static func validateFusionInput(
        _ fusionRule: EvidenceFusionRule?,
        session: AnalysisSessionBinding,
        capabilities: ReleaseCapabilityManifest,
        requiredCompatibility: ArtifactID
    ) throws(PresentationCopyError) {
        let bound = capabilities.policyCompatibility.fusionRule.boundReference

        switch (bound, fusionRule) {
        case (nil, nil):
            return

        case let (nil, .some(supplied)):
            throw .unexpectedFusionRule(supplied: supplied.id)

        case let (.some(expected), nil):
            throw .missingFusionRule(expected: expected)

        case let (.some(expected), .some(rule)):
            guard rule.id == expected else {
                throw .fusionRuleMismatch(expected: expected, found: rule.id)
            }
            // The session's own recorded rule version is checked separately: the
            // manifest says which rule the release binds, the session says which
            // rule it ran under, and a report shows the latter (Requirement 7.11).
            if let sessionRule = session.fusionRuleID, sessionRule != rule.id {
                throw .fusionRuleMismatch(expected: sessionRule, found: rule.id)
            }
            guard rule.compatibleVerdictCopy == requiredCompatibility else {
                throw .compatibilityMismatch(
                    source: .fusionRule,
                    expected: requiredCompatibility,
                    found: rule.compatibleVerdictCopy
                )
            }
        }
    }

    // MARK: - Resolution

    /// Resolves one reachable surface to its approved copy address.
    ///
    /// Throws for a surface this composition cannot reach and for a reachable surface
    /// the catalogue does not cover. Neither case yields text: an unresolvable key is
    /// a fail-closed presentation error, never a raw key or a free-form fallback.
    public func reference(
        for surface: VerdictCopySurface
    ) throws(PresentationCopyError) -> ResolvedCopyReference {
        guard reachableSurfaces.contains(surface) else {
            throw .unreachableSurface(surface)
        }
        guard let key = keysBySurface[surface] else {
            throw .unresolvableSurface(surface)
        }
        return ResolvedCopyReference(
            surface: surface,
            localizationKey: key,
            catalogID: catalogID,
            compatibilityID: compatibilityID
        )
    }

    /// Resolves a surface whose approved key a component already declared.
    ///
    /// Used where a domain value carries a copy key chosen by a release artifact - an
    /// apparent-inconsistency notice, for example. The declared key has to be the key
    /// the catalogue approved for that surface; anything else would show an
    /// unapproved sentence under an approved label, so it is refused rather than
    /// preferred or merged.
    public func reference(
        for surface: VerdictCopySurface,
        declaredKey: ApprovedCopyKey
    ) throws(PresentationCopyError) -> ResolvedCopyReference {
        let resolved = try reference(for: surface)
        guard resolved.localizationKey == declaredKey else {
            throw .unapprovedCopyKey(
                surface: surface,
                declared: declaredKey,
                approved: resolved.localizationKey
            )
        }
        return resolved
    }

    /// The approved key for one reachable surface, or `nil` when unreachable or
    /// uncovered.
    ///
    /// A non-throwing probe for callers that are deciding whether to render a section
    /// at all. It is not a lookup shortcut: rendering still goes through
    /// ``reference(for:)`` so a gap cannot become a silent omission.
    public func localizationKey(for surface: VerdictCopySurface) -> ApprovedCopyKey? {
        guard reachableSurfaces.contains(surface) else { return nil }
        return keysBySurface[surface]
    }
}
