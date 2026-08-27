import Foundation
import Testing
@testable import DefAIkeDomain

// Example tests for fusion validation and lookup.
//
// Two different claims are under test here, and they fail in opposite directions:
//
//   * A rule is usable only when it is approved, exhaustive, fixture-backed, and named in
//     approved copy. Each test below breaks exactly one of those and requires a refusal.
//   * A rule that is not usable costs the Combined Summary and nothing else. That half is
//     asserted positively: the release stays eligible and the report still carries both
//     source lanes in full.
//
// The exhaustive generated coverage belongs to Property 22 in task 9.8. These examples pin
// the individual refusals so a regression names one field.

// MARK: - Synthetic samples

/// Structurally valid, deliberately synthetic fusion inputs.
///
/// **No value here is an approved release decision.** The 15 mappings are an externally
/// approved, unresolved input, and the disposition pattern below is a mechanical
/// alternation chosen so that both ``FusionDisposition`` cases are exercised. It encodes no
/// judgement about which lane combination deserves a Combined Summary.
enum FusionSample {
    static let ruleIdentifier = "rule.fusion"
    static let approvalIdentifier = "approval.fusion"
    static let copyCompatibilityIdentifier = "copy.compatibility"
    static let suiteIdentifier = "suite.fixtures"

    /// The synthetic copy key for one combination's shown summary.
    static func copyKey(for combination: FusionLaneCombination) -> ApprovedCopyKey {
        Sample.copyKey("copy.fusion.\(combination.description)")
    }

    /// The synthetic fixture identifier demonstrating one combination.
    static func fixtureID(for combination: FusionLaneCombination) -> FixtureID {
        Sample.fixture("fixture.fusion.\(combination.description)")
    }

    /// A mechanical, non-approved disposition for one combination.
    ///
    /// Alternates on the combination's position so roughly half the table shows a summary
    /// and half omits one. The point is coverage of both cases, not a mapping.
    static func disposition(for combination: FusionLaneCombination) -> FusionDisposition {
        let position = FusionLaneCombination.allCombinations.prefix { $0 != combination }.count
        return position.isMultiple(of: 2) ? .show(copyKey(for: combination)) : .omit
    }

    /// The fixture family a synthetic fixture is filed under for one provenance state.
    ///
    /// Matching the family to the state keeps the samples readable. Nothing in the domain
    /// requires the correspondence, and this test file does not assert one.
    static func family(for state: ProvenanceStateKey) -> FixtureFamily {
        switch state {
        case .validated: .provenanceValidSigned
        case .invalid: .provenanceInvalid
        case .absent: .provenanceAbsent
        case .unsupported: .provenanceUnsupported
        case .indeterminate: .provenanceIndeterminate
        }
    }

    /// One fixture declaring exactly one pixel label and one provenance state.
    static func fixture(
        demonstrating combination: FusionLaneCombination,
        identifiedBy identifier: FixtureID? = nil,
        declaringPixelLabel: Bool = true
    ) throws -> FixtureRecord {
        var expectations: [FixtureExpectation] = [.provenanceState(combination.provenance)]
        if declaringPixelLabel {
            expectations.insert(.pixelLabel(combination.pixel), at: 0)
        }
        let resolved = identifier ?? fixtureID(for: combination)
        return try FixtureRecord(
            id: resolved,
            family: family(for: combination.provenance),
            assetPath: Sample.path("fixtures/fusion/\(combination.description).jpg"),
            contentDigest: Sample.digest("f"),
            byteCount: Sample.byteCount(),
            source: Sample.evidence("evidence.fixture"),
            expectations: expectations
        )
    }

    /// A suite holding one fixture per combination.
    static func fixtureSuite(
        provenanceApplicability: GateApplicability = .applicable,
        fixtures replacement: [FixtureRecord]? = nil
    ) throws -> ReleaseFixtureSuite {
        try ReleaseFixtureSuite(
            id: Sample.artifact(suiteIdentifier),
            schemaVersion: .v1,
            provenanceApplicability: provenanceApplicability,
            fixtures: try replacement
                ?? FusionLaneCombination.allCombinations.map { try fixture(demonstrating: $0) }
        )
    }

    /// A catalogue covering every unconditional surface plus every shown copy key.
    static func copyCatalog(
        approval decision: ApprovalDecision = .approved,
        compatibilityID: String = copyCompatibilityIdentifier,
        omittingSummarySurfaceFor omitted: FusionLaneCombination? = nil
    ) throws -> ApprovedVerdictCopyCatalog {
        var surfaces = VerdictCopySurface.unconditionalSurfaces
        for state in ProvenanceStateKey.allCases {
            surfaces.insert(.provenanceState(state))
        }
        for combination in FusionLaneCombination.allCombinations where combination != omitted {
            if case .show = disposition(for: combination) {
                surfaces.insert(.combinedSummary(copyKey(for: combination)))
            }
        }
        return try ApprovedVerdictCopyCatalog(
            id: Sample.artifact("catalog.verdict-copy"),
            schemaVersion: .v1,
            compatibilityID: Sample.artifact(compatibilityID),
            languageTag: Sample.text(ApprovedVerdictCopyCatalog.requiredLanguageTag),
            entries: Sample.copyEntries(surfaces: surfaces),
            approval: Sample.approval(decision)
        )
    }

    /// The 15 entries, optionally with one combination dropped or one field perturbed.
    static func entries(
        dropping dropped: FusionLaneCombination? = nil,
        fixtures overrides: [FusionLaneCombination: FixtureID] = [:],
        dispositions dispositionOverrides: [FusionLaneCombination: FusionDisposition] = [:]
    ) -> [FusionEntry] {
        FusionLaneCombination.allCombinations
            .filter { $0 != dropped }
            .map { combination in
                FusionEntry(
                    combination: combination,
                    disposition: dispositionOverrides[combination]
                        ?? disposition(for: combination),
                    fixture: overrides[combination] ?? fixtureID(for: combination)
                )
            }
    }

    static func candidate(
        identifier: String = ruleIdentifier,
        ruleVersion: String = "2.1.0",
        compatibleVerdictCopy: String = copyCompatibilityIdentifier,
        fixtureSuite suite: String = suiteIdentifier,
        entries replacement: [FusionEntry]? = nil,
        approval decision: ApprovalDecision = .approved,
        approvalEvidence: String = approvalIdentifier
    ) throws -> EvidenceFusionRule {
        try EvidenceFusionRule(
            id: Sample.artifact(identifier),
            schemaVersion: .v1,
            ruleVersion: Sample.version(ruleVersion),
            compatibleVerdictCopy: Sample.artifact(compatibleVerdictCopy),
            fixtureSuite: Sample.artifact(suite),
            entries: replacement ?? entries(),
            approval: Sample.approval(decision, identifier: approvalEvidence)
        )
    }

    static func evidenceIndex(
        omittingApproval: Bool = false,
        adding added: [EvidenceSource] = []
    ) throws -> ReleaseEvidenceIndex {
        try ReleaseEvidenceIndex(
            records: (omittingApproval ? [] : [Sample.evidence(approvalIdentifier)])
                + [Sample.evidence("evidence.fixture")]
                + added
        )
    }

    /// Validates the coherent baseline, or one deliberately broken variant of it.
    static func approved(
        candidate replacement: EvidenceFusionRule? = nil,
        verdictCopy catalog: ApprovedVerdictCopyCatalog? = nil,
        fixtures suite: ReleaseFixtureSuite? = nil,
        evidence index: ReleaseEvidenceIndex? = nil
    ) throws -> ApprovedFusionRule {
        try ApprovedFusionRule(
            validating: try replacement ?? candidate(),
            verdictCopy: try catalog ?? copyCatalog(),
            fixtures: try suite ?? fixtureSuite(),
            evidence: try index ?? evidenceIndex()
        )
    }

    /// The refusal a broken variant produced, or `nil` when it validated.
    static func refusal(_ build: () throws -> ApprovedFusionRule) -> ArtifactSchemaError? {
        do {
            _ = try build()
            return nil
        } catch let error as ArtifactSchemaError {
            return error
        } catch {
            return nil
        }
    }
}

// MARK: - Exhaustive coverage and lookup

@Suite("Approved fusion rule coverage and lookup")
struct ApprovedFusionRuleCoverageTests {

    @Test("A coherent rule validates and holds exactly one entry per enabled combination")
    func coherentRuleIsExhaustive() throws {
        let rule = try FusionSample.approved()
        #expect(rule.id == Sample.artifact(FusionSample.ruleIdentifier))
        #expect(rule.ruleVersion == Sample.version("2.1.0"))
        #expect(rule.verdictCopyCatalog == Sample.artifact("catalog.verdict-copy"))
        #expect(
            rule.verdictCopyCompatibilityID
                == Sample.artifact(FusionSample.copyCompatibilityIdentifier)
        )
        #expect(rule.fixtureSuite == Sample.artifact(FusionSample.suiteIdentifier))

        // Requirement 7.12: 3 pixel labels x 5 enabled provenance states, no more, no
        // fewer, and no slot left to a default.
        #expect(FusionLaneCombination.requiredCombinationCount == 15)
        #expect(rule.entries.count == 15)
        #expect(rule.entries.map(\.combination) == FusionLaneCombination.allCombinations)
    }

    @Test("Every combination looks up its own entry, attributed to this rule")
    func lookupIsTotalAndAttributed() throws {
        let rule = try FusionSample.approved()
        for combination in FusionLaneCombination.allCombinations {
            let looked = rule.attributedEntry(for: combination)
            // The table is addressed by computed index, so this is the assertion that the
            // arithmetic lands on the right slot for all 15 rather than only the first.
            #expect(looked.combination == combination)
            #expect(looked.ruleID == rule.id)
            #expect(looked.ruleVersion == rule.ruleVersion)
            #expect(looked.fixture == FusionSample.fixtureID(for: combination))
            #expect(looked.entry.disposition == FusionSample.disposition(for: combination))
        }
    }

    @Test("The lookup is deterministic and independent of the artifact's entry order")
    func lookupIsDeterministic() throws {
        let rule = try FusionSample.approved()
        let reversed = try FusionSample.approved(
            candidate: try FusionSample.candidate(entries: FusionSample.entries().reversed())
        )
        for combination in FusionLaneCombination.allCombinations {
            let first = rule.attributedEntry(for: combination)
            #expect(first == rule.attributedEntry(for: combination))
            #expect(first == reversed.attributedEntry(for: combination))
        }
    }

    @Test("Every enabled lane pair resolves through the same key the mapping publishes")
    func enabledLanePairsResolve() throws {
        let rule = try FusionSample.approved()
        for pixel in PixelEvidence.allCases {
            for evidence in SessionValue.enabledEvidence {
                let expected = FusionLaneCombination.lookupKey(pixel: pixel, provenance: evidence)
                let looked = rule.attributedEntry(pixel: pixel, provenance: evidence)
                #expect(looked.combination == expected)
                // Requirement 7.11: a shown summary is attributable to the exact rule.
                if let summary = looked.summary {
                    #expect(summary.fusionRuleID == rule.id)
                    #expect(summary.copyKey == FusionSample.copyKey(for: expected))
                } else {
                    #expect(rule.disposition(for: expected) == .omit)
                }
            }
        }
    }

    @Test("An explicit omission is still attributed to the rule that decided it")
    func explicitOmissionIsAttributed() throws {
        let combination = FusionLaneCombination.allCombinations[0]
        let rule = try FusionSample.approved(
            candidate: try FusionSample.candidate(
                entries: FusionSample.entries(dispositions: [combination: .omit])
            )
        )
        let looked = rule.attributedEntry(for: combination)
        // "This rule says nothing here" carries a rule version; "no rule was consulted"
        // has none. The two are different facts and stay distinguishable.
        #expect(looked.summary == nil)
        #expect(looked.entry.disposition == .omit)
        #expect(looked.ruleVersion == rule.ruleVersion)
    }

    @Test("A gap or a duplicate makes the candidate unrepresentable")
    func gapsAndDuplicatesRefused() throws {
        let dropped = FusionLaneCombination.allCombinations[7]
        // The schema refuses both before validation can see them, in process and on the
        // decoding path, which share this initializer. So there is no invalid table for a
        // lookup to fall through.
        #expect(throws: ArtifactSchemaError.missingRequiredEntries(
            field: "fusionEntries",
            keys: [dropped.description]
        )) {
            try FusionSample.candidate(entries: FusionSample.entries(dropping: dropped))
        }
        #expect(throws: ArtifactSchemaError.duplicateEntry(
            field: "fusionEntries",
            key: dropped.description
        )) {
            try FusionSample.candidate(
                entries: FusionSample.entries() + [
                    FusionEntry(
                        combination: dropped,
                        disposition: .omit,
                        fixture: FusionSample.fixtureID(for: dropped)
                    )
                ]
            )
        }
    }
}

// MARK: - Approval, copy, and fixtures

@Suite("Approved fusion rule validation")
struct ApprovedFusionRuleValidationTests {

    @Test("A rule carrying a rejection may not produce a summary")
    func unapprovedRuleRefused() throws {
        #expect(
            FusionSample.refusal {
                try FusionSample.approved(
                    candidate: try FusionSample.candidate(approval: .rejected)
                )
            } == .forbiddenValue(
                field: "fusionRule.approval.decision",
                value: "rejected",
                reason: "an unapproved fusion rule may not produce a Combined Summary"
            )
        )
    }

    @Test("An approval nobody can find is a synthesized approval")
    func unresolvableApprovalRefused() throws {
        #expect(
            FusionSample.refusal {
                try FusionSample.approved(
                    evidence: try FusionSample.evidenceIndex(omittingApproval: true)
                )
            } == .missingRequiredEntries(
                field: "fusionRule.approval.source",
                keys: [FusionSample.approvalIdentifier]
            )
        )
    }

    @Test("An unapproved copy catalogue approves no wording")
    func unapprovedCatalogRefused() throws {
        #expect(
            FusionSample.refusal {
                try FusionSample.approved(
                    verdictCopy: try FusionSample.copyCatalog(approval: .rejected)
                )
            } != nil
        )
    }

    @Test("A rule must be validated against the copy and the fixtures it names")
    func mismatchedReferencesRefused() throws {
        #expect(
            FusionSample.refusal {
                try FusionSample.approved(
                    verdictCopy: try FusionSample.copyCatalog(compatibilityID: "copy.other")
                )
            } == .inconsistentReference(
                field: "fusionRule.compatibleVerdictCopy",
                expected: FusionSample.copyCompatibilityIdentifier,
                found: "copy.other"
            )
        )
        #expect(
            FusionSample.refusal {
                try FusionSample.approved(
                    candidate: try FusionSample.candidate(fixtureSuite: "suite.other")
                )
            } == .inconsistentReference(
                field: "fusionRule.fixtureSuite",
                expected: "suite.other",
                found: FusionSample.suiteIdentifier
            )
        )
    }

    @Test("Free-form user-facing copy is unrepresentable, and an unapproved key is refused")
    func freeFormCopyRefused() throws {
        // Structural half: a disposition carries an `ApprovedCopyKey`, which is a canonical
        // identifier. A sentence is not one, so literal copy cannot be written down at all.
        #expect(ApprovedCopyKey("Signals consistent with AI generation") == nil)
        #expect(ApprovedCopyKey("This image was made by AI.") == nil)

        // Validated half: a well-formed key with no Combined Summary surface in the
        // approved catalogue is copy nobody approved.
        let shown = try #require(
            FusionLaneCombination.allCombinations.first {
                if case .show = FusionSample.disposition(for: $0) { return true }
                return false
            }
        )
        #expect(
            FusionSample.refusal {
                try FusionSample.approved(
                    verdictCopy: try FusionSample.copyCatalog(omittingSummarySurfaceFor: shown)
                )
            } == .missingRequiredEntries(
                field: "fusionRule.entries[\(shown.description)].disposition",
                keys: [VerdictCopySurface.combinedSummary(FusionSample.copyKey(for: shown))
                    .description]
            )
        )
    }

    @Test("An entry citing a fixture the suite does not hold is refused")
    func unfixturedEntryRefused() throws {
        let combination = FusionLaneCombination.allCombinations[3]
        #expect(
            FusionSample.refusal {
                try FusionSample.approved(
                    candidate: try FusionSample.candidate(
                        entries: FusionSample.entries(
                            fixtures: [combination: Sample.fixture("fixture.absent")]
                        )
                    )
                )
            } == .missingRequiredEntries(
                field: "fusionRule.entries[\(combination.description)].fixture",
                keys: ["fixture.absent"]
            )
        )
    }

    @Test("A fixture has to demonstrate the combination its entry maps")
    func fixtureMustMatchItsCombination() throws {
        let first = FusionLaneCombination.allCombinations[0]
        let other = try #require(
            FusionLaneCombination.allCombinations.first { $0.pixel != first.pixel }
        )
        // Same provenance state, different pixel label.
        let sameState = try #require(
            FusionLaneCombination.allCombinations.first {
                $0.pixel == other.pixel && $0.provenance == first.provenance
            }
        )
        #expect(
            FusionSample.refusal {
                try FusionSample.approved(
                    candidate: try FusionSample.candidate(
                        entries: FusionSample.entries(
                            fixtures: [first: FusionSample.fixtureID(for: sameState)]
                        )
                    )
                )
            } == .inconsistentReference(
                field: "fusionRule.entries[\(first.description)].fixture.expectations.pixelLabel",
                expected: first.pixel.rawValue,
                found: sameState.pixel.rawValue
            )
        )

        // Same pixel label, different provenance state.
        let sameLabel = try #require(
            FusionLaneCombination.allCombinations.first {
                $0.pixel == first.pixel && $0.provenance != first.provenance
            }
        )
        #expect(
            FusionSample.refusal {
                try FusionSample.approved(
                    candidate: try FusionSample.candidate(
                        entries: FusionSample.entries(
                            fixtures: [first: FusionSample.fixtureID(for: sameLabel)]
                        )
                    )
                )
            } == .inconsistentReference(
                field: """
                    fusionRule.entries[\(first.description)].fixture.expectations.\
                    provenanceState
                    """,
                expected: first.provenance.rawValue,
                found: sameLabel.provenance.rawValue
            )
        )
    }

    @Test("A fixture declaring two labels demonstrates no single combination")
    func ambiguousFixtureRefused() throws {
        let combination = FusionLaneCombination.allCombinations[0]
        let other = try #require(PixelLabelKey.allCases.first { $0 != combination.pixel })
        let ambiguous = try FixtureRecord(
            id: FusionSample.fixtureID(for: combination),
            family: FusionSample.family(for: combination.provenance),
            assetPath: Sample.path("fixtures/fusion/ambiguous.jpg"),
            contentDigest: Sample.digest("f"),
            byteCount: Sample.byteCount(),
            source: Sample.evidence("evidence.fixture"),
            expectations: [
                .pixelLabel(combination.pixel),
                .pixelLabel(other),
                .provenanceState(combination.provenance),
            ]
        )
        let rest = try FusionLaneCombination.allCombinations.dropFirst().map {
            try FusionSample.fixture(demonstrating: $0)
        }
        let suite = try FusionSample.fixtureSuite(fixtures: [ambiguous] + rest)
        // Picking one of the two would let iteration order decide what a release approved.
        #expect(
            FusionSample.refusal { try FusionSample.approved(fixtures: suite) }
                == .duplicateEntry(
                    field: "fusionRule.entries[\(combination.description)]"
                        + ".fixture.expectations.pixelLabel",
                    key: [combination.pixel.rawValue, other.rawValue].sorted()
                        .joined(separator: ",")
                )
        )
    }

    @Test("A fixture that declares no pixel label demonstrates no combination")
    func fixtureWithoutPixelLabelRefused() throws {
        let combination = FusionLaneCombination.allCombinations[0]
        let suite = try FusionSample.fixtureSuite(
            fixtures: try FusionLaneCombination.allCombinations.map {
                try FusionSample.fixture(demonstrating: $0, declaringPixelLabel: $0 != combination)
            }
        )
        #expect(
            FusionSample.refusal { try FusionSample.approved(fixtures: suite) }
                == .missingRequiredEntries(
                    field: "fusionRule.entries[\(combination.description)]"
                        + ".fixture.expectations",
                    keys: ["pixelLabel"]
                )
        )
    }

    @Test("A suite with no applicable provenance decision can demonstrate no combination")
    func suiteWithoutProvenanceRefused() throws {
        // `ReleaseFixtureSuite` already refuses provenance-family fixtures under a waived
        // provenance decision, so the reachable variant is an applicable-looking rule
        // against a suite that holds no fusion fixture at all.
        #expect(
            FusionSample.refusal {
                try FusionSample.approved(
                    fixtures: try FusionSample.fixtureSuite(
                        provenanceApplicability: Sample.notApplicable(),
                        fixtures: [try Sample.fixtureRecord()]
                    )
                )
            } == .forbiddenValue(
                field: "fusionRule.fixtureSuite.provenanceApplicability",
                value: "not-applicable",
                reason: """
                    every fusion combination names a provenance state, so a suite without \
                    an applicable provenance decision can demonstrate none of them
                    """
            )
        )
    }
}

// MARK: - The unavailable lane and the session binding

@Suite("Fusion bypass and session attribution")
struct FusionBypassTests {

    @Test("An unavailable provenance lane is never looked up")
    func unavailableLaneBypassesTheTable() throws {
        let rule = try FusionSample.approved()
        let fusion = OptionalFusion.approved(rule)
        for reason in UnavailableReason.allCases {
            let lane = ProvenanceLane.unavailable(reason)
            // Structural: the lane has no table key at all, so there is nothing to look up.
            #expect(lane.stateKey == nil)
            #expect(lane.category == nil)
            for pixel in PixelEvidence.allCases {
                #expect(rule.attributedEntry(pixel: pixel, provenance: lane) == nil)
                #expect(fusion.attributedEntry(pixel: pixel, provenance: lane) == nil)
                #expect(fusion.summary(pixel: pixel, provenance: lane) == nil)
            }
        }
    }

    @Test("The port refuses a rule the session was not bound to")
    func portRefusesAnUnboundRule() throws {
        let rule = try FusionSample.approved()
        let bound = SessionValue.binding(provenanceEnabled: true, fusionEnabled: true)
        #expect(bound.fusionRuleID == rule.id)

        // The bound session resolves.
        let summary = try rule.resolve(
            pixel: .signalsConsistentWithAIGeneration,
            provenance: .absent,
            rule: rule.rule,
            binding: bound
        )
        let expected = FusionLaneCombination.lookupKey(
            pixel: .signalsConsistentWithAIGeneration,
            provenance: .absent
        )
        #expect(summary == rule.attributedEntry(for: expected).summary)

        // A session with no bound rule cannot apply one.
        #expect(throws: FusionFault.ruleNotBoundToSession(expected: nil, found: rule.id)) {
            try rule.resolve(
                pixel: .noStrongSignalDetected,
                provenance: .absent,
                rule: rule.rule,
                binding: SessionValue.binding(provenanceEnabled: true, fusionEnabled: false)
            )
        }
    }

    @Test("A different table published under the same identifier is refused")
    func portRefusesASubstitutedTable() throws {
        let rule = try FusionSample.approved()
        let substituted = try FusionSample.candidate(
            entries: FusionSample.entries(
                dispositions: [FusionLaneCombination.allCombinations[0]: .omit]
            )
        )
        #expect(substituted.id == rule.id)
        #expect(substituted != rule.rule)
        #expect(throws: FusionFault.ruleNotBoundToSession(
            expected: rule.id,
            found: substituted.id
        )) {
            try rule.resolve(
                pixel: .notEnoughSignal,
                provenance: .absent,
                rule: substituted,
                binding: SessionValue.binding(provenanceEnabled: true, fusionEnabled: true)
            )
        }
    }

    @Test("A session compatible with other copy cannot show this rule's summary")
    func portRefusesIncompatibleCopy() throws {
        let rule = try FusionSample.approved(
            candidate: try FusionSample.candidate(compatibleVerdictCopy: "copy.other"),
            verdictCopy: try FusionSample.copyCatalog(compatibilityID: "copy.other")
        )
        #expect(throws: FusionFault.incompatibleVerdictCopy(
            expected: Sample.artifact("copy.compatibility"),
            found: Sample.artifact("copy.other")
        )) {
            try rule.resolve(
                pixel: .noStrongSignalDetected,
                provenance: .absent,
                rule: rule.rule,
                binding: SessionValue.binding(provenanceEnabled: true, fusionEnabled: true)
            )
        }
    }
}

// MARK: - Optional fusion

@Suite("Optional fusion omits without blocking")
struct OptionalFusionTests {

    @Test("A release with no candidate rule records the absence rather than an empty table")
    func noRuleBoundIsRecorded() throws {
        let fusion = OptionalFusion.resolving(
            candidate: nil,
            verdictCopy: try FusionSample.copyCatalog(),
            fixtures: try FusionSample.fixtureSuite(),
            evidence: try FusionSample.evidenceIndex()
        )
        #expect(fusion == .omitted(.noRuleBound))
        #expect(fusion.approvedRule == nil)
        #expect(fusion.boundRuleID == nil)
        #expect(fusion.ruleVersion == nil)
        #expect(fusion.omission?.rejection == nil)

        // Zero-as-unknown is the pattern this rules out: an absent rule is a case, never a
        // rule whose table is empty. A validated rule always holds all 15 entries.
        #expect(try FusionSample.approved().entries.count == 15)
    }

    @Test("A refused candidate omits the summary and keeps the refusal")
    func refusedCandidateIsOmittedWithItsReason() throws {
        let fusion = OptionalFusion.resolving(
            candidate: try FusionSample.candidate(approval: .rejected),
            verdictCopy: try FusionSample.copyCatalog(),
            fixtures: try FusionSample.fixtureSuite(),
            evidence: try FusionSample.evidenceIndex()
        )
        #expect(fusion.approvedRule == nil)
        // Omitting silently would make a broken rule and no rule indistinguishable.
        #expect(fusion.omission?.rejection != nil)
        #expect(
            fusion.omission?.rejection == .forbiddenValue(
                field: "fusionRule.approval.decision",
                value: "rejected",
                reason: "an unapproved fusion rule may not produce a Combined Summary"
            )
        )

        // Requirement 7.9: no summary for any lane pair, enabled or not.
        for pixel in PixelEvidence.allCases {
            for lane in SessionValue.allLanes {
                #expect(fusion.summary(pixel: pixel, provenance: lane) == nil)
                #expect(fusion.attributedEntry(pixel: pixel, provenance: lane) == nil)
            }
        }
    }

    @Test("Resolving a candidate never fails, whatever is wrong with it")
    func resolvingNeverFails() throws {
        // Requirement 7.16 as a signature: there is no `try` here to forget, so no caller
        // can turn a refused rule into a blocked release.
        let broken: [EvidenceFusionRule] = [
            try FusionSample.candidate(approval: .rejected),
            try FusionSample.candidate(fixtureSuite: "suite.other"),
            try FusionSample.candidate(compatibleVerdictCopy: "copy.other"),
            try FusionSample.candidate(
                entries: FusionSample.entries(
                    fixtures: [
                        FusionLaneCombination.allCombinations[0]: Sample.fixture("fixture.absent")
                    ]
                )
            ),
        ]
        for candidate in broken {
            let fusion = OptionalFusion.resolving(
                candidate: candidate,
                verdictCopy: try FusionSample.copyCatalog(),
                fixtures: try FusionSample.fixtureSuite(),
                evidence: try FusionSample.evidenceIndex()
            )
            #expect(fusion.approvedRule == nil)
            #expect(fusion.omission?.rejection != nil)
        }
    }

    @Test("An omitted summary blocks no otherwise eligible release and hides no lane")
    func omissionDoesNotBlockAnEligibleRelease() throws {
        let fusion = OptionalFusion.resolving(
            candidate: try FusionSample.candidate(approval: .rejected),
            verdictCopy: try FusionSample.copyCatalog(),
            fixtures: try FusionSample.fixtureSuite(),
            evidence: try FusionSample.evidenceIndex()
        )
        #expect(fusion.approvedRule == nil)

        // Half one: every mandatory gate passes and the fusion gate is waived, so the
        // release is eligible with no Combined Summary at all (Requirement 7.16).
        let eligible = try ReleaseReadinessSample.validated()
        #expect(!eligible.enablesFusion)
        #expect(eligible.record.unresolvedMandatoryGates.isEmpty)
        #expect(eligible.record.failingMandatoryGates.isEmpty)

        // Half two: the analysis still completes with both source lanes fully visible.
        // The missing summary is a missing sentence, never a refused report.
        for pixel in PixelEvidence.allCases {
            for evidence in SessionValue.enabledEvidence {
                let lane = ProvenanceLane.available(evidence)
                let report = try #require(
                    SessionValue.report(
                        pixel: pixel,
                        provenance: lane,
                        combinedSummary: fusion.summary(pixel: pixel, provenance: lane)
                    )
                )
                #expect(report.combinedSummary == nil)
                #expect(report.pixel == pixel)
                #expect(report.provenance == lane)
            }
        }
    }

    @Test("An approved rule resolves through the optional wrapper unchanged")
    func approvedRuleResolvesThroughTheWrapper() throws {
        let rule = try FusionSample.approved()
        let fusion = OptionalFusion.resolving(
            candidate: try FusionSample.candidate(),
            verdictCopy: try FusionSample.copyCatalog(),
            fixtures: try FusionSample.fixtureSuite(),
            evidence: try FusionSample.evidenceIndex()
        )
        #expect(fusion.approvedRule == rule)
        #expect(fusion.omission == nil)
        #expect(fusion.boundRuleID == rule.id)
        #expect(fusion.ruleVersion == rule.ruleVersion)
        for pixel in PixelEvidence.allCases {
            for evidence in SessionValue.enabledEvidence {
                let lane = ProvenanceLane.available(evidence)
                #expect(
                    fusion.summary(pixel: pixel, provenance: lane)
                        == rule.attributedEntry(pixel: pixel, provenance: evidence).summary
                )
            }
        }
    }
}
