import Foundation

// The signed Resource Budgets.
//
// Requirement 11.1 requires separate numeric budgets for the main application and the
// Share Extension. Requirements 11.2 and 11.3 fix which metrics each one must define,
// and they are different sets: the extension has no decoded pixel count, cold model
// load, or warm analysis latency, because it runs no inference.
//
// The numbers are decision D6 and stay unresolved. The schema requires each target's
// exact metric set with positive, unit-carrying limits, so a budget cannot ship with a
// missing metric, a zero standing in for "unmeasured", or a metric borrowed from the
// other target.

/// A resource dimension a budget can limit.
public enum ResourceMetric: String, Codable, Sendable, Hashable, CaseIterable {
    // Main application (Requirement 11.2).
    case decodedPixelCount = "decoded-pixel-count"
    case coldModelLoadTime = "cold-model-load-time"
    case warmAnalysisLatency = "warm-analysis-latency"

    // Share Extension (Requirement 11.3).
    case encodedInputSize = "encoded-input-size"
    case handoffLatency = "handoff-latency"

    // Both targets.
    case peakResidentMemory = "peak-resident-memory"
    case temporaryStorage = "temporary-storage"
    case energyImpact = "energy-impact"
    case thermalState = "thermal-state"

    /// The exact metric set a target's budget must define.
    public static func requiredMetrics(for target: ExecutionTarget) -> Set<ResourceMetric> {
        switch target {
        case .mainApplication:
            [
                .decodedPixelCount, .peakResidentMemory, .temporaryStorage, .coldModelLoadTime,
                .warmAnalysisLatency, .energyImpact, .thermalState,
            ]
        case .shareExtension:
            [
                .encodedInputSize, .peakResidentMemory, .temporaryStorage, .handoffLatency,
                .energyImpact, .thermalState,
            ]
        }
    }

    /// Whether this metric is categorical (a thermal state) rather than numeric.
    public var isCategorical: Bool { self == .thermalState }
}

/// The unit a numeric limit is expressed in.
///
/// Carried explicitly because Requirement 15.2 only permits determinate progress when
/// completed and total describe the same measured unit, and because a limit without a
/// unit cannot be compared to a measurement.
public enum ResourceLimitUnit: String, Codable, Sendable, Hashable, CaseIterable {
    case pixels
    case bytes
    case milliseconds
    case milliwattHours = "milliwatt-hours"
}

/// A thermal state, ordered from coolest to hottest.
public enum ThermalState: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case nominal
    case fair
    case serious
    case critical

    private var severity: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.severity < rhs.severity }
}

/// One hard limit, either numeric or categorical.
///
/// A limit always names the measurement conditions that produced it, so a number
/// cannot be inherited from an unrelated measurement setup.
public enum ValidatedLimit: Hashable, Codable, Sendable {
    /// A positive numeric ceiling in the given unit.
    case numeric(value: PositiveDecimal, unit: ResourceLimitUnit)
    /// The hottest thermal state that still passes.
    case thermal(maximumState: ThermalState)

    /// Whether this limit kind matches the metric it is attached to.
    public func matches(_ metric: ResourceMetric) -> Bool {
        switch self {
        case .numeric: !metric.isCategorical
        case .thermal: metric.isCategorical
        }
    }
}

/// One metric, its hard limit, and the measurement conditions behind it.
public struct ResourceLimitEntry: Hashable, Codable, Sendable {
    public let metric: ResourceMetric
    public let limit: ValidatedLimit

    /// The predeclared measurement conditions this limit was derived from
    /// (Requirement 11.4).
    public let measurementConditions: EvidenceSource

    public init(
        metric: ResourceMetric,
        limit: ValidatedLimit,
        measurementConditions: EvidenceSource
    ) throws {
        guard limit.matches(metric) else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "resourceLimit[\(metric.rawValue)]",
                expected: metric.isCategorical ? "a thermal-state limit" : "a numeric limit",
                found: metric.isCategorical ? "a numeric limit" : "a thermal-state limit"
            )
        }
        self.metric = metric
        self.limit = limit
        self.measurementConditions = measurementConditions
    }

    private enum CodingKeys: String, CodingKey {
        case metric, limit, measurementConditions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                metric: container.decode(ResourceMetric.self, forKey: .metric),
                limit: container.decode(ValidatedLimit.self, forKey: .limit),
                measurementConditions: container.decode(
                    EvidenceSource.self,
                    forKey: .measurementConditions
                )
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// One target's complete numeric budget.
public struct ResourceBudget: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion
    public let target: ExecutionTarget

    /// Exactly the metric set the requirements fix for this target.
    public let hardLimits: [ResourceLimitEntry]

    /// The Device Validation Plan that measured these limits (Requirement 15.9).
    public let validationPlan: ArtifactID

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        target: ExecutionTarget,
        hardLimits: [ResourceLimitEntry],
        validationPlan: ArtifactID
    ) throws {
        try ArtifactSchemaValidation.requireExactCoverage(
            hardLimits.map(\.metric.rawValue),
            required: Set(ResourceMetric.requiredMetrics(for: target).map(\.rawValue)),
            field: "hardLimits[\(target.rawValue)]"
        )
        self.id = id
        self.schemaVersion = schemaVersion
        self.target = target
        self.hardLimits = hardLimits
        self.validationPlan = validationPlan
    }

    /// The hard limit for one metric, or `nil` when the metric does not apply to this
    /// target. Total over the target's required metric set by construction.
    public func limit(for metric: ResourceMetric) -> ValidatedLimit? {
        hardLimits.first { $0.metric == metric }?.limit
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, target, hardLimits, validationPlan
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                target: container.decode(ExecutionTarget.self, forKey: .target),
                hardLimits: container.decode([ResourceLimitEntry].self, forKey: .hardLimits),
                validationPlan: container.decode(ArtifactID.self, forKey: .validationPlan)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// Both target budgets, bound together.
///
/// Requirement 11.1 is about the pair, not about one budget: a release that defines a
/// main-application budget and no extension budget is invalid, and a pair whose two
/// budgets are the same artifact is invalid too.
public struct ResourceBudgetSet: Hashable, Codable, Sendable {
    public let mainApplication: ResourceBudget
    public let shareExtension: ResourceBudget

    public init(mainApplication: ResourceBudget, shareExtension: ResourceBudget) throws {
        guard mainApplication.target == .mainApplication else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "budgetSet.mainApplication.target",
                expected: ExecutionTarget.mainApplication.rawValue,
                found: mainApplication.target.rawValue
            )
        }
        guard shareExtension.target == .shareExtension else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "budgetSet.shareExtension.target",
                expected: ExecutionTarget.shareExtension.rawValue,
                found: shareExtension.target.rawValue
            )
        }
        guard mainApplication.id != shareExtension.id else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "budgetSet.shareExtension.id",
                value: shareExtension.id.rawValue,
                reason: "each target needs its own separately measured budget"
            )
        }
        self.mainApplication = mainApplication
        self.shareExtension = shareExtension
    }

    /// The budget bound to one target.
    public func budget(for target: ExecutionTarget) -> ResourceBudget {
        switch target {
        case .mainApplication: mainApplication
        case .shareExtension: shareExtension
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mainApplication, shareExtension
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                mainApplication: container.decode(ResourceBudget.self, forKey: .mainApplication),
                shareExtension: container.decode(ResourceBudget.self, forKey: .shareExtension)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}
