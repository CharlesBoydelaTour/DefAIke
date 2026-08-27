import Foundation

@testable import DefAIkeDomain

// A coherent synthetic resource plan, and one knob per thing that can go wrong.
//
// The shape every test here takes is: build a budget pair, a Device Validation Plan, a
// fixture suite, a capability manifest, and an evidence index that all agree; change
// exactly one of them; and require validation to refuse. That only works if the baseline
// is genuinely coherent, so as much as possible is derived — the required comparison set
// follows from the provenance flag, each measurement's pass limit follows from the same
// builder the budget uses, and the result records follow from the plan — and a knob is
// exposed only for the single field a test means to break.
//
// None of these values is an approved device, budget, limit, tolerance, or decision. The
// hardware identifier is synthetic, every numeric limit is the same round placeholder
// number, and every approval is a synthetic record whose decision the test sets.

enum ResourcePlanSample {
    static let planIdentifier = "plan.device-validation"
    static let fixtureSuiteIdentifier = "suite.fixtures"
    static let manifestIdentifier = "manifest.capability"

    /// The one evidence artifact the plan's comparisons and workloads cite.
    static let planEvidenceIdentifier = "evidence.plan"

    /// The evidence artifact the sample budgets cite as measurement conditions.
    static let conditionsIdentifier = "evidence.measurement"

    /// The numeric limit every sample metric shares. A placeholder, not a measurement.
    static let baselineLimitValue: Decimal = 100

    // MARK: - Evidence index

    /// The release evidence the coherent baseline cites, plus anything a test adds.
    static func evidenceIndex(
        records: [EvidenceSource]? = nil
    ) throws -> ReleaseEvidenceIndex {
        try ReleaseEvidenceIndex(
            records: records
                ?? [
                    Sample.evidence("approval.sample"),
                    Sample.evidence(planEvidenceIdentifier),
                    Sample.evidence(conditionsIdentifier),
                ]
        )
    }

    // MARK: - Limits

    /// A limit for one metric: thermal for the categorical metric, otherwise numeric in
    /// the unit that metric is measured in.
    static func limit(
        _ metric: ResourceMetric,
        value: Decimal = ResourcePlanSample.baselineLimitValue,
        unit: ResourceLimitUnit? = nil,
        thermal: ThermalState = .fair
    ) -> ValidatedLimit {
        guard !metric.isCategorical else { return .thermal(maximumState: thermal) }
        return .numeric(
            value: Sample.positiveDecimal(value),
            unit: unit ?? metric.requiredUnit ?? .milliseconds
        )
    }

    static func limitEntry(
        _ metric: ResourceMetric,
        value: Decimal = ResourcePlanSample.baselineLimitValue,
        unit: ResourceLimitUnit? = nil,
        thermal: ThermalState = .fair,
        conditions: String = ResourcePlanSample.conditionsIdentifier
    ) throws -> ResourceLimitEntry {
        try ResourceLimitEntry(
            metric: metric,
            limit: limit(metric, value: value, unit: unit, thermal: thermal),
            measurementConditions: Sample.evidence(conditions)
        )
    }

    // MARK: - Budgets

    /// One target's budget, with every required metric at the baseline limit unless a
    /// test replaces one entry.
    static func budget(
        target: ExecutionTarget,
        identifier: String? = nil,
        validationPlan: String = ResourcePlanSample.planIdentifier,
        replacing replacement: ResourceLimitEntry? = nil
    ) throws -> ResourceBudget {
        let entries = try ResourceMetric.requiredMetrics(for: target)
            .sorted { $0.rawValue < $1.rawValue }
            .map { metric -> ResourceLimitEntry in
                if let replacement, replacement.metric == metric { return replacement }
                return try limitEntry(metric)
            }
        return try ResourceBudget(
            id: Sample.artifact(identifier ?? "budget.\(target.rawValue)"),
            schemaVersion: .v1,
            target: target,
            hardLimits: entries,
            validationPlan: Sample.artifact(validationPlan)
        )
    }

    static func budgets(
        mainApplicationPlan: String = ResourcePlanSample.planIdentifier,
        shareExtensionPlan: String = ResourcePlanSample.planIdentifier,
        replacingMainApplication mainReplacement: ResourceLimitEntry? = nil,
        replacingShareExtension extensionReplacement: ResourceLimitEntry? = nil
    ) throws -> ResourceBudgetSet {
        try ResourceBudgetSet(
            mainApplication: budget(
                target: .mainApplication,
                validationPlan: mainApplicationPlan,
                replacing: mainReplacement
            ),
            shareExtension: budget(
                target: .shareExtension,
                validationPlan: shareExtensionPlan,
                replacing: extensionReplacement
            )
        )
    }

    // MARK: - Comparisons

    static func comparison(
        _ metric: ComparisonMetric,
        reference: String = ResourcePlanSample.planEvidenceIdentifier,
        tolerance: Decimal = 1
    ) throws -> ComparisonSpecification {
        try ComparisonSpecification(
            metric: metric,
            reference: Sample.evidence(reference),
            tolerance: metric.isCategorical
                ? nil
                : try NumericTolerance(
                    kind: .absolute,
                    value: Sample.nonNegativeDecimal(tolerance)
                ),
            requiredAgreement: metric.isCategorical ? .one : nil
        )
    }

    /// Exactly the comparisons this release requires, unless a test narrows or widens
    /// the set.
    static func comparisons(
        provenanceEnabled: Bool = false,
        omitting omitted: Set<ComparisonMetric> = [],
        including included: Set<ComparisonMetric> = []
    ) throws -> [ComparisonSpecification] {
        let metrics = ComparisonMetric
            .requiredComparisons(provenanceEnabled: provenanceEnabled)
            .subtracting(omitted)
            .union(included)
        return try metrics.sorted { $0.rawValue < $1.rawValue }.map { try comparison($0) }
    }

    // MARK: - Measurement specifications

    static func measurement(
        _ metric: ResourceMetric,
        target: ExecutionTarget,
        configuration: CandidateDeviceConfiguration,
        appBuild: AppBuildID? = nil,
        workload: String = ResourcePlanSample.planEvidenceIdentifier,
        branchExecution: EvidenceBranchExecution = .serial,
        summaryStatistic: SummaryStatistic = .median,
        passLimit: ValidatedLimit? = nil
    ) throws -> ResourceMeasurementSpecification {
        try ResourceMeasurementSpecification(
            metric: metric,
            target: target,
            hardwareIdentifier: configuration.hardwareIdentifier,
            osVersion: configuration.osVersion,
            appBuild: appBuild ?? configuration.appBuild,
            workload: Sample.evidence(workload),
            warmth: metric == .coldModelLoadTime ? .cold : .warm,
            branchExecution: branchExecution,
            startingThermalState: .nominal,
            startingPowerCondition: .batteryUnplugged,
            sampleCount: Sample.count(),
            summaryStatistic: summaryStatistic,
            passLimit: passLimit ?? limit(metric)
        )
    }

    /// Every metric of both targets, for every candidate configuration.
    static func measurements(
        configurations: [CandidateDeviceConfiguration],
        branchExecution: EvidenceBranchExecution = .serial,
        replacing replacement: ResourceMeasurementSpecification? = nil,
        adding additional: [ResourceMeasurementSpecification] = []
    ) throws -> [ResourceMeasurementSpecification] {
        var declared: [ResourceMeasurementSpecification] = []
        for configuration in configurations {
            for target in ExecutionTarget.allCases {
                for metric in ResourceMetric.requiredMetrics(for: target)
                    .sorted(by: { $0.rawValue < $1.rawValue })
                {
                    if let replacement,
                       replacement.metric == metric,
                       replacement.target == target,
                       replacement.hardwareIdentifier == configuration.hardwareIdentifier,
                       replacement.osVersion == configuration.osVersion
                    {
                        declared.append(replacement)
                        continue
                    }
                    declared.append(
                        try measurement(
                            metric,
                            target: target,
                            configuration: configuration,
                            branchExecution: branchExecution
                        )
                    )
                }
            }
        }
        return declared + additional
    }

    // MARK: - Plan

    static func candidate(
        hardware: String = "iPhone17.1",
        osVersion: PlatformVersion = .iOS17,
        appBuild: String = "build.sample"
    ) throws -> CandidateDeviceConfiguration {
        try CandidateDeviceConfiguration(
            deviceModel: Sample.text("Synthetic iPhone"),
            hardwareIdentifier: Sample.hardware(hardware),
            osVersion: osVersion,
            appBuild: Sample.appBuild(appBuild),
            isAppleNeuralEngineCapable: true
        )
    }

    static func plan(
        identifier: String = ResourcePlanSample.planIdentifier,
        provenanceEnabled: Bool = false,
        configurations: [CandidateDeviceConfiguration]? = nil,
        fixtureSuite: String = ResourcePlanSample.fixtureSuiteIdentifier,
        modelBundle: String = "bundle.sample",
        capabilityManifest: String = ResourcePlanSample.manifestIdentifier,
        comparisons comparisonOverride: [ComparisonSpecification]? = nil,
        measurements measurementOverride: [ResourceMeasurementSpecification]? = nil,
        approval: ApprovalDecision = .approved,
        approvalEvidence: String = "approval.sample"
    ) throws -> DeviceValidationPlan {
        let candidates = try configurations ?? [candidate()]
        return try DeviceValidationPlan(
            id: Sample.artifact(identifier),
            schemaVersion: .v1,
            candidateConfigurations: candidates,
            fixtureSuite: Sample.artifact(fixtureSuite),
            modelBundle: Sample.bundle(modelBundle),
            capabilityManifest: Sample.artifact(capabilityManifest),
            comparisons: try comparisonOverride
                ?? comparisons(provenanceEnabled: provenanceEnabled),
            measurements: try measurementOverride ?? measurements(configurations: candidates),
            missingResultRule: .treatAsFailure,
            approval: ApprovalRecord(
                source: Sample.evidence(approvalEvidence),
                decision: approval,
                approver: Sample.approver(),
                decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
    }

    static func capabilityManifest(
        provenanceEnabled: Bool = false
    ) throws -> ReleaseCapabilityManifest {
        let capabilities: Set<CapabilityID> = provenanceEnabled
            ? [.pixelAnalysis, .contentCredentialValidation]
            : [.pixelAnalysis]
        return try Sample.capabilityManifest(
            capabilities: capabilities,
            policyCompatibility: Sample.policyCompatibility(
                provenance: provenanceEnabled
                    ? .bound(Sample.artifact("policy.provenance"))
                    : .notApplicable(decision: Sample.approval())
            )
        )
    }

    static func fixtureSuite(
        identifier: String = ResourcePlanSample.fixtureSuiteIdentifier,
        provenanceEnabled: Bool = false
    ) throws -> ReleaseFixtureSuite {
        try ReleaseFixtureSuite(
            id: Sample.artifact(identifier),
            schemaVersion: .v1,
            provenanceApplicability: provenanceEnabled ? .applicable : Sample.notApplicable(),
            fixtures: [
                try Sample.fixtureRecord(),
                try Sample.fixtureRecord(
                    family: provenanceEnabled ? .provenanceValidSigned : .orientation,
                    identifier: "fixture.second",
                    assetPath: "fixtures/second.jpg"
                ),
            ]
        )
    }

    /// The coherent baseline, or whichever pieces a test replaces.
    static func validated(
        plan planOverride: DeviceValidationPlan? = nil,
        budgets budgetOverride: ResourceBudgetSet? = nil,
        fixtureSuite suiteOverride: ReleaseFixtureSuite? = nil,
        capabilityManifest manifestOverride: ReleaseCapabilityManifest? = nil,
        evidence index: ReleaseEvidenceIndex? = nil,
        provenanceEnabled: Bool = false
    ) throws -> ValidatedResourcePlan {
        try ValidatedResourcePlan(
            activating: try planOverride ?? plan(provenanceEnabled: provenanceEnabled),
            budgets: try budgetOverride ?? budgets(),
            fixtureSuite: try suiteOverride
                ?? fixtureSuite(provenanceEnabled: provenanceEnabled),
            capabilityManifest: try manifestOverride
                ?? capabilityManifest(provenanceEnabled: provenanceEnabled),
            evidence: try index ?? evidenceIndex()
        )
    }

    // MARK: - Recorded results

    /// Which metrics each measurement gate reports.
    ///
    /// Decoded pixel count and encoded input size have no gate of their own, so each is
    /// reported alongside its target's peak-memory gate. A fixture arrangement, not a
    /// requirement: the validator asks whether each metric was measured for its target,
    /// not which gate carried it.
    static func measuredMetrics(for gate: DeviceGate) -> [ResourceMetric] {
        switch gate {
        case .coldModelLoad: [.coldModelLoadTime]
        case .warmAnalysisLatency: [.warmAnalysisLatency]
        case .mainApplicationPeakMemory: [.peakResidentMemory, .decodedPixelCount]
        case .mainApplicationTemporaryStorage: [.temporaryStorage]
        case .mainApplicationEnergy: [.energyImpact]
        case .sustainedAnalysisThermal: [.thermalState]
        case .handoffLatency: [.handoffLatency]
        case .shareExtensionPeakMemory: [.peakResidentMemory, .encodedInputSize]
        case .shareExtensionTemporaryStorage: [.temporaryStorage]
        case .shareExtensionEnergy: [.energyImpact]
        case .sustainedHandoffThermal: [.thermalState]
        default: []
        }
    }

    /// Which comparisons each non-measurement gate reports.
    static func comparedMetrics(for gate: DeviceGate) -> [ComparisonMetric] {
        guard gate.measurementTarget == nil else { return [] }
        switch gate {
        case .preprocessingParity: return [.preprocessingOutput]
        case .rawLogitParity: return [.rawLogit]
        case .rankAgreement: return [.rankAgreement]
        case .categoricalAgreement: return [.categoricalOutcome]
        case .screenshotFidelity: return [.screenshotGeometry]
        case .routeByteParity: return [.retainedBytes, .bytePreservationStatus]
        case .provenanceFixtures: return [.provenanceState]
        default: return [.categoricalOutcome]
        }
    }

    static func measurementRecord(
        _ metric: ResourceMetric,
        target: ExecutionTarget,
        specification: String = ResourcePlanSample.planIdentifier,
        rawValues: [Decimal] = [90, 100],
        summaryStatistic: SummaryStatistic = .median,
        summaryValue: Decimal = 95,
        limit limitOverride: ValidatedLimit? = nil,
        outcome: GateOutcome = .passed
    ) throws -> MeasurementRecord {
        try MeasurementRecord(
            metric: metric,
            target: target,
            specification: Sample.evidence(specification),
            rawValues: rawValues,
            summaryStatistic: summaryStatistic,
            summaryValue: summaryValue,
            limit: limitOverride ?? limit(metric),
            outcome: outcome
        )
    }

    static func comparisonRecord(
        _ metric: ComparisonMetric,
        specification: String = ResourcePlanSample.planIdentifier,
        compared: Int = 96,
        agreeing: Int = 96,
        maximumDeviation: Decimal? = 0,
        outcome: GateOutcome = .passed
    ) throws -> ComparisonRecord {
        try ComparisonRecord(
            metric: metric,
            specification: Sample.evidence(specification),
            comparedFixtureCount: Sample.nonNegative(compared),
            agreeingFixtureCount: Sample.nonNegative(agreeing),
            maximumDeviation: metric.isCategorical
                ? nil
                : maximumDeviation.map { Sample.nonNegativeDecimal($0) },
            outcome: outcome
        )
    }

    static func gateRecord(
        _ gate: DeviceGate,
        provenanceEnabled: Bool = false,
        measurements measurementOverride: [MeasurementRecord]? = nil,
        comparisons comparisonOverride: [ComparisonRecord]? = nil,
        outcome outcomeOverride: GateOutcome? = nil
    ) throws -> DeviceGateResultRecord {
        let applicable = !gate.isProvenanceConditional || provenanceEnabled
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
        let measurements = try measurementOverride
            ?? measuredMetrics(for: gate).map {
                try measurementRecord($0, target: target ?? .mainApplication)
            }
        let comparisons = try comparisonOverride
            ?? comparedMetrics(for: gate).map { try comparisonRecord($0) }
        return try DeviceGateResultRecord(
            gate: gate,
            applicability: .applicable,
            outcome: outcomeOverride ?? .passed,
            measurements: measurements,
            comparisons: comparisons
        )
    }

    static func gateRecords(
        provenanceEnabled: Bool = false,
        overrides: [DeviceGate: DeviceGateResultRecord] = [:]
    ) throws -> [DeviceGateResultRecord] {
        try DeviceGate.allCases.sorted { $0.rawValue < $1.rawValue }.map { gate in
            if let override = overrides[gate] { return override }
            return try gateRecord(gate, provenanceEnabled: provenanceEnabled)
        }
    }

    static func resultSet(
        identifier: String = "results.device-validation",
        configuration: CandidateDeviceConfiguration? = nil,
        versionTuple: ValidationVersionTuple? = nil,
        environment: ExecutionEnvironment = .physicalIPhone,
        provenanceEnabled: Bool = false,
        gateResults: [DeviceGateResultRecord]? = nil
    ) throws -> DeviceValidationResultSet {
        let capabilities: Set<CapabilityID> = provenanceEnabled
            ? [.pixelAnalysis, .contentCredentialValidation]
            : [.pixelAnalysis]
        return try DeviceValidationResultSet(
            id: Sample.artifact(identifier),
            schemaVersion: .v1,
            configuration: try configuration ?? candidate(),
            versionTuple: try versionTuple ?? Sample.versionTuple(capabilities: capabilities),
            environment: environment,
            gateResults: try gateResults
                ?? gateRecords(provenanceEnabled: provenanceEnabled)
        )
    }
}
