import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// Requirement 13.16, asserted as a property of this process rather than as a rule the runner
// follows.
//
// The requirement is that physical-iPhone results are the only admissible release evidence and
// that M3 Pro timing is development evidence. This suite runs on a development Mac. So the
// honest thing for it to assert is not "the runner would reject a Mac result if it saw one" —
// it is that *this very run* cannot produce a satisfied parity gate, and that the report says
// why by name.
//
// Two barriers are checked separately, because they fail for different reasons and a change
// could remove one without the other:
//
//   1. **Per observation.** `QualifyingParityEvidence` has no initialiser reachable from a test
//      target, and the one inside the module refuses a non-physical environment, a
//      configuration outside the plan, a configuration other than the bound one, and a
//      different version tuple. A cell whose observation fails any of those reports
//      `.nonQualifyingEvidence` and cannot be satisfied.
//   2. **Per process.** `ParityRunReport.gateResult(for:)` consults
//      `ObservedParityEnvironment.current`, which is compiled from the platform. A host or
//      simulator process fails every applicable parity gate whatever its observations claim.
//
// Barrier 2 is why the suite's central assertion is a *contradiction* that the design allows on
// purpose: a run in which every cell agrees, and every gate still fails. An observation's
// environment is a claim its producer makes; a gate is a conclusion this process draws, and the
// process cannot claim to be a phone.

/// What a host or simulator process can and cannot conclude about a device gate.
@Suite("Parity physical-device gate")
struct ParityPhysicalDeviceGateTests {

    // MARK: - This process

    @Test("This process cannot produce physical-device evidence")
    func hostProcessCannotProduceDeviceEvidence() {
        // The observed environment is compiled from the platform. On the development Mac this
        // repository builds on, it is `developmentMac`; under a simulator it would be
        // `iOSSimulator`. Neither satisfies a device gate, and there is no parameter,
        // artifact, or approval that changes the value.
        #expect(!ObservedParityEnvironment.canProducePhysicalDeviceEvidence)
        #expect(ObservedParityEnvironment.current != .physicalIPhone)
        #expect(
            ObservedParityEnvironment.current == .developmentMac
                || ObservedParityEnvironment.current == .iOSSimulator
        )
        #expect(!ObservedParityEnvironment.current.isPhysicalDeviceEvidence)
    }

    @Test("Every applicable parity gate fails in this process even when every cell agrees")
    func everyGateFailsDespiteFullAgreement() throws {
        let binding = try Sample.parityBinding(provenanceApplicable: true)
        let report = ParityRunner(observations: FakeParityObservationStore.agreeing(with: binding))
            .run(binding)

        // The comparisons that can be made were made and agreed. Only screenshot geometry,
        // whose approved expected value is unrepresentable, is not satisfied.
        let unsatisfied = report.unsatisfiedCells
        #expect(unsatisfied.allSatisfy { $0.comparison == .screenshotGeometry })
        #expect(!report.satisfiedCells.isEmpty)

        // And every applicable parity gate fails anyway.
        for gate in DeviceGate.parityGates {
            let result = report.gateResult(for: gate)
            guard result.applicability.isApplicable else { continue }
            #expect(result.outcome == .failed, "\(gate.rawValue) must not pass in this process")
            #expect(
                result.processRefusal == .notPhysicalIPhone(ObservedParityEnvironment.current),
                "\(gate.rawValue) must name the process refusal"
            )
        }
        #expect(report.outcome == .failed)
        #expect(report.processRefusal == .notPhysicalIPhone(ObservedParityEnvironment.current))
    }

    @Test("The run records where it actually executed, not what its observations claimed")
    func reportRecordsTheProcessEnvironment() throws {
        let binding = try Sample.parityBinding()
        var store = FakeParityObservationStore.agreeing(with: binding)
        store.setEnvironmentEverywhere(.physicalIPhone)

        let report = ParityRunner(observations: store).run(binding)
        #expect(report.runEnvironment == ObservedParityEnvironment.current)
        #expect(report.runEnvironment != .physicalIPhone)
    }

    @Test("A run that owes a physical device says so")
    func runOwesAPhysicalDevice() throws {
        let binding = try Sample.parityBinding()
        let report = ParityRunner(observations: FakeParityObservationStore.agreeing(with: binding))
            .run(binding)

        #expect(report.owedInputs.contains(.physicalIPhoneRunEnvironment))
    }

    // MARK: - Per observation

    @Test("A non-physical observation cannot satisfy a cell", arguments: [
        ExecutionEnvironment.developmentMac, .iOSSimulator,
    ])
    func nonPhysicalObservationCannotSatisfyACell(environment: ExecutionEnvironment) throws {
        let binding = try Sample.parityBinding()
        var store = FakeParityObservationStore.agreeing(with: binding)
        store.setEnvironmentEverywhere(environment)

        let report = ParityRunner(observations: store).run(binding)
        #expect(report.satisfiedCells.isEmpty)

        let compared = binding.requiredCells.filter { $0.comparison != .screenshotGeometry }
        for cell in compared {
            guard case let .nonQualifyingEvidence(reason) = report.outcome(of: cell) else {
                Issue.record("\(cell.description) must refuse non-physical evidence")
                continue
            }
            #expect(reason == .notPhysicalIPhone(environment))
        }
        #expect(report.nonQualifyingCells.count == compared.count)
    }

    @Test("A single non-physical observation is enough to refuse one cell")
    func onePerCellRefusalIsIndependent() throws {
        let binding = try Sample.parityBinding()
        var store = FakeParityObservationStore.agreeing(with: binding)
        let subject = try #require(binding.requiredCells.first { $0.comparison == .rawLogit })
        store.setEnvironment(.developmentMac, for: subject)

        let report = ParityRunner(observations: store).run(binding)
        #expect(report.nonQualifyingCells.contains(subject))
        // Every other logit cell is unaffected, so the refusal is per observation.
        let others = binding.requiredCells(for: .rawLogit).filter { $0 != subject }
        #expect(others.allSatisfy { report.outcome(of: $0).isSatisfied })
    }

    @Test("Rank agreement refuses when any contributing logit is non-physical")
    func rankAgreementRefusesMixedEvidence() throws {
        let binding = try Sample.parityBinding(catalog: try Sample.distinctLogitCatalog())
        var store = FakeParityObservationStore.agreeing(with: binding)
        let parity = try #require(binding.catalog.suite.fixtures(in: .modelParity).last)
        store.setEnvironment(
            .iOSSimulator,
            for: ParityCell(
                subject: .fixture(parity.id, family: .modelParity),
                comparison: .rawLogit
            )
        )
        let rank = try #require(binding.requiredCells.first { $0.comparison == .rankAgreement })

        guard case let .nonQualifyingEvidence(reason) = ParityRunner(observations: store)
            .run(binding)
            .outcome(of: rank)
        else {
            Issue.record("one simulator logit must refuse the derived ordering")
            return
        }
        #expect(reason == .notPhysicalIPhone(.iOSSimulator))
    }

    @Test("An observation from another configuration cannot satisfy a cell")
    func otherConfigurationCannotSatisfyACell() throws {
        let binding = try Sample.parityBinding()
        var store = FakeParityObservationStore.agreeing(with: binding)
        let other = try Sample.candidateConfiguration(hardware: DeviceHardwareID("iPhone99.9")!)
        let subject = try #require(binding.requiredCells.first { $0.comparison == .rawLogit })
        store.setConfiguration(other, for: subject)

        guard case let .nonQualifyingEvidence(reason) = ParityRunner(observations: store)
            .run(binding)
            .outcome(of: subject)
        else {
            Issue.record("another configuration must be refused")
            return
        }
        #expect(
            reason
                == .configurationMismatch(
                    expected: binding.configuration.hardwareIdentifier,
                    observed: other.hardwareIdentifier
                )
        )
    }

    @Test("An observation under another version tuple cannot satisfy a cell")
    func otherVersionTupleCannotSatisfyACell() throws {
        let binding = try Sample.parityBinding()
        var store = FakeParityObservationStore.agreeing(with: binding)
        let subject = try #require(binding.requiredCells.first { $0.comparison == .rawLogit })
        store.setVersionTuple(
            try Sample.parityVersionTuple(provenanceEnabled: true),
            for: subject
        )

        guard case let .nonQualifyingEvidence(reason) = ParityRunner(observations: store)
            .run(binding)
            .outcome(of: subject)
        else {
            Issue.record("another version tuple must be refused")
            return
        }
        #expect(reason == .versionTupleMismatch)
    }

    @Test("A qualifying-evidence value cannot be constructed from this test target")
    func qualifyingEvidenceIsNotClientConstructible() throws {
        // The compile-time half of barrier 1, asserted the way the module's other
        // not-constructible claims are: the initialiser is declared without `public`, so no
        // caller outside `DefAIkeReleaseValidation` can build one — and therefore no caller
        // outside the module can build a `ParityAgreement` or a `ParityCellOutcome.agreed`.
        //
        // This test target reaches the type through `@testable import`, which is exactly why
        // the claim is checked against the declaration text rather than by trying to call it.
        let code = Self.strippingComments(
            try Self.moduleSource(named: "ParityValidationInputs.swift")
        )
        #expect(code.contains("public struct QualifyingParityEvidence: Hashable, Sendable {"))
        #expect(!code.contains("public init?(\n        observations:"))
        #expect(code.contains("    init?(\n        observations: [ParityObservation],"))
        // And it is not `Codable`: a decodable proof would be a second way in.
        #expect(!code.contains("public struct QualifyingParityEvidence: Hashable, Codable"))
    }

    @Test("Nothing in the parity sources lets a caller hand in an outcome")
    func noOutcomeParameterExists() throws {
        // The other half of "generated, not asserted". The result types keep module-internal
        // initialisers, so the only client-constructible values are the binding, the runner,
        // a cell, and an observation — none of which carries an outcome.
        let runner = Self.strippingComments(try Self.moduleSource(named: "ParityValidation.swift"))
        #expect(runner.components(separatedBy: "public init").count - 1 == 2)
        #expect(runner.contains("public init(\n        plan: DeviceValidationPlan,"))
        #expect(runner.contains("public init(observations: any ParityObservationReading)"))
        for declaration in [
            "public struct ParityAgreement: Hashable, Sendable {",
            "public struct ParityDisagreement: Hashable, Sendable {",
            "public struct ParityResultGap: Hashable, Sendable {",
            "public struct ParityGateResult: Hashable, Sendable {",
            "public struct ParityRunReport: Hashable, Sendable {",
        ] {
            #expect(runner.contains(declaration))
        }
        // None of them is `Codable`: a decodable result would be a second way in.
        #expect(!runner.contains("public struct ParityRunReport: Hashable, Codable"))
        #expect(!runner.contains("public struct ParityAgreement: Hashable, Codable"))

        let inputs = Self.strippingComments(
            try Self.moduleSource(named: "ParityValidationInputs.swift")
        )
        #expect(inputs.components(separatedBy: "public init").count - 1 == 2)
        #expect(inputs.contains("public init(subject: ParitySubject, comparison: ComparisonMetric)"))
        #expect(inputs.contains("public init(\n        cell: ParityCell,"))

        for name in Self.paritySources {
            let code = Self.strippingComments(try Self.moduleSource(named: name))
            for token in [
                "isSatisfied =", "isPassing =", "func markPassed", "func waive",
                "func override", "func force", "func assume",
            ] {
                #expect(!code.contains(token), "\(name) must not reference \(token)")
            }
        }
    }

    @Test("The runner has no way to relax the environment gate")
    func runnerTakesNoEnvironmentOverride() throws {
        let code = Self.strippingComments(try Self.moduleSource(named: "ParityValidation.swift"))
        for token in [
            "allowSimulator", "allowHost", "treatAsPhysical", "assumePhysical",
            "skipEnvironment", "ignoreEnvironment", "developmentMac", "iOSSimulator",
        ] {
            #expect(!code.contains(token), "the runner must not reference \(token)")
        }
        // One public entry point, taking the binding and nothing else.
        #expect(code.components(separatedBy: "public func run").count - 1 == 1)
        #expect(code.contains("public func run(_ binding: ParityRunBinding) -> ParityRunReport"))
        // The environment it records is the observed one, never a parameter.
        #expect(code.contains("runEnvironment: ObservedParityEnvironment.current"))
    }

    @Test("The observed environment is compiled from the platform, not read from anywhere")
    func observedEnvironmentIsCompiledIn() throws {
        let code = Self.strippingComments(
            try Self.moduleSource(named: "ParityValidationInputs.swift")
        )
        #expect(code.contains("#if targetEnvironment(simulator)"))
        #expect(code.contains("public static let current: ExecutionEnvironment"))
        // No settable storage, no injection point, and nothing read at runtime.
        for token in [
            "static var current", "ProcessInfo", "environment[", "UserDefaults",
            "Bundle", "func setCurrent", "current =",
        ] {
            #expect(!code.contains(token), "the observed environment must not reference \(token)")
        }
    }

    // MARK: - Helpers

    /// The parity sources this task added.
    static let paritySources = [
        "ParityValidationInputs.swift",
        "ParityValidationError.swift",
        "ParityValidationSeams.swift",
        "ParityValidation.swift",
    ]

    private static func moduleSourceFiles() throws -> [URL] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DefAIkeReleaseValidation")
        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "the module's sources must be readable for this to mean anything")
        return files
    }

    static func moduleSource(named name: String) throws -> String {
        let file = try #require(try moduleSourceFiles().first { $0.lastPathComponent == name })
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Removes `//` comment text so a scan reads code rather than documentation.
    ///
    /// The parity sources discuss every one of the forbidden tokens by name, so an unstripped
    /// scan would read the documentation and get weakened rather than obeyed.
    static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let marker = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<marker.lowerBound])
            }
            .joined(separator: "\n")
    }
}
