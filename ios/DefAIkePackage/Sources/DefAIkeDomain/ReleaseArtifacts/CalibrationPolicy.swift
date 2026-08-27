import Foundation

// The signed Calibration Policy.
//
// The requirements fix the shape of harm control without fixing its numbers: one
// False Accusation Budget no greater than 1%, exactly three labels, an abstention
// half-width of at least 0.131 raw-logit units, abstention for short edges 1 through
// 439, evidence behind every additional quality rule, and `1.390625` retained as
// upstream model metadata rather than a product boundary.
//
// The numbers themselves are decision D2 and remain unresolved. This schema makes
// every one of them a required, range-checked field: there is no default budget, no
// default boundary, no default half-width, and no way to represent an additional
// abstention rule that cites no release evidence.

// MARK: - Budget and pass rule

/// The single Version 1 False Accusation Budget.
///
/// Requirement 5.1 caps it at 1.0% and permits exactly one budget; there is no
/// higher user-selectable mode. Zero is rejected as well: a budget of zero is not a
/// measured decision.
public struct FalseAccusationBudget: ValidatedScalarSchemaValue, CustomStringConvertible {
    /// Maximum permitted value: 1.0%.
    public static let maximumRate = Decimal(sign: .plus, exponent: -2, significand: 1)

    public let rate: Decimal

    public var rawSchemaValue: Decimal { rate }

    public init(validating raw: Decimal) throws {
        try ArtifactSchemaValidation.requirePositive(raw, field: "falseAccusationBudget")
        guard raw <= Self.maximumRate else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "falseAccusationBudget",
                value: "\(raw)",
                allowed: "greater than 0 and at most \(Self.maximumRate)"
            )
        }
        self.rate = raw
    }

    public var description: String { "\(rate)" }
}

/// A predeclared method for computing an interval on a measured rate.
///
/// Requirement 5.15 requires the method to be predeclared, so it is a required
/// field selected before evaluation, never a method chosen after seeing results.
public enum ConfidenceIntervalMethod: String, Codable, Sendable, Hashable, CaseIterable {
    case wilsonScore = "wilson-score"
    case clopperPearson = "clopper-pearson"
    case agrestiCoull = "agresti-coull"
    case jeffreys
    case bootstrapPercentile = "bootstrap-percentile"
}

/// Which statistic the budget pass decision reads.
public enum BudgetPassStatistic: String, Codable, Sendable, Hashable, CaseIterable {
    /// The observed rate alone must satisfy the budget.
    case observedRate = "observed-rate"
    /// The interval's upper bound must satisfy the budget.
    case intervalUpperBound = "interval-upper-bound"
    /// Both the observed rate and the interval upper bound must satisfy it.
    case observedRateAndIntervalUpperBound = "observed-rate-and-interval-upper-bound"
}

/// The release pass rule for the False Accusation Budget (Requirement 5.21).
public struct FalseAccusationPassRule: Hashable, Codable, Sendable {
    /// The confidence level the requirements fix for reported intervals.
    public static let requiredConfidenceLevel = Decimal(sign: .plus, exponent: -2, significand: 95)

    public let statistic: BudgetPassStatistic
    public let intervalMethod: ConfidenceIntervalMethod
    public let confidenceLevel: UnitInterval

    public init(
        statistic: BudgetPassStatistic,
        intervalMethod: ConfidenceIntervalMethod,
        confidenceLevel: UnitInterval
    ) throws {
        guard confidenceLevel.value == Self.requiredConfidenceLevel else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "passRule.confidenceLevel",
                expected: "\(Self.requiredConfidenceLevel)",
                found: "\(confidenceLevel.value)"
            )
        }
        self.statistic = statistic
        self.intervalMethod = intervalMethod
        self.confidenceLevel = confidenceLevel
    }

    private enum CodingKeys: String, CodingKey {
        case statistic, intervalMethod, confidenceLevel
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                statistic: container.decode(BudgetPassStatistic.self, forKey: .statistic),
                intervalMethod: container.decode(
                    ConfidenceIntervalMethod.self,
                    forKey: .intervalMethod
                ),
                confidenceLevel: container.decode(UnitInterval.self, forKey: .confidenceLevel)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - Boundaries

/// One category-changing raw-logit boundary and its closed abstention band.
///
/// Requirement 5.7 fixes a minimum half-width of 0.131 raw-logit units, which comes
/// from measured FP16 drift; Requirement 5.8 makes the band closed. A boundary whose
/// two sides carry the same label is not category-changing and is rejected.
public struct CategoryBoundary: Hashable, Codable, Sendable {
    /// Minimum abstention half-width in raw-logit units (Requirement 5.7).
    public static let minimumAbstentionHalfWidth = 0.131

    public let rawLogitBoundary: Double
    public let abstentionHalfWidth: Double
    public let lowerDecision: PixelLabelKey
    public let upperDecision: PixelLabelKey

    public init(
        rawLogitBoundary: Double,
        abstentionHalfWidth: Double,
        lowerDecision: PixelLabelKey,
        upperDecision: PixelLabelKey
    ) throws {
        try ArtifactSchemaValidation.requireFinite(
            rawLogitBoundary,
            field: "boundary.rawLogitBoundary"
        )
        try ArtifactSchemaValidation.requireFinite(
            abstentionHalfWidth,
            field: "boundary.abstentionHalfWidth"
        )
        guard abstentionHalfWidth >= Self.minimumAbstentionHalfWidth else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "boundary.abstentionHalfWidth",
                value: "\(abstentionHalfWidth)",
                allowed: "at least \(Self.minimumAbstentionHalfWidth)"
            )
        }
        guard lowerDecision != upperDecision else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "boundary.upperDecision",
                value: upperDecision.rawValue,
                reason: "a category-changing boundary needs two different labels"
            )
        }
        self.rawLogitBoundary = rawLogitBoundary
        self.abstentionHalfWidth = abstentionHalfWidth
        self.lowerDecision = lowerDecision
        self.upperDecision = upperDecision
    }

    /// Inclusive lower edge of the abstention band.
    public var abstentionLowerBound: Double { rawLogitBoundary - abstentionHalfWidth }

    /// Inclusive upper edge of the abstention band.
    public var abstentionUpperBound: Double { rawLogitBoundary + abstentionHalfWidth }

    private enum CodingKeys: String, CodingKey {
        case rawLogitBoundary, abstentionHalfWidth, lowerDecision, upperDecision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                rawLogitBoundary: container.decode(Double.self, forKey: .rawLogitBoundary),
                abstentionHalfWidth: container.decode(Double.self, forKey: .abstentionHalfWidth),
                lowerDecision: container.decode(PixelLabelKey.self, forKey: .lowerDecision),
                upperDecision: container.decode(PixelLabelKey.self, forKey: .upperDecision)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - Quality rules

/// The condition an additional quality rule matches.
public enum QualityCondition: Hashable, Codable, Sendable {
    /// The required feature is absent from the Input Quality Record.
    case valueMissing
    /// The required feature is present but not usable.
    case valueInvalid
    /// The measured value is at or below the given threshold.
    case atOrBelow(Decimal)
    /// The measured value is at or above the given threshold.
    case atOrAbove(Decimal)
    /// The measured value is outside the given closed range.
    case outsideClosedRange(lower: Decimal, upper: Decimal)
}

/// What an additional quality rule produces when it matches.
///
/// Both outcomes are non-evidence with respect to authenticity: one abstains, the
/// other refuses to produce Pixel Evidence at all.
public enum QualityRuleOutcome: String, Codable, Sendable, Hashable, CaseIterable {
    /// Return the Insufficient Evidence Outcome (Requirement 5.24).
    case insufficientSignal = "insufficient-signal"
    /// Return the `calibration-input-error` Analysis Error (Requirement 5.25).
    case calibrationInputError = "calibration-input-error"
}

/// One deterministic additional quality rule.
///
/// Requirements 5.11 and 5.12: a rule that can produce abstention must name release
/// validation evidence, and a policy containing an unevidenced abstention rule is
/// rejected. The evidence list is therefore required to be nonempty for exactly
/// those rules.
public struct QualityDecisionRule: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let feature: QualityFeatureID
    public let condition: QualityCondition
    public let outcome: QualityRuleOutcome
    public let evidence: [EvidenceSource]

    public init(
        id: ArtifactID,
        feature: QualityFeatureID,
        condition: QualityCondition,
        outcome: QualityRuleOutcome,
        evidence: [EvidenceSource]
    ) throws {
        if outcome == .insufficientSignal {
            try ArtifactSchemaValidation.requireNonEmpty(evidence, field: "qualityRule.evidence")
        }
        if case let .outsideClosedRange(lower, upper) = condition, lower > upper {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "qualityRule.condition",
                value: "\(lower)...\(upper)",
                allowed: "a closed range whose lower bound does not exceed its upper bound"
            )
        }
        self.id = id
        self.feature = feature
        self.condition = condition
        self.outcome = outcome
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case id, feature, condition, outcome, evidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                feature: container.decode(QualityFeatureID.self, forKey: .feature),
                condition: container.decode(QualityCondition.self, forKey: .condition),
                outcome: container.decode(QualityRuleOutcome.self, forKey: .outcome),
                evidence: container.decode([EvidenceSource].self, forKey: .evidence)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// What happens when a required quality value is missing or invalid and no rule
/// explicitly covers the observed condition.
///
/// Requirement 5.25 fixes this to `calibration-input-error`. Abstention is
/// representable so that a policy claiming it can be rejected with a specific
/// message rather than being silently unrepresentable.
public enum UncoveredQualityInputBehavior: String, Codable, Sendable, Hashable, CaseIterable {
    case calibrationInputError = "calibration-input-error"
    case insufficientSignal = "insufficient-signal"
}

/// How the upstream checkpoint boundary is carried.
public enum UpstreamBoundaryRole: String, Codable, Sendable, Hashable, CaseIterable {
    /// Recorded for traceability only.
    case modelMetadataOnly = "model-metadata-only"
    /// Used as a product verdict boundary. Rejected by Requirement 5.14.
    case productDecisionBoundary = "product-decision-boundary"
}

/// The upstream Lowq raw-logit boundary, carried as metadata.
///
/// Requirement 5.14 requires the Model Bundle to record `1.390625` and to identify
/// it as model metadata rather than a product-verdict boundary.
public struct UpstreamBoundaryMetadata: Hashable, Codable, Sendable {
    /// The upstream value the requirements fix.
    public static let requiredValue = Decimal(sign: .plus, exponent: -6, significand: 1_390_625)

    public let rawLogitValue: Decimal
    public let role: UpstreamBoundaryRole

    public init(rawLogitValue: Decimal, role: UpstreamBoundaryRole) throws {
        guard rawLogitValue == Self.requiredValue else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "upstreamBoundaryMetadata.rawLogitValue",
                expected: "\(Self.requiredValue)",
                found: "\(rawLogitValue)"
            )
        }
        guard role == .modelMetadataOnly else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "upstreamBoundaryMetadata.role",
                value: role.rawValue,
                reason: "the upstream boundary is metadata, not a product verdict boundary"
            )
        }
        self.rawLogitValue = rawLogitValue
        self.role = role
    }

    private enum CodingKeys: String, CodingKey {
        case rawLogitValue, role
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                rawLogitValue: container.decode(Decimal.self, forKey: .rawLogitValue),
                role: container.decode(UpstreamBoundaryRole.self, forKey: .role)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - Label and metric-category binding

/// One label and the metric category it contributes to.
public struct MetricCategoryAssignment: Hashable, Codable, Sendable {
    public let label: PixelLabelKey
    public let category: PixelMetricCategory

    public init(label: PixelLabelKey, category: PixelMetricCategory) {
        self.label = label
        self.category = category
    }
}

// MARK: - Policy

/// The versioned policy that turns a finite logit and a quality record into exactly
/// one of the three fixed labels, or into `calibration-input-error`.
public struct CalibrationPolicy: Hashable, Codable, Sendable {
    /// Short-edge length at or above which pixel evidence may be produced.
    ///
    /// Requirement 5.9 makes short edges 1 through 439 abstain, so the minimum is
    /// exactly 440 for Version 1.
    public static let requiredMinimumShortEdge = 440

    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// The exact model identity this policy was calibrated against.
    public let compatibleModel: ModelIdentity

    /// The Preprocessing Contract version this policy was calibrated against.
    public let compatiblePreprocessing: ArtifactID

    /// The Approved Verdict Copy compatibility record this policy expects.
    public let compatibleVerdictCopy: ArtifactID

    public let falseAccusationBudget: FalseAccusationBudget
    public let releasePassRule: FalseAccusationPassRule

    /// Exactly the three fixed labels (Requirement 5.2).
    public let outputLabels: Set<PixelLabelKey>

    /// The metric category of each label (Requirement 5.3).
    public let metricCategories: [MetricCategoryAssignment]

    public let boundaries: [CategoryBoundary]

    /// Fixed to ``requiredMinimumShortEdge``.
    public let minimumShortEdge: Int

    /// The label returned for a short edge below the minimum (Requirement 5.9).
    public let belowMinimumShortEdgeLabel: PixelLabelKey

    public let requiredQualityFeatures: Set<QualityFeatureID>
    public let qualityRules: [QualityDecisionRule]
    public let uncoveredQualityInputBehavior: UncoveredQualityInputBehavior

    /// Held-out calibration evidence this policy was derived from (Requirement 5.6).
    public let evidence: [EvidenceSource]

    public let upstreamBoundaryMetadata: UpstreamBoundaryMetadata

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        compatibleModel: ModelIdentity,
        compatiblePreprocessing: ArtifactID,
        compatibleVerdictCopy: ArtifactID,
        falseAccusationBudget: FalseAccusationBudget,
        releasePassRule: FalseAccusationPassRule,
        outputLabels: Set<PixelLabelKey>,
        metricCategories: [MetricCategoryAssignment],
        boundaries: [CategoryBoundary],
        minimumShortEdge: Int,
        belowMinimumShortEdgeLabel: PixelLabelKey,
        requiredQualityFeatures: Set<QualityFeatureID>,
        qualityRules: [QualityDecisionRule],
        uncoveredQualityInputBehavior: UncoveredQualityInputBehavior,
        evidence: [EvidenceSource],
        upstreamBoundaryMetadata: UpstreamBoundaryMetadata
    ) throws {
        guard outputLabels == Set(PixelLabelKey.allCases) else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "outputLabels",
                expected: "\(PixelLabelKey.allCases.map(\.rawValue).sorted())",
                found: "\(outputLabels.map(\.rawValue).sorted())"
            )
        }
        try ArtifactSchemaValidation.requireExactCoverage(
            metricCategories.map(\.label.rawValue),
            required: Set(PixelLabelKey.allCases.map(\.rawValue)),
            field: "metricCategories"
        )
        for assignment in metricCategories {
            guard assignment.category == assignment.label.requiredMetricCategory else {
                throw ArtifactSchemaError.fixedValueMismatch(
                    field: "metricCategories[\(assignment.label.rawValue)]",
                    expected: assignment.label.requiredMetricCategory.rawValue,
                    found: assignment.category.rawValue
                )
            }
        }
        try ArtifactSchemaValidation.requireNonEmpty(boundaries, field: "boundaries")
        guard minimumShortEdge == Self.requiredMinimumShortEdge else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "minimumShortEdge",
                expected: "\(Self.requiredMinimumShortEdge)",
                found: "\(minimumShortEdge)"
            )
        }
        guard belowMinimumShortEdgeLabel == .notEnoughSignal else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "belowMinimumShortEdgeLabel",
                value: belowMinimumShortEdgeLabel.rawValue,
                reason: "short edges 1 through 439 must return the insufficient outcome"
            )
        }
        guard uncoveredQualityInputBehavior == .calibrationInputError else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "uncoveredQualityInputBehavior",
                value: uncoveredQualityInputBehavior.rawValue,
                reason: "an uncovered missing or invalid required value cannot silently abstain"
            )
        }
        try ArtifactSchemaValidation.requireUniqueKeys(
            qualityRules.map(\.id.rawValue),
            field: "qualityRules"
        )
        for rule in qualityRules where !requiredQualityFeatures.contains(rule.feature) {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: "requiredQualityFeatures",
                keys: [rule.feature.rawValue]
            )
        }
        try ArtifactSchemaValidation.requireNonEmpty(evidence, field: "evidence")

        self.id = id
        self.schemaVersion = schemaVersion
        self.compatibleModel = compatibleModel
        self.compatiblePreprocessing = compatiblePreprocessing
        self.compatibleVerdictCopy = compatibleVerdictCopy
        self.falseAccusationBudget = falseAccusationBudget
        self.releasePassRule = releasePassRule
        self.outputLabels = outputLabels
        self.metricCategories = metricCategories
        self.boundaries = boundaries
        self.minimumShortEdge = minimumShortEdge
        self.belowMinimumShortEdgeLabel = belowMinimumShortEdgeLabel
        self.requiredQualityFeatures = requiredQualityFeatures
        self.qualityRules = qualityRules
        self.uncoveredQualityInputBehavior = uncoveredQualityInputBehavior
        self.evidence = evidence
        self.upstreamBoundaryMetadata = upstreamBoundaryMetadata
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, compatibleModel, compatiblePreprocessing, compatibleVerdictCopy
        case falseAccusationBudget, releasePassRule, outputLabels, metricCategories, boundaries
        case minimumShortEdge, belowMinimumShortEdgeLabel, requiredQualityFeatures, qualityRules
        case uncoveredQualityInputBehavior, evidence, upstreamBoundaryMetadata
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                compatibleModel: container.decode(ModelIdentity.self, forKey: .compatibleModel),
                compatiblePreprocessing: container.decode(
                    ArtifactID.self,
                    forKey: .compatiblePreprocessing
                ),
                compatibleVerdictCopy: container.decode(
                    ArtifactID.self,
                    forKey: .compatibleVerdictCopy
                ),
                falseAccusationBudget: container.decode(
                    FalseAccusationBudget.self,
                    forKey: .falseAccusationBudget
                ),
                releasePassRule: container.decode(
                    FalseAccusationPassRule.self,
                    forKey: .releasePassRule
                ),
                outputLabels: container.decode(Set<PixelLabelKey>.self, forKey: .outputLabels),
                metricCategories: container.decode(
                    [MetricCategoryAssignment].self,
                    forKey: .metricCategories
                ),
                boundaries: container.decode([CategoryBoundary].self, forKey: .boundaries),
                minimumShortEdge: container.decode(Int.self, forKey: .minimumShortEdge),
                belowMinimumShortEdgeLabel: container.decode(
                    PixelLabelKey.self,
                    forKey: .belowMinimumShortEdgeLabel
                ),
                requiredQualityFeatures: container.decode(
                    Set<QualityFeatureID>.self,
                    forKey: .requiredQualityFeatures
                ),
                qualityRules: container.decode([QualityDecisionRule].self, forKey: .qualityRules),
                uncoveredQualityInputBehavior: container.decode(
                    UncoveredQualityInputBehavior.self,
                    forKey: .uncoveredQualityInputBehavior
                ),
                evidence: container.decode([EvidenceSource].self, forKey: .evidence),
                upstreamBoundaryMetadata: container.decode(
                    UpstreamBoundaryMetadata.self,
                    forKey: .upstreamBoundaryMetadata
                )
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}
