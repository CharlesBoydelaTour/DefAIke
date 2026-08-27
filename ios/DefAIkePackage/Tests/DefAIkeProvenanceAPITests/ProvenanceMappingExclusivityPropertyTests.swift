import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain
@testable import DefAIkeProvenanceAPI

// Design Property 20: enabled provenance mapping is mutually exclusive.
//
// The design states it as: for any normalized offline validator outcome accepted by the
// Provenance Policy, the adapter produces exactly one state — definite
// cryptographic/structural/binding success maps to `validated` with bounded available
// details; definite no-manifest maps to `absent`; cryptographic, structural, or binding
// failure maps to `invalid`; unsupported capability maps to `unsupported`; and approved
// inconclusive processing maps to `indeterminate`.
//
// The claim has two directions, and a property that asserts one of them proves nothing
// about the other:
//
//   * **no outcome maps to two states.** An enum has one case by construction, so that
//     alone is not the claim. The mapping could still be ambiguous three ways: the signed
//     artifact could assign one normalized status to two states; the projection could
//     depend on the order a policy happened to list its mappings in, or on the order a
//     validator happened to report its details in; or the same outcome could answer
//     differently on a second evaluation. All three are asserted, and the first is
//     asserted at the artifact — a policy that maps one status to two states is refused
//     before a mapper can be built from it, so the mapping is a function by construction
//     rather than by convention.
//   * **no outcome maps to none.** Every combination of status, binding determination, and
//     named failed check over a generated policy's whole status vocabulary is exercised,
//     and each one has to land on exactly one answer: one enabled state, or one
//     ``ProvenanceMappingFault``. Nothing falls through, nothing returns two answers, and
//     the accepted region is where the policy answers rather than where the code guesses.
//
// ## The oracle
//
// Every expectation comes from one of two places outside the mapper. The state of an
// accepted outcome is read straight off the signed artifact's own `statusMappings` through
// ``ProvenancePolicy/state(for:)``, so the arm compares the code against the artifact
// rather than against itself. Which outcomes are accepted at all comes from
// ``MappingOracle``, which restates Requirements 6.9 through 6.14 clause by clause with
// the citation for each condition and for the order the clauses apply in.
//
// ## Nothing here decides a policy
//
// The mapping is policy-driven, so this file supplies a policy and asserts what the
// mapping does with it. Every generated case draws its own trust-store descriptor, offline
// revocation answer, displayable-field allowlist, assertion ceiling, and complete status
// mapping, and no arm depends on any particular value of any of them:
//
//   * the status keys are opaque (`p20.<seed>.status-<n>`) and the state each one is
//     assigned rotates between cases, so a key's spelling cannot hint at its state and no
//     arm can pass by recognizing a name;
//   * the offline revocation answer is generated across all three states the schema leaves
//     representable, and the only assertions about it are that the produced state is the
//     one the policy declared and that it is never `validated` and never `absent`;
//   * the trust store, signer details, assertion labels, and unsupported feature names are
//     synthetic arguments that exist so a seam taking a signed artifact can be called.
//
// **No value in this file is an approved release input, and nothing here may be copied
// into one.** The trust anchors, revocation answer, signer and assertion content, display
// allowlist, processing limits, copy keys, feasibility decision, and every identifier are
// unresolved external decisions (design decision D5 and the Provenance Feasibility Gate).
// No assertion claims any of them is correct.
//
// ## Offline by construction
//
// ``ProvenanceOutcomeMapper`` is a pure function of a signed policy, an approved copy
// binding, and one ``NormalizedProvenanceOutcome``. It has no store, clock, session, byte
// sequence, or validator, so nothing in this file can reach a network even accidentally,
// and Requirement 6.8 needs no arm here to hold: the type has nothing to reach one with.
//
// ## Neighbouring properties, and what this file does not assert
//
//   * **Property 19** owns whether provenance is enabled at all, whether the lane is
//     available, and whether the analyzer is invoked. Here the capability is a
//     precondition: every arm is inside "where Provenance Capability is enabled", which is
//     the scope Requirements 6.9 through 6.14 are written in.
//   * **Property 21** owns lane immutability and noninterference, so no report is built.
//   * **Property 22** owns fusion, so no rule table is built or looked up.
//   * Requirements 6.15 through 6.18 and 6.21 are presentation and release-fixture claims.
//     No arm here states what a user is shown, and no arm invents a trust outcome for a
//     fixture; task 9.9 owns the approved offline fixtures.
//   * `ProvenanceOutcomeMapperTests` pins each mapping and each refusal at one example.
//     This file quantifies the same statement over generated policies, allowlists,
//     ceilings, revocation answers, status vocabularies, bindings, and details.
//
// ## The conformance seam, and why it does not constrain this property
//
// The conditional C2PA adapter deliberately does not conform to `ProvenanceAnalyzing`,
// because the port returns evidence unconditionally and cannot express a Provenance
// Feasibility Gate finding. That recorded open question constrains Property 19, which has
// to quantify "compiled into the build" as the presence of a port conformance. It does not
// constrain this property: the subject here is the value-level projection from a
// normalized outcome onto one state, which is reached without a port, an analyzer, an
// asset, or a linked validator.
//
// ## Why no arm throws
//
// `propertyCheck` discards an error thrown from its body: a `throw` before the assertions
// makes the whole run pass in milliseconds with every arm skipped. Every mapping here
// therefore goes through ``MappingScenario/answer(for:)``, which turns a refusal into a
// ``MappingAnswer`` value, every construction is failable, and every helper reports through
// `Issue.record`. ``MappingVariationWitness`` counts the cases, the mappings, and the arms
// that completed and asserts those counts *outside* the body, where an issue is not
// suppressed. It also asserts that each of the five states and each of the six refusals was
// actually **produced** over the run, which is what turns "mutually exclusive" from a claim
// about unreached branches into a claim about observed outputs.

extension Tag {
    /// Design Property 20.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property20ProvenanceMappingExclusivity: Self
}

@Suite(
    "Property 20: Enabled provenance mapping is mutually exclusive",
    .tags(.property20ProvenanceMappingExclusivity)
)
struct ProvenanceMappingExclusivityPropertyTests {
    /// Runs at the library default of 100 generated cases with shrinking, which is the
    /// minimum the design requires; `PropertyToolchainWiringTests` pins that default.
    /// Every generator is composed with `zip`, so the shrinkers compose.
    ///
    /// **Validates: Requirements 6.9, 6.10, 6.11, 6.12, 6.13, 6.14**
    @Test("Enabled mapping is exclusive and total over generated validator outcomes")
    func enabledProvenanceMappingIsMutuallyExclusive() async {
        let witness = MappingVariationWitness()

        await propertyCheck(input: MappingShape.generator) { shape in
            witness.record(shape)
            guard let scenario = MappingScenario(shape: shape, witness: witness) else { return }

            scenario.checkEveryOutcomeReachesExactlyOneAnswer()
            scenario.checkEveryStateIsReachedAndPairwiseSeparate()
            scenario.checkValidatedDetailsAreAllowlistedBoundedAndOrdered()
            scenario.checkEveryProducedPayloadComesFromApprovedArtifacts()
            scenario.checkRepeatedAndReorderedMappingAgree()
            scenario.checkAmbiguousPolicyMappingIsUnrepresentable()
            scenario.checkEveryUnansweredConditionYieldsOneFaultAndNoState()
            scenario.checkTheStateFollowsThePolicyRatherThanTheOutcome()

            witness.recordCompletedArms()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - The two answers a mapping can produce

/// The answer one mapping produced, as a value rather than as control flow.
///
/// Two cases, because the mapper has exactly two results. Turning the refusal into a value
/// here is what keeps an arm from ending early by letting an error escape into
/// `propertyCheck`, which discards it.
private enum MappingAnswer: Hashable, CustomStringConvertible {
    case state(ProvenanceEvidence)
    case fault(ProvenanceMappingFault)

    var evidence: ProvenanceEvidence? {
        if case let .state(evidence) = self { return evidence }
        return nil
    }

    var fault: ProvenanceMappingFault? {
        if case let .fault(fault) = self { return fault }
        return nil
    }

    /// This answer with a produced state reduced to its category.
    ///
    /// The comparison unit for the oracle: the oracle derives which of the five states an
    /// outcome must reach and which refusal it must otherwise get, and the payload of a
    /// produced state is asserted separately against the artifacts that supplied it.
    var expectationForm: ExpectedAnswer {
        switch self {
        case let .state(evidence): return .state(evidence.category)
        case let .fault(fault): return .fault(fault)
        }
    }

    var description: String {
        switch self {
        case let .state(evidence): return "state \(evidence.category.rawValue)"
        case let .fault(fault): return "fault \(fault)"
        }
    }
}

/// What the requirements and the signed policy say one outcome must produce.
private enum ExpectedAnswer: Hashable, CustomStringConvertible {
    case state(ProvenanceCategory)
    case fault(ProvenanceMappingFault)

    var description: String {
        switch self {
        case let .state(category): return "state \(category.rawValue)"
        case let .fault(fault): return "fault \(fault)"
        }
    }
}

/// The six refusals, named so the witness can require each one to have been produced.
///
/// A closed set that mirrors ``ProvenanceMappingFault``: if a case is added there, this
/// stops compiling, and an unobserved refusal fails the witness rather than passing
/// unnoticed.
private enum FaultKind: String, Hashable, CaseIterable {
    case unmappedValidatorStatus
    case bindingInconsistentWithMappedState
    case undeterminedInvalidityCategory
    case invalidityCategoryOnNonInvalidState
    case detailsReportedForAbsentState
    case assertionLimitExceeded

    static func of(_ fault: ProvenanceMappingFault) -> FaultKind {
        switch fault {
        case .unmappedValidatorStatus: return .unmappedValidatorStatus
        case .bindingInconsistentWithMappedState: return .bindingInconsistentWithMappedState
        case .undeterminedInvalidityCategory: return .undeterminedInvalidityCategory
        case .invalidityCategoryOnNonInvalidState: return .invalidityCategoryOnNonInvalidState
        case .detailsReportedForAbsentState: return .detailsReportedForAbsentState
        case .assertionLimitExceeded: return .assertionLimitExceeded
        }
    }
}

// MARK: - The oracle

/// Requirements 6.9 through 6.14, restated over one policy and one normalized outcome.
///
/// Derived from the acceptance criteria and the artifact's own fields, never from the
/// mapper. The two are separable: ``state(for:)`` below is the artifact read verbatim, and
/// every other clause is one sentence of one criterion with its citation.
private enum MappingOracle {
    /// The single answer the requirements provide for `outcome` under `policy`.
    ///
    /// The clauses apply in the order their subjects come into existence, which is a
    /// property of the requirements rather than of any implementation:
    ///
    ///   1. a declared processing ceiling bounds the outcome itself, so it applies before
    ///      any state is in question;
    ///   2. without a mapping there is no state, so no state-specific question is askable;
    ///   3. a named failed check is meaningful only for Requirement 6.12's invalid state,
    ///      and Requirements 6.13 and 6.14 keep the other states separate from it, so the
    ///      contradiction holds for whichever of the other four states was mapped; then
    ///   4. the per-state consistency conditions of Requirements 6.10, 6.11, and 6.12.
    static func expectedAnswer(
        for outcome: NormalizedProvenanceOutcome,
        under policy: ProvenancePolicy
    ) -> ExpectedAnswer {
        // Requirement 6.9 speaks of an outcome the policy admits. An assertion list longer
        // than the policy's declared ceiling is not one, and the ceiling bounds the
        // outcome's size rather than describing any single state.
        let assertionLimit = policy.processingLimits.maximumAssertionCount.value
        if outcome.assertionLabels.count > assertionLimit {
            return .fault(
                .assertionLimitExceeded(
                    observed: outcome.assertionLabels.count,
                    limit: assertionLimit
                )
            )
        }

        // Requirement 6.9: the five states are the signed policy's, so a status the policy
        // does not map has no state at all. Read straight off `statusMappings`.
        guard let state = policy.state(for: outcome.status) else {
            return .fault(.unmappedValidatorStatus(outcome.status))
        }

        // Requirement 6.12 is the only state that says which check failed. Requirements
        // 6.13 and 6.14 report unsupported and indeterminate separately from it, and
        // Requirements 6.10 and 6.11 describe a success and an absence, so a named failed
        // check contradicts every mapped state other than invalid.
        if let category = outcome.failedCheck, state != .invalid {
            return .fault(
                .invalidityCategoryOnNonInvalidState(
                    status: outcome.status,
                    state: state,
                    category: category
                )
            )
        }

        switch state {
        case .validated:
            // Requirement 6.10 requires the validated state to report binding status, and
            // Requirement 6.12 puts a byte-binding failure in the invalid state. A
            // validated result whose binding is unestablished or refuted is therefore not
            // representable.
            guard outcome.binding == .boundToInspectedBytes else {
                return .fault(
                    .bindingInconsistentWithMappedState(
                        status: outcome.status,
                        state: state,
                        binding: outcome.binding
                    )
                )
            }
            return .state(.validated)

        case .invalid:
            // Requirement 6.12 requires the invalid state to name which of the three
            // checks failed, so an invalid result with no named check cannot be completed
            // without inventing a category.
            guard let category = outcome.failedCheck else {
                return .fault(.undeterminedInvalidityCategory(status: outcome.status))
            }
            // A failed byte binding and an established binding to the same inspected bytes
            // cannot both hold (Requirement 6.12).
            guard category != .byteBinding || outcome.binding != .boundToInspectedBytes else {
                return .fault(
                    .bindingInconsistentWithMappedState(
                        status: outcome.status,
                        state: state,
                        binding: outcome.binding
                    )
                )
            }
            return .state(.invalid)

        case .absent:
            // Requirement 6.11: absent means no Content Credential is present in the
            // inspected byte sequence. Nothing was found, so nothing was bound to those
            // bytes, and nothing can be described.
            guard outcome.binding == .notDetermined else {
                return .fault(
                    .bindingInconsistentWithMappedState(
                        status: outcome.status,
                        state: state,
                        binding: outcome.binding
                    )
                )
            }
            guard !outcome.reportsAnyDetail else {
                return .fault(.detailsReportedForAbsentState(status: outcome.status))
            }
            return .state(.absent)

        case .unsupported:
            // Requirement 6.13 requires a separate state and names no further condition.
            return .state(.unsupported)

        case .indeterminate:
            // Requirement 6.14 requires a separate state and names no further condition.
            return .state(.indeterminate)
        }
    }
}

// MARK: - Generated shape

/// Everything one generated case decides, as plain data.
///
/// The generator produces data only. Policies, copy bindings, mappers, and normalized
/// outcomes are built from it inside the scenario, where a construction that unexpectedly
/// fails is recorded as an issue rather than thrown: `propertyCheck` discards an error
/// thrown by its body, so a refusal that escaped as a throw would report a passing test
/// with every arm skipped.
///
/// ## How the baseline varies
///
/// A property whose baseline is one policy with one field flipped asserts one example a
/// hundred times over, so every dimension the arms depend on is generated:
///
///   * the displayable-field allowlist, over all 31 nonempty subsets of the five fields,
///     because Requirement 6.10 reports the *available* information and the allowlist is
///     what decides which of it may be shown;
///   * the policy's assertion ceiling, and a reported assertion count that reaches both
///     sides of it, so the bounded-details claim is not asserted only where it is slack;
///   * the offline revocation answer, over all three states the schema leaves
///     representable;
///   * how many additional statuses share the invalid state, so many-to-one mapping is
///     exercised alongside the refusal of one-to-many;
///   * the rotation that assigns states to opaque status keys, so no arm can pass by
///     recognizing a key's spelling;
///   * which signer fields the validator reports, and the text it reports for them;
///   * the binding determination and the named failed check the per-state arms use, while
///     the totality arm sweeps all three bindings against all four check values;
///   * the trust-store anchor count, and every synthetic identifier, from ``seed``.
///
/// ``MappingVariationWitness`` checks after the run that this happened.
private struct MappingShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic identifier, so a whole case's reference set varies together
    /// and stays coherent without a cross-reference table.
    let seed: Int

    // MARK: The generated policy

    /// Selects one of the 31 nonempty subsets of ``ProvenanceDisplayField``.
    let displayableFieldBits: Int

    /// The policy's declared maximum assertion count.
    let assertionLimit: Int

    /// Selects the state an unresolvable offline revocation question resolves to.
    let revocationStateIndex: Int

    /// How many extra statuses the policy maps onto the invalid state.
    let extraInvalidStatusCount: Int

    /// Rotates which opaque status key is assigned which state.
    let mappingRotation: Int

    /// Anchors the policy declares its offline trust store holds.
    let trustAnchorCount: Int

    // MARK: The generated validator outcome

    /// Selects which signer-side fields the validator reports.
    let signerFieldBits: Int

    /// How many assertion labels the validator read. Reaches past ``assertionLimit``.
    let reportedAssertionCount: Int

    /// How many unsupported features the validator could name.
    let unsupportedFeatureCount: Int

    /// Varies the display-safe text the validator reported.
    let detailTextIndex: Int

    /// The binding determination the per-state arms use where the state permits a choice.
    let bindingIndex: Int

    /// The named failed check the per-state arms use for the invalid state.
    let failedCheckIndex: Int

    // MARK: Derived

    /// The three states an unresolvable revocation answer may resolve to.
    ///
    /// ``ProvenanceRevocationBehavior`` refuses `validated`, because a missing answer is
    /// not a cryptographic success, and refuses `absent`, because absence means no manifest
    /// was found. Which of the remaining three is correct is an unresolved release
    /// decision, so all three are generated and no arm depends on one of them.
    static let admissibleRevocationStates: [ProvenanceStateKey] = [
        .invalid, .unsupported, .indeterminate,
    ]

    /// Signer-side display fields, in vocabulary order.
    ///
    /// ``ProvenanceDisplayField/assertionLabels`` is excluded: the normalized contract
    /// refuses a signer detail tagged with it, so assertion labels arrive through exactly
    /// one field and cannot be counted twice against the policy's assertion ceiling.
    static let signerCapableFields: [ProvenanceDisplayField] =
        ProvenanceDisplayField.allCases.filter { $0 != .assertionLabels }

    /// The fields this case's policy permits displaying. Never empty.
    var displayableFields: Set<ProvenanceDisplayField> {
        let bits = (displayableFieldBits % 31) + 1
        var fields: Set<ProvenanceDisplayField> = []
        for (index, field) in ProvenanceDisplayField.allCases.enumerated()
        where bits & (1 << index) != 0 {
            fields.insert(field)
        }
        return fields
    }

    /// The state this case's policy declares for an unresolvable revocation question.
    var revocationAnswerState: ProvenanceStateKey {
        Self.admissibleRevocationStates[
            revocationStateIndex % Self.admissibleRevocationStates.count
        ]
    }

    /// How far the state assignment is rotated across the opaque status keys.
    var rotation: Int { mappingRotation % ProvenanceStateKey.allCases.count }

    /// The signer-side fields the validator reports for this case.
    var reportedSignerFields: [ProvenanceDisplayField] {
        Self.signerCapableFields.enumerated()
            .filter { signerFieldBits & (1 << $0.offset) != 0 }
            .map(\.element)
    }

    /// The named failed check the invalid-state arms use. Never `nil`: Requirement 6.12
    /// requires the state to name one, and the absence of a name is its own refusal.
    var failedCheck: InvalidityCategory {
        InvalidityCategory.allCases[failedCheckIndex % InvalidityCategory.allCases.count]
    }

    /// The binding determination the arms use where the mapped state permits a choice.
    var binding: NormalizedBindingOutcome {
        NormalizedBindingOutcome.allCases[
            bindingIndex % NormalizedBindingOutcome.allCases.count
        ]
    }

    /// Whether the freely generated assertion count breaches the generated ceiling.
    ///
    /// Recorded by the witness: without at least one case on each side, the ceiling would
    /// only ever be exercised by the arm that constructs a breach deliberately.
    var breachesAssertionLimit: Bool { reportedAssertionCount > assertionLimit }

    var description: String {
        """
        seed \(seed), fields \(displayableFields.map(\.rawValue).sorted()), \
        assertionLimit \(assertionLimit), reportedAssertions \(reportedAssertionCount), \
        revocation \(revocationAnswerState.rawValue), rotation \(rotation), \
        extraInvalid \(extraInvalidStatusCount), \
        signerFields \(reportedSignerFields.map(\.rawValue)), \
        unsupportedFeatures \(unsupportedFeatureCount), binding \(binding.rawValue), \
        failedCheck \(failedCheck.rawValue), anchors \(trustAnchorCount)
        """
    }

    // MARK: Generators

    static var generator: Generator<MappingShape, AnySequence<Any>> {
        zip(Gen.int(in: 0...9_999), policyShape, outcomeShape)
            .map { raw in
                MappingShape(
                    seed: raw.0,
                    displayableFieldBits: raw.1.0,
                    assertionLimit: raw.1.1,
                    revocationStateIndex: raw.1.2,
                    extraInvalidStatusCount: raw.1.3,
                    mappingRotation: raw.1.4,
                    trustAnchorCount: raw.1.5,
                    signerFieldBits: raw.2.0,
                    reportedAssertionCount: raw.2.1,
                    unsupportedFeatureCount: raw.2.2,
                    detailTextIndex: raw.2.3,
                    bindingIndex: raw.2.4,
                    failedCheckIndex: raw.2.5
                )
            }
            .eraseToAny()
    }

    /// The signed policy's generated fields.
    ///
    /// The assertion ceiling is drawn from a small range and the reported count from a
    /// wider one, so both sides of the ceiling arrive without weighting either: a ceiling
    /// large enough to never bite would leave the bounded-details claim untested.
    private static var policyShape: Generator<(Int, Int, Int, Int, Int, Int), AnySequence<Any>> {
        zip(
            Gen.int(in: 0...30),
            Gen.int(in: 1...8),
            Gen.int(in: 0...199),
            Gen.int(in: 0...3),
            Gen.int(in: 0...199),
            Gen.int(in: 1...16)
        )
        .eraseToAny()
    }

    /// The validator outcome's generated fields.
    ///
    /// Bounded well below ``NormalizedProvenanceOutcome/maximumDetailCount``: this property
    /// is about which state an outcome reaches, and a detail list that met the contract's
    /// structural ceiling would make the answer depend on that bound instead.
    private static var outcomeShape: Generator<(Int, Int, Int, Int, Int, Int), AnySequence<Any>> {
        zip(
            Gen.int(in: 0...15),
            Gen.int(in: 0...11),
            Gen.int(in: 0...3),
            Gen.int(in: 0...199),
            Gen.int(in: 0...199),
            Gen.int(in: 0...199)
        )
        .eraseToAny()
    }
}

// MARK: - One probe status

/// One normalized status the arms map, and the state the generated policy assigns it.
///
/// The key is opaque and its role is carried separately, so a failure names which probe
/// disagreed without the key itself having to spell out a state.
private struct StatusProbe: Hashable, Sendable {
    let status: ProvenanceValidatorStatusID
    /// The state the policy maps this status to, or `nil` for the unmapped probe.
    let state: ProvenanceStateKey?
    /// Why this probe is in the vocabulary. Reporting only.
    let role: String
}

// MARK: - Scenario

/// One generated case: the artifacts built from its shape, and the arms it runs.
///
/// Construction is failable rather than throwing so the property body can record an issue
/// and return. Nothing in here decides a policy: every artifact is synthetic, and the arms
/// assert what the *mapping* does with it.
private struct MappingScenario {
    let shape: MappingShape
    private let witness: MappingVariationWitness

    /// The signed policy in force for this case.
    private let policy: ProvenancePolicy

    /// The same policy with its state assignment rotated one step further.
    ///
    /// Same status keys, same everything else. Used to show the state is the artifact's
    /// choice rather than the code's.
    private let rotatedPolicy: ProvenancePolicy

    /// The same policy with `statusMappings` listed in the opposite order.
    ///
    /// ``ProvenancePolicy/state(for:)`` returns the first matching entry, so a mapping that
    /// was ambiguous would answer differently here. Combined with the arm that shows an
    /// ambiguous policy cannot be constructed, this is what makes the projection a
    /// function rather than a first-match convention.
    private let reversedPolicy: ProvenancePolicy

    private let mapper: ProvenanceOutcomeMapper
    private let rotatedMapper: ProvenanceOutcomeMapper
    private let reversedMapper: ProvenanceOutcomeMapper

    /// Every status the arms probe, including the deliberately unmapped one.
    private let probes: [StatusProbe]

    init?(shape: MappingShape, witness: MappingVariationWitness) {
        guard let artifacts = MappingArtifacts(shape: shape) else {
            Issue.record("building the generated provenance artifacts failed [\(shape)]")
            return nil
        }
        self.shape = shape
        self.witness = witness
        self.policy = artifacts.policy
        self.rotatedPolicy = artifacts.rotatedPolicy
        self.reversedPolicy = artifacts.reversedPolicy
        self.mapper = artifacts.mapper
        self.rotatedMapper = artifacts.rotatedMapper
        self.reversedMapper = artifacts.reversedMapper
        self.probes = artifacts.probes
    }

    // MARK: Mapping, never a thrown error

    /// The answer one mapping produced, recorded with the witness.
    ///
    /// The only path from an arm to the mapper. A refusal becomes a value here, so an arm
    /// cannot end early by letting an error escape into `propertyCheck`, which would
    /// discard it.
    private func answer(
        for outcome: NormalizedProvenanceOutcome,
        using selected: ProvenanceOutcomeMapper? = nil
    ) -> MappingAnswer {
        let active = selected ?? mapper
        let produced: MappingAnswer
        do {
            produced = .state(try active.evidence(for: outcome))
        } catch {
            produced = .fault(error)
        }
        witness.recordProduced(produced)
        return produced
    }

    /// Asserts that one mapping produced exactly what the requirements provide for.
    ///
    /// Reports at the caller's source location, so a failure names the arm that made the
    /// claim rather than this shared helper.
    private func expectOracleAnswer(
        for outcome: NormalizedProvenanceOutcome,
        under oraclePolicy: ProvenancePolicy,
        using selected: ProvenanceOutcomeMapper? = nil,
        _ reason: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> MappingAnswer {
        let produced = answer(for: outcome, using: selected)
        let expected = MappingOracle.expectedAnswer(for: outcome, under: oraclePolicy)
        if produced.expectationForm != expected {
            Issue.record(
                "\(reason): expected \(expected), got \(produced) [\(shape)]",
                sourceLocation: sourceLocation
            )
        }
        return produced
    }

    // MARK: - Arm 1: exactly one answer, for every outcome

    /// Every status, binding, and named-check combination reaches exactly one answer.
    ///
    /// The whole representable input space of ``NormalizedProvenanceOutcome`` for this
    /// case's policy: each probe status crossed with all three binding determinations and
    /// all four values of the named failed check, carrying this case's generated details.
    ///
    /// Both directions of the claim are asserted on every combination:
    ///
    ///   * **nothing maps to none.** Every combination produces one enabled state or one
    ///     refusal, and which one is the oracle's answer rather than the mapper's.
    ///   * **nothing maps to two.** A produced state matches exactly one of the five
    ///     payload shapes, exactly one category, and exactly one encoded state key. The
    ///     five checks are independent pattern matches rather than a `switch`, so they
    ///     count matches instead of asking the value which case it is.
    ///
    /// A refusal has to name the outcome it refused. Requirement 6.9's exclusivity is what
    /// forbids resolving an unanswered condition by selecting a state, and the design routes
    /// exactly these conditions to the Provenance Feasibility Gate — a refusal that named a
    /// status other than the one it was given would send that gate to the wrong artifact
    /// position.
    func checkEveryOutcomeReachesExactlyOneAnswer() {
        for probe in probes {
            for binding in NormalizedBindingOutcome.allCases {
                for failedCheck in Self.namedCheckValues {
                    guard let outcome = outcome(
                        status: probe.status,
                        binding: binding,
                        failedCheck: failedCheck
                    ) else {
                        witness.recordUnbuildableOutcome()
                        Issue.record(
                            """
                            building the normalized outcome for \(probe.role) with \
                            binding \(binding.rawValue) failed [\(shape)]
                            """
                        )
                        continue
                    }

                    let produced = expectOracleAnswer(
                        for: outcome,
                        under: policy,
                        "the \(probe.role) probe disagreed with the requirement"
                    )

                    if let evidence = produced.evidence {
                        expectExactlyOneState(evidence, probe: probe)
                    }
                    if let fault = produced.fault {
                        expectRefusalNamesTheOutcome(fault, probe: probe)
                    }
                }
            }
        }
    }

    /// A refusal names the status it refused, wherever it names one at all.
    ///
    /// Two of the six refusals are about the outcome's size and shape rather than about one
    /// status, so they carry none; the other four have to carry this probe's status and not
    /// some other entry in the policy's vocabulary.
    private func expectRefusalNamesTheOutcome(
        _ fault: ProvenanceMappingFault,
        probe: StatusProbe
    ) {
        let named: ProvenanceValidatorStatusID?
        switch fault {
        case let .unmappedValidatorStatus(status): named = status
        case let .bindingInconsistentWithMappedState(status, _, _): named = status
        case let .undeterminedInvalidityCategory(status): named = status
        case let .invalidityCategoryOnNonInvalidState(status, _, _): named = status
        case let .detailsReportedForAbsentState(status): named = status
        case .assertionLimitExceeded: named = nil
        }
        guard let named else { return }
        #expect(
            named == probe.status,
            """
            the refusal for \(probe.role) named \(named.rawValue) rather than \
            \(probe.status.rawValue) [\(shape)]
            """
        )
    }

    /// The four values a named failed check can take: absent, or one of the three checks.
    ///
    /// Requirement 6.12 fixes the three kinds, and `nil` is the fourth thing a validator
    /// can report — that it named none — which is a different finding from any of them.
    private static let namedCheckValues: [InvalidityCategory?] =
        [nil] + InvalidityCategory.allCases.map { $0 }

    /// A produced state reads as exactly one of the five, three independent ways.
    private func expectExactlyOneState(_ evidence: ProvenanceEvidence, probe: StatusProbe) {
        var payloadMatches = 0
        if case .validated = evidence { payloadMatches += 1 }
        if case .invalid = evidence { payloadMatches += 1 }
        if case .absent = evidence { payloadMatches += 1 }
        if case .unsupported = evidence { payloadMatches += 1 }
        if case .indeterminate = evidence { payloadMatches += 1 }
        #expect(
            payloadMatches == 1,
            """
            the \(probe.role) probe produced a value readable as \(payloadMatches) of the \
            five states [\(shape)]
            """
        )

        #expect(
            ProvenanceCategory.allCases.filter({ $0 == evidence.category }).count == 1,
            "a produced state matched no single category [\(shape)]"
        )
        #expect(
            ProvenanceStateKey.allCases.filter({ $0 == evidence.stateKey }).count == 1,
            "a produced state matched no single encoded state key [\(shape)]"
        )
        // The encoded key and the runtime category name the same state in both directions,
        // so a state cannot be one thing to a signed artifact and another at runtime.
        #expect(evidence.stateKey.provenanceCategory == evidence.category, "[\(shape)]")
    }

    // MARK: - Arm 2: all five states, pairwise separate

    /// All five states are reachable under one policy, and no two can be confused.
    ///
    /// Requirement 6.9 requires exactly one of five, which is empty unless all five are
    /// reachable, so this arm builds one accepted outcome per state and requires the five
    /// produced categories to be the whole set — a partition rather than a subset.
    ///
    /// The separations the requirements name individually are then asserted on the
    /// payloads, because "reported separately" is a claim about what each state carries:
    ///
    ///   * Requirement 6.11 against 6.12: absent carries nothing, and invalid names which
    ///     check failed. Only invalid carries an invalidity category.
    ///   * Requirement 6.13 against 6.12: only unsupported carries unsupported features,
    ///     and it never carries an invalidity category.
    ///   * Requirement 6.14 against both: indeterminate carries neither.
    ///   * Requirement 6.10: only validated carries a binding status and detail fields.
    func checkEveryStateIsReachedAndPairwiseSeparate() {
        var produced: [ProvenanceStateKey: ProvenanceEvidence] = [:]
        for state in ProvenanceStateKey.allCases {
            guard let outcome = acceptedOutcome(for: state) else {
                Issue.record("no accepted outcome for \(state.rawValue) [\(shape)]")
                continue
            }
            let answer = expectOracleAnswer(
                for: outcome,
                under: policy,
                "the accepted \(state.rawValue) outcome did not reach its state"
            )
            guard let evidence = answer.evidence else { continue }
            produced[state] = evidence
        }

        #expect(
            Set(produced.values.map(\.category)) == Set(ProvenanceCategory.allCases),
            """
            one policy did not reach all five states: \
            \(produced.values.map(\.category.rawValue).sorted()) [\(shape)]
            """
        )
        #expect(produced.count == ProvenanceStateKey.allCases.count, "[\(shape)]")

        for (state, evidence) in produced {
            #expect(
                evidence.category == state.provenanceCategory,
                "the accepted \(state.rawValue) outcome produced \(evidence.category.rawValue)"
            )

            #expect(
                (Self.invalidityCategory(of: evidence) != nil) == (state == .invalid),
                "only the invalid state names which check failed [\(shape)]"
            )
            #expect(
                (Self.unsupportedFeatures(of: evidence) != nil) == (state == .unsupported),
                "only the unsupported state names unsupported features [\(shape)]"
            )
            #expect(
                (Self.validatedSummary(of: evidence) != nil) == (state == .validated),
                "only the validated state reports binding and detail fields [\(shape)]"
            )
            if state == .absent {
                // No payload exists to carry a detail, which is the structural form of
                // Requirement 6.11: absence cannot be dressed as a finding.
                #expect(evidence == .absent, "[\(shape)]")
            }
        }
    }

    // MARK: - Arm 3: bounded, allowlisted, ordered details

    /// The validated state reports the available details, bounded and in a fixed order.
    ///
    /// Requirement 6.10 requires the available signer identity information, claim
    /// assertions, and binding status; the design adds that the details are bounded, and
    /// the signed policy's `displayableFields` decides which of them may be shown at all.
    /// So the expectation is derived from the policy and the copy binding rather than from
    /// the projection: the permitted signer fields this outcome reported, in vocabulary
    /// order, each under the approved label key the binding supplies for that field.
    ///
    /// The order claim is asserted twice over, because a projection that echoed the
    /// validator's ordering would agree with the first assertion by coincidence: the same
    /// details reported in the opposite order have to produce the identical value. That
    /// matters beyond tidiness — a displayed order an attacker-influenced manifest could
    /// choose is a display decision the policy did not make.
    func checkValidatedDetailsAreAllowlistedBoundedAndOrdered() {
        guard let outcome = acceptedOutcome(for: .validated),
              let evidence = answer(for: outcome).evidence,
              let summary = Self.validatedSummary(of: evidence)
        else {
            Issue.record("the accepted validated outcome did not produce a claim summary")
            return
        }

        // Requirement 6.10's binding status. `validated` cannot represent any other value,
        // which is Requirement 6.12 keeping an unbound claim out of this state.
        #expect(summary.bindingStatus == .boundToInspectedBytes, "[\(shape)]")

        // Signer-side details: the allowlisted intersection, in vocabulary order, under the
        // approved label key for each field.
        let reportedFields = Set(outcome.signerDetails.map(\.field))
        let expectedFields = MappingShape.signerCapableFields.filter { field in
            policy.displayableFields.contains(field) && reportedFields.contains(field)
        }
        // Compared as optionals rather than through `compactMap`, so a field the binding has
        // no label for is a visible mismatch instead of an entry that quietly disappears
        // from the expectation.
        #expect(
            summary.signerFields.map { Optional($0.labelKey) } == expectedFields.map { field in
                mapper.copy.detailLabels[field]
            },
            "displayed signer fields disagreed with the policy allowlist [\(shape)]"
        )
        #expect(
            summary.signerFields.map(\.value) == expectedFields.compactMap { field in
                outcome.signerDetails.first { $0.field == field }?.value
            },
            "a displayed signer value did not come from the validator's detail [\(shape)]"
        )
        // Nothing outside the allowlist reached the display projection.
        let permittedKeys = Set(
            policy.displayableFields.compactMap { mapper.copy.detailLabels[$0] }
        )
        #expect(
            Set(summary.signerFields.map(\.labelKey)).subtracting(permittedKeys).isEmpty,
            "a field the policy does not permit displaying was projected [\(shape)]"
        )

        // Assertion labels ride under exactly one approved key, in the order they were
        // read, and only where the policy permits showing them at all.
        let assertionKey = mapper.copy.detailLabels[.assertionLabels]
        let expectedAssertions =
            policy.displayableFields.contains(.assertionLabels) ? outcome.assertionLabels : []
        #expect(
            summary.assertionFields.map(\.value) == expectedAssertions,
            "displayed assertion labels disagreed with the policy allowlist [\(shape)]"
        )
        #expect(
            summary.assertionFields.allSatisfy { $0.labelKey == assertionKey },
            "an assertion label carried a key other than the approved one [\(shape)]"
        )

        // Bounded on both lists, by the vocabulary and by the policy's own ceiling.
        #expect(
            summary.signerFields.count <= MappingShape.signerCapableFields.count,
            "[\(shape)]"
        )
        #expect(
            summary.assertionFields.count <= policy.processingLimits.maximumAssertionCount.value,
            "displayed assertions exceeded the policy's declared ceiling [\(shape)]"
        )
        // Display-safe, which is what makes a bounded projection of attacker-influenced
        // manifest content presentable at all.
        for field in summary.signerFields + summary.assertionFields {
            let text = field.value.rawValue
            #expect(text.count <= DisplaySafeText.maximumCharacterCount, "[\(shape)]")
            let carriesLineBreak = text.contains { $0.isNewline }
            #expect(
                !carriesLineBreak,
                "a displayed value carried a line break [\(shape)]"
            )
        }

        // The same details, reported in the opposite order, produce the identical value.
        guard let reversed = NormalizedProvenanceOutcome(
            status: outcome.status,
            binding: outcome.binding,
            failedCheck: outcome.failedCheck,
            signerDetails: outcome.signerDetails.reversed(),
            assertionLabels: outcome.assertionLabels,
            unsupportedFeatures: outcome.unsupportedFeatures
        ) else {
            Issue.record("reversing the reported signer details failed [\(shape)]")
            return
        }
        #expect(
            answer(for: reversed).evidence == .validated(summary),
            "the displayed order followed the validator's reporting order [\(shape)]"
        )
    }

    // MARK: - Arm 4: every payload comes from an approved artifact

    /// Each produced state carries the policy version that mapped it and approved copy.
    ///
    /// Requirement 8.1 requires version-controlled approved copy for every provenance
    /// state, and Requirements 6.12 through 6.14 require the state to say what it found.
    /// Both are assertions about provenance: the invalidity category is the validator's own
    /// finding, the explanation is the copy binding's key for that state, and the policy
    /// identifier is the artifact that chose the state. None of the three may be minted by
    /// the projection.
    func checkEveryProducedPayloadComesFromApprovedArtifacts() {
        for state in ProvenanceStateKey.allCases {
            guard let outcome = acceptedOutcome(for: state),
                  let evidence = answer(for: outcome).evidence
            else {
                continue
            }

            #expect(
                Self.policyID(of: evidence) == (state == .absent ? nil : policy.id),
                """
                the \(state.rawValue) state did not record the policy that mapped it \
                [\(shape)]
                """
            )
            #expect(
                Self.explanationKey(of: evidence) == Self.expectedExplanation(
                    for: state,
                    in: mapper.copy
                ),
                "the \(state.rawValue) state did not carry its approved explanation [\(shape)]"
            )

            switch state {
            case .invalid:
                #expect(
                    Self.invalidityCategory(of: evidence) == outcome.failedCheck,
                    "the invalid state renamed the check the validator reported [\(shape)]"
                )
            case .unsupported:
                #expect(
                    Self.unsupportedFeatures(of: evidence) == outcome.unsupportedFeatures,
                    "the unsupported state rewrote the features the validator named [\(shape)]"
                )
            case .validated, .absent, .indeterminate:
                break
            }
        }

        // The offline revocation answer is the policy's, and the schema's two prohibitions
        // hold whichever of the three admissible answers was generated: a question the
        // validator could not resolve without a network never reads as a cryptographic
        // success, and never as an absence of any credential.
        guard let revocation = probes.first(where: { $0.role == Self.revocationProbeRole }),
              let state = revocation.state,
              let outcome = acceptedOutcome(for: state, status: revocation.status),
              let evidence = answer(for: outcome).evidence
        else {
            Issue.record("the revocation probe produced no state [\(shape)]")
            return
        }
        let declared = policy.revocationBehavior.unavailableAnswerState
        #expect(
            evidence.category == declared.provenanceCategory,
            "the unresolvable revocation answer did not follow the policy [\(shape)]"
        )
        #expect(evidence.category != .validated, "[\(shape)]")
        #expect(evidence.category != .absent, "[\(shape)]")
    }

    // MARK: - Arm 5: repeated and reordered mapping agree

    /// The same outcome always produces the same state, however the policy is ordered.
    ///
    /// Three claims that together forbid a second answer for one outcome:
    ///
    ///   * repeating the mapping returns the identical value, payload included, so the
    ///     projection holds no state and consults nothing outside its arguments;
    ///   * a mapper built from the same policy content with `statusMappings` listed in the
    ///     opposite order returns the identical value. ``ProvenancePolicy/state(for:)``
    ///     answers with the first matching entry, so a vocabulary that resolved a status
    ///     two ways would disagree between the two orders; and
    ///   * both hold across the whole probe vocabulary, refusals included, so a
    ///     nondeterministic refusal is caught as well as a nondeterministic state.
    func checkRepeatedAndReorderedMappingAgree() {
        for probe in probes {
            guard let outcome = outcome(
                status: probe.status,
                binding: shape.binding,
                failedCheck: probe.state == .invalid ? shape.failedCheck : nil
            ) else {
                Issue.record("building the \(probe.role) outcome failed [\(shape)]")
                continue
            }

            let first = answer(for: outcome)
            #expect(
                answer(for: outcome) == first,
                "repeating the \(probe.role) mapping produced a different answer [\(shape)]"
            )
            #expect(
                answer(for: outcome, using: reversedMapper) == first,
                """
                listing the policy's status mappings in the opposite order changed the \
                \(probe.role) answer [\(shape)]
                """
            )
        }
    }

    // MARK: - Arm 6: an ambiguous policy is unrepresentable

    /// A policy that maps one status to two states cannot be constructed.
    ///
    /// The no-overlap claim at its source. Every other arm asserts that the projection
    /// returns one state for one outcome; this one asserts that the artifact the projection
    /// reads cannot say two, so exclusivity does not depend on the projection noticing an
    /// ambiguity and choosing. Every ordered pair of states is tried, including a status
    /// listed twice for the same state: a repeated key is ambiguous about which entry is in
    /// force even when both agree, and a decoder that resolved it silently would let the
    /// same signed bytes read as two different policies.
    func checkAmbiguousPolicyMappingIsUnrepresentable() {
        guard let ambiguous = probes.first(where: { $0.state != nil })?.status else {
            Issue.record("no mapped status was available to duplicate [\(shape)]")
            return
        }

        for first in ProvenanceStateKey.allCases {
            for second in ProvenanceStateKey.allCases {
                let mappings =
                    [
                        ProvenanceStatusMapping(status: ambiguous, state: first),
                        ProvenanceStatusMapping(status: ambiguous, state: second),
                    ]
                do {
                    _ = try MappingArtifacts.policy(shape: shape, statusMappings: mappings)
                    Issue.record(
                        """
                        a policy mapping \(ambiguous.rawValue) to both \(first.rawValue) and \
                        \(second.rawValue) was accepted [\(shape)]
                        """
                    )
                } catch let error as ArtifactSchemaError {
                    #expect(
                        error == .duplicateEntry(
                            field: "statusMappings",
                            key: ambiguous.rawValue
                        ),
                        "the ambiguous mapping was refused for the wrong reason [\(shape)]"
                    )
                } catch {
                    Issue.record("an unexpected refusal: \(error) [\(shape)]")
                }
            }
        }
    }

    // MARK: - Arm 7: the refusals are reachable and named

    /// Each unanswered condition produces exactly one named refusal and no state.
    ///
    /// This is what gives "accepted by the Provenance Policy" its content. Without it the
    /// accepted region could be everything, and the exclusivity claim would hold trivially
    /// because nothing was ever refused. Each condition is built from this case's generated
    /// values so the refusal is not one literal repeated a hundred times, and each is
    /// asserted to carry no state at all — Requirement 6.9's exclusivity is precisely what
    /// forbids resolving an unanswered condition by selecting one.
    func checkEveryUnansweredConditionYieldsOneFaultAndNoState() {
        for condition in UnansweredCondition.allCases {
            guard let (outcome, expected) = unanswered(condition) else {
                Issue.record("building the \(condition.rawValue) condition failed [\(shape)]")
                continue
            }
            let produced = answer(for: outcome)
            #expect(
                produced.fault == expected,
                """
                \(condition.rawValue) produced \(produced) rather than \(expected) \
                [\(shape)]
                """
            )
            #expect(
                produced.evidence == nil,
                "\(condition.rawValue) produced an evidence state [\(shape)]"
            )
        }
    }

    // MARK: - Arm 8: the state follows the policy

    /// Rotating the policy's state assignment moves the state, for the same outcome.
    ///
    /// The mapping is the signed artifact's decision, so the same normalized outcome under a
    /// policy that assigns its status a different state has to produce that different
    /// state. Asserted against the oracle recomputed for the rotated policy, because a
    /// rotation can also turn an accepted outcome into a refused one — an outcome bound to
    /// the inspected bytes whose status now maps to `absent` is a contradiction, not a
    /// state — and accepting either answer would be asserting nothing.
    ///
    /// The witness records whether the rotation actually moved a produced state, so a
    /// rotation that silently became the identity fails outside the body instead of making
    /// this arm vacuous.
    func checkTheStateFollowsThePolicyRatherThanTheOutcome() {
        for probe in probes {
            // Inside the policy's assertion ceiling, so both policies reach a state rather
            // than both refusing the list and leaving the rotation unexercised.
            guard let outcome = outcome(
                status: probe.status,
                binding: shape.binding,
                failedCheck: nil,
                assertionLabels: clippedAssertionLabels
            ) else {
                Issue.record("building the \(probe.role) outcome failed [\(shape)]")
                continue
            }

            let original = answer(for: outcome)
            let rotated = expectOracleAnswer(
                for: outcome,
                under: rotatedPolicy,
                using: rotatedMapper,
                "the rotated policy's \(probe.role) answer disagreed with the requirement"
            )

            // The artifact-only oracle, applied to both policies: the produced state equals
            // the one that policy's `statusMappings` names, with no requirement clause
            // restated. Wherever a state was produced at all, this is the whole claim.
            if let before = original.evidence?.category {
                #expect(
                    before == policy.state(for: probe.status)?.provenanceCategory,
                    "the \(probe.role) state did not follow the policy [\(shape)]"
                )
            }
            if let after = rotated.evidence?.category {
                #expect(
                    after == rotatedPolicy.state(for: probe.status)?.provenanceCategory,
                    "the rotated state did not follow the rotated policy [\(shape)]"
                )
            }
            if let before = original.evidence?.category, let after = rotated.evidence?.category {
                witness.recordRotation(changedState: before != after)
            }
        }
    }

    // MARK: - Building normalized outcomes

    /// One normalized outcome carrying this case's generated details.
    ///
    /// `nil` only when the normalized contract refuses the combination, which the caller
    /// reports: the details are built unique and display-safe, so a refusal here is a defect
    /// in this file rather than a finding about the mapping.
    private func outcome(
        status: ProvenanceValidatorStatusID,
        binding: NormalizedBindingOutcome,
        failedCheck: InvalidityCategory?,
        assertionLabels: [DisplaySafeText]? = nil
    ) -> NormalizedProvenanceOutcome? {
        NormalizedProvenanceOutcome(
            status: status,
            binding: binding,
            failedCheck: failedCheck,
            signerDetails: signerDetails,
            assertionLabels: assertionLabels ?? self.assertionLabels,
            unsupportedFeatures: unsupportedFeatures
        )
    }

    /// An outcome the policy accepts for `state`, carrying this case's generated details.
    ///
    /// The consistency conditions the requirements name are satisfied deliberately rather
    /// than by luck, because this is the arm that has to reach a state: an absent outcome
    /// describes nothing and determines no binding (Requirement 6.11), a validated outcome
    /// is bound to the inspected bytes (Requirements 6.10 and 6.12), and an invalid outcome
    /// names one failed check whose kind does not contradict its binding (Requirement 6.12).
    /// The assertion list is clipped to the policy's ceiling for the same reason.
    private func acceptedOutcome(
        for state: ProvenanceStateKey,
        status: ProvenanceValidatorStatusID? = nil
    ) -> NormalizedProvenanceOutcome? {
        guard let status = status ?? probes.first(where: { $0.state == state })?.status else {
            return nil
        }
        let clipped = clippedAssertionLabels

        switch state {
        case .validated:
            return NormalizedProvenanceOutcome(
                status: status,
                binding: .boundToInspectedBytes,
                failedCheck: nil,
                signerDetails: signerDetails,
                assertionLabels: clipped
            )
        case .invalid:
            let category = shape.failedCheck
            let binding: NormalizedBindingOutcome =
                category == .byteBinding && shape.binding == .boundToInspectedBytes
                ? .notBound
                : shape.binding
            return NormalizedProvenanceOutcome(
                status: status,
                binding: binding,
                failedCheck: category,
                signerDetails: signerDetails,
                assertionLabels: clipped,
                unsupportedFeatures: unsupportedFeatures
            )
        case .absent:
            return NormalizedProvenanceOutcome(
                status: status,
                binding: .notDetermined,
                failedCheck: nil
            )
        case .unsupported:
            return NormalizedProvenanceOutcome(
                status: status,
                binding: shape.binding,
                failedCheck: nil,
                signerDetails: signerDetails,
                assertionLabels: clipped,
                unsupportedFeatures: unsupportedFeatures
            )
        case .indeterminate:
            return NormalizedProvenanceOutcome(
                status: status,
                binding: shape.binding,
                failedCheck: nil,
                signerDetails: signerDetails,
                assertionLabels: clipped,
                unsupportedFeatures: unsupportedFeatures
            )
        }
    }

    /// The signer-side details this case's validator reported, unique by field.
    private var signerDetails: [NormalizedProvenanceDetail] {
        shape.reportedSignerFields.map { field in
            NormalizedProvenanceDetail(
                field: field,
                value: Sample.display(
                    "synthetic \(field.rawValue) \(shape.detailTextIndex).\(shape.seed)"
                )
            )
        }
    }

    /// The assertion labels this case's validator read, unique and in read order.
    ///
    /// Deliberately unclipped: the generated count reaches past the policy's ceiling, which
    /// is how the totality sweep reaches the ceiling refusal without constructing one.
    private var assertionLabels: [DisplaySafeText] {
        (0..<shape.reportedAssertionCount).map {
            Sample.display("synthetic assertion \($0) of \(shape.seed)")
        }
    }

    /// The same labels, clipped to the policy's declared ceiling.
    ///
    /// Used by every arm that has to isolate one condition: an assertion list already past
    /// the ceiling is itself an unanswered condition, and it would preempt the condition the
    /// arm is about. That is not a hypothetical — the first run of this file asserted the
    /// wrong refusal for six of the seven conditions until each one was isolated.
    private var clippedAssertionLabels: [DisplaySafeText] {
        Array(assertionLabels.prefix(policy.processingLimits.maximumAssertionCount.value))
    }

    /// The unsupported features this case's validator could name.
    private var unsupportedFeatures: [DisplaySafeText] {
        (0..<shape.unsupportedFeatureCount).map {
            Sample.display("synthetic feature \($0) of \(shape.seed)")
        }
    }

    // MARK: - The unanswered conditions

    /// One condition no approved input answers, and the refusal it must produce.
    private enum UnansweredCondition: String, CaseIterable {
        /// A status the policy's vocabulary does not contain.
        case unmappedStatus
        /// A validated status whose binding to the inspected bytes is not established.
        case validatedWithoutBinding
        /// An invalid status naming no failed check.
        case invalidWithoutNamedCheck
        /// A byte-binding failure that also reports an established binding.
        case byteBindingFailureThatIsAlsoBound
        /// A named failed check beside a state that is not invalid.
        case namedCheckOutsideInvalid
        /// A detail reported beside an absent state.
        case detailBesideAbsence
        /// More assertion labels than the policy's declared ceiling permits.
        case assertionsPastTheCeiling
    }

    /// The role string of the revocation probe, used to find it without spelling a state.
    private static let revocationProbeRole = "the unresolvable-revocation probe"

    /// Builds one unanswered condition and the refusal the requirements provide for it.
    private func unanswered(
        _ condition: UnansweredCondition
    ) -> (NormalizedProvenanceOutcome, ProvenanceMappingFault)? {
        func status(for state: ProvenanceStateKey) -> ProvenanceValidatorStatusID? {
            probes.first { $0.state == state }?.status
        }
        let limit = policy.processingLimits.maximumAssertionCount.value

        // Every condition but the ceiling one keeps its assertion list inside the policy's
        // ceiling, so the condition under test is the only unanswered one and the refusal
        // this arm asserts is the refusal for it.
        let within = clippedAssertionLabels

        switch condition {
        case .unmappedStatus:
            guard let unmapped = probes.first(where: { $0.state == nil })?.status,
                  let outcome = outcome(
                      status: unmapped,
                      binding: shape.binding,
                      failedCheck: nil,
                      assertionLabels: within
                  )
            else {
                return nil
            }
            return (outcome, .unmappedValidatorStatus(unmapped))

        case .validatedWithoutBinding:
            // `notBound` and `notDetermined` are different findings, so the generated one
            // is used rather than a fixed choice: neither is a cryptographic success.
            let binding: NormalizedBindingOutcome =
                shape.binding == .boundToInspectedBytes ? .notBound : shape.binding
            guard let validated = status(for: .validated),
                  let outcome = outcome(
                      status: validated,
                      binding: binding,
                      failedCheck: nil,
                      assertionLabels: within
                  )
            else {
                return nil
            }
            return (
                outcome,
                .bindingInconsistentWithMappedState(
                    status: validated,
                    state: .validated,
                    binding: binding
                )
            )

        case .invalidWithoutNamedCheck:
            guard let invalid = status(for: .invalid),
                  let outcome = outcome(
                      status: invalid,
                      binding: shape.binding,
                      failedCheck: nil,
                      assertionLabels: within
                  )
            else {
                return nil
            }
            return (outcome, .undeterminedInvalidityCategory(status: invalid))

        case .byteBindingFailureThatIsAlsoBound:
            guard let invalid = status(for: .invalid),
                  let outcome = outcome(
                      status: invalid,
                      binding: .boundToInspectedBytes,
                      failedCheck: .byteBinding,
                      assertionLabels: within
                  )
            else {
                return nil
            }
            return (
                outcome,
                .bindingInconsistentWithMappedState(
                    status: invalid,
                    state: .invalid,
                    binding: .boundToInspectedBytes
                )
            )

        case .namedCheckOutsideInvalid:
            // The state is generated from the four that are not invalid, so this condition
            // is exercised against unsupported and indeterminate — Requirements 6.13 and
            // 6.14 — as well as against validated and absent.
            let others = ProvenanceStateKey.allCases.filter { $0 != .invalid }
            let state = others[shape.bindingIndex % others.count]
            guard let target = status(for: state),
                  let outcome = outcome(
                      status: target,
                      binding: shape.binding,
                      failedCheck: shape.failedCheck,
                      assertionLabels: within
                  )
            else {
                return nil
            }
            return (
                outcome,
                .invalidityCategoryOnNonInvalidState(
                    status: target,
                    state: state,
                    category: shape.failedCheck
                )
            )

        case .detailBesideAbsence:
            // Any one of the three detail lists is enough: nothing was found, so nothing a
            // detail could describe exists. The generated field is used where the validator
            // reported one, and an unsupported feature otherwise, so the condition is
            // reachable on every case rather than only on the ones with signer details.
            guard let absent = status(for: .absent) else { return nil }
            let outcome: NormalizedProvenanceOutcome?
            if let detail = signerDetails.first {
                outcome = NormalizedProvenanceOutcome(
                    status: absent,
                    binding: .notDetermined,
                    failedCheck: nil,
                    signerDetails: [detail]
                )
            } else {
                outcome = NormalizedProvenanceOutcome(
                    status: absent,
                    binding: .notDetermined,
                    failedCheck: nil,
                    unsupportedFeatures: [
                        Sample.display("synthetic feature beside absence \(shape.seed)")
                    ]
                )
            }
            guard let outcome else { return nil }
            return (outcome, .detailsReportedForAbsentState(status: absent))

        case .assertionsPastTheCeiling:
            // One label past the declared ceiling. The state the status maps to is
            // irrelevant: a list the policy's limit forbids cannot be reported from at all.
            guard let validated = status(for: .validated) else { return nil }
            let overLimit = (0...limit).map {
                Sample.display("synthetic overflowing assertion \($0) of \(shape.seed)")
            }
            guard let outcome = NormalizedProvenanceOutcome(
                status: validated,
                binding: .boundToInspectedBytes,
                failedCheck: nil,
                assertionLabels: overLimit
            ) else {
                return nil
            }
            return (
                outcome,
                .assertionLimitExceeded(observed: overLimit.count, limit: limit)
            )
        }
    }

    // MARK: - Reading a produced state without asking it which case it is

    /// The invalidity category a state carries, or `nil` when it carries none.
    private static func invalidityCategory(of evidence: ProvenanceEvidence) -> InvalidityCategory? {
        if case let .invalid(summary) = evidence { return summary.category }
        return nil
    }

    /// The unsupported features a state names, or `nil` when it names none.
    private static func unsupportedFeatures(
        of evidence: ProvenanceEvidence
    ) -> [DisplaySafeText]? {
        if case let .unsupported(summary) = evidence { return summary.unsupportedFeatures }
        return nil
    }

    /// The validated claim summary, or `nil` for every other state.
    private static func validatedSummary(
        of evidence: ProvenanceEvidence
    ) -> ValidatedClaimSummary? {
        if case let .validated(summary) = evidence { return summary }
        return nil
    }

    /// The Provenance Policy version a state records, or `nil` when it records none.
    ///
    /// `absent` records none, because it carries no payload at all.
    private static func policyID(of evidence: ProvenanceEvidence) -> ArtifactID? {
        switch evidence {
        case let .validated(summary): return summary.provenancePolicyID
        case let .invalid(summary): return summary.provenancePolicyID
        case .absent: return nil
        case let .unsupported(summary): return summary.provenancePolicyID
        case let .indeterminate(summary): return summary.provenancePolicyID
        }
    }

    /// The approved explanation key a state carries, or `nil` when it carries none.
    private static func explanationKey(of evidence: ProvenanceEvidence) -> ApprovedCopyKey? {
        switch evidence {
        case let .invalid(summary): return summary.explanationKey
        case let .unsupported(summary): return summary.explanationKey
        case let .indeterminate(summary): return summary.explanationKey
        case .validated, .absent: return nil
        }
    }

    /// The explanation the copy binding supplies for `state`, or `nil` where the state
    /// carries no explanation of its own.
    ///
    /// Validated and absent carry none: the validated state's copy is the Approved Verdict
    /// Copy for a validated claim binding (Requirements 6.17 and 8.6) rather than a field of
    /// this summary, and absence has no payload to carry one.
    private static func expectedExplanation(
        for state: ProvenanceStateKey,
        in copy: ProvenanceCopyBinding
    ) -> ApprovedCopyKey? {
        switch state {
        case .invalid, .unsupported, .indeterminate: return copy.stateExplanations[state]
        case .validated, .absent: return nil
        }
    }
}

// MARK: - Generated artifacts

/// The synthetic artifacts one generated case is built from.
///
/// Failable rather than throwing, because every caller is inside a property body where an
/// escaping error would be discarded and the arms would pass vacuously.
///
/// **Nothing here is an approved release input.** The trust store, revocation answer,
/// supported specification and assertion labels, display allowlist, processing limits,
/// status vocabulary, resource budget reference, and feasibility decision are unresolved
/// external decisions. They exist so a seam that takes a signed artifact can be called.
private struct MappingArtifacts {
    let policy: ProvenancePolicy
    let rotatedPolicy: ProvenancePolicy
    let reversedPolicy: ProvenancePolicy
    let mapper: ProvenanceOutcomeMapper
    let rotatedMapper: ProvenanceOutcomeMapper
    let reversedMapper: ProvenanceOutcomeMapper
    let probes: [StatusProbe]

    init?(shape: MappingShape) {
        guard let probes = Self.probes(shape: shape) else { return nil }
        let mapped = probes.compactMap { probe -> ProvenanceStatusMapping? in
            guard let state = probe.state else { return nil }
            return ProvenanceStatusMapping(status: probe.status, state: state)
        }
        guard let rotatedProbes = Self.probes(shape: shape, rotationOffset: 1) else { return nil }
        let rotated = rotatedProbes.compactMap { probe -> ProvenanceStatusMapping? in
            guard let state = probe.state else { return nil }
            return ProvenanceStatusMapping(status: probe.status, state: state)
        }

        guard let policy = try? Self.policy(shape: shape, statusMappings: mapped),
              let rotatedPolicy = try? Self.policy(shape: shape, statusMappings: rotated),
              let reversedPolicy = try? Self.policy(
                  shape: shape,
                  statusMappings: mapped.reversed()
              ),
              let mapper = Self.mapper(for: policy, shape: shape),
              let rotatedMapper = Self.mapper(for: rotatedPolicy, shape: shape),
              let reversedMapper = Self.mapper(for: reversedPolicy, shape: shape)
        else {
            return nil
        }
        self.policy = policy
        self.rotatedPolicy = rotatedPolicy
        self.reversedPolicy = reversedPolicy
        self.mapper = mapper
        self.rotatedMapper = rotatedMapper
        self.reversedMapper = reversedMapper
        self.probes = probes
    }

    // MARK: The status vocabulary

    /// This case's probe statuses and their assigned states.
    ///
    /// The keys are opaque and numbered. Their spelling says nothing about the state they
    /// are assigned, and `rotationOffset` shifts the assignment, so no arm can pass by
    /// recognizing a name and the mapping under test has to come from the artifact.
    ///
    /// Four kinds of probe, each present for a reason:
    ///
    ///   * five rotated keys, one per state, so all five states are reachable under one
    ///     policy (Requirement 6.9);
    ///   * zero to three extra keys sharing the invalid state, because many library status
    ///     codes legitimately mean one state — many-to-one is expected, and it is
    ///     one-to-many that is refused;
    ///   * one key for a revocation question the validator could not resolve offline,
    ///     assigned the state the policy's own revocation behavior declares; and
    ///   * one key deliberately left out of the mapping, so the refused region has a
    ///     member on every case.
    static func probes(shape: MappingShape, rotationOffset: Int = 0) -> [StatusProbe]? {
        let states = ProvenanceStateKey.allCases
        var probes: [StatusProbe] = []

        for index in states.indices {
            guard let status = ProvenanceValidatorStatusID(
                "p20.\(shape.seed).status-\(index)"
            ) else {
                return nil
            }
            let assigned = states[(index + shape.rotation + rotationOffset) % states.count]
            probes.append(
                StatusProbe(status: status, state: assigned, role: "the status-\(index) probe")
            )
        }

        for extra in 0..<shape.extraInvalidStatusCount {
            guard let status = ProvenanceValidatorStatusID(
                "p20.\(shape.seed).also-invalid-\(extra)"
            ) else {
                return nil
            }
            probes.append(
                StatusProbe(
                    status: status,
                    state: .invalid,
                    role: "the extra-invalid-\(extra) probe"
                )
            )
        }

        guard let revocation = ProvenanceValidatorStatusID(
            "p20.\(shape.seed).revocation-answer-unavailable"
        ),
            let unmapped = ProvenanceValidatorStatusID("p20.\(shape.seed).not-in-policy")
        else {
            return nil
        }
        probes.append(
            StatusProbe(
                status: revocation,
                state: shape.revocationAnswerState,
                role: "the unresolvable-revocation probe"
            )
        )
        probes.append(
            StatusProbe(status: unmapped, state: nil, role: "the unmapped probe")
        )
        return probes
    }

    // MARK: The signed policy

    /// One candidate Provenance Policy for this case's shape and a given status mapping.
    ///
    /// Throwing rather than failable, because one arm's whole claim is that a particular
    /// mapping is *refused* and needs to read the refusal. Callers that only want a valid
    /// policy use `try?`.
    static func policy(
        shape: MappingShape,
        statusMappings: [ProvenanceStatusMapping]
    ) throws -> ProvenancePolicy {
        try ProvenancePolicy(
            id: Sample.artifact("provenance.p20.\(shape.seed)"),
            schemaVersion: .v1,
            capability: .contentCredentialValidation,
            // Fixed rather than generated: which implementation version a manifest has to
            // record is Property 19's subject, and a generated version can render as the
            // rejected `0.0.0` placeholder.
            validatorImplementationVersion: Sample.version("0.0.12"),
            validatorBinaryDigest: Sample.digest("c"),
            supportedSpecification: Sample.evidence("specification.p20.\(shape.seed)"),
            trustStore: try ProvenanceTrustStoreDescriptor(
                store: Sample.evidence("trust-store.p20.\(shape.seed)"),
                anchorCount: try PositiveCount(validating: shape.trustAnchorCount),
                isOfflineOnly: true
            ),
            revocationBehavior: try ProvenanceRevocationBehavior(
                permitsNetworkRevocationCheck: false,
                unavailableAnswerState: shape.revocationAnswerState,
                approval: Sample.approval()
            ),
            supportedAssertionLabels: [Sample.text("synthetic.assertion.\(shape.seed)")],
            displayableFields: shape.displayableFields,
            processingLimits: ProvenanceProcessingLimits(
                maximumManifestByteCount: try PositiveByteCount(validating: 65_536),
                maximumAssertionCount: try PositiveCount(validating: shape.assertionLimit),
                maximumNestingDepth: try PositiveCount(validating: 4),
                maximumProcessingDuration: try ValidatedDuration(validating: 5_000)
            ),
            resourceBudget: Sample.artifact("budget.main.p20.\(shape.seed)"),
            statusMappings: statusMappings,
            feasibilityApproval: Sample.approval()
        )
    }

    /// A mapper for `policy`, or `nil` when the policy and the copy do not agree.
    ///
    /// The copy catalogue and the detail labels come from the shared read-only samples, so
    /// the label keys the arms compare against are the binding's own rather than values
    /// this file restates.
    private static func mapper(
        for policy: ProvenancePolicy,
        shape: MappingShape
    ) -> ProvenanceOutcomeMapper? {
        guard let copy = ProvenanceCopyBinding(
            policy: policy,
            catalog: CopySample.catalog(id: "copy.p20.\(shape.seed)"),
            detailLabels: CopySample.detailLabels(for: policy)
        ) else {
            return nil
        }
        return ProvenanceOutcomeMapper(policy: policy, copy: copy)
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator produced and what the mapping actually returned, so the
/// property cannot pass by mapping one outcome a hundred times.
///
/// It also proves the run happened at all. `propertyCheck` discards an error thrown by its
/// body, so a body that failed before its first assertion — a construction that threw, a
/// generator that produced nothing usable — reports a passing test in milliseconds with
/// every arm skipped. A witness that counts cases *outside* the body is the only thing that
/// catches that, which is why the case, mapping, and completed-arm counts live here rather
/// than in an arm. A pure projection is legitimately fast, so the clock proves nothing on
/// its own and these counts are what stand in for it.
///
/// The produced-state and produced-refusal sets are the substantive half: they turn
/// "exactly one of five" from a claim about branches that were never reached into a claim
/// about outputs that were observed.
///
/// The variation thresholds are far below what 100 uniform draws produce, so they witness
/// variation rather than pinning a distribution.
private final class MappingVariationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var cases = 0
    private var completedArms = 0
    private var mappings = 0
    private var producedStates: Set<ProvenanceCategory> = []
    private var producedFaults: Set<FaultKind> = []
    private var unbuildableOutcomes = 0
    private var rotationsChangingState: Set<Bool> = []
    private var seeds: Set<Int> = []
    private var displayableFieldSets: Set<[String]> = []
    private var assertionLimits: Set<Int> = []
    private var assertionCounts: Set<Int> = []
    private var ceilingBreaches: Set<Bool> = []
    private var revocationStates: Set<ProvenanceStateKey> = []
    private var rotations: Set<Int> = []
    private var extraInvalidCounts: Set<Int> = []
    private var signerFieldSets: Set<[String]> = []
    private var unsupportedCounts: Set<Int> = []
    private var bindings: Set<NormalizedBindingOutcome> = []
    private var namedChecks: Set<InvalidityCategory> = []
    private var anchorCounts: Set<Int> = []

    func record(_ shape: MappingShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        displayableFieldSets.insert(shape.displayableFields.map(\.rawValue).sorted())
        assertionLimits.insert(shape.assertionLimit)
        assertionCounts.insert(shape.reportedAssertionCount)
        ceilingBreaches.insert(shape.breachesAssertionLimit)
        revocationStates.insert(shape.revocationAnswerState)
        rotations.insert(shape.rotation)
        extraInvalidCounts.insert(shape.extraInvalidStatusCount)
        signerFieldSets.insert(shape.reportedSignerFields.map(\.rawValue))
        unsupportedCounts.insert(shape.unsupportedFeatureCount)
        bindings.insert(shape.binding)
        namedChecks.insert(shape.failedCheck)
        anchorCounts.insert(shape.trustAnchorCount)
    }

    /// Records one mapping's answer, whichever answer it was.
    func recordProduced(_ answer: MappingAnswer) {
        lock.lock()
        defer { lock.unlock() }
        mappings += 1
        switch answer {
        case let .state(evidence): producedStates.insert(evidence.category)
        case let .fault(fault): producedFaults.insert(FaultKind.of(fault))
        }
    }

    /// Records that the normalized contract refused to build an input this file described.
    ///
    /// Never a finding about the mapping: the details here are built unique and
    /// display-safe, so a refusal is a defect in this file, and it is counted so a run whose
    /// inputs quietly stopped being buildable fails outside the body rather than shrinking
    /// its own coverage.
    func recordUnbuildableOutcome() {
        lock.lock()
        defer { lock.unlock() }
        unbuildableOutcomes += 1
    }

    /// Records whether one policy rotation moved a produced state.
    func recordRotation(changedState: Bool) {
        lock.lock()
        defer { lock.unlock() }
        rotationsChangingState.insert(changedState)
    }

    /// Called at the end of the body, so a case that stopped early is countable.
    func recordCompletedArms() {
        lock.lock()
        defer { lock.unlock() }
        completedArms += 1
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases; ran \(cases)")
        #expect(
            completedArms == cases,
            "\(cases - completedArms) of \(cases) cases did not reach the end of the body"
        )
        // The totality arm alone maps at least seven statuses against three bindings and
        // four named-check values, so a case performs well over a hundred mappings. The
        // floor is far below that so it does not pin an arm's internal loop, but far enough
        // above zero that a run which only built policies fails here rather than passing.
        #expect(mappings >= 5_000, "mappings performed: \(mappings)")
        #expect(
            unbuildableOutcomes == 0,
            "\(unbuildableOutcomes) described outcomes could not be built at all"
        )

        // The substantive half: every state and every refusal was produced, not merely
        // offered. Without this, "exactly one of five" could hold because four of the five
        // were never reached.
        let unreachedStates = Set(ProvenanceCategory.allCases).subtracting(producedStates)
        #expect(
            producedStates == Set(ProvenanceCategory.allCases),
            "states never produced: \(unreachedStates.map(\.rawValue).sorted())"
        )
        let unreachedFaults = Set(FaultKind.allCases).subtracting(producedFaults)
        #expect(
            producedFaults == Set(FaultKind.allCases),
            "refusals never produced: \(unreachedFaults.map(\.rawValue).sorted())"
        )
        // A rotation that never moved a state would make the policy-driven arm vacuous.
        #expect(
            rotationsChangingState.contains(true),
            "rotating the policy never moved a produced state"
        )

        // The generated baseline actually varied.
        #expect(seeds.count >= 50, "generated seeds: \(seeds.count)")
        // 31 nonempty subsets are reachable; a constant allowlist shows 1.
        #expect(
            displayableFieldSets.count >= 15,
            "generated allowlists: \(displayableFieldSets.count)"
        )
        #expect(
            assertionLimits.count >= 6,
            "generated assertion ceilings: \(assertionLimits.count)"
        )
        #expect(assertionCounts.count >= 8, "generated assertion counts: \(assertionCounts.count)")
        #expect(
            ceilingBreaches == [false, true],
            "the reported assertion count reached only one side of the ceiling"
        )
        #expect(
            revocationStates == Set(MappingShape.admissibleRevocationStates),
            "generated revocation answers: \(revocationStates.map(\.rawValue).sorted())"
        )
        #expect(
            rotations == Set(0..<ProvenanceStateKey.allCases.count),
            "generated rotations: \(rotations.sorted())"
        )
        #expect(
            extraInvalidCounts == [0, 1, 2, 3],
            "generated extra invalid statuses: \(extraInvalidCounts.sorted())"
        )
        // 16 subsets of the four signer-capable fields are reachable.
        #expect(
            signerFieldSets.count >= 8,
            "generated signer detail sets: \(signerFieldSets.count)"
        )
        #expect(
            unsupportedCounts == [0, 1, 2, 3],
            "generated feature counts: \(unsupportedCounts.sorted())"
        )
        #expect(
            bindings == Set(NormalizedBindingOutcome.allCases),
            "generated bindings: \(bindings.map(\.rawValue).sorted())"
        )
        #expect(
            namedChecks == Set(InvalidityCategory.allCases),
            "generated named checks: \(namedChecks.map(\.rawValue).sorted())"
        )
        #expect(anchorCounts.count >= 8, "generated trust anchor counts: \(anchorCounts.count)")
    }
}
