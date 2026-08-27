import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain

// Design Property 22: fusion is exhaustive, deterministic, and optional.
//
// The design states it as: for any candidate Evidence Fusion Rule, the rule is valid only
// when it contains exactly one unique fixture-approved disposition for every one of the 15
// enabled lane combinations; a valid rule returns that one disposition and its version,
// while a missing, unapproved, incomplete, duplicate, conflicting, or unfixtured rule
// returns no summary and does not otherwise block a release whose mandatory gates pass.
//
// The title names three claims, and a property that proves one proves nothing about the
// other two. Each gets its own arm and its own oracle.
//
// ## Exhaustive
//
// Two halves, and both are needed.
//
// The *positive* half is structural and swept rather than sampled. The key space is the
// closed product of the three pixel labels and the five enabled provenance states, read
// from `PixelLabelKey.allCases` and `ProvenanceStateKey.allCases` rather than written as
// the number 15, so the count is derived from the two factors Requirement 7.12 names. A
// validated rule holds one entry per combination in one fixed order, and every one of the
// 15 is looked up and required to answer for itself — which is the assertion that the
// table's computed index lands on the right slot for all 15 and not only the first.
//
// The *negative* half is the knockout sweep. ``FusionDefect`` enumerates every single edit
// that makes an otherwise coherent candidate unusable — a dropped combination, a duplicate,
// a duplicate that *disagrees* with its twin, a shown copy key no approved catalogue has a
// Combined Summary surface for, and six separate ways for a cited fixture to fail to
// demonstrate the entry it is attached to, plus the approval and reference faults. Every
// case knocks out every defect on its own, and ``FusionVariationWitness`` requires each of
// those refusals to have actually been produced at the exact field it names. A defect whose
// refusal stops biting fails the run even when every individual case still passes.
//
// The two halves pair deliberately. Coverage alone is not validity — a rule can cover all
// 15 and still carry a rejection, name unapproved copy, or cite a fixture that demonstrates
// some other combination — and refusals alone would not show that the coherent baseline
// they are measured against is itself usable.
//
// ## Deterministic
//
// Three separate statements, because "same answer" can fail three ways.
//
//   * **Repetition.** The same combination looked up twice returns the identical attributed
//     entry, including the rule version Requirement 7.11 requires a displayed summary to
//     carry.
//   * **Entry order.** ``EvidenceFusionRule`` stores its entries in no required order, so
//     the same 15 entries are validated again in a generated rotation, optionally reversed,
//     and every one of the 15 lookups has to agree with the baseline's. A rule whose answer
//     depended on the order an artifact happened to list its entries in would not be a
//     function of the combination.
//   * **Path.** Four routes reach a disposition — the attributed entry, the rule's own
//     `disposition(for:)`, the schema's `disposition(for:)`, and the `EvidenceFusing` port
//     against a session bound to that rule — and all four have to return the same value.
//     The expectation itself comes from the *generated shape's* own table rather than from
//     re-reading the rule, so the comparison is against the input rather than against the
//     code under test.
//
// ## Optional
//
// The clause most easily lost. Requirement 7.16 is two facts, and they are proved
// separately because one does not imply the other.
//
//   * **The summary is omitted.** Every defect above, and the absence of any candidate at
//     all, is routed through ``OptionalFusion/resolving(candidate:verdictCopy:fixtures:evidence:)``,
//     which has no failable form: there is no `try` for a caller to forget. Each one yields
//     an omission that *keeps* its refusal, binds no rule identifier and no rule version,
//     and produces no summary for any of the 21 representable lane pairs — three pixel
//     labels crossed with the five enabled states and both unavailable reasons
//     (Requirement 7.9).
//   * **Nothing else is lost.** A release whose fusion gate is waived and whose every
//     mandatory gate passes is *eligible*, in both compositions: pixel-only, and — the
//     stronger form — provenance enabled with only the fused sentence given up. The report
//     still builds for all 15 enabled pairs with both source lanes intact and no summary.
//     And the qualifier is shown to bite rather than to decorate the sentence: the same
//     release with one generated mandatory non-fusion gate failed or unexecuted is blocked,
//     and the record names that gate. Without that contrast, "eligible" would hold whether
//     or not the gate sweep worked at all.
//
// ## The approved-rule form of Requirement 7.10
//
// Property 19 asserted the reachable forms of "an unavailable lane omits the summary": the
// composition-level `canProduceCombinedSummary`, the structural bypass through a lane with
// no table key, the report's unrepresentability, and `OptionalFusion.omitted`. It could not
// assert the strongest form — that an unavailable lane omits the summary *in a build holding
// an approved rule* — because constructing an ``ApprovedFusionRule`` needs the full 15-entry
// table plus fixtures, a copy catalogue, and an evidence index, which is this file's
// subject. That form is asserted here, and it is asserted *discriminatingly*: the same
// approved rule is first shown to produce a real summary for a combination it shows, so the
// omission beside an unavailable lane is a fact about the lane rather than about a rule that
// never says anything.
//
// ## Nothing here decides a fusion mapping
//
// **Which disposition belongs to which combination is an unresolved, externally approved
// input, and no value in this file is one.** The disposition pattern is a generated bit
// pattern chosen to reach every combination of shown and omitted entries; the copy keys,
// fixture identifiers, rule version, suite, catalogue, and approvals are synthetic
// arguments that exist so a validator taking signed artifacts can be called at all. No
// assertion claims any of them is correct, no arm invents a trust outcome, and nothing here
// may be copied into a shipping artifact. Task 9.9 owns the approved offline fixtures,
// including the 15 fusion fixtures as fixtures.
//
// ## Neighbouring properties, and what this file does not assert
//
//   * **Property 19** owns whether provenance is enabled at all. Here both compositions are
//     inputs.
//   * **Property 20** owns the projection from a validator outcome onto one of the five
//     enabled states. Here a state is a given value; no outcome is mapped.
//   * **Property 21** owns lane immutability and noninterference. No arm here claims a
//     summary leaves a lane unchanged; that is quantified there.
//   * **Property 23** owns presentation. No arm here states what a user is shown, so
//     Requirements 7.11 and 7.17 are asserted at the value and the artifact — the summary is
//     identified as a ``CombinedSummary`` carrying its rule version, and its wording is an
//     ``ApprovedCopyKey`` the approved catalogue has a Combined Summary surface for.
//   * `ApprovedFusionRuleTests` pins each refusal and each lookup at one example. This file
//     quantifies the same statements over generated disposition patterns, entry orders,
//     targets, versions, identifiers, compositions, and gates.
//
// ## Why no arm throws
//
// `propertyCheck` discards an error thrown from its body: a `throw` before the assertions
// reports a passing run in milliseconds with every arm skipped, and a pure value-level
// property is legitimately fast, so the clock proves nothing either way. Every construction
// here therefore goes through ``FusionArtifacts/validate()``, which turns a refusal into a
// ``ValidationAttempt`` value, every release approval goes through
// ``ReleaseAttempt``, and every helper reports through `Issue.record`.
// ``FusionVariationWitness`` counts the cases, controls, combination checks, defects,
// omissions, bypasses, and releases and asserts those counts *outside* the body, where an
// issue is not suppressed. Each count is compared against the number of cases rather than
// against an absolute floor, because `record(_:)` is the body's first statement: a body that
// threw immediately afterwards still reaches the full case count, and only a per-case
// identity makes that visible.

extension Tag {
    /// Design Property 22.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property22ExhaustiveOptionalFusion: Self
}

@Suite(
    "Property 22: Fusion is exhaustive, deterministic, and optional",
    .tags(.property22ExhaustiveOptionalFusion)
)
struct ExhaustiveOptionalFusionPropertyTests {
    /// Runs 400 generated cases with shrinking, above the design's floor of 100.
    ///
    /// The count is raised rather than left at the library default because of one coverage
    /// assertion that cannot be sound at 100 draws. The optionality arm blocks one generated
    /// mandatory non-fusion gate per case, and the witness requires *every* gate in
    /// ``ReleaseGate/unconditionalGates`` to have been observed blocking, drawn uniformly.
    /// That is a coupon collection over a set in the twenties: at 100 draws the chance of
    /// leaving at least one gate unvisited is around a third, so the assertion would fail
    /// intermittently on a correct implementation, while at 400 it is a few parts in a
    /// million. Raising the count keeps the assertion at its full strength instead of
    /// weakening it to a subset of the gates. Every generator is composed with `zip`, so the
    /// shrinkers compose.
    ///
    /// **Validates: Requirements 7.9, 7.11, 7.12, 7.15, 7.16**
    @Test("Fusion is exhaustive over all 15 combinations, deterministic, and optional")
    func fusionIsExhaustiveDeterministicAndOptional() async {
        let witness = FusionVariationWitness()

        await propertyCheck(count: 400, input: FusionShape.generator) { shape in
            witness.record(shape)
            guard let scenario = FusionScenario(shape: shape, witness: witness) else { return }

            scenario.checkTheKeySpaceIsTheClosedProductOfBothFactors()
            guard let approved = scenario.checkACoherentRuleIsExhaustive() else { return }

            scenario.checkEveryCombinationLooksUpItsOwnEntry(approved)
            scenario.checkTheLookupIsDeterministic(approved)
            scenario.checkEveryDefectIsRefused()
            scenario.checkEveryDefectOmitsTheSummaryWithoutFailing()
            scenario.checkAnUnavailableLaneOmitsUnderAnApprovedRule(approved)
            scenario.checkOmissionBlocksNoEligibleRelease()

            witness.recordCompletedArms()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - The single edits that make a candidate unusable

/// One thing that can be wrong with an otherwise coherent Evidence Fusion Rule.
///
/// Every case is a single edit to one position of a coherent set, and every case has to be
/// refused on its own. Grouped by the four kinds of fault Requirements 7.12, 7.14, and 7.15
/// reach: the completeness of the 3 x 5 table, the approval of the copy a shown disposition
/// names, whether a cited fixture demonstrates the entry it is attached to, and whether
/// anyone approved the rule and the catalogue at all.
///
/// `CaseIterable` so the knockout arm sweeps the set rather than a hand-written list: a case
/// added here without an expectation is a compile error in
/// ``FusionScenario/expectation(for:)``, and a case whose refusal stops firing is a witness
/// failure at the end of the run rather than an arm that quietly stops asserting.
private enum FusionDefect: String, CaseIterable, Sendable {

    // MARK: The table is not exhaustive (Requirement 7.12)

    /// One of the 15 combinations carries no entry, so the table would need a default.
    case oneCombinationOmitted

    /// One combination carries two entries that agree. Even agreeing twins are refused: a
    /// table with a repeated key is not a function, whatever the two values happen to be.
    case oneCombinationDuplicated

    /// One combination carries two entries whose dispositions *disagree*, so which one a
    /// release approved has no single answer. Checked separately from the agreeing twin
    /// because resolving it by iteration order is the specific silent failure Requirement
    /// 7.12's "exactly one deterministic behavior" rules out.
    case oneCombinationDuplicatedWithADifferentDisposition

    // MARK: The shown copy is not approved (Requirements 7.12, 7.17)

    /// A disposition shows a well-formed copy key the approved catalogue has no Combined
    /// Summary surface for, which is free-form copy wearing an identifier.
    ///
    /// This defect writes its own shown disposition rather than editing whichever entry the
    /// generated pattern happened to show, so it bites in every case — including the case
    /// whose pattern omits every combination and therefore has no shown copy to break.
    case shownCopyKeyHasNoApprovedSummarySurface

    // MARK: The cited fixture demonstrates something else (Requirements 7.14, 7.15)

    /// The cited fixture is not catalogued at all, so no approved result exists.
    case entryCitesAFixtureTheSuiteDoesNotHold

    /// The cited fixture declares another pixel label beside this entry's own provenance
    /// state, so it demonstrates a different combination.
    case fixtureDemonstratesAnotherPixelLabel

    /// The cited fixture declares another provenance state beside this entry's own pixel
    /// label. Checked separately from the label: a validator that compared only one factor
    /// would pass one of these two and fail the other.
    case fixtureDemonstratesAnotherProvenanceState

    /// The cited fixture declares two different pixel labels, so which combination it
    /// demonstrates has no single answer.
    case fixtureDeclaresTwoPixelLabels

    /// The cited fixture declares two different provenance states.
    case fixtureDeclaresTwoProvenanceStates

    /// The cited fixture declares no pixel label at all, so it says nothing about which of
    /// the three labels this combination pairs.
    case fixtureDeclaresNoPixelLabel

    // MARK: Nobody approved it (Requirements 7.9, 7.15)

    /// The rule's own approval record carries a rejection. Presence in a build is never
    /// approval.
    case ruleApprovalRejected

    /// The rule's approval names evidence this release does not carry, which is a
    /// synthesized approval.
    case ruleApprovalUnresolvable

    /// The copy catalogue is itself unapproved, so its keys are not approved copy however
    /// well they resolve.
    case copyCatalogUnapproved

    // MARK: Validated against something other than what it names (Requirements 7.14, 8.1)

    /// The supplied catalogue is not the one the rule claims compatibility with. Broken at
    /// the catalogue, so the refusal reads as the artifact disagreeing with the rule.
    case validatedAgainstAnotherCopyCatalog

    /// The rule names a fixture suite other than the one supplied. Broken at the rule, so
    /// the same reference check is exercised from its other side.
    case validatedAgainstAnotherFixtureSuite

    /// The suite carries no applicable provenance decision, so it can demonstrate none of
    /// the 15 combinations — every one of them names a provenance state.
    case fixtureSuiteHasNoApplicableProvenanceDecision
}

/// Where a defect is caught, and with which refusal.
///
/// Two kinds, because the refusals arrive from two layers and the difference matters. A
/// table that is not exhaustive is refused by ``EvidenceFusionRule``'s own initializer, so
/// the *candidate does not exist* — there is no invalid table for a lookup to fall through,
/// on the in-process path or the decoding path, which share that initializer. Everything
/// else is a coherent artifact that ``ApprovedFusionRule`` refuses to accept.
private enum DefectExpectation {
    /// The candidate cannot be built at all: the schema refuses the entry list.
    case candidateUnrepresentable(ArtifactSchemaError)

    /// The candidate exists, and validation refuses it with exactly this error.
    case validationRefuses(ArtifactSchemaError)
}

/// Which capability composition a release-eligibility check is made in.
private enum FusionComposition: String, CaseIterable, Sendable {
    /// No provenance lane at all, so there is nothing to fuse. The ordinary pixel-only
    /// release.
    case pixelOnly

    /// The provenance lane is enabled and the fusion gate is waived. The stronger form of
    /// Requirement 7.16: both source-lane cards exist and the fused sentence is the only
    /// thing the release gives up.
    case provenanceEnabledFusionWaived

    var enablesProvenance: Bool { self == .provenanceEnabledFusionWaived }
}

// MARK: - Generated shape

/// Everything one generated case varies.
///
/// The shape carries raw draws and derives every artifact value, so a case is reproducible
/// from the printed shape alone and the shrinkers stay composed. Derived from it:
///
///   * every synthetic identifier, from ``seed``, so a case's whole reference set varies
///     together and no assertion can pass by recognizing a constant name;
///   * which of the 15 combinations show a summary and which omit one, from
///     ``dispositionPattern`` and ``dispositionMask``;
///   * which combination each defect targets, from ``rotation``, offset per defect so the
///     defects do not all land on the same slot;
///   * the entry order the determinism arm revalidates in;
///   * the rule version a displayed summary is attributed to; and
///   * which composition, mandatory gate, and non-passing outcome the optionality arm's
///     blocked contrast uses.
///
/// ``FusionVariationWitness`` checks after the run that this actually happened.
private struct FusionShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic identifier, so the whole reference set varies together.
    let seed: Int

    /// Selects one of the four disposition patterns.
    let dispositionPatternSelector: Int

    /// The free 15-bit shown/omitted pattern, used by ``DispositionPattern/generatedMask``.
    let dispositionMask: Int

    /// Which combination each defect targets, offset per defect.
    let rotation: Int

    /// The rotation the determinism arm revalidates the same entries in.
    let permutationOffset: Int

    /// Whether the revalidated entry list is also reversed.
    let reversesEntries: Int

    /// The rule version's three components. The major is at least 1, so a seeded version
    /// can never be the rejected `0.0.0` placeholder.
    let versionMajor: Int
    let versionMinor: Int
    let versionPatch: Int

    /// Which composition the blocked contrast is made in.
    let compositionSelector: Int

    /// Which mandatory non-fusion gate the blocked contrast breaks.
    let blockedGateSelector: Int

    /// Which non-passing outcome that gate records.
    let blockedOutcomeSelector: Int

    // MARK: Derived

    var dispositionPattern: DispositionPattern {
        DispositionPattern.allCases[dispositionPatternSelector % DispositionPattern.allCases.count]
    }

    /// Whether the combination at `position` in ``FusionLaneCombination/allCombinations``
    /// shows a summary in this case's baseline table.
    func shows(position: Int) -> Bool {
        switch dispositionPattern {
        case .everyCombinationShows: true
        case .everyCombinationOmits: false
        case .alternating: position.isMultiple(of: 2)
        case .generatedMask: dispositionMask & (1 << position) != 0
        }
    }

    /// The combination one defect targets. Different offsets for different defects, so a
    /// validator that only ever refused the first slot would not pass this run.
    func target(_ offset: Int) -> FusionLaneCombination {
        let all = FusionLaneCombination.allCombinations
        return all[(rotation + offset) % all.count]
    }

    /// The rule version a displayed summary is attributed to.
    ///
    /// The major component is pinned positive rather than derived freely from the seed. A
    /// version of `0.0.0` is the repository's local development stand-in and is rejected as
    /// a placeholder, so a freely seeded version would surface as a construction failure in
    /// whichever case happened to draw all-zero components, and shrinking would then drive
    /// the seed toward it and report a fusion failure that has nothing to do with fusion.
    var ruleVersion: String { "\(versionMajor).\(versionMinor).\(versionPatch)" }

    var composition: FusionComposition {
        FusionComposition.allCases[compositionSelector % FusionComposition.allCases.count]
    }

    /// The mandatory gate the blocked contrast breaks. Never a conditional gate: the claim
    /// is about the *other* mandatory gates, and the fusion gate is the one being waived.
    var blockedGate: ReleaseGate {
        let mandatory = ReleaseGate.unconditionalGates.sorted { $0.rawValue < $1.rawValue }
        return mandatory[blockedGateSelector % mandatory.count]
    }

    /// A gate outcome that does not satisfy a gate: it failed, or it never ran.
    var blockedOutcome: GateOutcome {
        let blocking = GateOutcome.allCases.filter { !$0.isPassing }
        return blocking[blockedOutcomeSelector % blocking.count]
    }

    var description: String {
        """
        seed \(seed), pattern \(dispositionPattern.rawValue), mask \(dispositionMask), \
        rotation \(rotation), order +\(permutationOffset)\(reversesEntries == 1 ? " reversed" : ""), \
        version \(ruleVersion), \(composition.rawValue), \
        blocked \(blockedGate.rawValue) as \(blockedOutcome.rawValue)
        """
    }

    // MARK: Generator

    static var generator: Generator<FusionShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            dispositionShape,
            orderShape,
            versionShape,
            releaseShape
        )
        .map { raw in
            FusionShape(
                seed: raw.0,
                dispositionPatternSelector: raw.1.0,
                dispositionMask: raw.1.1,
                rotation: raw.2.0,
                permutationOffset: raw.2.1,
                reversesEntries: raw.2.2,
                versionMajor: raw.3.0,
                versionMinor: raw.3.1,
                versionPatch: raw.3.2,
                compositionSelector: raw.4.0,
                blockedGateSelector: raw.4.1,
                blockedOutcomeSelector: raw.4.2
            )
        }
        .eraseToAny()
    }

    /// The pattern selector and the free 15-bit mask.
    ///
    /// The selector spans a multiple of the pattern count, so each of the four patterns is
    /// drawn about a quarter of the time. That is what makes the two extremes — a table that
    /// shows every combination and one that omits every combination — reachable at all: a
    /// uniform 15-bit mask alone reaches each of them once in 32,768 draws.
    private static var dispositionShape: Generator<(Int, Int), AnySequence<Any>> {
        zip(
            Gen.int(in: 0...(DispositionPattern.allCases.count * 97)),
            Gen.int(in: 0...((1 << FusionLaneCombination.requiredCombinationCount) - 1))
        )
        .map { ($0.0, $0.1) }
        .eraseToAny()
    }

    /// The defect target rotation, the revalidation rotation, and the reversal flag.
    ///
    /// The target rotation spans twice the combination count, so `rotation % 15` covers
    /// every slot uniformly and each defect's own offset still lands somewhere different.
    private static var orderShape: Generator<(Int, Int, Int), AnySequence<Any>> {
        zip(
            Gen.int(in: 0...(FusionLaneCombination.requiredCombinationCount * 2 - 1)),
            Gen.int(in: 0...(FusionLaneCombination.requiredCombinationCount - 1)),
            Gen.int(in: 0...1)
        )
        .map { ($0.0, $0.1, $0.2) }
        .eraseToAny()
    }

    /// The three rule-version components, with a positive major.
    private static var versionShape: Generator<(Int, Int, Int), AnySequence<Any>> {
        zip(Gen.int(in: 1...99), Gen.int(in: 0...999), Gen.int(in: 0...999))
            .map { ($0.0, $0.1, $0.2) }
            .eraseToAny()
    }

    /// The composition, gate, and outcome the blocked contrast uses.
    private static var releaseShape: Generator<(Int, Int, Int), AnySequence<Any>> {
        zip(
            Gen.int(in: 0...(FusionComposition.allCases.count * 97)),
            Gen.int(in: 0...(ReleaseGate.unconditionalGates.count * 13)),
            Gen.int(in: 0...(GateOutcome.allCases.count * 97))
        )
        .map { ($0.0, $0.1, $0.2) }
        .eraseToAny()
    }
}

/// How one generated case decides which combinations show a summary.
///
/// Four patterns rather than one free mask. The two uniform patterns are what make the
/// boundaries reachable: a table that shows a summary for all 15 combinations and one that
/// explicitly omits all 15 are both valid rules, and both are cases a lookup has to answer.
/// Nothing here is an approved mapping — the pattern exists to reach both
/// ``FusionDisposition`` cases at every slot over the run.
private enum DispositionPattern: String, CaseIterable, Sendable {
    case everyCombinationShows
    case everyCombinationOmits
    case alternating
    case generatedMask
}

// MARK: - Attempted validations

/// What one attempt to validate a candidate produced, as a value rather than a thrown error.
///
/// `propertyCheck` discards an error thrown from its body, so a refusal has to arrive as
/// data. Three cases, and every arm distinguishes all three: a refusal for the wrong reason
/// is a failure rather than an unexamined "did not validate".
private enum ValidationAttempt {
    case validated(ApprovedFusionRule)
    case refused(ArtifactSchemaError)
    case failedOtherwise(String)

    var rule: ApprovedFusionRule? {
        guard case let .validated(rule) = self else { return nil }
        return rule
    }

    var refusal: ArtifactSchemaError? {
        guard case let .refused(error) = self else { return nil }
        return error
    }

    var description: String {
        switch self {
        case .validated: "validated"
        case let .refused(error): "refused: \(error.description)"
        case let .failedOtherwise(text): "failed: \(text)"
        }
    }
}

/// What one attempt to build a candidate produced.
///
/// Separate from ``ValidationAttempt`` because "the schema refused the entry list" and
/// "validation refused the artifact" are different findings, and the incomplete-table
/// defects have to produce the first rather than the second.
private enum CandidateAttempt {
    case built(EvidenceFusionRule)
    case refused(ArtifactSchemaError)
    case failedOtherwise(String)

    var candidate: EvidenceFusionRule? {
        guard case let .built(candidate) = self else { return nil }
        return candidate
    }

    var refusal: ArtifactSchemaError? {
        guard case let .refused(error) = self else { return nil }
        return error
    }

    var description: String {
        switch self {
        case .built: "built"
        case let .refused(error): "refused: \(error.description)"
        case let .failedOtherwise(text): "failed: \(text)"
        }
    }
}

/// What one attempt to approve a release for distribution produced.
private enum ReleaseAttempt {
    case eligible(EligibleRelease)
    case refused(ArtifactSchemaError)
    case failedOtherwise(String)

    var release: EligibleRelease? {
        guard case let .eligible(release) = self else { return nil }
        return release
    }

    var refusalText: String? {
        guard case let .refused(error) = self else { return nil }
        return error.description
    }

    var description: String {
        switch self {
        case .eligible: "eligible"
        case let .refused(error): "refused: \(error.description)"
        case let .failedOtherwise(text): "failed: \(text)"
        }
    }
}

// MARK: - Seeded identifiers

/// Every identifier one generated case uses, derived from its seed.
///
/// None of these is an approved artifact identifier. They exist so a validator that takes
/// signed artifacts can be called, and so that no assertion in this file can pass by
/// recognizing a constant name.
private struct FusionNames {
    let seed: Int

    private var prefix: String { "p22.\(seed)" }

    var rule: String { "\(prefix).rule.fusion" }
    var ruleApproval: String { "\(prefix).approval.fusion-rule" }
    var catalog: String { "\(prefix).catalog.verdict-copy" }
    var copyCompatibility: String { "\(prefix).copy.compatibility" }
    var catalogApproval: String { "\(prefix).approval.verdict-copy" }
    var suite: String { "\(prefix).suite.fixtures" }
    var fixtureEvidence: String { "\(prefix).evidence.fixture" }

    /// An identifier for a catalogue this rule never claimed compatibility with.
    var otherCopyCompatibility: String { "\(prefix).copy.other-catalogue" }

    /// An identifier for a fixture suite this release does not supply.
    var otherSuite: String { "\(prefix).suite.other" }

    /// A fixture identifier no suite in this case holds.
    var uncataloguedFixture: String { "\(prefix).fixture.not-catalogued" }

    /// A well-formed copy key no catalogue in this case has a summary surface for.
    var unapprovedCopyKey: String { "\(prefix).copy.summary.never-approved" }

    /// The one placeholder fixture a provenance-waived suite may hold.
    var unconditionalFixture: String { "\(prefix).fixture.model-parity" }

    func copyKey(_ combination: FusionLaneCombination) -> String {
        "\(prefix).copy.summary.\(combination.description)"
    }

    func fixture(_ combination: FusionLaneCombination) -> String {
        "\(prefix).fixture.\(combination.description)"
    }

    func assetPath(_ combination: FusionLaneCombination) -> String {
        "fixtures/p22/\(seed)/\(combination.description).jpg"
    }
}

// MARK: - The four artifacts a validation takes

/// One coherent set of fusion inputs, or the same set with one defect applied.
///
/// Held together as a value so the control and every knockout are built the same way and
/// differ in exactly one position. `validate()` never throws.
private struct FusionArtifacts {
    let candidate: EvidenceFusionRule
    let catalog: ApprovedVerdictCopyCatalog
    let suite: ReleaseFixtureSuite
    let index: ReleaseEvidenceIndex

    /// Validates, or returns the refusal as a value.
    func validate() -> ValidationAttempt {
        do {
            return .validated(
                try ApprovedFusionRule(
                    validating: candidate,
                    verdictCopy: catalog,
                    fixtures: suite,
                    evidence: index
                )
            )
        } catch let error as ArtifactSchemaError {
            return .refused(error)
        } catch {
            return .failedOtherwise("\(error)")
        }
    }

    /// Resolves through the optional wrapper, which has no failable form at all.
    func resolveOptionally() -> OptionalFusion {
        OptionalFusion.resolving(
            candidate: candidate,
            verdictCopy: catalog,
            fixtures: suite,
            evidence: index
        )
    }

    /// Resolves with no candidate rule, which is the release that binds none.
    func resolveWithNoCandidate() -> OptionalFusion {
        OptionalFusion.resolving(
            candidate: nil,
            verdictCopy: catalog,
            fixtures: suite,
            evidence: index
        )
    }
}

// MARK: - Scenario

/// Builds the fusion inputs one generated shape describes, and rebuilds them with any one
/// defect applied.
private struct FusionScenario {
    let shape: FusionShape
    let witness: FusionVariationWitness
    private let names: FusionNames

    /// The baseline table this case's shape describes, in `allCombinations` order.
    private let baselineDispositions: [FusionDisposition]

    /// The coherent baseline every knockout is measured against.
    private let baseline: FusionArtifacts

    init?(shape: FusionShape, witness: FusionVariationWitness) {
        self.shape = shape
        self.witness = witness
        let names = FusionNames(seed: shape.seed)
        self.names = names

        var dispositions: [FusionDisposition] = []
        for (position, combination) in FusionLaneCombination.allCombinations.enumerated() {
            dispositions.append(
                shape.shows(position: position)
                    ? .show(Sample.copyKey(names.copyKey(combination)))
                    : .omit
            )
        }
        self.baselineDispositions = dispositions

        guard
            let baseline = Self.artifacts(
                shape: shape,
                names: names,
                dispositions: dispositions,
                applying: nil
            )
        else {
            Issue.record("the coherent baseline could not be built [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }
        self.baseline = baseline
    }

    // MARK: - Arm: the key space is the closed product of both factors

    /// Requirement 7.12's own arithmetic, read off the two factors rather than written down.
    ///
    /// The requirement says "the 15 combinations formed by the three Pixel Evidence labels
    /// crossed with the five Provenance Evidence states". Asserting the literal 15 alone
    /// would still hold if one factor grew and the other shrank, so the product is asserted
    /// too, and both closed vocabularies are required to be the size the requirement names.
    /// The unavailable lane is required to be absent from the state factor, which is the
    /// structural reason an unavailable lane has no slot to look up.
    func checkTheKeySpaceIsTheClosedProductOfBothFactors() {
        let labels = PixelLabelKey.allCases.count
        let states = ProvenanceStateKey.allCases.count
        #expect(labels == 3, "pixel labels: \(labels) [\(shape)]")
        #expect(states == 5, "enabled provenance states: \(states) [\(shape)]")
        #expect(
            FusionLaneCombination.requiredCombinationCount == labels * states,
            "required combinations: \(FusionLaneCombination.requiredCombinationCount) [\(shape)]"
        )
        #expect(FusionLaneCombination.requiredCombinationCount == 15, "[\(shape)]")

        // Exactly once each: the key space is a set of that size, not a list with repeats.
        #expect(
            Set(FusionLaneCombination.allCombinations).count
                == FusionLaneCombination.requiredCombinationCount,
            "distinct combinations: \(Set(FusionLaneCombination.allCombinations).count) [\(shape)]"
        )

        // The runtime evidence vocabularies are the same two factors, so "the 15 enabled
        // lane combinations" really is the product of what a session can produce.
        #expect(PixelEvidence.allCases.count == labels, "[\(shape)]")
        #expect(ProvenanceCategory.allCases.count == states, "[\(shape)]")
        #expect(
            Set(PixelEvidence.allCases.map(\.labelKey)) == Set(PixelLabelKey.allCases),
            "[\(shape)]"
        )
        #expect(
            Set(ProvenanceCategory.allCases.map(\.stateKey)) == Set(ProvenanceStateKey.allCases),
            "[\(shape)]"
        )

        // Requirement 7.10's structural half, and the reason it needs no table entry: no
        // unavailable lane has a state key, so none of the 15 keys can name one.
        for reason in UnavailableReason.allCases {
            #expect(ProvenanceLane.unavailable(reason).stateKey == nil, "[\(shape)]")
        }
        witness.recordKeySpaceCheck()
    }

    // MARK: - Arm: a coherent rule is exhaustive

    /// The control every refusal below is attributable against.
    ///
    /// A coherent candidate validates, and the validated rule holds exactly one entry per
    /// combination, in `allCombinations` order regardless of the order the artifact listed
    /// them in. That normalization is what makes the lookup a total array read rather than a
    /// search, so it is asserted rather than assumed.
    func checkACoherentRuleIsExhaustive() -> ApprovedFusionRule? {
        let attempt = baseline.validate()
        guard let rule = attempt.rule else {
            Issue.record("a coherent fusion rule was \(attempt.description) [\(shape)]")
            return nil
        }
        witness.recordControl()

        #expect(rule.id == Sample.artifact(names.rule), "[\(shape)]")
        #expect(rule.ruleVersion == Sample.version(shape.ruleVersion), "[\(shape)]")
        #expect(rule.verdictCopyCatalog == Sample.artifact(names.catalog), "[\(shape)]")
        #expect(
            rule.verdictCopyCompatibilityID == Sample.artifact(names.copyCompatibility),
            "[\(shape)]"
        )
        #expect(rule.fixtureSuite == Sample.artifact(names.suite), "[\(shape)]")

        #expect(
            rule.entries.count == FusionLaneCombination.requiredCombinationCount,
            "validated entries: \(rule.entries.count) [\(shape)]"
        )
        #expect(
            rule.entries.map(\.combination) == FusionLaneCombination.allCombinations,
            "[\(shape)]"
        )
        return rule
    }

    // MARK: - Arm: every combination looks up its own entry

    /// Requirements 7.11 and 7.12: all 15 slots answer, each for itself, attributed.
    ///
    /// Swept exhaustively rather than sampled, and the expected disposition comes from the
    /// generated shape's own table rather than from re-reading the rule, so the comparison is
    /// against this case's input. A shown entry has to produce a ``CombinedSummary`` carrying
    /// the generated copy key and this rule's identifier; an omitting entry has to produce no
    /// summary and *still* carry the rule version, because "this rule decided to say nothing
    /// here" and "no rule was consulted" are different facts.
    func checkEveryCombinationLooksUpItsOwnEntry(_ rule: ApprovedFusionRule) {
        for (position, combination) in FusionLaneCombination.allCombinations.enumerated() {
            let looked = rule.attributedEntry(for: combination)
            let expected = baselineDispositions[position]

            #expect(looked.combination == combination, "[\(shape)]")
            #expect(looked.ruleID == rule.id, "[\(shape)]")
            #expect(looked.ruleVersion == rule.ruleVersion, "[\(shape)]")
            #expect(looked.fixture == Sample.fixture(names.fixture(combination)), "[\(shape)]")
            #expect(
                looked.entry.disposition == expected,
                """
                \(combination.description) mapped to \(looked.entry.disposition) rather than \
                the generated \(expected) [\(shape)]
                """
            )

            switch expected {
            case let .show(copyKey):
                guard let summary = looked.summary else {
                    Issue.record("\(combination.description) showed no summary [\(shape)]")
                    continue
                }
                // Requirement 7.11: identified as a Combined Summary, attributed to this
                // rule, and its wording is a key the approved catalogue covers.
                #expect(summary.copyKey == copyKey, "[\(shape)]")
                #expect(summary.fusionRuleID == rule.id, "[\(shape)]")
                #expect(
                    self.baseline.catalog.localizationKey(for: .combinedSummary(copyKey)) != nil,
                    "[\(shape)]"
                )
                witness.recordShownDisposition()
            case .omit:
                #expect(looked.summary == nil, "[\(shape)]")
                #expect(looked.ruleVersion == rule.ruleVersion, "[\(shape)]")
                witness.recordOmittingDisposition()
            }
            witness.recordCombinationCheck()
        }
    }

    // MARK: - Arm: the lookup is deterministic

    /// Three statements: repetition, entry order, and path agreement.
    ///
    /// The permuted rule is validated from the *same* 15 entries in a generated rotation,
    /// optionally reversed, so a disagreement is a dependence on artifact order rather than
    /// on content. The four paths are compared against each other and against this case's
    /// generated table, so agreement is a decision rather than a coincidence.
    func checkTheLookupIsDeterministic(_ rule: ApprovedFusionRule) {
        let permuted = permutedBaseline().validate()
        guard let permutedRule = permuted.rule else {
            Issue.record("the same entries in another order were \(permuted.description) [\(shape)]")
            return
        }
        // The same rule, listed differently: one identifier, one version, one table.
        #expect(permutedRule.id == rule.id, "[\(shape)]")
        #expect(permutedRule.ruleVersion == rule.ruleVersion, "[\(shape)]")
        #expect(permutedRule.entries == rule.entries, "[\(shape)]")

        let binding = boundSession(fusionRuleID: rule.id)
        for (position, combination) in FusionLaneCombination.allCombinations.enumerated() {
            let expected = baselineDispositions[position]
            let first = rule.attributedEntry(for: combination)

            // Repetition.
            #expect(first == rule.attributedEntry(for: combination), "[\(shape)]")
            // Entry order.
            #expect(first == permutedRule.attributedEntry(for: combination), "[\(shape)]")

            // Path: the attributed entry, the rule, and the schema all answer alike, and
            // all three answer with the generated table's own value.
            #expect(first.entry.disposition == expected, "[\(shape)]")
            #expect(rule.disposition(for: combination) == expected, "[\(shape)]")
            #expect(rule.rule.disposition(for: combination) == expected, "[\(shape)]")
            #expect(
                rule.rule.disposition(
                    pixel: combination.pixel,
                    provenance: combination.provenance
                ) == expected,
                "[\(shape)]"
            )

            // Path: the runtime lane pair reaches the same slot, and the fusion port a
            // session actually uses returns the same summary.
            guard let evidence = Self.evidence(for: combination.provenance) else {
                Issue.record("no sample evidence for \(combination.provenance.rawValue) [\(shape)]")
                continue
            }
            let pixel = combination.pixel.pixelEvidence
            #expect(
                FusionLaneCombination.lookupKey(pixel: pixel, provenance: evidence) == combination,
                "[\(shape)]"
            )
            #expect(
                rule.attributedEntry(pixel: pixel, provenance: evidence) == first,
                "[\(shape)]"
            )
            #expect(
                rule.attributedEntry(pixel: pixel, provenance: .available(evidence)) == first,
                "[\(shape)]"
            )
            #expect(
                OptionalFusion.approved(rule)
                    .attributedEntry(pixel: pixel, provenance: .available(evidence)) == first,
                "[\(shape)]"
            )

            do {
                let summary = try rule.resolve(
                    pixel: pixel,
                    provenance: evidence,
                    rule: rule.rule,
                    binding: binding
                )
                #expect(summary == first.summary, "[\(shape)]")
            } catch {
                Issue.record("the bound port refused \(combination.description): \(error) [\(shape)]")
            }
            witness.recordDeterminismCheck()
        }
    }

    // MARK: - Arm: every defect is refused

    /// The arm the exhaustiveness claim is named for.
    ///
    /// Every defect is applied on its own in every case, rather than a generated selection of
    /// them, so "each of these makes a rule unusable" is a fact about this run rather than
    /// about the draws it happened to make. The refusal is compared for exact equality
    /// against the error ``expectation(for:)`` states, and the witness requires each defect's
    /// refusal to have been produced, so a defect whose refusal stopped biting fails the run
    /// even when every individual case still passes.
    ///
    /// Exact equality is available here — rather than the fragment matching a sweep-order
    /// dependent refusal needs — because each defect breaks exactly one position and the
    /// validator's field names carry that position.
    func checkEveryDefectIsRefused() {
        for defect in FusionDefect.allCases {
            witness.recordDefect()
            switch expectation(for: defect) {
            case let .candidateUnrepresentable(expected):
                let attempt = candidateAttempt(applying: defect)
                guard let refusal = attempt.refusal else {
                    Issue.record(
                        """
                        \(defect.rawValue) produced a candidate the schema accepted: \
                        \(attempt.description) [\(shape)]
                        """
                    )
                    continue
                }
                guard refusal == expected else {
                    Issue.record(
                        """
                        \(defect.rawValue) was refused as \(refusal.description) rather than \
                        \(expected.description) [\(shape)]
                        """
                    )
                    continue
                }
                witness.recordRefusal(of: defect, targeting: target(of: defect))
            case let .validationRefuses(expected):
                let attempt = artifacts(applying: defect)?.validate()
                guard let attempt else {
                    Issue.record("\(defect.rawValue) could not be built [\(shape)]")
                    witness.recordUnbuildableInput()
                    continue
                }
                guard let refusal = attempt.refusal else {
                    Issue.record(
                        "\(defect.rawValue) was \(attempt.description) [\(shape)]"
                    )
                    continue
                }
                guard refusal == expected else {
                    Issue.record(
                        """
                        \(defect.rawValue) was refused as \(refusal.description) rather than \
                        \(expected.description) [\(shape)]
                        """
                    )
                    continue
                }
                witness.recordRefusal(of: defect, targeting: target(of: defect))
            }
        }
    }

    /// The slot one defect breaks, or `nil` when it breaks no single entry.
    ///
    /// Exhaustive with no `default`, and the offsets are the ones ``expectation(for:)`` and
    /// the entry builders use, so a defect cannot be recorded against a slot other than the
    /// one it actually edited. Offsets differ per defect so the sweep does not pile every
    /// defect onto one combination.
    private func target(of defect: FusionDefect) -> FusionLaneCombination? {
        switch defect {
        case .oneCombinationOmitted: shape.target(0)
        case .oneCombinationDuplicated: shape.target(1)
        case .oneCombinationDuplicatedWithADifferentDisposition: shape.target(2)
        case .shownCopyKeyHasNoApprovedSummarySurface: shape.target(3)
        case .entryCitesAFixtureTheSuiteDoesNotHold: shape.target(4)
        case .fixtureDemonstratesAnotherPixelLabel: shape.target(5)
        case .fixtureDemonstratesAnotherProvenanceState: shape.target(6)
        case .fixtureDeclaresTwoPixelLabels: shape.target(7)
        case .fixtureDeclaresTwoProvenanceStates: shape.target(8)
        case .fixtureDeclaresNoPixelLabel: shape.target(9)
        case .ruleApprovalRejected, .ruleApprovalUnresolvable, .copyCatalogUnapproved,
             .validatedAgainstAnotherCopyCatalog, .validatedAgainstAnotherFixtureSuite,
             .fixtureSuiteHasNoApplicableProvenanceDecision:
            nil
        }
    }

    /// What one defect has to produce, and where.
    ///
    /// Exhaustive with no `default`, so a defect added to ``FusionDefect`` is a compile error
    /// here rather than a defect nothing asserts. Every expected value is either a generated
    /// identifier, a closed-vocabulary raw value, or the validator's own wording, so an
    /// assertion cannot pass because an unrelated check refused the same field.
    private func expectation(for defect: FusionDefect) -> DefectExpectation {
        switch defect {
        case .oneCombinationOmitted:
            return .candidateUnrepresentable(
                .missingRequiredEntries(
                    field: "fusionEntries",
                    keys: [shape.target(0).description]
                )
            )
        case .oneCombinationDuplicated:
            return .candidateUnrepresentable(
                .duplicateEntry(field: "fusionEntries", key: shape.target(1).description)
            )
        case .oneCombinationDuplicatedWithADifferentDisposition:
            return .candidateUnrepresentable(
                .duplicateEntry(field: "fusionEntries", key: shape.target(2).description)
            )
        case .shownCopyKeyHasNoApprovedSummarySurface:
            let target = shape.target(3)
            return .validationRefuses(
                .missingRequiredEntries(
                    field: "fusionRule.entries[\(target.description)].disposition",
                    keys: [
                        VerdictCopySurface
                            .combinedSummary(Sample.copyKey(names.unapprovedCopyKey))
                            .description
                    ]
                )
            )
        case .entryCitesAFixtureTheSuiteDoesNotHold:
            let target = shape.target(4)
            return .validationRefuses(
                .missingRequiredEntries(
                    field: "fusionRule.entries[\(target.description)].fixture",
                    keys: [names.uncataloguedFixture]
                )
            )
        case .fixtureDemonstratesAnotherPixelLabel:
            let target = shape.target(5)
            return .validationRefuses(
                .inconsistentReference(
                    field: "fusionRule.entries[\(target.description)].fixture"
                        + ".expectations.pixelLabel",
                    expected: target.pixel.rawValue,
                    found: Self.otherLabel(than: target.pixel).rawValue
                )
            )
        case .fixtureDemonstratesAnotherProvenanceState:
            let target = shape.target(6)
            return .validationRefuses(
                .inconsistentReference(
                    field: "fusionRule.entries[\(target.description)].fixture"
                        + ".expectations.provenanceState",
                    expected: target.provenance.rawValue,
                    found: Self.otherState(than: target.provenance).rawValue
                )
            )
        case .fixtureDeclaresTwoPixelLabels:
            let target = shape.target(7)
            return .validationRefuses(
                .duplicateEntry(
                    field: "fusionRule.entries[\(target.description)].fixture"
                        + ".expectations.pixelLabel",
                    key: [target.pixel.rawValue, Self.otherLabel(than: target.pixel).rawValue]
                        .sorted()
                        .joined(separator: ",")
                )
            )
        case .fixtureDeclaresTwoProvenanceStates:
            let target = shape.target(8)
            return .validationRefuses(
                .duplicateEntry(
                    field: "fusionRule.entries[\(target.description)].fixture"
                        + ".expectations.provenanceState",
                    key: [
                        target.provenance.rawValue,
                        Self.otherState(than: target.provenance).rawValue,
                    ]
                    .sorted()
                    .joined(separator: ",")
                )
            )
        case .fixtureDeclaresNoPixelLabel:
            let target = shape.target(9)
            return .validationRefuses(
                .missingRequiredEntries(
                    field: "fusionRule.entries[\(target.description)].fixture.expectations",
                    keys: ["pixelLabel"]
                )
            )
        case .ruleApprovalRejected:
            return .validationRefuses(
                .forbiddenValue(
                    field: "fusionRule.approval.decision",
                    value: ApprovalDecision.rejected.rawValue,
                    reason: "an unapproved fusion rule may not produce a Combined Summary"
                )
            )
        case .ruleApprovalUnresolvable:
            return .validationRefuses(
                .missingRequiredEntries(
                    field: "fusionRule.approval.source",
                    keys: [names.ruleApproval]
                )
            )
        case .copyCatalogUnapproved:
            return .validationRefuses(
                .forbiddenValue(
                    field: "fusionRule.verdictCopy.approval.decision",
                    value: ApprovalDecision.rejected.rawValue,
                    reason: "an unapproved copy catalogue approves no Combined Summary wording"
                )
            )
        case .validatedAgainstAnotherCopyCatalog:
            return .validationRefuses(
                .inconsistentReference(
                    field: "fusionRule.compatibleVerdictCopy",
                    expected: names.copyCompatibility,
                    found: names.otherCopyCompatibility
                )
            )
        case .validatedAgainstAnotherFixtureSuite:
            return .validationRefuses(
                .inconsistentReference(
                    field: "fusionRule.fixtureSuite",
                    expected: names.otherSuite,
                    found: names.suite
                )
            )
        case .fixtureSuiteHasNoApplicableProvenanceDecision:
            return .validationRefuses(
                .forbiddenValue(
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

    // MARK: - Arm: every defect omits the summary without failing

    /// Requirements 7.9 and 7.16, the omission half.
    ///
    /// Every defect, and the absence of any candidate, is routed through ``OptionalFusion``,
    /// whose resolving member has no failable form at all: there is no `try` in this arm to
    /// forget, so no caller could turn a refused rule into a blocked release even by
    /// mistake. Each omission has to keep its refusal — omitting silently would make a broken
    /// rule and no rule indistinguishable — bind no rule identifier and no rule version, and
    /// produce no summary for any of the 21 representable lane pairs.
    func checkEveryDefectOmitsTheSummaryWithoutFailing() {
        // How many omissions this case owes: one per defect that produces a candidate at all,
        // plus the no-candidate release. Derived from ``expectation(for:)`` rather than
        // written as a number, so a defect moved between the two layers cannot leave the
        // witness expecting a stale total.
        let owed = FusionDefect.allCases.count { defect in
            if case .validationRefuses = expectation(for: defect) { return true }
            return false
        }
        witness.recordOmissionsOwed(owed + 1)

        // No candidate at all: the ordinary release that binds no rule.
        let none = baseline.resolveWithNoCandidate()
        #expect(none == .omitted(.noRuleBound), "[\(shape)]")
        #expect(none.omission?.rejection == nil, "[\(shape)]")
        expectNoSummaryAnywhere(in: none, describedAs: "a release with no candidate rule")
        witness.recordOmission()

        for defect in FusionDefect.allCases {
            // The incomplete-table defects have no candidate to offer at all, which is a
            // stronger omission than a refused one: the artifact does not exist.
            guard case .validationRefuses = expectation(for: defect) else { continue }
            guard let artifacts = artifacts(applying: defect) else {
                Issue.record("\(defect.rawValue) could not be built [\(shape)]")
                witness.recordUnbuildableInput()
                continue
            }
            let fusion = artifacts.resolveOptionally()
            #expect(
                fusion.approvedRule == nil,
                "\(defect.rawValue) produced a usable rule [\(shape)]"
            )
            #expect(fusion.boundRuleID == nil, "[\(shape)]")
            #expect(fusion.ruleVersion == nil, "[\(shape)]")
            #expect(
                fusion.omission?.rejection != nil,
                "\(defect.rawValue) omitted without keeping its refusal [\(shape)]"
            )
            #expect(
                fusion.omission?.rejection == artifacts.validate().refusal,
                "\(defect.rawValue) kept a different refusal than validation produced [\(shape)]"
            )
            expectNoSummaryAnywhere(in: fusion, describedAs: defect.rawValue)
            witness.recordOmission()
        }
    }

    /// No summary for any pixel label beside any representable lane: the five enabled states
    /// and both unavailable reasons.
    private func expectNoSummaryAnywhere(in fusion: OptionalFusion, describedAs label: String) {
        for pixel in PixelEvidence.allCases {
            for lane in Self.allLanes {
                #expect(
                    fusion.summary(pixel: pixel, provenance: lane) == nil,
                    "\(label) produced a summary [\(shape)]"
                )
                #expect(
                    fusion.attributedEntry(pixel: pixel, provenance: lane) == nil,
                    "\(label) produced an entry [\(shape)]"
                )
            }
        }
    }

    // MARK: - Arm: an unavailable lane omits under an approved rule

    /// Requirement 7.10 in the form Property 19 could not reach.
    ///
    /// Property 19 asserted every reachable form of this at the composition, the lane, the
    /// report, and ``OptionalFusion/omitted(_:)``, but could not build an
    /// ``ApprovedFusionRule`` to assert the strongest one. Here the rule is approved,
    /// exhaustive, and fixture-backed, and an unavailable lane still omits.
    ///
    /// The premise makes it discriminating. Whenever the generated table shows a summary
    /// somewhere, the same rule is first shown to produce a real one for a combination it
    /// shows; the omission beside an unavailable lane is then a fact about the lane rather
    /// than about a rule that never says anything. The bypass is also structural: the lane
    /// has no state key, so no index is computed at all.
    func checkAnUnavailableLaneOmitsUnderAnApprovedRule(_ rule: ApprovedFusionRule) {
        let fusion = OptionalFusion.approved(rule)
        #expect(fusion.approvedRule == rule, "[\(shape)]")
        #expect(fusion.omission == nil, "[\(shape)]")
        #expect(fusion.boundRuleID == rule.id, "[\(shape)]")
        #expect(fusion.ruleVersion == rule.ruleVersion, "[\(shape)]")

        // A summary this rule really could show, used to prove the report refuses one beside
        // an unavailable lane whether or not the rule's own entry for that pair omits.
        let offered = CombinedSummary(
            copyKey: Sample.copyKey(names.copyKey(FusionLaneCombination.allCombinations[0])),
            fusionRuleID: rule.id
        )

        for reason in UnavailableReason.allCases {
            let lane = ProvenanceLane.unavailable(reason)
            #expect(lane.stateKey == nil, "[\(shape)]")
            #expect(lane.category == nil, "[\(shape)]")
            #expect(lane.evidence == nil, "[\(shape)]")

            for pixel in PixelEvidence.allCases {
                #expect(rule.attributedEntry(pixel: pixel, provenance: lane) == nil, "[\(shape)]")
                #expect(fusion.attributedEntry(pixel: pixel, provenance: lane) == nil, "[\(shape)]")
                #expect(fusion.summary(pixel: pixel, provenance: lane) == nil, "[\(shape)]")

                // Unrepresentable, not merely unpopulated: the report refuses to hold a
                // summary beside a lane there was nothing to fuse.
                #expect(
                    SessionValue.report(
                        pixel: pixel,
                        provenance: lane,
                        combinedSummary: offered
                    ) == nil,
                    "[\(shape)]"
                )
                // And the same report without one is perfectly ordinary.
                #expect(
                    SessionValue.report(pixel: pixel, provenance: lane, combinedSummary: nil)
                        != nil,
                    "[\(shape)]"
                )
                witness.recordUnavailableBypass()
            }
        }

        // The discriminating premise.
        let shown = zip(FusionLaneCombination.allCombinations, baselineDispositions)
            .first { _, disposition in
                if case .show = disposition { return true }
                return false
            }
        guard let (combination, _) = shown else { return }
        guard let evidence = Self.evidence(for: combination.provenance) else { return }
        let pixel = combination.pixel.pixelEvidence

        #expect(
            fusion.summary(pixel: pixel, provenance: .available(evidence)) != nil,
            """
            this approved rule shows a summary for \(combination.description), so its \
            omission beside an unavailable lane means something [\(shape)]
            """
        )
        for reason in UnavailableReason.allCases {
            #expect(
                fusion.summary(pixel: pixel, provenance: .unavailable(reason)) == nil,
                """
                the same pixel label kept its summary when the provenance lane became \
                unavailable for \(reason.rawValue) [\(shape)]
                """
            )
        }
        witness.recordDiscriminatingBypass()
    }

    // MARK: - Arm: omission blocks no eligible release

    /// Requirement 7.16, the half that is not about the summary at all.
    ///
    /// Three statements, and the third is what keeps the first two from being vacuous.
    ///
    ///   * A release whose fusion gate is waived and whose every mandatory gate passes is
    ///     eligible, in both compositions. The provenance-enabled one is the stronger form:
    ///     both source-lane cards exist and the fused sentence is the only thing given up.
    ///   * The analysis still completes. For all 15 enabled pairs the report builds with both
    ///     source lanes intact and no summary, and the session binds no rule identifier —
    ///     which is exactly the value ``OptionalFusion/boundRuleID`` takes when fusion is
    ///     omitted, so the two agree rather than merely both being absent.
    ///   * The qualifier bites. The same release with one generated mandatory non-fusion gate
    ///     failed or unexecuted is blocked, the refusal names that gate, and the record's own
    ///     predicates report it. Without this, "eligible" would hold whether or not the gate
    ///     sweep worked.
    func checkOmissionBlocksNoEligibleRelease() {
        let fusion = baseline.resolveWithNoCandidate()
        #expect(fusion.approvedRule == nil, "[\(shape)]")

        for composition in FusionComposition.allCases {
            let attempt = releaseAttempt(composition, breaking: nil)
            guard let eligible = attempt.release else {
                Issue.record(
                    """
                    a \(composition.rawValue) release with every mandatory gate passing and \
                    the fusion gate waived was \(attempt.description) [\(shape)]
                    """
                )
                continue
            }
            #expect(!eligible.enablesFusion, "[\(shape)]")
            #expect(eligible.enablesProvenance == composition.enablesProvenance, "[\(shape)]")
            #expect(eligible.record.unresolvedMandatoryGates.isEmpty, "[\(shape)]")
            #expect(eligible.record.failingMandatoryGates.isEmpty, "[\(shape)]")
            witness.recordEligibleRelease(composition)
        }

        // The analysis completes with both lanes and no summary.
        let binding = SessionValue.binding(provenanceEnabled: true, fusionEnabled: false)
        #expect(binding.fusionRuleID == fusion.boundRuleID, "[\(shape)]")
        for pixel in PixelEvidence.allCases {
            for evidence in SessionValue.enabledEvidence {
                let lane = ProvenanceLane.available(evidence)
                guard
                    let report = SessionValue.report(
                        pixel: pixel,
                        provenance: lane,
                        combinedSummary: fusion.summary(pixel: pixel, provenance: lane)
                    )
                else {
                    Issue.record("no report for \(pixel.rawValue) beside \(lane) [\(shape)]")
                    continue
                }
                #expect(report.combinedSummary == nil, "[\(shape)]")
                #expect(report.pixel == pixel, "[\(shape)]")
                #expect(report.provenance == lane, "[\(shape)]")
                #expect(report.binding.fusionRuleID == nil, "[\(shape)]")
                witness.recordReportWithoutSummary()
            }
        }

        // The qualifier bites.
        let gate = shape.blockedGate
        let blocked = releaseAttempt(shape.composition, breaking: gate)
        guard let text = blocked.refusalText else {
            Issue.record(
                """
                a release whose \(gate.rawValue) gate was \(shape.blockedOutcome.rawValue) was \
                \(blocked.description) [\(shape)]
                """
            )
            return
        }
        #expect(
            text.contains(gate.rawValue),
            "the refusal did not name \(gate.rawValue): \(text) [\(shape)]"
        )
        // A second, independent oracle: the record itself reports the gate as blocking.
        guard let record = blockedRecord(shape.composition, breaking: gate) else {
            Issue.record("the blocked record could not be built [\(shape)]")
            witness.recordUnbuildableInput()
            return
        }
        switch shape.blockedOutcome {
        case .failed:
            #expect(record.failingMandatoryGates.contains(gate), "[\(shape)]")
        case .notExecuted:
            #expect(record.unresolvedMandatoryGates.contains(gate), "[\(shape)]")
        case .passed:
            Issue.record("a passing outcome cannot block [\(shape)]")
        }
        // The fusion gate is still the waived one, so nothing here blocked because of fusion.
        #expect(!record.enablesFusion, "[\(shape)]")
        witness.recordBlockedRelease(shape.composition, gate: gate, outcome: shape.blockedOutcome)
    }

    // MARK: - Building the artifacts

    /// The baseline with one defect applied, or `nil` when the set cannot be built.
    private func artifacts(applying defect: FusionDefect) -> FusionArtifacts? {
        Self.artifacts(
            shape: shape,
            names: names,
            dispositions: baselineDispositions,
            applying: defect
        )
    }

    /// The baseline's own entries in a generated order, for the determinism arm.
    private func permutedBaseline() -> FusionArtifacts {
        let entries = baseline.candidate.entries
        let rotated = Array(entries[shape.permutationOffset...] + entries[..<shape.permutationOffset])
        let reordered = shape.reversesEntries == 1 ? rotated.reversed().map { $0 } : rotated
        guard
            let candidate = Self.candidate(
                shape: shape,
                names: names,
                entries: reordered,
                namedSuite: names.suite,
                approval: .approved
            )
        else {
            Issue.record("the same entries could not be listed in another order [\(shape)]")
            witness.recordUnbuildableInput()
            return baseline
        }
        return FusionArtifacts(
            candidate: candidate,
            catalog: baseline.catalog,
            suite: baseline.suite,
            index: baseline.index
        )
    }

    /// One attempt to build the candidate a defect describes, for the defects the schema
    /// itself refuses.
    private func candidateAttempt(applying defect: FusionDefect) -> CandidateAttempt {
        let entries = Self.entries(
            shape: shape,
            names: names,
            dispositions: baselineDispositions,
            applying: defect
        )
        do {
            return .built(
                try EvidenceFusionRule(
                    id: Sample.artifact(names.rule),
                    schemaVersion: .v1,
                    ruleVersion: Sample.version(shape.ruleVersion),
                    compatibleVerdictCopy: Sample.artifact(names.copyCompatibility),
                    fixtureSuite: Sample.artifact(names.suite),
                    entries: entries,
                    approval: Sample.approval(.approved, identifier: names.ruleApproval)
                )
            )
        } catch let error as ArtifactSchemaError {
            return .refused(error)
        } catch {
            return .failedOtherwise("\(error)")
        }
    }

    /// The 15 entries this shape describes, with one defect applied.
    ///
    /// Built by walking ``FusionLaneCombination/allCombinations``, so the coherent list is
    /// complete by construction and a defect is a visible single edit rather than a
    /// difference in how the list was assembled.
    private static func entries(
        shape: FusionShape,
        names: FusionNames,
        dispositions: [FusionDisposition],
        applying defect: FusionDefect?
    ) -> [FusionEntry] {
        var entries: [FusionEntry] = []
        for (position, combination) in FusionLaneCombination.allCombinations.enumerated() {
            if defect == .oneCombinationOmitted, combination == shape.target(0) { continue }

            var disposition = dispositions[position]
            var fixture = Sample.fixture(names.fixture(combination))

            if defect == .shownCopyKeyHasNoApprovedSummarySurface, combination == shape.target(3) {
                disposition = .show(Sample.copyKey(names.unapprovedCopyKey))
            }
            if defect == .entryCitesAFixtureTheSuiteDoesNotHold, combination == shape.target(4) {
                fixture = Sample.fixture(names.uncataloguedFixture)
            }
            if defect == .fixtureDemonstratesAnotherPixelLabel, combination == shape.target(5) {
                // Same provenance state, another pixel label, so the label check is the one
                // that fires rather than both at once.
                fixture = Sample.fixture(
                    names.fixture(
                        FusionLaneCombination(
                            pixel: otherLabel(than: combination.pixel),
                            provenance: combination.provenance
                        )
                    )
                )
            }
            if defect == .fixtureDemonstratesAnotherProvenanceState, combination == shape.target(6) {
                fixture = Sample.fixture(
                    names.fixture(
                        FusionLaneCombination(
                            pixel: combination.pixel,
                            provenance: otherState(than: combination.provenance)
                        )
                    )
                )
            }
            entries.append(
                FusionEntry(
                    combination: combination,
                    disposition: disposition,
                    fixture: fixture
                )
            )
        }

        // A second entry for one combination. The agreeing twin repeats the baseline
        // disposition; the disagreeing one inverts it, so which behaviour a release approved
        // would have no single answer if either were accepted.
        if defect == .oneCombinationDuplicated {
            let target = shape.target(1)
            entries.append(
                FusionEntry(
                    combination: target,
                    disposition: disposition(of: target, in: dispositions),
                    fixture: Sample.fixture(names.fixture(target))
                )
            )
        }
        if defect == .oneCombinationDuplicatedWithADifferentDisposition {
            let target = shape.target(2)
            let opposed: FusionDisposition =
                switch disposition(of: target, in: dispositions) {
                case .omit: .show(Sample.copyKey(names.copyKey(target)))
                case .show: .omit
                }
            entries.append(
                FusionEntry(
                    combination: target,
                    disposition: opposed,
                    fixture: Sample.fixture(names.fixture(target))
                )
            )
        }
        return entries
    }

    private static func disposition(
        of combination: FusionLaneCombination,
        in dispositions: [FusionDisposition]
    ) -> FusionDisposition {
        let position = FusionLaneCombination.allCombinations.prefix { $0 != combination }.count
        return dispositions[position]
    }

    /// One candidate rule over `entries`, or `nil` when the schema refuses the list.
    private static func candidate(
        shape: FusionShape,
        names: FusionNames,
        entries: [FusionEntry],
        namedSuite: String,
        approval: ApprovalDecision
    ) -> EvidenceFusionRule? {
        try? EvidenceFusionRule(
            id: Sample.artifact(names.rule),
            schemaVersion: .v1,
            ruleVersion: Sample.version(shape.ruleVersion),
            compatibleVerdictCopy: Sample.artifact(names.copyCompatibility),
            fixtureSuite: Sample.artifact(namedSuite),
            entries: entries,
            approval: Sample.approval(approval, identifier: names.ruleApproval)
        )
    }

    /// The whole input set, coherent or with one defect applied.
    private static func artifacts(
        shape: FusionShape,
        names: FusionNames,
        dispositions: [FusionDisposition],
        applying defect: FusionDefect?
    ) -> FusionArtifacts? {
        let entries = entries(
            shape: shape,
            names: names,
            dispositions: dispositions,
            applying: defect
        )
        guard
            let candidate = candidate(
                shape: shape,
                names: names,
                entries: entries,
                namedSuite: defect == .validatedAgainstAnotherFixtureSuite
                    ? names.otherSuite
                    : names.suite,
                approval: defect == .ruleApprovalRejected ? .rejected : .approved
            ),
            let catalog = catalog(
                shape: shape,
                names: names,
                dispositions: dispositions,
                applying: defect
            ),
            let suite = suite(shape: shape, names: names, applying: defect),
            let index = index(names: names, applying: defect)
        else {
            return nil
        }
        return FusionArtifacts(
            candidate: candidate,
            catalog: catalog,
            suite: suite,
            index: index
        )
    }

    /// The approved copy catalogue: every unconditional surface, every enabled provenance
    /// state, and a Combined Summary surface for exactly the keys this table shows.
    ///
    /// ``FusionNames/unapprovedCopyKey`` is deliberately never given a surface here, which is
    /// what makes the copy defect a single edit to the *rule* rather than a matched pair of
    /// edits to both artifacts.
    private static func catalog(
        shape: FusionShape,
        names: FusionNames,
        dispositions: [FusionDisposition],
        applying defect: FusionDefect?
    ) -> ApprovedVerdictCopyCatalog? {
        var surfaces = VerdictCopySurface.unconditionalSurfaces
        for state in ProvenanceStateKey.allCases {
            surfaces.insert(.provenanceState(state))
        }
        for (position, combination) in FusionLaneCombination.allCombinations.enumerated() {
            if case .show = dispositions[position] {
                surfaces.insert(.combinedSummary(Sample.copyKey(names.copyKey(combination))))
            }
        }
        let compatibility = defect == .validatedAgainstAnotherCopyCatalog
            ? names.otherCopyCompatibility
            : names.copyCompatibility
        return try? ApprovedVerdictCopyCatalog(
            id: Sample.artifact(names.catalog),
            schemaVersion: .v1,
            compatibilityID: Sample.artifact(compatibility),
            languageTag: Sample.text(ApprovedVerdictCopyCatalog.requiredLanguageTag),
            entries: Sample.copyEntries(surfaces: surfaces),
            approval: Sample.approval(
                defect == .copyCatalogUnapproved ? .rejected : .approved,
                identifier: names.catalogApproval
            )
        )
    }

    /// The fixture suite: one fixture per combination, each declaring exactly that
    /// combination's pixel label and provenance state.
    ///
    /// The provenance-waived variant holds one unconditional fixture instead. That is the
    /// only reachable shape for it: ``ReleaseFixtureSuite`` already refuses a
    /// provenance-family fixture under a waived provenance decision, so a suite that kept the
    /// 15 fusion fixtures could not be built at all.
    private static func suite(
        shape: FusionShape,
        names: FusionNames,
        applying defect: FusionDefect?
    ) -> ReleaseFixtureSuite? {
        if defect == .fixtureSuiteHasNoApplicableProvenanceDecision {
            guard
                let placeholder = try? Sample.fixtureRecord(
                    family: .modelParity,
                    identifier: names.unconditionalFixture,
                    assetPath: "fixtures/p22/\(names.seed)/model-parity.jpg"
                )
            else {
                return nil
            }
            return try? ReleaseFixtureSuite(
                id: Sample.artifact(names.suite),
                schemaVersion: .v1,
                provenanceApplicability: Sample.notApplicable(),
                fixtures: [placeholder]
            )
        }

        var records: [FixtureRecord] = []
        for combination in FusionLaneCombination.allCombinations {
            var expectations: [FixtureExpectation] = [
                .pixelLabel(combination.pixel),
                .provenanceState(combination.provenance),
            ]
            if defect == .fixtureDeclaresTwoPixelLabels, combination == shape.target(7) {
                expectations.insert(.pixelLabel(otherLabel(than: combination.pixel)), at: 1)
            }
            if defect == .fixtureDeclaresTwoProvenanceStates, combination == shape.target(8) {
                expectations.append(.provenanceState(otherState(than: combination.provenance)))
            }
            if defect == .fixtureDeclaresNoPixelLabel, combination == shape.target(9) {
                expectations.removeAll {
                    if case .pixelLabel = $0 { return true }
                    return false
                }
            }
            guard
                let record = try? FixtureRecord(
                    id: Sample.fixture(names.fixture(combination)),
                    // Reused read-only from `ApprovedFusionRuleTests`: a total switch from a
                    // provenance state onto its fixture family. Not a release decision, and
                    // adding a state to the closed vocabulary is a compile error there.
                    family: FusionSample.family(for: combination.provenance),
                    assetPath: Sample.path(names.assetPath(combination)),
                    contentDigest: Sample.digest("f"),
                    byteCount: Sample.byteCount(),
                    source: Sample.evidence(names.fixtureEvidence),
                    expectations: expectations
                )
            else {
                return nil
            }
            records.append(record)
        }
        return try? ReleaseFixtureSuite(
            id: Sample.artifact(names.suite),
            schemaVersion: .v1,
            provenanceApplicability: .applicable,
            fixtures: records
        )
    }

    /// The release evidence this case carries.
    ///
    /// The rule's approval is the one reference ``ApprovedFusionRule`` resolves, so omitting
    /// it is how the unresolvable-approval defect is expressed without touching the rule that
    /// cites it: the difference between "this reference names nothing" and "this rule names
    /// something else".
    private static func index(
        names: FusionNames,
        applying defect: FusionDefect?
    ) -> ReleaseEvidenceIndex? {
        var records: [EvidenceSource] = [
            Sample.evidence(names.catalogApproval),
            Sample.evidence(names.fixtureEvidence),
        ]
        if defect != .ruleApprovalUnresolvable {
            records.append(Sample.evidence(names.ruleApproval))
        }
        return try? ReleaseEvidenceIndex(records: records)
    }

    // MARK: - Releases

    /// One release-readiness record in `composition`, optionally with one mandatory gate
    /// broken.
    ///
    /// The fusion gate is always waived, which is how "no Evidence Fusion Rule passes every
    /// fusion criterion" is written down in a signed record.
    private func blockedRecord(
        _ composition: FusionComposition,
        breaking gate: ReleaseGate?
    ) -> ReleaseReadinessRecord? {
        let outcomes: [ReleaseGate: GateOutcome] =
            gate.map { [$0: shape.blockedOutcome] } ?? [:]
        return try? ReleaseReadinessSample.record(
            gateRecords: try ReleaseReadinessSample.gateRecords(
                provenanceApplicable: composition.enablesProvenance,
                fusionApplicable: false,
                outcomes: outcomes
            )
        )
    }

    /// One attempt to approve that record for distribution.
    private func releaseAttempt(
        _ composition: FusionComposition,
        breaking gate: ReleaseGate?
    ) -> ReleaseAttempt {
        do {
            guard let record = blockedRecord(composition, breaking: gate) else {
                return .failedOtherwise("the record could not be built")
            }
            return .eligible(
                try ReleaseReadinessSample.validated(
                    record: record,
                    manifest: try ReleaseReadinessSample.capabilityManifest(
                        provenanceEnabled: composition.enablesProvenance,
                        fusionEnabled: false
                    )
                )
            )
        } catch let error as ArtifactSchemaError {
            return .refused(error)
        } catch {
            return .failedOtherwise("\(error)")
        }
    }

    /// One session binding that names `fusionRuleID`, for the fusion port.
    private func boundSession(fusionRuleID: ArtifactID) -> AnalysisSessionBinding {
        AnalysisSessionBinding(
            sessionID: SessionValue.session(),
            appBuildID: Sample.appBuild(),
            deviceConfigurationID: Sample.configuration(),
            modelBundleID: Sample.bundle(),
            modelIdentity: RequiredPixelModel.identity,
            coreMLModelVersion: Sample.artifact("component.coreml"),
            modelBundleIntegrity: SessionValue.integrity(),
            preprocessingContractID: Sample.artifact("contract.preprocessing"),
            calibrationPolicyID: Sample.artifact("policy.calibration"),
            verdictCopyCompatibilityID: Sample.artifact(names.copyCompatibility),
            capabilityManifestID: Sample.artifact("manifest.capability"),
            provenancePolicyID: Sample.artifact("policy.provenance"),
            fusionRuleID: fusionRuleID,
            lifecyclePolicyID: Sample.artifact("policy.lifecycle"),
            resourceBudgetID: Sample.artifact("budget.main-application")
        )
    }

    // MARK: - Closed-vocabulary helpers

    /// Every representable provenance lane: both unavailable reasons and the five enabled
    /// states.
    private static let allLanes: [ProvenanceLane] =
        UnavailableReason.allCases.map { ProvenanceLane.unavailable($0) }
        + SessionValue.enabledEvidence.map { ProvenanceLane.available($0) }

    /// One enabled evidence value for a state key, reused read-only from the session
    /// fixtures. `nil` would mean the fixture list stopped covering the closed vocabulary.
    private static func evidence(for state: ProvenanceStateKey) -> ProvenanceEvidence? {
        SessionValue.enabledEvidence.first { $0.stateKey == state }
    }

    /// A pixel label other than this one. Total: the vocabulary has three.
    private static func otherLabel(than label: PixelLabelKey) -> PixelLabelKey {
        let all = PixelLabelKey.allCases
        let position = all.prefix { $0 != label }.count
        return all[(position + 1) % all.count]
    }

    /// A provenance state other than this one. Total: the vocabulary has five.
    private static func otherState(than state: ProvenanceStateKey) -> ProvenanceStateKey {
        let all = ProvenanceStateKey.allCases
        let position = all.prefix { $0 != state }.count
        return all[(position + 1) % all.count]
    }
}

// MARK: - Variation witness

/// Counts what the run actually did, outside the property body.
///
/// This exists because `propertyCheck` runs its body under `try?` and discards anything
/// thrown from it: a construction failure at the top of the body reports a passing run in
/// milliseconds with every arm skipped, and a pure value-level property is legitimately fast,
/// so the clock is no evidence either way. Every counter below is incremented from inside an
/// arm and asserted here, where an issue is not suppressed.
///
/// Each count is compared against the number of cases rather than against an absolute floor.
/// ``record(_:)`` is the body's first statement, so `cases` reaches its full total even when
/// everything after it throws; a floor of zero would then be satisfied vacuously, while a
/// per-case identity shows the shortfall. The same reasoning rules out comparing
/// `completedArms` against itself.
///
/// The coverage sets are the property's central claims restated as observations: every defect
/// produced its own refusal at the field stated for it, every combination was targeted by the
/// defect sweep, every unconditional gate was observed blocking a release, and both
/// dispositions were actually returned by a lookup.
private final class FusionVariationWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Variation in the generated inputs.
    private var seeds = Set<Int>()
    private var patterns = Set<DispositionPattern>()
    private var masks = Set<Int>()
    private var targets = Set<FusionLaneCombination>()
    private var permutations = Set<Int>()
    private var reversals = Set<Int>()
    private var versions = Set<String>()
    private var compositionsBlocked = Set<FusionComposition>()
    private var blockedGates = Set<ReleaseGate>()
    private var blockedOutcomes = Set<GateOutcome>()

    // What the arms observed.
    private var refusalsProduced = Set<FusionDefect>()
    private var eligibleCompositions = Set<FusionComposition>()

    // Per-case counts.
    private var cases = 0
    private var completedArms = 0
    private var keySpaceChecks = 0
    private var controls = 0
    private var combinationChecks = 0
    private var determinismChecks = 0
    private var defects = 0
    private var omissions = 0
    private var omissionsOwed = 0
    private var omissionsOwedPerCase = Set<Int>()
    private var unavailableBypasses = 0
    private var discriminatingBypasses = 0
    private var eligibleReleases = 0
    private var blockedReleases = 0
    private var reportsWithoutSummary = 0
    private var shownDispositions = 0
    private var omittingDispositions = 0
    private var unbuildableInputs = 0

    func record(_ shape: FusionShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        patterns.insert(shape.dispositionPattern)
        masks.insert(shape.dispositionMask)
        permutations.insert(shape.permutationOffset)
        reversals.insert(shape.reversesEntries)
        versions.insert(shape.ruleVersion)
    }

    func recordKeySpaceCheck() {
        lock.lock()
        keySpaceChecks += 1
        lock.unlock()
    }

    func recordControl() {
        lock.lock()
        controls += 1
        lock.unlock()
    }

    func recordCombinationCheck() {
        lock.lock()
        combinationChecks += 1
        lock.unlock()
    }

    func recordDeterminismCheck() {
        lock.lock()
        determinismChecks += 1
        lock.unlock()
    }

    func recordDefect() {
        lock.lock()
        defects += 1
        lock.unlock()
    }

    /// Called only when a defect's refusal matched the expected error exactly, so the
    /// coverage assertions below mean each refusal was produced as stated and each slot the
    /// entry-level defects target was refused at.
    ///
    /// `combination` is the slot the defect broke, or `nil` for the approval, catalogue, and
    /// suite defects, which break no single entry. Recorded here rather than off the shape,
    /// so a slot counts as targeted only once a refusal was actually verified at it.
    func recordRefusal(of defect: FusionDefect, targeting combination: FusionLaneCombination?) {
        lock.lock()
        refusalsProduced.insert(defect)
        if let combination { targets.insert(combination) }
        lock.unlock()
    }

    func recordOmission() {
        lock.lock()
        omissions += 1
        lock.unlock()
    }

    /// How many omissions one case owes, derived from the defect set rather than written as a
    /// number. Collected as a set so a run in which different cases owed different totals
    /// fails rather than averaging out.
    func recordOmissionsOwed(_ count: Int) {
        lock.lock()
        omissionsOwedPerCase.insert(count)
        omissionsOwed += count
        lock.unlock()
    }

    func recordUnavailableBypass() {
        lock.lock()
        unavailableBypasses += 1
        lock.unlock()
    }

    func recordDiscriminatingBypass() {
        lock.lock()
        discriminatingBypasses += 1
        lock.unlock()
    }

    func recordEligibleRelease(_ composition: FusionComposition) {
        lock.lock()
        eligibleReleases += 1
        eligibleCompositions.insert(composition)
        lock.unlock()
    }

    /// Called only after a broken gate was verified to block, both in the refusal text and in
    /// the record's own predicate. Recorded here rather than off the shape, so the gate
    /// coverage assertion cannot be satisfied by a case whose blocked arm never ran.
    func recordBlockedRelease(
        _ composition: FusionComposition,
        gate: ReleaseGate,
        outcome: GateOutcome
    ) {
        lock.lock()
        blockedReleases += 1
        compositionsBlocked.insert(composition)
        blockedGates.insert(gate)
        blockedOutcomes.insert(outcome)
        lock.unlock()
    }

    func recordReportWithoutSummary() {
        lock.lock()
        reportsWithoutSummary += 1
        lock.unlock()
    }

    func recordShownDisposition() {
        lock.lock()
        shownDispositions += 1
        lock.unlock()
    }

    func recordOmittingDisposition() {
        lock.lock()
        omittingDispositions += 1
        lock.unlock()
    }

    /// Every generated input here is inside a validated range, so an unbuildable one is a
    /// defect in this file rather than in the code under test. Counted so a run whose inputs
    /// quietly stopped being buildable fails outside the body rather than shrinking its own
    /// coverage.
    func recordUnbuildableInput() {
        lock.lock()
        unbuildableInputs += 1
        lock.unlock()
    }

    /// Called at the end of the body, so a case that stopped early is countable.
    func recordCompletedArms() {
        lock.lock()
        completedArms += 1
        lock.unlock()
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        let combinations = FusionLaneCombination.requiredCombinationCount
        let defectCount = FusionDefect.allCases.count

        #expect(cases >= 100, "the design requires at least 100 generated cases, ran \(cases)")
        #expect(cases == 400, "the raised count did not take effect, ran \(cases)")
        #expect(
            completedArms == cases,
            "\(cases - completedArms) of \(cases) cases did not reach the end of the body"
        )
        #expect(unbuildableInputs == 0, "unbuildable generated inputs: \(unbuildableInputs)")

        // Each of these comes from a specific arm, so a body that stopped before that arm
        // shows a shortfall here even when every case that ran passed. Compared against
        // `cases` rather than a floor: zero against a nonzero case count fails loudly.
        #expect(keySpaceChecks == cases, "key-space checks: \(keySpaceChecks) of \(cases)")
        #expect(controls == cases, "coherent rules validated: \(controls) of \(cases)")
        #expect(
            combinationChecks == cases * combinations,
            "combination lookups: \(combinationChecks), expected \(cases * combinations)"
        )
        #expect(
            determinismChecks == cases * combinations,
            "determinism checks: \(determinismChecks), expected \(cases * combinations)"
        )
        #expect(
            defects == cases * defectCount,
            "defects attempted: \(defects), expected \(cases * defectCount)"
        )
        // One omission per validation-refusable defect, plus the no-candidate release. The
        // total is the one the arm itself derived from the defect set, and every case has to
        // have owed the same amount, so this cannot drift with the defect list.
        #expect(
            omissionsOwedPerCase.count == 1,
            "cases owed differing omission totals: \(omissionsOwedPerCase.sorted())"
        )
        #expect(
            omissionsOwed > cases,
            "omissions owed across the run: \(omissionsOwed) over \(cases) cases"
        )
        #expect(
            omissions == omissionsOwed,
            "omissions checked: \(omissions), owed \(omissionsOwed)"
        )
        #expect(
            unavailableBypasses
                == cases * UnavailableReason.allCases.count * PixelEvidence.allCases.count,
            "unavailable-lane bypasses: \(unavailableBypasses)"
        )
        #expect(
            eligibleReleases == cases * FusionComposition.allCases.count,
            """
            eligible releases: \(eligibleReleases), \
            expected \(cases * FusionComposition.allCases.count)
            """
        )
        #expect(blockedReleases == cases, "blocked releases: \(blockedReleases) of \(cases)")
        #expect(
            reportsWithoutSummary
                == cases * PixelEvidence.allCases.count * ProvenanceStateKey.allCases.count,
            "reports built without a summary: \(reportsWithoutSummary)"
        )

        // The property's central claim: every single edit produced its own refusal, at the
        // exact field stated for it.
        let never = Set(FusionDefect.allCases).subtracting(refusalsProduced)
        #expect(
            refusalsProduced == Set(FusionDefect.allCases),
            "refusals never produced: \(never.map(\.rawValue).sorted())"
        )

        // Every one of the 15 slots was the slot a verified refusal fired at, so no validator
        // could pass this run by only ever refusing the first combination. Recorded at the
        // point of verification rather than off the generated shape, so a case whose defect
        // arm never ran contributes nothing here.
        #expect(
            targets == Set(FusionLaneCombination.allCombinations),
            """
            combinations never targeted: \
            \(Set(FusionLaneCombination.allCombinations).subtracting(targets)
                .map(\.description).sorted())
            """
        )

        // Both dispositions were actually returned by a lookup, so neither branch of
        // `FusionDisposition` is asserted only in the abstract.
        #expect(shownDispositions > 0, "shown dispositions looked up: \(shownDispositions)")
        #expect(
            omittingDispositions > 0,
            "omitting dispositions looked up: \(omittingDispositions)"
        )
        #expect(
            shownDispositions + omittingDispositions == cases * combinations,
            "dispositions looked up: \(shownDispositions + omittingDispositions)"
        )

        // The discriminating premise of the unavailable-lane arm: the approved rule really
        // did show a summary somewhere. Reached whenever the table shows anything, which
        // three of the four patterns always do.
        #expect(
            discriminatingBypasses >= cases / 2,
            "discriminating bypasses: \(discriminatingBypasses) of \(cases)"
        )

        // Both compositions reached both directions, so Requirement 7.16 is asserted in the
        // pixel-only release and in the stronger provenance-enabled one.
        #expect(
            eligibleCompositions == Set(FusionComposition.allCases),
            "compositions found eligible: \(eligibleCompositions.map(\.rawValue).sorted())"
        )
        #expect(
            compositionsBlocked == Set(FusionComposition.allCases),
            "compositions blocked: \(compositionsBlocked.map(\.rawValue).sorted())"
        )

        // Every mandatory non-fusion gate was observed blocking. This is the assertion the
        // raised case count exists for: at the library default it would fail intermittently
        // on a correct implementation, because a uniform draw over this many gates does not
        // reliably visit all of them in 100 tries.
        #expect(
            blockedGates == ReleaseGate.unconditionalGates,
            """
            mandatory gates never observed blocking: \
            \(ReleaseGate.unconditionalGates.subtracting(blockedGates).map(\.rawValue).sorted())
            """
        )
        #expect(
            blockedOutcomes == Set(GateOutcome.allCases.filter { !$0.isPassing }),
            "non-passing outcomes observed: \(blockedOutcomes.map(\.rawValue).sorted())"
        )

        // Generated variation. The seed is drawn from 10,000 values, so a constant baseline
        // shows 1.
        #expect(seeds.count >= 250, "generated seeds: \(seeds.count)")
        #expect(
            patterns == Set(DispositionPattern.allCases),
            "generated disposition patterns: \(patterns.map(\.rawValue).sorted())"
        )
        #expect(masks.count >= 250, "generated disposition masks: \(masks.count)")
        // Input variation rather than an observation. The determinism arm's own count above
        // already showed it completed in every case, so these two say the orders it
        // revalidated in covered every rotation and both directions.
        #expect(
            permutations.count == combinations,
            "generated entry rotations: \(permutations.count) of \(combinations)"
        )
        #expect(reversals == [0, 1], "generated reversal flags: \(reversals.sorted())")
        #expect(versions.count >= 250, "generated rule versions: \(versions.count)")
    }
}
