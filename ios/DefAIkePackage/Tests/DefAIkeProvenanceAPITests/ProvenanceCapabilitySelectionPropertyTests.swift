import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain
@testable import DefAIkeProvenanceAPI

// Design Property 19: provenance capability selection is exact.
//
// The design states it as: for any release gate matrix and completed pixel result,
// provenance is enabled if and only if its complete feasibility gate passes and its exact
// implementation is compiled into the build; otherwise, when all mandatory non-provenance
// gates pass, the release composition is pixel-only, the analyzer is never invoked, every
// report uses only the unavailable lane, and Combined Summary is absent.
//
// The statement is two-sided, and both sides are asserted on every generated case:
//
//   * **only a complete passing exact implementation enables provenance.** Five
//     conditions are jointly necessary — the implementation is compiled in, the signed
//     Release Capability Manifest enables the capability, it binds exactly this
//     Provenance Policy, it records exactly this implementation version, and the policy
//     carries an approved Provenance Feasibility decision. The generated combination of
//     those conditions is compared against an expectation read off the requirement, and a
//     complete baseline is then knocked down one condition at a time, so "exact" means
//     each condition is individually necessary rather than jointly sufficient;
//   * **every other eligible composition stays pixel-only with no Combined Summary.**
//     For each non-enabling composition: the lane is one of the two unavailable states
//     and nothing else, the analyzer records zero calls, no inspection is described, and
//     the report for the generated completed pixel result exists without a Combined
//     Summary while a report *with* one is unrepresentable.
//
// Every case also runs a **control**: a complete passing composition built from the same
// generated values, which must reach the validator exactly once with this session's asset
// and return the generated state as an available lane. The nonoccurrence half is the kind
// of claim that holds when nothing happens for the wrong reason — a spy wired to nothing
// also records zero calls — so the control is what proves the recorder would have seen a
// call had one been made. It runs on every generated case rather than once, so a change
// that silently disconnects the analyzer fails a hundred times instead of never.
//
// ## The gate matrix half
//
// Requirement 6.3 makes the pixel-only release *permitted* rather than merely tolerated,
// and it is conditional: the provenance feasibility gate does not pass **and** every
// mandatory non-provenance gate does. Both halves are asserted over generated matrices —
// a matrix whose only unsatisfied gate is provenance feasibility blocks nothing, and the
// same matrix with one generated mandatory non-provenance gate failed or unexecuted blocks
// and names that gate. The qualifier therefore bites instead of decorating the sentence.
//
// Fusion is checked only where Requirement 7.10 puts it: a Combined Summary cannot outlive
// the provenance lane. A pixel-only gate matrix cannot carry an applicable fusion gate, a
// pixel-only manifest cannot compile fusion or bind a Provenance Policy, and an
// unavailable lane has no fusion key at all.
//
// ## Neighbouring properties, and what this file does not assert
//
//   * **Property 20** owns the mapping from a normalized validator outcome to one of the
//     five enabled states. Here a state is an *input*: the control's analyzer returns a
//     generated one, and the only claim is that the provider passes it through unchanged.
//   * **Property 21** owns lane immutability and noninterference. The completed pixel
//     result appears here only as the report field Requirement 6.4 is about.
//   * **Property 22** owns fusion exhaustiveness and determinism, and validates candidate
//     rules. No rule table is built or validated in this file.
//   * **Property 33** owns whether a release-readiness record is auditable and whether a
//     conditional gate's applicability matches the signed manifest. What is added here is
//     Requirement 6.3's permission, stated on the record's own gate predicates.
//   * `UnavailableProvenanceLaneTests` pins each refusal at one condition with one
//     example. This file quantifies the same statement over generated conditions, states,
//     labels, routes, preservation bases, gate matrices, and identifiers.
//
// ## The conformance seam this property is written against
//
// The conditional C2PA adapter deliberately does not conform to `ProvenanceAnalyzing`,
// because the port returns evidence unconditionally and cannot express "no approved input
// answers this". That is a recorded open question, not a defect, and it is fail-closed:
// `ProvenanceLaneProvider.resolve(analyzer:policy:manifest:)` treats a `nil` analyzer as
// the pixel-only lane whatever the signed manifest says. So "the exact implementation is
// compiled into the build" is quantified here as the presence of a port conformance, with
// a recording double standing in for it, and the property asserts nothing about which
// concrete adapter supplies one.
//
// **No value in this file is an approved release input.** The trust store, revocation
// answer, status mappings, displayable fields, processing limits, feasibility decision,
// gate outcomes, waiver decisions, governance record, and every identifier are synthetic
// arguments that exist so a seam taking a signed artifact can be called at all. No
// assertion claims any of them is correct, and nothing here may be copied into a shipping
// artifact.

extension Tag {
    /// Design Property 19.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property19ProvenanceCapabilitySelection: Self
}

@Suite(
    "Property 19: Provenance capability selection is exact",
    .tags(.property19ProvenanceCapabilitySelection)
)
struct ProvenanceCapabilitySelectionPropertyTests {
    /// Runs at the library default of 100 generated cases with shrinking, which is the
    /// minimum the design requires; `PropertyToolchainWiringTests` pins that default.
    /// Every generator is composed with `zip`, so the shrinkers compose.
    ///
    /// **Validates: Requirements 6.2, 6.3, 6.4, 6.19, 6.20, 7.10**
    @Test("Capability selection is exact over generated gate matrices and compositions")
    func provenanceCapabilitySelectionIsExact() async {
        let witness = CapabilitySelectionVariationWitness()

        await propertyCheck(input: CapabilityShape.generator) { shape in
            witness.record(shape)
            guard let scenario = CapabilitySelectionScenario(shape: shape) else { return }

            await scenario.checkEnabledControlReachesTheValidator()
            await scenario.checkGeneratedCompositionMatchesTheRequirement()
            await scenario.checkEachMissingConditionDisablesProvenance()
            scenario.checkGateMatrixPermitsAnOtherwiseCompletePixelOnlyRelease()
            scenario.checkCombinedSummaryCannotOutliveTheProvenanceLane()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - The conditions the requirement makes necessary

/// One jointly necessary condition for enabling on-device Content Credential validation.
///
/// Requirement 6.2 enables the capability only when the Provenance Feasibility Gate
/// passes, and the design adds that its exact implementation has to be compiled into the
/// build. These are the pieces of that sentence the provenance-lane seam can actually be
/// asked about, listed so each one can be removed on its own: a condition that is only
/// ever removed together with another is not shown to be necessary.
///
/// The expected unavailable reason is a property of the *condition*, not of the code path:
/// a build with no compiled implementation reports that fact, and a build that compiled one
/// the signed manifest has not enabled for it reports the manifest. Collapsing the two
/// would let a provenance build claim it never compiled a validator.
private enum EnablingCondition: String, Hashable, Sendable, CaseIterable {
    /// The port conformance is compiled into this build's module graph.
    case implementationCompiled
    /// The signed manifest compiles the capability for this build.
    case capabilityEnabledByManifest
    /// A Provenance Policy resolved for this session.
    case policyResolved
    /// The manifest binds exactly this policy version.
    case manifestBindsThisPolicy
    /// The manifest records exactly this implementation version.
    case manifestRecordsThisVersion
    /// The policy carries an approved Provenance Feasibility decision.
    case feasibilityApproved

    /// The lane state a build missing only this condition must report.
    var unavailableReason: UnavailableReason {
        switch self {
        case .implementationCompiled: .validatorNotCompiledIntoRelease
        case .capabilityEnabledByManifest, .policyResolved, .manifestBindsThisPolicy,
            .manifestRecordsThisVersion, .feasibilityApproved:
            .capabilityNotEnabledByReleaseCapabilityManifest
        }
    }
}

// MARK: - Generated shape

/// Everything one generated case decides, as plain data.
///
/// The generator produces data only. Policies, manifests, gate matrices, assets, and
/// reports are built from it inside the property body, where a construction that
/// unexpectedly fails is recorded as an issue rather than thrown: `propertyCheck` discards
/// an error thrown by its body, so a refusal that escaped as a throw would report a
/// passing test with every arm skipped.
///
/// ## How the baseline varies
///
/// A property whose baseline is one composition with a flag flipped asserts one example a
/// hundred times over, so every dimension the arms depend on is generated:
///
///   * each of the six enabling conditions, drawn independently at a rate that reaches
///     both a complete composition and every single-condition failure, so the free
///     combination covers enabled and disabled builds and the partial failures between;
///   * the completed pixel result, over all three labels, because Requirements 6.4 and
///     6.20 are about *every* report;
///   * the enabled state the generated composition's validator returns, and the control's
///     own state, drawn separately over all five;
///   * the ingest route and preservation basis, so the inspection request and the report's
///     recorded byte status vary;
///   * the retained byte count and digest, so the control's exact-bytes assertion is not
///     comparing one constant to itself;
///   * which mandatory non-provenance gate carries the matrix defect, and whether that
///     defect is a failure or a missing result;
///   * the mismatching implementation version, so the version arm is not one literal;
///   * every synthetic identifier, from ``seed``.
///
/// ``CapabilitySelectionVariationWitness`` checks after the run that this happened.
private struct CapabilityShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic identifier, so a whole case's reference set varies together
    /// and stays coherent without a cross-reference table.
    let seed: Int

    let compilesImplementation: Bool
    let manifestEnablesCapability: Bool
    let policyResolved: Bool
    let manifestBindsThisPolicy: Bool
    let manifestRecordsThisVersion: Bool
    let feasibilityApproved: Bool

    let pixelIndex: Int
    let stateIndex: Int
    let controlStateIndex: Int

    /// Byte count the store measured while writing the retained object.
    let byteCount: UInt64
    let digestIndex: Int
    let route: InputRoute
    let basisIndex: Int

    /// Which mandatory non-provenance gate carries the generated matrix defect.
    let defectGateIndex: Int
    /// Whether that defect is a recorded failure or a result that never ran.
    let defectIsFailure: Bool

    /// Distinguishes the mismatching implementation version from the recorded one.
    let versionOffset: Int

    // MARK: Derived

    /// The completed pixel result this case's reports carry.
    var pixel: PixelEvidence {
        PixelEvidence.allCases[pixelIndex % PixelEvidence.allCases.count]
    }

    /// The enabled state the generated composition's validator returns.
    var state: ProvenanceCategory {
        ProvenanceCategory.allCases[stateIndex % ProvenanceCategory.allCases.count]
    }

    /// The enabled state the control's validator returns, drawn independently.
    var controlState: ProvenanceCategory {
        ProvenanceCategory.allCases[controlStateIndex % ProvenanceCategory.allCases.count]
    }

    var basis: PreservationBasis {
        PreservationBasis.allCases[basisIndex % PreservationBasis.allCases.count]
    }

    /// The mandatory gate the matrix arm breaks.
    ///
    /// Drawn from the unconditional gates only. The two conditional gates carry an
    /// explicit applicability decision instead, and breaking one of them would be asserting
    /// something about a capability gate rather than about Requirement 6.3's "every
    /// mandatory non-provenance release gate".
    var defectGate: ReleaseGate {
        let gates = Self.mandatoryNonProvenanceGates
        return gates[defectGateIndex % gates.count]
    }

    /// The outcome the defect writes into that gate's entry.
    var defectOutcome: GateOutcome { defectIsFailure ? .failed : .notExecuted }

    /// Every unconditional release gate, in a stable order.
    static let mandatoryNonProvenanceGates: [ReleaseGate] =
        ReleaseGate.allCases.filter { !$0.isConditional }.sorted { $0.rawValue < $1.rawValue }

    /// Whether this condition holds in the freely generated composition.
    func satisfies(_ condition: EnablingCondition) -> Bool {
        switch condition {
        case .implementationCompiled: compilesImplementation
        case .capabilityEnabledByManifest: manifestEnablesCapability
        case .policyResolved: policyResolved
        case .manifestBindsThisPolicy: manifestBindsThisPolicy
        case .manifestRecordsThisVersion: manifestRecordsThisVersion
        case .feasibilityApproved: feasibilityApproved
        }
    }

    /// The requirement's own answer for the generated composition.
    ///
    /// Read off Requirement 6.2 and the design's "complete feasibility gate passes and its
    /// exact implementation is compiled into the build" rather than off the seam under
    /// test, so the arm compares the code against the statement instead of against itself.
    var requiresEnabledProvenance: Bool {
        EnablingCondition.allCases.allSatisfy(satisfies)
    }

    /// The unavailable state the generated composition must report, or `nil` when the
    /// requirement enables provenance for it.
    ///
    /// A build with no compiled implementation reports that regardless of what its manifest
    /// says: a signed artifact cannot enable a capability whose implementation is absent
    /// from the binary.
    var requiredUnavailableReason: UnavailableReason? {
        guard !requiresEnabledProvenance else { return nil }
        return compilesImplementation
            ? .capabilityNotEnabledByReleaseCapabilityManifest
            : .validatorNotCompiledIntoRelease
    }

    var description: String {
        """
        seed \(seed), compiled \(compilesImplementation), \
        manifestEnables \(manifestEnablesCapability), policy \(policyResolved), \
        bindsPolicy \(manifestBindsThisPolicy), bindsVersion \(manifestRecordsThisVersion), \
        feasibility \(feasibilityApproved), enabled \(requiresEnabledProvenance), \
        pixel \(pixel.rawValue), state \(state.rawValue), \
        control \(controlState.rawValue), route \(route.rawValue), \
        basis \(basis.rawValue), bytes \(byteCount), \
        defect \(defectGate.rawValue)/\(defectOutcome.rawValue)
        """
    }

    // MARK: Generators

    static var generator: Generator<CapabilityShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            conditions,
            Gen.int(in: 0...199),
            Gen.int(in: 0...199),
            Gen.int(in: 0...199),
            retainedBytes,
            Gen.bool,
            Gen.int(in: 0...199),
            Gen.bool,
            Gen.int(in: 0...199)
        )
        .map { raw in
            CapabilityShape(
                seed: raw.0,
                compilesImplementation: raw.1.0,
                manifestEnablesCapability: raw.1.1,
                policyResolved: raw.1.2,
                manifestBindsThisPolicy: raw.1.3,
                manifestRecordsThisVersion: raw.1.4,
                feasibilityApproved: raw.1.5,
                pixelIndex: raw.2,
                stateIndex: raw.3,
                controlStateIndex: raw.4,
                byteCount: raw.5.0,
                digestIndex: raw.5.1,
                route: raw.6 ? .photosPicker : .shareExtension,
                basisIndex: raw.7,
                defectGateIndex: raw.9,
                defectIsFailure: raw.8,
                versionOffset: raw.5.2
            )
        }
        .eraseToAny()
    }

    /// The six enabling conditions, each drawn independently.
    ///
    /// The rate is deliberate. At an even coin the all-true combination arrives with
    /// probability `1/64`, so about one run in five would generate no enabled composition
    /// at all and the witness assertion that both answers occurred would fail as noise
    /// rather than as a defect. At this rate a complete composition arrives about a quarter
    /// of the time and each individual condition is still absent in roughly one case in
    /// five, so both directions of the biconditional and every single-condition failure are
    /// reached with margin.
    ///
    /// Weighted, not narrowed: all 64 combinations remain reachable, and the shrinker still
    /// reduces `true` toward `false`, so a failure shrinks to the smallest set of conditions
    /// that reproduces it.
    private static var conditions: Generator<
        (Bool, Bool, Bool, Bool, Bool, Bool), AnySequence<Any>
    > {
        zip(
            Gen.bool(Self.conditionRate),
            Gen.bool(Self.conditionRate),
            Gen.bool(Self.conditionRate),
            Gen.bool(Self.conditionRate),
            Gen.bool(Self.conditionRate),
            Gen.bool(Self.conditionRate)
        )
        .eraseToAny()
    }

    /// Rate at which one enabling condition is generated as satisfied.
    ///
    /// A property-test sampling choice, not a release value: nothing reads it, and no
    /// assertion depends on its exact magnitude.
    private static let conditionRate: Float = 0.8

    /// The retained object's measured byte count, a digest selector, and a version offset.
    ///
    /// Bounded well below any generated processing limit: this property is about which
    /// composition may inspect bytes at all, and a size that reached a policy limit would
    /// make the outcome depend on a resource decision instead.
    private static var retainedBytes: Generator<(UInt64, Int, Int), AnySequence<Any>> {
        zip(Gen.uint64(in: 1...1_048_576), Gen.int(in: 0...199), Gen.int(in: 0...199))
            .eraseToAny()
    }
}

// MARK: - Scenario

/// One generated case: the artifacts built from its shape, and the arms it runs.
///
/// Construction is failable rather than throwing so the property body can record an issue
/// and return. Nothing in here decides a policy: every artifact is synthetic, and the arms
/// assert what the *selection* does with it.
private struct CapabilitySelectionScenario {
    let shape: CapabilityShape
    private let artifacts: CapabilitySelectionArtifacts

    init?(shape: CapabilityShape) {
        guard let artifacts = CapabilitySelectionArtifacts(shape: shape) else {
            Issue.record("building the generated artifacts failed [\(shape)]")
            return nil
        }
        self.shape = shape
        self.artifacts = artifacts
    }

    // MARK: The control: spy liveness and the occurrence half

    /// A complete passing exact composition enables provenance and reaches the validator.
    ///
    /// This is the non-vacuity half of every nonoccurrence assertion below. A recorder that
    /// is not wired to anything reports zero calls, so a composition that must reach the
    /// analyzer — built from the same generated values, through the same seam, on every
    /// generated case — is what distinguishes "the validator was not invoked" from "the
    /// validator could not have been invoked".
    ///
    /// Requirement 6.2's positive direction, and the reason the exactness arms are not
    /// satisfied by a seam that refuses everything.
    func checkEnabledControlReachesTheValidator() async {
        let analyzer = RecordingProvenanceAnalyzer(
            returning: artifacts.evidence(for: shape.controlState)
        )
        let provider = ProvenanceLaneProvider.resolve(
            analyzer: analyzer,
            policy: artifacts.policy,
            manifest: artifacts.completeManifest
        )

        #expect(provider.isEnabled, "a complete exact composition enables provenance [\(shape)]")
        #expect(provider.unavailableReason == nil, "[\(shape)]")
        #expect(provider.boundPolicyID == artifacts.policy.id, "[\(shape)]")
        #expect(provider.canProduceCombinedSummary, "[\(shape)]")

        // The inspection is described, and it describes the bytes ingest actually retained
        // (Requirement 6.6). Without this the control could "reach" a validator that was
        // handed something else.
        let request = provider.inspectionRequest(for: artifacts.asset)
        #expect(request?.policyID == artifacts.policy.id, "[\(shape)]")
        #expect(request?.sessionID == artifacts.asset.sessionID, "[\(shape)]")
        #expect(request?.storageKey == artifacts.asset.handle.storageKey, "[\(shape)]")
        #expect(
            request?.inspectsExactly(
                byteCount: artifacts.asset.byteCount,
                sha256: artifacts.asset.sha256
            ) == true,
            "the control must inspect the exact retained bytes [\(shape)]"
        )
        #expect(request?.preservationStatus == shape.basis.mostConservativeStatus, "[\(shape)]")

        let lane = await provider.lane(for: artifacts.asset)
        #expect(analyzer.callCount == 1, "the control must reach the validator once [\(shape)]")
        #expect(analyzer.inspectedSessions == [artifacts.asset.sessionID], "[\(shape)]")

        // The provider passes the validator's state through unchanged. Which state a given
        // validator output maps to is Property 20's subject; that it is not rewritten here
        // is this file's.
        #expect(lane == .available(artifacts.evidence(for: shape.controlState)), "[\(shape)]")
        #expect(lane.isAvailable, "[\(shape)]")
        #expect(lane.category == shape.controlState, "[\(shape)]")
        #expect(lane.fusionInput != nil, "an available lane has a fusion key [\(shape)]")
        #expect(lane.stateKey == shape.controlState.stateKey, "[\(shape)]")

        // And a report is representable for the generated completed pixel result, with the
        // available lane and the bound policy recorded.
        let report = artifacts.report(pixel: shape.pixel, provenance: lane, combinedSummary: nil)
        #expect(report?.provenance == lane, "[\(shape)]")
        #expect(report?.pixel == shape.pixel, "[\(shape)]")
        #expect(report?.binding.provenancePolicyID == artifacts.policy.id, "[\(shape)]")
    }

    // MARK: The freely generated composition

    /// The generated composition is enabled exactly when the requirement says so.
    ///
    /// Requirement 6.2 for the enabling direction, and Requirements 6.4, 6.19, 6.20, and
    /// 7.10 for every other composition. The expectation comes from
    /// ``CapabilityShape/requiresEnabledProvenance``, which is the requirement restated over
    /// the generated conditions rather than a second copy of the seam's logic.
    func checkGeneratedCompositionMatchesTheRequirement() async {
        let analyzer: RecordingProvenanceAnalyzer? = shape.compilesImplementation
            ? RecordingProvenanceAnalyzer(returning: artifacts.evidence(for: shape.state))
            : nil
        let provider = ProvenanceLaneProvider.resolve(
            analyzer: analyzer,
            policy: artifacts.generatedPolicy,
            manifest: artifacts.generatedManifest
        )

        #expect(
            provider.isEnabled == shape.requiresEnabledProvenance,
            "selection disagreed with the requirement [\(shape)]"
        )

        guard let requiredReason = shape.requiredUnavailableReason else {
            // The generated combination happens to be a complete exact composition. The
            // dedicated control already asserts that path unconditionally; asserting the
            // reason here would be asserting `nil`.
            #expect(provider.unavailableReason == nil, "[\(shape)]")
            #expect(provider.boundPolicyID == artifacts.policy.id, "[\(shape)]")
            return
        }

        await checkPixelOnlyComposition(
            "the generated composition",
            provider: provider,
            analyzer: analyzer,
            expecting: requiredReason
        )
    }

    // MARK: Exactness, one condition at a time

    /// Removing any single enabling condition from a complete composition disables it.
    ///
    /// The generated combination above quantifies over the whole space, but a space visited
    /// at random can leave a condition that never mattered looking necessary. These six arms
    /// start from a composition that *does* enable provenance and remove exactly one
    /// condition, which is what makes each one individually necessary — and each removal
    /// keeps the analyzer present wherever the condition is not about compilation, so the
    /// nonoccurrence claim is about a validator that exists and was not called.
    func checkEachMissingConditionDisablesProvenance() async {
        for condition in EnablingCondition.allCases {
            // Present for every condition except the one about compilation, so five of the
            // six arms are the strictly harder configuration: a linked, instantiable
            // validator that the selection must still refuse to invoke.
            let analyzer: RecordingProvenanceAnalyzer? = condition == .implementationCompiled
                ? nil
                : RecordingProvenanceAnalyzer(returning: artifacts.evidence(for: shape.state))

            let provider = ProvenanceLaneProvider.resolve(
                analyzer: analyzer,
                policy: condition == .policyResolved ? nil : artifacts.policy(missing: condition),
                manifest: artifacts.manifest(missing: condition)
            )

            await checkPixelOnlyComposition(
                "a composition missing \(condition.rawValue)",
                provider: provider,
                analyzer: analyzer,
                expecting: condition.unavailableReason
            )
        }
    }

    // MARK: The pixel-only consequences

    /// The four coupled statements of a pixel-only composition, asserted together.
    ///
    /// Requirements 6.4, 6.19, 6.20, and 7.10 are one configuration seen from four sides,
    /// so they are checked in one place: separating them would let a change satisfy the
    /// lane state while quietly invoking the validator, or leave a Combined Summary beside
    /// an unavailable lane.
    private func checkPixelOnlyComposition(
        _ label: String,
        provider: ProvenanceLaneProvider,
        analyzer: RecordingProvenanceAnalyzer?,
        expecting reason: UnavailableReason
    ) async {
        // Requirement 6.2, negative direction: the capability is not enabled.
        #expect(provider.isEnabled == false, "\(label) must not enable provenance [\(shape)]")
        #expect(provider.unavailableReason == reason, "\(label) [\(shape)]")
        #expect(provider.boundPolicyID == nil, "\(label) records no policy [\(shape)]")

        // Requirement 7.10 at the composition level: no summary is reachable at all.
        #expect(
            provider.canProduceCombinedSummary == false,
            "\(label) must not reach a Combined Summary [\(shape)]"
        )

        // Requirement 6.19: no inspection is even described, so there is nothing for a
        // validator to be pointed at.
        #expect(
            provider.inspectionRequest(for: artifacts.asset) == nil,
            "\(label) describes no inspection [\(shape)]"
        )

        // Requirement 6.20: the lane is the unavailable state and nothing else.
        let lane = await provider.lane(for: artifacts.asset)
        #expect(lane == .unavailable(reason), "\(label) [\(shape)]")
        #expect(lane.isAvailable == false, "\(label) [\(shape)]")
        #expect(lane.evidence == nil, "\(label) reports no enabled state [\(shape)]")
        #expect(lane.category == nil, "\(label) [\(shape)]")

        // Requirement 6.19: the analyzer stayed inactive. The control proves this recorder
        // would have seen a call.
        #expect(
            (analyzer?.callCount ?? 0) == 0,
            "\(label) invoked the validator [\(shape)]"
        )
        #expect(analyzer?.inspectedSessions.isEmpty ?? true, "\(label) [\(shape)]")

        checkEveryPixelOnlyReportOmitsTheCombinedSummary(label, lane: lane)
    }

    /// Requirements 6.4 and 7.10: every report of the generated completed pixel result uses
    /// only the unavailable lane, and omits the Combined Summary entirely.
    ///
    /// Omission is asserted in both available forms: the report that exists has no summary,
    /// and the report *with* one is not a value the domain will build. The second is the
    /// stronger statement — a presenter cannot show a summary that cannot be represented —
    /// and it is why the first is not merely a description of this call site.
    private func checkEveryPixelOnlyReportOmitsTheCombinedSummary(
        _ label: String,
        lane: ProvenanceLane
    ) {
        guard let report = artifacts.report(
            pixel: shape.pixel,
            provenance: lane,
            combinedSummary: nil
        ) else {
            Issue.record("\(label) must still produce an Evidence Report [\(shape)]")
            return
        }

        #expect(report.provenance == lane, "\(label) [\(shape)]")
        #expect(report.provenance.isAvailable == false, "\(label) [\(shape)]")
        #expect(report.pixel == shape.pixel, "the pixel lane is unchanged [\(shape)]")
        #expect(report.combinedSummary == nil, "\(label) shows no summary [\(shape)]")
        #expect(report.apparentInconsistency == nil, "\(label) [\(shape)]")
        #expect(
            report.binding.provenancePolicyID == nil,
            "\(label) binds no Provenance Policy [\(shape)]"
        )
        #expect(
            report.binding.fusionRuleID == nil,
            "\(label) binds no Evidence Fusion Rule [\(shape)]"
        )
        #expect(report.bytePreservationStatus == shape.basis.mostConservativeStatus, "[\(shape)]")

        // A summary beside an unavailable lane is unrepresentable, so there is no report to
        // omit it from.
        #expect(
            artifacts.report(
                pixel: shape.pixel,
                provenance: lane,
                combinedSummary: artifacts.combinedSummary
            ) == nil,
            "\(label) must not admit a Combined Summary [\(shape)]"
        )

        // Nor can an unavailable lane be inconsistent with the pixel lane: there is no
        // second finding to disagree with.
        #expect(
            artifacts.report(
                pixel: shape.pixel,
                provenance: lane,
                combinedSummary: nil,
                apparentInconsistency: artifacts.inconsistencyKey
            ) == nil,
            "\(label) must not admit an inconsistency notice [\(shape)]"
        )

        // The structural fusion bypass: an unavailable lane has no table key, so there is no
        // entry for a presenter to look up. A release that binds no rule at all is the value
        // a pixel-only composition root actually holds.
        #expect(lane.fusionInput == nil, "\(label) [\(shape)]")
        #expect(lane.stateKey == nil, "\(label) [\(shape)]")
        #expect(
            OptionalFusion.omitted(.noRuleBound)
                .summary(pixel: shape.pixel, provenance: lane) == nil,
            "\(label) [\(shape)]"
        )
    }

    // MARK: The release gate matrix

    /// Requirement 6.3: a failed provenance feasibility gate does not block a release whose
    /// mandatory non-provenance gates all pass — and the qualifier is load-bearing.
    ///
    /// Stated on the record's own predicates rather than through release eligibility.
    /// Whether a record is auditable is Property 33's subject; what is asserted here is the
    /// permission Requirement 6.3 grants and the condition attached to it.
    func checkGateMatrixPermitsAnOtherwiseCompletePixelOnlyRelease() {
        guard let permitted = artifacts.pixelOnlyGateMatrix(defect: nil) else {
            Issue.record("building the pixel-only gate matrix failed [\(shape)]")
            return
        }

        // The provenance gate did not pass; it was declared inapplicable by an approved
        // decision, which is the only representable way for it not to pass without blocking.
        #expect(
            permitted.record(for: .provenanceFeasibility).applicability.isApplicable == false,
            "[\(shape)]"
        )
        #expect(permitted.enablesProvenance == false, "[\(shape)]")
        #expect(permitted.enablesFusion == false, "[\(shape)]")

        // Nothing blocks: the pixel-only release is permitted.
        #expect(
            permitted.unresolvedMandatoryGates.isEmpty,
            "unresolved: \(permitted.unresolvedMandatoryGates.map(\.rawValue).sorted()) [\(shape)]"
        )
        #expect(
            permitted.failingMandatoryGates.isEmpty,
            "failing: \(permitted.failingMandatoryGates.map(\.rawValue).sorted()) [\(shape)]"
        )

        // The qualifier bites: one broken mandatory non-provenance gate blocks the same
        // matrix, and the record names that gate rather than reporting "a gate failed".
        guard let blocked = artifacts.pixelOnlyGateMatrix(
            defect: (shape.defectGate, shape.defectOutcome)
        ) else {
            Issue.record("building the defective gate matrix failed [\(shape)]")
            return
        }

        let blockingGates = blocked.failingMandatoryGates
            .union(blocked.unresolvedMandatoryGates)
        #expect(
            blockingGates == [shape.defectGate],
            """
            a \(shape.defectOutcome.rawValue) \(shape.defectGate.rawValue) must block alone; \
            blocked: \(blockingGates.map(\.rawValue).sorted()) [\(shape)]
            """
        )
        if shape.defectIsFailure {
            #expect(blocked.failingMandatoryGates == [shape.defectGate], "[\(shape)]")
            #expect(blocked.unresolvedMandatoryGates.isEmpty, "[\(shape)]")
        } else {
            #expect(blocked.unresolvedMandatoryGates == [shape.defectGate], "[\(shape)]")
            #expect(blocked.failingMandatoryGates.isEmpty, "[\(shape)]")
        }
    }

    /// Requirement 7.10 at the release layer: a Combined Summary cannot outlive the
    /// provenance lane it would summarize.
    ///
    /// Three refusals, at the three layers that could otherwise disagree. Each is a schema
    /// refusal rather than a runtime check, so a pixel-only release carrying fusion evidence
    /// is unrepresentable instead of merely unexpected.
    func checkCombinedSummaryCannotOutliveTheProvenanceLane() {
        // A gate matrix cannot declare the fusion gate applicable while provenance
        // feasibility is not.
        #expect(
            artifacts.gateMatrix(
                provenanceApplicable: false,
                fusionApplicable: true,
                defect: nil
            ) == nil,
            "a pixel-only matrix must not carry an applicable fusion gate [\(shape)]"
        )

        // A signed manifest cannot compile fusion without the provenance lane.
        #expect(
            artifacts.candidateManifest(
                enablesCapability: false,
                boundPolicy: nil,
                recordedVersion: artifacts.policy.validatorImplementationVersion,
                fusionRule: artifacts.fusionRuleID
            ) == nil,
            "a pixel-only manifest must not compile fusion [\(shape)]"
        )

        // And a pixel-only manifest cannot bind a Provenance Policy, so "no validator" and
        // "a live provenance policy" cannot be recorded together.
        #expect(
            artifacts.candidateManifest(
                enablesCapability: false,
                boundPolicy: artifacts.policy.id,
                recordedVersion: artifacts.policy.validatorImplementationVersion,
                fusionRule: nil
            ) == nil,
            "a pixel-only manifest must not bind a Provenance Policy [\(shape)]"
        )

        // The positive control for all three: the complete composition's own manifest is
        // representable, so these arms are refusals rather than a builder that always fails.
        #expect(
            artifacts.candidateManifest(
                enablesCapability: true,
                boundPolicy: artifacts.policy.id,
                recordedVersion: artifacts.policy.validatorImplementationVersion,
                fusionRule: nil
            ) != nil,
            "[\(shape)]"
        )
    }
}

// MARK: - Synthetic artifacts

/// Every artifact one generated case needs in order for the selection seam to be callable.
///
/// **No value here is an approved release input.** The trust store, revocation answer,
/// status mappings, displayable fields, processing limits, feasibility decision, waiver
/// decisions, gate outcomes, governance disclosures, and identifiers are synthetic. They
/// exist so a seam that takes a signed artifact can be invoked, and no assertion in this
/// file claims any of them is correct.
///
/// Built per generated case, so two compositions never share a policy, manifest, matrix, or
/// asset, and so the identifiers a failure reports name the case that produced it.
private struct CapabilitySelectionArtifacts {
    let shape: CapabilityShape

    /// The Provenance Policy the complete composition binds.
    let policy: ProvenancePolicy

    /// The same policy version with a rejected Provenance Feasibility decision.
    private let unapprovedPolicy: ProvenancePolicy

    /// A second policy version, for the binding-mismatch arm.
    private let otherPolicy: ProvenancePolicy

    /// The manifest of a complete, exact, provenance-enabled composition.
    let completeManifest: ReleaseCapabilityManifest

    /// The manifest the freely generated composition ships.
    let generatedManifest: ReleaseCapabilityManifest

    /// One accepted ingest, whose retained bytes an enabled validator would inspect.
    let asset: ImportedEncodedAsset

    /// A summary and a notice a pixel-only report must refuse to hold.
    let combinedSummary: CombinedSummary
    let inconsistencyKey: ApprovedCopyKey
    let fusionRuleID: ArtifactID

    private let sessionID: AnalysisSessionID
    private let mismatchedVersion: SchemaSemanticVersion

    init?(shape: CapabilityShape) {
        self.shape = shape
        let seed = shape.seed

        guard let sessionID = AnalysisSessionID("session.p19.\(seed)"),
              let storageKey = EphemeralStorageKey("object.p19.\(seed)"),
              let inconsistencyKey = ApprovedCopyKey("copy.p19.inconsistency.\(seed)"),
              let summaryKey = ApprovedCopyKey("copy.p19.combined.\(seed)"),
              let fusionRuleID = ArtifactID("fusion.p19.\(seed)")
        else {
            return nil
        }

        let digestCharacter = Self.digestAlphabet[
            shape.digestIndex % Self.digestAlphabet.count
        ]
        guard let handle = EncodedAssetHandle(
            sessionID: sessionID,
            storageKey: storageKey,
            byteCount: shape.byteCount,
            sha256: Sample.digest(digestCharacter),
            protection: .complete
        ) else {
            return nil
        }
        guard let asset = ImportedEncodedAsset(
            route: shape.route,
            handle: handle,
            preservationStatus: shape.basis.mostConservativeStatus,
            preservationBasis: shape.basis,
            contentTypeHint: ContentTypeHint("public.jpeg")
        ) else {
            return nil
        }

        // The recorded implementation version and one that is not it. The mismatch's major
        // component is always at least two, so it can never coincide with the recorded
        // version however the generated components fall.
        let recordedVersion = "1.\(seed % 500).0"
        let mismatched = "\(2 + shape.versionOffset % 5).\(seed % 500).0"
        guard let mismatchedVersion = try? SchemaSemanticVersion(validating: mismatched) else {
            return nil
        }

        let policy = PolicySample.policy(
            id: "provenance.p19.\(seed)",
            implementationVersion: recordedVersion
        )
        let unapprovedPolicy = PolicySample.policy(
            id: "provenance.p19.\(seed)",
            implementationVersion: recordedVersion,
            feasibility: .rejected
        )
        let otherPolicy = PolicySample.policy(
            id: "provenance.p19.\(seed).other",
            implementationVersion: recordedVersion
        )

        guard let completeManifest = Self.manifest(
            seed: seed,
            enablesCapability: true,
            boundPolicy: policy.id,
            recordedVersion: policy.validatorImplementationVersion,
            fusionRule: nil
        ) else {
            return nil
        }

        // The generated composition's manifest. Which policy it binds and which version it
        // records are generated, and a manifest that does not enable the capability cannot
        // bind either — the schema couples them, which is why the two mismatch conditions
        // only distinguish anything inside an enabling manifest.
        guard let generatedManifest = Self.manifest(
            seed: seed,
            enablesCapability: shape.manifestEnablesCapability,
            boundPolicy: shape.manifestEnablesCapability
                ? (shape.manifestBindsThisPolicy ? policy.id : otherPolicy.id)
                : nil,
            recordedVersion: shape.manifestRecordsThisVersion
                ? policy.validatorImplementationVersion
                : mismatchedVersion,
            fusionRule: nil
        ) else {
            return nil
        }

        self.sessionID = sessionID
        self.policy = policy
        self.unapprovedPolicy = unapprovedPolicy
        self.otherPolicy = otherPolicy
        self.completeManifest = completeManifest
        self.generatedManifest = generatedManifest
        self.asset = asset
        self.combinedSummary = CombinedSummary(copyKey: summaryKey, fusionRuleID: fusionRuleID)
        self.inconsistencyKey = inconsistencyKey
        self.fusionRuleID = fusionRuleID
        self.mismatchedVersion = mismatchedVersion
    }

    /// Hexadecimal characters a synthetic 64-character digest can be filled with.
    private static let digestAlphabet: [Character] = Array("0123456789abcdef")

    // MARK: The freely generated composition

    /// The policy the freely generated composition resolves, or `nil` when none resolved.
    ///
    /// `nil` and a rejected feasibility decision are different conditions and are generated
    /// separately: the first is a session with no policy at all, the second is a policy
    /// whose Provenance Feasibility Gate did not pass. Collapsing them would leave one of
    /// the two never exercised.
    var generatedPolicy: ProvenancePolicy? {
        guard shape.policyResolved else { return nil }
        return shape.feasibilityApproved ? policy : unapprovedPolicy
    }

    // MARK: One condition removed

    /// The policy a composition missing `condition` binds.
    ///
    /// Only the feasibility arm changes it. The `policyResolved` arm passes no policy at
    /// all, which the caller handles, because "no policy resolved" is the absence of the
    /// value rather than a different one.
    func policy(missing condition: EnablingCondition) -> ProvenancePolicy {
        condition == .feasibilityApproved ? unapprovedPolicy : policy
    }

    /// The manifest a composition missing `condition` ships.
    ///
    /// Every arm other than the three manifest arms ships the complete manifest, so the
    /// removed condition is the only difference from a composition that would be enabled.
    func manifest(missing condition: EnablingCondition) -> ReleaseCapabilityManifest {
        switch condition {
        case .capabilityEnabledByManifest:
            return Self.manifest(
                seed: shape.seed,
                enablesCapability: false,
                boundPolicy: nil,
                recordedVersion: policy.validatorImplementationVersion,
                fusionRule: nil
            ) ?? completeManifest
        case .manifestBindsThisPolicy:
            return Self.manifest(
                seed: shape.seed,
                enablesCapability: true,
                boundPolicy: otherPolicy.id,
                recordedVersion: policy.validatorImplementationVersion,
                fusionRule: nil
            ) ?? completeManifest
        case .manifestRecordsThisVersion:
            return Self.manifest(
                seed: shape.seed,
                enablesCapability: true,
                boundPolicy: policy.id,
                recordedVersion: mismatchedVersion,
                fusionRule: nil
            ) ?? completeManifest
        case .implementationCompiled, .policyResolved, .feasibilityApproved:
            return completeManifest
        }
    }

    // MARK: Manifests

    /// A candidate manifest, or `nil` when the schema refuses that combination.
    ///
    /// Exposed so the coupling arms can ask for a combination the schema must refuse. The
    /// refusal is the assertion; nothing here interprets which field disagreed.
    func candidateManifest(
        enablesCapability: Bool,
        boundPolicy: ArtifactID?,
        recordedVersion: SchemaSemanticVersion,
        fusionRule: ArtifactID?
    ) -> ReleaseCapabilityManifest? {
        Self.manifest(
            seed: shape.seed,
            enablesCapability: enablesCapability,
            boundPolicy: boundPolicy,
            recordedVersion: recordedVersion,
            fusionRule: fusionRule
        )
    }

    /// Builds one signed capability manifest, or `nil` when the schema refuses it.
    ///
    /// Failable rather than throwing: every caller is inside a property body, where an
    /// escaping error would be discarded and the arm would pass vacuously.
    private static func manifest(
        seed: Int,
        enablesCapability: Bool,
        boundPolicy: ArtifactID?,
        recordedVersion: SchemaSemanticVersion,
        fusionRule: ArtifactID?
    ) -> ReleaseCapabilityManifest? {
        var capabilities: Set<CapabilityID> = [.pixelAnalysis]
        var versions = [
            CapabilityImplementationEntry(
                capability: .pixelAnalysis,
                version: Sample.version("1.0.0")
            )
        ]
        if enablesCapability {
            capabilities.insert(.contentCredentialValidation)
            versions.append(
                CapabilityImplementationEntry(
                    capability: .contentCredentialValidation,
                    version: recordedVersion
                )
            )
        }
        if fusionRule != nil {
            capabilities.insert(.evidenceFusion)
            versions.append(
                CapabilityImplementationEntry(
                    capability: .evidenceFusion,
                    version: Sample.version("1.0.0")
                )
            )
        }
        guard let build = AppBuildID("build.p19.\(seed)"),
              let bundleID = ModelBundleID("bundle.p19.\(seed)")
        else {
            return nil
        }
        return try? ReleaseCapabilityManifest(
            id: Sample.artifact("capability-manifest.p19.\(seed)"),
            schemaVersion: .v1,
            appBuild: build,
            compositionIdentifier: Sample.text("Synthetic composition \(seed)"),
            compiledCapabilities: capabilities,
            implementationVersions: versions,
            approvedConfigurationAllowlist: Sample.artifact("allowlist.p19.\(seed)"),
            approvedBundleCatalog: [bundleID],
            policyCompatibility: try PolicyCompatibilitySet(
                preprocessingContract: Sample.artifact("preprocessing.p19.\(seed)"),
                calibrationPolicy: Sample.artifact("calibration.p19.\(seed)"),
                lifecyclePolicy: Sample.artifact("lifecycle.p19.\(seed)"),
                extensionExecutionPolicy: Sample.artifact("extension-policy.p19.\(seed)"),
                mainApplicationResourceBudget: Sample.artifact("budget.main.p19.\(seed)"),
                shareExtensionResourceBudget: Sample.artifact("budget.extension.p19.\(seed)"),
                bundleVerificationPolicy: Sample.artifact("bundle-policy.p19.\(seed)"),
                verdictCopyCompatibility: Sample.artifact("copy-compatibility.p19.\(seed)"),
                provenancePolicy: boundPolicy.map { .bound($0) }
                    ?? .notApplicable(decision: Sample.approval()),
                fusionRule: fusionRule.map { .bound($0) }
                    ?? .notApplicable(decision: Sample.approval())
            ),
            approval: Sample.approval()
        )
    }

    // MARK: Enabled states

    /// One bounded enabled provenance state per category.
    ///
    /// Payloads are the minimum each state's schema requires, so nothing here resembles a
    /// trust, signer, or assertion decision. Which validator output maps to which state is
    /// Property 20's subject; these values exist so the available lane can carry all five.
    func evidence(for category: ProvenanceCategory) -> ProvenanceEvidence {
        let explanation = Sample.copyKey("copy.p19.state.\(category.rawValue).\(shape.seed)")
        switch category {
        case .validated:
            return .validated(
                ValidatedClaimSummary(
                    provenancePolicyID: policy.id,
                    bindingStatus: .boundToInspectedBytes,
                    signerFields: [
                        DisplaySafeField(
                            labelKey: Sample.copyKey("copy.p19.field.signer.\(shape.seed)"),
                            value: Sample.display("synthetic signer \(shape.seed)")
                        )
                    ],
                    assertionFields: []
                )
            )
        case .invalid:
            return .invalid(
                InvaliditySummary(
                    provenancePolicyID: policy.id,
                    category: .cryptographic,
                    explanationKey: explanation
                )
            )
        case .absent:
            return .absent
        case .unsupported:
            return .unsupported(
                UnsupportedFeatureSummary(
                    provenancePolicyID: policy.id,
                    explanationKey: explanation,
                    unsupportedFeatures: [Sample.display("synthetic feature \(shape.seed)")]
                )
            )
        case .indeterminate:
            return .indeterminate(
                IndeterminateSummary(
                    provenancePolicyID: policy.id,
                    explanationKey: explanation
                )
            )
        }
    }

    // MARK: Reports

    /// One Evidence Report for a completed session, or `nil` when the lane combination is
    /// not representable.
    ///
    /// The binding records the Provenance Policy only for an available lane and never
    /// records an Evidence Fusion Rule, which is what a pixel-only session actually binds.
    func report(
        pixel: PixelEvidence,
        provenance: ProvenanceLane,
        combinedSummary: CombinedSummary?,
        apparentInconsistency: ApprovedCopyKey? = nil
    ) -> EvidenceReport? {
        guard let quality = InputQualityRecord(
            decodedWidthBeforeOrientation: 640,
            decodedHeightBeforeOrientation: 480
        ) else {
            return nil
        }
        guard let binding = sessionBinding(
            provenancePolicyID: provenance.isAvailable ? policy.id : nil
        ) else {
            return nil
        }
        return EvidenceReport(
            binding: binding,
            pixel: pixel,
            provenance: provenance,
            combinedSummary: combinedSummary,
            apparentInconsistency: apparentInconsistency,
            bytePreservationStatus: asset.preservationStatus,
            inputQuality: quality,
            onDeviceProcessing: true,
            scope: .version1(id: Sample.artifact("scope.p19.\(shape.seed)"))
        )
    }

    /// The immutable snapshot one generated session is bound to.
    private func sessionBinding(provenancePolicyID: ArtifactID?) -> AnalysisSessionBinding? {
        let seed = shape.seed
        guard let build = AppBuildID("build.p19.\(seed)"),
              let configuration = ApprovedConfigurationID("configuration.p19.\(seed)"),
              let bundleID = ModelBundleID("bundle.p19.\(seed)"),
              let path = CanonicalRelativePath("model.mlmodelc")
        else {
            return nil
        }
        guard let integrity = VerifiedBundleIntegrity(
            status: .verified,
            activationReceiptID: Sample.artifact("receipt.p19.\(seed)"),
            verificationPolicyID: Sample.artifact("bundle-policy.p19.\(seed)"),
            verifiedManifestDigest: Sample.digest("e"),
            verifiedArtifactDigests: [
                ArtifactDigestRecord(
                    path: path,
                    kind: .directoryTree,
                    byteCount: 1_024,
                    digest: Sample.digest("f")
                )
            ]
        ) else {
            return nil
        }
        return AnalysisSessionBinding(
            sessionID: sessionID,
            appBuildID: build,
            deviceConfigurationID: configuration,
            modelBundleID: bundleID,
            modelIdentity: RequiredPixelModel.identity,
            coreMLModelVersion: Sample.artifact("coreml.p19.\(seed)"),
            modelBundleIntegrity: integrity,
            preprocessingContractID: Sample.artifact("preprocessing.p19.\(seed)"),
            calibrationPolicyID: Sample.artifact("calibration.p19.\(seed)"),
            verdictCopyCompatibilityID: Sample.artifact("copy-compatibility.p19.\(seed)"),
            capabilityManifestID: Sample.artifact("capability-manifest.p19.\(seed)"),
            provenancePolicyID: provenancePolicyID,
            // No approved Evidence Fusion Rule is bound in any composition this file builds.
            fusionRuleID: nil,
            lifecyclePolicyID: Sample.artifact("lifecycle.p19.\(seed)"),
            resourceBudgetID: Sample.artifact("budget.main.p19.\(seed)")
        )
    }

    // MARK: Release gate matrices

    /// A pixel-only gate matrix: the provenance gate waived by an approved decision, every
    /// mandatory non-provenance gate passing unless `defect` breaks one.
    func pixelOnlyGateMatrix(
        defect: (gate: ReleaseGate, outcome: GateOutcome)?
    ) -> ReleaseReadinessRecord? {
        gateMatrix(provenanceApplicable: false, fusionApplicable: false, defect: defect)
    }

    /// One release-readiness gate matrix, or `nil` when the schema refuses it.
    ///
    /// Failable rather than throwing, for the same reason as the manifest builder: a
    /// refusal that escaped as a throw from a property body would be discarded.
    func gateMatrix(
        provenanceApplicable: Bool,
        fusionApplicable: Bool,
        defect: (gate: ReleaseGate, outcome: GateOutcome)?
    ) -> ReleaseReadinessRecord? {
        let seed = shape.seed
        guard let build = AppBuildID("build.p19.\(seed)"),
              let bundleID = ModelBundleID("bundle.p19.\(seed)")
        else {
            return nil
        }

        var entries: [ReleaseGateRecord] = []
        for gate in ReleaseGate.allCases {
            let applicable: Bool
            switch gate {
            case .provenanceFeasibility: applicable = provenanceApplicable
            case .fusionRuleApproval: applicable = fusionApplicable
            default: applicable = true
            }
            // A waived gate carries an approved inapplicability decision and no executed
            // result. That is the only representable way for a conditional gate not to pass
            // without blocking, which is exactly the shape Requirement 6.3 describes.
            let applicability: GateApplicability = applicable
                ? .applicable
                : .notApplicable(decision: Sample.approval())
            var outcome: GateOutcome = applicable ? .passed : .notExecuted
            if let defect, defect.gate == gate, applicable {
                outcome = defect.outcome
            }
            guard let entry = try? ReleaseGateRecord(
                gate: gate,
                applicability: applicability,
                outcome: outcome,
                evidence: Sample.evidence("gate.\(gate.rawValue).p19.\(seed)")
            ) else {
                return nil
            }
            entries.append(entry)
        }

        guard let governance = try? ModelGovernanceDecisionRecord(
            modelIdentity: RequiredPixelModel.identity,
            isIndependentNonPeerReviewed: true,
            redTeamValidationValid: false,
            inheritedRedTeamStatus: .invalidNoReportInherited,
            decision: Sample.approval()
        ) else {
            return nil
        }

        return try? ReleaseReadinessRecord(
            id: Sample.artifact("release.p19.\(seed)"),
            schemaVersion: .v1,
            appBuild: build,
            capabilityManifest: Sample.artifact("capability-manifest.p19.\(seed)"),
            modelBundle: bundleID,
            deviceAllowlist: Sample.artifact("allowlist.p19.\(seed)"),
            gateRecords: entries,
            distributionRights: DistributionRightsRecord(
                repositoryCodeLicense: Sample.approval(),
                datasetDistributionTerms: Sample.approval()
            ),
            modelGovernance: governance,
            benchmarkClaims: []
        )
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator actually produced, so the property cannot pass by generating
/// one composition a hundred times.
///
/// It also proves the run happened at all. `propertyCheck` discards an error thrown by its
/// body, so a body that failed before its first assertion — a construction that threw, a
/// generator that produced nothing usable — reports a passing test in milliseconds with
/// every arm skipped. A witness that counts cases *outside* the body is the only thing that
/// catches that, which is why the case-count assertion lives here rather than in an arm.
///
/// The thresholds are far below what 100 uniform draws produce, so this witnesses variation
/// rather than pinning a distribution.
private final class CapabilitySelectionVariationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var cases = 0
    private var conditionsSatisfied: Set<String> = []
    private var conditionsMissing: Set<String> = []
    private var enabledOutcomes: Set<Bool> = []
    private var requiredReasons: Set<UnavailableReason> = []
    private var pixelLabels: Set<PixelEvidence> = []
    private var states: Set<ProvenanceCategory> = []
    private var routes: Set<InputRoute> = []
    private var bases: Set<PreservationBasis> = []
    private var byteCounts: Set<UInt64> = []
    private var digests: Set<Int> = []
    private var defectGates: Set<ReleaseGate> = []
    private var defectOutcomes: Set<GateOutcome> = []
    private var seeds: Set<Int> = []

    func record(_ shape: CapabilityShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        for condition in EnablingCondition.allCases {
            if shape.satisfies(condition) {
                conditionsSatisfied.insert(condition.rawValue)
            } else {
                conditionsMissing.insert(condition.rawValue)
            }
        }
        enabledOutcomes.insert(shape.requiresEnabledProvenance)
        if let reason = shape.requiredUnavailableReason { requiredReasons.insert(reason) }
        pixelLabels.insert(shape.pixel)
        states.formUnion([shape.state, shape.controlState])
        routes.insert(shape.route)
        bases.insert(shape.basis)
        byteCounts.insert(shape.byteCount)
        digests.insert(shape.digestIndex % 16)
        defectGates.insert(shape.defectGate)
        defectOutcomes.insert(shape.defectOutcome)
        seeds.insert(shape.seed)
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases; ran \(cases)")

        // Each of the six conditions has to be seen both holding and absent, or the
        // "if and only if" is asserted in one direction only.
        let allConditions = Set(EnablingCondition.allCases.map(\.rawValue))
        #expect(
            conditionsSatisfied == allConditions,
            "conditions never satisfied: \(allConditions.subtracting(conditionsSatisfied).sorted())"
        )
        #expect(
            conditionsMissing == allConditions,
            "conditions never absent: \(allConditions.subtracting(conditionsMissing).sorted())"
        )

        // Both answers have to be generated. An all-disabled run would make the enabling
        // direction rest entirely on the control, and an all-enabled run would leave the
        // pixel-only consequences to the knockout arms alone.
        #expect(enabledOutcomes == [true, false], "generated enabling outcomes: \(enabledOutcomes)")
        #expect(
            requiredReasons == Set(UnavailableReason.allCases),
            "generated unavailable reasons: \(requiredReasons.map(\.rawValue).sorted())"
        )

        #expect(
            pixelLabels == Set(PixelEvidence.allCases),
            "generated pixel labels: \(pixelLabels.map(\.rawValue).sorted())"
        )
        #expect(
            states == Set(ProvenanceCategory.allCases),
            "generated enabled states: \(states.map(\.rawValue).sorted())"
        )
        #expect(routes == Set(InputRoute.allCases), "both ingest routes are generated")
        #expect(
            bases == Set(PreservationBasis.allCases),
            "generated preservation bases: \(bases.map(\.rawValue).sorted())"
        )
        #expect(byteCounts.count >= 50, "generated byte counts: \(byteCounts.count)")
        #expect(digests.count >= 10, "generated digests: \(digests.count)")
        #expect(
            defectOutcomes == [.failed, .notExecuted],
            "generated defect outcomes: \(defectOutcomes.map(\.rawValue).sorted())"
        )
        #expect(defectGates.count >= 10, "generated defect gates: \(defectGates.count)")
        #expect(seeds.count >= 50, "generated seeds: \(seeds.count)")
    }
}
