import Foundation

// Device validation results, including accessibility and localization matrices.
//
// Requirement 13.17 requires each mandatory gate result to record its device, version
// tuple, measured values, categorical comparisons, and pass or fail result, and
// Requirement 11.19 requires main-application and Share Extension measurements to be
// separate sets with separate gate results.
//
// Raw values and the pass decision are stored separately, so a threshold cannot be
// chosen after observing a measurement and then presented as if it had been predeclared.

// MARK: - Measurements and comparisons

/// One measured metric: every raw sample, the declared summary, and the outcome.
public struct MeasurementRecord: Hashable, Codable, Sendable {
    public let metric: ResourceMetric
    public let target: ExecutionTarget

    /// The predeclared specification this measurement executed.
    public let specification: EvidenceSource

    /// Every raw sample, retained rather than replaced by its summary.
    public let rawValues: [Decimal]

    public let summaryStatistic: SummaryStatistic
    public let summaryValue: Decimal
    public let limit: ValidatedLimit
    public let outcome: GateOutcome

    public init(
        metric: ResourceMetric,
        target: ExecutionTarget,
        specification: EvidenceSource,
        rawValues: [Decimal],
        summaryStatistic: SummaryStatistic,
        summaryValue: Decimal,
        limit: ValidatedLimit,
        outcome: GateOutcome
    ) throws {
        guard ResourceMetric.requiredMetrics(for: target).contains(metric) else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "measurementRecord.metric",
                value: metric.rawValue,
                reason: "\(target.rawValue) does not measure this metric"
            )
        }
        guard limit.matches(metric) else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "measurementRecord.limit",
                expected: metric.isCategorical ? "a thermal-state limit" : "a numeric limit",
                found: metric.isCategorical ? "a numeric limit" : "a thermal-state limit"
            )
        }
        if outcome != .notExecuted {
            try ArtifactSchemaValidation.requireNonEmpty(
                rawValues,
                field: "measurementRecord.rawValues"
            )
        }
        self.metric = metric
        self.target = target
        self.specification = specification
        self.rawValues = rawValues
        self.summaryStatistic = summaryStatistic
        self.summaryValue = summaryValue
        self.limit = limit
        self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey {
        case metric, target, specification, rawValues, summaryStatistic, summaryValue, limit
        case outcome
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                metric: container.decode(ResourceMetric.self, forKey: .metric),
                target: container.decode(ExecutionTarget.self, forKey: .target),
                specification: container.decode(EvidenceSource.self, forKey: .specification),
                rawValues: container.decode([Decimal].self, forKey: .rawValues),
                summaryStatistic: container.decode(
                    SummaryStatistic.self,
                    forKey: .summaryStatistic
                ),
                summaryValue: container.decode(Decimal.self, forKey: .summaryValue),
                limit: container.decode(ValidatedLimit.self, forKey: .limit),
                outcome: container.decode(GateOutcome.self, forKey: .outcome)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// One comparison against an approved reference, with its measured agreement.
public struct ComparisonRecord: Hashable, Codable, Sendable {
    public let metric: ComparisonMetric

    /// The predeclared comparison this record executed.
    public let specification: EvidenceSource

    /// Fixtures compared. Never zero for an executed comparison.
    public let comparedFixtureCount: NonNegativeCount

    /// Fixtures that agreed with the approved expected result.
    public let agreeingFixtureCount: NonNegativeCount

    /// Largest observed numeric deviation, for a numeric comparison.
    public let maximumDeviation: NonNegativeDecimal?

    public let outcome: GateOutcome

    public init(
        metric: ComparisonMetric,
        specification: EvidenceSource,
        comparedFixtureCount: NonNegativeCount,
        agreeingFixtureCount: NonNegativeCount,
        maximumDeviation: NonNegativeDecimal?,
        outcome: GateOutcome
    ) throws {
        guard agreeingFixtureCount.value <= comparedFixtureCount.value else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "comparisonRecord.agreeingFixtureCount",
                value: "\(agreeingFixtureCount.value)",
                allowed: "at most the compared fixture count \(comparedFixtureCount.value)"
            )
        }
        if outcome != .notExecuted, comparedFixtureCount.value == 0 {
            throw ArtifactSchemaError.nonPositiveValue(
                field: "comparisonRecord.comparedFixtureCount",
                value: "0"
            )
        }
        if metric.isCategorical, maximumDeviation != nil {
            throw ArtifactSchemaError.forbiddenValue(
                field: "comparisonRecord.maximumDeviation",
                value: "present",
                reason: "a categorical comparison has no numeric deviation"
            )
        }
        self.metric = metric
        self.specification = specification
        self.comparedFixtureCount = comparedFixtureCount
        self.agreeingFixtureCount = agreeingFixtureCount
        self.maximumDeviation = maximumDeviation
        self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey {
        case metric, specification, comparedFixtureCount, agreeingFixtureCount, maximumDeviation
        case outcome
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                metric: container.decode(ComparisonMetric.self, forKey: .metric),
                specification: container.decode(EvidenceSource.self, forKey: .specification),
                comparedFixtureCount: container.decode(
                    NonNegativeCount.self,
                    forKey: .comparedFixtureCount
                ),
                agreeingFixtureCount: container.decode(
                    NonNegativeCount.self,
                    forKey: .agreeingFixtureCount
                ),
                maximumDeviation: container.decodeIfPresent(
                    NonNegativeDecimal.self,
                    forKey: .maximumDeviation
                ),
                outcome: container.decode(GateOutcome.self, forKey: .outcome)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - Gate result record

/// The recorded result of one mandatory device gate.
public struct DeviceGateResultRecord: Hashable, Codable, Sendable {
    public let gate: DeviceGate
    public let applicability: GateApplicability
    public let outcome: GateOutcome
    public let measurements: [MeasurementRecord]
    public let comparisons: [ComparisonRecord]

    public init(
        gate: DeviceGate,
        applicability: GateApplicability,
        outcome: GateOutcome,
        measurements: [MeasurementRecord],
        comparisons: [ComparisonRecord]
    ) throws {
        if !applicability.isApplicable {
            guard outcome == .notExecuted, measurements.isEmpty, comparisons.isEmpty else {
                throw ArtifactSchemaError.inconsistentReference(
                    field: "gateRecord[\(gate.rawValue)]",
                    expected: "no result for a gate declared not applicable",
                    found: "recorded work"
                )
            }
        } else if outcome != .notExecuted {
            guard !measurements.isEmpty || !comparisons.isEmpty else {
                throw ArtifactSchemaError.emptyValue(
                    field: "gateRecord[\(gate.rawValue)].measurements and comparisons"
                )
            }
        }
        if let target = gate.measurementTarget {
            for measurement in measurements where measurement.target != target {
                throw ArtifactSchemaError.inconsistentReference(
                    field: "gateRecord[\(gate.rawValue)].measurements.target",
                    expected: target.rawValue,
                    found: measurement.target.rawValue
                )
            }
        }
        self.gate = gate
        self.applicability = applicability
        self.outcome = outcome
        self.measurements = measurements
        self.comparisons = comparisons
    }

    private enum CodingKeys: String, CodingKey {
        case gate, applicability, outcome, measurements, comparisons
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                gate: container.decode(DeviceGate.self, forKey: .gate),
                applicability: container.decode(GateApplicability.self, forKey: .applicability),
                outcome: container.decode(GateOutcome.self, forKey: .outcome),
                measurements: container.decode([MeasurementRecord].self, forKey: .measurements),
                comparisons: container.decode([ComparisonRecord].self, forKey: .comparisons)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// Every gate result produced for one configuration under one version tuple.
///
/// The result set is bound to one tuple, which is what makes pooling results from
/// different builds, bundles, fixtures, plans, or capability versions unrepresentable
/// (Requirement 13.20).
public struct DeviceValidationResultSet: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    public let configuration: CandidateDeviceConfiguration
    public let versionTuple: ValidationVersionTuple
    public let environment: ExecutionEnvironment

    /// One record per mandatory gate, each gate exactly once.
    public let gateResults: [DeviceGateResultRecord]

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        configuration: CandidateDeviceConfiguration,
        versionTuple: ValidationVersionTuple,
        environment: ExecutionEnvironment,
        gateResults: [DeviceGateResultRecord]
    ) throws {
        guard configuration.appBuild == versionTuple.appBuild else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "resultSet.configuration.appBuild",
                expected: versionTuple.appBuild.rawValue,
                found: configuration.appBuild.rawValue
            )
        }
        try ArtifactSchemaValidation.requireExactCoverage(
            gateResults.map(\.gate.rawValue),
            required: Set(DeviceGate.mandatoryGates.map(\.rawValue)),
            field: "resultSet.gateResults"
        )
        for record in gateResults where record.gate.isProvenanceConditional {
            guard record.applicability.isApplicable == versionTuple.enablesProvenance else {
                throw ArtifactSchemaError.inconsistentReference(
                    field: "resultSet.gateResults[\(record.gate.rawValue)].applicability",
                    expected: versionTuple.enablesProvenance ? "applicable" : "not applicable",
                    found: record.applicability.isApplicable ? "applicable" : "not applicable"
                )
            }
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.configuration = configuration
        self.versionTuple = versionTuple
        self.environment = environment
        self.gateResults = gateResults
    }

    /// Whether this result set can supply release evidence at all.
    ///
    /// A simulator or development-Mac run is recorded honestly and reports `false`.
    public var isPhysicalDeviceEvidence: Bool { environment.isPhysicalDeviceEvidence }

    /// Mandatory gates that did not pass and were not declared inapplicable.
    public var unsatisfiedGates: Set<DeviceGate> {
        Set(
            gateResults
                .filter { record in
                    switch record.applicability {
                    case .applicable: !record.outcome.isPassing || !isPhysicalDeviceEvidence
                    case let .notApplicable(decision): !decision.isApproved
                    }
                }
                .map(\.gate)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, configuration, versionTuple, environment, gateResults
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                configuration: container.decode(
                    CandidateDeviceConfiguration.self,
                    forKey: .configuration
                ),
                versionTuple: container.decode(ValidationVersionTuple.self, forKey: .versionTuple),
                environment: container.decode(ExecutionEnvironment.self, forKey: .environment),
                gateResults: container.decode(
                    [DeviceGateResultRecord].self,
                    forKey: .gateResults
                )
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}
