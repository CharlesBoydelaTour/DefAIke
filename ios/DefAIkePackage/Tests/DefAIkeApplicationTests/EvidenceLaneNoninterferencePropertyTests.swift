import Foundation
import PropertyBased
import Testing

@testable import DefAIkeApplication
@testable import DefAIkeDomain

// Design Property 21: evidence lanes are immutable and noninterfering.
//
// The design states it as: for any Pixel Evidence and enabled provenance state,
// constructing, ordering, or displaying either lane leaves the other lane unchanged;
// absent provenance and insufficient pixel evidence add no authenticity inference; apparent
// inconsistency retains both original lanes and may add only an approved explanatory notice;
// adding a Combined Summary never mutates, suppresses, or ranks either lane.
//
// That is two claims, and the second is four claims wearing one word.
//
// ## Immutable
//
// Over **every lane combination and every operation order**, the source lanes are
// structurally equal before and after. The combinations are the closed product of the three
// pixel labels and the seven lane states a session can resolve — the five enabled states
// plus both unavailable reasons — so 21 per configuration, swept exhaustively rather than
// sampled. The orders are the two the branches can resolve in, each also extended with a
// late duplicate write for one lane, which is the one remaining path by which a branch could
// change an answer the join already holds: six orders, all six exercised
// (Requirements 7.1, 7.4, 7.5).
//
// "Structurally equal" is not `==` on an enum. A lane is compared through
// ``LaneProjection``, which renders the label key, the lane kind, the unavailable reason, the
// enabled state's whole payload — binding status, signer and assertion fields with their
// label keys and values, invalidity category, explanation keys, named unsupported features —
// and the Provenance Policy version the state attributes itself to. A lane that kept its
// category and lost its detail fails here.
//
// ## Noninterfering: four verbs, four oracles
//
// A notice or a Combined Summary never **mutates**, **suppresses**, **ranks**, or **adds**
// authenticity evidence. Each verb is a separate claim with its own oracle, because a
// property that proves one of them proves nothing about the other three:
//
//   * **mutate** — the same two source lanes are joined four ways (plain, with a notice,
//     with a summary, with both) and all four reports have the *identical* lane projection.
//     The additive fields are then required to be exactly the approved inputs that were
//     offered: the notice is the classifier's own catalogue key or nothing, and the summary
//     is the value that was passed in or nothing. Nothing is invented and nothing moves.
//   * **suppress** — a mutant oracle. Suppressing a lane destroys information, so the
//     honest map from 21 source combinations to 21 report projections is injective while
//     both suppression mutants collapse it: dropping the provenance lane leaves at most 3
//     distinct projections and dropping the pixel lane at most 7. The real sweep is required
//     to be injective *and* to differ from each mutant at every combination the mutant
//     actually lost information at.
//   * **rank** — three independent statements. Order independence: the projection is
//     identical across all six operation orders, so no lane wins by resolving first.
//     Single-lane independence: with one lane held fixed, moving the other leaves the fixed
//     lane's projection constant in every case — Requirements 7.4 and 7.5 read at the
//     report. And a mutant: the winner-take-all variant, which reports both slots from the
//     dominant lane, collapses the sweep to at most 3 projections, and the real sweep is
//     required to differ from it.
//   * **add** — absent provenance, an unavailable lane, and the Insufficient Evidence
//     Outcome are never promoted. Each has one forbidden promotion inside the closed
//     vocabulary — absent to validated, unavailable to absent, insufficient to the
//     non-positive label — and the real projection is required to differ from each promoted
//     variant while the two lanes stay exactly what resolved. Asserted with a *hostile*
//     classifier that declares every enabled combination contradictory, so the additive path
//     is open in every case rather than dormant. An unavailable lane additionally cannot gain
//     a summary at all: the report is refused rather than built.
//
// The mutant oracles follow Property 17's pattern deliberately. Computing the wrong answer
// beside the right one and requiring them to differ is what makes agreement a decision
// rather than a coincidence; each mutant is also required to differ from the pre-image, so a
// mutant that lost nothing cannot make its arm pass vacuously.
//
// ## Nothing here decides a release value
//
// Which lane combinations a release calls apparently inconsistent, what the notice says, and
// what any Combined Summary says are unresolved external decisions. This file generates a
// declared contradiction set and an already-resolved summary and asserts only what the
// *join* does with them. No arm claims a declared set is correct, no arm claims a summary's
// wording is correct, and **no fusion rule table is built, validated, or looked up** — a
// Combined Summary appears here only as the thing that must not interfere. Task 9.8 owns
// fusion, task 9.9 owns the approved offline fixtures, and no trust outcome or fusion
// mapping is invented anywhere below.
//
// ## Neighbouring properties, and what this file does not assert
//
//   * **Property 19** owns whether provenance is enabled at all. Here both compositions are
//     inputs: a session bound to a policy resolves an available lane, one bound to none
//     resolves the unavailable lane.
//   * **Property 20** owns the projection from a validator outcome onto one of the five
//     states. Here an enabled state is a given value; no outcome is mapped.
//   * **Property 22** owns fusion's exhaustiveness and determinism.
//   * Requirements 7.2 and 7.3 are presentation claims about visible cards. No arm here
//     states what a user is shown; task 11.3 owns that.
//   * `EvidenceCoordinatorTests` and `EvidenceLaneJoinTests` pin each behaviour at one
//     example. This file quantifies the same statements over generated payloads, declared
//     sets, byte statuses, quality records, scopes, and every combination and order.
//
// ## Why no arm throws
//
// `propertyCheck` discards an error thrown from its body: a `throw` before the assertions
// reports a passing run in milliseconds with every arm skipped. Every construction of a
// report therefore goes through ``LaneScenario/attempt(_:lanes:summary:)``, which turns an
// ``EvidenceJoinFault`` into a ``ReportAttempt`` value, every fixture helper reports through
// `Issue.record`, and nothing below rethrows. ``LaneVariationWitness`` counts the cases,
// joins, reports, comparisons, and mutant comparisons *outside* the body, where an issue is
// not suppressed, and additionally requires every one of the 21 combinations, every pixel
// label, every provenance category, both unavailable reasons, both notice states, both
// summary states, and the refusal to have been **produced** over the run. A pure value-level
// property is legitimately fast, so the clock proves nothing and those counts are what stand
// in for it.

extension Tag {
    /// Design Property 21.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property21EvidenceLaneNoninterference: Self
}

@Suite(
    "Property 21: Evidence lanes are immutable and noninterfering",
    .tags(.property21EvidenceLaneNoninterference)
)
struct EvidenceLaneNoninterferencePropertyTests {
    /// Runs at the library default of 100 generated cases with shrinking, which is the
    /// minimum the design requires; `PropertyToolchainWiringTests` pins that default.
    /// Every generator is composed with `zip`, so the shrinkers compose.
    ///
    /// **Validates: Requirements 7.1, 7.4, 7.5, 7.6, 7.7, 7.8, 7.13**
    @Test("Lanes stay immutable and noninterfering over every combination and order")
    func evidenceLanesAreImmutableAndNoninterfering() async {
        let witness = LaneVariationWitness()

        await propertyCheck(input: LaneShape.generator) { shape in
            witness.record(shape)
            guard let scenario = LaneScenario(shape: shape, witness: witness) else { return }

            scenario.checkJoinsAreImmutableUnderEveryOrder()
            scenario.checkReportLanesEqualTheirSources()
            scenario.checkNoticeAndSummaryMutateNeitherLane()
            scenario.checkNeitherLaneIsSuppressed()
            scenario.checkNeitherLaneIsRanked()
            scenario.checkAbsentAndInsufficientAddNothing()
            scenario.checkAnUnavailableLaneCannotGainASummary()
            scenario.checkLanesAreIndependentOfTheBoundScope()

            witness.recordCompletedArms()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - The two answers a join can produce

/// The result of one attempt to construct a report, as a value rather than control flow.
///
/// Two cases, because the coordinator has exactly two results. Turning the refusal into a
/// value is what keeps an arm from ending early by letting an error escape into
/// `propertyCheck`, which discards it.
private enum ReportAttempt {
    case report(EvidenceReport)
    case fault(EvidenceJoinFault)

    var report: EvidenceReport? {
        if case let .report(report) = self { return report }
        return nil
    }

    var fault: EvidenceJoinFault? {
        if case let .fault(fault) = self { return fault }
        return nil
    }
}

// MARK: - Structural lane rendering

/// One source lane pair rendered field by field, including every payload detail.
///
/// The comparison unit for every arm. `==` on ``PixelEvidence`` and ``ProvenanceLane`` would
/// already catch a swapped case, but not a lane that kept its category and quietly lost its
/// signer fields, its explanation key, or the policy version it attributes itself to. This
/// renders all of it, so "the lane is unchanged" means the whole value is unchanged.
///
/// Deliberately built from *either* side: from the two lane values a branch produced, or
/// from a constructed report. The two are then required to be equal, which is what makes the
/// oracle independent of the code under test — the expectation is the source lanes
/// themselves, not another reading of the report.
private struct LaneProjection: Hashable, CustomStringConvertible {
    /// The pixel label's encoded artifact key.
    let pixel: String

    /// The lane kind and its state or reason.
    let provenanceLane: String

    /// The enabled state's whole payload, or the empty string when it carries none.
    let provenanceDetail: String

    /// The Provenance Policy version the state attributes itself to, or the empty string.
    let attributedPolicy: String

    init(pixel: PixelEvidence, provenance: ProvenanceLane) {
        self.pixel = pixel.labelKey.rawValue
        switch provenance {
        case let .unavailable(reason):
            self.provenanceLane = "unavailable/\(reason.rawValue)"
            self.provenanceDetail = ""
            self.attributedPolicy = ""
        case let .available(evidence):
            self.provenanceLane = "available/\(evidence.stateKey.rawValue)"
            self.provenanceDetail = Self.detail(of: evidence)
            self.attributedPolicy = Self.policy(of: evidence)
        }
    }

    init(_ report: EvidenceReport) {
        self.init(pixel: report.pixel, provenance: report.provenance)
    }

    init(_ lanes: ResolvedEvidenceLanes) {
        self.init(pixel: lanes.pixel, provenance: lanes.provenance)
    }

    /// A projection with only the pixel slot filled.
    ///
    /// The provenance-suppression mutant: what a report that dropped the provenance lane
    /// would render. Not reachable through any production path, which is the point.
    var droppingProvenance: LaneProjection {
        LaneProjection(
            pixel: pixel,
            provenanceLane: "",
            provenanceDetail: "",
            attributedPolicy: ""
        )
    }

    /// A projection with only the provenance slots filled.
    var droppingPixel: LaneProjection {
        LaneProjection(
            pixel: "",
            provenanceLane: provenanceLane,
            provenanceDetail: provenanceDetail,
            attributedPolicy: attributedPolicy
        )
    }

    /// A projection in which the pixel lane won and reports both slots.
    ///
    /// The ranking mutant. Ranking is a structural collapse — one lane speaks for the pair —
    /// so the mutant is defined positionally and needs no mapping between a label and a
    /// state. Nothing here says which lane a release *would* prefer, only what a report
    /// looks like once one of them has.
    var rankedByPixel: LaneProjection {
        LaneProjection(
            pixel: pixel,
            provenanceLane: pixel,
            provenanceDetail: "",
            attributedPolicy: ""
        )
    }

    /// A projection in which the provenance lane won and reports both slots.
    var rankedByProvenance: LaneProjection {
        LaneProjection(
            pixel: provenanceLane,
            provenanceLane: provenanceLane,
            provenanceDetail: provenanceDetail,
            attributedPolicy: attributedPolicy
        )
    }

    private init(
        pixel: String,
        provenanceLane: String,
        provenanceDetail: String,
        attributedPolicy: String
    ) {
        self.pixel = pixel
        self.provenanceLane = provenanceLane
        self.provenanceDetail = provenanceDetail
        self.attributedPolicy = attributedPolicy
    }

    /// How many payload details this lane carries.
    ///
    /// A separate reading from ``provenanceDetail`` so an emptied payload fails a count as
    /// well as a string comparison.
    var detailCount: Int {
        provenanceDetail.isEmpty
            ? 0 : provenanceDetail.split(separator: "\u{1F}", omittingEmptySubsequences: false).count
    }

    var description: String {
        "pixel=\(pixel) lane=\(provenanceLane) detail=\(provenanceDetail) policy=\(attributedPolicy)"
    }

    private static func detail(of evidence: ProvenanceEvidence) -> String {
        switch evidence {
        case let .validated(summary):
            return ([summary.bindingStatus.rawValue]
                + summary.signerFields.map(render) + summary.assertionFields.map(render))
                .joined(separator: "\u{1F}")
        case let .invalid(summary):
            return [summary.category.rawValue, summary.explanationKey.rawValue]
                .joined(separator: "\u{1F}")
        case .absent:
            // Absent carries no payload by design: "no Content Credential was found" needs
            // no detail, and adding one would risk presenting absence as evidence
            // (Requirements 6.11 and 7.6).
            return ""
        case let .unsupported(summary):
            return ([summary.explanationKey.rawValue]
                + summary.unsupportedFeatures.map(\.description))
                .joined(separator: "\u{1F}")
        case let .indeterminate(summary):
            return summary.explanationKey.rawValue
        }
    }

    private static func policy(of evidence: ProvenanceEvidence) -> String {
        switch evidence {
        case let .validated(summary): return summary.provenancePolicyID.rawValue
        case let .invalid(summary): return summary.provenancePolicyID.rawValue
        case .absent: return ""
        case let .unsupported(summary): return summary.provenancePolicyID.rawValue
        case let .indeterminate(summary): return summary.provenancePolicyID.rawValue
        }
    }

    private static func render(_ field: DisplaySafeField) -> String {
        "\(field.labelKey.rawValue)=\(field.value.description)"
    }
}

// MARK: - Operation orders

/// One order in which the two branches resolve their lanes.
///
/// The two base orders, each also extended with a late duplicate write for one lane. A
/// duplicate is the only remaining path by which one branch could change an answer the join
/// already holds, so it belongs in the order sweep rather than in a separate example.
private enum LaneOperationOrder: String, CaseIterable {
    case pixelThenProvenance
    case provenanceThenPixel
    case pixelThenProvenanceThenLatePixel
    case pixelThenProvenanceThenLateProvenance
    case provenanceThenPixelThenLatePixel
    case provenanceThenPixelThenLateProvenance

    /// Whether the pixel lane resolves first.
    var pixelFirst: Bool {
        switch self {
        case .pixelThenProvenance,
             .pixelThenProvenanceThenLatePixel,
             .pixelThenProvenanceThenLateProvenance:
            return true
        case .provenanceThenPixel,
             .provenanceThenPixelThenLatePixel,
             .provenanceThenPixelThenLateProvenance:
            return false
        }
    }

    /// Which lane a late duplicate write targets, or `nil` when this order has none.
    var lateWrite: EvidenceSourceLane? {
        switch self {
        case .pixelThenProvenance, .provenanceThenPixel:
            return nil
        case .pixelThenProvenanceThenLatePixel, .provenanceThenPixelThenLatePixel:
            return .pixel
        case .pixelThenProvenanceThenLateProvenance, .provenanceThenPixelThenLateProvenance:
            return .provenance
        }
    }
}

// MARK: - Generated shape

/// Everything one generated case decides, as plain data.
///
/// The generator produces integers only. Coordinators, classifiers, lanes, and summaries are
/// built from them inside the scenario, where a construction that unexpectedly fails is
/// recorded as an issue rather than thrown: `propertyCheck` discards an error thrown by its
/// body, so a refusal that escaped as a throw would report a passing test with every arm
/// skipped.
///
/// ## How the baseline varies
///
/// A property whose baseline is one lane pair with one field flipped asserts one example a
/// hundred times over. The 21 combinations and 6 orders are swept exhaustively in every
/// case, so what the generator varies is everything *around* them:
///
///   * the declared contradiction set, over the nonempty subsets of the 15 enabled
///     combinations, so the notice path is open for some combinations and closed for others
///     within the same case;
///   * whether the release declared a classifier at all, so both the notice-capable and the
///     notice-free composition are exercised;
///   * which combinations are offered a Combined Summary, so a summary is present for some
///     lanes and absent for others while the lanes are held identical;
///   * the payload of each enabled state — how many signer fields, how many assertion
///     fields, how many named unsupported features, which invalidity category, and the
///     display-safe text reported — so "the whole payload survived" is asserted over varying
///     payloads rather than over one;
///   * the Byte Preservation Status, the recorded pre-orientation dimensions, and the
///     on-device flag, which are report fields a lane must not depend on; and
///   * the bound evidence-scope artifact version, which the lanes must also not depend on.
///
/// ``LaneVariationWitness`` checks after the run that this happened.
private struct LaneShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic identifier, so a case's reference set varies together.
    let seed: Int

    /// Selects one of the nonempty subsets of the 15 enabled lane combinations.
    let declaredCombinationBits: Int

    /// Selects whether this release declared an apparent-inconsistency classifier.
    let classifierPresenceIndex: Int

    /// Rotates which combinations in the sweep are offered a Combined Summary.
    let summaryOfferBits: Int

    /// How many signer fields the validated state reports.
    let signerFieldCount: Int

    /// How many assertion fields the validated state reports.
    let assertionFieldCount: Int

    /// How many features the unsupported state names. At least one: a state that named none
    /// would carry no reason for being unsupported.
    let unsupportedFeatureCount: Int

    /// Varies the display-safe text the payloads report.
    let detailTextIndex: Int

    /// Selects which of the three invalidity categories the invalid state names.
    let invalidityCategoryIndex: Int

    /// Selects the Byte Preservation Status recorded for the session.
    let bytePreservationIndex: Int

    /// The recorded pre-orientation decoded dimensions.
    let qualityWidth: Int
    let qualityHeight: Int

    /// Selects the on-device-processing flag.
    let onDeviceIndex: Int

    /// Selects which of two evidence-scope artifact versions the session is bound to.
    let scopeVariantIndex: Int

    // MARK: Derived

    /// Whether this release declared a classifier.
    var declaresClassifier: Bool { classifierPresenceIndex % 2 == 0 }

    /// The enabled combinations this release declared apparently inconsistent. Never empty:
    /// ``ApparentInconsistencyClassifier`` refuses an empty set, because a release that
    /// declares no contradictions has no classifier rather than an empty one.
    var declaredCombinations: Set<FusionLaneCombination> {
        let all = FusionLaneCombination.allCombinations
        let bits = (declaredCombinationBits % ((1 << all.count) - 1)) + 1
        var declared: Set<FusionLaneCombination> = []
        for (index, combination) in all.enumerated() where bits & (1 << index) != 0 {
            declared.insert(combination)
        }
        return declared
    }

    var invalidityCategory: InvalidityCategory {
        InvalidityCategory.allCases[invalidityCategoryIndex % InvalidityCategory.allCases.count]
    }

    var bytePreservationStatus: BytePreservationStatus {
        BytePreservationStatus.allCases[
            bytePreservationIndex % BytePreservationStatus.allCases.count
        ]
    }

    var onDeviceProcessing: Bool { onDeviceIndex % 2 == 0 }

    /// Whether the combination at `index` in the sweep is offered a Combined Summary.
    func offersSummary(at index: Int) -> Bool {
        summaryOfferBits & (1 << (index % 16)) != 0
    }

    var description: String {
        """
        seed \(seed), declaredCombinations \(declaredCombinations.count), \
        classifier \(declaresClassifier), summaryBits \(summaryOfferBits), \
        signerFields \(signerFieldCount), assertionFields \(assertionFieldCount), \
        unsupportedFeatures \(unsupportedFeatureCount), textIndex \(detailTextIndex), \
        invalidity \(invalidityCategory.rawValue), \
        byteStatus \(bytePreservationStatus.rawValue), \
        dimensions \(qualityWidth)x\(qualityHeight), onDevice \(onDeviceProcessing), \
        scopeVariant \(scopeVariantIndex % 2)
        """
    }

    // MARK: Generators

    static var generator: Generator<LaneShape, AnySequence<Any>> {
        zip(Gen.int(in: 0...9_999), releaseShape, payloadShape, reportShape)
            .map { raw in
                LaneShape(
                    seed: raw.0,
                    declaredCombinationBits: raw.1.0,
                    classifierPresenceIndex: raw.1.1,
                    summaryOfferBits: raw.1.2,
                    signerFieldCount: raw.2.0,
                    assertionFieldCount: raw.2.1,
                    unsupportedFeatureCount: raw.2.2,
                    detailTextIndex: raw.2.3,
                    invalidityCategoryIndex: raw.2.4,
                    bytePreservationIndex: raw.3.0,
                    qualityWidth: raw.3.1,
                    qualityHeight: raw.3.2,
                    onDeviceIndex: raw.3.3,
                    scopeVariantIndex: raw.3.4
                )
            }
            .eraseToAny()
    }

    /// What the release declared: the contradiction set, whether a classifier exists, and
    /// which combinations are offered a summary.
    private static var releaseShape: Generator<(Int, Int, Int), AnySequence<Any>> {
        zip(
            Gen.int(in: 0...32_766),
            Gen.int(in: 0...199),
            Gen.int(in: 0...65_535)
        )
        .eraseToAny()
    }

    /// The enabled states' payloads.
    ///
    /// Detail counts stay small: this property is about whether a payload survives a join,
    /// and a list at the display contract's own ceiling would make the answer depend on that
    /// bound instead.
    private static var payloadShape: Generator<(Int, Int, Int, Int, Int), AnySequence<Any>> {
        zip(
            Gen.int(in: 0...3),
            Gen.int(in: 0...3),
            Gen.int(in: 1...3),
            Gen.int(in: 0...199),
            Gen.int(in: 0...199)
        )
        .eraseToAny()
    }

    /// The report fields a lane must not depend on, and the bound scope version.
    private static var reportShape: Generator<(Int, Int, Int, Int, Int), AnySequence<Any>> {
        zip(
            Gen.int(in: 0...199),
            Gen.int(in: 1...4_096),
            Gen.int(in: 1...4_096),
            Gen.int(in: 0...199),
            Gen.int(in: 0...199)
        )
        .eraseToAny()
    }
}

// MARK: - Generated artifacts

/// The synthetic artifacts one generated case needs in order to call the coordinator.
///
/// **No value here is an approved release input, and nothing here may be copied into one.**
/// The declared contradiction set, the notice wording, the summary wording, the signer and
/// assertion content, the named unsupported features, and every identifier are unresolved
/// external decisions. No assertion below claims any of them is correct; each asserts what
/// the *join* does with a given input, and what stays fixed when an input changes.
private struct LaneArtifacts {
    /// The five enabled states, payloads drawn from the shape.
    let enabledStates: [ProvenanceEvidence]

    /// Every lane a session can resolve: five enabled states plus both unavailable reasons.
    let lanes: [ProvenanceLane]

    /// The classifier this release declared, or `nil` when it declared none.
    let classifier: ApparentInconsistencyClassifier?

    /// A classifier that declares every enabled combination contradictory.
    ///
    /// The hostile case. Every additive arm runs against it so the notice path is open in
    /// every combination rather than dormant in most of them.
    let hostileClassifier: ApparentInconsistencyClassifier

    /// An already-resolved Combined Summary attributed to the session's bound rule.
    ///
    /// A value, not a lookup. Fusion is task 9.8's subject; here a summary exists only as
    /// something that must not touch a lane.
    let summary: CombinedSummary

    /// The evidence scope this case's sessions are bound to.
    let scope: EvidenceScope

    /// A second scope version, differing only in its artifact identifier.
    let alternateScope: EvidenceScope

    init?(shape: LaneShape) {
        let text = "p21.detail-\(shape.detailTextIndex % 97)"
        let signerFields = (0..<shape.signerFieldCount).map { index in
            DisplaySafeField(
                labelKey: EvidenceSample.copyKey("copy.provenance.field.signer-\(index)"),
                value: EvidenceSample.displayText("\(text).signer-\(index)")
            )
        }
        let assertionFields = (0..<shape.assertionFieldCount).map { index in
            DisplaySafeField(
                labelKey: EvidenceSample.copyKey("copy.provenance.field.assertion-\(index)"),
                value: EvidenceSample.displayText("\(text).assertion-\(index)")
            )
        }
        let features = (0..<shape.unsupportedFeatureCount).map { index in
            EvidenceSample.displayText("\(text).feature-\(index)")
        }

        let states: [ProvenanceEvidence] = [
            .validated(
                ValidatedClaimSummary(
                    provenancePolicyID: ProvenanceSample.policyID,
                    bindingStatus: .boundToInspectedBytes,
                    signerFields: signerFields,
                    assertionFields: assertionFields
                )
            ),
            .invalid(
                InvaliditySummary(
                    provenancePolicyID: ProvenanceSample.policyID,
                    category: shape.invalidityCategory,
                    explanationKey: EvidenceSample.copyKey(
                        "copy.provenance.state.invalid.\(shape.invalidityCategory.rawValue)"
                    )
                )
            ),
            .absent,
            .unsupported(
                UnsupportedFeatureSummary(
                    provenancePolicyID: ProvenanceSample.policyID,
                    explanationKey: EvidenceSample.copyKey("copy.provenance.state.unsupported"),
                    unsupportedFeatures: features
                )
            ),
            .indeterminate(
                IndeterminateSummary(
                    provenancePolicyID: ProvenanceSample.policyID,
                    explanationKey: EvidenceSample.copyKey("copy.provenance.state.indeterminate")
                )
            ),
        ]

        let catalog = CopyCatalogSample.catalog()
        guard let hostile = ApparentInconsistencyClassifier(
            catalog: catalog,
            contradictoryCombinations: Set(FusionLaneCombination.allCombinations)
        ) else {
            Issue.record("the hostile classifier must be constructible [\(shape)]")
            return nil
        }
        if shape.declaresClassifier {
            guard let declared = ApparentInconsistencyClassifier(
                catalog: catalog,
                contradictoryCombinations: shape.declaredCombinations
            ) else {
                Issue.record("a nonempty declared set must build a classifier [\(shape)]")
                return nil
            }
            self.classifier = declared
        } else {
            self.classifier = nil
        }

        self.enabledStates = states
        self.lanes =
            states.map(ProvenanceLane.available)
            + UnavailableReason.allCases.map(ProvenanceLane.unavailable)
        self.hostileClassifier = hostile
        self.summary = CombinedSummary(
            copyKey: EvidenceSample.copyKey("copy.combined-summary.p21-\(shape.seed % 13)"),
            fusionRuleID: SessionSample.fusionRuleID
        )
        self.scope = .version1(id: Fixture.artifactID("evidence-scope-p21-a"))
        self.alternateScope = .version1(id: Fixture.artifactID("evidence-scope-p21-b"))
    }
}

// MARK: - Scenario

/// One generated case: its artifacts, and the arms it runs.
///
/// Construction is failable rather than throwing so the property body can record an issue
/// and return.
private struct LaneScenario {
    let shape: LaneShape
    private let witness: LaneVariationWitness
    private let artifacts: LaneArtifacts

    /// The pixel labels, in vocabulary order.
    private let pixelLabels = PixelEvidence.allCases

    init?(shape: LaneShape, witness: LaneVariationWitness) {
        guard let artifacts = LaneArtifacts(shape: shape) else { return nil }
        self.shape = shape
        self.witness = witness
        self.artifacts = artifacts
    }

    // MARK: The sweep

    /// Every lane combination this case exercises: 3 pixel labels x 7 lane states.
    ///
    /// Exhaustive rather than sampled. "Generate every lane combination" is a claim about the
    /// whole closed product, and a generator that drew one combination per case would leave
    /// coverage of the product to a distribution.
    private var combinations: [(index: Int, pixel: PixelEvidence, lane: ProvenanceLane)] {
        var swept: [(Int, PixelEvidence, ProvenanceLane)] = []
        var index = 0
        for pixel in pixelLabels {
            for lane in artifacts.lanes {
                swept.append((index, pixel, lane))
                index += 1
            }
        }
        return swept
    }

    // MARK: Coordinators, never a thrown error

    /// A coordinator for a composition that matches `lane`.
    ///
    /// A session records a Provenance Policy version exactly when its composition resolved an
    /// available lane, so the binding follows the lane rather than being chosen independently.
    /// `boundToFusionRule` is what a session bound to an approved Evidence Fusion Rule looks
    /// like; this file does not decide whether such a rule exists.
    private func coordinator(
        for lane: ProvenanceLane,
        classifier: ApparentInconsistencyClassifier?,
        boundToFusionRule: Bool,
        scope: EvidenceScope? = nil
    ) -> EvidenceCoordinator? {
        let binding = SessionSample.binding(
            provenancePolicyID: lane.isAvailable ? ProvenanceSample.policyID : nil,
            fusionRuleID: boundToFusionRule ? SessionSample.fusionRuleID : nil
        )
        guard let coordinator = EvidenceCoordinator(
            binding: binding,
            scope: scope ?? artifacts.scope,
            inconsistencyClassifier: classifier
        ) else {
            witness.recordUnbuildableInput()
            Issue.record("the coordinator must accept its own generated inputs [\(shape)]")
            return nil
        }
        return coordinator
    }

    /// The result of one report construction, recorded with the witness.
    ///
    /// The only path from an arm to the coordinator. A refusal becomes a value here, so an
    /// arm cannot end early by letting an error escape into `propertyCheck`.
    private func attempt(
        _ coordinator: EvidenceCoordinator,
        lanes: ResolvedEvidenceLanes,
        summary: CombinedSummary?
    ) -> ReportAttempt {
        let attempt: ReportAttempt
        do {
            attempt = .report(
                try coordinator.report(
                    lanes: lanes,
                    combinedSummary: summary,
                    bytePreservationStatus: shape.bytePreservationStatus,
                    inputQuality: qualityRecord(),
                    onDeviceProcessing: shape.onDeviceProcessing
                )
            )
        } catch {
            attempt = .fault(error)
        }
        witness.recordAttempt(attempt, lanes: lanes, summaryOffered: summary != nil)
        return attempt
    }

    /// The pre-orientation measurements recorded for this case's sessions.
    private func qualityRecord() -> InputQualityRecord {
        guard let record = InputQualityRecord(
            decodedWidthBeforeOrientation: shape.qualityWidth,
            decodedHeightBeforeOrientation: shape.qualityHeight
        ) else {
            witness.recordUnbuildableInput()
            Issue.record("positive generated dimensions must build a record [\(shape)]")
            return .unmeasured
        }
        return record
    }

    /// The report for one combination, or `nil` when it was refused.
    ///
    /// Refusals are legitimate for some configurations — a summary beside an unavailable lane
    /// is not representable — so an arm that needs a report skips a refused one and the
    /// dedicated refusal arm asserts the refusal itself.
    private func report(
        pixel: PixelEvidence,
        lane: ProvenanceLane,
        classifier: ApparentInconsistencyClassifier?,
        summary: CombinedSummary?,
        scope: EvidenceScope? = nil
    ) -> EvidenceReport? {
        guard let coordinator = coordinator(
            for: lane,
            classifier: classifier,
            boundToFusionRule: summary != nil,
            scope: scope
        ) else { return nil }
        return attempt(
            coordinator,
            lanes: ResolvedEvidenceLanes(pixel: pixel, provenance: lane),
            summary: summary
        ).report
    }

    // MARK: Arm 1 — immutable under every operation order

    /// Requirements 7.1, 7.4, and 7.5: resolving one lane leaves the other unchanged, in
    /// every order, including when a late duplicate arrives.
    ///
    /// Three separate statements per combination and order:
    ///
    ///   * the join value that existed before the second lane resolved is *still* that value
    ///     afterwards, holding its own lane and no other. Recording a lane returns a new
    ///     join, so the earlier value is observable, which is what makes noninterference a
    ///     measurement rather than a comment;
    ///   * the completed join's two lanes are structurally equal to the two source values;
    ///     and
    ///   * a duplicate write for an already-resolved lane is refused, and the join it was
    ///     called on is unchanged. Applying it would be the one path by which a late callback
    ///     could change an answer the join already holds.
    ///
    /// Order independence is asserted here at the join and again at the report in the
    /// ranking arm, because a join that is order-independent could still be read
    /// order-dependently.
    func checkJoinsAreImmutableUnderEveryOrder() {
        for (_, pixel, lane) in combinations {
            let expected = LaneProjection(pixel: pixel, provenance: lane)
            var projectionsByOrder: Set<LaneProjection> = []

            for order in LaneOperationOrder.allCases {
                witness.recordOrder(order)
                guard let joined = join(pixel: pixel, lane: lane, order: order, expected: expected)
                else { continue }
                projectionsByOrder.insert(LaneProjection(joined))
            }

            // One projection across all six orders: no order produced a different answer.
            witness.recordComparison()
            #expect(
                projectionsByOrder == [expected],
                """
                the joined lanes differ across operation orders: \
                \(projectionsByOrder.map(\.description).sorted()) [\(shape)]
                """
            )
        }
    }

    /// Builds one join in `order`, asserting immutability at each step.
    private func join(
        pixel: PixelEvidence,
        lane: ProvenanceLane,
        order: LaneOperationOrder,
        expected: LaneProjection
    ) -> ResolvedEvidenceLanes? {
        let unresolved = EvidenceLaneJoin.unresolved
        witness.recordJoin()

        // The first write. Only one lane is named, so the other cannot have been reached.
        guard let first = order.pixelFirst
            ? unresolved.resolving(pixel: pixel)
            : unresolved.resolving(provenance: lane)
        else {
            witness.recordUnbuildableInput()
            Issue.record("an unresolved join must accept its first lane [\(shape)]")
            return nil
        }

        // Exactly one lane resolved, and it is the one that was written.
        witness.recordComparison()
        if order.pixelFirst {
            #expect(first.pixel == pixel, "the first write did not record its lane [\(shape)]")
            #expect(first.provenance == nil, "resolving pixel reached the provenance lane [\(shape)]")
            #expect(first.unresolvedLanes == [.provenance], "wrong pending lane [\(shape)]")
        } else {
            #expect(first.provenance == lane, "the first write did not record its lane [\(shape)]")
            #expect(first.pixel == nil, "resolving provenance reached the pixel lane [\(shape)]")
            #expect(first.unresolvedLanes == [.pixel], "wrong pending lane [\(shape)]")
        }
        #expect(first.isComplete == false, "one resolved lane is not a complete join [\(shape)]")
        #expect(first.resolvedLanes == nil, "an incomplete join yielded a report input [\(shape)]")

        guard let second = order.pixelFirst
            ? first.resolving(provenance: lane)
            : first.resolving(pixel: pixel)
        else {
            witness.recordUnbuildableInput()
            Issue.record("a half-resolved join must accept its other lane [\(shape)]")
            return nil
        }

        // The value that existed before the second write still holds exactly what it held.
        // This is the assertion the whole property rests on: the earlier join was not
        // mutated in place, so neither branch can have observed or altered the other.
        witness.recordComparison()
        if order.pixelFirst {
            #expect(first.pixel == pixel, "the earlier join's pixel lane moved [\(shape)]")
            #expect(
                first.provenance == nil,
                "resolving provenance wrote into the earlier join [\(shape)]"
            )
        } else {
            #expect(first.provenance == lane, "the earlier join's provenance lane moved [\(shape)]")
            #expect(first.pixel == nil, "resolving pixel wrote into the earlier join [\(shape)]")
        }

        // A late duplicate is refused, and refusing it changes nothing.
        if let late = order.lateWrite {
            let refused: EvidenceLaneJoin? = late == .pixel
                ? second.resolving(pixel: pixelLabels.first { $0 != pixel } ?? pixel)
                : second.resolving(provenance: differentLane(from: lane))
            witness.recordLateWrite(refused: refused == nil)
            #expect(
                refused == nil,
                "a duplicate \(late.rawValue) write was applied to a resolved lane [\(shape)]"
            )
            #expect(
                LaneProjection(pixel: second.pixel ?? pixel, provenance: second.provenance ?? lane)
                    == expected,
                "a refused duplicate write still moved a lane [\(shape)]"
            )
        }

        guard let resolved = second.resolvedLanes else {
            witness.recordUnbuildableInput()
            Issue.record("a join with both lanes must yield report input [\(shape)]")
            return nil
        }
        #expect(second.isComplete, "both lanes resolved but the join is incomplete [\(shape)]")
        #expect(second.unresolvedLanes.isEmpty, "a complete join still reports pending [\(shape)]")
        return resolved
    }

    /// Some lane other than `lane`, for the duplicate-write attempt.
    private func differentLane(from lane: ProvenanceLane) -> ProvenanceLane {
        artifacts.lanes.first { $0 != lane } ?? lane
    }

    // MARK: Arm 2 — the report's lanes are its sources

    /// Requirement 7.1: the report's two lane fields are the two resolved lanes, whole.
    ///
    /// The oracle is the source lanes themselves, rendered through ``LaneProjection``
    /// independently of the report. Every payload detail is compared, and the detail *count*
    /// is compared separately, so a lane that kept its category and lost its signer fields,
    /// its explanation key, its named features, or its attributed policy version fails here
    /// rather than passing an enum comparison.
    func checkReportLanesEqualTheirSources() {
        for (index, pixel, lane) in combinations {
            let expected = LaneProjection(pixel: pixel, provenance: lane)
            let summary = lane.isAvailable && shape.offersSummary(at: index)
                ? artifacts.summary : nil

            guard let report = report(
                pixel: pixel,
                lane: lane,
                classifier: artifacts.classifier,
                summary: summary
            ) else { continue }

            let produced = LaneProjection(report)
            witness.recordComparison()
            #expect(
                produced == expected,
                "the report's lanes are \(produced), the sources were \(expected) [\(shape)]"
            )
            #expect(
                produced.detailCount == expected.detailCount,
                """
                the report's provenance lane carries \(produced.detailCount) details, the \
                source carried \(expected.detailCount) [\(shape)]
                """
            )
            // The two lanes are separate immutable fields, reachable independently. Reading
            // one does not require reading the other, which is Requirement 7.1's structure.
            #expect(report.pixel == pixel, "the pixel lane field moved [\(shape)]")
            #expect(report.provenance == lane, "the provenance lane field moved [\(shape)]")
        }
    }

    // MARK: Arm 3 — verb one: mutate

    /// Requirements 7.8 and 7.13: a notice or a summary never mutates either lane.
    ///
    /// The same two lanes are joined four ways — plain, with a notice-capable classifier,
    /// with a summary, with both — and all four reports must have the *identical* lane
    /// projection. What differs is only the additive fields, and those are then required to
    /// be exactly the inputs that were offered: the notice is the classifier's own catalogue
    /// key or nothing, and the summary is the value that was passed in or nothing. A report
    /// therefore cannot have invented either one.
    ///
    /// Run over the 15 enabled combinations, which are the ones where all four
    /// configurations are representable. The unavailable lane's refusal is its own arm.
    func checkNoticeAndSummaryMutateNeitherLane() {
        for (_, pixel, lane) in combinations where lane.isAvailable {
            let expected = LaneProjection(pixel: pixel, provenance: lane)

            let plain = report(pixel: pixel, lane: lane, classifier: nil, summary: nil)
            let noticed = report(
                pixel: pixel, lane: lane, classifier: artifacts.hostileClassifier, summary: nil
            )
            let summarized = report(
                pixel: pixel, lane: lane, classifier: nil, summary: artifacts.summary
            )
            let both = report(
                pixel: pixel,
                lane: lane,
                classifier: artifacts.hostileClassifier,
                summary: artifacts.summary
            )
            guard let plain, let noticed, let summarized, let both else { continue }

            witness.recordMutationCheck()
            let projections = Set([plain, noticed, summarized, both].map(LaneProjection.init))
            #expect(
                projections == [expected],
                """
                adding a notice or a summary moved a lane: \
                \(projections.map(\.description).sorted()) [\(shape)]
                """
            )

            // The additive fields are additive: present or absent, never a third value.
            #expect(plain.apparentInconsistency == nil, "a notice appeared with no classifier [\(shape)]")
            #expect(plain.combinedSummary == nil, "a summary appeared with none offered [\(shape)]")
            #expect(
                noticed.apparentInconsistency == artifacts.hostileClassifier.noticeKey,
                "the notice is not the classifier's approved key [\(shape)]"
            )
            #expect(
                summarized.combinedSummary == artifacts.summary,
                "the summary is not the value that was offered [\(shape)]"
            )
            #expect(
                both.apparentInconsistency == artifacts.hostileClassifier.noticeKey,
                "a summary beside a notice changed the notice [\(shape)]"
            )
            #expect(
                both.combinedSummary == artifacts.summary,
                "a notice beside a summary changed the summary [\(shape)]"
            )
            // Requirement 7.13 in one line: both immutable lane fields, alongside the summary.
            #expect(
                both.pixel == pixel && both.provenance == lane,
                "a lane did not survive a Combined Summary [\(shape)]"
            )
        }
    }

    // MARK: Arm 4 — verb two: suppress

    /// Requirement 7.8: neither lane is suppressed.
    ///
    /// Suppression destroys information, so the claim is about what the map from source lanes
    /// to report lanes preserves. Two readings, and the property needs both:
    ///
    ///   * **injectivity.** All 21 combinations produce 21 distinct projections. A report
    ///     that dropped the provenance lane would produce at most 3, and one that dropped the
    ///     pixel lane at most 7, so a collapse is visible in the cardinality alone. The
    ///     mutant sweeps are computed alongside and required to collapse, which is the
    ///     control: if a mutant did *not* lose information, this arm could not see the defect
    ///     it exists for.
    ///   * **per-combination difference.** At every combination, the real projection differs
    ///     from both suppression mutants, and each mutant differs from the pre-image. The
    ///     first without the second would pass on any two unequal values.
    func checkNeitherLaneIsSuppressed() {
        var honest: Set<LaneProjection> = []
        var withoutProvenance: Set<LaneProjection> = []
        var withoutPixel: Set<LaneProjection> = []

        for (index, pixel, lane) in combinations {
            let expected = LaneProjection(pixel: pixel, provenance: lane)
            let summary = lane.isAvailable && shape.offersSummary(at: index)
                ? artifacts.summary : nil
            guard let report = report(
                pixel: pixel,
                lane: lane,
                classifier: artifacts.hostileClassifier,
                summary: summary
            ) else { continue }

            let produced = LaneProjection(report)
            honest.insert(produced)
            withoutProvenance.insert(expected.droppingProvenance)
            withoutPixel.insert(expected.droppingPixel)

            witness.recordSuppressionMutant()
            // The controls: each mutant really did lose something.
            #expect(
                expected.droppingProvenance != expected,
                "the provenance-suppression mutant lost nothing [\(shape)]"
            )
            #expect(
                expected.droppingPixel != expected,
                "the pixel-suppression mutant lost nothing [\(shape)]"
            )
            // The claim.
            #expect(
                produced != expected.droppingProvenance,
                "the report is what a suppressed provenance lane produces [\(shape)]"
            )
            #expect(
                produced != expected.droppingPixel,
                "the report is what a suppressed pixel lane produces [\(shape)]"
            )
            // A suppressed lane can also hide inside a kept category, so the payload has to
            // be non-degenerate wherever the source carried one.
            #expect(
                produced.detailCount == expected.detailCount,
                "the provenance payload was emptied while its category was kept [\(shape)]"
            )
        }

        guard !honest.isEmpty else { return }
        let swept = combinations.count
        witness.recordSuppressionMutant()
        #expect(
            honest.count == swept,
            """
            \(swept) source combinations produced only \(honest.count) distinct report lane \
            pairs, so at least two were collapsed [\(shape)]
            """
        )
        #expect(
            withoutProvenance.count < honest.count,
            """
            dropping the provenance lane collapsed nothing (\(withoutProvenance.count) of \
            \(honest.count)), so this arm cannot see the defect it exists for [\(shape)]
            """
        )
        #expect(
            withoutPixel.count < honest.count,
            """
            dropping the pixel lane collapsed nothing (\(withoutPixel.count) of \
            \(honest.count)) [\(shape)]
            """
        )
        #expect(
            honest.isDisjoint(with: withoutProvenance),
            "a report lane pair coincides with a provenance-suppressed one [\(shape)]"
        )
        #expect(
            honest.isDisjoint(with: withoutPixel),
            "a report lane pair coincides with a pixel-suppressed one [\(shape)]"
        )
    }

    // MARK: Arm 5 — verb three: rank

    /// Requirement 7.8: neither lane outranks the other.
    ///
    /// Ranking is precedence, and precedence shows up three ways. All three are asserted,
    /// because any one of them alone leaves the others open:
    ///
    ///   * **no lane wins by arriving first.** The report's projection is identical across
    ///     all six operation orders. An implementation that let the first-resolved lane
    ///     decide anything would answer differently in the opposite order.
    ///   * **no lane's value depends on the other's.** Holding the provenance lane fixed and
    ///     moving the pixel label across all three leaves the provenance projection constant,
    ///     and holding the pixel label fixed and moving the lane across all seven leaves the
    ///     pixel projection constant. This is Requirements 7.4 and 7.5 read at the report,
    ///     and it is the statement a ranking implementation cannot satisfy: ranking means one
    ///     lane's value is a function of both.
    ///   * **the pair is not reduced to a winner.** The winner-take-all mutant reports both
    ///     slots from the dominant lane and collapses the 21 combinations to at most 3, and
    ///     the real sweep must differ from it everywhere. The mutant is positional, so
    ///     nothing here invents a preference between a label and a state.
    func checkNeitherLaneIsRanked() {
        // (a) No lane wins by arriving first.
        for (_, pixel, lane) in combinations {
            var projections: Set<LaneProjection> = []
            for order in LaneOperationOrder.allCases {
                guard let joined = join(
                    pixel: pixel,
                    lane: lane,
                    order: order,
                    expected: LaneProjection(pixel: pixel, provenance: lane)
                ) else { continue }
                guard let coordinator = coordinator(
                    for: joined.provenance,
                    classifier: artifacts.hostileClassifier,
                    boundToFusionRule: false
                ) else { continue }
                guard let report = attempt(coordinator, lanes: joined, summary: nil).report
                else { continue }
                projections.insert(LaneProjection(report))
            }
            witness.recordRankingMutant()
            #expect(
                projections == [LaneProjection(pixel: pixel, provenance: lane)],
                """
                the report's lanes depend on the order the branches resolved in: \
                \(projections.map(\.description).sorted()) [\(shape)]
                """
            )
        }

        // (b) Moving one lane never moves the other.
        for lane in artifacts.lanes {
            var provenanceReadings: Set<String> = []
            var pixelReadings: [String] = []
            for pixel in pixelLabels {
                guard let report = report(
                    pixel: pixel, lane: lane, classifier: artifacts.hostileClassifier, summary: nil
                ) else { continue }
                let produced = LaneProjection(report)
                provenanceReadings.insert(
                    [produced.provenanceLane, produced.provenanceDetail, produced.attributedPolicy]
                        .joined(separator: "\u{1E}")
                )
                pixelReadings.append(produced.pixel)
            }
            witness.recordRankingMutant()
            #expect(
                provenanceReadings.count <= 1,
                """
                moving the pixel label moved the provenance lane to \
                \(provenanceReadings.sorted()) [\(shape)]
                """
            )
            // The control: the pixel lane really did move, so a constant provenance reading
            // is independence rather than a sweep that never varied anything.
            #expect(
                Set(pixelReadings).count == pixelReadings.count,
                "the pixel lane did not move across the three labels [\(shape)]"
            )
        }

        for pixel in pixelLabels {
            var pixelReadings: Set<String> = []
            var provenanceReadings: [String] = []
            for lane in artifacts.lanes {
                guard let report = report(
                    pixel: pixel, lane: lane, classifier: artifacts.hostileClassifier, summary: nil
                ) else { continue }
                let produced = LaneProjection(report)
                pixelReadings.insert(produced.pixel)
                provenanceReadings.append(
                    [produced.provenanceLane, produced.provenanceDetail].joined(separator: "\u{1E}")
                )
            }
            witness.recordRankingMutant()
            #expect(
                pixelReadings.count <= 1,
                "moving the provenance lane moved the pixel lane to \(pixelReadings.sorted()) [\(shape)]"
            )
            #expect(
                Set(provenanceReadings).count == provenanceReadings.count,
                "the provenance lane did not move across the seven states [\(shape)]"
            )
        }

        // (c) The pair is not reduced to a winner.
        var honest: Set<LaneProjection> = []
        var pixelWins: Set<LaneProjection> = []
        var provenanceWins: Set<LaneProjection> = []
        for (_, pixel, lane) in combinations {
            let expected = LaneProjection(pixel: pixel, provenance: lane)
            guard let report = report(
                pixel: pixel, lane: lane, classifier: artifacts.hostileClassifier, summary: nil
            ) else { continue }
            let produced = LaneProjection(report)
            honest.insert(produced)
            pixelWins.insert(expected.rankedByPixel)
            provenanceWins.insert(expected.rankedByProvenance)

            witness.recordRankingMutant()
            #expect(
                expected.rankedByPixel != expected,
                "the pixel-wins mutant collapsed nothing [\(shape)]"
            )
            #expect(
                expected.rankedByProvenance != expected,
                "the provenance-wins mutant collapsed nothing [\(shape)]"
            )
            #expect(
                produced != expected.rankedByPixel,
                "the report is what a pixel-ranked pair produces [\(shape)]"
            )
            #expect(
                produced != expected.rankedByProvenance,
                "the report is what a provenance-ranked pair produces [\(shape)]"
            )
        }

        guard !honest.isEmpty else { return }
        witness.recordRankingMutant()
        #expect(
            pixelWins.count < honest.count,
            """
            letting the pixel lane speak for the pair collapsed nothing \
            (\(pixelWins.count) of \(honest.count)) [\(shape)]
            """
        )
        #expect(
            provenanceWins.count < honest.count,
            """
            letting the provenance lane speak for the pair collapsed nothing \
            (\(provenanceWins.count) of \(honest.count)) [\(shape)]
            """
        )
        #expect(
            honest.isDisjoint(with: pixelWins),
            "a report lane pair coincides with a pixel-ranked one [\(shape)]"
        )
        #expect(
            honest.isDisjoint(with: provenanceWins),
            "a report lane pair coincides with a provenance-ranked one [\(shape)]"
        )
    }

    // MARK: Arm 6 — verb four: add

    /// Requirements 7.6 and 7.7: absence and insufficiency add no authenticity evidence.
    ///
    /// The three values that carry no finding each have exactly one forbidden promotion
    /// inside the closed vocabulary — `absent` to `validated`, `unavailable` to `absent`, and
    /// the Insufficient Evidence Outcome to the non-positive label — and each is required to
    /// differ from what the report produced. Naming the promotion rather than merely
    /// asserting equality is what makes the arm a claim about the *direction* an
    /// implementation would drift in: every one of those three is the substitution
    /// Requirements 8.7 and 8.8 forbid the presenter from making.
    ///
    /// Run with the hostile classifier and with a summary offered wherever one is
    /// representable, so the additive paths are open. Nothing may arrive through them but the
    /// approved notice key and the offered summary, which the mutation arm already pinned;
    /// here the claim is that neither lane gained a finding.
    func checkAbsentAndInsufficientAddNothing() {
        // Requirement 7.6: absent provenance preserves the pixel lane and adds nothing. The
        // unavailable lane is included: it is not a finding about the image either, and
        // Requirement 8.8 forbids presenting it as absent.
        for pixel in pixelLabels {
            for lane in artifacts.lanes where lane.category == .absent || !lane.isAvailable {
                guard let report = report(
                    pixel: pixel,
                    lane: lane,
                    classifier: artifacts.hostileClassifier,
                    summary: nil
                ) else { continue }

                witness.recordAdditionCheck()
                #expect(report.pixel == pixel, "an absent lane moved the pixel lane [\(shape)]")
                #expect(report.provenance == lane, "an absent lane was rewritten [\(shape)]")
                #expect(
                    report.provenance.category != .validated,
                    "a lane with no credential became validated [\(shape)]"
                )
                if lane.isAvailable {
                    #expect(
                        report.provenance.category == .absent,
                        "the absent state changed category [\(shape)]"
                    )
                    #expect(
                        report.provenance.unavailableReason == nil,
                        "an available absent lane reported an unavailable reason [\(shape)]"
                    )
                } else {
                    // Unavailable is not absent: no category at all, and its reason survives.
                    #expect(
                        report.provenance.category == nil,
                        "an unavailable lane gained an evidence category [\(shape)]"
                    )
                    #expect(
                        report.provenance.unavailableReason == lane.unavailableReason,
                        "the unavailable reason moved [\(shape)]"
                    )
                }
                expectNoPromotion(report: report, pixel: pixel, lane: lane)
            }
        }

        // Requirement 7.7: an insufficient pixel outcome preserves the provenance lane and
        // adds no pixel-based authenticity evidence.
        for (index, _, lane) in combinations {
            let summary = lane.isAvailable && shape.offersSummary(at: index)
                ? artifacts.summary : nil
            guard let report = report(
                pixel: .notEnoughSignal,
                lane: lane,
                classifier: artifacts.hostileClassifier,
                summary: summary
            ) else { continue }

            witness.recordAdditionCheck()
            #expect(
                report.pixel == .notEnoughSignal,
                "the Insufficient Evidence Outcome became \(report.pixel.rawValue) [\(shape)]"
            )
            #expect(
                report.provenance == lane,
                "an insufficient pixel outcome rewrote the provenance lane [\(shape)]"
            )
            expectNoPromotion(report: report, pixel: .notEnoughSignal, lane: lane)
        }
    }

    /// Requires the report's lanes to differ from every forbidden promotion of them.
    ///
    /// Each promotion is a value the closed vocabulary already contains, so nothing is
    /// invented; what is named is the substitution that would turn "no finding" into
    /// evidence. Each promoted variant is also required to differ from the pre-image, so a
    /// promotion that changed nothing cannot make this pass.
    private func expectNoPromotion(
        report: EvidenceReport,
        pixel: PixelEvidence,
        lane: ProvenanceLane
    ) {
        let expected = LaneProjection(pixel: pixel, provenance: lane)
        let produced = LaneProjection(report)
        var promotions: [(String, LaneProjection)] = []

        if pixel == .notEnoughSignal {
            promotions.append((
                "insufficient pixel evidence promoted to the non-positive label",
                LaneProjection(pixel: .noStrongSignalDetected, provenance: lane)
            ))
            promotions.append((
                "insufficient pixel evidence promoted to the positive label",
                LaneProjection(pixel: .signalsConsistentWithAIGeneration, provenance: lane)
            ))
        }
        if lane.category == .absent, let validated = artifacts.enabledStates.first(
            where: { $0.category == .validated }
        ) {
            promotions.append((
                "absent provenance promoted to validated",
                LaneProjection(pixel: pixel, provenance: .available(validated))
            ))
        }
        if !lane.isAvailable {
            promotions.append((
                "an unavailable lane promoted to absent",
                LaneProjection(pixel: pixel, provenance: .available(.absent))
            ))
        }

        for (named, promoted) in promotions {
            witness.recordAdditionCheck()
            #expect(promoted != expected, "the promotion mutant changed nothing: \(named) [\(shape)]")
            #expect(produced != promoted, "the report is \(named) [\(shape)]")
        }
    }

    // MARK: Arm 7 — an unavailable lane cannot gain a summary

    /// Requirement 7.10's structure, in service of "never adds": with no provenance evidence
    /// there is nothing to fuse and nothing to be inconsistent with, so neither additive
    /// field can attach to an unavailable lane.
    ///
    /// The composition is deliberately hostile — a session with no bound Provenance Policy
    /// but a bound Evidence Fusion Rule, which a coherently composed build cannot produce —
    /// so the refusal is what holds even when the surrounding configuration is incoherent.
    /// The report is refused rather than built with the summary dropped, which is why the
    /// assertion is on the fault and not on a field.
    func checkAnUnavailableLaneCannotGainASummary() {
        for (_, pixel, lane) in combinations where !lane.isAvailable {
            guard let coordinator = coordinator(
                for: lane,
                classifier: artifacts.hostileClassifier,
                boundToFusionRule: true
            ) else { continue }

            let refused = attempt(
                coordinator,
                lanes: ResolvedEvidenceLanes(pixel: pixel, provenance: lane),
                summary: artifacts.summary
            )
            witness.recordRefusal(refused.fault)
            #expect(
                refused.fault == .reportNotRepresentable,
                """
                a Combined Summary beside an unavailable lane produced \
                \(refused.report == nil ? "\(String(describing: refused.fault))" : "a report") \
                [\(shape)]
                """
            )
            #expect(refused.report == nil, "an unavailable lane gained a summary [\(shape)]")

            // Without a summary the same hostile classifier yields a report with no notice:
            // the lane is visible in full and nothing was attached to it.
            guard let report = report(
                pixel: pixel, lane: lane, classifier: artifacts.hostileClassifier, summary: nil
            ) else { continue }
            #expect(
                report.apparentInconsistency == nil,
                "an unavailable lane was declared inconsistent [\(shape)]"
            )
            #expect(report.combinedSummary == nil, "a summary appeared with none offered [\(shape)]")
            #expect(report.provenance == lane, "the unavailable lane moved [\(shape)]")
            #expect(report.pixel == pixel, "an unavailable lane moved the pixel lane [\(shape)]")
        }
    }

    // MARK: Arm 8 — lanes do not depend on the bound scope

    /// The lanes are independent of which evidence-scope artifact version the session bound.
    ///
    /// A recorded open item sits here: `EvidenceCoordinator.init?` takes `binding` and `scope`
    /// as independent parameters and validates only the classifier's copy compatibility, so a
    /// composition root could pair a session binding with a scope from a different bundle
    /// version. The pairing is checked where the two come from one source — `BoundAnalysisSession`
    /// derives the scope from the bound bundle's own component version — and the initializer
    /// stays permissive. That is not this property's subject and is deliberately not addressed
    /// here.
    ///
    /// This arm states what Property 21 *can* say about it: a scope is not a lane, and moving
    /// it moves nothing in either lane. So a misattributed scope, whatever else it would
    /// misstate, cannot perturb the evidence.
    func checkLanesAreIndependentOfTheBoundScope() {
        for (_, pixel, lane) in combinations {
            guard let underA = report(
                pixel: pixel,
                lane: lane,
                classifier: artifacts.classifier,
                summary: nil,
                scope: artifacts.scope
            ),
            let underB = report(
                pixel: pixel,
                lane: lane,
                classifier: artifacts.classifier,
                summary: nil,
                scope: artifacts.alternateScope
            ) else { continue }

            witness.recordComparison()
            #expect(
                LaneProjection(underA) == LaneProjection(underB),
                "the bound evidence scope moved a lane [\(shape)]"
            )
            #expect(
                underA.apparentInconsistency == underB.apparentInconsistency,
                "the bound evidence scope moved the notice [\(shape)]"
            )
            // The control: the scope really did change, so equal lanes are independence
            // rather than two readings of the same coordinator.
            #expect(
                underA.scope.id != underB.scope.id,
                "the two scope variants are the same artifact version [\(shape)]"
            )
        }
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator produced and what the join actually returned, so the property
/// cannot pass by joining one lane pair a hundred times.
///
/// It also proves the run happened at all. `propertyCheck` discards an error thrown by its
/// body, so a body that failed before its first assertion reports a passing test in
/// milliseconds with every arm skipped. `completedArms == cases` alone does not catch that:
/// it passes vacuously as `0 == 0` when the body throws on the first case. The case floor,
/// the join and report counts, and the counted comparisons are what close that gap, and they
/// live here rather than in an arm because an issue recorded outside the body is not
/// suppressed. A pure value-level property is legitimately fast, so the clock proves nothing
/// on its own and these counts stand in for it.
///
/// The produced sets are the substantive half. Every one of the 21 lane combinations, every
/// pixel label, every provenance category, both unavailable reasons, both notice states, both
/// summary states, all six operation orders, and the refusal are required to have been
/// *observed in a constructed output* rather than merely offered — which is what turns
/// "immutable and noninterfering" from a claim about unreached branches into a claim about
/// produced reports.
///
/// The variation thresholds are far below what 100 uniform draws produce, so they witness
/// variation rather than pinning a distribution.
private final class LaneVariationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var cases = 0
    private var completedArms = 0
    private var joins = 0
    private var reports = 0
    private var comparisons = 0
    private var mutationChecks = 0
    private var suppressionMutants = 0
    private var rankingMutants = 0
    private var additionChecks = 0
    private var refusals = 0
    private var unbuildableInputs = 0
    private var lateWritesRefused: Set<Bool> = []

    // Produced outputs.
    private var producedCombinations: Set<String> = []
    private var producedPixelLabels: Set<PixelEvidence> = []
    private var producedCategories: Set<ProvenanceCategory> = []
    private var producedUnavailableReasons: Set<UnavailableReason> = []
    private var producedNoticeStates: Set<Bool> = []
    private var producedSummaryStates: Set<Bool> = []
    private var producedFaults: Set<EvidenceJoinFault> = []
    private var exercisedOrders: Set<LaneOperationOrder> = []

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var declaredSetSizes: Set<Int> = []
    private var classifierPresence: Set<Bool> = []
    private var summaryOfferBits: Set<Int> = []
    private var signerCounts: Set<Int> = []
    private var assertionCounts: Set<Int> = []
    private var featureCounts: Set<Int> = []
    private var invalidityCategories: Set<InvalidityCategory> = []
    private var byteStatuses: Set<BytePreservationStatus> = []
    private var dimensionPairs: Set<String> = []
    private var onDeviceFlags: Set<Bool> = []

    /// Every lane combination the sweep must reach, as a stable key.
    static let requiredCombinations: Set<String> = {
        var keys: Set<String> = []
        for pixel in PixelEvidence.allCases {
            for category in ProvenanceCategory.allCases {
                keys.insert("\(pixel.labelKey.rawValue)+available/\(category.stateKey.rawValue)")
            }
            for reason in UnavailableReason.allCases {
                keys.insert("\(pixel.labelKey.rawValue)+unavailable/\(reason.rawValue)")
            }
        }
        return keys
    }()

    func record(_ shape: LaneShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        declaredSetSizes.insert(shape.declaredCombinations.count)
        classifierPresence.insert(shape.declaresClassifier)
        summaryOfferBits.insert(shape.summaryOfferBits)
        signerCounts.insert(shape.signerFieldCount)
        assertionCounts.insert(shape.assertionFieldCount)
        featureCounts.insert(shape.unsupportedFeatureCount)
        invalidityCategories.insert(shape.invalidityCategory)
        byteStatuses.insert(shape.bytePreservationStatus)
        dimensionPairs.insert("\(shape.qualityWidth)x\(shape.qualityHeight)")
        onDeviceFlags.insert(shape.onDeviceProcessing)
    }

    /// Records one report construction, whichever answer it produced.
    func recordAttempt(_ attempt: ReportAttempt, lanes: ResolvedEvidenceLanes, summaryOffered: Bool) {
        lock.lock()
        defer { lock.unlock() }
        switch attempt {
        case let .report(report):
            reports += 1
            producedPixelLabels.insert(report.pixel)
            if let category = report.provenance.category { producedCategories.insert(category) }
            if let reason = report.provenance.unavailableReason {
                producedUnavailableReasons.insert(reason)
            }
            producedNoticeStates.insert(report.apparentInconsistency != nil)
            producedSummaryStates.insert(report.combinedSummary != nil)
            let projection = LaneProjection(report)
            producedCombinations.insert("\(projection.pixel)+\(projection.provenanceLane)")
        case let .fault(fault):
            producedFaults.insert(fault)
            _ = lanes
            _ = summaryOffered
        }
    }

    func recordJoin() {
        lock.lock()
        joins += 1
        lock.unlock()
    }

    func recordOrder(_ order: LaneOperationOrder) {
        lock.lock()
        exercisedOrders.insert(order)
        lock.unlock()
    }

    func recordLateWrite(refused: Bool) {
        lock.lock()
        lateWritesRefused.insert(refused)
        lock.unlock()
    }

    func recordComparison() {
        lock.lock()
        comparisons += 1
        lock.unlock()
    }

    func recordMutationCheck() {
        lock.lock()
        mutationChecks += 1
        lock.unlock()
    }

    func recordSuppressionMutant() {
        lock.lock()
        suppressionMutants += 1
        lock.unlock()
    }

    func recordRankingMutant() {
        lock.lock()
        rankingMutants += 1
        lock.unlock()
    }

    func recordAdditionCheck() {
        lock.lock()
        additionChecks += 1
        lock.unlock()
    }

    func recordRefusal(_ fault: EvidenceJoinFault?) {
        lock.lock()
        if fault != nil { refusals += 1 }
        lock.unlock()
    }

    /// Records that a fixture this file described could not be built.
    ///
    /// Never a finding about the join: every input here is built from generated integers
    /// inside validated ranges, so a refusal is a defect in this file. It is counted so a run
    /// whose inputs quietly stopped being buildable fails outside the body rather than
    /// shrinking its own coverage.
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

        #expect(cases >= 100, "the design requires at least 100 generated cases; ran \(cases)")
        #expect(
            completedArms == cases,
            "\(cases - completedArms) of \(cases) cases did not reach the end of the body"
        )
        #expect(
            unbuildableInputs == 0,
            "\(unbuildableInputs) described inputs could not be built at all"
        )

        // Counted work. Each case sweeps 21 combinations, and the order arms build 6 joins
        // per combination twice, so a case performs well over 200 joins and 100 reports. The
        // floors sit far below that so they do not pin an arm's internal loop, and far enough
        // above zero that a run which built only fixtures fails here rather than passing.
        #expect(joins >= 10_000, "joins performed: \(joins)")
        #expect(reports >= 5_000, "reports constructed: \(reports)")
        #expect(comparisons >= 5_000, "lane comparisons performed: \(comparisons)")
        #expect(mutationChecks >= 1_000, "mutation checks performed: \(mutationChecks)")
        #expect(suppressionMutants >= 1_000, "suppression mutants compared: \(suppressionMutants)")
        #expect(rankingMutants >= 1_000, "ranking mutants compared: \(rankingMutants)")
        #expect(additionChecks >= 1_000, "addition checks performed: \(additionChecks)")
        #expect(refusals >= 500, "refusals observed: \(refusals)")

        // The substantive half: the outputs were produced, not merely offered.
        let unreachedCombinations = Self.requiredCombinations.subtracting(producedCombinations)
        #expect(
            unreachedCombinations.isEmpty,
            "lane combinations never produced in a report: \(unreachedCombinations.sorted())"
        )
        #expect(
            producedPixelLabels == Set(PixelEvidence.allCases),
            "pixel labels never produced: \(producedPixelLabels.map(\.rawValue).sorted())"
        )
        #expect(
            producedCategories == Set(ProvenanceCategory.allCases),
            "provenance categories never produced: \(producedCategories.map(\.rawValue).sorted())"
        )
        #expect(
            producedUnavailableReasons == Set(UnavailableReason.allCases),
            "unavailable reasons never produced: \(producedUnavailableReasons.map(\.rawValue).sorted())"
        )
        #expect(
            producedNoticeStates == [false, true],
            "only one notice state was ever produced: \(producedNoticeStates.sorted(by: { !$0 && $1 }))"
        )
        #expect(
            producedSummaryStates == [false, true],
            "only one Combined Summary state was ever produced"
        )
        #expect(
            producedFaults.contains(.reportNotRepresentable),
            "the unavailable-lane refusal was never produced: \(producedFaults)"
        )
        #expect(
            exercisedOrders == Set(LaneOperationOrder.allCases),
            "operation orders never exercised: \(Set(LaneOperationOrder.allCases).subtracting(exercisedOrders).map(\.rawValue).sorted())"
        )
        #expect(
            lateWritesRefused == [true],
            "a late duplicate write was not refused in every case: \(lateWritesRefused.sorted(by: { !$0 && $1 }))"
        )

        // The generated baseline actually varied.
        #expect(seeds.count >= 50, "generated seeds: \(seeds.count)")
        #expect(declaredSetSizes.count >= 5, "generated declared-set sizes: \(declaredSetSizes.count)")
        #expect(
            classifierPresence == [false, true],
            "only one classifier composition was generated"
        )
        #expect(summaryOfferBits.count >= 30, "generated summary offer masks: \(summaryOfferBits.count)")
        #expect(signerCounts == [0, 1, 2, 3], "generated signer counts: \(signerCounts.sorted())")
        #expect(
            assertionCounts == [0, 1, 2, 3],
            "generated assertion counts: \(assertionCounts.sorted())"
        )
        #expect(featureCounts == [1, 2, 3], "generated feature counts: \(featureCounts.sorted())")
        #expect(
            invalidityCategories == Set(InvalidityCategory.allCases),
            "generated invalidity categories: \(invalidityCategories.map(\.rawValue).sorted())"
        )
        #expect(
            byteStatuses == Set(BytePreservationStatus.allCases),
            "generated byte statuses: \(byteStatuses.map(\.rawValue).sorted())"
        )
        #expect(dimensionPairs.count >= 30, "generated dimension pairs: \(dimensionPairs.count)")
        #expect(onDeviceFlags == [false, true], "only one on-device flag was generated")
    }
}
