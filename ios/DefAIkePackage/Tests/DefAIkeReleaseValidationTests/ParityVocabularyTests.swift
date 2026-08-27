import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// The closed vocabularies and total mappings the parity runners rest on.
//
// Everything here is a statement about a switch written without a `default`. Those cannot be
// checked by a compiler assertion from outside the module, so they are checked the way the
// requirements read them: exhaustively, over `allCases`, in both directions.
//
// Three claims carry the most weight:
//
//   * every ``ComparisonMetric`` has a scope, an approved expectation source, a parity gate,
//     and an owed release input, so a new comparison cannot silently stop being required;
//   * the two gap vocabularies are disjoint and every case of both is reachable from a real
//     run, so neither is a list nobody consults; and
//   * ``ParityValueKind`` mirrors exactly the expectation kinds that map to a comparison, so an
//     observation cannot arrive in a shape no approved expectation could have been written in.

/// The closed vocabularies and the total mappings over them.
@Suite("Parity vocabularies")
struct ParityVocabularyTests {

    // MARK: - Comparison metrics

    @Test("Every comparison metric has a scope, an expected-value source, a gate, and an owed input")
    func everyMetricIsTotallyMapped() {
        for metric in ComparisonMetric.allCases {
            // Each of these is a total switch in the module. Reading them all is what proves
            // no metric fell through a `default` that does not exist.
            _ = metric.parityScope
            _ = metric.approvedExpectationSource
            _ = metric.parityGate
            _ = metric.owedReleaseInput
            _ = metric.standingObservationLimits
            #expect(DeviceGate.parityGates.contains(metric.parityGate), "\(metric.rawValue)")
        }
        #expect(ComparisonMetric.allCases.count == 8)
    }

    @Test("The eight comparisons map onto the seven parity gates Requirements 13.6-13.11 define")
    func metricsCoverTheParityGates() {
        let expected: [DeviceGate] = [
            .preprocessingParity,
            .rawLogitParity,
            .rankAgreement,
            .categoricalAgreement,
            .screenshotFidelity,
            .routeByteParity,
            .provenanceFixtures,
        ]
        #expect(Set(DeviceGate.parityGates) == Set(expected))
        #expect(DeviceGate.parityGates.count == 7)
        // Retained bytes and preservation status are the pair that share a gate.
        let shared = ComparisonMetric.allCases.filter { $0.parityGate == .routeByteParity }
        #expect(Set(shared) == Set<ComparisonMetric>([.retainedBytes, .bytePreservationStatus]))
    }

    @Test("Only the provenance comparison and gate are conditional")
    func onlyProvenanceIsConditional() {
        // Computed outside the macro: `#expect` expands a trailing key-path call into a
        // rethrowing invocation, which does not compile in a nonthrowing test body.
        // `isProvenanceConditional` on a comparison metric is the domain's own property, not
        // one this module restates: a second definition would be an ambiguous use here.
        let conditionalMetrics = ComparisonMetric.allCases.filter { $0.isProvenanceConditional }
        let conditionalGates = DeviceGate.parityGates.filter { $0.isProvenanceConditional }
        #expect(conditionalMetrics == [ComparisonMetric.provenanceState])
        #expect(conditionalGates == [DeviceGate.provenanceFixtures])
    }

    @Test("Exactly two comparisons are not read through the observation seam")
    func twoComparisonsAreNotObserved() {
        let unobserved = ComparisonMetric.allCases.filter { $0.requiredObservationKind == nil }
        #expect(Set(unobserved) == Set<ComparisonMetric>([.rankAgreement, .screenshotGeometry]))
        // Rank agreement is derived; screenshot geometry has no expected side at all.
        if case .derivedFromFamilyExpectations(let kind) =
            ComparisonMetric.rankAgreement.approvedExpectationSource
        {
            #expect(kind == .rawLogit)
        } else {
            Issue.record("rank agreement's expected ordering must be derived from raw logits")
        }
        if case .unrepresentable(let limit) =
            ComparisonMetric.screenshotGeometry.approvedExpectationSource
        {
            #expect(limit == .screenshotGeometryHasNoExpectationKind)
        } else {
            Issue.record("screenshot geometry must report an unrepresentable expected value")
        }
    }

    @Test("The observed value kinds mirror the expectation kinds that map to a comparison")
    func observedKindsMirrorExpectationKinds() throws {
        // One representative expectation per kind, so `referenceComparison` can be read.
        let representatives: [FixtureExpectationKind: FixtureExpectation] = [
            .pixelLabel: .pixelLabel(.notEnoughSignal),
            .rawLogit: .rawLogit(value: 0, tolerance: Sample.nonNegativeDecimal(0)),
            .preprocessingOutputDigest: .preprocessingOutputDigest(Sample.digest(1)),
            .retainedBytesDigest: .retainedBytesDigest(Sample.digest(2)),
            .bytePreservationStatus: .bytePreservationStatus(.unknown),
            .provenanceState: .provenanceState(.absent),
            .analysisError: .analysisError(.decodingError),
        ]
        #expect(representatives.count == FixtureExpectationKind.allCases.count)

        let comparable = FixtureExpectationKind.allCases.filter { kind in
            representatives[kind]?.referenceComparison != nil
        }
        #expect(comparable.count == ParityValueKind.allCases.count)
        #expect(comparable.count == 6)
        // The raw values agree name for name, so a reader can line the two vocabularies up.
        let comparableNames = Set(comparable.map { $0.rawValue })
        let observedNames = Set(ParityValueKind.allCases.map { $0.rawValue })
        #expect(comparableNames == observedNames)
        // And the one expectation that maps to no comparison is the terminal Analysis Error.
        let uncomparable = Set(FixtureExpectationKind.allCases).subtracting(comparable)
        #expect(uncomparable == Set<FixtureExpectationKind>([.analysisError]))
    }

    @Test("Every observed value reports its own kind")
    func observedValuesReportTheirKind() {
        let values: [ObservedParityValue] = [
            .preprocessingOutputDigest(Sample.digest(1)),
            .rawLogit(0),
            .pixelLabel(.notEnoughSignal),
            .retainedBytesDigest(Sample.digest(2)),
            .bytePreservationStatus(.unknown),
            .provenanceState(.absent),
        ]
        let kinds = Set(values.map { $0.kind })
        #expect(kinds == Set(ParityValueKind.allCases))
        #expect(values.count == ParityValueKind.allCases.count)
    }

    // MARK: - The gap vocabularies

    @Test("The release-input vocabulary is closed, unique, and canonically spelled")
    func unprovisionedInputsAreWellFormed() {
        let cases = UnprovisionedParityInput.allCases
        let names = Set(cases.map { $0.rawValue })
        #expect(cases.count == 12)
        #expect(names.count == cases.count)
        for value in cases {
            #expect(value.description == value.rawValue)
            #expect(!value.rawValue.isEmpty)
            let isCanonical = value.rawValue.allSatisfy { character in
                character.isLowercase || character.isNumber || character == "-"
            }
            #expect(isCanonical, "\(value.rawValue) must be lowercase kebab-case")
        }
    }

    @Test("The unobservable-evidence vocabulary is closed, unique, and canonically spelled")
    func unobservableEvidenceIsWellFormed() {
        let cases = UnobservableParityEvidence.allCases
        let names = Set(cases.map { $0.rawValue })
        #expect(cases.count == 8)
        #expect(names.count == cases.count)
        for value in cases {
            #expect(value.description == value.rawValue)
            let isCanonical = value.rawValue.allSatisfy { character in
                character.isLowercase || character.isNumber || character == "-"
            }
            #expect(isCanonical, "\(value.rawValue) must be lowercase kebab-case")
        }
    }

    @Test("Exactly one unobservable limit prevents a comparison from being made")
    func oneLimitBlocksComparison() {
        let blocking = UnobservableParityEvidence.allCases.filter { $0.blocksComparison }
        let permitting = UnobservableParityEvidence.allCases.filter { !$0.blocksComparison }
        #expect(blocking == [UnobservableParityEvidence.screenshotGeometryHasNoExpectationKind])
        // The other seven narrow what agreement establishes without preventing it.
        #expect(permitting.count == 7)
    }

    @Test("The two vocabularies are disjoint")
    func vocabulariesAreDisjoint() {
        // They record different blockers and are closed by different work, so a value cannot
        // legitimately appear in both. Sharing a raw value would let an audit satisfy one by
        // closing the other.
        let inputs = Set(UnprovisionedParityInput.allCases.map { $0.rawValue })
        let limits = Set(UnobservableParityEvidence.allCases.map { $0.rawValue })
        #expect(inputs.isDisjoint(with: limits))
        #expect(inputs.count + limits.count == 20)
    }

    @Test("Every unobservable limit is reachable from a real run's standing limits")
    func everyLimitIsReachable() {
        // A vocabulary nothing consults is documentation. Each of the eight is attached to at
        // least one comparison, so a provenance-enabled run reports all of them.
        let attached = Set(
            ComparisonMetric.allCases.flatMap { $0.standingObservationLimits }
        )
        #expect(attached == Set(UnobservableParityEvidence.allCases))
    }

    @Test("Every owed release input except two is reachable from a comparison")
    func owedInputsAreReachable() {
        // Six of the twelve are the per-comparison references. The other six are the artifacts
        // a run needs before it has any cells at all — a plan, a suite, the parity inventory
        // and its assets, a bound version tuple — plus the physical device, which the report
        // adds when the process cannot produce device evidence.
        let perComparison = Set(ComparisonMetric.allCases.map { $0.owedReleaseInput })
        #expect(
            perComparison == Set<UnprovisionedParityInput>([
                .preprocessingReferenceOutputs,
                .rawLogitReferences,
                .categoricalOutcomeReferences,
                .screenshotFixtureReferences,
                .routeByteReferences,
                .provenanceFixtureExpectations,
            ])
        )
        let structural = Set(UnprovisionedParityInput.allCases).subtracting(perComparison)
        #expect(
            structural == Set<UnprovisionedParityInput>([
                .deviceValidationPlan,
                .releaseFixtureSuite,
                .modelParityFixtureInventory,
                .modelParityFixtureAssets,
                .boundValidationVersionTuple,
                .physicalIPhoneRunEnvironment,
            ])
        )
    }

    @Test("Every observation fault is a refusal with a distinct description")
    func observationFaultsAreRefusals() {
        let cases = ParityObservationFault.allCases
        #expect(cases.count == 3)
        let descriptions = Set(cases.map { $0.description })
        #expect(descriptions.count == cases.count)
        #expect(cases.contains(.observationAbsent))
    }

    // MARK: - Cells and subjects

    @Test("A subject reports its family and, for a fixture, its identifier")
    func subjectsDescribeThemselves() {
        let fixture = ParitySubject.fixture(Sample.fixture("fixture.a"), family: .modelParity)
        let family = ParitySubject.family(.modelParity)

        #expect(fixture.family == .modelParity)
        #expect(fixture.fixture == Sample.fixture("fixture.a"))
        #expect(family.family == .modelParity)
        #expect(family.fixture == nil)
        #expect(fixture.description != family.description)
    }

    @Test("A cell's ordering key separates comparison from subject and is stable")
    func cellOrderingKeyIsStable() {
        let subject = ParitySubject.fixture(Sample.fixture("fixture.a"), family: .modelParity)
        let logit = ParityCell(subject: subject, comparison: .rawLogit)
        let label = ParityCell(subject: subject, comparison: .categoricalOutcome)

        #expect(logit.orderingKey != label.orderingKey)
        #expect(logit.orderingKey.hasPrefix(ComparisonMetric.rawLogit.rawValue))
        #expect(logit == ParityCell(subject: subject, comparison: .rawLogit))
        #expect(logit.description.contains("fixture.a"))
    }

    @Test("A cell carrying the wrong family is a different cell")
    func cellFamilyIsPartOfIdentity() {
        let id = Sample.fixture("fixture.a")
        #expect(
            ParityCell(subject: .fixture(id, family: .modelParity), comparison: .rawLogit)
                != ParityCell(
                    subject: .fixture(id, family: .physicalScreenshot),
                    comparison: .rawLogit
                )
        )
    }

    // MARK: - Outcomes

    @Test("Only agreement satisfies a cell, and only agreement and disagreement are comparisons")
    func outcomeClassificationIsExact() throws {
        // Built through a real run rather than by hand, because ``ParityAgreement`` has no
        // client-reachable initialiser. One run stages one of every shape.
        let binding = try Sample.parityBinding(provenanceApplicable: true)
        var store = FakeParityObservationStore.agreeing(with: binding)
        let cells = binding.requiredCells
        let agreeing = try #require(cells.first { $0.comparison == .categoricalOutcome })
        let missing = try #require(cells.first { $0.comparison == .retainedBytes })
        let refused = try #require(cells.first { $0.comparison == .provenanceState })
        let mismatched = try #require(cells.first { $0.comparison == .preprocessingOutput })
        let unrepresentable = try #require(cells.first { $0.comparison == .screenshotGeometry })
        let disagreeing = try #require(
            cells.first { $0.comparison == .categoricalOutcome && $0 != agreeing }
        )

        store.remove(missing)
        store.setEnvironment(.developmentMac, for: refused)
        store.set(.rawLogit(1), for: mismatched)
        store.set(.pixelLabel(.notEnoughSignal), for: disagreeing)

        let report = ParityRunner(observations: store).run(binding)
        #expect(report.outcome(of: agreeing).isSatisfied)
        #expect(report.outcome(of: agreeing).wasCompared)
        #expect(report.outcome(of: agreeing).outcome == .passed)

        for cell in [disagreeing] {
            #expect(!report.outcome(of: cell).isSatisfied)
            #expect(report.outcome(of: cell).wasCompared)
            #expect(report.outcome(of: cell).outcome == .failed)
        }
        for cell in [missing, refused, mismatched, unrepresentable] {
            let outcome = report.outcome(of: cell)
            #expect(!outcome.isSatisfied, "\(cell.description)")
            #expect(!outcome.wasCompared, "\(cell.description)")
            #expect(outcome.outcome == .failed, "\(cell.description)")
            #expect(!outcome.description.isEmpty)
        }
    }

    @Test("A run over a complete catalogue records one outcome per required cell and no more")
    func outcomesCoverTheRequiredSetExactly() throws {
        let binding = try Sample.parityBinding(provenanceApplicable: true)
        let report = ParityRunner(observations: FakeParityObservationStore.agreeing(with: binding))
            .run(binding)

        #expect(report.requiredCells == binding.requiredCells)
        #expect(
            report.satisfiedCells.count + report.unsatisfiedCells.count
                == binding.requiredCells.count
        )
        #expect(Set(report.satisfiedCells).isDisjoint(with: Set(report.unsatisfiedCells)))
    }

    @Test("A report identifies the exact tuple it was produced under")
    func reportCarriesItsIdentity() throws {
        let binding = try Sample.parityBinding()
        let report = ParityRunner(observations: FakeParityObservationStore.empty(for: binding))
            .run(binding)

        #expect(report.plan == binding.plan.id)
        #expect(report.fixtureSuite == binding.catalog.suite.id)
        #expect(report.configuration == binding.configuration)
        #expect(report.versionTuple == binding.versionTuple)
    }

    // MARK: - Non-parity gates

    @Test("A parity report claims nothing about a resource, thermal, or accessibility gate")
    func nonParityGatesAreNotClaimed() throws {
        let binding = try Sample.parityBinding(provenanceApplicable: true)
        let report = ParityRunner(observations: FakeParityObservationStore.agreeing(with: binding))
            .run(binding)

        let others = DeviceGate.mandatoryGates.subtracting(Set(DeviceGate.parityGates))
        #expect(!others.isEmpty)
        for gate in others.sorted(by: { $0.rawValue < $1.rawValue }) {
            let result = report.gateResult(for: gate)
            #expect(result.cells.isEmpty, "\(gate.rawValue)")
            #expect(result.outcome == .failed, "\(gate.rawValue) must not be claimed as passing")
        }
    }

    // MARK: - The seam

    @Test("The observation seam offers one member and no way to list, write, or summarise")
    func seamOffersNothingElse() throws {
        let code = ParityPhysicalDeviceGateTests.strippingComments(
            try ParityPhysicalDeviceGateTests.moduleSource(named: "ParityValidationSeams.swift")
        )
        for token in [
            "func observations", "func allObservations", "func availableCells", "func count",
            "func write", "func record", "func publish", "func cache", "func store",
            "func ordering", "func rank", "func summary", "func expected", "func tolerance",
            "-> [ParityObservation]", "-> ParityObservation?", "= nil",
            "extension ParityObservationReading",
        ] {
            #expect(!code.contains(token), "the observation seam must not declare \(token)")
        }
        #expect(code.components(separatedBy: "    func ").count - 1 == 1)
        #expect(code.contains("func observation("))
        #expect(
            code.components(
                separatedBy: ") throws(ParityObservationFault) -> ParityObservation"
            ).count - 1 == 1
        )
    }

    @Test("No default observation reader exists anywhere in the module")
    func moduleShipsNoObservationReader() throws {
        // A runner cannot be constructed without a reader, and this is the other half: nothing
        // in the module conforms to the seam, so there is no implementation a caller could fall
        // back to. The only conformer is in the tests.
        for name in ParityPhysicalDeviceGateTests.paritySources {
            let code = ParityPhysicalDeviceGateTests.strippingComments(
                try ParityPhysicalDeviceGateTests.moduleSource(named: name)
            )
            #expect(
                !code.contains(": ParityObservationReading {"),
                "\(name) must not implement the observation seam"
            )
        }
    }

    @Test("Nothing in the parity sources can produce an expected value")
    func runnerProducesNoExpectedValue() throws {
        // The expected side of every comparison comes from the signed catalogue. A module that
        // could hash, render, decode, resize, crop, or infer one could complete a catalogue
        // from the implementation under test, which is exactly what task 14.1's schema exists
        // to prevent.
        for name in ParityPhysicalDeviceGateTests.paritySources {
            let code = ParityPhysicalDeviceGateTests.strippingComments(
                try ParityPhysicalDeviceGateTests.moduleSource(named: name)
            )
            for token in [
                "CryptoKit", "SHA256.hash", "Insecure.", ".finalize()", "Hasher(",
                "func expectedDigest", "func computeExpected", "func deriveExpected",
                "func preprocess", "func infer", "func resize", "func crop", "MLModel",
                "CGImage", "vImage", "import CoreML", "import ImageIO",
            ] {
                #expect(!code.contains(token), "\(name) must not reference \(token)")
            }
        }
    }
}
