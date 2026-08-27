import DefAIkeTestSupport
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain

// Design Property 32: device validation plans and result records are referentially
// complete.
//
// The design states it as: for any candidate device plan, capability set, fixture
// inventory, and result record, validation may start only when the plan predeclares every
// required reference, metric, tolerance, expected category, condition, and missing-result
// rule; a result is admissible only when it records every required identity,
// implementation version, measured value, categorical comparison, and pass/fail result,
// including all required provenance fixture families when provenance is enabled.
//
// ## What "referentially complete" means here
//
// Two halves, and they are enforced by two different types. ``ValidatedResourcePlan``
// decides whether validation may start; ``AdmissibleDeviceValidationResult`` decides
// whether what came back answers the plan that predeclared it. Neither can be reached
// without the other, so the property quantifies over both together:
//
//   * every reference a plan carries names evidence this release holds, **at the cited
//     version and content digest**. A reference to content the release does not carry is
//     not a reference, and neither is a reference to the right artifact at the wrong
//     version;
//   * every recorded result answers a predeclared measurement, against the limit and the
//     summary statistic the plan declared, citing that plan as its specification;
//   * the category of each metric — categorical or numeric — is total over both metric
//     vocabularies and decides which acceptance rule, which limit kind, and which
//     expected fixture outcome are admissible, in both directions;
//   * every identity and version the result records is the release's own: another plan,
//     bundle, fixture suite, capability manifest, capability set, application build, or
//     configuration is refused;
//   * a conditional gate's applicability follows the compiled capability set in both
//     directions — applicable when the capability is present, waived when it is absent —
//     at the plan layer (the fixture suite) and at the result layer (the gate record);
//   * the capability, fixture, gate, candidate, and measurement inventories are exact:
//     missing, extra, and duplicate entries are all refused or reported.
//
// ## What this file deliberately does not assert, and why
//
//   * **Property 28's statement.** ``ResourcePlanAuthorityPropertyTests`` already
//     quantifies budget and plan *completeness and authority*: a missing required metric,
//     measurement, condition, or comparison; a placeholder token; a nonpositive limit or
//     sample count; a cross-target budget or measurement; and the plan being the only
//     source of a limit. None of that is repeated here. This property is the *referential*
//     statement — that what the plan and its results point at exists, at the version and
//     content cited, and that the inventories are exact.
//   * **A result specification's version and digest.** A recorded result cites its
//     specification as an ``EvidenceSource``, and admission compares only the artifact
//     identifier against the plan. Confirmed by experiment: a measurement citing this
//     plan's identifier at another version *and* another content digest is admitted. That
//     is a narrower binding than the four references the plan resolves through the
//     evidence index, and asserting otherwise would invent a rule rather than quantify
//     one, so it is recorded here instead.
//   * **Capability implementation version *values*.** The result's version tuple requires
//     one entry per enabled capability, which is asserted here. Whether those versions are
//     the ones the release compiled is checked where the running build is known, and
//     Property 1 quantifies it at that layer.
//   * **An extra recorded comparison.** Admission iterates the plan's predeclared
//     comparisons and requires a result for each, so a result carrying a comparison the
//     plan did not predeclare is accepted — confirmed by experiment with a pixel-only
//     release whose result recorded a provenance-state comparison. That matches the design
//     statement, which is completeness of the required set rather than exactness of the
//     recorded set.
//
// No value here is an approved device, budget, limit, tolerance, fixture, capability
// version, or decision. Every identifier carries the generated seed, every number comes
// from a synthetic range, and the whole shape exists so that validation can be asked to
// refuse it.

extension Tag {
    /// Design Property 32.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property32PlanAndResultCompleteness: Self
}

@Suite(
    "Property 32: device validation plans and result records are referentially complete",
    .tags(.property32PlanAndResultCompleteness)
)
struct DeviceValidationCompletenessPropertyTests {
    /// Runs at the library default of 100 generated cases with shrinking, which is the
    /// minimum the design requires; `PropertyToolchainWiringTests` pins that default.
    /// Every generator is composed with `zip`, so the shrinkers compose.
    ///
    /// **Validates: Requirements 13.1, 13.3, 13.5, 13.17**
    @Test("Plans and results are referentially complete over generated inventories")
    func plansAndResultsAreReferentiallyComplete() async {
        let witness = PlanCompletenessVariationWitness()

        await propertyCheck(input: PlanCompletenessShape.generator) { shape in
            witness.record(shape)

            // The coherent baseline is built once per case and every arm mutates one table
            // and rebuilds from it, so a mutation cannot leave two artifacts disagreeing
            // about anything except the one thing the arm is about — and so a case pays for
            // one plan, one fixture inventory, and one result set rather than one per arm.
            let scenario: PlanCompletenessScenario
            do {
                scenario = try PlanCompletenessScenario(shape: shape)
            } catch {
                Issue.record(
                    "a coherent generated plan or result was refused: \(error) [\(shape)]"
                )
                return
            }
            witness.recordBaseline(scenario)

            scenario.checkCoherentPlanAndResultAreReferentiallyComplete()
            scenario.checkEveryPlanReferenceResolvesAtItsCitedVersionAndContent()
            scenario.checkRecordedMeasurementsAnswerThePlan()
            scenario.checkCategoryAssignmentsAreExactAndTotal()
            scenario.checkRecordedVersionsAreBinding()
            scenario.checkProvenanceApplicabilityFollowsTheCapabilitySet()
            scenario.checkInventoriesAreExact()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - Generated shape

/// One target and one metric. Metric sets differ per target and the two targets share
/// four metrics, so the pair is the key every limit, specification, and record is indexed
/// by.
private struct TargetMetric: Hashable, Sendable {
    let target: ExecutionTarget
    let metric: ResourceMetric
}

/// Which index-resolved reference site an arm moves off the release.
///
/// Enumerated rather than listed as strings so the field an arm asserts is derived from
/// the same value that chose the mutation.
private enum ReferenceSite: CaseIterable, Sendable {
    case planApproval
    case comparisonReference
    case measurementWorkload
    case measurementConditions
}

/// One candidate iPhone configuration, as plain data.
private struct DeviceShape: Sendable {
    let hardwareDigit: Int
    let osMinor: Int
    let osPatch: Int
}

/// One generated numeric limit magnitude.
///
/// Split into a whole part and thousandths so generated limits are exact non-integer
/// decimals: a limit that only ever landed on an integer would not exercise the exact
/// decimal equality a recorded result has to reproduce.
private struct Magnitude: Sendable {
    let whole: Int
    let thousandths: Int

    var value: Decimal { Decimal(whole) + Decimal(thousandths) / 1_000 }
}

/// Three offsets in thousandths that place a measurement's samples and its summary.
///
/// Used ascending, so the summary always lies inside the sample range and, for a numeric
/// metric, strictly inside the declared limit. Both are *derived* rather than generated:
/// a generated summary outside its samples, or above its limit, would fail admission for
/// a reason this property is not about.
private struct SampleOffsets: Sendable {
    let first: Int
    let second: Int
    let third: Int

    var ascending: [Int] { [first, second, third].sorted() }
}

/// The acceptance rule a generated comparison declares, and what the run measured.
///
/// The tolerance and the observed deviation come from the same pair of draws — the larger
/// is the tolerance, the smaller is the deviation — so a coherent comparison always
/// satisfies its own rule and no generated case fails for that reason.
private struct ComparisonShape: Sendable {
    let toleranceKindIndex: Int
    let toleranceFirst: Int
    let toleranceSecond: Int
    let agreementThousandths: Int
    let extraComparedFixtures: Int
}

/// The measurement method Requirement 11.4 requires every measurement to declare.
private struct MethodShape: Sendable {
    let sampleCount: Int
    let statisticIndex: Int
    let concurrent: Bool
    let pluggedIn: Bool
    let startingThermalIndex: Int
}

/// Which member of each enumerable set a mutation arm breaks.
///
/// Generated rather than enumerated so the shrinker can reduce a failing arm to one
/// metric, family, or gate, and so 100 cases spread across the sets instead of every case
/// paying for all of them.
private struct Selectors: Sendable {
    let referenceSite: Int
    let target: Int
    let metric: Int
    let numericMetric: Int
    let comparison: Int
    let family: Int
    let gate: Int
    let device: Int
}

/// Everything the plan and result layers read, as plain data.
///
/// The generator produces data only. Artifacts are built from it inside the property
/// body, where a construction that unexpectedly throws is recorded as a failure rather
/// than escaping: `propertyCheck` discards an error thrown by its body, so a refusal that
/// escaped as a throw would pass vacuously.
///
/// ## How the baseline varies
///
/// A property whose baseline is one constant with a mutation applied asserts one example
/// a hundred times over, so every dimension the arms depend on is generated:
///
///   * every numeric limit is its own generated exact decimal, one per
///     `(target, metric)` pair, so the two targets carry different numbers for the four
///     metrics they share;
///   * the sample range and summary of every recorded measurement, as offsets below that
///     metric's own limit;
///   * every comparison's tolerance kind, tolerance, observed deviation, required
///     agreement ratio, and compared fixture count;
///   * both capability sets, which changes the required comparison set, the required
///     fixture families, whether the conditional gate applies, and the capability
///     inventory the version tuple has to carry;
///   * one or two candidate configurations, each with its own hardware identifier and
///     operating-system version. Kept small on purpose: a plan carries a measurement for
///     every candidate, target, and metric, so candidate count multiplies this property's
///     whole cost;
///   * sample count, summary statistic, branch execution, starting thermal state, and
///     starting power condition;
///   * every identifier, version, and content digest, from ``seed``. Deriving the whole
///     reference set from one number keeps it coherent without a cross-reference table
///     while still varying each reference between cases.
///
/// ``PlanCompletenessVariationWitness`` checks after the run that this actually happened.
private struct PlanCompletenessShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic identifier, version, and digest, so the whole reference set
    /// varies together and stays coherent without a cross-reference table.
    let seed: Int

    let provenanceEnabled: Bool
    let devices: [DeviceShape]

    /// One magnitude per numeric `(target, metric)` pair, in ``numericPairs`` order.
    let magnitudes: [Magnitude]

    /// One thermal ceiling per target, never `critical`.
    let thermalCeilings: [ThermalState]

    let samples: SampleOffsets
    let comparison: ComparisonShape
    let method: MethodShape
    let selectors: Selectors

    /// Thermal ceilings a limit may carry. `critical` admits every observation, so it is
    /// not a limit; ``ResourcePlanAuthorityPropertyTests`` asserts that refusal.
    static let admissibleThermalStates: [ThermalState] = [.nominal, .fair, .serious]

    /// Every numeric `(target, metric)` pair a plan has to measure, in a fixed order so a
    /// generated magnitude array indexes into it deterministically.
    static let numericPairs: [TargetMetric] = ExecutionTarget.allCases.flatMap { target in
        ResourceMetric.requiredMetrics(for: target)
            .filter { !$0.isCategorical }
            .sorted { $0.rawValue < $1.rawValue }
            .map { TargetMetric(target: target, metric: $0) }
    }

    /// The tolerance kind every numeric comparison in this case declares.
    var toleranceKind: ToleranceKind {
        ToleranceKind.allCases[comparison.toleranceKindIndex % ToleranceKind.allCases.count]
    }

    var description: String {
        """
        seed \(seed), \(devices.count) candidate(s), provenance \(provenanceEnabled), \
        offsets \(samples.ascending), tolerance kind \(toleranceKind.rawValue)
        """
    }

    // MARK: Generators

    static var generator: Generator<PlanCompletenessShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.bool,
            devices,
            magnitudes,
            thermalCeilings,
            sampleOffsets,
            comparison,
            method,
            selectors
        )
        .map { raw in
            PlanCompletenessShape(
                seed: raw.0,
                provenanceEnabled: raw.1,
                devices: raw.2,
                magnitudes: raw.3,
                thermalCeilings: raw.4,
                samples: raw.5,
                comparison: raw.6,
                method: raw.7,
                selectors: raw.8
            )
        }
        .eraseToAny()
    }

    private static var devices: Generator<[DeviceShape], AnySequence<Any>> {
        zip(Gen.int(in: 0...9), Gen.int(in: 0...9), Gen.int(in: 0...9))
            .map { DeviceShape(hardwareDigit: $0.0, osMinor: $0.1, osPatch: $0.2) }
            .array(of: 1...2)
            .eraseToAny()
    }

    private static var magnitudes: Generator<[Magnitude], AnySequence<Any>> {
        zip(Gen.int(in: 1_000...1_000_000), Gen.int(in: 0...999))
            .map { Magnitude(whole: $0.0, thousandths: $0.1) }
            .array(of: numericPairs.count)
            .eraseToAny()
    }

    private static var thermalCeilings: Generator<[ThermalState], AnySequence<Any>> {
        Gen.int(in: 0...(admissibleThermalStates.count - 1))
            .map { admissibleThermalStates[$0] }
            .array(of: ExecutionTarget.allCases.count)
            .eraseToAny()
    }

    private static var sampleOffsets: Generator<SampleOffsets, AnySequence<Any>> {
        zip(Gen.int(in: 0...999), Gen.int(in: 0...999), Gen.int(in: 0...999))
            .map { SampleOffsets(first: $0.0, second: $0.1, third: $0.2) }
            .eraseToAny()
    }

    private static var comparison: Generator<ComparisonShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...(ToleranceKind.allCases.count - 1)),
            Gen.int(in: 0...999),
            Gen.int(in: 0...999),
            Gen.int(in: 0...1_000),
            Gen.int(in: 0...63)
        )
        .map {
            ComparisonShape(
                toleranceKindIndex: $0.0,
                toleranceFirst: $0.1,
                toleranceSecond: $0.2,
                agreementThousandths: $0.3,
                extraComparedFixtures: $0.4
            )
        }
        .eraseToAny()
    }

    private static var method: Generator<MethodShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 1...50),
            Gen.int(in: 0...(SummaryStatistic.allCases.count - 1)),
            Gen.bool,
            Gen.bool,
            Gen.int(in: 0...(admissibleThermalStates.count - 1))
        )
        .map {
            MethodShape(
                sampleCount: $0.0,
                statisticIndex: $0.1,
                concurrent: $0.2,
                pluggedIn: $0.3,
                startingThermalIndex: $0.4
            )
        }
        .eraseToAny()
    }

    private static var selectors: Generator<Selectors, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...99),
            Gen.int(in: 0...99),
            Gen.int(in: 0...99),
            Gen.int(in: 0...99),
            Gen.int(in: 0...99),
            Gen.int(in: 0...99),
            Gen.int(in: 0...99),
            Gen.int(in: 0...99)
        )
        .map {
            Selectors(
                referenceSite: $0.0,
                target: $0.1,
                metric: $0.2,
                numericMetric: $0.3,
                comparison: $0.4,
                family: $0.5,
                gate: $0.6,
                device: $0.7
            )
        }
        .eraseToAny()
    }
}

// MARK: - Scenario

/// A generated shape and the coherent artifacts built from it.
///
/// Built once per case. Every heavy artifact — the fixture inventory, the plan, the
/// activated plan, the result set — is stored rather than recomputed, and every mutation
/// arm starts from a stored table so the only difference between the baseline and a
/// mutation is the one field the arm is about.
private struct PlanCompletenessScenario {
    let shape: PlanCompletenessShape

    /// Builds artifacts from the shape. Stored rather than recreated per access: it caches
    /// the whole validated identifier, version, and digest set for the case.
    let builder: PlanCompletenessBuilder

    // Baseline artifacts, all coherent with each other.
    let candidates: [CandidateDeviceConfiguration]
    let limits: [TargetMetric: ValidatedLimit]
    let comparisonSpecifications: [ComparisonMetric: ComparisonSpecification]

    /// Predeclared measurements, per candidate offset.
    let measurementSpecifications: [[TargetMetric: ResourceMeasurementSpecification]]

    let fixtures: [FixtureRecord]

    /// The inventory without its provenance families, and the six provenance families on
    /// their own. Split once, because the applicability and inventory arms recombine them
    /// several times each and this inventory is a hundred records long.
    let unconditionalFixtures: [FixtureRecord]
    let provenanceFixtures: [FixtureRecord]

    let suite: ReleaseFixtureSuite
    let manifest: ReleaseCapabilityManifest
    let index: ReleaseEvidenceIndex
    let budgets: ResourceBudgetSet
    let plan: DeviceValidationPlan
    let activated: ValidatedResourcePlan

    let versionTuple: ValidationVersionTuple
    let measurementRecords: [TargetMetric: MeasurementRecord]
    let comparisonRecords: [ComparisonMetric: ComparisonRecord]
    let resultSet: DeviceValidationResultSet
    let admitted: AdmissibleDeviceValidationResult

    // MARK: Construction

    init(shape: PlanCompletenessShape) throws {
        let builder = PlanCompletenessBuilder(shape: shape)

        // Locals throughout, so no closure captures a partly initialized `self`.
        let candidates = try builder.candidates()
        let limits = try builder.limits()
        let comparisons = try builder.comparisonSpecifications()
        var specifications: [[TargetMetric: ResourceMeasurementSpecification]] = []
        for candidate in candidates {
            specifications.append(
                try builder.measurementSpecifications(for: candidate, limits: limits)
            )
        }
        let unconditionalFixtures = try builder.unconditionalFixtures()
        let provenanceFixtures = try builder.provenanceFixtures()
        let fixtures = shape.provenanceEnabled
            ? unconditionalFixtures + provenanceFixtures
            : unconditionalFixtures
        let suite = try builder.suite(fixtures: fixtures)
        let manifest = try builder.capabilityManifest()
        let index = try builder.evidenceIndex()
        let budgets = try builder.budgets(limits: limits)
        let plan = try builder.plan(
            candidates: candidates,
            comparisons: builder.ordered(comparisons),
            measurements: builder.ordered(specifications)
        )
        let activated = try ValidatedResourcePlan(
            activating: plan,
            budgets: budgets,
            fixtureSuite: suite,
            capabilityManifest: manifest,
            evidence: index
        )

        let offset = builder.resultCandidateOffset(candidates)
        let versionTuple = try builder.versionTuple()
        let measurementRecords = try builder.measurementRecords(
            specifications: specifications[offset]
        )
        let comparisonRecords = try builder.comparisonRecords(specifications: comparisons)
        let resultSet = try builder.resultSet(
            configuration: candidates[offset],
            versionTuple: versionTuple,
            gateResults: try builder.gateRecords(
                measurements: measurementRecords,
                comparisons: comparisonRecords
            )
        )

        self.shape = shape
        self.builder = builder
        self.candidates = candidates
        self.limits = limits
        self.comparisonSpecifications = comparisons
        self.measurementSpecifications = specifications
        self.fixtures = fixtures
        self.unconditionalFixtures = unconditionalFixtures
        self.provenanceFixtures = provenanceFixtures
        self.suite = suite
        self.manifest = manifest
        self.index = index
        self.budgets = budgets
        self.plan = plan
        self.activated = activated
        self.versionTuple = versionTuple
        self.measurementRecords = measurementRecords
        self.comparisonRecords = comparisonRecords
        self.resultSet = resultSet
        self.admitted = try AdmissibleDeviceValidationResult(
            admitting: resultSet,
            under: activated
        )
    }

    // MARK: Selections

    /// The configuration the generated result set describes.
    var resultConfiguration: CandidateDeviceConfiguration {
        candidates[builder.resultCandidateOffset(candidates)]
    }

    var selectedTarget: ExecutionTarget {
        ExecutionTarget.allCases[shape.selectors.target % ExecutionTarget.allCases.count]
    }

    /// The required metric of ``selectedTarget`` this case's arms break.
    var selectedMetric: TargetMetric {
        let metrics = PlanCompletenessBuilder.requiredMetrics(selectedTarget)
        return TargetMetric(
            target: selectedTarget,
            metric: metrics[shape.selectors.metric % metrics.count]
        )
    }

    /// The required *numeric* metric of ``selectedTarget``, for arms that need a limit
    /// that can be moved by a decimal amount.
    var selectedNumericMetric: TargetMetric {
        let metrics = PlanCompletenessBuilder.requiredMetrics(selectedTarget)
            .filter { !$0.isCategorical }
        return TargetMetric(
            target: selectedTarget,
            metric: metrics[shape.selectors.numericMetric % metrics.count]
        )
    }

    var selectedComparison: ComparisonMetric {
        let metrics = builder.requiredComparisons.sorted { $0.rawValue < $1.rawValue }
        return metrics[shape.selectors.comparison % metrics.count]
    }

    var selectedFamily: FixtureFamily {
        let families = FixtureFamily.allCases.sorted { $0.rawValue < $1.rawValue }
        return families[shape.selectors.family % families.count]
    }

    var selectedGate: DeviceGate {
        let gates = DeviceGate.mandatoryGates.sorted { $0.rawValue < $1.rawValue }
        return gates[shape.selectors.gate % gates.count]
    }

    var selectedReferenceSite: ReferenceSite {
        ReferenceSite.allCases[shape.selectors.referenceSite % ReferenceSite.allCases.count]
    }

    // MARK: - Valid arm

    /// A complete, coherent plan and result set validate and admit, and everything they
    /// report is exactly what the shape generated.
    ///
    /// Without this arm the property would pass by refusing everything. It also pins the
    /// two arrangement invariants the mutation arms depend on: the gate table covers each
    /// target's required metric set exactly once, and every recorded comparison is one the
    /// plan predeclared. A metric or comparison added to either vocabulary fails these
    /// rather than being silently skipped.
    func checkCoherentPlanAndResultAreReferentiallyComplete() {
        // Requirement 13.3: the plan predeclares its references, comparison metrics,
        // tolerances, expected categories, conditions, and missing-result rule.
        #expect(activated.id == builder.planID)
        #expect(activated.enablesProvenance == shape.provenanceEnabled)
        #expect(activated.missingResultRule == .treatAsFailure)
        #expect(
            Set(plan.comparisons.map(\.metric)) == builder.requiredComparisons,
            "the plan predeclares exactly the required comparison set"
        )
        for metric in builder.requiredComparisons {
            guard let declared = activated.plan.comparison(for: metric) else {
                Issue.record("the plan omits the \(metric.rawValue) comparison [\(shape)]")
                continue
            }
            // The declared acceptance rule is the generated one, unchanged: a categorical
            // comparison carries an agreement ratio and no tolerance, a numeric one the
            // reverse.
            #expect(declared.tolerance == comparisonSpecifications[metric]?.tolerance)
            #expect(
                declared.requiredAgreement == comparisonSpecifications[metric]?.requiredAgreement
            )
            #expect(declared.reference == builder.referenceEvidence)
        }

        // Requirement 13.1: each candidate is enumerated by model, hardware identifier,
        // operating-system version, and application build.
        #expect(activated.candidateConfigurations.count == shape.devices.count)
        for (offset, configuration) in activated.candidateConfigurations.enumerated() {
            #expect(configuration.hardwareIdentifier == builder.hardware(offset))
            #expect(configuration.osVersion == builder.osVersion(offset))
            #expect(configuration.appBuild == builder.appBuildID)
            #expect(configuration.deviceModel == builder.deviceModel(offset))
            #expect(configuration.isAppleNeuralEngineCapable)
        }

        // Requirements 13.4 and 13.5: the fixture inventory is complete for this
        // capability set, and the required family set follows the vocabulary rather than a
        // list written here.
        let missingFamilies = suite.missingFamilies
        let parityComplete = suite.hasCompleteModelParityCoverage
        let requiredFamilies = suite.requiredFamilies
        #expect(
            missingFamilies.isEmpty,
            "generated fixture inventory is short of \(missingFamilies.map(\.rawValue).sorted())"
        )
        #expect(parityComplete)
        #expect(
            requiredFamilies
                == (shape.provenanceEnabled
                    ? Set(FixtureFamily.allCases)
                    : FixtureFamily.unconditionalFamilies)
        )

        // Requirement 13.17: the result records every required identity, implementation
        // version, measured value, categorical comparison, and pass or fail result.
        #expect(admitted.plan == builder.planID)
        #expect(admitted.configuration == resultConfiguration)
        #expect(admitted.results.versionTuple == versionTuple)
        #expect(admitted.results.isPhysicalDeviceEvidence)
        #expect(admitted.satisfiesEveryMandatoryGate)
        #expect(admitted.results.unsatisfiedGates.isEmpty)
        #expect(
            admitted.results.versionTuple.capabilities == builder.capabilities,
            "the recorded capability set is the generated one"
        )
        #expect(
            Set(admitted.results.versionTuple.capabilityImplementationVersions.map(\.capability))
                == builder.capabilities,
            "one recorded implementation version per enabled capability"
        )

        let recorded = admitted.results.gateResults.flatMap(\.measurements)
        for target in ExecutionTarget.allCases {
            let own = recorded.filter { $0.target == target }
            #expect(
                Set(own.map(\.metric)) == ResourceMetric.requiredMetrics(for: target),
                "\(target.rawValue) records exactly its own metric set"
            )
            #expect(
                own.count == ResourceMetric.requiredMetrics(for: target).count,
                "\(target.rawValue) records each metric once"
            )
        }
        for (key, record) in measurementRecords {
            #expect(record.limit == limits[key], "\(key.target.rawValue)/\(key.metric.rawValue)")
            #expect(record.summaryStatistic == builder.summaryStatistic)
            #expect(record.outcome == .passed)
            #expect(record.summaryValue == builder.summary(for: limits[key]!))
            #expect(record.rawValues == builder.rawValues(for: limits[key]!))
        }

        let recordedComparisons = admitted.results.gateResults.flatMap(\.comparisons)
        #expect(
            Set(recordedComparisons.map(\.metric)).isSubset(of: builder.requiredComparisons),
            "every recorded comparison is one the plan predeclared"
        )
        #expect(
            builder.requiredComparisons.isSubset(of: Set(recordedComparisons.map(\.metric))),
            "every predeclared comparison has a recorded result"
        )
        for (metric, record) in comparisonRecords {
            #expect(record.outcome == .passed, "\(metric.rawValue)")
            #expect(record.comparedFixtureCount.value == builder.comparedFixtureCount)
            #expect(record.agreeingFixtureCount == record.comparedFixtureCount)
            #expect(
                record.maximumDeviation?.value == (metric.isCategorical ? nil : builder.deviation)
            )
        }
    }

    // MARK: - Reference arm

    /// Every reference the plan carries names evidence this release holds, at the cited
    /// version and at the cited content digest.
    ///
    /// The artifact-absent form of this is Property 28's; what is asserted here is the two
    /// forms that a general "does the artifact exist" check cannot see. A reference to the
    /// right artifact at the wrong version, or at the right version with other content, is
    /// a reference to content this release does not carry — and it is a different audit
    /// finding from a reference to nothing, which is why the field is asserted too.
    ///
    /// One site per case, over the four sites a plan's references resolve at, so 100 cases
    /// cover all four and no case pays for four activations.
    func checkEveryPlanReferenceResolvesAtItsCitedVersionAndContent() {
        let site = selectedReferenceSite
        let field = referenceField(site)

        expectRefused(
            "a \(field) citing another version of the same artifact",
            .inconsistentReference,
            reportedField: "\(field).version"
        ) {
            _ = try self.activate(replacing: site) {
                EvidenceSource(
                    artifact: $0.artifact,
                    version: self.builder.otherVersion,
                    contentDigest: $0.contentDigest
                )
            }
        }

        expectRefused(
            "a \(field) citing other content at the same version",
            .inconsistentReference,
            reportedField: "\(field).contentDigest"
        ) {
            _ = try self.activate(replacing: site) {
                EvidenceSource(
                    artifact: $0.artifact,
                    version: $0.version,
                    contentDigest: self.builder.otherContentDigest
                )
            }
        }

        // The result side cites its specification by artifact identity rather than through
        // the evidence index, so the corresponding statement is that the specification is
        // *this* plan. A result recorded against some other predeclaration is not this
        // plan's evidence.
        let key = selectedMetric
        let measurementField =
            "results.measurements[\(key.target.rawValue)/\(key.metric.rawValue)].specification"
        expectRefused(
            "a recorded measurement citing another specification",
            .inconsistentReference,
            reportedField: measurementField
        ) {
            var records = self.measurementRecords
            records[key] = try self.builder.measurementRecord(
                key,
                limit: self.limits[key]!,
                specification: self.builder.evidence(self.builder.otherPlanID)
            )
            _ = try self.admit(measurements: records)
        }

        let comparison = selectedComparison
        expectRefused(
            "a recorded comparison citing another specification",
            .inconsistentReference,
            reportedField: "results.comparisons[\(comparison.rawValue)].specification"
        ) {
            var records = self.comparisonRecords
            records[comparison] = try self.builder.comparisonRecord(
                comparison,
                specification: self.builder.evidence(self.builder.otherPlanID)
            )
            _ = try self.admit(comparisons: records)
        }
    }

    /// The field an unresolvable reference at one site is reported at.
    ///
    /// Derived from the same value that selects the mutation, so the two cannot drift.
    private func referenceField(_ site: ReferenceSite) -> String {
        switch site {
        case .planApproval:
            "plan.approval.source"
        case .comparisonReference:
            "plan.comparisons[\(selectedComparison.rawValue)].reference"
        case .measurementWorkload:
            "plan.measurements[\(selectedMetric.target.rawValue)/\(selectedMetric.metric.rawValue)"
                + "/\(resultConfiguration.hardwareIdentifier.rawValue)].workload"
        case .measurementConditions:
            "budgets.\(selectedMetric.target.rawValue)"
                + ".hardLimits[\(selectedMetric.metric.rawValue)].measurementConditions"
        }
    }

    // MARK: - Measurement arm

    /// Every predeclared measurement has a recorded result, and that result was taken
    /// against the contract the plan predeclared.
    ///
    /// Four forms, and they are different faults at the same position: the record is gone;
    /// the record is present but records that nothing ran; the record was taken against
    /// another limit; the record was summarized by another statistic. The last two are what
    /// "measures something the plan did not predeclare" means for a result — the number
    /// exists, but nothing predeclared the contract it was judged against.
    func checkRecordedMeasurementsAnswerThePlan() {
        let key = selectedMetric
        let position = "results.measurements[\(key.target.rawValue)/\(key.metric.rawValue)]"

        expectRefused(
            "a plan measurement with no recorded result",
            .missingRequiredEntries,
            reportedField: position
        ) {
            var records = self.measurementRecords
            records.removeValue(forKey: key)
            _ = try self.admit(measurements: records)
        }

        expectRefused(
            "a recorded measurement that did not execute",
            .missingRequiredEntries,
            reportedField: position
        ) {
            var records = self.measurementRecords
            records[key] = try self.builder.measurementRecord(
                key,
                limit: self.limits[key]!,
                outcome: .notExecuted
            )
            _ = try self.admit(measurements: records)
        }

        let numeric = selectedNumericMetric
        let numericPosition =
            "results.measurements[\(numeric.target.rawValue)/\(numeric.metric.rawValue)]"
        expectRefused(
            "a measurement taken against a limit the plan did not declare",
            .inconsistentReference,
            reportedField: "\(numericPosition).limit"
        ) {
            var records = self.measurementRecords
            // One decimal above the declared ceiling: still a limit the summary satisfies,
            // so the refusal is about the contract rather than about a breach.
            records[numeric] = try self.builder.measurementRecord(
                numeric,
                limit: .numeric(
                    value: try PositiveDecimal(
                        validating: self.builder.magnitude(for: numeric)! + 1
                    ),
                    unit: numeric.metric.requiredUnit!
                ),
                summaryLimit: self.limits[numeric]!
            )
            _ = try self.admit(measurements: records)
        }

        expectRefused(
            "a measurement summarized by a statistic the plan did not declare",
            .inconsistentReference,
            reportedField: "\(position).summaryStatistic"
        ) {
            var records = self.measurementRecords
            records[key] = try self.builder.measurementRecord(
                key,
                limit: self.limits[key]!,
                summaryStatistic: self.builder.otherSummaryStatistic
            )
            _ = try self.admit(measurements: records)
        }

        // Requirement 13.17 also requires a recorded comparison for every predeclared
        // one, and a numeric comparison with no measured deviation records no measured
        // value at all.
        let comparison = selectedComparison
        expectRefused(
            "a predeclared \(comparison.rawValue) comparison with no recorded result",
            .missingRequiredEntries,
            reportedField: "results.comparisons[\(comparison.rawValue)]"
        ) {
            _ = try self.admit(omittingComparison: comparison)
        }
    }

    // MARK: - Category arm

    /// The categorical-or-numeric category of every metric is total, and it decides which
    /// acceptance rule, which limit kind, and which expected fixture outcome are
    /// admissible — in both directions.
    ///
    /// Quantified over the whole vocabulary rather than over a selected member, because
    /// the statement is that the assignment is *complete*: a metric, comparison, or
    /// fixture family added to its vocabulary lands in one of the two branches and is
    /// asserted automatically. Every construction here is one artifact, so covering the
    /// vocabularies costs no plan activation.
    func checkCategoryAssignmentsAreExactAndTotal() {
        // Totality and disjointness of both category assignments.
        let categoricalComparisons = ComparisonMetric.allCases.filter(\.isCategorical)
        let numericComparisons = ComparisonMetric.allCases.filter { !$0.isCategorical }
        #expect(
            Set(categoricalComparisons).union(numericComparisons) == Set(ComparisonMetric.allCases)
        )
        #expect(Set(categoricalComparisons).isDisjoint(with: numericComparisons))
        for metric in ResourceMetric.allCases {
            #expect(
                metric.isCategorical == (metric.requiredUnit == nil),
                "\(metric.rawValue) is categorical exactly when it has no unit"
            )
        }

        // A comparison declares the acceptance rule its category requires, and only that
        // one. Both directions, over every metric.
        for metric in ComparisonMetric.allCases {
            expectRefused(
                "a \(metric.rawValue) comparison declaring the other category's rule",
                .missingRequiredEntries,
                reportedField: "comparison[\(metric.rawValue)]"
            ) {
                _ = try ComparisonSpecification(
                    metric: metric,
                    reference: self.builder.referenceEvidence,
                    tolerance: metric.isCategorical ? self.builder.tolerance : nil,
                    requiredAgreement: metric.isCategorical ? nil : .one
                )
            }
        }

        // Requirement 13.8 fixes the Pixel Evidence outcome ratio at 100%, so that one
        // categorical comparison cannot declare any other ratio.
        expectRefused(
            "a categorical-outcome comparison below full agreement",
            .fixedValueMismatch,
            reportedField: "comparison[\(ComparisonMetric.categoricalOutcome.rawValue)]"
                + ".requiredAgreement"
        ) {
            _ = try ComparisonSpecification(
                metric: .categoricalOutcome,
                reference: self.builder.referenceEvidence,
                tolerance: nil,
                requiredAgreement: try UnitInterval(validating: 0)
            )
        }

        // A recorded comparison reports a numeric deviation exactly when its metric is
        // numeric. A categorical comparison has no deviation to report.
        for metric in categoricalComparisons {
            expectRefused(
                "a categorical \(metric.rawValue) record reporting a deviation",
                .forbiddenValue,
                reportedField: "comparisonRecord.maximumDeviation"
            ) {
                _ = try ComparisonRecord(
                    metric: metric,
                    specification: self.builder.planEvidence,
                    comparedFixtureCount: try NonNegativeCount(
                        validating: self.builder.comparedFixtureCount
                    ),
                    agreeingFixtureCount: try NonNegativeCount(
                        validating: self.builder.comparedFixtureCount
                    ),
                    maximumDeviation: try NonNegativeDecimal(validating: self.builder.deviation),
                    outcome: .passed
                )
            }
        }
        if let numeric = numericComparisons.first(where: { builder.requiredComparisons.contains($0) })
        {
            expectRefused(
                "a numeric \(numeric.rawValue) record reporting no deviation",
                .missingRequiredEntries,
                reportedField: "results.comparisons[\(numeric.rawValue)]"
            ) {
                var records = self.comparisonRecords
                records[numeric] = try self.builder.comparisonRecord(
                    numeric,
                    reportsDeviation: false
                )
                _ = try self.admit(comparisons: records)
            }
        }

        // A measured value carries the limit kind its metric's category requires. Both
        // directions, over every metric of both targets.
        for target in ExecutionTarget.allCases {
            for metric in PlanCompletenessBuilder.requiredMetrics(target) {
                let key = TargetMetric(target: target, metric: metric)
                expectRefused(
                    "a \(metric.rawValue) result carrying the other category's limit",
                    .fixedValueMismatch,
                    reportedField: "measurementRecord.limit"
                ) {
                    _ = try self.builder.measurementRecord(
                        key,
                        limit: metric.isCategorical
                            ? .numeric(
                                value: try PositiveDecimal(validating: 1),
                                unit: .milliseconds
                            )
                            : .thermal(maximumState: .fair),
                        summaryLimit: self.limits[key]!
                    )
                }
            }
        }

        // Requirements 13.3 and 13.5: a fixture declares the expected category its family
        // requires, and only a provenance family declares a provenance state. Both
        // directions, over every family.
        for family in FixtureFamily.allCases {
            expectRefused(
                "a \(family.rawValue) fixture declaring the other category's outcome",
                family.isProvenanceConditional ? .missingRequiredEntries : .forbiddenValue,
                reportedField: "fixture.expectations"
            ) {
                _ = try self.builder.fixture(
                    family: family,
                    offset: 0,
                    expectations: family.isProvenanceConditional
                        ? [.pixelLabel(.noStrongSignalDetected)]
                        : [.provenanceState(.validated)]
                )
            }
        }
    }

    // MARK: - Version arm

    /// Every identity and version a result records is the release's own.
    ///
    /// Each of the seven members ``ValidationVersionTuple`` encodes is moved alone, and
    /// the encoded member list is read out of the artifact so a member added to the tuple
    /// fails the coverage assertion instead of being silently skipped. Four members are
    /// refused by admission against the plan, the capability set by admission against the
    /// release's capabilities, the implementation-version inventory by the tuple itself,
    /// and the application build by the result set against the configuration it describes.
    func checkRecordedVersionsAreBinding() {
        let encoded: [String]
        do {
            encoded = try CanonicalArtifactPayload.topLevelKeys(versionTuple)
        } catch {
            Issue.record("the generated version tuple could not be encoded: \(error) [\(shape)]")
            return
        }
        #expect(
            Set(encoded) == Self.assertedVersionTupleMembers,
            "a version tuple member was added or removed: \(encoded)"
        )

        expectRefused(
            "a result recorded under another Device Validation Plan",
            .inconsistentReference,
            reportedField: "results.versionTuple.validationPlan"
        ) {
            _ = try self.admit(
                versionTuple: try self.builder.versionTuple(
                    validationPlan: self.builder.otherPlanID
                )
            )
        }

        expectRefused(
            "a result recorded against another Model Bundle",
            .inconsistentReference,
            reportedField: "results.versionTuple.modelBundle"
        ) {
            _ = try self.admit(
                versionTuple: try self.builder.versionTuple(
                    modelBundle: self.builder.otherBundleID
                )
            )
        }

        expectRefused(
            "a result recorded against another Release Fixture Suite",
            .inconsistentReference,
            reportedField: "results.versionTuple.fixtureSuite"
        ) {
            _ = try self.admit(
                versionTuple: try self.builder.versionTuple(
                    fixtureSuite: self.builder.otherSuiteID
                )
            )
        }

        expectRefused(
            "a result recorded under another capability manifest",
            .inconsistentReference,
            reportedField: "results.versionTuple.capabilityManifest"
        ) {
            _ = try self.admit(
                versionTuple: try self.builder.versionTuple(
                    capabilityManifest: self.builder.otherManifestID
                )
            )
        }

        expectRefused(
            "a result recorded under another capability set",
            .inconsistentReference,
            reportedField: "results.versionTuple.capabilities"
        ) {
            // The gate applicability follows the tuple, so the only disagreement left is
            // the capability set itself.
            _ = try self.admit(
                versionTuple: try self.builder.versionTuple(
                    provenanceEnabled: !self.shape.provenanceEnabled
                ),
                gateResults: try self.builder.gateRecords(
                    measurements: self.measurementRecords,
                    comparisons: self.comparisonRecords,
                    provenanceApplicable: !self.shape.provenanceEnabled
                )
            )
        }

        expectRefused(
            "a result recorded at another application build",
            .inconsistentReference,
            reportedField: "resultSet.configuration.appBuild"
        ) {
            _ = try self.builder.resultSet(
                configuration: self.resultConfiguration,
                versionTuple: try self.builder.versionTuple(
                    appBuild: self.builder.otherAppBuildID
                ),
                gateResults: try self.builder.gateRecords(
                    measurements: self.measurementRecords,
                    comparisons: self.comparisonRecords
                )
            )
        }

        // The capability inventory the tuple carries is exact in all three directions.
        let position = "versionTuple.capabilityImplementationVersions"
        expectRefused(
            "a tuple missing an enabled capability's implementation version",
            .missingRequiredEntries,
            reportedField: position
        ) {
            _ = try self.builder.versionTuple(
                implementationVersions: Array(self.builder.implementationVersions().dropLast())
            )
        }
        expectRefused(
            "a tuple carrying an implementation version for a capability it does not enable",
            .unexpectedEntries,
            reportedField: position
        ) {
            _ = try self.builder.versionTuple(
                implementationVersions: self.builder.implementationVersions() + [
                    CapabilityImplementationEntry(
                        capability: .shareExtensionHandoff,
                        version: self.builder.schemaVersion
                    )
                ]
            )
        }
        expectRefused(
            "a tuple declaring one capability's implementation version twice",
            .duplicateEntry,
            reportedField: position
        ) {
            let versions = self.builder.implementationVersions()
            _ = try self.builder.versionTuple(implementationVersions: versions + [versions[0]])
        }
        expectRefused(
            "a tuple that does not record the required pixel-analysis capability",
            .missingRequiredEntries,
            reportedField: "versionTuple.capabilities"
        ) {
            _ = try self.builder.versionTuple(
                capabilities: [.shareExtensionHandoff],
                implementationVersions: [
                    CapabilityImplementationEntry(
                        capability: .shareExtensionHandoff,
                        version: self.builder.schemaVersion
                    )
                ]
            )
        }

        // Requirement 13.17 records the device model as part of the identity, so identity
        // is value equality over the whole configuration rather than a hardware-identifier
        // lookup: a result whose every other field matches a listed candidate is still not
        // that candidate.
        expectRefused(
            "a result recorded against a near-match of a listed candidate",
            .inconsistentReference,
            reportedField: "results.configuration"
        ) {
            _ = try self.admit(
                configuration: try CandidateDeviceConfiguration(
                    deviceModel: Sample.text("Unlisted iPhone \(self.builder.seed)"),
                    hardwareIdentifier: self.resultConfiguration.hardwareIdentifier,
                    osVersion: self.resultConfiguration.osVersion,
                    appBuild: self.resultConfiguration.appBuild,
                    isAppleNeuralEngineCapable: true
                )
            )
        }
    }

    /// Every top-level member ``ValidationVersionTuple`` encodes, each one asserted by
    /// ``checkRecordedVersionsAreBinding()``.
    ///
    /// Compared against ``CanonicalArtifactPayload/topLevelKeys(_:)`` rather than trusted
    /// as a written list, so a member added to the tuple fails that comparison instead of
    /// being skipped.
    static let assertedVersionTupleMembers: Set<String> = [
        "appBuild",
        "capabilities",
        "capabilityImplementationVersions",
        "capabilityManifest",
        "fixtureSuite",
        "modelBundle",
        "validationPlan",
    ]

    // MARK: - Provenance applicability arm

    /// A conditional gate's applicability follows the compiled capability set, in both
    /// directions, at the plan layer and at the result layer.
    ///
    /// Requirement 13.5 makes the provenance fixture families and the provenance gate
    /// conditional on the capability, and "conditional" cuts both ways: the gate applies
    /// when the capability is compiled, and it is waived by an explicit decision when it is
    /// not. Neither direction may be inferred from a field simply being absent.
    func checkProvenanceApplicabilityFollowsTheCapabilitySet() {
        // Plan layer. The fixture suite decides whether the provenance families exist and
        // the manifest decides whether the capability is compiled; two answers to one
        // question leaves the plan unable to say which comparisons it needs. One direction
        // per case — the suite is flipped away from this release's own capability set —
        // and the witness records that both capability sets are generated.
        expectRefused(
            "a fixture suite disagreeing with the manifest about provenance",
            .inconsistentReference,
            reportedField: "plan.fixtureSuite.provenanceApplicability"
        ) {
            _ = try self.activate(
                suite: try self.builder.suite(
                    fixtures: self.unconditionalFixtures,
                    provenanceApplicable: !self.shape.provenanceEnabled
                )
            )
        }

        // Result layer, both directions in every case: a waived gate under a capability
        // set that enables it, and an applied gate under a capability set that does not.
        for enabled in [false, true] {
            expectRefused(
                "a provenance gate declared \(enabled ? "not applicable" : "applicable") "
                    + "under a capability set that says otherwise",
                .inconsistentReference,
                reportedField:
                    "resultSet.gateResults[\(DeviceGate.provenanceFixtures.rawValue)].applicability"
            ) {
                _ = try self.builder.resultSet(
                    configuration: self.resultConfiguration,
                    versionTuple: try self.builder.versionTuple(provenanceEnabled: enabled),
                    gateResults: try self.builder.gateRecords(
                        measurements: self.measurementRecords,
                        comparisons: self.comparisonRecords,
                        provenanceApplicable: !enabled
                    )
                )
            }
        }

        // A waived gate records no work. "Not applicable" is a decision about whether the
        // gate applies, not a place to file a result.
        expectRefused(
            "a waived gate that recorded work",
            .inconsistentReference,
            reportedField: "gateRecord[\(DeviceGate.provenanceFixtures.rawValue)]"
        ) {
            _ = try DeviceGateResultRecord(
                gate: .provenanceFixtures,
                applicability: Sample.notApplicable(),
                outcome: .passed,
                measurements: [],
                comparisons: [try self.builder.comparisonRecord(.categoricalOutcome)]
            )
        }

        // Requirement 13.5's fixture side, both directions and independent of this case's
        // capability set: a suite whose provenance decision waives the families cannot
        // carry one, and an applicable suite is short until all six are catalogued.
        let waived = selectedProvenanceFamily
        guard let carried = provenanceFixtures.first(where: { $0.family == waived }) else {
            Issue.record("the \(waived.rawValue) fixture was not generated [\(shape)]")
            return
        }
        expectRefused(
            "a \(waived.rawValue) fixture in a suite whose provenance decision waives it",
            .forbiddenValue,
            reportedField: "suite.fixtures[\(carried.id.rawValue)].family"
        ) {
            _ = try self.builder.suite(
                fixtures: self.unconditionalFixtures + [carried],
                provenanceApplicable: false
            )
        }

        do {
            let applicable = try builder.suite(
                fixtures: unconditionalFixtures + provenanceFixtures,
                provenanceApplicable: true
            )
            let required = applicable.requiredFamilies
            let complete = applicable.missingFamilies
            #expect(required == Set(FixtureFamily.allCases))
            #expect(
                complete.isEmpty,
                "a provenance release carries every family: \(complete.map(\.rawValue).sorted())"
            )
            // One family per case; the witness records that the selection spread across
            // all six over the run.
            let missing = try builder.suite(
                fixtures: unconditionalFixtures
                    + provenanceFixtures.filter { $0.family != waived },
                provenanceApplicable: true
            )
            .missingFamilies
            #expect(
                missing == [waived],
                "dropping \(waived.rawValue) leaves \(missing.map(\.rawValue).sorted())"
            )
        } catch {
            Issue.record("a coherent provenance fixture inventory was refused: \(error)")
        }
    }

    /// The provenance family this case's applicability arm waives and drops.
    var selectedProvenanceFamily: FixtureFamily {
        let families = FixtureFamily.provenanceFamilies.sorted { $0.rawValue < $1.rawValue }
        return families[shape.selectors.family % families.count]
    }

    // MARK: - Inventory arm

    /// The fixture, gate, candidate, and measurement inventories are exact: a missing,
    /// extra, or duplicated entry is refused or reported.
    ///
    /// Every required set is derived from its vocabulary or from the artifact rather than
    /// written out here, so a family, gate, or metric added to the domain joins the
    /// required set automatically instead of being skipped.
    func checkInventoriesAreExact() {
        // Fixture inventory. A repeated identifier or asset path means the catalogue
        // describes one fixture twice, so "the suite ran every fixture" stops being
        // checkable.
        let family = selectedFamily
        expectRefused(
            "a fixture catalogued twice under one identifier",
            .duplicateEntry,
            reportedField: "suite.fixtures"
        ) {
            let duplicate = try self.builder.fixture(family: .orientation, offset: 0)
            _ = try self.builder.suite(fixtures: self.fixtures + [duplicate])
        }
        expectRefused(
            "two fixtures catalogued at one asset path",
            .duplicateEntry,
            reportedField: "suite.fixtureAssetPaths"
        ) {
            let shared = try self.builder.fixture(
                family: .orientation,
                offset: 0,
                identifier: "fixture.orientation-second-\(self.builder.seed)"
            )
            _ = try self.builder.suite(fixtures: self.fixtures + [shared])
        }

        // A missing family is *reported* rather than refused, so a runner can catalogue
        // incrementally and still fail the release gate. Dropping the whole family makes
        // the report exact whichever family was drawn.
        if suite.requiredFamilies.contains(family) {
            do {
                let short = try builder.suite(
                    fixtures: fixtures.filter { $0.family != family }
                )
                let missing = short.missingFamilies
                let parityComplete = short.hasCompleteModelParityCoverage
                #expect(
                    missing == [family],
                    "dropping \(family.rawValue) leaves \(missing.map(\.rawValue).sorted())"
                )
                #expect(parityComplete == (family != .modelParity))
            } catch {
                Issue.record("dropping the \(family.rawValue) family was refused: \(error)")
            }
        }

        // Requirement 13.4 fixes the model-parity count, so the inventory is exact in both
        // directions. The expected count comes from the artifact rather than a literal.
        // The reported flags are bound to locals before being asserted: a failed
        // `#expect` renders its receiver, and rendering a hundred-fixture suite buries the
        // finding in tens of thousands of characters of artifact dump.
        do {
            let parity = fixtures.filter { $0.family == .modelParity }
            #expect(parity.count == ReleaseFixtureSuite.requiredModelParityFixtureCount)
            let fewer = try builder.suite(fixtures: Array(fixtures.dropFirst()))
                .hasCompleteModelParityCoverage
            #expect(
                !fewer,
                "one model-parity fixture short still reports complete coverage"
            )
            let more = try builder.suite(
                fixtures: fixtures + [
                    try builder.fixture(
                        family: .modelParity,
                        offset: ReleaseFixtureSuite.requiredModelParityFixtureCount
                    )
                ]
            )
            .hasCompleteModelParityCoverage
            #expect(
                !more,
                "one model-parity fixture too many still reports complete coverage"
            )
        } catch {
            Issue.record("a model-parity inventory variation was refused: \(error) [\(shape)]")
        }

        // Gate inventory. Every mandatory gate exactly once; the required set is
        // ``DeviceGate/mandatoryGates``, so a gate added to the vocabulary is required here
        // without this file changing. An entry outside that set is unrepresentable, because
        // the gate vocabulary is closed and every member of it is mandatory.
        let gate = selectedGate
        expectRefused(
            "a result set with no record for the \(gate.rawValue) gate",
            .missingRequiredEntries,
            reportedField: "resultSet.gateResults"
        ) {
            _ = try self.builder.resultSet(
                configuration: self.resultConfiguration,
                versionTuple: self.versionTuple,
                gateResults: try self.builder.gateRecords(
                    measurements: self.measurementRecords,
                    comparisons: self.comparisonRecords,
                    omittingGate: gate
                )
            )
        }
        expectRefused(
            "a result set recording the \(gate.rawValue) gate twice",
            .duplicateEntry,
            reportedField: "resultSet.gateResults"
        ) {
            _ = try self.builder.resultSet(
                configuration: self.resultConfiguration,
                versionTuple: self.versionTuple,
                gateResults: try self.builder.gateRecords(
                    measurements: self.measurementRecords,
                    comparisons: self.comparisonRecords,
                    duplicatingGate: gate
                )
            )
        }
        #expect(
            DeviceGate.mandatoryGates == Set(DeviceGate.allCases),
            "every gate in the vocabulary is mandatory, so no entry outside the set exists"
        )

        // Candidate inventory (Requirement 13.1). Two entries for one hardware identifier
        // and operating-system version are two enumerations of one configuration.
        expectRefused(
            "a plan enumerating one candidate configuration twice",
            .duplicateEntry,
            reportedField: "plan.candidateConfigurations"
        ) {
            _ = try self.builder.plan(
                candidates: self.candidates + [self.candidates[0]],
                comparisons: self.builder.ordered(self.comparisonSpecifications),
                measurements: self.builder.ordered(self.measurementSpecifications)
            )
        }

        // Measurement inventory. Property 28 asserts that a predeclared measurement cannot
        // be missing; the other direction is that it cannot be declared twice, because two
        // pass limits for one metric on one device are two plans.
        expectRefused(
            "a plan predeclaring one measurement twice",
            .duplicateEntry,
            reportedField: "plan.measurements"
        ) {
            let declared = self.builder.ordered(self.measurementSpecifications)
            _ = try self.builder.plan(
                candidates: self.candidates,
                comparisons: self.builder.ordered(self.comparisonSpecifications),
                measurements: declared + [declared[0]]
            )
        }
    }

    // MARK: - Rebuilders

    /// The activated plan, with one reference site moved or one artifact replaced.
    private func activate(
        suite suiteOverride: ReleaseFixtureSuite? = nil,
        replacing site: ReferenceSite? = nil,
        _ transform: ((EvidenceSource) -> EvidenceSource)? = nil
    ) throws -> ValidatedResourcePlan {
        var comparisons = comparisonSpecifications
        var conditions = builder.conditions(limits: limits)
        var approval = builder.approvalEvidence
        var workloads = builder.workloads(candidates: candidates, limits: limits)

        if let site, let transform {
            switch site {
            case .planApproval:
                approval = transform(approval)
            case .comparisonReference:
                let metric = selectedComparison
                comparisons[metric] = try builder.comparisonSpecification(
                    metric,
                    reference: transform(builder.referenceEvidence)
                )
            case .measurementWorkload:
                let key = MeasurementPosition(
                    candidate: builder.resultCandidateOffset(candidates),
                    target: selectedMetric.target,
                    metric: selectedMetric.metric
                )
                workloads[key] = transform(builder.workloadEvidence)
            case .measurementConditions:
                conditions[selectedMetric] = transform(builder.conditionsEvidence)
            }
        }

        return try ValidatedResourcePlan(
            activating: try builder.plan(
                candidates: candidates,
                comparisons: builder.ordered(comparisons),
                measurements: try builder.measurements(
                    candidates: candidates,
                    limits: limits,
                    workloads: workloads
                ),
                approval: approval
            ),
            budgets: try builder.budgets(limits: limits, conditions: conditions),
            fixtureSuite: suiteOverride ?? suite,
            capabilityManifest: manifest,
            evidence: index
        )
    }

    /// The admitted result, with one recorded table or identity replaced.
    private func admit(
        configuration: CandidateDeviceConfiguration? = nil,
        versionTuple tupleOverride: ValidationVersionTuple? = nil,
        measurements: [TargetMetric: MeasurementRecord]? = nil,
        comparisons: [ComparisonMetric: ComparisonRecord]? = nil,
        omittingComparison: ComparisonMetric? = nil,
        gateResults: [DeviceGateResultRecord]? = nil
    ) throws -> AdmissibleDeviceValidationResult {
        let records: [DeviceGateResultRecord]
        if let gateResults {
            records = gateResults
        } else if measurements == nil, comparisons == nil, omittingComparison == nil {
            // An arm that only moves an identity or a version leaves every gate record
            // exactly as the baseline built it, so the baseline's records are reused rather
            // than rebuilt twenty-three at a time.
            records = resultSet.gateResults
        } else {
            records = try builder.gateRecords(
                measurements: measurements ?? measurementRecords,
                comparisons: comparisons ?? comparisonRecords,
                omittingComparison: omittingComparison
            )
        }
        return try AdmissibleDeviceValidationResult(
            admitting: try builder.resultSet(
                configuration: configuration ?? resultConfiguration,
                versionTuple: tupleOverride ?? versionTuple,
                gateResults: records
            ),
            under: activated
        )
    }

    // MARK: - Refusal helper

    /// Requires `build` to refuse with a specific fault, recording an issue otherwise.
    ///
    /// Never rethrows. `propertyCheck` discards an error thrown by its body without
    /// recording an issue, so a refusal that escaped as a throw would make this property
    /// pass vacuously.
    ///
    /// `reportedField` is asserted everywhere, because almost every arm here reaches
    /// ``ArtifactSchemaError/inconsistentReference(field:expected:found:)`` — the case
    /// alone would let one arm's mutation be refused for another arm's reason and still
    /// pass.
    func expectRefused(
        _ what: String,
        _ expected: PlanCompletenessFault,
        reportedField: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ build: () throws -> Void
    ) {
        do {
            try build()
            Issue.record("\(what) was accepted [\(shape)]", sourceLocation: sourceLocation)
        } catch let error as ArtifactSchemaError {
            #expect(
                PlanCompletenessFault(error) == expected,
                "\(what) was refused as \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
            #expect(
                PlanCompletenessFault.reportedField(error) == reportedField,
                "\(what) named \(PlanCompletenessFault.reportedField(error)) [\(shape)]",
                sourceLocation: sourceLocation
            )
        } catch {
            Issue.record(
                "\(what) failed with a non-schema error \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
        }
    }
}

// MARK: - Measurement position

/// One predeclared measurement's position: which candidate, target, and metric.
private struct MeasurementPosition: Hashable, Sendable {
    let candidate: Int
    let target: ExecutionTarget
    let metric: ResourceMetric
}

// MARK: - Builder

/// Builds every artifact the property needs from one generated shape.
///
/// Separate from the scenario so the scenario's stored baseline and every arm's mutation
/// go through the same construction path: an arm hands in one replaced table and gets the
/// same artifacts back otherwise.
private struct PlanCompletenessBuilder {
    let shape: PlanCompletenessShape

    // MARK: Identifiers, versions, and digests
    //
    // Stored rather than computed. Every identifier is validated on construction and every
    // digest is parsed from text, and this set is read thousands of times per generated
    // case; recomputing it was a measurable share of this property's wall clock.

    let seed: Int

    let planID: ArtifactID
    let otherPlanID: ArtifactID
    let mainBudgetID: ArtifactID
    let extensionBudgetID: ArtifactID
    let manifestID: ArtifactID
    let otherManifestID: ArtifactID
    let suiteID: ArtifactID
    let otherSuiteID: ArtifactID
    let allowlistID: ArtifactID
    let resultsID: ArtifactID

    let conditionsID: ArtifactID
    let workloadID: ArtifactID
    let referenceID: ArtifactID
    let approvalID: ArtifactID
    let fixtureSourceID: ArtifactID

    let bundleID: ModelBundleID
    let otherBundleID: ModelBundleID
    let appBuildID: AppBuildID
    let otherAppBuildID: AppBuildID

    let schemaVersion: SchemaSemanticVersion

    /// A version this release does not carry, for the reference arm.
    let otherVersion: SchemaSemanticVersion

    let contentDigest: SHA256Digest

    /// Content this release does not carry, for the reference arm.
    let otherContentDigest: SHA256Digest

    /// The evidence sources the coherent baseline cites, built once.
    let conditionsEvidence: EvidenceSource
    let workloadEvidence: EvidenceSource
    let referenceEvidence: EvidenceSource
    let approvalEvidence: EvidenceSource
    let fixtureSourceEvidence: EvidenceSource
    let planEvidence: EvidenceSource

    init(shape: PlanCompletenessShape) {
        func artifact(_ raw: String) -> ArtifactID { ArtifactID(raw)! }
        func digest(from value: Int) -> SHA256Digest {
            let hexadecimal = String(value, radix: 16)
            return SHA256Digest(
                hexadecimal: String(repeating: "0", count: 64 - hexadecimal.count) + hexadecimal
            )!
        }

        let seed = shape.seed
        self.shape = shape
        self.seed = seed

        planID = artifact("plan.device-validation-\(seed)")
        otherPlanID = artifact("plan.device-validation-other-\(seed)")
        mainBudgetID = artifact("budget.main-application-\(seed)")
        extensionBudgetID = artifact("budget.share-extension-\(seed)")
        manifestID = artifact("manifest.capability-\(seed)")
        otherManifestID = artifact("manifest.capability-other-\(seed)")
        suiteID = artifact("suite.fixtures-\(seed)")
        otherSuiteID = artifact("suite.fixtures-other-\(seed)")
        allowlistID = artifact("allowlist.devices-\(seed)")
        resultsID = artifact("results.device-validation-\(seed)")

        conditionsID = artifact("evidence.measurement-conditions-\(seed)")
        workloadID = artifact("evidence.workload-\(seed)")
        referenceID = artifact("evidence.comparison-reference-\(seed)")
        approvalID = artifact("evidence.plan-approval-\(seed)")
        fixtureSourceID = artifact("evidence.fixture-source-\(seed)")

        bundleID = ModelBundleID("bundle.model-\(seed)")!
        otherBundleID = ModelBundleID("bundle.model-other-\(seed)")!
        appBuildID = AppBuildID("build.app-\(seed)")!
        otherAppBuildID = AppBuildID("build.app-other-\(seed)")!

        let version = try! SchemaSemanticVersion(validating: "1.\(seed % 1_000).0")
        schemaVersion = version
        otherVersion = try! SchemaSemanticVersion(validating: "2.\(seed % 1_000).0")
        let content = digest(from: seed)
        contentDigest = content
        otherContentDigest = digest(from: seed + 100_000)

        func source(_ artifact: ArtifactID) -> EvidenceSource {
            EvidenceSource(artifact: artifact, version: version, contentDigest: content)
        }
        conditionsEvidence = source(conditionsID)
        workloadEvidence = source(workloadID)
        referenceEvidence = source(referenceID)
        approvalEvidence = source(approvalID)
        fixtureSourceEvidence = source(fixtureSourceID)
        planEvidence = source(planID)
    }

    /// Evidence at this shape's version and digest, so a reference built the same way
    /// resolves and one built at another version or over other content does not.
    func evidence(_ artifact: ArtifactID) -> EvidenceSource {
        EvidenceSource(artifact: artifact, version: schemaVersion, contentDigest: contentDigest)
    }

    /// The evidence this release carries. Nothing else resolves.
    ///
    /// The fixture source is included so the whole artifact set is coherent, even though
    /// nothing cross-checks it: a fixture's source is a required field of the fixture and
    /// is not resolved against the index by any production path.
    func evidenceIndex() throws -> ReleaseEvidenceIndex {
        try ReleaseEvidenceIndex(
            records: [
                conditionsEvidence,
                workloadEvidence,
                referenceEvidence,
                approvalEvidence,
                fixtureSourceEvidence,
            ]
        )
    }

    // MARK: Capabilities

    var capabilities: Set<CapabilityID> {
        capabilities(provenanceEnabled: shape.provenanceEnabled)
    }

    func capabilities(provenanceEnabled: Bool) -> Set<CapabilityID> {
        provenanceEnabled ? [.pixelAnalysis, .contentCredentialValidation] : [.pixelAnalysis]
    }

    /// One implementation version per enabled capability, each its own generated version.
    func implementationVersions(
        provenanceEnabled: Bool? = nil
    ) -> [CapabilityImplementationEntry] {
        capabilities(provenanceEnabled: provenanceEnabled ?? shape.provenanceEnabled)
            .sorted { $0.rawValue < $1.rawValue }
            .enumerated()
            .map { offset, capability in
                CapabilityImplementationEntry(
                    capability: capability,
                    version: try! SchemaSemanticVersion(
                        validating: "\(1 + offset).\(seed % 1_000).0"
                    )
                )
            }
    }

    func capabilityManifest() throws -> ReleaseCapabilityManifest {
        try ReleaseCapabilityManifest(
            id: manifestID,
            schemaVersion: .v1,
            appBuild: appBuildID,
            compositionIdentifier: Sample.text(
                shape.provenanceEnabled ? "pixel-plus-provenance" : "pixel-only"
            ),
            compiledCapabilities: capabilities,
            implementationVersions: implementationVersions(),
            approvedConfigurationAllowlist: allowlistID,
            approvedBundleCatalog: [bundleID],
            policyCompatibility: try Sample.policyCompatibility(
                provenance: shape.provenanceEnabled
                    ? .bound(Sample.artifact("policy.provenance"))
                    : .notApplicable(decision: Sample.approval())
            ),
            approval: Sample.approval()
        )
    }

    // MARK: Candidates

    static func requiredMetrics(_ target: ExecutionTarget) -> [ResourceMetric] {
        ResourceMetric.requiredMetrics(for: target).sorted { $0.rawValue < $1.rawValue }
    }

    func deviceModel(_ offset: Int) -> ArtifactText {
        Sample.text("Synthetic iPhone \(seed)-\(offset)")
    }

    /// The hardware identifier of the candidate at `offset`. The major component is the
    /// position, so two candidates can never collide on the plan's uniqueness key.
    func hardware(_ offset: Int) -> DeviceHardwareID {
        let device = shape.devices[offset % shape.devices.count]
        return DeviceHardwareID("iPhone\(17 + offset).\(device.hardwareDigit)")!
    }

    func osVersion(_ offset: Int) -> PlatformVersion {
        let device = shape.devices[offset % shape.devices.count]
        return try! PlatformVersion(
            validating: "\(17 + offset).\(device.osMinor).\(device.osPatch)"
        )
    }

    func candidates() throws -> [CandidateDeviceConfiguration] {
        try shape.devices.indices.map { offset in
            try CandidateDeviceConfiguration(
                deviceModel: deviceModel(offset),
                hardwareIdentifier: hardware(offset),
                osVersion: osVersion(offset),
                appBuild: appBuildID,
                isAppleNeuralEngineCapable: true
            )
        }
    }

    /// Which candidate the generated result set describes. A result set covers one
    /// configuration, so exactly one of the plan's candidates is the one under test.
    func resultCandidateOffset(_ candidates: [CandidateDeviceConfiguration]) -> Int {
        shape.selectors.device % candidates.count
    }

    // MARK: Limits and conditions

    /// The generated limit for every required `(target, metric)` pair.
    func limits() throws -> [TargetMetric: ValidatedLimit] {
        var table: [TargetMetric: ValidatedLimit] = [:]
        for (offset, pair) in PlanCompletenessShape.numericPairs.enumerated() {
            table[pair] = .numeric(
                value: try PositiveDecimal(validating: shape.magnitudes[offset].value),
                unit: pair.metric.requiredUnit!
            )
        }
        for (offset, target) in ExecutionTarget.allCases.enumerated() {
            table[TargetMetric(target: target, metric: .thermalState)] = .thermal(
                maximumState: shape.thermalCeilings[offset]
            )
        }
        return table
    }

    /// The generated magnitude for one numeric pair, or `nil` for the categorical metric.
    func magnitude(for pair: TargetMetric) -> Decimal? {
        guard let offset = PlanCompletenessShape.numericPairs.firstIndex(of: pair) else {
            return nil
        }
        return shape.magnitudes[offset].value
    }

    /// The measurement conditions every limit cites (Requirement 11.4).
    func conditions(limits: [TargetMetric: ValidatedLimit]) -> [TargetMetric: EvidenceSource] {
        limits.keys.reduce(into: [:]) { $0[$1] = conditionsEvidence }
    }

    /// The workload every predeclared measurement cites.
    func workloads(
        candidates: [CandidateDeviceConfiguration],
        limits: [TargetMetric: ValidatedLimit]
    ) -> [MeasurementPosition: EvidenceSource] {
        var table: [MeasurementPosition: EvidenceSource] = [:]
        for offset in candidates.indices {
            for key in limits.keys {
                table[
                    MeasurementPosition(
                        candidate: offset,
                        target: key.target,
                        metric: key.metric
                    )
                ] = workloadEvidence
            }
        }
        return table
    }

    // MARK: Budgets

    func budgets(
        limits: [TargetMetric: ValidatedLimit],
        conditions conditionOverride: [TargetMetric: EvidenceSource]? = nil
    ) throws -> ResourceBudgetSet {
        let conditions = conditionOverride ?? self.conditions(limits: limits)
        return try ResourceBudgetSet(
            mainApplication: try budget(
                target: .mainApplication,
                limits: limits,
                conditions: conditions
            ),
            shareExtension: try budget(
                target: .shareExtension,
                limits: limits,
                conditions: conditions
            )
        )
    }

    private func budget(
        target: ExecutionTarget,
        limits: [TargetMetric: ValidatedLimit],
        conditions: [TargetMetric: EvidenceSource]
    ) throws -> ResourceBudget {
        let entries = try Self.requiredMetrics(target).map { metric -> ResourceLimitEntry in
            let key = TargetMetric(target: target, metric: metric)
            guard let limit = limits[key] else {
                throw ArtifactSchemaError.missingRequiredEntries(
                    field: "test.limits",
                    keys: [metric.rawValue]
                )
            }
            return try ResourceLimitEntry(
                metric: metric,
                limit: limit,
                measurementConditions: conditions[key] ?? conditionsEvidence
            )
        }
        return try ResourceBudget(
            id: target == .mainApplication ? mainBudgetID : extensionBudgetID,
            schemaVersion: .v1,
            target: target,
            hardLimits: entries,
            validationPlan: planID
        )
    }

    // MARK: Comparisons

    var requiredComparisons: Set<ComparisonMetric> {
        ComparisonMetric.requiredComparisons(provenanceEnabled: shape.provenanceEnabled)
    }

    var toleranceKind: ToleranceKind { shape.toleranceKind }

    /// The declared tolerance and the observed deviation come from one pair of draws, so
    /// the larger is the tolerance and the smaller is what the run measured. An `exact`
    /// comparison pins both at zero, which is the only value that kind admits.
    var toleranceValue: Decimal {
        guard toleranceKind != .exact else { return 0 }
        return Decimal(max(shape.comparison.toleranceFirst, shape.comparison.toleranceSecond))
            / 1_000
    }

    var deviation: Decimal {
        guard toleranceKind != .exact else { return 0 }
        return Decimal(min(shape.comparison.toleranceFirst, shape.comparison.toleranceSecond))
            / 1_000
    }

    var tolerance: NumericTolerance {
        try! NumericTolerance(
            kind: toleranceKind,
            value: try! NonNegativeDecimal(validating: toleranceValue)
        )
    }

    /// The agreement ratio a categorical comparison declares. Fixed at 100% for the Pixel
    /// Evidence outcome, which Requirement 13.8 does not leave to a release decision.
    func requiredAgreement(_ metric: ComparisonMetric) throws -> UnitInterval {
        guard metric != .categoricalOutcome else { return .one }
        return try UnitInterval(
            validating: Decimal(shape.comparison.agreementThousandths) / 1_000
        )
    }

    /// Fixtures compared. Every one agrees, so a coherent comparison satisfies whatever
    /// ratio it declared.
    var comparedFixtureCount: Int {
        ReleaseFixtureSuite.requiredModelParityFixtureCount + shape.comparison.extraComparedFixtures
    }

    func comparisonSpecification(
        _ metric: ComparisonMetric,
        reference: EvidenceSource? = nil
    ) throws -> ComparisonSpecification {
        try ComparisonSpecification(
            metric: metric,
            reference: reference ?? referenceEvidence,
            tolerance: metric.isCategorical ? nil : tolerance,
            requiredAgreement: metric.isCategorical ? try requiredAgreement(metric) : nil
        )
    }

    func comparisonSpecifications() throws -> [ComparisonMetric: ComparisonSpecification] {
        try requiredComparisons.reduce(into: [:]) {
            $0[$1] = try comparisonSpecification($1)
        }
    }

    func ordered(
        _ specifications: [ComparisonMetric: ComparisonSpecification]
    ) -> [ComparisonSpecification] {
        specifications.keys.sorted { $0.rawValue < $1.rawValue }.map { specifications[$0]! }
    }

    // MARK: Measurement specifications

    var summaryStatistic: SummaryStatistic {
        SummaryStatistic.allCases[shape.method.statisticIndex]
    }

    /// A statistic the plan did not declare, for the contract arm.
    var otherSummaryStatistic: SummaryStatistic {
        SummaryStatistic.allCases[
            (shape.method.statisticIndex + 1) % SummaryStatistic.allCases.count
        ]
    }

    var startingThermalState: ThermalState {
        PlanCompletenessShape.admissibleThermalStates[shape.method.startingThermalIndex]
    }

    /// One predeclared measurement, complete enough to be repeatable (Requirement 11.4).
    func measurementSpecification(
        _ key: TargetMetric,
        for configuration: CandidateDeviceConfiguration,
        limit: ValidatedLimit,
        workload: EvidenceSource? = nil
    ) throws -> ResourceMeasurementSpecification {
        try ResourceMeasurementSpecification(
            metric: key.metric,
            target: key.target,
            hardwareIdentifier: configuration.hardwareIdentifier,
            osVersion: configuration.osVersion,
            appBuild: configuration.appBuild,
            workload: workload ?? workloadEvidence,
            warmth: key.metric == .coldModelLoadTime ? .cold : .warm,
            branchExecution: shape.method.concurrent ? .concurrent : .serial,
            startingThermalState: startingThermalState,
            startingPowerCondition: shape.method.pluggedIn
                ? .batteryPluggedIn
                : .batteryUnplugged,
            sampleCount: try PositiveCount(validating: shape.method.sampleCount),
            summaryStatistic: summaryStatistic,
            passLimit: limit
        )
    }

    func measurementSpecifications(
        for configuration: CandidateDeviceConfiguration,
        limits: [TargetMetric: ValidatedLimit]
    ) throws -> [TargetMetric: ResourceMeasurementSpecification] {
        try limits.reduce(into: [:]) { table, entry in
            table[entry.key] = try measurementSpecification(
                entry.key,
                for: configuration,
                limit: entry.value
            )
        }
    }

    /// Every candidate's measurements, with one workload replaced where an arm moved it.
    ///
    /// Only the moved measurement is rebuilt. Rebuilding the whole table per position made
    /// this quadratic in the metric count, which showed up directly in the property's
    /// runtime.
    func measurements(
        candidates: [CandidateDeviceConfiguration],
        limits: [TargetMetric: ValidatedLimit],
        workloads: [MeasurementPosition: EvidenceSource]
    ) throws -> [ResourceMeasurementSpecification] {
        var declared: [ResourceMeasurementSpecification] = []
        for (offset, configuration) in candidates.enumerated() {
            let base = try measurementSpecifications(for: configuration, limits: limits)
            for key in Self.orderedKeys(limits) {
                let position = MeasurementPosition(
                    candidate: offset,
                    target: key.target,
                    metric: key.metric
                )
                let workload = workloads[position] ?? workloadEvidence
                if workload == workloadEvidence {
                    declared.append(base[key]!)
                } else {
                    declared.append(
                        try measurementSpecification(
                            key,
                            for: configuration,
                            limit: limits[key]!,
                            workload: workload
                        )
                    )
                }
            }
        }
        return declared
    }

    func ordered(
        _ specifications: [[TargetMetric: ResourceMeasurementSpecification]]
    ) -> [ResourceMeasurementSpecification] {
        specifications.flatMap { table in
            Self.orderedKeys(table).map { table[$0]! }
        }
    }

    private static func orderedKeys<Value>(_ table: [TargetMetric: Value]) -> [TargetMetric] {
        table.keys.sorted {
            ($0.target.rawValue, $0.metric.rawValue) < ($1.target.rawValue, $1.metric.rawValue)
        }
    }

    // MARK: Plan

    func plan(
        candidates: [CandidateDeviceConfiguration],
        comparisons: [ComparisonSpecification],
        measurements: [ResourceMeasurementSpecification],
        approval: EvidenceSource? = nil
    ) throws -> DeviceValidationPlan {
        try DeviceValidationPlan(
            id: planID,
            schemaVersion: .v1,
            candidateConfigurations: candidates,
            fixtureSuite: suiteID,
            modelBundle: bundleID,
            capabilityManifest: manifestID,
            comparisons: comparisons,
            measurements: measurements,
            missingResultRule: .treatAsFailure,
            approval: ApprovalRecord(
                source: approval ?? approvalEvidence,
                decision: .approved,
                approver: Sample.approver(),
                decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
    }

    // MARK: Fixture inventory

    /// The expected outcome a fixture of one family declares.
    ///
    /// Derived from the family rather than drawn, so the expected category always matches
    /// the family's own rule and no generated fixture is refused for a reason the category
    /// arm is about. Every value is synthetic: none of these is an approved expected
    /// result.
    static func expectations(for family: FixtureFamily, offset: Int) -> [FixtureExpectation] {
        switch family {
        case .provenanceValidSigned: [.provenanceState(.validated)]
        case .provenanceTampered, .provenanceInvalid: [.provenanceState(.invalid)]
        case .provenanceAbsent: [.provenanceState(.absent)]
        case .provenanceUnsupported: [.provenanceState(.unsupported)]
        case .provenanceIndeterminate: [.provenanceState(.indeterminate)]
        case .malformedInput: [.analysisError(.decodingError)]
        case .photosPickerRoute, .shareExtensionRoute:
            [
                .retainedBytesDigest(Sample.digest("2")),
                .bytePreservationStatus(.originalBytes),
            ]
        case .physicalScreenshot: [.preprocessingOutputDigest(Sample.digest("3"))]
        default:
            [
                .pixelLabel(
                    PixelLabelKey.allCases[offset % PixelLabelKey.allCases.count]
                )
            ]
        }
    }

    func fixture(
        family: FixtureFamily,
        offset: Int,
        identifier: String? = nil,
        assetPath: String? = nil,
        expectations: [FixtureExpectation]? = nil
    ) throws -> FixtureRecord {
        try FixtureRecord(
            id: FixtureID(identifier ?? "fixture.\(family.rawValue)-\(seed)-\(offset)")!,
            family: family,
            assetPath: CanonicalRelativePath(
                assetPath ?? "fixtures/\(family.rawValue)-\(seed)-\(offset).bin"
            )!,
            // This case's one generated digest. The suite requires unique identifiers and
            // asset paths, not unique content, and nothing here asserts anything about a
            // fixture's bytes; parsing 96 more digests per case bought nothing.
            contentDigest: contentDigest,
            byteCount: try PositiveByteCount(validating: UInt64(1_024 + offset)),
            source: fixtureSourceEvidence,
            expectations: expectations ?? Self.expectations(for: family, offset: offset)
        )
    }

    /// The six provenance-family fixtures Requirement 13.5 requires when the capability is
    /// enabled. Built independently of this case's capability set, so the applicability
    /// arm can assert both directions.
    func provenanceFixtures() throws -> [FixtureRecord] {
        try FixtureFamily.provenanceFamilies
            .sorted { $0.rawValue < $1.rawValue }
            .map { try fixture(family: $0, offset: 0) }
    }

    /// Every family a release populates regardless of its capability set: the required
    /// model-parity count plus one fixture for each of the others.
    ///
    /// The family list comes from ``FixtureFamily/unconditionalFamilies`` and the count
    /// from ``ReleaseFixtureSuite/requiredModelParityFixtureCount``, so a family added to
    /// the vocabulary is catalogued here without this file changing.
    func unconditionalFixtures() throws -> [FixtureRecord] {
        var records: [FixtureRecord] = []
        for offset in 0..<ReleaseFixtureSuite.requiredModelParityFixtureCount {
            records.append(try fixture(family: .modelParity, offset: offset))
        }
        for family in FixtureFamily.unconditionalFamilies
            .subtracting([.modelParity])
            .sorted(by: { $0.rawValue < $1.rawValue })
        {
            records.append(try fixture(family: family, offset: 0))
        }
        return records
    }

    func suite(
        fixtures: [FixtureRecord],
        provenanceApplicable: Bool? = nil
    ) throws -> ReleaseFixtureSuite {
        let applicable = provenanceApplicable ?? shape.provenanceEnabled
        return try ReleaseFixtureSuite(
            id: suiteID,
            schemaVersion: .v1,
            provenanceApplicability: applicable ? .applicable : Sample.notApplicable(),
            fixtures: fixtures
        )
    }

    // MARK: Version tuple

    /// The coherent tuple, or the same tuple with exactly one member replaced.
    ///
    /// `implementationVersions` is an optional array rather than a defaulted one, because
    /// one arm hands in an *empty* list: a pixel-only release enables one capability, so
    /// dropping its implementation version leaves nothing, and an empty-list sentinel would
    /// have silently restored the derived list and made that arm pass vacuously.
    func versionTuple(
        appBuild: AppBuildID? = nil,
        modelBundle: ModelBundleID? = nil,
        fixtureSuite: ArtifactID? = nil,
        validationPlan: ArtifactID? = nil,
        capabilityManifest: ArtifactID? = nil,
        provenanceEnabled: Bool? = nil,
        capabilities capabilityOverride: Set<CapabilityID>? = nil,
        implementationVersions versionOverride: [CapabilityImplementationEntry]? = nil
    ) throws -> ValidationVersionTuple {
        let enabled = provenanceEnabled ?? shape.provenanceEnabled
        return try ValidationVersionTuple(
            appBuild: appBuild ?? appBuildID,
            modelBundle: modelBundle ?? bundleID,
            fixtureSuite: fixtureSuite ?? suiteID,
            validationPlan: validationPlan ?? planID,
            capabilityManifest: capabilityManifest ?? manifestID,
            capabilities: capabilityOverride ?? capabilities(provenanceEnabled: enabled),
            capabilityImplementationVersions: versionOverride
                ?? implementationVersions(provenanceEnabled: enabled)
        )
    }

    // MARK: Recorded results

    /// Which metrics each measurement gate reports.
    ///
    /// A fixture arrangement, not a requirement: admission asks whether each metric was
    /// measured for its target, not which gate carried it. The valid arm asserts the
    /// arrangement covers each target's required metric set exactly once, so a metric
    /// added to the vocabulary fails there rather than being skipped.
    static let measuredMetrics: [DeviceGate: [ResourceMetric]] = [
        .coldModelLoad: [.coldModelLoadTime],
        .warmAnalysisLatency: [.warmAnalysisLatency],
        .mainApplicationPeakMemory: [.peakResidentMemory, .decodedPixelCount],
        .mainApplicationTemporaryStorage: [.temporaryStorage],
        .mainApplicationEnergy: [.energyImpact],
        .sustainedAnalysisThermal: [.thermalState],
        .handoffLatency: [.handoffLatency],
        .shareExtensionPeakMemory: [.peakResidentMemory, .encodedInputSize],
        .shareExtensionTemporaryStorage: [.temporaryStorage],
        .shareExtensionEnergy: [.energyImpact],
        .sustainedHandoffThermal: [.thermalState],
    ]

    /// Which comparisons each gate reports.
    ///
    /// Every measurement gate also carries the Pixel Evidence outcome comparison, so that
    /// removing any one measured value leaves its gate still recording work: an applicable
    /// gate that recorded nothing is a different fault, and an arm that tripped it would
    /// not be testing the missing measurement.
    static func comparedMetrics(for gate: DeviceGate) -> [ComparisonMetric] {
        switch gate {
        case .preprocessingParity: [.preprocessingOutput]
        case .rawLogitParity: [.rawLogit]
        case .rankAgreement: [.rankAgreement]
        case .categoricalAgreement: [.categoricalOutcome]
        case .screenshotFidelity: [.screenshotGeometry]
        case .routeByteParity: [.retainedBytes, .bytePreservationStatus]
        case .provenanceFixtures: [.provenanceState]
        default: [.categoricalOutcome]
        }
    }

    /// The sample values a measurement of one metric recorded, smallest first.
    func rawValues(for limit: ValidatedLimit) -> [Decimal] {
        let offsets = shape.samples.ascending
        switch limit {
        case let .numeric(value, _):
            return [
                value.value - Decimal(offsets[2]) / 1_000,
                value.value - Decimal(offsets[0]) / 1_000,
            ]
        case .thermal:
            return [Decimal(offsets[0]), Decimal(offsets[2])]
        }
    }

    /// The declared summary of those samples: inside their range, and inside the limit.
    func summary(for limit: ValidatedLimit) -> Decimal {
        let offsets = shape.samples.ascending
        switch limit {
        case let .numeric(value, _):
            return value.value - Decimal(offsets[1]) / 1_000
        case .thermal:
            return Decimal(offsets[1])
        }
    }

    /// One recorded measurement.
    ///
    /// `summaryLimit` exists for the arm that moves the recorded limit away from the
    /// declared one: the samples and summary stay the ones the run observed against the
    /// declared limit, so the only difference is the contract the record claims.
    func measurementRecord(
        _ key: TargetMetric,
        limit: ValidatedLimit,
        summaryLimit: ValidatedLimit? = nil,
        specification: EvidenceSource? = nil,
        summaryStatistic statisticOverride: SummaryStatistic? = nil,
        outcome: GateOutcome = .passed
    ) throws -> MeasurementRecord {
        let observed = summaryLimit ?? limit
        return try MeasurementRecord(
            metric: key.metric,
            target: key.target,
            specification: specification ?? planEvidence,
            rawValues: rawValues(for: observed),
            summaryStatistic: statisticOverride ?? summaryStatistic,
            summaryValue: summary(for: observed),
            limit: limit,
            outcome: outcome
        )
    }

    func measurementRecords(
        specifications: [TargetMetric: ResourceMeasurementSpecification]
    ) throws -> [TargetMetric: MeasurementRecord] {
        try specifications.reduce(into: [:]) { table, entry in
            table[entry.key] = try measurementRecord(
                entry.key,
                limit: entry.value.passLimit
            )
        }
    }

    /// One recorded comparison, with full agreement and the deviation the run observed.
    ///
    /// `reportsDeviation` is the one knob: a numeric comparison has to report the deviation
    /// it measured, and one arm needs one that does not. A categorical comparison never
    /// reports a deviation, so the flag does not apply to it.
    func comparisonRecord(
        _ metric: ComparisonMetric,
        specification: EvidenceSource? = nil,
        reportsDeviation: Bool = true
    ) throws -> ComparisonRecord {
        let observed = metric.isCategorical || !reportsDeviation
            ? nil
            : try NonNegativeDecimal(validating: deviation)
        let compared = try NonNegativeCount(validating: comparedFixtureCount)
        return try ComparisonRecord(
            metric: metric,
            specification: specification ?? planEvidence,
            comparedFixtureCount: compared,
            agreeingFixtureCount: compared,
            maximumDeviation: observed,
            outcome: .passed
        )
    }

    func comparisonRecords(
        specifications: [ComparisonMetric: ComparisonSpecification]
    ) throws -> [ComparisonMetric: ComparisonRecord] {
        try specifications.keys.reduce(into: [:]) { $0[$1] = try comparisonRecord($1) }
    }

    // MARK: Gate records and result set

    /// The recorded gate results.
    ///
    /// A comparison an arm drops is named explicitly rather than removed from the table,
    /// because a gate whose comparison list came back empty would otherwise be filled in
    /// from a fallback and the arm would pass vacuously — which is exactly what happened
    /// on the first run of this file.
    func gateRecords(
        measurements: [TargetMetric: MeasurementRecord],
        comparisons: [ComparisonMetric: ComparisonRecord],
        omittingComparison omittedComparison: ComparisonMetric? = nil,
        provenanceApplicable: Bool? = nil,
        omittingGate omitted: DeviceGate? = nil,
        duplicatingGate duplicated: DeviceGate? = nil
    ) throws -> [DeviceGateResultRecord] {
        var gates = DeviceGate.mandatoryGates
            .sorted { $0.rawValue < $1.rawValue }
            .filter { $0 != omitted }
        if let duplicated { gates.append(duplicated) }

        return try gates.map { gate in
            let applicable = gate.isProvenanceConditional
                ? (provenanceApplicable ?? shape.provenanceEnabled)
                : true
            guard applicable else {
                return try DeviceGateResultRecord(
                    gate: gate,
                    applicability: Sample.notApplicable(),
                    outcome: .notExecuted,
                    measurements: [],
                    comparisons: []
                )
            }
            let target = gate.measurementTarget
            let measured = (Self.measuredMetrics[gate] ?? []).compactMap { metric in
                measurements[TargetMetric(target: target ?? .mainApplication, metric: metric)]
            }
            let compared = try Self.comparedMetrics(for: gate)
                .filter { $0 != omittedComparison }
                .map { metric in
                    // The provenance comparison is predeclared only when the capability is
                    // enabled, so a gate forced applicable under a pixel-only capability
                    // set records one built here rather than one from the plan's table.
                    try comparisons[metric] ?? comparisonRecord(metric)
                }
            // A gate that has nothing left to report records that it did not run, rather
            // than being padded so it looks like it did.
            return try DeviceGateResultRecord(
                gate: gate,
                applicability: .applicable,
                outcome: measured.isEmpty && compared.isEmpty ? .notExecuted : .passed,
                measurements: measured,
                comparisons: compared
            )
        }
    }

    func resultSet(
        configuration: CandidateDeviceConfiguration,
        versionTuple: ValidationVersionTuple,
        gateResults: [DeviceGateResultRecord],
        environment: ExecutionEnvironment = .physicalIPhone
    ) throws -> DeviceValidationResultSet {
        try DeviceValidationResultSet(
            id: resultsID,
            schemaVersion: .v1,
            configuration: configuration,
            versionTuple: versionTuple,
            environment: environment,
            gateResults: gateResults
        )
    }
}

// MARK: - Fault classification

/// Which ``ArtifactSchemaError`` a refusal reported, without its value strings.
///
/// Asserting the case rather than the whole value keeps the property about *why* an
/// artifact was refused while leaving the audit message free to change. The field is
/// asserted separately, because most arms here land on the same case.
private enum PlanCompletenessFault: Equatable {
    case emptyValue
    case placeholderValue
    case noncanonicalValue
    case valueOutOfRange
    case nonPositiveValue
    case nonFiniteValue
    case duplicateEntry
    case missingRequiredEntries
    case unexpectedEntries
    case fixedValueMismatch
    case forbiddenValue
    case inconsistentReference

    init(_ error: ArtifactSchemaError) {
        switch error {
        case .emptyValue: self = .emptyValue
        case .placeholderValue: self = .placeholderValue
        case .noncanonicalValue: self = .noncanonicalValue
        case .valueOutOfRange: self = .valueOutOfRange
        case .nonPositiveValue: self = .nonPositiveValue
        case .nonFiniteValue: self = .nonFiniteValue
        case .duplicateEntry: self = .duplicateEntry
        case .missingRequiredEntries: self = .missingRequiredEntries
        case .unexpectedEntries: self = .unexpectedEntries
        case .fixedValueMismatch: self = .fixedValueMismatch
        case .forbiddenValue: self = .forbiddenValue
        case .inconsistentReference: self = .inconsistentReference
        }
    }

    /// The artifact field a refusal named. Every case names one.
    static func reportedField(_ error: ArtifactSchemaError) -> String {
        switch error {
        case let .emptyValue(field): field
        case let .placeholderValue(field, _): field
        case let .noncanonicalValue(field, _): field
        case let .valueOutOfRange(field, _, _): field
        case let .nonPositiveValue(field, _): field
        case let .nonFiniteValue(field, _): field
        case let .duplicateEntry(field, _): field
        case let .missingRequiredEntries(field, _): field
        case let .unexpectedEntries(field, _): field
        case let .fixedValueMismatch(field, _, _): field
        case let .forbiddenValue(field, _, _): field
        case let .inconsistentReference(field, _, _): field
        }
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator actually produced, so the property cannot pass by
/// generating one fixed shape a hundred times.
///
/// A property whose baseline never varies asserts one example a hundred times over. This
/// collects the dimensions the arms depend on and requires each to have been exercised
/// with more than one value. It also counts the coherent baselines that were actually
/// built: a run where every baseline construction threw would otherwise report nothing,
/// because `propertyCheck` discards an error thrown by its body.
private final class PlanCompletenessVariationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var limitValues = Set<Decimal>()
    private var summaryValues = Set<Decimal>()
    private var candidateCounts = Set<Int>()
    private var provenanceFlags = Set<Bool>()
    private var thermalCeilings = Set<ThermalState>()
    private var toleranceKinds = Set<ToleranceKind>()
    private var agreementRatios = Set<Int>()
    private var comparedCounts = Set<Int>()
    private var statistics = Set<Int>()
    private var referenceSites = Set<Int>()
    private var families = Set<FixtureFamily>()
    private var provenanceFamilies = Set<FixtureFamily>()
    private var gates = Set<DeviceGate>()
    private var fixtureCounts = Set<Int>()
    private var cases = 0
    private var baselines = 0

    func record(_ shape: PlanCompletenessShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        limitValues.formUnion(shape.magnitudes.map(\.value))
        candidateCounts.insert(shape.devices.count)
        provenanceFlags.insert(shape.provenanceEnabled)
        thermalCeilings.formUnion(shape.thermalCeilings)
        toleranceKinds.insert(
            ToleranceKind.allCases[
                shape.comparison.toleranceKindIndex % ToleranceKind.allCases.count
            ]
        )
        agreementRatios.insert(shape.comparison.agreementThousandths)
        comparedCounts.insert(shape.comparison.extraComparedFixtures)
        statistics.insert(shape.method.statisticIndex)
        referenceSites.insert(shape.selectors.referenceSite % ReferenceSite.allCases.count)
    }

    func recordBaseline(_ scenario: PlanCompletenessScenario) {
        lock.lock()
        defer { lock.unlock() }
        baselines += 1
        summaryValues.formUnion(scenario.measurementRecords.values.map(\.summaryValue))
        families.insert(scenario.selectedFamily)
        provenanceFamilies.insert(scenario.selectedProvenanceFamily)
        gates.insert(scenario.selectedGate)
        fixtureCounts.insert(scenario.fixtures.count)
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases")
        #expect(baselines == cases, "every generated case built a coherent baseline")
        // One shape carries 11 numeric limits, so a constant baseline would show 11.
        #expect(limitValues.count >= 100, "generated limit values: \(limitValues.count)")
        #expect(summaryValues.count >= 100, "recorded summary values: \(summaryValues.count)")
        #expect(candidateCounts == [1, 2], "generated candidate counts: \(candidateCounts.sorted())")
        #expect(provenanceFlags == [false, true], "both capability sets are generated")
        #expect(
            thermalCeilings == Set(PlanCompletenessShape.admissibleThermalStates),
            "generated thermal ceilings: \(thermalCeilings.map(\.rawValue).sorted())"
        )
        #expect(
            toleranceKinds == Set(ToleranceKind.allCases),
            "generated tolerance kinds: \(toleranceKinds.map(\.rawValue).sorted())"
        )
        #expect(agreementRatios.count >= 50, "generated agreement ratios: \(agreementRatios.count)")
        #expect(comparedCounts.count >= 20, "generated compared counts: \(comparedCounts.count)")
        #expect(
            statistics.count == SummaryStatistic.allCases.count,
            "generated summary statistics: \(statistics.sorted())"
        )
        #expect(
            referenceSites.count == ReferenceSite.allCases.count,
            "every reference site was exercised: \(referenceSites.sorted())"
        )
        // The fixture inventory differs between the two capability sets by exactly the six
        // provenance families, so a run that only ever built one inventory shows one size.
        #expect(fixtureCounts.count == 2, "generated fixture inventory sizes: \(fixtureCounts.sorted())")
        #expect(families.count >= 10, "families exercised by the inventory arm: \(families.count)")
        #expect(
            provenanceFamilies == FixtureFamily.provenanceFamilies,
            "provenance families waived and dropped: \(provenanceFamilies.map(\.rawValue).sorted())"
        )
        #expect(gates.count >= 15, "gates exercised by the inventory arm: \(gates.count)")
    }
}
