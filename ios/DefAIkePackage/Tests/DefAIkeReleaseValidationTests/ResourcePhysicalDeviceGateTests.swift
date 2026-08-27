import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// Requirement 13.16, asserted as a property of this process rather than as a rule the harness
// follows.
//
// The requirement is that physical-iPhone results are the only admissible release evidence and
// that M3 Pro timing is development evidence. This suite runs on a development Mac. So the honest
// thing for it to assert is not "the harness would reject a Mac measurement if it saw one" — it is
// that *this very run* cannot produce a satisfied resource gate, and that the report says why by
// name.
//
// Two barriers are checked separately, because they fail for different reasons and a change could
// remove one without the other:
//
//   1. **Per sample.** ``QualifyingResourceEvidence`` has no initialiser reachable from a test
//      target, and the one inside the module refuses a non-physical environment, a sample from the
//      other target's process, a configuration outside the plan, a configuration other than the
//      bound one, and a different version tuple. A cell whose samples fail any of those reports
//      ``ResourceCellOutcome/nonQualifyingEvidence(_:)`` and cannot be satisfied.
//   2. **Per process.** ``ResourceTargetReport/gateResult(for:)`` consults
//      ``ObservedParityEnvironment/current``, which is compiled from the platform. A host or
//      simulator process fails every resource gate whatever its samples claim.
//
// Barrier 2 is why this suite's central assertion is a *contradiction* the design allows on
// purpose: a run in which every measurable cell reads inside its limit, and every gate still
// fails. A sample's environment is a claim its producer makes; a gate is a conclusion this process
// draws, and the process cannot claim to be a phone.
//
// One thing differs from the parity equivalent, and it is a finding rather than a gap in the test.
// A parity run can reach full cell agreement on a host, because a comparison needs only two
// values. A resource run cannot: five budget metrics have no measurement path in this repository
// and two of the nine enumerated measurements cannot be predeclared, so even a store with every
// sample present leaves seven main-application cells and six Share Extension cells refused before
// the seam. The contradiction is therefore narrower and stated as such: every cell that *can* be
// measured reads inside its limit, and every gate still fails.

/// What a host or simulator process can and cannot conclude about a resource gate.
@Suite("Resource physical-device gate")
struct ResourcePhysicalDeviceGateTests {

    // MARK: - This process

    @Test("This process cannot produce physical-device evidence")
    func hostProcessCannotProduceDeviceEvidence() {
        // Reused rather than redeclared. There is exactly one statement in this module of where
        // the running process is, and adding a second would create a way for the two to disagree.
        #expect(!ObservedParityEnvironment.canProducePhysicalDeviceEvidence)
        #expect(ObservedParityEnvironment.current != .physicalIPhone)
        #expect(
            ObservedParityEnvironment.current == .developmentMac
                || ObservedParityEnvironment.current == .iOSSimulator
        )
        #expect(!ObservedParityEnvironment.current.isPhysicalDeviceEvidence)
    }

    @Test("Every resource gate fails in this process even when every measurable cell passes")
    func everyGateFailsDespiteEveryMeasurableCellPassing() throws {
        let binding = try Sample.resourceRunBinding()
        var store = FakeResourceSampleStore.complete(for: binding)
        store.setEnvironmentEverywhere(.physicalIPhone)
        let report = ResourceMeasurementRunner(samples: store).run(binding)

        for target in ExecutionTarget.allCases {
            let scoped = report.report(for: target)
            // Every cell whose measurement can be taken at all was taken and read inside its
            // approved limit.
            let readable = Sample.readableCells(of: binding.binding(for: target))
            #expect(!readable.isEmpty)
            for cell in readable {
                #expect(
                    scoped.outcome(of: cell).isSatisfied,
                    "\(cell.description) should read inside its limit"
                )
            }
            // Everything else is refused before the seam, and names why.
            for cell in Sample.blockedCells(of: binding.binding(for: target)) {
                guard case .measurementUnavailable = scoped.outcome(of: cell) else {
                    Issue.record("a blocked cell must report that no measurement is available")
                    continue
                }
            }
            // And every gate fails anyway.
            for gate in DeviceGate.resourceGates {
                let result = scoped.gateResult(for: gate)
                #expect(result.outcome == .failed, "\(gate.rawValue) must not pass in this process")
                #expect(
                    result.processRefusal
                        == .notPhysicalIPhone(ObservedParityEnvironment.current),
                    "\(gate.rawValue) must name the process refusal"
                )
                // No resource gate is provenance conditional, so `notExecuted` is unreachable.
                #expect(result.applicability == .applicable)
                #expect(result.outcome != .notExecuted)
            }
            #expect(scoped.outcome == .failed)
            #expect(scoped.processRefusal == .notPhysicalIPhone(ObservedParityEnvironment.current))
        }
        #expect(report.outcome == .failed)
        #expect(report.processRefusal == .notPhysicalIPhone(ObservedParityEnvironment.current))
    }

    @Test("A gate that would pass on its cells alone still fails on the process")
    func aFullyPassingGateStillFails() throws {
        // The sharpest form of the contradiction, on one gate. Peak resident memory has a
        // measurement path, its whole declared series came back, every sample claims a physical
        // iPhone, and the summary is inside the approved ceiling. The cell passes and the gate
        // does not.
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        var store = FakeResourceSampleStore.complete(for: binding)
        store.setEnvironmentEverywhere(.physicalIPhone)
        let report = ResourceMeasurementRunner(samples: store).run(binding)

        let cell = try #require(binding.requiredCells.first { $0.metric == .peakResidentMemory })
        #expect(report.outcome(of: cell).isSatisfied)
        #expect(report.record(of: cell).summary.isComplete)
        #expect(report.record(of: cell).summary.completeness == .one)

        let result = report.gateResult(for: .mainApplicationPeakMemory)
        #expect(result.cells == [cell])
        #expect(result.measuredCompleteness == .one)
        #expect(result.outcome == .failed)
        #expect(result.processRefusal == .notPhysicalIPhone(ObservedParityEnvironment.current))
    }

    @Test("The run records where it actually executed, not what its samples claimed")
    func reportRecordsTheProcessEnvironment() throws {
        let binding = try Sample.resourceRunBinding()
        var store = FakeResourceSampleStore.complete(for: binding)
        store.setEnvironmentEverywhere(.physicalIPhone)
        let report = ResourceMeasurementRunner(samples: store).run(binding)
        #expect(report.runEnvironment == ObservedParityEnvironment.current)
        #expect(report.runEnvironment != .physicalIPhone)
        for target in ExecutionTarget.allCases {
            #expect(report.report(for: target).runEnvironment == ObservedParityEnvironment.current)
        }
    }

    @Test("A run that owes a physical device says so")
    func runOwesAPhysicalDevice() throws {
        let binding = try Sample.resourceRunBinding()
        var store = FakeResourceSampleStore.complete(for: binding)
        store.setEnvironmentEverywhere(.physicalIPhone)
        let report = ResourceMeasurementRunner(samples: store).run(binding)
        #expect(report.owedInputs.contains(.physicalIPhoneMeasurementEnvironment))
    }

    // MARK: - Per sample

    @Test("A non-physical sample cannot satisfy a cell", arguments: [
        ExecutionEnvironment.developmentMac, .iOSSimulator,
    ])
    func nonPhysicalSampleCannotSatisfyACell(environment: ExecutionEnvironment) throws {
        let binding = try Sample.resourceRunBinding()
        var store = FakeResourceSampleStore.complete(for: binding)
        store.setEnvironmentEverywhere(environment)
        let report = ResourceMeasurementRunner(samples: store).run(binding)

        for target in ExecutionTarget.allCases {
            let scoped = report.report(for: target)
            #expect(scoped.satisfiedCells.isEmpty)
            let readable = Sample.readableCells(of: binding.binding(for: target))
            for cell in readable {
                guard case let .nonQualifyingEvidence(reason) = scoped.outcome(of: cell) else {
                    Issue.record("a readable cell must refuse non-physical evidence")
                    continue
                }
                #expect(reason == .notPhysicalIPhone(environment))
            }
            #expect(scoped.nonQualifyingCells.count == readable.count)
        }
    }

    @Test("A single non-physical sample is enough to refuse one measurement")
    func onePerCellRefusalIsIndependent() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        var store = FakeResourceSampleStore.complete(for: binding)
        store.setEnvironmentEverywhere(.physicalIPhone)
        let subject = try #require(binding.requiredCells.first { $0.metric == .peakResidentMemory })
        store.setEnvironment(.developmentMac, for: subject)

        let report = ResourceMeasurementRunner(samples: store).run(binding)
        #expect(report.nonQualifyingCells.contains(subject))
        // Every other readable cell is unaffected, so the refusal is per measurement.
        let others = Sample.readableCells(of: binding).filter { $0 != subject }
        #expect(!others.isEmpty)
        #expect(others.allSatisfy { report.outcome(of: $0).isSatisfied })
    }

    @Test("One non-physical sample refuses the whole declared series")
    func oneSampleRefusesTheWholeSeries() throws {
        // A measurement is a series, and a series is only as admissible as its least admissible
        // sample. Otherwise a run could take four samples on a phone, one on a Mac, and summarize
        // the five as a device measurement.
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        let subject = try #require(binding.requiredCells.first { $0.metric == .peakResidentMemory })
        let declared = binding.declaredSampleCount(for: subject)
        let mixed = MixedEnvironmentSampleStore(
            backing: FakeResourceSampleStore.complete(for: binding),
            foreignOrdinal: declared - 1,
            foreignEnvironment: .iOSSimulator,
            cell: subject
        )
        guard case let .nonQualifyingEvidence(reason) = ResourceMeasurementRunner(samples: mixed)
            .run(binding)
            .outcome(of: subject)
        else {
            Issue.record("one simulator sample must refuse the whole series")
            return
        }
        #expect(reason == .notPhysicalIPhone(.iOSSimulator))
    }

    @Test("A sample from another configuration cannot satisfy a cell")
    func otherConfigurationCannotSatisfyACell() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        var store = FakeResourceSampleStore.complete(for: binding)
        store.setEnvironmentEverywhere(.physicalIPhone)
        let other = try Sample.candidateConfiguration(hardware: DeviceHardwareID("iPhone99.9")!)
        let subject = try #require(binding.requiredCells.first { $0.metric == .peakResidentMemory })
        store.setConfiguration(other, for: subject)

        guard case let .nonQualifyingEvidence(reason) = ResourceMeasurementRunner(samples: store)
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

    @Test("A sample under another version tuple cannot satisfy a cell")
    func otherVersionTupleCannotSatisfyACell() throws {
        let binding = try Sample.resourceTargetBinding(target: .mainApplication)
        var store = FakeResourceSampleStore.complete(for: binding)
        store.setEnvironmentEverywhere(.physicalIPhone)
        let subject = try #require(binding.requiredCells.first { $0.metric == .thermalState })
        store.setVersionTuple(
            try Sample.resourceVersionTuple(provenanceEnabled: true),
            for: subject
        )

        guard case let .nonQualifyingEvidence(reason) = ResourceMeasurementRunner(samples: store)
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
        // not-constructible claims are: the initialiser is declared without `public`, so no caller
        // outside `DefAIkeReleaseValidation` can build one — and therefore no caller outside the
        // module can build a `ResourceMeasurementAgreement` or a `ResourceCellOutcome.withinLimit`.
        //
        // This test target reaches the type through `@testable import`, which is exactly why the
        // claim is checked against the declaration text rather than by trying to call it.
        let code = Self.strippingComments(
            try Self.moduleSource(named: "ResourceValidationInputs.swift")
        )
        #expect(code.contains("public struct QualifyingResourceEvidence: Hashable, Sendable {"))
        #expect(!code.contains("public init?(\n        samples:"))
        #expect(code.contains("    init?(\n        samples: [ResourceSample],"))
        // And it is not `Codable`: a decodable proof would be a second way in.
        #expect(!code.contains("public struct QualifyingResourceEvidence: Hashable, Codable"))
        // Nor is a sample index, so a caller cannot mint a position outside the declared series.
        #expect(code.contains("    init(ordinal: Int) {"))
        #expect(!code.contains("public init(ordinal: Int)"))
    }

    @Test("Nothing in the resource sources lets a caller hand in an outcome")
    func noOutcomeParameterExists() throws {
        let runner = Self.strippingComments(try Self.moduleSource(named: "ResourceValidation.swift"))
        // Four public initialisers: two bindings and the runner, plus nothing else.
        #expect(runner.components(separatedBy: "public init").count - 1 == 3)
        #expect(runner.contains("public init(\n        target: ExecutionTarget,"))
        #expect(runner.contains("public init(\n        plan: DeviceValidationPlan,"))
        #expect(runner.contains("public init(samples: any ResourceSampleReading)"))
        for declaration in [
            "public struct ResourceMeasurementAgreement: Hashable, Sendable {",
            "public struct ResourceLimitExceedance: Hashable, Sendable {",
            "public struct ResourceMeasurementGap: Hashable, Sendable {",
            "public struct ResourceMeasurementSummary: Hashable, Sendable {",
            "public struct ResourceCellRecord: Hashable, Sendable {",
            "public struct ResourceGateResult: Hashable, Sendable {",
            "public struct ResourceTargetReport: Hashable, Sendable {",
            "public struct ResourceValidationReport: Hashable, Sendable {",
        ] {
            #expect(runner.contains(declaration), "missing declaration: \(declaration)")
        }
        // None of them is `Codable`: a decodable result would be a second way in.
        #expect(!runner.contains("public struct ResourceTargetReport: Hashable, Codable"))
        #expect(!runner.contains("public struct ResourceValidationReport: Hashable, Codable"))
        #expect(!runner.contains("public struct ResourceMeasurementAgreement: Hashable, Codable"))

        for name in Self.resourceSources {
            let code = Self.strippingComments(try Self.moduleSource(named: name))
            for token in [
                "isSatisfied =", "isPassing =", "func markPassed", "func waive", "func override",
                "func force", "func assume", "func approximate",
            ] {
                #expect(!code.contains(token), "\(name) must not reference \(token)")
            }
        }
    }

    @Test("The runner has no way to relax the environment gate")
    func runnerTakesNoEnvironmentOverride() throws {
        let code = Self.strippingComments(try Self.moduleSource(named: "ResourceValidation.swift"))
        for token in [
            "allowSimulator", "allowHost", "treatAsPhysical", "assumePhysical", "skipEnvironment",
            "ignoreEnvironment", "developmentMac", "iOSSimulator",
        ] {
            #expect(!code.contains(token), "the runner must not reference \(token)")
        }
        // Two public entry points, each taking a binding and nothing else.
        #expect(code.components(separatedBy: "public func run").count - 1 == 2)
        #expect(
            code.contains(
                "public func run(_ binding: ResourceValidationRunBinding) -> ResourceValidationReport"
            )
        )
        #expect(code.contains("public func run(_ binding: ResourceTargetBinding) -> ResourceTargetReport"))
        // The environment it records is the observed one, never a parameter.
        #expect(code.contains("runEnvironment: ObservedParityEnvironment.current"))
    }

    @Test("Nothing in the resource sources reads a clock or holds a duration")
    func noTimeoutIsSynthesized() throws {
        // Requirements 15.8 and 15.9 make the plan the authoritative source of numeric
        // analysis-time limits, and Property 36 forbids creating one from elapsed time. A harness
        // that timed anything itself would be doing exactly that, so no source here reads a clock,
        // holds a `Duration`, or sleeps.
        for name in Self.resourceSources {
            let code = Self.strippingComments(try Self.moduleSource(named: name))
            for token in [
                "ContinuousClock", "SuspendingClock", "DispatchTime", "CFAbsoluteTime",
                "mach_absolute_time", "Task.sleep", "ValidatedDuration", "timeIntervalSince",
                "Date()", ": Duration", "-> Duration", "Duration(", "Duration.",
                "timeout", "Timeout",
            ] {
                #expect(!code.contains(token), "\(name) must not reference \(token)")
            }
        }
        // The words "duration" and "deadline" *do* occur, and only as gap-vocabulary case names —
        // the names of things this module records as owed and refuses to supply. Asserted as the
        // narrower true claim rather than as an absence that is not the case.
        for name in Self.resourceSources {
            let offending = Self.lines(
                of: try Self.moduleSource(named: name),
                containing: "eadline"
            )
            .filter { !$0.contains("dataLifecycleCleanupDeadlines") }
            #expect(offending.isEmpty, "\(name) mentions a deadline outside the owed vocabulary")

            let source = try Self.moduleSource(named: name)
            let durations = (
                Self.lines(of: source, containing: "Duration")
                    + Self.lines(of: source, containing: "duration")
            )
            .filter {
                !$0.contains("sustainedThermalDuration")
                    && !$0.contains("sustained-thermal-duration")
            }
            #expect(durations.isEmpty, "\(name) mentions a duration outside the owed vocabulary")
        }
    }

    @Test("The resource sources manufacture no limit, sample count, or statistic of their own")
    func noApprovedValueIsManufacturedHere() throws {
        // Every number a run compares against comes from the plan or a budget. The runner
        // constructs no limit, no count, and no thermal state, so it has nothing of its own to
        // compare against.
        let code = Self.strippingComments(try Self.moduleSource(named: "ResourceValidation.swift"))
        for token in [
            "PositiveDecimal(", "PositiveCount(", "ValidatedLimit(", "ValidatedLimit.numeric",
            "ValidatedLimit.thermal", "ThermalState.", "ResourceLimitEntry(", "ResourceBudget(",
            "ResourceMeasurementSpecification(",
        ] {
            #expect(!code.contains(token), "the runner must not construct \(token)")
        }
        // And no source defaults a sample count, a statistic, or a limit.
        for name in Self.resourceSources {
            let source = Self.strippingComments(try Self.moduleSource(named: name))
            for token in [
                "sampleCount: Int = ", "summaryStatistic: SummaryStatistic = ",
                "defaultSampleCount", "defaultLimit", "defaultStatistic", "?? .median",
                "?? .maximum", "?? .mean", "?? .percentile95",
            ] {
                #expect(!source.contains(token), "\(name) must not default \(token)")
            }
        }
        // The declared count is read from the predeclared specification, and its only fallback is
        // zero — which is not a sample count a run can complete.
        #expect(
            code.contains("specification(for: cell)?.sampleCount.value ?? 0"),
            "the declared sample count must come from the plan's specification"
        )
        #expect(
            code.contains("specification(for: cell)?.passLimit"),
            "the pass limit must come from the plan's specification"
        )
    }

    // MARK: - Helpers

    /// The resource sources this task added.
    static let resourceSources = [
        "ResourceValidationInputs.swift",
        "ResourceValidationError.swift",
        "ResourceValidationSeams.swift",
        "ResourceValidation.swift",
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

    /// Stripped code lines containing `fragment`, so an audit can name what it found.
    static func lines(of source: String, containing fragment: String) -> [String] {
        strippingComments(source)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.contains(fragment) }
    }

    /// Removes `//` comment text so a scan reads code rather than documentation.
    ///
    /// The resource sources discuss every one of the forbidden tokens by name, so an unstripped
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

// MARK: - A store that varies one sample's environment

/// A reader that reports one position of one series from a foreign environment.
///
/// The per-cell overrides in ``FakeResourceSampleStore`` apply to a whole series, which cannot
/// express "four samples on a phone and one in a simulator". This does, so the claim that a series
/// is only as admissible as its least admissible sample is checked rather than assumed.
struct MixedEnvironmentSampleStore: ResourceSampleReading {
    let backing: FakeResourceSampleStore
    let foreignOrdinal: Int
    let foreignEnvironment: ExecutionEnvironment
    let cell: ResourceCell

    func sample(
        for cell: ResourceCell,
        at index: ResourceSampleIndex
    ) throws(ResourceSampleFault) -> ResourceSample {
        let base = try backing.sample(for: cell, at: index)
        guard cell == self.cell, index.ordinal == foreignOrdinal else { return base }
        return ResourceSample(
            cell: base.cell,
            index: base.index,
            value: base.value,
            target: base.target,
            environment: foreignEnvironment,
            configuration: base.configuration,
            versionTuple: base.versionTuple
        )
    }
}
