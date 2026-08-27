import DefAIkeDomain
import Foundation

@testable import DefAIkeReleaseValidation

// Synthetic samples for the accessibility and Localization Readiness matrix runner, and a bounded
// in-memory observation reader.
//
// Every value here is deliberately synthetic. None of these is an approved Device Validation Plan,
// an approved candidate configuration, an approved Accessibility Gate Matrix, an approved manual
// execution authorization, an imported human run record, or a real physical-device result. The
// tests build a structurally complete run and then change one thing at a time.
//
// Four things are worth being explicit about, because a reader could mistake any of them for a
// claim this suite is not making.
//
// **An observation that says `.physicalIPhone` is a claim, not evidence.** `MatrixCellObservation`
// takes its environment as a parameter because the real caller is a device harness that knows where
// it ran. A test can therefore exercise the execution-mode and manual-authorization arithmetic on a
// host. What a test cannot do is make a *gate* pass: `gateResult(for:)` consults
// `ObservedParityEnvironment.current`, which is compiled from the platform and has no parameter. So
// every gate in this suite fails, deliberately, and ``AccessibilityMatrixPhysicalDeviceGateTests``
// asserts exactly that.
//
// **An imported manual result here is not an imported manual result.** ``Sample/importedManual(for:)``
// builds the *shape* the requirement asks for — a versioned, digest-bound reference plus an
// approval record naming that exact position — from two synthetic artifacts. No human ran anything,
// nothing was approved, and the pair exists so the refusal paths can be exercised at all.
//
// **Most positions in a "complete" store hold nothing, and that is correct.** All 28 localization
// positions per configuration are refused before the seam, because substituting a readiness catalog
// replaces no rendered string; the handoff-consent and retry positions are refused too, because the
// Share Extension exposes no accessibility projection and the retry workflow's recovery control is
// credited to no workflow. Twenty of 56 positions per configuration are ever read.
//
// **The two digests behind a manual position are deliberately different.** An approval whose record
// is the run it approves — by identifier or by content — is refused, so the samples give the
// imported result and the authorization distinct artifacts and distinct digests. A store that used
// one for both would exercise the refusal instead of the pass.

extension Sample {

    // MARK: Evidence with distinct digests

    /// An evidence source at a distinct content digest.
    ///
    /// ``Sample/evidence(_:)`` gives every reference the same digest, which is fine where only the
    /// artifact identity matters. A manual authorization is refused when its record shares the
    /// imported result's digest, so the matrix samples need references that differ in both.
    static func matrixEvidence(_ identifier: String, digest index: Int) -> EvidenceSource {
        EvidenceSource(
            artifact: artifact(identifier),
            version: version(),
            contentDigest: digest(index)
        )
    }

    /// An approval record at a distinct content digest.
    static func matrixApproval(
        _ identifier: String,
        digest index: Int,
        decision: ApprovalDecision = .approved
    ) -> ApprovalRecord {
        ApprovalRecord(
            source: matrixEvidence(identifier, digest: index),
            decision: decision,
            approver: approver(),
            decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: Configurations

    /// A candidate configuration at an explicit hardware identifier and operating-system version.
    ///
    /// ``Sample/candidateConfiguration(hardware:appBuild:)`` pins iOS 17, which cannot exercise the
    /// major-version dimension at all.
    static func matrixConfiguration(
        hardware device: String = "iPhone17.1",
        osVersion: String = "17.0.0",
        appBuild build: AppBuildID? = nil
    ) throws -> CandidateDeviceConfiguration {
        try CandidateDeviceConfiguration(
            deviceModel: text("Sample iPhone \(device)"),
            hardwareIdentifier: DeviceHardwareID(device)!,
            osVersion: try PlatformVersion(validating: osVersion),
            appBuild: build ?? appBuild(),
            isAppleNeuralEngineCapable: true
        )
    }

    // MARK: Plan

    /// A plan whose candidate configurations are exactly the ones given.
    ///
    /// The resource measurement half is filled in for every candidate because the plan schema
    /// requires it, not because a matrix run reads any of it: nothing in
    /// `DeviceValidationPlan` carries an accessibility or localization dimension, which is
    /// `accessibility-matrix-cell-has-no-plan-specification`.
    static func matrixPlan(
        configurations: [CandidateDeviceConfiguration]? = nil,
        planIdentifier: String = "plan.device-validation",
        modelBundle overrideBundle: ModelBundleID? = nil,
        capabilityManifest: String = "manifest.capability"
    ) throws -> DeviceValidationPlan {
        let candidates = try configurations ?? [matrixConfiguration()]
        return try DeviceValidationPlan(
            id: artifact(planIdentifier),
            schemaVersion: .v1,
            candidateConfigurations: candidates,
            fixtureSuite: artifact("suite.fixtures"),
            modelBundle: overrideBundle ?? bundle(),
            capabilityManifest: artifact(capabilityManifest),
            comparisons: try ComparisonMetric.allCases
                .sorted { $0.rawValue < $1.rawValue }
                .map { metric in
                    try ComparisonSpecification(
                        metric: metric,
                        reference: evidence("evidence.reference.\(metric.rawValue)"),
                        tolerance: metric.isCategorical
                            ? nil
                            : try NumericTolerance(kind: .absolute, value: nonNegativeDecimal(1)),
                        requiredAgreement: metric.isCategorical ? ratio(1) : nil
                    )
                },
            measurements: try candidates.flatMap { candidate in
                try ExecutionTarget.allCases.flatMap { target in
                    try ResourceMetric.requiredMetrics(for: target)
                        .sorted { $0.rawValue < $1.rawValue }
                        .map { metric in
                            try ResourceMeasurementSpecification(
                                metric: metric,
                                target: target,
                                hardwareIdentifier: candidate.hardwareIdentifier,
                                osVersion: candidate.osVersion,
                                appBuild: candidate.appBuild,
                                workload: evidence("evidence.workload.\(metric.rawValue)"),
                                warmth: .warm,
                                branchExecution: .serial,
                                startingThermalState: .nominal,
                                startingPowerCondition: .batteryUnplugged,
                                sampleCount: count(5),
                                summaryStatistic: .maximum,
                                passLimit: limit(for: metric)
                            )
                        }
                }
            },
            missingResultRule: .treatAsFailure,
            approval: approval()
        )
    }

    // MARK: Version tuple

    static func matrixVersionTuple(
        validationPlan: String = "plan.device-validation",
        modelBundle overrideBundle: ModelBundleID? = nil,
        capabilityManifest: String = "manifest.capability",
        appBuild overrideBuild: AppBuildID? = nil
    ) throws -> ValidationVersionTuple {
        try parityVersionTuple(
            validationPlan: validationPlan,
            modelBundle: overrideBundle,
            capabilityManifest: capabilityManifest,
            appBuild: overrideBuild
        )
    }

    // MARK: Bindings

    static func matrixBinding(
        plan overridePlan: DeviceValidationPlan? = nil,
        configuration overrideConfiguration: CandidateDeviceConfiguration? = nil,
        versionTuple overrideTuple: ValidationVersionTuple? = nil
    ) throws -> AccessibilityMatrixBinding {
        let plan = try overridePlan ?? matrixPlan()
        return try AccessibilityMatrixBinding(
            plan: plan,
            configuration: try overrideConfiguration ?? plan.candidateConfigurations[0],
            versionTuple: try overrideTuple ?? matrixVersionTuple()
        )
    }

    static func matrixCoverageBinding(
        plan overridePlan: DeviceValidationPlan? = nil,
        versionTuple overrideTuple: ValidationVersionTuple? = nil
    ) throws -> AccessibilityMatrixCoverageBinding {
        try AccessibilityMatrixCoverageBinding(
            plan: try overridePlan ?? matrixPlan(),
            versionTuple: try overrideTuple ?? matrixVersionTuple()
        )
    }

    // MARK: Imported manual evidence

    /// An imported human result and an approval naming exactly `cell`.
    ///
    /// Two distinct artifacts at two distinct digests, because an approval whose record is the run
    /// it approves is refused on both.
    static func importedManual(
        for cell: AccessibilityMatrixCell,
        decision: ApprovalDecision = .approved
    ) -> ImportedManualEvidence {
        ImportedManualEvidence(
            cellKey: cell.matrixKey,
            importedResult: matrixEvidence("evidence.manual-run", digest: 0xA1),
            authorization: matrixApproval(
                "approval.manual-portion",
                digest: 0xA2,
                decision: decision
            )
        )
    }

    /// The execution mode a position admits at all.
    ///
    /// Not a choice this helper makes: a position whose condition no automation can establish is
    /// answerable only by an imported human result, and one whose condition automation can
    /// establish is answered by an automated run.
    static func admissibleExecution(for cell: AccessibilityMatrixCell) -> ObservedMatrixExecution {
        cell.automationSupport.requiresImportedManualEvidence
            ? .manual(importedManual(for: cell))
            : .automated
    }

    // MARK: Position partitions

    /// The positions of one binding the runner actually reads an observation for.
    ///
    /// Twenty of 56: the five workflows that have something to exercise, against the four assistive
    /// conditions. Everything else is refused before the seam.
    static func readableCells(
        of binding: AccessibilityMatrixBinding
    ) -> [AccessibilityMatrixCell] {
        binding.requiredCells.filter { $0.blockingLimit == nil }
    }

    /// The positions of one binding the runner refuses before touching the seam.
    static func blockedCells(
        of binding: AccessibilityMatrixBinding
    ) -> [AccessibilityMatrixCell] {
        binding.requiredCells.filter { $0.blockingLimit != nil }
    }
}

// MARK: - Read-only in-memory observation reader

/// A bounded in-memory ``MatrixObservationReading`` for matrix-runner tests.
///
/// Read-only, like the seam it implements. The mutators change what the store *already holds* so a
/// test can stage a missing, unreadable, unactivatable, misfiled, wrongly executed, unauthorized, or
/// non-qualifying observation; the runner under test never reaches them.
///
/// An empty store is the honest default state of this repository: nothing has been executed on a
/// physical iPhone under any assistive technology, so every position is missing. That is why
/// ``empty`` is a named value rather than something a test has to build.
struct FakeMatrixObservationStore: MatrixObservationReading {
    /// What the run observed at each position.
    var coverages: [AccessibilityMatrixCell: ObservedWorkflowCoverage] = [:]

    /// Per-position overrides for the conditions an observation claims.
    var executions: [AccessibilityMatrixCell: ObservedMatrixExecution] = [:]
    var environments: [AccessibilityMatrixCell: ExecutionEnvironment] = [:]
    var configurations: [AccessibilityMatrixCell: CandidateDeviceConfiguration] = [:]
    var versionTuples: [AccessibilityMatrixCell: ValidationVersionTuple] = [:]
    var resultReferences: [AccessibilityMatrixCell: EvidenceSource] = [:]

    /// Positions whose observation is filed against a different position.
    var misfiled: [AccessibilityMatrixCell: AccessibilityMatrixCell] = [:]

    /// Positions that exist and cannot be read, and conditions that cannot be established.
    var unreadable: Set<AccessibilityMatrixCell> = []
    var notActivatable: Set<AccessibilityMatrixCell> = []
    var isUnavailable = false

    /// The default conditions every observation claims.
    var defaultEnvironment: ExecutionEnvironment = .physicalIPhone
    var defaultConfiguration: CandidateDeviceConfiguration
    var defaultVersionTuple: ValidationVersionTuple

    /// A store holding nothing at all.
    static func empty(for binding: AccessibilityMatrixBinding) -> FakeMatrixObservationStore {
        FakeMatrixObservationStore(
            defaultConfiguration: binding.configuration,
            defaultVersionTuple: binding.versionTuple
        )
    }

    /// A store whose every readable position holds an admissible, completing observation.
    ///
    /// "Readable" is not a choice this helper makes: it is the positions the runner asks about at
    /// all, which is every position no standing finding blocks.
    static func complete(for binding: AccessibilityMatrixBinding) -> FakeMatrixObservationStore {
        var store = empty(for: binding)
        for cell in Sample.readableCells(of: binding) {
            store.coverages[cell] = .workflowCompleted
            store.executions[cell] = Sample.admissibleExecution(for: cell)
        }
        return store
    }

    /// A store covering every configuration of one coverage binding.
    static func complete(
        for binding: AccessibilityMatrixCoverageBinding
    ) -> FakeMatrixObservationStore {
        guard let first = binding.bindings.first else {
            preconditionFailure("a coverage binding always carries at least one configuration")
        }
        var store = complete(for: first)
        for scoped in binding.bindings.dropFirst() {
            let other = complete(for: scoped)
            for (cell, coverage) in other.coverages { store.coverages[cell] = coverage }
            for (cell, execution) in other.executions { store.executions[cell] = execution }
            // Each observation reports the configuration its own position names, which is what a
            // real fleet of harnesses would do. A cross-configuration test overrides one position.
            for cell in scoped.requiredCells { store.configurations[cell] = scoped.configuration }
        }
        for cell in first.requiredCells { store.configurations[cell] = first.configuration }
        return store
    }

    // MARK: Staging

    mutating func remove(_ cell: AccessibilityMatrixCell) {
        coverages.removeValue(forKey: cell)
        executions.removeValue(forKey: cell)
    }

    mutating func setCoverage(
        _ coverage: ObservedWorkflowCoverage,
        for cell: AccessibilityMatrixCell
    ) {
        coverages[cell] = coverage
    }

    mutating func setExecution(
        _ execution: ObservedMatrixExecution,
        for cell: AccessibilityMatrixCell
    ) {
        executions[cell] = execution
    }

    mutating func setEnvironment(
        _ environment: ExecutionEnvironment,
        for cell: AccessibilityMatrixCell
    ) {
        environments[cell] = environment
    }

    mutating func setEnvironmentEverywhere(_ environment: ExecutionEnvironment) {
        defaultEnvironment = environment
        environments.removeAll()
    }

    mutating func setConfiguration(
        _ configuration: CandidateDeviceConfiguration,
        for cell: AccessibilityMatrixCell
    ) {
        configurations[cell] = configuration
    }

    mutating func setVersionTuple(
        _ tuple: ValidationVersionTuple,
        for cell: AccessibilityMatrixCell
    ) {
        versionTuples[cell] = tuple
    }

    mutating func setResultReference(
        _ reference: EvidenceSource,
        for cell: AccessibilityMatrixCell
    ) {
        resultReferences[cell] = reference
    }

    mutating func misfile(_ cell: AccessibilityMatrixCell, as other: AccessibilityMatrixCell) {
        misfiled[cell] = other
    }

    mutating func makeUnreadable(_ cell: AccessibilityMatrixCell) {
        unreadable.insert(cell)
    }

    mutating func makeNotActivatable(_ cell: AccessibilityMatrixCell) {
        notActivatable.insert(cell)
    }

    // MARK: Reading

    func observation(
        for cell: AccessibilityMatrixCell
    ) throws(MatrixObservationFault) -> MatrixCellObservation {
        if isUnavailable { throw MatrixObservationFault.storeUnavailable }
        if notActivatable.contains(cell) { throw MatrixObservationFault.conditionNotActivatable }
        if unreadable.contains(cell) { throw MatrixObservationFault.observationUnreadable }
        guard let coverage = coverages[cell] else {
            throw MatrixObservationFault.observationAbsent
        }
        return MatrixCellObservation(
            cell: misfiled[cell] ?? cell,
            coverage: coverage,
            execution: executions[cell] ?? Sample.admissibleExecution(for: cell),
            resultReference: resultReferences[cell]
                ?? Sample.matrixEvidence("evidence.matrix-run", digest: 0xB1),
            environment: environments[cell] ?? defaultEnvironment,
            configuration: configurations[cell] ?? defaultConfiguration,
            versionTuple: versionTuples[cell] ?? defaultVersionTuple
        )
    }
}
