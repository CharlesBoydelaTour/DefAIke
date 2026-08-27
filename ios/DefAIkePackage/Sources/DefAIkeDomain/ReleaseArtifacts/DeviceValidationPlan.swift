import Foundation

// The signed Device Validation Plan.
//
// Requirement 13.3 requires reference artifacts, comparison metrics, numeric tolerances,
// expected categorical outcomes, measurement conditions, and missing-result rules to be
// declared before validation begins. Requirement 11.4 requires every resource
// measurement to declare its device configuration, operating system, build, workload,
// cold or warm state, concurrency, starting thermal and power conditions, sample count,
// summary statistic, and pass limit. Requirements 15.8 and 15.9 make this plan the
// authoritative source of numeric analysis-time and resource limits.
//
// Every one of those is a required field here, so a plan cannot be partially declared
// and then completed after seeing results. The numbers themselves stay unresolved.

// MARK: - Comparison metrics

/// A comparison a fixture run performs against an approved reference.
public enum ComparisonMetric: String, Codable, Sendable, Hashable, CaseIterable {
    case preprocessingOutput = "preprocessing-output"
    case rawLogit = "raw-logit"
    case rankAgreement = "rank-agreement"
    case categoricalOutcome = "categorical-outcome"
    case retainedBytes = "retained-bytes"
    case bytePreservationStatus = "byte-preservation-status"
    case screenshotGeometry = "screenshot-geometry"
    case provenanceState = "provenance-state"

    /// Whether this comparison is categorical rather than numeric.
    public var isCategorical: Bool {
        switch self {
        case .preprocessingOutput, .rawLogit, .rankAgreement, .screenshotGeometry: false
        case .categoricalOutcome, .retainedBytes, .bytePreservationStatus, .provenanceState: true
        }
    }
}

/// How a numeric comparison is bounded.
public enum ToleranceKind: String, Codable, Sendable, Hashable, CaseIterable {
    case absolute
    case relative
    case exact
}

/// A declared numeric tolerance for one comparison.
public struct NumericTolerance: Hashable, Codable, Sendable {
    public let kind: ToleranceKind
    public let value: NonNegativeDecimal

    public init(kind: ToleranceKind, value: NonNegativeDecimal) throws {
        if kind == .exact, value.value != 0 {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "tolerance.value",
                expected: "0 for an exact comparison",
                found: "\(value.value)"
            )
        }
        self.kind = kind
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                kind: container.decode(ToleranceKind.self, forKey: .kind),
                value: container.decode(NonNegativeDecimal.self, forKey: .value)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// One predeclared comparison: metric, reference, and acceptance rule.
///
/// A categorical comparison declares a required agreement ratio, which Requirement 13.8
/// fixes at 100% for Pixel Evidence outcomes; a numeric comparison declares a tolerance.
public struct ComparisonSpecification: Hashable, Codable, Sendable {
    public let metric: ComparisonMetric
    public let reference: EvidenceSource
    public let tolerance: NumericTolerance?
    public let requiredAgreement: UnitInterval?

    public init(
        metric: ComparisonMetric,
        reference: EvidenceSource,
        tolerance: NumericTolerance?,
        requiredAgreement: UnitInterval?
    ) throws {
        if metric.isCategorical {
            guard let requiredAgreement, tolerance == nil else {
                throw ArtifactSchemaError.missingRequiredEntries(
                    field: "comparison[\(metric.rawValue)]",
                    keys: ["requiredAgreement without a numeric tolerance"]
                )
            }
            if metric == .categoricalOutcome, requiredAgreement != .one {
                throw ArtifactSchemaError.fixedValueMismatch(
                    field: "comparison[\(metric.rawValue)].requiredAgreement",
                    expected: "1",
                    found: "\(requiredAgreement.value)"
                )
            }
        } else {
            guard tolerance != nil, requiredAgreement == nil else {
                throw ArtifactSchemaError.missingRequiredEntries(
                    field: "comparison[\(metric.rawValue)]",
                    keys: ["tolerance without a required agreement ratio"]
                )
            }
        }
        self.metric = metric
        self.reference = reference
        self.tolerance = tolerance
        self.requiredAgreement = requiredAgreement
    }

    private enum CodingKeys: String, CodingKey {
        case metric, reference, tolerance, requiredAgreement
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                metric: container.decode(ComparisonMetric.self, forKey: .metric),
                reference: container.decode(EvidenceSource.self, forKey: .reference),
                tolerance: container.decodeIfPresent(NumericTolerance.self, forKey: .tolerance),
                requiredAgreement: container.decodeIfPresent(
                    UnitInterval.self,
                    forKey: .requiredAgreement
                )
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - Measurement conditions

/// Whether the measurement starts from a cold or warm process state.
public enum ProcessWarmth: String, Codable, Sendable, Hashable, CaseIterable {
    case cold
    case warm
}

/// Whether pixel and provenance work run serially or concurrently.
///
/// The design refuses to assume that lower wall time is safer than lower peak memory or
/// energy, so the execution policy is measured and approved rather than chosen in code.
public enum EvidenceBranchExecution: String, Codable, Sendable, Hashable, CaseIterable {
    case serial
    case concurrent
}

/// The device power condition a measurement starts from.
public enum StartingPowerCondition: String, Codable, Sendable, Hashable, CaseIterable {
    case batteryUnplugged = "battery-unplugged"
    case batteryPluggedIn = "battery-plugged-in"
}

/// The statistic that summarizes repeated samples.
public enum SummaryStatistic: String, Codable, Sendable, Hashable, CaseIterable {
    case median
    case mean
    case maximum
    case percentile95 = "percentile-95"
}

/// One predeclared resource measurement, complete enough to be repeatable.
public struct ResourceMeasurementSpecification: Hashable, Codable, Sendable {
    public let metric: ResourceMetric
    public let target: ExecutionTarget
    public let hardwareIdentifier: DeviceHardwareID
    public let osVersion: PlatformVersion
    public let appBuild: AppBuildID

    /// The fixture workload measured.
    public let workload: EvidenceSource

    public let warmth: ProcessWarmth
    public let branchExecution: EvidenceBranchExecution
    public let startingThermalState: ThermalState
    public let startingPowerCondition: StartingPowerCondition
    public let sampleCount: PositiveCount
    public let summaryStatistic: SummaryStatistic
    public let passLimit: ValidatedLimit

    public init(
        metric: ResourceMetric,
        target: ExecutionTarget,
        hardwareIdentifier: DeviceHardwareID,
        osVersion: PlatformVersion,
        appBuild: AppBuildID,
        workload: EvidenceSource,
        warmth: ProcessWarmth,
        branchExecution: EvidenceBranchExecution,
        startingThermalState: ThermalState,
        startingPowerCondition: StartingPowerCondition,
        sampleCount: PositiveCount,
        summaryStatistic: SummaryStatistic,
        passLimit: ValidatedLimit
    ) throws {
        guard ResourceMetric.requiredMetrics(for: target).contains(metric) else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "measurement.metric",
                value: metric.rawValue,
                reason: "\(target.rawValue) does not measure this metric"
            )
        }
        guard passLimit.matches(metric) else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "measurement.passLimit",
                expected: metric.isCategorical ? "a thermal-state limit" : "a numeric limit",
                found: metric.isCategorical ? "a numeric limit" : "a thermal-state limit"
            )
        }
        guard osVersion >= .iOS17 else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "measurement.osVersion",
                value: osVersion.description,
                allowed: "at least \(PlatformVersion.iOS17)"
            )
        }
        self.metric = metric
        self.target = target
        self.hardwareIdentifier = hardwareIdentifier
        self.osVersion = osVersion
        self.appBuild = appBuild
        self.workload = workload
        self.warmth = warmth
        self.branchExecution = branchExecution
        self.startingThermalState = startingThermalState
        self.startingPowerCondition = startingPowerCondition
        self.sampleCount = sampleCount
        self.summaryStatistic = summaryStatistic
        self.passLimit = passLimit
    }

    private enum CodingKeys: String, CodingKey {
        case metric, target, hardwareIdentifier, osVersion, appBuild, workload, warmth
        case branchExecution, startingThermalState, startingPowerCondition, sampleCount
        case summaryStatistic, passLimit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                metric: container.decode(ResourceMetric.self, forKey: .metric),
                target: container.decode(ExecutionTarget.self, forKey: .target),
                hardwareIdentifier: container.decode(
                    DeviceHardwareID.self,
                    forKey: .hardwareIdentifier
                ),
                osVersion: container.decode(PlatformVersion.self, forKey: .osVersion),
                appBuild: container.decode(AppBuildID.self, forKey: .appBuild),
                workload: container.decode(EvidenceSource.self, forKey: .workload),
                warmth: container.decode(ProcessWarmth.self, forKey: .warmth),
                branchExecution: container.decode(
                    EvidenceBranchExecution.self,
                    forKey: .branchExecution
                ),
                startingThermalState: container.decode(
                    ThermalState.self,
                    forKey: .startingThermalState
                ),
                startingPowerCondition: container.decode(
                    StartingPowerCondition.self,
                    forKey: .startingPowerCondition
                ),
                sampleCount: container.decode(PositiveCount.self, forKey: .sampleCount),
                summaryStatistic: container.decode(SummaryStatistic.self, forKey: .summaryStatistic),
                passLimit: container.decode(ValidatedLimit.self, forKey: .passLimit)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// What a missing result means.
///
/// Requirement 13.19 excludes a configuration whose mandatory result is missing, so the
/// only admissible rule is that missing fails. `treatAsPass` is representable purely so
/// the schema can refuse it by name.
public enum MissingResultRule: String, Codable, Sendable, Hashable, CaseIterable {
    case treatAsFailure = "treat-as-failure"
    case treatAsPass = "treat-as-pass"
}

// MARK: - Plan

/// The predeclared, signed plan the Device Validation Suite executes.
public struct DeviceValidationPlan: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// Candidate configurations this plan covers. Never empty.
    public let candidateConfigurations: [CandidateDeviceConfiguration]

    public let fixtureSuite: ArtifactID
    public let modelBundle: ModelBundleID
    public let capabilityManifest: ArtifactID

    /// Comparison specifications, each metric declared once.
    public let comparisons: [ComparisonSpecification]

    /// Resource measurement specifications for both targets.
    public let measurements: [ResourceMeasurementSpecification]

    public let missingResultRule: MissingResultRule

    /// The release decision that predeclared this plan (Requirement 13.3).
    public let approval: ApprovalRecord

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        candidateConfigurations: [CandidateDeviceConfiguration],
        fixtureSuite: ArtifactID,
        modelBundle: ModelBundleID,
        capabilityManifest: ArtifactID,
        comparisons: [ComparisonSpecification],
        measurements: [ResourceMeasurementSpecification],
        missingResultRule: MissingResultRule,
        approval: ApprovalRecord
    ) throws {
        try ArtifactSchemaValidation.requireNonEmpty(
            candidateConfigurations,
            field: "plan.candidateConfigurations"
        )
        try ArtifactSchemaValidation.requireUniqueKeys(
            candidateConfigurations.map {
                "\($0.hardwareIdentifier.rawValue)@\($0.osVersion.description)"
            },
            field: "plan.candidateConfigurations"
        )
        try ArtifactSchemaValidation.requireUniqueKeys(
            comparisons.map(\.metric.rawValue),
            field: "plan.comparisons"
        )
        try ArtifactSchemaValidation.requireNonEmpty(comparisons, field: "plan.comparisons")
        try ArtifactSchemaValidation.requireUniqueKeys(
            measurements.map { "\($0.target.rawValue)/\($0.metric.rawValue)/"
                + "\($0.hardwareIdentifier.rawValue)@\($0.osVersion.description)"
            },
            field: "plan.measurements"
        )
        guard missingResultRule == .treatAsFailure else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "plan.missingResultRule",
                value: missingResultRule.rawValue,
                reason: "a missing mandatory device result excludes the configuration"
            )
        }

        // Every candidate configuration needs the complete metric set for both targets,
        // so no target's measurement set can be silently omitted (Requirement 11.19).
        for configuration in candidateConfigurations {
            for target in ExecutionTarget.allCases {
                let declared = Set(
                    measurements
                        .filter {
                            $0.target == target
                                && $0.hardwareIdentifier == configuration.hardwareIdentifier
                                && $0.osVersion == configuration.osVersion
                        }
                        .map(\.metric.rawValue)
                )
                let required = Set(ResourceMetric.requiredMetrics(for: target).map(\.rawValue))
                let missing = required.subtracting(declared)
                guard missing.isEmpty else {
                    throw ArtifactSchemaError.missingRequiredEntries(
                        field: """
                            plan.measurements[\(target.rawValue)/\
                            \(configuration.hardwareIdentifier.rawValue)]
                            """,
                        keys: missing.sorted()
                    )
                }
            }
        }

        self.id = id
        self.schemaVersion = schemaVersion
        self.candidateConfigurations = candidateConfigurations
        self.fixtureSuite = fixtureSuite
        self.modelBundle = modelBundle
        self.capabilityManifest = capabilityManifest
        self.comparisons = comparisons
        self.measurements = measurements
        self.missingResultRule = missingResultRule
        self.approval = approval
    }

    /// The comparison specification for one metric, or `nil` when the plan omits it.
    public func comparison(for metric: ComparisonMetric) -> ComparisonSpecification? {
        comparisons.first { $0.metric == metric }
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, candidateConfigurations, fixtureSuite, modelBundle
        case capabilityManifest, comparisons, measurements, missingResultRule, approval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                candidateConfigurations: container.decode(
                    [CandidateDeviceConfiguration].self,
                    forKey: .candidateConfigurations
                ),
                fixtureSuite: container.decode(ArtifactID.self, forKey: .fixtureSuite),
                modelBundle: container.decode(ModelBundleID.self, forKey: .modelBundle),
                capabilityManifest: container.decode(ArtifactID.self, forKey: .capabilityManifest),
                comparisons: container.decode(
                    [ComparisonSpecification].self,
                    forKey: .comparisons
                ),
                measurements: container.decode(
                    [ResourceMeasurementSpecification].self,
                    forKey: .measurements
                ),
                missingResultRule: container.decode(
                    MissingResultRule.self,
                    forKey: .missingResultRule
                ),
                approval: container.decode(ApprovalRecord.self, forKey: .approval)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}
