// Validating one candidate Evidence Fusion Rule, and looking a combination up in it.
//
// `ReleaseArtifacts/EvidenceFusionRule.swift` is the *schema*: it proves that an entry
// list covers the exact 3 x 5 key space once each, and nothing more. Coverage alone does
// not make a rule usable. A rule can cover all 15 combinations while
//
//   * carrying a rejection in its own approval record, because presence in a build is
//     never approval;
//   * naming copy keys no approved catalogue has a Combined Summary surface for, which is
//     free-form copy wearing an identifier;
//   * naming a catalogue this session's Model Bundle and capability set were never
//     compatible with; or
//   * citing fixtures that do not exist, or that demonstrate some other combination than
//     the one the entry maps.
//
// Each of those is Requirement 7.15's "lacks deterministic behavior or an approved fixture
// result", and each is refused here. ``ApprovedFusionRule`` is the only way to hold a rule
// that passed all of it, so "this rule may produce a Combined Summary" is a type rather
// than a convention.
//
// # The lookup is a total map, not a search
//
// The schema's own `disposition(for:)` scans the entry list and force-unwraps on the
// coverage proof. That is total, but it is total *because* of an invariant a reader has to
// go and verify. Validation here builds the 15 entries into one fixed-size row-major
// table addressed by a computed index, so lookup is an array read at an index the type
// system bounds. There is no `default`, no fallback, no optional to unwrap, and no
// dictionary miss to handle: the table has exactly one slot per combination and every
// combination computes to exactly one slot.
//
// # What this file does not decide
//
// Which disposition belongs to which combination. The 15 mappings are an unresolved,
// externally approved input, and there is no default entry, no "omit unless stated", and
// no inferred pairing anywhere below. A release that has not approved a rule has none,
// which ``OptionalFusion`` represents without inventing an empty table.

// MARK: - Table index

extension FusionLaneCombination {
    /// This combination's slot in a row-major 3 x 5 table.
    ///
    /// Both factors are closed `CaseIterable` vocabularies whose `allCases` order is fixed
    /// by their declaration order, so the index is stable for one source revision. It is
    /// an implementation detail of the table and is deliberately not public: nothing
    /// outside this file may address a disposition by number.
    ///
    /// Each ordinal is the count of cases preceding the one asked for, which is that
    /// case's position in `allCases`. Written that way rather than with
    /// `firstIndex(of:)!`, so the arithmetic needs no force unwrap: a case is always
    /// present in its own `allCases`, but this file states that structurally instead of
    /// asserting it.
    ///
    /// Row-major with the pixel label as the outer factor, matching the order
    /// ``allCombinations`` is built in, so slot `i` holds `allCombinations[i]`.
    static func tableIndex(pixel: PixelLabelKey, provenance: ProvenanceStateKey) -> Int {
        let pixelOrdinal = PixelLabelKey.allCases.prefix { $0 != pixel }.count
        let provenanceOrdinal = ProvenanceStateKey.allCases.prefix { $0 != provenance }.count
        return pixelOrdinal * ProvenanceStateKey.allCases.count + provenanceOrdinal
    }

    /// This combination's slot in a row-major 3 x 5 table.
    var tableIndex: Int { Self.tableIndex(pixel: pixel, provenance: provenance) }
}

// MARK: - Attributed lookup result

/// One looked-up fusion entry, attributed to the exact rule artifact that produced it.
///
/// Requirement 7.11 requires a displayed summary to be identified as a Combined Summary
/// *and* to show the rule version, so the version travels with the entry rather than being
/// fetched separately later. ``CombinedSummary`` records the rule's artifact identifier;
/// this adds the semantic version that identifier resolved to, which is what an audit
/// reads when it asks which approved mapping produced a sentence.
///
/// An omitting entry is still attributed. "This rule decided to say nothing here" and "no
/// rule was consulted" are different facts, and only the first has a rule version.
public struct AttributedFusionEntry: Hashable, Sendable {
    /// The single entry the rule holds for this combination, unchanged.
    public let entry: FusionEntry

    /// The rule artifact this entry came from.
    public let ruleID: ArtifactID

    /// That rule's version, for the displayed attribution (Requirement 7.11).
    public let ruleVersion: SchemaSemanticVersion

    init(entry: FusionEntry, ruleID: ArtifactID, ruleVersion: SchemaSemanticVersion) {
        self.entry = entry
        self.ruleID = ruleID
        self.ruleVersion = ruleVersion
    }

    /// The combination this entry answers for.
    public var combination: FusionLaneCombination { entry.combination }

    /// The approved fixture that demonstrated this entry's behavior.
    public var fixture: FixtureID { entry.fixture }

    /// The summary to show, or `nil` when the approved entry is explicit omission.
    ///
    /// `nil` here is a decision the rule wrote down, not a gap: ``FusionDisposition/omit``
    /// had to be authored for this combination for the table to validate at all.
    public var summary: CombinedSummary? {
        switch entry.disposition {
        case .omit:
            return nil
        case let .show(copyKey):
            return CombinedSummary(copyKey: copyKey, fusionRuleID: ruleID)
        }
    }
}

// MARK: - Validated rule

/// A candidate Evidence Fusion Rule that passed every fusion criterion.
///
/// Holding this value means: the rule's own approval record approves it and resolves to
/// evidence this release carries; it covers all 15 enabled lane combinations exactly once
/// with no default branch; every shown disposition names an ``ApprovedCopyKey`` the
/// compatible Approved Verdict Copy catalogue has a Combined Summary surface for; and
/// every entry cites a catalogued fixture that demonstrates that entry's own combination
/// (Requirements 7.12, 7.14, 7.15, and 7.17).
///
/// It conforms to ``EvidenceFusing``, so the composition root injects the validated rule
/// itself as the fusion port rather than a resolver that could be handed an unvalidated
/// one.
public struct ApprovedFusionRule: EvidenceFusing, Hashable, Sendable {
    /// The rule, unchanged. Validation never repairs, reorders, or fills an entry.
    public let rule: EvidenceFusionRule

    /// The approved catalogue every shown copy key was resolved against.
    public let verdictCopyCatalog: ArtifactID

    /// The catalogue's compatibility identifier, which a session's Model Bundle and
    /// capability set must match (Requirement 8.1).
    public let verdictCopyCompatibilityID: ArtifactID

    /// The fixture suite every entry's fixture was found in.
    public let fixtureSuite: ArtifactID

    /// The 15 entries in row-major combination order: one slot per combination, always
    /// populated.
    ///
    /// Private, because the ordering is how lookup stays total and nothing outside this
    /// type should depend on it. ``entries`` exposes the same values in the same order for
    /// a reader that wants to enumerate them.
    private let table: [FusionEntry]

    /// Validates `candidate` for use in this release.
    ///
    /// Fails closed with one ``ArtifactSchemaError`` naming the offending field, so an
    /// audit can point at one entry rather than reporting "invalid fusion rule". A failure
    /// is never an ``AnalysisError`` and never a ``FusionFault``: a rule that does not
    /// validate produces no Combined Summary and blocks nothing else, which is what
    /// ``OptionalFusion`` is for.
    ///
    /// The catalogue and the suite are required inputs rather than things looked up here.
    /// A validator that accepted only a rule would have to trust the rule's own account of
    /// which copy and which fixtures approved it, which is the circularity the
    /// compatibility identifiers exist to break.
    public init(
        validating candidate: EvidenceFusionRule,
        verdictCopy catalog: ApprovedVerdictCopyCatalog,
        fixtures suite: ReleaseFixtureSuite,
        evidence index: ReleaseEvidenceIndex
    ) throws {
        try Self.validateApproval(candidate, catalog: catalog, against: index)
        try Self.validateReferences(candidate, catalog: catalog, suite: suite)
        let table = try Self.validatedTable(candidate, catalog: catalog, suite: suite)

        self.rule = candidate
        self.verdictCopyCatalog = catalog.id
        self.verdictCopyCompatibilityID = catalog.compatibilityID
        self.fixtureSuite = suite.id
        self.table = table
    }

    // MARK: Accessors

    /// The rule's artifact identifier, matching an ``AnalysisSessionBinding``.
    public var id: ArtifactID { rule.id }

    /// The version a displayed summary is attributed to (Requirement 7.11).
    public var ruleVersion: SchemaSemanticVersion { rule.ruleVersion }

    /// The 15 validated entries in row-major combination order.
    public var entries: [FusionEntry] { table }

    // MARK: Approval

    /// Requirements 7.9 and 7.15: presence in a build is not approval.
    ///
    /// Three separate refusals. A rule carrying a rejection is the release decision that
    /// this mapping may not be used, written down; an approval nobody can find at the
    /// cited version and digest is a synthesized approval; and a catalogue that is itself
    /// unapproved cannot approve the copy a summary would show, so its keys are not
    /// approved copy no matter how well they resolve.
    private static func validateApproval(
        _ candidate: EvidenceFusionRule,
        catalog: ApprovedVerdictCopyCatalog,
        against index: ReleaseEvidenceIndex
    ) throws {
        guard candidate.approval.isApproved else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "fusionRule.approval.decision",
                value: candidate.approval.decision.rawValue,
                reason: "an unapproved fusion rule may not produce a Combined Summary"
            )
        }
        try index.requireResolved(
            candidate.approval.source,
            field: "fusionRule.approval.source"
        )
        guard catalog.approval.isApproved else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "fusionRule.verdictCopy.approval.decision",
                value: catalog.approval.decision.rawValue,
                reason: "an unapproved copy catalogue approves no Combined Summary wording"
            )
        }
    }

    // MARK: References

    /// Requirements 7.14, 7.15, and 8.1: the rule was validated against the copy and the
    /// fixtures it names.
    ///
    /// Both are checked in the direction that matters: the rule names a catalogue and a
    /// suite, and the values supplied have to be those. Validating against some other
    /// catalogue would approve keys the rule never claimed compatibility with, and
    /// validating against some other suite would find fixtures that demonstrate a
    /// different release's behavior.
    ///
    /// The suite's provenance applicability is required, and that is the coupling
    /// Requirement 7.10 implies at release scope: fusion reads a provenance state for
    /// every one of its 15 combinations, so a suite with no applicable provenance decision
    /// cannot hold a fixture for any of them.
    private static func validateReferences(
        _ candidate: EvidenceFusionRule,
        catalog: ApprovedVerdictCopyCatalog,
        suite: ReleaseFixtureSuite
    ) throws {
        try ArtifactSchemaValidation.requireMatchingReference(
            catalog.compatibilityID,
            matches: candidate.compatibleVerdictCopy,
            field: "fusionRule.compatibleVerdictCopy"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            suite.id,
            matches: candidate.fixtureSuite,
            field: "fusionRule.fixtureSuite"
        )
        guard suite.provenanceApplicability.isApplicable else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "fusionRule.fixtureSuite.provenanceApplicability",
                value: "not-applicable",
                reason: """
                    every fusion combination names a provenance state, so a suite without \
                    an applicable provenance decision can demonstrate none of them
                    """
            )
        }
    }

    // MARK: The table

    /// Builds the total 15-slot table, refusing any entry that is not fixture-approved.
    ///
    /// Driven by ``FusionLaneCombination/allCombinations`` rather than by the candidate's
    /// entry list, which is what makes the result total by construction: every slot is
    /// filled from a required combination, so an omission is a missing slot rather than a
    /// short array. The schema already proved exact coverage, so the lookup below finds
    /// each one; doing it in this direction means the table cannot be built from a rule
    /// that only *mostly* covers the space, even if that schema check were ever relaxed.
    private static func validatedTable(
        _ candidate: EvidenceFusionRule,
        catalog: ApprovedVerdictCopyCatalog,
        suite: ReleaseFixtureSuite
    ) throws -> [FusionEntry] {
        var table: [FusionEntry] = []
        table.reserveCapacity(FusionLaneCombination.requiredCombinationCount)
        for combination in FusionLaneCombination.allCombinations {
            let matches = candidate.entries.filter { $0.combination == combination }
            guard let entry = matches.first else {
                throw ArtifactSchemaError.missingRequiredEntries(
                    field: "fusionRule.entries",
                    keys: [combination.description]
                )
            }
            guard matches.count == 1 else {
                throw ArtifactSchemaError.duplicateEntry(
                    field: "fusionRule.entries",
                    key: combination.description
                )
            }
            try validateDisposition(entry, catalog: catalog)
            try validateFixture(entry, suite: suite)
            table.append(entry)
        }
        return table
    }

    /// Requirements 7.12 and 7.17: a shown disposition names copy the catalogue approved.
    ///
    /// ``FusionDisposition`` already makes literal user-facing text unrepresentable — it
    /// carries an ``ApprovedCopyKey``, which is a canonical identifier and cannot hold a
    /// sentence — so what is left to check is that the key is not merely well formed. A
    /// key with no Combined Summary surface in the catalogue is copy nobody approved, and
    /// rendering would refuse it later; refusing it here means an unapproved claim fails
    /// the rule rather than one combination at display time.
    ///
    /// An omitting entry needs no key, and requiring one would be inventing a wording for
    /// a decision to say nothing.
    private static func validateDisposition(
        _ entry: FusionEntry,
        catalog: ApprovedVerdictCopyCatalog
    ) throws {
        guard case let .show(copyKey) = entry.disposition else { return }
        let field = "fusionRule.entries[\(entry.combination.description)].disposition"
        try ArtifactSchemaValidation.requireDecidedReference(copyKey, field: "\(field).copyKey")
        guard catalog.localizationKey(for: .combinedSummary(copyKey)) != nil else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: field,
                keys: [VerdictCopySurface.combinedSummary(copyKey).description]
            )
        }
    }

    /// Requirements 7.14 and 7.15: this entry's behavior was demonstrated by a fixture for
    /// *this* combination.
    ///
    /// A `FixtureID` on an entry is a reference, and a reference is not a result. Three
    /// refusals:
    ///
    ///   * the fixture is not catalogued at all, so no approved result exists;
    ///   * it declares a pixel label or a provenance state other than this entry's, so it
    ///     demonstrates a different combination;
    ///   * it declares no pixel label at all, so it says nothing about which of the three
    ///     labels this combination pairs; or
    ///   * it declares two different labels or two different states, so which combination
    ///     it demonstrates has no single answer. Picking one of the two would decide by
    ///     iteration order what a release approved.
    ///
    /// Entry-level fixture uniqueness needs no separate rule and is not asserted as one:
    /// a fixture declares one label and one state, so two entries citing the same fixture
    /// cannot both name the combination it demonstrates.
    private static func validateFixture(
        _ entry: FusionEntry,
        suite: ReleaseFixtureSuite
    ) throws {
        let field = "fusionRule.entries[\(entry.combination.description)].fixture"
        try ArtifactSchemaValidation.requireDecidedReference(entry.fixture, field: field)
        guard let fixture = suite.fixtures.first(where: { $0.id == entry.fixture }) else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: field,
                keys: [entry.fixture.rawValue]
            )
        }

        var labels: Set<PixelLabelKey> = []
        var states: Set<ProvenanceStateKey> = []
        for expectation in fixture.expectations {
            switch expectation {
            case let .pixelLabel(label): labels.insert(label)
            case let .provenanceState(state): states.insert(state)
            case .rawLogit, .preprocessingOutputDigest, .retainedBytesDigest,
                 .bytePreservationStatus, .analysisError:
                continue
            }
        }
        guard labels.count <= 1 else {
            throw ArtifactSchemaError.duplicateEntry(
                field: "\(field).expectations.pixelLabel",
                key: labels.map(\.rawValue).sorted().joined(separator: ",")
            )
        }
        guard states.count <= 1 else {
            throw ArtifactSchemaError.duplicateEntry(
                field: "\(field).expectations.provenanceState",
                key: states.map(\.rawValue).sorted().joined(separator: ",")
            )
        }

        guard let declaredLabel = labels.first else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: "\(field).expectations",
                keys: ["pixelLabel"]
            )
        }
        guard declaredLabel == entry.combination.pixel else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).expectations.pixelLabel",
                expected: entry.combination.pixel.rawValue,
                found: declaredLabel.rawValue
            )
        }
        guard let declaredState = states.first else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: "\(field).expectations",
                keys: ["provenanceState"]
            )
        }
        guard declaredState == entry.combination.provenance else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).expectations.provenanceState",
                expected: entry.combination.provenance.rawValue,
                found: declaredState.rawValue
            )
        }
    }
}

// MARK: - Lookup

extension ApprovedFusionRule {
    /// The single entry for one enabled lane combination, attributed to this rule.
    ///
    /// Total and pure: one array read at a computed index, no default branch, no optional,
    /// and no search. Calling it twice with the same combination returns the same value,
    /// because there is nothing here to read a clock, a set's iteration order, or any
    /// state.
    public func attributedEntry(for combination: FusionLaneCombination) -> AttributedFusionEntry {
        AttributedFusionEntry(
            entry: table[combination.tableIndex],
            ruleID: rule.id,
            ruleVersion: rule.ruleVersion
        )
    }

    /// The single disposition for one enabled lane combination. Total by construction.
    public func disposition(for combination: FusionLaneCombination) -> FusionDisposition {
        attributedEntry(for: combination).entry.disposition
    }

    /// The attributed entry for one pixel label beside one enabled provenance state.
    public func attributedEntry(
        pixel: PixelEvidence,
        provenance: ProvenanceEvidence
    ) -> AttributedFusionEntry {
        attributedEntry(for: .lookupKey(pixel: pixel, provenance: provenance))
    }

    /// The attributed entry for one pixel label beside a provenance *lane*, or `nil` when
    /// the lane is unavailable.
    ///
    /// The unavailable bypass is the whole point of this overload, and it happens before
    /// the table is addressed: the guard returns without computing an index, so an
    /// unavailable lane is never looked up rather than being looked up and discarded
    /// (Requirement 7.10). It is not a finding about the image, and there is no
    /// combination it belongs to — ``ProvenanceStateKey`` has no unavailable case, so
    /// there is no slot for one either.
    public func attributedEntry(
        pixel: PixelEvidence,
        provenance: ProvenanceLane
    ) -> AttributedFusionEntry? {
        guard let evidence = provenance.evidence else { return nil }
        return attributedEntry(pixel: pixel, provenance: evidence)
    }

    // MARK: The fusion port

    /// Requirements 7.9 through 7.13.
    ///
    /// `rule` is the Evidence Fusion Rule the Analysis Session was bound to. It has to be
    /// the rule this value validated: a session's summary is attributed to a rule version,
    /// so resolving a session's lanes against a different rule — one activated after the
    /// session started, or one that never passed validation — would attribute a sentence
    /// to a mapping that did not produce it. Whole-value equality rather than identifier
    /// equality, because two different entry tables published under one identifier is
    /// exactly the substitution the check exists to catch.
    public func resolve(
        pixel: PixelEvidence,
        provenance: ProvenanceEvidence,
        rule candidate: EvidenceFusionRule,
        binding: AnalysisSessionBinding
    ) throws(FusionFault) -> CombinedSummary? {
        guard candidate == rule, binding.fusionRuleID == rule.id else {
            throw .ruleNotBoundToSession(expected: binding.fusionRuleID, found: candidate.id)
        }
        guard binding.verdictCopyCompatibilityID == verdictCopyCompatibilityID else {
            throw .incompatibleVerdictCopy(
                expected: binding.verdictCopyCompatibilityID,
                found: verdictCopyCompatibilityID
            )
        }
        return attributedEntry(pixel: pixel, provenance: provenance).summary
    }
}
