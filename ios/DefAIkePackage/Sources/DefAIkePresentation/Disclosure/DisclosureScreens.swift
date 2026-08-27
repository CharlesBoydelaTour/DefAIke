import DefAIkeDomain

// The four disclosure destinations, projected together from one input.
//
// They are one value rather than four independent projections for the same reason
// ``AnalysisScreen``'s families are one enum: the requirement is about *totality*.
// Requirement 8.17 requires a user-accessible path from every Evidence Report to six
// destinations, and a design where each destination is built on demand can satisfy five of
// them and fail the sixth without anything noticing. Here all four members are non-optional,
// so a build either has every destination or has none - and "has none" is a thrown refusal a
// release audit reads, not a screen a user reaches and finds empty.
//
// The projection is pure, total over a checked input, and independent of when it runs. It
// touches no file, no clock, no network, and no coordinator; the same input projects to the
// same value forever, which is what lets task 11.8 snapshot these screens on the host.
//
// Every refusal happens once, up front, before any screen exists:
//
//   * five records have to agree about the session, the capability manifest, and the
//     lifecycle policy;
//   * the governance record has to disclose the model the session ran under; and
//   * the release has to have actually published the versioned active known limitations and
//     the correction channel.
//
// After that, resolving a screen cannot fail for a coherence reason, because a coherence
// failure was already refused. What resolution can still refuse is an approved surface the
// bound catalogue does not cover, which the copy layer reports unchanged.
//
// What is deliberately absent from every screen here: a control that leaves the destination
// with data. There is no member on any of the four that a save, export, pasteboard, share,
// history, or telemetry affordance could hang from, which is the same structural guarantee
// ``ExcludedResultControl`` records for the result surface.

/// The four destinations Requirement 8.17's paths lead to, as one value.
public struct DisclosureScreens: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// Every surface these destinations need and cannot show, in stable order.
    ///
    /// The union of the four screens' own recorded gaps, which is the list a release audit
    /// reads to see what the approved-copy decision and the release artifacts still owe these
    /// requirements.
    public static var unapprovedSurfaces: Set<UnapprovedDisclosureSurface> {
        PrivacyDisclosureScreen.unapprovedSurfaces
            .union(ModelInformationScreen.unapprovedSurfaces)
            .union(ScopeAndLimitationsScreen.unapprovedSurfaces)
            .union(CorrectionChannelScreen.unapprovedSurfaces)
    }

    /// The in-application privacy explanation (Requirement 9.16).
    public let privacy: PrivacyDisclosureScreen

    /// Model identity and release status (Requirements 8.17 and 14.9).
    public let modelInformation: ModelInformationScreen

    /// The evidence scope and limitations (Requirements 1.10, 1.15, 8.10, and 8.11).
    public let scopeAndLimitations: ScopeAndLimitationsScreen

    /// The externally supplied correction channel (Requirement 14.14).
    public let correctionChannel: CorrectionChannelScreen

    /// The session these destinations were reached from.
    ///
    /// Held so a caller can check that a destination belongs to the session whose report it
    /// was opened from, exactly as the report layer checks its own binding.
    public let sessionID: AnalysisSessionID

    init(
        privacy: PrivacyDisclosureScreen,
        modelInformation: ModelInformationScreen,
        scopeAndLimitations: ScopeAndLimitationsScreen,
        correctionChannel: CorrectionChannelScreen,
        sessionID: AnalysisSessionID
    ) {
        self.privacy = privacy
        self.modelInformation = modelInformation
        self.scopeAndLimitations = scopeAndLimitations
        self.correctionChannel = correctionChannel
        self.sessionID = sessionID
    }

    // MARK: - Reachability

    /// Which screen presents one required destination (Requirement 8.17).
    ///
    /// Total, with no optional result: every destination has a screen, and the mapping is the
    /// destination's own.
    public func screen(for destination: RequiredDisclosureDestination) -> DisclosureScreenKind {
        destination.screen
    }

    /// The approved copy reference one screen shows as its own statement.
    ///
    /// Total switch, no `default`, and no optional. The scope-and-limitations screen's own
    /// statement is the approved evidence-scope sentence, which is what Requirement 8.10
    /// fixes for exactly that content.
    public func statementCopy(for kind: DisclosureScreenKind) -> ResolvedCopyReference {
        switch kind {
        case .privacy: privacy.explanationCopy
        case .modelInformation: modelInformation.informationCopy
        case .scopeAndLimitations: scopeAndLimitations.scopeCopy
        case .correctionChannel: correctionChannel.channelCopy
        }
    }

    // MARK: - Audits

    /// Whether every destination Requirement 8.17 names is reachable.
    ///
    /// Always true for a constructible value, because all four members are non-optional and
    /// the destination-to-screen mapping is total. Exposed so a release audit can assert it
    /// over a real projection.
    public var reachesEveryRequiredDestination: Bool {
        let reached = Set(RequiredDisclosureDestination.allCases.map(\.screen))
        return reached == Set(DisclosureScreenKind.allCases)
    }

    /// Whether each screen is reached through the report path task 11.3 mapped its
    /// destinations to.
    ///
    /// Checks the two mappings against each other rather than restating either: for every
    /// destination, the path the report offers and the path its screen declares must be the
    /// same path. A disagreement would mean a report offering a path that leads somewhere
    /// else.
    public var pathMappingsAgree: Bool {
        RequiredDisclosureDestination.allCases.allSatisfy { destination in
            destination.path == destination.screen.entryPath
        }
    }

    /// Whether this projection makes the two disclosures Requirement 14.9 requires.
    public var makesTheRequiredGovernanceDisclosures: Bool {
        modelInformation.makesTheRequiredGovernanceDisclosures
    }
}

// MARK: - Projection

extension DisclosureScreens {
    /// Projects all four destinations from one input, or refuses.
    ///
    /// Pure and deterministic. Coherence is checked first and in one place, so no screen is
    /// built from records that disagree, and a refusal names one cause.
    public static func projecting(
        _ input: DisclosureScreenInput
    ) throws(DisclosureAssemblyError) -> DisclosureScreens {
        try checkCoherence(of: input)

        let privacy: PrivacyDisclosureScreen
        let limitations: ScopeAndLimitationsScreen
        do {
            privacy = try PrivacyDisclosureScreen.projecting(input)
            limitations = try ScopeAndLimitationsScreen.projecting(input)
        } catch {
            throw .copy(error)
        }

        return DisclosureScreens(
            privacy: privacy,
            modelInformation: try ModelInformationScreen.projecting(input),
            scopeAndLimitations: limitations,
            correctionChannel: try CorrectionChannelScreen.projecting(input),
            sessionID: input.session.sessionID
        )
    }

    /// Refuses an input whose records disagree about which session, capability set, or
    /// lifecycle policy this is.
    ///
    /// Each check names the disagreeing record rather than reconciling it. Version skew is not
    /// a renderable state: a privacy screen describing a capability set the session never ran
    /// under, or deadlines from a policy it was not bound to, would be confidently wrong.
    private static func checkCoherence(
        of input: DisclosureScreenInput
    ) throws(DisclosureAssemblyError) {
        guard input.copy.sessionID == input.session.sessionID else {
            throw .copyBindingSessionMismatch(
                session: input.session.sessionID,
                binding: input.copy.sessionID
            )
        }

        let manifestID = input.capabilities.id
        guard input.session.capabilityManifestID == manifestID else {
            throw .capabilityManifestMismatch(
                source: .sessionBinding,
                expected: manifestID,
                found: input.session.capabilityManifestID
            )
        }
        guard input.copy.capabilityManifestID == manifestID else {
            throw .capabilityManifestMismatch(
                source: .copyBinding,
                expected: manifestID,
                found: input.copy.capabilityManifestID
            )
        }
        guard input.release.capabilityManifest == manifestID else {
            throw .capabilityManifestMismatch(
                source: .releaseRecord,
                expected: manifestID,
                found: input.release.capabilityManifest
            )
        }

        guard input.session.lifecyclePolicyID == input.lifecyclePolicy.id else {
            throw .lifecyclePolicyMismatch(
                session: input.session.lifecyclePolicyID,
                supplied: input.lifecyclePolicy.id
            )
        }
    }
}
