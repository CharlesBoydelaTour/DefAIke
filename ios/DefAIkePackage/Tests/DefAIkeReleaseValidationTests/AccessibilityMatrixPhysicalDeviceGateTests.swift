import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// The two barriers that make a matrix gate unsatisfiable without a physical iPhone, and the
// declaration-level claims that keep them in place.
//
// Barrier 1 bounds what an *observation* can become: ``QualifyingMatrixEvidence`` refuses anything
// not produced on a physical iPhone, on the bound configuration, on a plan candidate, under the
// bound version tuple, by a means the position admits. Barrier 2 bounds what a *process* can
// conclude: ``AccessibilityMatrixConfigurationReport/gateResult(for:)`` consults
// ``ObservedParityEnvironment/current``, which is compiled from the platform.
//
// The two are independent, and the second is the one that cannot be worked around. Every
// observation in a "complete" store claims a physical iPhone, so the *positions* pass — and every
// gate still fails, because this process is not a phone whatever it is handed. That contradiction is
// deliberate: an observation's environment is a claim its producer makes, while a gate result is a
// conclusion this process draws.
//
// The declaration-level tests read the module's own source text. They are asserted that way for one
// reason: this test target reaches the module through `@testable import`, so it *can* call an
// internal initialiser, and a test that tried to prove "no caller outside the module can build one"
// by calling it would prove the opposite. Every scan strips `//` comment text first, because these
// sources discuss most of the forbidden tokens by name and an unstripped scan would read the
// documentation and get weakened rather than obeyed.

/// Barrier 2, and the declaration-level claims behind barrier 1.
@Suite("Accessibility matrix gates need a physical iPhone")
struct AccessibilityMatrixPhysicalDeviceGateTests {

    // MARK: - Barrier 2

    @Test("This process reports its real environment and cannot be told otherwise")
    func theProcessEnvironmentIsObservedNotSupplied() {
        let current = ObservedParityEnvironment.current
        #expect(current != .physicalIPhone, "no host or simulator process is a physical iPhone")
        #expect(!ObservedParityEnvironment.canProducePhysicalDeviceEvidence)
        #expect(current == .developmentMac || current == .iOSSimulator)
    }

    @Test("Every position can pass and every gate still fails")
    func aCompleteRunStillFailsEveryGate() throws {
        // The sharpest case: every readable position was observed, every observation claims a
        // physical iPhone, every manual position carries an imported result with an approved
        // authorization naming that exact position. Twenty positions pass. Both gates fail.
        let binding = try Sample.matrixBinding()
        let report = AccessibilityMatrixRunner(
            observations: FakeMatrixObservationStore.complete(for: binding)
        )
        .run(binding)

        #expect(report.satisfiedCells.count == 20)
        let refusal = try #require(report.processRefusal)
        #expect(refusal == .notPhysicalIPhone(ObservedParityEnvironment.current))

        for gate in DeviceGate.matrixGates {
            let result = report.gateResult(for: gate)
            #expect(result.applicability == .applicable)
            #expect(result.outcome == .failed)
            #expect(result.outcome != .notExecuted)
            #expect(result.processRefusal == refusal)
            #expect(!result.cells.isEmpty)
        }
        #expect(report.outcome == .failed)
        #expect(report.owedInputs.contains(.physicalIPhoneAssistiveRunEnvironment))
    }

    @Test("An observation from a host or simulator cannot satisfy a position either")
    func barrierOneRefusesAForeignEnvironment() throws {
        let binding = try Sample.matrixBinding()
        let subject = try #require(Sample.readableCells(of: binding).first)
        for environment in [ExecutionEnvironment.developmentMac, .iOSSimulator] {
            var store = FakeMatrixObservationStore.complete(for: binding)
            store.setEnvironment(environment, for: subject)
            let report = AccessibilityMatrixRunner(observations: store).run(binding)
            guard case let .nonQualifyingEvidence(reason) = report.outcome(of: subject) else {
                Issue.record("an observation from a foreign environment must be refused")
                return
            }
            #expect(reason == .notPhysicalIPhone(environment))
            #expect(report.nonQualifyingCells.contains(subject))
        }
    }

    @Test("An observation from another configuration or another tuple is refused")
    func barrierOneRefusesAForeignConfigurationAndTuple() throws {
        let binding = try Sample.matrixBinding()
        let subject = try #require(Sample.readableCells(of: binding).first)

        var wrongDevice = FakeMatrixObservationStore.complete(for: binding)
        wrongDevice.setConfiguration(
            try Sample.matrixConfiguration(hardware: "iPhone98.1"),
            for: subject
        )
        let deviceReport = AccessibilityMatrixRunner(observations: wrongDevice).run(binding)
        guard case let .nonQualifyingEvidence(deviceReason) = deviceReport.outcome(of: subject)
        else {
            Issue.record("an observation from another device must be refused")
            return
        }
        guard case .configurationMismatch = deviceReason else {
            Issue.record("the refusal must name the configuration mismatch")
            return
        }

        var wrongTuple = FakeMatrixObservationStore.complete(for: binding)
        wrongTuple.setVersionTuple(
            try Sample.matrixVersionTuple(validationPlan: "plan.other"),
            for: subject
        )
        let tupleReport = AccessibilityMatrixRunner(observations: wrongTuple).run(binding)
        guard case let .nonQualifyingEvidence(tupleReason) = tupleReport.outcome(of: subject) else {
            Issue.record("an observation under another tuple must be refused")
            return
        }
        #expect(tupleReason == .versionTupleMismatch)
    }

    // MARK: - Declaration-level claims

    @Test("A qualifying-evidence value cannot be constructed from this test target")
    func qualifyingEvidenceIsNotClientConstructible() throws {
        // The compile-time half of barrier 1, asserted the way the module's other
        // not-constructible claims are: the initialiser is declared without `public`, so no caller
        // outside `DefAIkeReleaseValidation` can build one — and therefore no caller outside the
        // module can build a `MatrixCellAgreement` or an
        // `AccessibilityMatrixCellOutcome.exercised`.
        let code = Self.strippingComments(
            try Self.moduleSource(named: "AccessibilityMatrixInputs.swift")
        )
        #expect(code.contains("public struct QualifyingMatrixEvidence: Hashable, Sendable {"))
        #expect(!code.contains("public init?(\n        observation:"))
        #expect(code.contains("    init?(\n        observation: MatrixCellObservation,"))
        // And it is not `Codable`: a decodable proof would be a second way in.
        #expect(!code.contains("public struct QualifyingMatrixEvidence: Hashable, Codable"))
        // The three public initialisers here are the shapes a reader supplies, and nothing else.
        #expect(code.components(separatedBy: "public init").count - 1 == 3)
        for declaration in [
            "public init(\n        workflow: AccessibilityWorkflow,",
            "public init(\n        cellKey: String,",
            "public init(\n        cell: AccessibilityMatrixCell,\n        coverage:",
        ] {
            #expect(code.contains(declaration), "missing declaration: \(declaration)")
        }
    }

    @Test("Nothing in the matrix sources lets a caller hand in an outcome")
    func noOutcomeParameterExists() throws {
        let runner = Self.strippingComments(
            try Self.moduleSource(named: "AccessibilityMatrixValidation.swift")
        )
        // Three public initialisers: two bindings and the runner, plus nothing else.
        #expect(runner.components(separatedBy: "public init").count - 1 == 3)
        #expect(runner.contains("public init(observations: any MatrixObservationReading)"))
        #expect(runner.contains("public init(\n        plan: DeviceValidationPlan,"))
        // The record, the agreement, the gate result, and both reports are built inside the module
        // only, so their `outcome` fields cannot be supplied from outside it.
        for declaration in [
            "    init(\n        cell: AccessibilityMatrixCell,\n        coverage: ObservedWorkflowCoverage?,",
            "    init(\n        gate: DeviceGate,",
            "    init(\n        binding: AccessibilityMatrixBinding,",
            "    init(\n        plan: ArtifactID,",
        ] {
            #expect(runner.contains(declaration), "missing internal initialiser: \(declaration)")
        }
        for declaration in [
            "public struct MatrixCellAgreement: Hashable, Sendable {",
            "public struct MatrixResultGap: Hashable, Sendable {",
            "public struct AccessibilityMatrixCellRecord: Hashable, Sendable {",
            "public struct AccessibilityMatrixGateResult: Hashable, Sendable {",
            "public struct AccessibilityMatrixConfigurationReport: Hashable, Sendable {",
            "public struct AccessibilityMatrixReport: Hashable, Sendable {",
        ] {
            #expect(runner.contains(declaration), "missing declaration: \(declaration)")
        }
        // None of them is `Codable`: a decodable result would be a second way in.
        for forbidden in [
            "public struct AccessibilityMatrixReport: Hashable, Codable",
            "public struct AccessibilityMatrixConfigurationReport: Hashable, Codable",
            "public struct MatrixCellAgreement: Hashable, Codable",
        ] {
            #expect(!runner.contains(forbidden), "\(forbidden) must not exist")
        }

        for name in Self.matrixSources {
            let code = Self.strippingComments(try Self.moduleSource(named: name))
            for token in [
                "isSatisfied =", "isPassing =", "func markPassed", "func markExecuted",
                "func waive", "func override", "func force", "func assume", "func approve",
            ] {
                #expect(!code.contains(token), "\(name) must not reference \(token)")
            }
        }
    }

    @Test("The runner has no way to relax the environment gate")
    func runnerTakesNoEnvironmentOverride() throws {
        let code = Self.strippingComments(
            try Self.moduleSource(named: "AccessibilityMatrixValidation.swift")
        )
        for token in [
            "allowSimulator", "allowHost", "treatAsPhysical", "assumePhysical", "skipEnvironment",
            "ignoreEnvironment", "developmentMac", "iOSSimulator", "ProcessInfo",
            // `Bundle` is spelled out as `Bundle.main` and `Bundle(` rather than bare, because the
            // bare word occurs legitimately in `modelBundle` — the version tuple's Model Bundle
            // identity, which has nothing to do with a resource bundle lookup.
            "Bundle.main", "Bundle(", "Bundle.module",
        ] {
            #expect(!code.contains(token), "the runner must not reference \(token)")
        }
        // Two public entry points, each taking a binding and nothing else.
        #expect(code.components(separatedBy: "public func run").count - 1 == 2)
        #expect(
            code.contains(
                "public func run(_ binding: AccessibilityMatrixCoverageBinding) -> AccessibilityMatrixReport"
            )
        )
        #expect(
            code.contains(
                "public func run(\n        _ binding: AccessibilityMatrixBinding\n    ) -> AccessibilityMatrixConfigurationReport"
            )
        )
        // The environment it records is the observed one, never a parameter.
        #expect(code.contains("runEnvironment: ObservedParityEnvironment.current"))
    }

    @Test("The observation seam offers one member and no way to list, write, or conclude")
    func seamOffersNothingElse() throws {
        let code = Self.strippingComments(
            try Self.moduleSource(named: "AccessibilityMatrixSeams.swift")
        )
        // One protocol requirement, and it takes one position and returns one observation.
        #expect(code.components(separatedBy: "func ").count - 1 == 1)
        #expect(code.contains("public protocol MatrixObservationReading: Sendable {"))
        #expect(code.contains("    func observation(\n        for cell: AccessibilityMatrixCell"))
        for token in [
            "func record", "func write", "func publish", "func store", "func save", "func cache",
            "func all", "func list", "func count", "func observations", "var count",
            "func outcome", "func approve", "func authorize", "func configurations",
            "-> [MatrixCellObservation]", "-> Set<", "-> GateOutcome", "-> Int",
        ] {
            #expect(!code.contains(token), "the seam must not declare \(token)")
        }
        // No source in the module conforms to the reader, so there is no default a caller could
        // fall back to. The only conformer is in the tests.
        for name in Self.matrixSources {
            let source = Self.strippingComments(try Self.moduleSource(named: name))
            #expect(
                !source.contains(": MatrixObservationReading {"),
                "\(name) must not provide a default reader"
            )
        }
    }

    @Test("The matrix sources manufacture no approval, no evidence reference, and no identifier")
    func noApprovedValueIsManufacturedHere() throws {
        // The clause with the most room to go wrong: if this module could build an `ApprovalRecord`
        // or an `EvidenceSource`, it could satisfy its own manual positions. It cannot, and the
        // absence is checked at the declaration level rather than argued for.
        for name in Self.matrixSources {
            let code = Self.strippingComments(try Self.moduleSource(named: name))
            for token in [
                "ApprovalRecord(", "EvidenceSource(", "ApprovalDecision.approved",
                "ImportedManualEvidence(", "ApprovedConfigurationID(", "SHA256Digest(",
                "ApproverID(", "Date(", "decision: .approved", "isApproved = true",
            ] {
                #expect(!code.contains(token), "\(name) must not construct \(token)")
            }
        }
        // And nothing here reads a clock or holds a duration: a matrix position has no numeric
        // limit, so there is nothing for one to be compared against.
        for name in Self.matrixSources {
            let code = Self.strippingComments(try Self.moduleSource(named: name))
            for token in [
                "ContinuousClock", "SuspendingClock", "DispatchTime", "CFAbsoluteTime",
                "mach_absolute_time", "Task.sleep", "timeIntervalSince", ": Duration",
                "-> Duration", "Duration(", "timeout", "Timeout", "deadline",
            ] {
                #expect(!code.contains(token), "\(name) must not reference \(token)")
            }
        }
    }

    @Test("No matrix source reaches the presentation module")
    func theModuleBoundaryHolds() throws {
        // Workflow operability is computed in `DefAIkePresentation`, and this module depends on
        // `DefAIkeDomain` alone. The matrix is modelled over the domain's vocabularies plus
        // imported evidence instead, and the finding is recorded rather than worked around.
        for name in Self.matrixSources {
            let code = Self.strippingComments(try Self.moduleSource(named: name))
            for token in [
                "import DefAIkePresentation", "import DefAIkeApplication",
                "import DefAIkeSharedTransfer", "import SwiftUI", "import UIKit",
                "WorkflowOperability", "AccessibilitySemanticsSnapshot", "AccessibleElement",
                "AdaptiveLayoutPolicy", "SuppliedDocumentReference",
            ] {
                #expect(!code.contains(token), "\(name) must not reference \(token)")
            }
            #expect(code.contains("import DefAIkeDomain"))
        }
        // And the finding is a value the report carries, not a comment.
        let binding = try Sample.matrixBinding()
        let report = AccessibilityMatrixRunner(
            observations: FakeMatrixObservationStore.complete(for: binding)
        )
        .run(binding)
        #expect(report.standingLimits.contains(.workflowOperabilityIsNotReachableFromThisModule))
    }

    @Test("The plan carries no accessibility, localization, or condition dimension")
    func thePlanCannotPredeclareAMatrixPosition() throws {
        // Checked against the schema rather than asserted in prose. The plan's comparison keys are
        // the eight parity metrics and its measurement keys are target, metric, hardware, and
        // operating-system version. Neither can name a workflow, an assistive condition, or a
        // localization variant, so no position's procedure or conditions can be predeclared.
        let plan = try Sample.matrixPlan()
        let comparisonMetrics = Set(plan.comparisons.map { $0.metric.rawValue })
        #expect(comparisonMetrics == Set(ComparisonMetric.allCases.map { $0.rawValue }))
        for workflow in AccessibilityWorkflow.allCases {
            #expect(!comparisonMetrics.contains(workflow.rawValue))
        }
        for condition in AssistiveCondition.allCases {
            #expect(!comparisonMetrics.contains(condition.rawValue))
        }
        // The measurement key has no condition dimension, so a VoiceOver-enabled and a
        // Switch-Control-enabled measurement of one metric on one device differ in nothing the key
        // records. Demonstrated by building the key the schema's uniqueness rule uses.
        let keys = plan.measurements.map {
            "\($0.target.rawValue)/\($0.metric.rawValue)/"
                + "\($0.hardwareIdentifier.rawValue)@\($0.osVersion.description)"
        }
        #expect(Set(keys).count == keys.count)
        for condition in AssistiveCondition.allCases {
            #expect(!keys.contains { $0.contains(condition.rawValue) })
        }
        // Both findings are values a run reports.
        let binding = try Sample.matrixBinding(plan: plan)
        let report = AccessibilityMatrixRunner(
            observations: FakeMatrixObservationStore.empty(for: binding)
        )
        .run(binding)
        let standing = Set(report.standingLimits)
        #expect(standing.contains(.accessibilityMatrixCellHasNoPlanSpecification))
        #expect(standing.contains(.assistiveConditionIsAbsentFromThePlanMeasurementKey))
        #expect(standing.contains(.supportedMajorVersionSetIsDerivedFromPlanCandidates))
    }

    // MARK: - Helpers

    /// The matrix sources this task added.
    static let matrixSources = [
        "AccessibilityMatrixInputs.swift",
        "AccessibilityMatrixError.swift",
        "AccessibilityMatrixSeams.swift",
        "AccessibilityMatrixValidation.swift",
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
    /// The matrix sources discuss most of the forbidden tokens by name, so an unstripped scan would
    /// read the documentation and get weakened rather than obeyed.
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
