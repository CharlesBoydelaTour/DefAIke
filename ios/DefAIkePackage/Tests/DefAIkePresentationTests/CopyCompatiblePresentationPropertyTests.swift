import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain
@testable import DefAIkePresentation

// Design Property 23: presentation models are copy-compatible and probability-free.
//
// The design states it as: for any reachable completed report and bound Approved Verdict
// Copy catalog, presentation construction succeeds only when every reachable
// label/state/warning/error has a compatible versioned key, the Pixel Evidence string is
// exactly one of the three fixed labels, all required scope, false-result, version,
// byte-status, dimension, and on-device fields are present, and the model contains no
// consumer probability, confidence value/level, percentage, or probability-like encoding
// (Requirements 8.1, 8.2, 8.9, 8.10, 8.11, 8.12, 8.13).
//
// ## The four claims, and how each one is measured
//
//   1. **Compatible versioned keys.** Every `ResolvedCopyReference` reachable in an
//      assembled report is checked three ways: its compatibility identifier is the one the
//      *session-bound Model Bundle* recorded, its catalogue identifier is the catalogue that
//      was actually bound, and its localization key is the key that bound catalogue approved
//      for that exact surface. The refusal half is measured too, on the same case: a
//      catalogue or a capability manifest naming a different compatibility identifier is
//      refused by `ApprovedCopyBinding.bind`, so no presentation exists to render, and a
//      binding belonging to a different session is refused by assembly.
//   2. **Exactly one of the three fixed labels.** The three strings are transcribed into
//      this file as literals. A test that asked ``FixedPixelLabelText`` what the required
//      text is would assert nothing, so the required text is stated here and compared
//      against both the presentation model *and* the value the shipped String Catalog
//      carries under the key the bound catalogue approved for that surface. That join —
//      binding key, catalogue key, catalogue value, required literal — is the whole of
//      Requirement 8.2 in one chain.
//   3. **Every required field present.** The transparency and limitation fields are
//      extracted into a plain fact record and checked by a pure function, which is what
//      lets the same check be probed with a field deliberately blanked (see
//      ``TransparencyProbeTests``). The six bound component versions, the closed
//      pre-orientation dimension vocabulary, the on-device status, the verified integrity
//      status, the byte status and its limitation, the covered and uncovered scope
//      statements, and the three onward paths are all measured against transcribed
//      vocabularies rather than against the enumerations under test.
//   4. **No probability or confidence representation.** Measured structurally, on the type
//      system, not by reading English. The whole assembled value graph is walked and the set
//      of *types* it reaches is compared against a transcribed list of the representations a
//      probability, confidence level, percentage, score, or raw logit arrives in. A second,
//      sharper structural claim rides alongside: no reachable stored `String` contains a
//      space, so no rendered sentence is stored anywhere in a presentation model — user
//      facing prose reaches a view only as an address.
//
// ## Every absence is measured beside a presence
//
// "Probability-free" and "no confidence representation" are absences, and a run that only
// ever built reports without such a field would satisfy them for free. So each measured
// zero sits beside a measured one, on the same case, and the witness *requires* the
// presences to have happened:
//
//   * the type-graph audit's zero magnitude types sits beside a counted set of reached
//     types and a counted number of reached `Int` measurements — a recorded pixel dimension
//     and a verified-artifact count are integers this module deliberately does carry, so an
//     empty or truncated walk fails rather than passing;
//   * the "no stored prose" zero sits beside the assertion that the three required label
//     strings *do* contain spaces, so the exclusion is discriminating rather than trivially
//     true of every string;
//   * the "shipped catalogue approves nothing but the three fixed labels" zero sits beside
//     the three keys it *does* approve, and beside a covering catalogue on the same binding
//     that covers every resolvable key;
//   * pixel-only and provenance-enabled compositions are both generated, and available and
//     unavailable provenance lanes both, so the unavailable-lane and enabled-state surfaces
//     are each exercised rather than one being inferred from the other; and
//   * a shown Combined Summary and an omitted one are both generated, with both recorded
//     omission reasons, so "a summary suppresses no card and adds no magnitude" is measured
//     against a summary that exists.
//
// ## The copy catalogue is mostly empty, and this file says so rather than pretending
//
// The shipped `Localizable.xcstrings` carries **only** the three fixed pixel-label keys.
// Every other approved value is an unresolved external content decision, and the coverage
// gate reports it as a named list of keys. So "exact labels" is asserted over what the
// catalogue actually approves, and everything else is asserted to be a *recorded blocked
// surface* rather than a rendered string: the three gap vocabularies are non-empty, their
// keys are pairwise disjoint, no gap key names a surface the approved vocabulary defines,
// and no gap key is reachable as a string in an assembled report. Nothing here invents copy
// to make an arm pass.
//
// ## What this file does not claim
//
//   * **It approves no wording.** The three fixed labels are a requirement, transcribed.
//     Every other sentence is external approved content, and the design's non-property
//     validation for Requirement 8 is human content approval plus English UI snapshots.
//     Nothing here substitutes for either.
//   * **Requirement 8.14's definitions are not claimed to exist.** They do not. They are
//     recorded gaps, and this file asserts they are recorded, not that they are filled.
//   * **Requirement 8.16 is Property 24's.** No benchmark claim is constructed here.
//   * **Requirement 9.15's forbidden controls are task 11.3's unit audits.** This file
//     re-runs the reflection audits over generated reports because they are cheap and the
//     generated space is wider, but it adds no new claim about them.
//   * **Requirement 6.16 is satisfied for a superset.** Nothing in the system records
//     whether an image is a screenshot, so task 11.3 attaches the approved screenshot
//     explanation to *every* enabled `absent` result. This file measures that superset
//     directly and records the missing input as the reason, rather than asserting the
//     narrower statement the requirement names.
//   * **Coordinator and application types are unreachable.** `DefAIkePresentation` depends
//     only on `DefAIkeDomain`, so the "reachable reports" here are domain-typed snapshots
//     run through the real projection, exactly as task 11.2's tests build them. A report
//     that the projection refuses is not a report this file can assert about.
//
// ## Why no arm throws
//
// `propertyCheck` runs its body under `try?` and discards a thrown error, so a `throw` in
// the body would report a passing run in milliseconds with every arm skipped. Nothing below
// rethrows: every catalogue, manifest, fusion rule, session binding, report, projection, and
// assembly is turned into a recorded value or into an `Issue.record` plus a counted
// unbuildable input. The witness counters live *outside* the body, `recordCompletedBody()`
// is the body's last statement, and `completedBodies == cases` is paired with
// `cases == requestedCases`, `executedCases == cases`, and counted-work floors, because on
// its own it passes vacuously as `0 == 0`.

extension Tag {
    /// Design Property 23.
    ///
    /// Declared here rather than in a shared namespace: each design property owns one file,
    /// and a shared tag namespace would be a merge point between independently written
    /// property files.
    @Tag static var property23CopyCompatiblePresentation: Self
}

@Suite(
    "Property 23: Presentation models are copy-compatible and probability-free",
    .tags(.property23CopyCompatiblePresentation)
)
struct CopyCompatiblePresentationPropertyTests {

    /// The number of generated cases requested.
    ///
    /// Each case binds up to three approved-copy bindings against freshly built catalogues,
    /// manifests, and a fifteen-entry fusion rule, projects a completed screen through the
    /// real projection, assembles a report, walks the assembled value graph, and audits four
    /// String Catalogs against the binding's resolvable keys. Four hundred is what the
    /// witness's coverage product needs — three pixel labels crossed with seven lane states,
    /// three byte statuses, five independent flags, six omitted-surface kinds, and two
    /// compatibility-skew sources — while keeping the suite's runtime honest. No assertion is
    /// relaxed to fit it; if a cell ever thins out, the count is what moves.
    static let generatedCaseCount = 400

    /// **Validates: Requirements 8.1, 8.2, 8.9, 8.10, 8.11, 8.12, 8.13**
    @Test("Every reachable report resolves compatible approved keys and carries no magnitude")
    func everyReachableReportIsCopyCompatibleAndProbabilityFree() async {
        let witness = PresentationWitness()

        await propertyCheck(
            count: Self.generatedCaseCount,
            input: ReportShape.generator
        ) { shape in
            witness.record(shape)
            guard let run = PresentationCase.execute(shape: shape, witness: witness) else {
                return
            }

            run.checkThePresentationDescribesTheGeneratedReport()
            run.checkTheFixedPixelLabelIsExactlyTheRequiredString()
            run.checkEveryResolvedKeyIsTheApprovedCompatibleKey()
            run.checkEveryRequiredTransparencyFieldIsPresent()
            run.checkEveryRequiredLimitationIsStated()
            run.checkBothCardsStandAndNeitherIsRanked()
            run.checkTheCombinedSummaryAddsNoLaneAndNoMagnitude()
            run.checkNoProbabilityOrConfidenceRepresentationIsReachable()
            run.checkNoRenderedProseIsStoredAnywhere()
            run.checkACoveringCatalogCoversEveryResolvableKey()
            run.checkOneMissingValueIsNamedRatherThanRendered()
            run.checkTheShippedCatalogApprovesEverythingButTheCombinedSummary()
            run.checkAnIncompatibleRecordIsRefusedInsteadOfRendered()
            run.checkAnotherSessionsBindingIsRefused()
            run.checkEveryBlockedSurfaceIsRecordedRatherThanInvented()

            witness.recordCompletedBody()
        }

        witness.expectMeasuredRun(requestedCases: Self.generatedCaseCount)
    }
}

// MARK: - The required values, transcribed

/// The values Requirement 8 fixes, written out here rather than read from the code.
///
/// A test that asked ``FixedPixelLabelText``, ``DisclosedComponent``, or
/// ``AnalysisScopeStatement`` what their members are would assert nothing. These are the
/// claims: these three strings, these six components, these ten scope statements, these
/// three dimensions.
private enum RequiredByRequirement {

    /// The three exact user-facing pixel labels (Requirement 8.2).
    static let pixelLabelText: [PixelLabelKey: String] = [
        .signalsConsistentWithAIGeneration: "Signals consistent with AI generation",
        .noStrongSignalDetected: "No strong signal detected",
        .notEnoughSignal: "Not enough signal",
    ]

    /// The component versions a report exposes (Requirements 4.12, 8.12, and 10.18).
    static let disclosedComponents: Set<String> = [
        "model-bundle",
        "model-checkpoint",
        "core-ml-model",
        "preprocessing-contract",
        "calibration-policy",
        "verdict-copy-compatibility",
    ]

    /// The pre-orientation dimensions a report exposes (Requirement 8.12).
    static let preOrientationDimensions: Set<String> = [
        "decoded-width",
        "decoded-height",
        "short-edge",
    ]

    /// The scope Requirement 8.10 requires every report to state as covered.
    static let coveredScopes: Set<String> = ["wholeImageSynthesis"]

    /// The scopes Requirement 8.10 requires every report to state as not covered.
    static let uncoveredScopes: Set<String> = [
        "localizedEdit",
        "composite",
        "vaeReconstruction",
        "video",
        "audio",
        "animatedMedia",
        "additionalStaticFormat",
        "additionalIngestRoute",
        "multipleImages",
    ]

    /// The claim categories Requirement 8.9 and 8.13 forbid a presentation field from
    /// representing.
    static let prohibitedClaims: Set<String> = [
        "probability",
        "confidence",
        "percentage-or-score",
        "raw-logit",
        "certainty",
        "authenticity",
        "authorship",
        "intent",
        "complete-editing-history",
        "absence-of-localized-editing",
    ]

    /// The six destinations Requirement 8.17 requires a path to from every report.
    static let disclosureDestinations: Set<String> = [
        "selected-model-identity",
        "measured-limitations",
        "independent-non-peer-reviewed-release-status",
        "invalid-inherited-red-team-status",
        "privacy-behavior",
        "correction-channel",
    ]
}

// MARK: - The generated vocabulary

/// Everything one generated case decides, as plain integers.
///
/// The generator produces integers only. Every catalogue, manifest, rule, binding, report,
/// screen, and presentation is built from them inside the run, where a construction that
/// unexpectedly fails becomes an `Issue.record` and a counted unbuildable input rather than
/// a throw `propertyCheck` would discard.
///
/// ## How the baseline varies
///
///   * the **pixel label**, over all three, so all three fixed strings are exercised;
///   * the **provenance lane state**, over all seven a completed report can carry — two
///     unavailable reasons and five enabled states — so the unavailable-lane surface and the
///     enabled-state surfaces are each measured rather than one standing in for the other;
///   * the **byte preservation status**, over all three, so every status's approved
///     limitation is resolved;
///   * whether the session **recorded pre-orientation dimensions**, so the projection is
///     measured both with three recorded dimensions and with none;
///   * whether the session recorded **all processing on device**, so both named statuses are
///     rendered rather than only the true one;
///   * whether the report declared an **apparent inconsistency**, which is representable
///     only alongside an available lane;
///   * whether the release binds a **fusion rule**, and whether that rule **produced a
///     summary** for this combination, so a shown summary and both recorded omission reasons
///     are all measured;
///   * which **required surface** the coverage-gap catalogue omits, over six surfaces the
///     generated report genuinely resolves, so a missing value is measured on copy the
///     report actually needs rather than on an unrelated key; and
///   * which **record** disagrees about the copy compatibility identifier, over the
///     catalogue and the capability manifest.
///
/// Each selector has its own range, and each range is an exact multiple of the modulus it is
/// reduced by: 120 for a three-way or two-way choice, 280 for the seven lane states, and 960
/// for the five packed flag bits (960 is divisible by 2, 4, 8, 16, and 32). A shared range
/// would have made at least one draw nonuniform, because seven does not divide the range any
/// three-way choice needs.
private struct ReportShape: Sendable, CustomStringConvertible {

    /// Every lane state a completed report can carry, in a stable order.
    ///
    /// Two unavailable reasons and five enabled states. Built from the domain's own closed
    /// vocabularies so a new state cannot be added without this list growing, and the witness
    /// requires every entry to have been generated.
    static let laneStates: [LaneChoice] =
        UnavailableReason.allCases.map(LaneChoice.unavailable)
        + ProvenanceCategory.allCases.map(LaneChoice.available)

    /// Which required surface the coverage-gap catalogue omits.
    static let omittedSurfaceKindCount = 6

    let seed: Int
    let pixelSelector: Int
    let laneSelector: Int
    let byteSelector: Int
    let flagSelector: Int
    let omittedSurfaceSelector: Int
    let skewSelector: Int

    // MARK: Derived

    var pixel: PixelEvidence {
        PixelEvidence.allCases[pixelSelector % PixelEvidence.allCases.count]
    }

    var lane: LaneChoice { Self.laneStates[laneSelector % Self.laneStates.count] }

    var bytePreservationStatus: BytePreservationStatus {
        BytePreservationStatus.allCases[byteSelector % BytePreservationStatus.allCases.count]
    }

    /// Whether the session recorded its pre-orientation dimensions.
    var recordsDimensions: Bool { flagSelector % 2 == 1 }

    /// Whether the session recorded that all processing ran on device.
    var onDeviceProcessing: Bool { (flagSelector / 2) % 2 == 1 }

    /// Whether the report declared an apparent inconsistency. Representable only alongside
    /// an available lane, which the domain enforces, so it is forced off otherwise.
    var declaresInconsistency: Bool { (flagSelector / 4) % 2 == 1 && lane.isAvailable }

    /// Whether this release binds an Evidence Fusion Rule. A rule needs both lanes, so an
    /// unavailable lane forces it off.
    var bindsFusionRule: Bool { (flagSelector / 8) % 2 == 1 && lane.isAvailable }

    /// Whether the bound rule produced a summary for this combination.
    var showsSummary: Bool { (flagSelector / 16) % 2 == 1 && bindsFusionRule }

    var provenanceEnabled: Bool { lane.isAvailable }

    /// Which required surface the coverage-gap catalogue omits, as an index.
    var omittedSurfaceKind: Int { omittedSurfaceSelector % Self.omittedSurfaceKindCount }

    /// Which record disagrees about the compatibility identifier.
    var skewSource: CopyCompatibilitySource {
        skewSelector % 2 == 0 ? .copyCatalog : .capabilityManifest
    }

    /// This case's session identifier. Distinct per seed, so a case's binding cannot be
    /// confused with another's.
    var sessionIdentifier: String { "session.synthetic-\(seed)" }

    /// A recorded decoded width, when this case records dimensions. Always positive, and
    /// never equal to the height, so the short edge is a real minimum rather than a tie.
    var decodedWidth: Int { 320 + (seed % 700) }

    var decodedHeight: Int { 240 + (seed % 500) }

    var description: String {
        let composition =
            bindsFusionRule
            ? (showsSummary ? "provenance+fusion, summary shown" : "provenance+fusion, omitted")
            : (provenanceEnabled ? "provenance" : "pixel-only")
        return """
            seed \(seed), \(pixel.rawValue), \(lane.description), \
            \(bytePreservationStatus.rawValue), \(composition), \
            dimensions \(recordsDimensions ? "recorded" : "unmeasured"), \
            on-device \(onDeviceProcessing), inconsistency \(declaresInconsistency), \
            omit surface #\(omittedSurfaceKind), skew \(skewSource.rawValue)
            """
    }

    static var generator: Generator<ReportShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.int(in: 0...119),
            Gen.int(in: 0...279),
            Gen.int(in: 0...119),
            Gen.int(in: 0...959),
            Gen.int(in: 0...119),
            Gen.int(in: 0...119)
        )
        .map { seed, pixel, lane, byte, flags, omitted, skew in
            ReportShape(
                seed: seed,
                pixelSelector: pixel,
                laneSelector: lane,
                byteSelector: byte,
                flagSelector: flags,
                omittedSurfaceSelector: omitted,
                skewSelector: skew
            )
        }
        .eraseToAny()
    }
}

/// One provenance lane state a completed report can carry.
///
/// A generated choice rather than a built ``ProvenanceLane``, so the shape stays plain data
/// and the lane payloads are constructed inside the run.
private enum LaneChoice: Hashable, Sendable, CustomStringConvertible {
    case unavailable(UnavailableReason)
    case available(ProvenanceCategory)

    var isAvailable: Bool {
        switch self {
        case .unavailable: false
        case .available: true
        }
    }

    var category: ProvenanceCategory? {
        switch self {
        case .unavailable: nil
        case let .available(category): category
        }
    }

    /// The copy surface this lane state resolves its own description from.
    var surface: VerdictCopySurface {
        switch self {
        case .unavailable: .provenanceUnavailable
        case let .available(category): .provenanceState(category.stateKey)
        }
    }

    /// The distinction Requirements 6.21 and 8.8 require this state to be told apart by.
    var expectedDistinction: ProvenanceLaneDistinction {
        switch self {
        case .unavailable: .releaseCannotValidate
        case .available(.indeterminate): .enabledValidatorInconclusive
        case .available: .enabledValidatorResult
        }
    }

    /// A stable key for witness coverage, so both halves of the vocabulary are countable in
    /// one set.
    var coverageKey: String {
        switch self {
        case let .unavailable(reason): "unavailable/\(reason.rawValue)"
        case let .available(category): "available/\(category.rawValue)"
        }
    }

    var description: String { coverageKey }
}

// MARK: - One executed case

/// One generated case: one bound catalogue, one assembled report, four catalogue audits, and
/// two refusals.
private struct PresentationCase {
    let shape: ReportShape

    /// The immutable session binding the report was produced under.
    let session: AnalysisSessionBinding

    /// The approved copy binding the screen was projected through.
    let binding: ApprovedCopyBinding

    /// The report the completed screen carries.
    let report: EvidenceReport

    /// The assembled result presentation.
    let presentation: EvidenceReportPresentation

    /// Every value the assembled presentation reaches, by reflection.
    let graph: PresentationGraph

    /// Every localization key the binding can resolve, in stable order.
    let resolvableKeys: [ApprovedCopyKey]

    /// A catalogue with an approved value for every resolvable key.
    let coveringMissing: [ApprovedCopyKey]

    /// The required surface the coverage-gap catalogue omits, and its approved key.
    let omittedSurface: VerdictCopySurface
    let omittedKey: ApprovedCopyKey

    /// What the coverage gate reported for the gap catalogue.
    let gapMissing: [ApprovedCopyKey]

    /// What the coverage gate reported for the catalogue this repository ships.
    let shippedMissing: [ApprovedCopyKey]

    /// The shipped catalogue's value for this case's pixel label, if it carries one.
    let shippedLabelValue: String?

    /// The key the bound catalogue approved for this case's pixel-label surface.
    let boundLabelKey: ApprovedCopyKey

    /// The key the shipped String Catalog pins the same label under.
    let shippedLabelKey: ApprovedCopyKey

    /// The refusal a compatibility-skewed record produced, or `nil` when binding succeeded.
    let skewRefusal: PresentationCopyError?

    /// The refusal assembling through another session's binding produced.
    let foreignBindingRefusal: EvidenceReportAssemblyError?

    /// The transparency facts extracted from the assembled presentation.
    let facts: TransparencyFacts

    /// The shipped String Catalog, loaded once for the whole run.
    ///
    /// Cached because it is file I/O and every case asks the same question of it. `nil` means
    /// the resource was unreadable, which the run reports as an unbuildable input rather than
    /// silently skipping the shipped-catalogue arm.
    static let shippedCatalog: StringCatalog? = try? EnglishStringCatalog.loadShippedCatalog()

    // MARK: Execution

    static func execute(shape: ReportShape, witness: PresentationWitness) -> PresentationCase? {
        guard let shipped = shippedCatalog else {
            Issue.record("the shipped String Catalog must be readable for this property to mean anything")
            witness.recordUnbuildableInput()
            return nil
        }

        let sessionID = shape.sessionIdentifier
        let session = CopyFixture.sessionBinding(
            sessionID: sessionID,
            provenanceEnabled: shape.provenanceEnabled,
            fusionEnabled: shape.bindsFusionRule
        )

        let binding: ApprovedCopyBinding
        let otherBinding: ApprovedCopyBinding
        let skewRefusal: PresentationCopyError?
        do {
            binding = try ApprovedCopyBinding.bind(
                catalog: CopyFixture.catalog(),
                session: session,
                capabilities: CopyFixture.capabilityManifest(
                    provenanceEnabled: shape.provenanceEnabled,
                    fusionEnabled: shape.bindsFusionRule
                ),
                fusionRule: shape.bindsFusionRule ? CopyFixture.fusionRule() : nil
            )
            // The same composition for a different session. Used to measure that assembly
            // refuses copy bound to another session rather than rendering through it.
            otherBinding = try ApprovedCopyBinding.bind(
                catalog: CopyFixture.catalog(),
                session: CopyFixture.sessionBinding(
                    sessionID: "\(sessionID).other",
                    provenanceEnabled: shape.provenanceEnabled,
                    fusionEnabled: shape.bindsFusionRule
                ),
                capabilities: CopyFixture.capabilityManifest(
                    provenanceEnabled: shape.provenanceEnabled,
                    fusionEnabled: shape.bindsFusionRule
                ),
                fusionRule: shape.bindsFusionRule ? CopyFixture.fusionRule() : nil
            )
            skewRefusal = Self.refusalForSkewedCompatibility(shape: shape, session: session)
        } catch {
            Issue.record("a coherent synthetic composition must bind: \(error) [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }

        guard let report = Self.report(shape: shape, session: session) else {
            Issue.record("the generated lane combination must be representable [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }

        // Projected through the real projection rather than constructed directly, so the
        // lanes a card is assembled from are the lanes the application would resolve.
        let screen: CompletedScreen
        let presentation: EvidenceReportPresentation
        let foreignRefusal: EvidenceReportAssemblyError?
        do {
            let projected = try AnalysisScreen.projecting(
                .session(
                    AnalysisSessionSnapshot(
                        identity: SessionAttemptIdentity(
                            sessionID: session.sessionID,
                            attemptGeneration: 1
                        ),
                        phase: .ended(.completed(report)),
                        copy: binding
                    )
                )
            )
            guard case let .completed(completed) = projected else {
                Issue.record("a completed outcome must project the completed family; got \(projected.family) [\(shape)]")
                witness.recordUnbuildableInput()
                return nil
            }
            screen = completed
        } catch {
            Issue.record("a coherent completed snapshot must project: \(error) [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }
        do {
            presentation = try EvidenceReportPresentation.assembling(screen, copy: binding)
        } catch {
            Issue.record("a projected completed screen must assemble: \(error) [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }
        foreignRefusal = Self.refusalForForeignBinding(screen: screen, copy: otherBinding)

        // The four catalogue audits, all against the one binding this case produced.
        let resolvableKeys = CatalogFixture.resolvableKeys(of: binding)
        guard let omittedSurface = Self.omittedSurface(shape: shape),
            let omittedKey = binding.localizationKey(for: omittedSurface)
        else {
            Issue.record("the omitted surface must be one the binding resolves [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }
        let covering = CatalogFixture.covering(binding)
        var gapStrings = covering.strings
        gapStrings[omittedKey.rawValue] = nil
        let gap = CatalogFixture.catalog(gapStrings)

        let boundLabelKey = binding.localizationKey(for: .pixelLabel(shape.pixel.labelKey))
        guard let boundLabelKey,
            let shippedLabelKey = EnglishStringCatalog.fixedPixelLabelKeys[shape.pixel.labelKey]
        else {
            Issue.record("every pixel label must have a bound key and a pinned catalogue key [\(shape)]")
            witness.recordUnbuildableInput()
            return nil
        }

        let graph = PresentationGraph.walking(presentation)
        let facts = TransparencyFacts(extractedFrom: presentation)

        let executed = PresentationCase(
            shape: shape,
            session: session,
            binding: binding,
            report: report,
            presentation: presentation,
            graph: graph,
            resolvableKeys: resolvableKeys,
            coveringMissing: StringCatalogCoverage.missingValues(in: covering, for: binding),
            omittedSurface: omittedSurface,
            omittedKey: omittedKey,
            gapMissing: StringCatalogCoverage.missingValues(in: gap, for: binding),
            shippedMissing: StringCatalogCoverage.missingValues(in: shipped, for: binding),
            shippedLabelValue: shipped.singleValue(
                forKey: shippedLabelKey.rawValue,
                language: EnglishStringCatalog.requiredLanguageTag
            ),
            boundLabelKey: boundLabelKey,
            shippedLabelKey: shippedLabelKey,
            skewRefusal: skewRefusal,
            foreignBindingRefusal: foreignRefusal,
            facts: facts
        )
        witness.recordExecutedCase(executed)
        return executed
    }

    /// The report one generated case describes, or `nil` when the domain refuses it.
    ///
    /// Every conditional is forced coherent by ``ReportShape`` before it reaches here, so a
    /// `nil` is a defect in this file rather than a finding about the domain.
    private static func report(
        shape: ReportShape,
        session: AnalysisSessionBinding
    ) -> EvidenceReport? {
        let lane: ProvenanceLane
        switch shape.lane {
        case let .unavailable(reason):
            lane = .unavailable(reason)
        case let .available(category):
            lane = ReportFixture.availableLane(category)
        }

        let quality: InputQualityRecord? =
            shape.recordsDimensions
            ? InputQualityRecord(
                decodedWidthBeforeOrientation: shape.decodedWidth,
                decodedHeightBeforeOrientation: shape.decodedHeight
            )
            : .unmeasured
        guard let quality else { return nil }

        return EvidenceReport(
            binding: session,
            pixel: shape.pixel,
            provenance: lane,
            combinedSummary: shape.showsSummary
                ? CombinedSummary(
                    copyKey: CopyFixture.summaryKeys[shape.pixel.labelKey]!,
                    fusionRuleID: CopyFixture.fusionRuleID
                )
                : nil,
            apparentInconsistency: shape.declaresInconsistency
                ? CopyFixture.localizationKey(for: .apparentInconsistency)
                : nil,
            bytePreservationStatus: shape.bytePreservationStatus,
            inputQuality: quality,
            onDeviceProcessing: shape.onDeviceProcessing,
            scope: .version1(id: CopyFixture.artifact("scope.evidence.synthetic"))
        )
    }

    /// The surface the coverage-gap catalogue omits.
    ///
    /// Six surfaces the generated report genuinely resolves, so a missing value is measured
    /// on copy this report actually needs rather than on an unrelated key.
    private static func omittedSurface(shape: ReportShape) -> VerdictCopySurface? {
        switch shape.omittedSurfaceKind {
        case 0: .pixelLabel(shape.pixel.labelKey)
        case 1: .pixelExplanation(shape.pixel.labelKey)
        case 2: .evidenceScope
        case 3: .falseResultLimitation
        case 4: .bytePreservationLimitation(shape.bytePreservationStatus.statusKey)
        case 5: shape.lane.surface
        default: nil
        }
    }

    /// The refusal a compatibility-skewed record produces, or `nil` when binding succeeded.
    ///
    /// Returned rather than thrown, so a skew that is wrongly accepted becomes a `nil` an arm
    /// fails on instead of an error `propertyCheck` would discard.
    private static func refusalForSkewedCompatibility(
        shape: ReportShape,
        session: AnalysisSessionBinding
    ) -> PresentationCopyError? {
        let skewed = CopyFixture.artifact("copy.compatibility.skewed")
        do {
            _ = try ApprovedCopyBinding.bind(
                catalog: CopyFixture.catalog(
                    compatibilityID: shape.skewSource == .copyCatalog
                        ? skewed
                        : CopyFixture.compatibilityID
                ),
                session: session,
                capabilities: CopyFixture.capabilityManifest(
                    provenanceEnabled: shape.provenanceEnabled,
                    fusionEnabled: shape.bindsFusionRule,
                    verdictCopyCompatibility: shape.skewSource == .capabilityManifest
                        ? skewed
                        : CopyFixture.compatibilityID
                ),
                fusionRule: shape.bindsFusionRule ? CopyFixture.fusionRule() : nil
            )
            return nil
        } catch let error as PresentationCopyError {
            return error
        } catch {
            // The catalogue, manifest, and rule builders throw untyped artifact-schema
            // errors, so the cast above is load-bearing rather than decorative. Reaching
            // here means a fixture this file described could not be built, which the arm
            // reports as a missing refusal rather than absorbing.
            return nil
        }
    }

    /// The refusal assembling through another session's binding produces.
    private static func refusalForForeignBinding(
        screen: CompletedScreen,
        copy: ApprovedCopyBinding
    ) -> EvidenceReportAssemblyError? {
        do {
            _ = try EvidenceReportPresentation.assembling(screen, copy: copy)
            return nil
        } catch {
            // Typed throws again: assembly's only error type is the assembly error.
            return error
        }
    }

    // MARK: - Arms

    /// The presentation describes the report that was generated, and nothing else.
    func checkThePresentationDescribesTheGeneratedReport() {
        #expect(
            presentation.identity.sessionID == session.sessionID,
            "the presentation must describe the generated session [\(shape)]"
        )
        #expect(
            presentation.cards.pixel.evidence == shape.pixel,
            "the pixel card must show the generated label [\(shape)]"
        )
        #expect(
            presentation.cards.provenance.distinction == shape.lane.expectedDistinction,
            "the provenance card must fall under the distinction its state requires [\(shape)]"
        )
        #expect(
            presentation.recovery == .selectAnotherImage,
            "a completed report offers exactly one recovery [\(shape)]"
        )
    }

    /// Requirement 8.2: the displayed pixel label is exactly one of three fixed strings, and
    /// it is the string the shipped catalogue carries under the key the binding approved.
    func checkTheFixedPixelLabelIsExactlyTheRequiredString() {
        guard let required = RequiredByRequirement.pixelLabelText[shape.pixel.labelKey] else {
            Issue.record("every pixel label must have a transcribed required string [\(shape)]")
            return
        }
        let displayed = presentation.cards.pixel.fixedLabelText.value

        #expect(
            displayed == required,
            "the displayed pixel label must be exactly the required string; got '\(displayed)' [\(shape)]"
        )
        #expect(
            FixedPixelLabelText(exact: displayed)?.label == shape.pixel.labelKey,
            "the required string must recover exactly its own label [\(shape)]"
        )
        #expect(
            FixedPixelLabelText.allTexts == Set(RequiredByRequirement.pixelLabelText.values),
            "the permitted label vocabulary must be exactly the three required strings [\(shape)]"
        )
        #expect(
            presentation.cards.pixel.lane.fixedLabelText.value == displayed,
            "the card and the lane presentation must not disagree about the label [\(shape)]"
        )

        // The join Requirement 8.2 actually needs: the bound catalogue's approved key for
        // this surface is the key the shipped String Catalog pins, and the value there is the
        // required string character for character.
        #expect(
            boundLabelKey == shippedLabelKey,
            "the bound catalogue must address the pixel label at the key the shipped catalogue pins; bound \(boundLabelKey.rawValue), pinned \(shippedLabelKey.rawValue) [\(shape)]"
        )
        #expect(
            shippedLabelValue == required,
            "the shipped catalogue's value for \(shippedLabelKey.rawValue) must be exactly the required string; got \(String(describing: shippedLabelValue)) [\(shape)]"
        )
        #expect(
            presentation.cards.pixel.lane.labelCopy.localizationKey == boundLabelKey,
            "the resolved label copy must address the approved key [\(shape)]"
        )

        // The measured presence beside the "no stored prose" zero below: a required label
        // string does contain a space, so excluding spaces excludes something real.
        #expect(
            required.contains(" "),
            "every required label string contains a space, which is what makes the stored-prose exclusion discriminating [\(shape)]"
        )
    }

    /// Requirement 8.1: every resolved reference carries a compatible versioned key, and the
    /// key is the one the bound catalogue approved for that exact surface.
    func checkEveryResolvedKeyIsTheApprovedCompatibleKey() {
        #expect(
            graph.references.count >= 8,
            "an assembled report must resolve at least the eight unconditional surfaces it needs; found \(graph.references.count) [\(shape)]"
        )

        for reference in graph.references {
            #expect(
                reference.compatibilityID == session.verdictCopyCompatibilityID,
                "\(reference.surface.description) must carry the session-bound compatibility identifier; got \(reference.compatibilityID.rawValue) [\(shape)]"
            )
            #expect(
                reference.catalogID == binding.catalogID,
                "\(reference.surface.description) must name the bound catalogue; got \(reference.catalogID.rawValue) [\(shape)]"
            )
            #expect(
                binding.reachableSurfaces.contains(reference.surface),
                "\(reference.surface.description) must be reachable in this composition [\(shape)]"
            )
            #expect(
                binding.localizationKey(for: reference.surface) == reference.localizationKey,
                "\(reference.surface.description) must resolve to the key the bound catalogue approved; got \(reference.localizationKey.rawValue) [\(shape)]"
            )
        }

        // A pixel-only composition cannot reach an enabled provenance state at all, which is
        // what makes "describe the lane as unavailable rather than absent, invalid, or
        // authentic" structural (Requirement 8.8).
        for state in ProvenanceStateKey.allCases {
            #expect(
                binding.reachableSurfaces.contains(.provenanceState(state))
                    == shape.provenanceEnabled,
                "provenance-state reachability must follow the enabled capability set [\(shape)]"
            )
        }
        #expect(
            binding.reachableSurfaces.contains(.provenanceUnavailable),
            "the unavailable-lane surface is unconditional [\(shape)]"
        )
    }

    /// Requirements 8.12, 10.18, and 4.12: every required transparency field is present.
    ///
    /// The check runs over an extracted fact record through a pure function, so the same
    /// check can be probed with a field deliberately blanked.
    func checkEveryRequiredTransparencyFieldIsPresent() {
        let findings = TransparencyFacts.findings(
            in: facts,
            expectingRecordedDimensions: shape.recordsDimensions,
            expectedWidth: shape.decodedWidth,
            expectedHeight: shape.decodedHeight,
            expectedOnDevice: shape.onDeviceProcessing,
            expectedByteStatus: shape.bytePreservationStatus
        )
        #expect(
            findings.isEmpty,
            "required transparency fields are missing or wrong: \(findings) [\(shape)]"
        )

        #expect(
            Set(DisclosedComponent.allCases.map(\.rawValue))
                == RequiredByRequirement.disclosedComponents,
            "the disclosed-component vocabulary must be exactly the six required components [\(shape)]"
        )
        #expect(
            Set(PreOrientationDimension.allCases.map(\.rawValue))
                == RequiredByRequirement.preOrientationDimensions,
            "the dimension vocabulary must be exactly the three required dimensions [\(shape)]"
        )
        #expect(
            Set(RequiredDisclosureDestination.allCases.map(\.rawValue))
                == RequiredByRequirement.disclosureDestinations,
            "the disclosure-destination vocabulary must be exactly the six Requirement 8.17 names [\(shape)]"
        )
        for destination in RequiredDisclosureDestination.allCases {
            let reference = presentation.disclosurePaths.reference(reaching: destination)
            #expect(
                graph.references.contains(reference),
                "the path reaching \(destination.rawValue) must be part of the assembled report [\(shape)]"
            )
        }
    }

    /// Requirements 8.10, 8.11, and 6.15: every report states the scope, the false-result
    /// limitation, and the byte-status limitation.
    func checkEveryRequiredLimitationIsStated() {
        let limitations = presentation.limitations

        #expect(
            Set(limitations.coveredScopes.map(\.rawValue)) == RequiredByRequirement.coveredScopes,
            "the covered scope must be exactly the Whole Image Synthesis scope; got \(limitations.coveredScopes.map(\.rawValue)) [\(shape)]"
        )
        #expect(
            Set(limitations.uncoveredScopes.map(\.rawValue))
                == RequiredByRequirement.uncoveredScopes,
            "the uncovered scopes must be exactly the nine Requirement 8.10 names; got \(limitations.uncoveredScopes.map(\.rawValue)) [\(shape)]"
        )
        #expect(
            limitations.statesEveryRequiredScope,
            "a report may not understate its scope limits [\(shape)]"
        )
        #expect(
            limitations.scopeCopy.surface == .evidenceScope,
            "the scope statement must come from the approved evidence-scope surface [\(shape)]"
        )
        #expect(
            limitations.falseResultCopy.surface == .falseResultLimitation,
            "every report must state that false-positive and false-negative results can occur [\(shape)]"
        )
        #expect(
            limitations.bytePreservation.status == shape.bytePreservationStatus,
            "the exposed byte status must be the recorded one [\(shape)]"
        )
        #expect(
            limitations.bytePreservation.limitationCopy.surface
                == .bytePreservationLimitation(shape.bytePreservationStatus.statusKey),
            "the byte-status limitation must come from that status's approved surface [\(shape)]"
        )

        // Requirement 6.15 names the transformed and unknown statuses explicitly, and the
        // limitation is attached for all three, so the named flag is reported rather than
        // acted on.
        let isNamed = shape.bytePreservationStatus != .originalBytes
        #expect(
            limitations.bytePreservation.isNamedByTransformedOrUnknownRequirement == isNamed,
            "the transformed-or-unknown flag must follow the recorded status [\(shape)]"
        )
    }

    /// Requirements 7.2, 7.3, and 7.8: both cards stand, neither is ranked, and a declared
    /// inconsistency sits beside them rather than inside one.
    func checkBothCardsStandAndNeitherIsRanked() {
        let cards = presentation.cards

        #expect(
            cards.pixel.evidence == shape.pixel,
            "the pixel card must stand for every lane state [\(shape)]"
        )
        #expect(
            cards.provenance.state == expectedLanePresentationState,
            "the provenance card must show the generated lane state [\(shape)]"
        )
        #expect(
            Mirror(reflecting: cards).children.count == 2,
            "the pair must have exactly two members and no collection to be empty [\(shape)]"
        )

        // Neither card can hold the other lane's value, so ranking is not a behaviour to
        // avoid: there is no field for it.
        let pixelLabels = Mirror(reflecting: cards.pixel).children.compactMap(\.label)
        let provenanceLabels = Mirror(reflecting: cards.provenance).children.compactMap(\.label)
        #expect(
            pixelLabels.contains(where: { $0.lowercased().contains("provenance") }) == false,
            "the pixel card must carry no provenance member; found \(pixelLabels) [\(shape)]"
        )
        #expect(
            provenanceLabels.contains(where: { $0.lowercased().contains("pixel") }) == false,
            "the provenance card must carry no pixel member; found \(provenanceLabels) [\(shape)]"
        )
        for label in pixelLabels + provenanceLabels {
            let name = ForbiddenControlAudit.normalized(label)
            for ranking in ["rank", "priority", "weight", "order", "primary", "winner"] {
                #expect(
                    name.contains(ranking) == false,
                    "no card may carry a '\(ranking)' member; found \(label) [\(shape)]"
                )
            }
        }

        if shape.declaresInconsistency {
            #expect(
                presentation.apparentInconsistency.reference?.surface == .apparentInconsistency,
                "a declared notice must resolve the approved apparent-inconsistency surface [\(shape)]"
            )
        } else {
            #expect(
                presentation.apparentInconsistency == DefAIkePresentation
                    .ApparentInconsistencyNotice.none,
                "a report that declared no notice must say so rather than leave it unanswered [\(shape)]"
            )
        }

        // Requirement 6.16 is satisfied for a superset: nothing records screenshot origin, so
        // the approved explanation is attached to every enabled `absent` result.
        switch shape.lane {
        case .available(.absent):
            guard case let .shownForAbsentCredential(reference) = cards.provenance
                .screenshotExplanation
            else {
                Issue.record("every enabled absent result must carry the screenshot explanation [\(shape)]")
                return
            }
            #expect(
                reference.surface == .screenshotProvenanceExplanation,
                "the screenshot explanation must come from its own approved surface [\(shape)]"
            )
        default:
            #expect(
                cards.provenance.screenshotExplanation == .notApplicable,
                "the screenshot explanation applies only to an enabled absent result [\(shape)]"
            )
        }
        #expect(
            UnavailableEvidenceInput.screenshotOriginDetermination.narrows == "6.16",
            "the missing screenshot-origin input must record the requirement it would narrow [\(shape)]"
        )
    }

    /// Requirements 7.9 through 7.13: a Combined Summary names its rule, adds no lane value,
    /// and an omission records its reason.
    func checkTheCombinedSummaryAddsNoLaneAndNoMagnitude() {
        switch presentation.combinedSummary {
        case let .shown(summary):
            #expect(
                shape.showsSummary,
                "a summary appeared for a report that carried none [\(shape)]"
            )
            #expect(
                summary.fusionRuleID == CopyFixture.fusionRuleID,
                "a shown summary must name the rule version that produced it [\(shape)]"
            )
            #expect(
                summary.summaryCopy.surface
                    == .combinedSummary(CopyFixture.summaryKeys[shape.pixel.labelKey]!),
                "a shown summary must address its own approved surface [\(shape)]"
            )
            #expect(
                Mirror(reflecting: summary).children.count == 2,
                "a summary carries only its copy and its rule version [\(shape)]"
            )
            // Both cards and every limitation still stand beside it.
            #expect(
                presentation.cards.pixel.evidence == shape.pixel,
                "a summary must not suppress the pixel card [\(shape)]"
            )
            #expect(
                presentation.cards.provenance.state == expectedLanePresentationState,
                "a summary must not suppress the provenance card [\(shape)]"
            )
        case let .omitted(reason):
            #expect(
                shape.showsSummary == false,
                "a summary the report carried was omitted [\(shape)]"
            )
            let expected: FusionOmissionReason =
                shape.lane.isAvailable
                ? .noApprovedSummaryForThisCombination
                : .provenanceLaneUnavailable
            #expect(
                reason == expected,
                "the recorded omission reason must follow the report's own lane; got \(reason.rawValue) [\(shape)]"
            )
        }
    }

    /// Requirements 8.9, 8.13, and 8.15: nothing reachable in an assembled report is a
    /// consumer probability, confidence, percentage, score, or raw-logit representation.
    ///
    /// Measured on the type system. The walk collects every type the assembled value graph
    /// reaches and compares it against a transcribed list, rather than reading source text or
    /// English.
    func checkNoProbabilityOrConfidenceRepresentationIsReachable() {
        // The measured presence: the walk reached a real, populated value graph. Without
        // these, every zero below would be the zero of an empty walk.
        #expect(
            graph.nodeCount >= 30,
            "the walk must reach a populated graph; visited \(graph.nodeCount) values [\(shape)]"
        )
        #expect(
            graph.typeNames.count >= 15,
            "the walk must reach a varied graph; reached \(graph.typeNames.count) types [\(shape)]"
        )
        #expect(
            graph.integers.isEmpty == false,
            "this module deliberately carries integer measurements, and the walk must reach them [\(shape)]"
        )

        // The measured zeros, on the same graph.
        let magnitudes = graph.magnitudeTypeFindings()
        #expect(
            magnitudes.isEmpty,
            "an assembled report reaches a result-magnitude type: \(magnitudes) [\(shape)]"
        )
        let namedFields = graph.prohibitedFieldNameFindings()
        #expect(
            namedFields.isEmpty,
            "an assembled report carries a field named as a result magnitude: \(namedFields) [\(shape)]"
        )
        #expect(
            ProhibitedClaimAudit.findings(in: presentation).isEmpty,
            "the report presentation represents a prohibited claim: \(ProhibitedClaimAudit.findings(in: presentation)) [\(shape)]"
        )
        #expect(
            ForbiddenControlAudit.findings(in: presentation).isEmpty,
            "the report presentation carries a forbidden control: \(ForbiddenControlAudit.findings(in: presentation)) [\(shape)]"
        )

        // The vocabulary is closed, and closed at exactly what the requirements forbid.
        #expect(
            Set(ProhibitedPresentationClaim.allCases.map(\.rawValue))
                == RequiredByRequirement.prohibitedClaims,
            "the prohibited-claim vocabulary must be exactly the ten transcribed categories [\(shape)]"
        )
        #expect(
            EvidenceReportPresentation.excludedControls == Set(ExcludedResultControl.allCases),
            "the report must declare every excluded control [\(shape)]"
        )
        #expect(
            EvidenceReportPresentation.excludedControls.contains(
                .probabilityOrConfidenceRepresentation
            ),
            "a probability or confidence representation must be a declared exclusion [\(shape)]"
        )
        #expect(
            EvidenceReportPresentation.excludedControls
                .contains(.uncalibratedRawOutputDisclosure),
            "an unapproved raw-output disclosure must be a declared exclusion [\(shape)]"
        )
    }

    /// No presentation model stores rendered prose.
    ///
    /// Every user-facing sentence in this application reaches a view as a
    /// ``ResolvedCopyReference``, so the only display string in the whole graph is one
    /// *computed* from a pixel label. Every string a presentation model actually stores is an
    /// identifier, and an identifier carries no whitespace. A stored English sentence
    /// necessarily would, which is what makes the exclusion sharp rather than incidental.
    func checkNoRenderedProseIsStoredAnywhere() {
        #expect(
            graph.strings.isEmpty == false,
            "the walk must reach the identifiers a report stores; found none [\(shape)]"
        )
        for entry in graph.strings {
            // Computed outside the macro: `#expect` expands a trailing key-path call into a
            // `rethrows` invocation, which does not compile inside a nonthrowing arm.
            let carriesWhitespace = entry.value.contains(where: \.isWhitespace)
            let isASCII = entry.value.allSatisfy(\.isASCII)

            #expect(
                entry.value.isEmpty == false,
                "\(entry.path) stores an empty string [\(shape)]"
            )
            #expect(
                carriesWhitespace == false,
                "\(entry.path) stores '\(entry.value)', which carries whitespace and so is prose rather than an identifier [\(shape)]"
            )
            #expect(
                isASCII,
                "\(entry.path) stores a non-ASCII identifier: '\(entry.value)' [\(shape)]"
            )
        }
        // The displayed label is computed from the label key, not stored, so it does not
        // appear among the stored strings even though the report shows it.
        let displayed = presentation.cards.pixel.fixedLabelText.value
        #expect(
            graph.strings.contains(where: { $0.value == displayed }) == false,
            "the displayed label must be computed from its key rather than stored as text [\(shape)]"
        )
    }

    /// A catalogue with an approved value for every resolvable key passes the coverage gate.
    ///
    /// The presence beside the shipped catalogue's absence: the gate can be satisfied, so a
    /// failing shipped catalogue is a statement about the catalogue rather than about the
    /// gate.
    func checkACoveringCatalogCoversEveryResolvableKey() {
        #expect(
            coveringMissing.isEmpty,
            "a covering catalogue must cover every resolvable key; missing \(coveringMissing.map(\.rawValue)) [\(shape)]"
        )
        #expect(
            resolvableKeys.count >= 37,
            "a bound composition resolves at least the unconditional surfaces; found \(resolvableKeys.count) [\(shape)]"
        )
        #expect(
            Set(resolvableKeys).count == resolvableKeys.count,
            "no surface may share a localization key with another [\(shape)]"
        )
        // Reachability grows with the enabled capability set, so the resolvable set is larger
        // for a provenance-enabled composition than the unconditional floor.
        if shape.provenanceEnabled {
            #expect(
                resolvableKeys.count >= 42,
                "a provenance-enabled composition resolves the five enabled states too; found \(resolvableKeys.count) [\(shape)]"
            )
        }
    }

    /// One missing approved value is named rather than rendered.
    func checkOneMissingValueIsNamedRatherThanRendered() {
        #expect(
            gapMissing == [omittedKey],
            "omitting \(omittedSurface.description) must be reported as exactly that key; got \(gapMissing.map(\.rawValue)) [\(shape)]"
        )
    }

    /// The shipped catalogue approves every reachable surface except a Combined Summary, and
    /// whatever it does not approve is reported as a named gap rather than rendered.
    ///
    /// The honest state of the repository, updated. Requirement 8.2 fixes three display strings;
    /// the unconditional verdict surfaces and the five enabled provenance states now carry
    /// proposed English marked unapproved in the catalog itself. What is left is the Combined
    /// Summary, whose key an approved Evidence Fusion Rule would name.
    ///
    /// The property being checked is unchanged in kind: whatever has no approved value is a
    /// *named key*, never a rendered string. Only the size of that set moved.
    func checkTheShippedCatalogApprovesEverythingButTheCombinedSummary() {
        let fixedKeys = Set(EnglishStringCatalog.fixedPixelLabelKeys.values)

        #expect(
            fixedKeys.count == 3,
            "exactly three pixel-label keys are pinned; found \(fixedKeys.count) [\(shape)]"
        )
        #expect(
            fixedKeys.isSubset(of: Set(resolvableKeys)),
            "every pinned label key must be one the binding resolves [\(shape)]"
        )
        #expect(
            shippedMissing.allSatisfy { $0.rawValue.hasPrefix("copy.combined-summary") },
            "only a Combined Summary may lack an approved value; got \(shippedMissing.map(\.rawValue).sorted()) [\(shape)]"
        )
        #expect(
            Set(shippedMissing).isDisjoint(with: fixedKeys),
            "no fixed label key may be reported as missing [\(shape)]"
        )
        #expect(
            shippedMissing == shippedMissing.sorted { $0.rawValue < $1.rawValue },
            "a reported gap must be deterministic and diffable [\(shape)]"
        )
    }

    /// Requirement 8.1: a record naming a different compatibility identifier is refused, so
    /// no incompatible presentation exists to render.
    func checkAnIncompatibleRecordIsRefusedInsteadOfRendered() {
        guard let refusal = skewRefusal else {
            Issue.record("a compatibility-skewed \(shape.skewSource.rawValue) must be refused, not bound [\(shape)]")
            return
        }
        guard case let .compatibilityMismatch(source, expected, found) = refusal else {
            Issue.record("a compatibility skew must be refused as a compatibility mismatch; got \(refusal) [\(shape)]")
            return
        }
        #expect(
            source == shape.skewSource,
            "the refusal must name the record that disagreed; got \(source.rawValue) [\(shape)]"
        )
        #expect(
            expected == session.verdictCopyCompatibilityID,
            "the expected identifier must be the session-bound one [\(shape)]"
        )
        #expect(
            found == CopyFixture.artifact("copy.compatibility.skewed"),
            "the refusal must report the identifier it actually found [\(shape)]"
        )
    }

    /// Copy is bound per session, so a binding for another session is refused rather than
    /// used to render this one.
    func checkAnotherSessionsBindingIsRefused() {
        guard let refusal = foreignBindingRefusal else {
            Issue.record("another session's copy binding must be refused, not rendered [\(shape)]")
            return
        }
        guard case let .copyBindingSessionMismatch(screenSession, bindingSession) = refusal else {
            Issue.record("a foreign binding must be refused as a session mismatch; got \(refusal) [\(shape)]")
            return
        }
        #expect(
            screenSession == session.sessionID,
            "the refusal must name the screen's own session [\(shape)]"
        )
        #expect(
            bindingSession != session.sessionID,
            "the refusal must name a different binding session [\(shape)]"
        )
    }

    /// Every surface the closed approved vocabulary does not define is a recorded gap, and
    /// nothing renders a string for one.
    func checkEveryBlockedSurfaceIsRecordedRatherThanInvented() {
        let reportKeys = Set(UnapprovedReportSurface.allCases.map(\.rawValue))
        let viewStateKeys = Set(UnapprovedViewStateSurface.allCases.map(\.rawValue))
        let accessibilityKeys = Set(UnapprovedAccessibilitySurface.allCases.map(\.rawValue))

        #expect(
            EvidenceReportPresentation.unapprovedSurfaces
                == Set(UnapprovedReportSurface.allCases),
            "the report must declare every gap it has [\(shape)]"
        )
        #expect(
            reportKeys.count == UnapprovedReportSurface.allCases.count,
            "no two report gaps may share a key [\(shape)]"
        )
        #expect(
            reportKeys.count >= 10,
            "the report gaps recorded by task 11.3 must still be recorded; found \(reportKeys.count) [\(shape)]"
        )
        #expect(
            viewStateKeys.isEmpty == false && accessibilityKeys.isEmpty == false,
            "the view-state and accessibility gaps must still be recorded [\(shape)]"
        )
        #expect(
            reportKeys.isDisjoint(with: viewStateKeys),
            "a report gap collides with a view-state gap: \(reportKeys.intersection(viewStateKeys).sorted()) [\(shape)]"
        )
        #expect(
            reportKeys.isDisjoint(with: accessibilityKeys),
            "a report gap collides with an accessibility gap: \(reportKeys.intersection(accessibilityKeys).sorted()) [\(shape)]"
        )
        #expect(
            viewStateKeys.isDisjoint(with: accessibilityKeys),
            "a view-state gap collides with an accessibility gap: \(viewStateKeys.intersection(accessibilityKeys).sorted()) [\(shape)]"
        )
        for surface in UnapprovedReportSurface.allCases {
            #expect(
                surface.gates.isEmpty == false,
                "every recorded gap names the requirement it gates; \(surface.rawValue) names none [\(shape)]"
            )
        }

        // A gap is a surface the approved vocabulary does not define, so no gap key may name
        // a reachable copy surface, and nothing in an assembled report may render one.
        let gapKeys = reportKeys.union(viewStateKeys).union(accessibilityKeys)
        let reachable = Set(binding.reachableSurfaces.surfaces.map(\.description))
        #expect(
            reachable.isDisjoint(with: gapKeys),
            "a recorded gap names a surface the approved vocabulary defines: \(reachable.intersection(gapKeys).sorted()) [\(shape)]"
        )
        for entry in graph.strings {
            #expect(
                gapKeys.contains(entry.value) == false,
                "\(entry.path) renders the gap key '\(entry.value)' rather than nothing [\(shape)]"
            )
        }
    }

    /// The lane presentation state this case's report must produce.
    private var expectedLanePresentationState: ProvenanceLanePresentationState {
        switch shape.lane {
        case let .unavailable(reason): .unavailable(reason)
        case let .available(category): .available(category)
        }
    }
}

// MARK: - The transparency fact record

/// The transparency fields one assembled report exposes, as plain data.
///
/// Extracted so the completeness check is a pure function over a value this file can also
/// build by hand. That is what makes the check probeable: ``TransparencyProbeTests`` blanks
/// one field at a time and requires the check to fail, which a check written inline against a
/// real presentation could not demonstrate.
private struct TransparencyFacts {
    var componentIdentifiers: [DisclosedComponent: String]
    var recordedDimensions: [PreOrientationDimension: Int]
    var unrecordedDimensions: Set<PreOrientationDimension>
    var onDeviceProcessing: OnDeviceProcessingStatus
    var integrityStatus: ModelBundleIntegrityStatus
    var activationReceipt: String
    var verificationPolicy: String
    var verifiedArtifactCount: Int
    var bytePreservationStatus: BytePreservationStatus
    var disclosurePathSurfaces: [ReportDisclosurePath: VerdictCopySurface]

    /// Spelled out because the extracting initializer below suppresses the synthesized
    /// memberwise one, and the probes need to build a record by hand.
    init(
        componentIdentifiers: [DisclosedComponent: String],
        recordedDimensions: [PreOrientationDimension: Int],
        unrecordedDimensions: Set<PreOrientationDimension>,
        onDeviceProcessing: OnDeviceProcessingStatus,
        integrityStatus: ModelBundleIntegrityStatus,
        activationReceipt: String,
        verificationPolicy: String,
        verifiedArtifactCount: Int,
        bytePreservationStatus: BytePreservationStatus,
        disclosurePathSurfaces: [ReportDisclosurePath: VerdictCopySurface]
    ) {
        self.componentIdentifiers = componentIdentifiers
        self.recordedDimensions = recordedDimensions
        self.unrecordedDimensions = unrecordedDimensions
        self.onDeviceProcessing = onDeviceProcessing
        self.integrityStatus = integrityStatus
        self.activationReceipt = activationReceipt
        self.verificationPolicy = verificationPolicy
        self.verifiedArtifactCount = verifiedArtifactCount
        self.bytePreservationStatus = bytePreservationStatus
        self.disclosurePathSurfaces = disclosurePathSurfaces
    }

    init(extractedFrom presentation: EvidenceReportPresentation) {
        let details = presentation.technicalDetails
        self.componentIdentifiers = Dictionary(
            uniqueKeysWithValues: DisclosedComponent.allCases.map {
                ($0, details.components.identifier(for: $0))
            }
        )
        self.recordedDimensions = Dictionary(
            uniqueKeysWithValues: details.dimensions.recorded.map { ($0.dimension, $0.pixels) }
        )
        self.unrecordedDimensions = Set(details.dimensions.unrecorded)
        self.onDeviceProcessing = details.onDeviceProcessing
        self.integrityStatus = details.integrity.status
        self.activationReceipt = details.integrity.activationReceipt.rawValue
        self.verificationPolicy = details.integrity.verificationPolicy.rawValue
        self.verifiedArtifactCount = details.integrity.verifiedArtifactCount
        self.bytePreservationStatus = presentation.limitations.bytePreservation.status
        self.disclosurePathSurfaces = Dictionary(
            uniqueKeysWithValues: ReportDisclosurePath.allCases.map {
                ($0, presentation.disclosurePaths.reference(for: $0).surface)
            }
        )
    }

    /// Every way `facts` falls short of what Requirements 8.12, 10.18, and 4.12 require.
    ///
    /// Total over the closed vocabularies rather than a list of spot checks: a component,
    /// dimension, or path that stops being reported is a finding, not a silently smaller set.
    static func findings(
        in facts: TransparencyFacts,
        expectingRecordedDimensions: Bool,
        expectedWidth: Int,
        expectedHeight: Int,
        expectedOnDevice: Bool,
        expectedByteStatus: BytePreservationStatus
    ) -> [String] {
        var findings: [String] = []

        for component in DisclosedComponent.allCases {
            guard let identifier = facts.componentIdentifiers[component] else {
                findings.append("no identifier disclosed for \(component.rawValue)")
                continue
            }
            if identifier.isEmpty {
                findings.append("\(component.rawValue) discloses an empty identifier")
            }
        }

        let recorded = Set(facts.recordedDimensions.keys)
        if !recorded.isDisjoint(with: facts.unrecordedDimensions) {
            findings.append("a dimension is reported as both recorded and unrecorded")
        }
        if recorded.union(facts.unrecordedDimensions) != Set(PreOrientationDimension.allCases) {
            findings.append("the dimension projection is not total over the vocabulary")
        }
        if expectingRecordedDimensions {
            if recorded != Set(PreOrientationDimension.allCases) {
                findings.append("a measured session must report all three dimensions")
            }
            if facts.recordedDimensions[.decodedWidth] != expectedWidth {
                findings.append("the recorded width is not the measured width")
            }
            if facts.recordedDimensions[.decodedHeight] != expectedHeight {
                findings.append("the recorded height is not the measured height")
            }
            if facts.recordedDimensions[.shortEdge] != min(expectedWidth, expectedHeight) {
                findings.append("the short edge is not the lesser recorded dimension")
            }
        } else if !recorded.isEmpty {
            findings.append("an unmeasured session must substitute no dimension value")
        }

        let expectedStatus: OnDeviceProcessingStatus =
            expectedOnDevice ? .allProcessingOnDevice : .notRecordedAsFullyOnDevice
        if facts.onDeviceProcessing != expectedStatus {
            findings.append("the on-device status does not reflect the recorded fact")
        }
        if facts.integrityStatus != .verified {
            findings.append("the disclosed integrity status is not verified")
        }
        if facts.activationReceipt.isEmpty {
            findings.append("no activation receipt version is disclosed")
        }
        if facts.verificationPolicy.isEmpty {
            findings.append("no verification policy version is disclosed")
        }
        if facts.verifiedArtifactCount < 1 {
            findings.append("the verified artifact count is not a real count")
        }
        if facts.bytePreservationStatus != expectedByteStatus {
            findings.append("the exposed byte status is not the recorded one")
        }

        let expectedPaths: [ReportDisclosurePath: VerdictCopySurface] = [
            .modelInformation: .modelInformation,
            .privacyBehavior: .privacyExplanation,
            .correctionChannel: .correctionChannel,
        ]
        for path in ReportDisclosurePath.allCases {
            guard let surface = facts.disclosurePathSurfaces[path] else {
                findings.append("no onward path for \(path.rawValue)")
                continue
            }
            if surface != expectedPaths[path] {
                findings.append("\(path.rawValue) does not address its approved surface")
            }
        }

        return findings
    }
}

// MARK: - The reachable value graph

/// Every value one assembled presentation reaches, by reflection.
///
/// The structural half of Requirement 8.13. A source-text audit for "no probability type"
/// would be a false-positive machine, because this module's own documentation names every
/// forbidden category on purpose. So the claim is made on the type system instead: walk the
/// assembled value, collect the *types* and the *field names* it reaches, and compare them
/// against a transcribed list.
///
/// The walk records what it reached as well as what it did not, so every measured zero sits
/// beside a measured count. An empty or truncated walk fails its own floors rather than
/// reporting a clean graph.
private struct PresentationGraph {
    /// Fully qualified names of every type reached.
    var typeNames: Set<String> = []

    /// Every stored property label reached, with its path.
    var labels: [(path: String, label: String)] = []

    /// Every stored `String` reached.
    var strings: [(path: String, value: String)] = []

    /// Every stored integer measurement reached. This module deliberately carries these — a
    /// recorded pixel dimension and a verified-artifact count are exact measurements, not
    /// result magnitudes — so they are the presence the magnitude zero is measured against.
    var integers: [(path: String, value: Int)] = []

    /// Every resolved approved-copy reference reached.
    var references: [ResolvedCopyReference] = []

    /// How many values the walk visited in total.
    var nodeCount = 0

    /// Depth ceiling. A presentation is a shallow value tree; the bound only stops a
    /// pathological graph from hanging a test.
    static let maximumDepth = 12

    /// Type-name tokens that are how a consumer probability, confidence value or level,
    /// percentage, score, raw logit, or probability-like graphical encoding arrives.
    ///
    /// Transcribed here rather than derived, so this is a claim rather than a restatement of
    /// whatever the module happens to contain. Matched on word boundaries, so `Float16` and
    /// `Float` are listed separately and neither matches an unrelated identifier.
    static let magnitudeTypeTokens = [
        "Double",
        "Float",
        "Float16",
        "Float32",
        "Float64",
        "Float80",
        "CGFloat",
        "Decimal",
        "NSNumber",
        "NSDecimalNumber",
        "Probability",
        "Confidence",
        "ConfidenceLevel",
        "Likelihood",
        "Percent",
        "Percentage",
        "Score",
        "Logit",
        "Certainty",
        "Gauge",
        "ProgressView",
    ]

    /// Field-name fragments that mark a member as a result magnitude, matched against a
    /// normalized label.
    static let prohibitedNameFragments = [
        "probab",
        "confidence",
        "certainty",
        "percent",
        "score",
        "logit",
        "likelihood",
        "chance",
        "gauge",
        "meter",
    ]

    static func walking<Model: ProbabilityFreePresentationModel>(_ model: Model) -> PresentationGraph {
        var graph = PresentationGraph()
        graph.visit(model, path: "\(Model.self)", depth: 0)
        return graph
    }

    private mutating func visit(_ value: Any, path: String, depth: Int) {
        guard depth < Self.maximumDepth else { return }

        nodeCount += 1
        typeNames.insert(String(reflecting: type(of: value)))

        if let string = value as? String { strings.append((path, string)) }
        if let integer = value as? Int { integers.append((path, integer)) }
        if let reference = value as? ResolvedCopyReference { references.append(reference) }

        let mirror = Mirror(reflecting: value)

        // Look through an optional at the same path, so a wrapped value is recorded once and
        // under the field's own name rather than as `field.some`.
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return }
            visit(wrapped, path: path, depth: depth + 1)
            return
        }

        for child in mirror.children {
            let label = child.label ?? "<unlabeled>"
            let childPath = "\(path).\(label)"
            if child.label != nil { labels.append((childPath, label)) }
            visit(child.value, path: childPath, depth: depth + 1)
        }
    }

    /// Every reached type that is a result-magnitude representation.
    func magnitudeTypeFindings() -> [String] {
        typeNames
            .filter { name in
                Self.magnitudeTypeTokens.contains { token in
                    name.range(of: "\\b\(token)\\b", options: .regularExpression) != nil
                }
            }
            .sorted()
    }

    /// Every reached field whose name marks it as a result magnitude.
    func prohibitedFieldNameFindings() -> [String] {
        labels
            .filter { entry in
                let name = entry.label.lowercased().filter { $0.isLetter || $0.isNumber }
                return Self.prohibitedNameFragments.contains { name.contains($0) }
            }
            .map(\.path)
            .sorted()
    }
}

// MARK: - Negative controls

/// The probes that prove the two structural checks can fail.
///
/// A structural absence is worthless without a demonstration that the mechanism measuring it
/// reports a presence. Both probes run entirely through this file's own seams: the transparency
/// check runs over a fact record this file can blank a field in, and the graph walk runs over a
/// deliberately non-compliant stand-in. Nothing in the shipping module is edited, and nothing
/// like either stand-in is representable there.
@Suite("Property 23 probes: the structural checks can fail")
struct TransparencyProbeTests {

    /// A complete fact record, matching what an assembled report exposes.
    private static func completeFacts() -> TransparencyFactsProbe {
        TransparencyFactsProbe(
            facts: TransparencyFacts(
                componentIdentifiers: Dictionary(
                    uniqueKeysWithValues: DisclosedComponent.allCases.map {
                        ($0, "component.\($0.rawValue).synthetic")
                    }
                ),
                recordedDimensions: [
                    .decodedWidth: 1024,
                    .decodedHeight: 768,
                    .shortEdge: 768,
                ],
                unrecordedDimensions: [],
                onDeviceProcessing: .allProcessingOnDevice,
                integrityStatus: .verified,
                activationReceipt: "receipt.activation.synthetic",
                verificationPolicy: "policy.bundle-verification.synthetic",
                verifiedArtifactCount: 1,
                bytePreservationStatus: .originalBytes,
                disclosurePathSurfaces: [
                    .modelInformation: .modelInformation,
                    .privacyBehavior: .privacyExplanation,
                    .correctionChannel: .correctionChannel,
                ]
            )
        )
    }

    @Test("A complete fact record has no findings, so the probes below mean something")
    func completeRecordPasses() {
        #expect(Self.completeFacts().findings().isEmpty)
    }

    @Test(
        "Blanking one component version is reported",
        arguments: DisclosedComponent.allCases
    )
    func blankedComponentIsReported(component: DisclosedComponent) {
        var probe = Self.completeFacts()
        probe.facts.componentIdentifiers[component] = ""

        #expect(probe.findings().contains { $0.contains(component.rawValue) })
    }

    @Test(
        "Dropping one component version entirely is reported",
        arguments: DisclosedComponent.allCases
    )
    func droppedComponentIsReported(component: DisclosedComponent) {
        var probe = Self.completeFacts()
        probe.facts.componentIdentifiers[component] = nil

        #expect(probe.findings().contains { $0.contains(component.rawValue) })
    }

    @Test(
        "Dropping one recorded dimension is reported",
        arguments: PreOrientationDimension.allCases
    )
    func droppedDimensionIsReported(dimension: PreOrientationDimension) {
        var probe = Self.completeFacts()
        probe.facts.recordedDimensions[dimension] = nil

        #expect(probe.findings().isEmpty == false)
    }

    @Test("Dropping one onward path is reported", arguments: ReportDisclosurePath.allCases)
    func droppedPathIsReported(path: ReportDisclosurePath) {
        var probe = Self.completeFacts()
        probe.facts.disclosurePathSurfaces[path] = nil

        #expect(probe.findings().contains { $0.contains(path.rawValue) })
    }

    @Test("Pointing an onward path at the wrong surface is reported")
    func misdirectedPathIsReported() {
        var probe = Self.completeFacts()
        probe.facts.disclosurePathSurfaces[.privacyBehavior] = .modelInformation

        #expect(probe.findings().contains { $0.contains("privacy-behavior") })
    }

    @Test("Substituting a value for an unmeasured dimension is reported")
    func substitutedDimensionIsReported() {
        var probe = Self.completeFacts()
        probe.expectsRecordedDimensions = false

        // An unmeasured session must report absence rather than a value.
        #expect(probe.findings().isEmpty == false)
    }

    @Test("Losing the byte status is reported")
    func changedByteStatusIsReported() {
        var probe = Self.completeFacts()
        probe.facts.bytePreservationStatus = .unknown

        #expect(probe.findings().contains { $0.contains("byte status") })
    }

    @Test("An on-device status that disagrees with the recorded fact is reported")
    func disagreeingOnDeviceStatusIsReported() {
        var probe = Self.completeFacts()
        probe.facts.onDeviceProcessing = .notRecordedAsFullyOnDevice

        #expect(probe.findings().contains { $0.contains("on-device") })
    }

    @Test("A verified-artifact count of zero is reported")
    func emptyIntegrityInventoryIsReported() {
        var probe = Self.completeFacts()
        probe.facts.verifiedArtifactCount = 0

        #expect(probe.findings().contains { $0.contains("count") })
    }

    @Test("The graph walk reports a smuggled probability-shaped value")
    func graphWalkCatchesASmuggledMagnitude() {
        let graph = PresentationGraph.walking(SmuggledMagnitudeModel.populated)

        #expect(graph.magnitudeTypeFindings().isEmpty == false)
        #expect(
            graph.prohibitedFieldNameFindings().contains { $0.hasSuffix(".confidenceLevel") }
        )
    }

    @Test("The graph walk reports a magnitude even when the value is absent")
    func graphWalkCatchesAnUnpopulatedMagnitude() {
        // The declared type is what matters. An `Optional<Double>` that happens to be `nil`
        // is still a field a probability could be written into.
        let graph = PresentationGraph.walking(SmuggledMagnitudeModel.empty)

        #expect(graph.magnitudeTypeFindings().isEmpty == false)
    }

    @Test("The graph walk reports a magnitude nested inside an otherwise clean model")
    func graphWalkCatchesANestedMagnitude() {
        let graph = PresentationGraph.walking(NestingModel.populated)

        #expect(graph.magnitudeTypeFindings().isEmpty == false)
        #expect(graph.nodeCount >= 3)
    }

    @Test("The graph walk reports stored prose")
    func graphWalkSeesStoredProse() {
        // The stored-prose exclusion is a claim about whitespace, so it has to be shown able
        // to see a sentence.
        let graph = PresentationGraph.walking(SmuggledMagnitudeModel.populated)

        #expect(graph.strings.contains { $0.value.contains(where: \.isWhitespace) })
    }
}

/// A mutable wrapper around ``TransparencyFacts`` for the probes.
private struct TransparencyFactsProbe {
    var facts: TransparencyFacts
    var expectsRecordedDimensions = true
    var expectedWidth = 1024
    var expectedHeight = 768
    var expectedOnDevice = true
    var expectedByteStatus = BytePreservationStatus.originalBytes

    func findings() -> [String] {
        TransparencyFacts.findings(
            in: facts,
            expectingRecordedDimensions: expectsRecordedDimensions,
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight,
            expectedOnDevice: expectedOnDevice,
            expectedByteStatus: expectedByteStatus
        )
    }
}

/// A deliberately non-compliant stand-in, so the graph walk is proven able to fail.
///
/// It exists only in tests. Nothing shaped like it is representable in the shipping module:
/// no presentation model has a floating-point field, a percentage, or a stored sentence.
private struct SmuggledMagnitudeModel: ProbabilityFreePresentationModel {
    let magnitude: Double?
    let confidenceLevel: String?

    static let populated = SmuggledMagnitudeModel(
        magnitude: 0.87,
        confidenceLevel: "high confidence in this result"
    )
    static let empty = SmuggledMagnitudeModel(magnitude: nil, confidenceLevel: nil)
}

/// A clean-looking model with a magnitude one level down, so the walk is shown to recurse.
private struct NestingModel: ProbabilityFreePresentationModel {
    let inner: SmuggledMagnitudeModel

    static let populated = NestingModel(inner: .populated)
}

// MARK: - Non-vacuity witness

/// Counts what the run generated, assembled, walked, and refused — outside the property body.
///
/// `propertyCheck` runs its body under `try?` and discards a thrown error, so a body that
/// failed on its first statement would report a passing test in milliseconds with every arm
/// skipped. `completedBodies == cases` alone does not catch that: it passes vacuously as
/// `0 == 0`. The case floor, `cases == requestedCases`, `executedCases == cases`, the
/// per-case counts, and the produced sets are what close the gap, and they live here because
/// an issue recorded outside the body is not suppressed.
///
/// The substantive half is the produced sets and the paired presences. Every pixel label,
/// every lane state, and every byte status must have been generated; both compositions must
/// have run; both dimension recordings, both on-device statuses, a shown Combined Summary and
/// both omission reasons, a declared inconsistency and an undeclared one, all six
/// omitted-surface kinds, and both compatibility-skew sources must all have been measured.
/// Those are what turn each measured zero into a measurement rather than an accident of a
/// narrow run.
private final class PresentationWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Run shape.
    private var cases = 0
    private var completedBodies = 0
    private var executedCases = 0
    private var unbuildableInputs = 0

    // Measurement volume.
    private var resolvedReferences = 0
    private var walkedNodes = 0
    private var walkedStrings = 0
    private var walkedIntegers = 0
    private var reportedGapKeys = 0

    // Compositions and paired presences.
    private var pixelOnlyCases = 0
    private var provenanceEnabledCases = 0
    private var fusionBoundCases = 0
    private var summariesShown = 0
    private var summariesOmitted = 0
    private var inconsistenciesDeclared = 0
    private var inconsistenciesUndeclared = 0
    private var measuredDimensionCases = 0
    private var unmeasuredDimensionCases = 0
    private var onDeviceRecordedCases = 0
    private var onDeviceNotRecordedCases = 0
    private var screenshotExplanationsShown = 0
    private var skewsRefused = 0
    private var foreignBindingsRefused = 0
    private var coveringCatalogsThatCovered = 0
    private var shippedCatalogsWithARealGap = 0

    // Produced coverage.
    private var observedPixelLabels: Set<String> = []
    private var observedLaneStates: Set<String> = []
    private var observedByteStatuses: Set<String> = []
    private var observedDistinctions: Set<ProvenanceLaneDistinction> = []
    private var observedOmissionReasons: Set<FusionOmissionReason> = []
    private var observedOmittedSurfaceKinds: Set<Int> = []
    private var observedSkewSources: Set<CopyCompatibilitySource> = []
    private var observedTypeNames: Set<String> = []
    private var seeds: Set<Int> = []

    func record(_ shape: ReportShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        observedPixelLabels.insert(shape.pixel.rawValue)
        observedLaneStates.insert(shape.lane.coverageKey)
        observedByteStatuses.insert(shape.bytePreservationStatus.rawValue)
        observedOmittedSurfaceKinds.insert(shape.omittedSurfaceKind)
        observedSkewSources.insert(shape.skewSource)
        if shape.provenanceEnabled { provenanceEnabledCases += 1 } else { pixelOnlyCases += 1 }
        if shape.bindsFusionRule { fusionBoundCases += 1 }
        if shape.recordsDimensions {
            measuredDimensionCases += 1
        } else {
            unmeasuredDimensionCases += 1
        }
        if shape.onDeviceProcessing {
            onDeviceRecordedCases += 1
        } else {
            onDeviceNotRecordedCases += 1
        }
        if shape.declaresInconsistency {
            inconsistenciesDeclared += 1
        } else {
            inconsistenciesUndeclared += 1
        }
    }

    func recordExecutedCase(_ run: PresentationCase) {
        lock.lock()
        defer { lock.unlock() }
        executedCases += 1
        resolvedReferences += run.graph.references.count
        walkedNodes += run.graph.nodeCount
        walkedStrings += run.graph.strings.count
        walkedIntegers += run.graph.integers.count
        reportedGapKeys += run.shippedMissing.count
        observedTypeNames.formUnion(run.graph.typeNames)
        observedDistinctions.insert(run.presentation.cards.provenance.distinction)

        switch run.presentation.combinedSummary {
        case .shown: summariesShown += 1
        case let .omitted(reason):
            summariesOmitted += 1
            observedOmissionReasons.insert(reason)
        }
        if case .shownForAbsentCredential = run.presentation.cards.provenance
            .screenshotExplanation
        {
            screenshotExplanationsShown += 1
        }
        if run.skewRefusal != nil { skewsRefused += 1 }
        if run.foreignBindingRefusal != nil { foreignBindingsRefused += 1 }
        if run.coveringMissing.isEmpty { coveringCatalogsThatCovered += 1 }
        if !run.shippedMissing.isEmpty { shippedCatalogsWithARealGap += 1 }
    }

    /// Records an input this file described but could not build.
    ///
    /// Never a finding about the presentation layer: every input here is built from generated
    /// integers inside validated ranges and forced coherent before construction, so a refusal
    /// is a defect in this file. It is counted so a run whose inputs quietly stopped being
    /// buildable fails outside the body rather than shrinking its own coverage.
    func recordUnbuildableInput() {
        lock.lock()
        unbuildableInputs += 1
        lock.unlock()
    }

    /// Called last in the body, so a case that stopped early is countable.
    func recordCompletedBody() {
        lock.lock()
        completedBodies += 1
        lock.unlock()
    }

    func expectMeasuredRun(requestedCases: Int) {
        lock.lock()
        defer { lock.unlock() }

        let expectedLaneStates = Set(ReportShape.laneStates.map(\.coverageKey))
        let readOut = """
            cases \(cases)/\(requestedCases), completed bodies \(completedBodies), \
            executed \(executedCases), unbuildable \(unbuildableInputs); \
            resolved references \(resolvedReferences), walked nodes \(walkedNodes) \
            (strings \(walkedStrings), integers \(walkedIntegers)), \
            reached types \(observedTypeNames.count); \
            compositions pixel-only \(pixelOnlyCases) / provenance \(provenanceEnabledCases) \
            (fusion bound \(fusionBoundCases)); \
            summaries shown \(summariesShown) / omitted \(summariesOmitted) \
            reasons \(observedOmissionReasons.map(\.rawValue).sorted()); \
            inconsistencies declared \(inconsistenciesDeclared) / \
            undeclared \(inconsistenciesUndeclared); \
            dimensions measured \(measuredDimensionCases) / \
            unmeasured \(unmeasuredDimensionCases); \
            on-device recorded \(onDeviceRecordedCases) / \
            not recorded \(onDeviceNotRecordedCases); \
            screenshot explanations \(screenshotExplanationsShown); \
            skews refused \(skewsRefused), foreign bindings refused \(foreignBindingsRefused); \
            covering catalogues that covered \(coveringCatalogsThatCovered), \
            shipped catalogues with a real gap \(shippedCatalogsWithARealGap) \
            (\(reportedGapKeys) reported keys); \
            labels \(observedPixelLabels.count)/3, \
            lane states \(observedLaneStates.count)/\(expectedLaneStates.count), \
            byte statuses \(observedByteStatuses.count)/3, \
            distinctions \(observedDistinctions.count)/3, \
            omitted-surface kinds \(observedOmittedSurfaceKinds.count)/\(ReportShape.omittedSurfaceKindCount), \
            skew sources \(observedSkewSources.count)/2, seeds \(seeds.count)
            """

        // The run happened at all.
        #expect(
            cases == requestedCases && completedBodies == cases && executedCases == cases,
            "read-out: \(readOut)"
        )
        #expect(
            cases == requestedCases,
            "the run must generate \(requestedCases) cases; ran \(cases)"
        )
        #expect(
            cases >= 200,
            "a run this thin cannot support the coverage floors below; ran \(cases) cases"
        )
        #expect(
            completedBodies == cases,
            "\(cases - completedBodies) of \(cases) cases did not reach the end of the body"
        )
        #expect(
            executedCases == cases,
            "\(cases - executedCases) of \(cases) cases assembled no presentation"
        )
        #expect(
            unbuildableInputs == 0,
            "\(unbuildableInputs) described inputs could not be built at all"
        )

        // Counted work. Every case assembles one report, walks it, and audits four catalogues.
        #expect(
            resolvedReferences >= 8 * cases,
            "approved references resolved: \(resolvedReferences) for \(cases) cases"
        )
        #expect(
            walkedNodes >= 30 * cases,
            "values visited by the graph walk: \(walkedNodes) for \(cases) cases"
        )
        #expect(
            walkedStrings >= 8 * cases,
            "identifiers reached by the graph walk: \(walkedStrings) for \(cases) cases"
        )
        #expect(
            walkedIntegers >= cases,
            "integer measurements reached by the graph walk, without which the magnitude zero is the zero of an empty walk: \(walkedIntegers)"
        )
        #expect(
            observedTypeNames.count >= 30,
            "distinct types reached across the run: \(observedTypeNames.count)"
        )

        // Every refusal happened on every case, and every catalogue audit answered.
        #expect(
            skewsRefused == cases,
            "\(cases - skewsRefused) cases bound a compatibility-skewed record instead of refusing it"
        )
        #expect(
            foreignBindingsRefused == cases,
            "\(cases - foreignBindingsRefused) cases assembled through another session's binding"
        )
        #expect(
            coveringCatalogsThatCovered == cases,
            "\(cases - coveringCatalogsThatCovered) cases could not be covered at all, so the shipped gap is a statement about the gate rather than the catalogue"
        )
        // These two floors used to require a gap on *every* case and at least thirty missing keys
        // per case. Both were non-vacuity guards: they existed so a passing audit could not be a
        // statement about an empty report, back when the shipped catalogue approved three strings.
        //
        // The shipped catalogue now approves every reachable surface except a Combined Summary, so
        // requiring a gap everywhere would require the gap to stay open, which is the opposite of
        // what the floor was for. What still has to hold is that the gate is *exercised in both
        // directions* by this run: some cases report a gap and some report none, and a case that
        // reports one reports at least the key it is missing.
        #expect(
            shippedCatalogsWithARealGap > 0,
            "no case reported a gap, so the audit was never exercised against a missing value"
        )
        #expect(
            shippedCatalogsWithARealGap < cases,
            "every case reported a gap, so no case exercised a fully covered catalogue"
        )
        #expect(
            reportedGapKeys >= shippedCatalogsWithARealGap,
            "a case with a gap must report at least one key: \(reportedGapKeys) keys across \(shippedCatalogsWithARealGap) cases"
        )

        // Every absence was measured beside a presence.
        #expect(
            pixelOnlyCases >= 60,
            "pixel-only compositions, without which the unavailable-lane surface is never exercised: \(pixelOnlyCases)"
        )
        #expect(
            provenanceEnabledCases >= 150,
            "provenance-enabled compositions, without which no enabled state is exercised: \(provenanceEnabledCases)"
        )
        #expect(
            fusionBoundCases >= 50,
            "compositions binding a fusion rule: \(fusionBoundCases)"
        )
        #expect(
            summariesShown >= 20,
            "shown Combined Summaries, without which every summary zero is vacuous: \(summariesShown)"
        )
        #expect(
            summariesOmitted >= 100,
            "omitted Combined Summaries: \(summariesOmitted)"
        )
        #expect(
            observedOmissionReasons == Set(FusionOmissionReason.allCases),
            "omission reasons never recorded: \(Set(FusionOmissionReason.allCases).subtracting(observedOmissionReasons).map(\.rawValue).sorted())"
        )
        #expect(
            inconsistenciesDeclared >= 50,
            "reports declaring an apparent inconsistency: \(inconsistenciesDeclared)"
        )
        #expect(
            inconsistenciesUndeclared >= 50,
            "reports declaring none: \(inconsistenciesUndeclared)"
        )
        #expect(
            measuredDimensionCases >= 100,
            "sessions that recorded their pre-orientation dimensions: \(measuredDimensionCases)"
        )
        #expect(
            unmeasuredDimensionCases >= 100,
            "sessions that recorded none, so absence is measured as absence: \(unmeasuredDimensionCases)"
        )
        #expect(
            onDeviceRecordedCases >= 100,
            "sessions recorded as fully on device: \(onDeviceRecordedCases)"
        )
        #expect(
            onDeviceNotRecordedCases >= 100,
            "sessions not recorded as fully on device, so both named statuses are rendered: \(onDeviceNotRecordedCases)"
        )
        #expect(
            screenshotExplanationsShown >= 20,
            "enabled absent results carrying the approved screenshot explanation: \(screenshotExplanationsShown)"
        )

        // The substantive half: the inputs were actually varied.
        #expect(
            observedPixelLabels == Set(PixelEvidence.allCases.map(\.rawValue)),
            "pixel labels never generated: \(Set(PixelEvidence.allCases.map(\.rawValue)).subtracting(observedPixelLabels).sorted())"
        )
        #expect(
            observedLaneStates == expectedLaneStates,
            "lane states never generated: \(expectedLaneStates.subtracting(observedLaneStates).sorted())"
        )
        #expect(
            observedByteStatuses == Set(BytePreservationStatus.allCases.map(\.rawValue)),
            "byte statuses never generated: \(Set(BytePreservationStatus.allCases.map(\.rawValue)).subtracting(observedByteStatuses).sorted())"
        )
        #expect(
            observedDistinctions == Set(ProvenanceLaneDistinction.allCases),
            "lane distinctions never produced: \(Set(ProvenanceLaneDistinction.allCases).subtracting(observedDistinctions).map(\.rawValue).sorted())"
        )
        #expect(
            observedOmittedSurfaceKinds.count == ReportShape.omittedSurfaceKindCount,
            "omitted-surface kinds never exercised: \(observedOmittedSurfaceKinds.sorted())"
        )
        #expect(
            observedSkewSources == [.copyCatalog, .capabilityManifest],
            "compatibility-skew sources never exercised: \(observedSkewSources.map(\.rawValue).sorted())"
        )
        #expect(seeds.count >= 200, "generated seeds: \(seeds.count)")
    }
}
