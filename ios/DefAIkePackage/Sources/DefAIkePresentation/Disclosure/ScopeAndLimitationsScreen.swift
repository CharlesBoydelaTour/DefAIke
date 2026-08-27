import DefAIkeDomain

// The evidence scope, the unsupported Version 1 scopes, and what pixel evidence does not
// establish.
//
// Requirement 1.10 requires the Result Presenter to identify a specific list of unsupported
// Version 1 scopes. Requirement 1.15 requires it to state that pixel evidence is
// probabilistic and does not establish authenticity, authorship, intent, editing history, or
// the absence of localized editing. Requirements 8.10 and 8.11 put the scope statement and
// the false-result statement in every Evidence Report, and task 11.3 already resolves both
// there; this screen is the destination Requirement 8.17 names, where the same limitations
// are readable outside a single report.
//
// Three of the four things this screen needs are resolvable today:
//
//   * the approved evidence-scope statement, which is the sentence Requirement 8.10 fixes;
//   * the approved false-result statement (Requirement 8.11); and
//   * all three approved pixel explanations, which is where Requirements 8.3 through 8.5
//     put the probabilistic framing and the "not proof of authenticity" framing that
//     Requirement 1.15 asks for. Resolving all three rather than the session's own label is
//     deliberate: this screen explains the labels as a set, so a reader can see what each
//     one does and does not mean without running three sessions.
//
// The fourth is not. Nothing in the closed approved-copy vocabulary states that pixel
// evidence establishes neither authorship nor intent nor editing history. The parts that do
// exist cannot be glued into that sentence either - the design forbids assembling
// user-facing text from fragments, because a joined sentence fixes English word order in the
// code where no translation can reach it. So Requirement 1.15 is satisfied in part and
// recorded as blocked in part, and ``UnapprovedDisclosureSurface`` names which part.
//
// The structured scope sets travel beside the approved sentence, taken from the session's own
// bound Evidence Scope rather than restated here. The domain refuses a scope that omits a
// required covered or uncovered statement, so "the screen states the whole scope" is checked
// before the screen exists rather than by reading English.
//
// One limit of the structured vocabulary is worth stating plainly, because a reader of this
// screen might otherwise assume more precision than exists: Requirement 1.10 names Files
// ingest, paste ingest, drag-and-drop ingest, and camera capture individually, and the
// domain's closed statement vocabulary has one member covering every route outside the
// Photos picker and the Share Extension. The structured value therefore excludes all four
// collectively, and naming them individually is something the approved scope statement does
// in words. That is a property of the artifact vocabulary, not something this screen may fix
// by inventing four more statements.

/// One property pixel evidence does not establish (Requirement 1.15).
///
/// A closed set, so a test can assert that the screen accounts for all five rather than
/// checking a paragraph for nouns. It records what must be said; it is not itself a sentence,
/// and no wording for it exists - see
/// ``UnapprovedDisclosureSurface/pixelEvidenceNonEstablishmentStatement``.
public enum UnestablishedByPixelEvidence: String, Hashable, Sendable, CaseIterable {
    /// That the image is authentic, genuine, or unmanipulated.
    case authenticity

    /// Who created or captured the depicted image.
    case authorship

    /// Why the image was made or shared.
    case intent

    /// The complete sequence of edits applied to the image.
    case editingSequence = "editing-sequence"

    /// That no localized editing occurred.
    case absenceOfLocalizedEditing = "absence-of-localized-editing"

    /// Whether an approved surface already frames this property for a pixel label.
    ///
    /// Requirements 8.3 through 8.5 fix the framing for certainty and authenticity in the
    /// three approved pixel explanations, and Requirement 8.10's scope statement carries the
    /// localized-edit exclusion. The other two have no approved framing at all, which is why
    /// Requirement 1.15 is only partly satisfiable today.
    public var hasApprovedFraming: Bool {
        switch self {
        case .authenticity, .absenceOfLocalizedEditing: true
        case .authorship, .intent, .editingSequence: false
        }
    }
}

/// How pixel evidence relates to what it reports (Requirement 1.15).
///
/// One case by construction. Pixel evidence is probabilistic evidence rather than proof, and
/// there is no value here for a certain, definitive, or conclusive result - so the screen
/// cannot describe the evidence as anything stronger than it is.
public enum PixelEvidenceStrength: String, Hashable, Sendable, CaseIterable {
    /// Probabilistic evidence, never proof.
    case probabilisticEvidence = "probabilistic-evidence"
}

/// One approved pixel label explanation, addressed by label.
///
/// The label is the domain's own key and the explanation is an approved address, so this pair
/// cannot drift: a label with a different explanation is a different key, and the copy
/// binding refuses a key the catalogue never approved for that surface.
public struct PixelLabelExplanation: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// Which of the three labels this explains.
    public let label: PixelLabelKey

    /// The exact required display string for that label (Requirement 8.2).
    ///
    /// Carried rather than looked up again, so the explanation and the label a reader sees
    /// beside it come from one place.
    public let labelText: FixedPixelLabelText

    /// Approved copy explaining what that label does and does not mean
    /// (Requirements 8.3 through 8.5).
    public let explanationCopy: ResolvedCopyReference

    init(label: PixelLabelKey, explanationCopy: ResolvedCopyReference) {
        self.label = label
        self.labelText = FixedPixelLabelText(label: label)
        self.explanationCopy = explanationCopy
    }
}

// MARK: - The screen

/// The evidence scope and limitations destination (Requirements 1.10, 1.15, 8.10, 8.11,
/// and 8.17).
public struct ScopeAndLimitationsScreen: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// Surfaces this screen needs and the approved vocabulary does not define. Nothing is
    /// rendered for them.
    public static let unapprovedSurfaces: Set<UnapprovedDisclosureSurface> = [
        .unsupportedScopeItemLabel,
        .pixelEvidenceNonEstablishmentStatement,
    ]

    /// The structured scope the session was bound to.
    ///
    /// The domain rejects a scope missing any required covered or uncovered statement, so
    /// this value cannot understate the limits (Requirement 8.10).
    public let scope: EvidenceScope

    /// Approved copy stating the evidence scope and the unsupported scopes
    /// (Requirement 8.10).
    public let scopeCopy: ResolvedCopyReference

    /// Approved copy stating that false-positive and false-negative results can occur
    /// (Requirement 8.11).
    public let falseResultCopy: ResolvedCopyReference

    /// All three approved label explanations, in the domain's declaration order.
    public let labelExplanations: [PixelLabelExplanation]

    /// How strong pixel evidence is (Requirement 1.15).
    public let evidenceStrength: PixelEvidenceStrength

    /// The five properties pixel evidence does not establish, in declaration order
    /// (Requirement 1.15).
    public let unestablishedProperties: [UnestablishedByPixelEvidence]

    init(
        scope: EvidenceScope,
        scopeCopy: ResolvedCopyReference,
        falseResultCopy: ResolvedCopyReference,
        labelExplanations: [PixelLabelExplanation]
    ) {
        self.scope = scope
        self.scopeCopy = scopeCopy
        self.falseResultCopy = falseResultCopy
        self.labelExplanations = labelExplanations
        self.evidenceStrength = .probabilisticEvidence
        self.unestablishedProperties = UnestablishedByPixelEvidence.allCases
    }

    // MARK: - Scope

    /// The scopes this evidence covers, in the domain's declaration order.
    ///
    /// Ordered by the closed statement vocabulary rather than by anything derived from
    /// English, so the order is stable under localization.
    public var coveredScopes: [AnalysisScopeStatement] {
        AnalysisScopeStatement.allCases.filter(scope.includedStatements.contains)
    }

    /// The scopes this evidence does not cover, in the domain's declaration order
    /// (Requirement 1.10).
    public var uncoveredScopes: [AnalysisScopeStatement] {
        AnalysisScopeStatement.allCases.filter(scope.excludedStatements.contains)
    }

    // MARK: - Audits

    /// Whether every scope statement Requirement 8.10 requires is stated.
    ///
    /// Always true for a constructible value, because the domain enforces it. Exposed so a
    /// release audit can assert it over a real screen rather than trusting the domain check
    /// ran.
    public var statesEveryRequiredScope: Bool {
        EvidenceScope.requiredIncludedStatements.isSubset(of: scope.includedStatements)
            && EvidenceScope.requiredExcludedStatements.isSubset(of: scope.excludedStatements)
    }

    /// Whether all three approved label explanations are present.
    public var explainsEveryPixelLabel: Bool {
        Set(labelExplanations.map(\.label)) == Set(PixelLabelKey.allCases)
    }

    /// Whether every property Requirement 1.15 names is accounted for.
    public var accountsForEveryUnestablishedProperty: Bool {
        Set(unestablishedProperties) == Set(UnestablishedByPixelEvidence.allCases)
    }

    /// The properties Requirement 1.15 names that no approved surface frames, in declaration
    /// order.
    ///
    /// Nonempty today, and that is the honest report: the screen accounts for all five
    /// structurally and can state only three of them in approved words.
    public var propertiesWithoutApprovedFraming: [UnestablishedByPixelEvidence] {
        unestablishedProperties.filter { !$0.hasApprovedFraming }
    }

    /// The destinations this screen answers for (Requirement 8.17).
    public var destinations: [RequiredDisclosureDestination] {
        RequiredDisclosureDestination.allCases.filter { $0.screen == .scopeAndLimitations }
    }
}

// MARK: - Assembly

extension ScopeAndLimitationsScreen {
    /// Projects the scope-and-limitations screen from one checked input.
    ///
    /// No branch. The scope statement, the false-result statement, and all three label
    /// explanations are resolved unconditionally, so there is no condition under which a
    /// limitation is skipped; a surface the bound catalogue does not cover is a fail-closed
    /// error rather than a quiet omission.
    static func projecting(
        _ input: DisclosureScreenInput
    ) throws(PresentationCopyError) -> ScopeAndLimitationsScreen {
        var explanations: [PixelLabelExplanation] = []
        explanations.reserveCapacity(PixelLabelKey.allCases.count)
        for label in PixelLabelKey.allCases {
            explanations.append(
                PixelLabelExplanation(
                    label: label,
                    explanationCopy: try input.copy.reference(for: .pixelExplanation(label))
                )
            )
        }

        return ScopeAndLimitationsScreen(
            scope: input.scope,
            scopeCopy: try input.copy.reference(for: .evidenceScope),
            falseResultCopy: try input.copy.reference(for: .falseResultLimitation),
            labelExplanations: explanations
        )
    }
}
