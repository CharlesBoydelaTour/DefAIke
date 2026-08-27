import Foundation

// Predeclared release-gating slices and the results measured against them.
//
// Requirement 5.15 requires every slice, eligibility rule, outcome mapping, interval
// method, and pass rule to be predeclared before evaluation begins, and Requirements
// 5.16 through 5.19 fix how the rates are computed and what must be reported. The
// separation of training, calibration, and evaluation populations (Requirements 5.5
// and 5.23) is a recorded verification result, never an assumption.
//
// No threshold, budget, or interval method is chosen here, and no result is derived
// here. These are the record shapes the release evaluator fills and the calibration
// approval gate reads.

// MARK: - Slice specification

/// A predeclared mandatory Release Gating Slice.
///
/// `isContemporaryPhoneCameraSlice` marks the dedicated contamination-controlled
/// contemporary phone-camera real-image slice that Requirement 5.20 makes mandatory,
/// so the approval gate can require its presence rather than infer it from a name.
public struct ReleaseGatingSliceSpecification: Hashable, Codable, Sendable {
    public let id: ReleaseSliceID
    public let schemaVersion: ArtifactSchemaVersion

    /// The predeclared eligibility rule for membership in this slice.
    public let eligibilityRule: EvidenceSource

    /// The predeclared mapping from model outcome to metric category.
    public let outcomeMapping: EvidenceSource

    /// The predeclared metric definitions this slice reports.
    public let metricDefinition: EvidenceSource

    /// The dataset composition record for this slice.
    public let datasetComposition: EvidenceSource

    /// The degradation condition applied to this slice.
    public let degradationCondition: EvidenceSource

    /// The predeclared interval method and level.
    public let intervalMethod: ConfidenceIntervalMethod
    public let confidenceLevel: UnitInterval

    /// Whether this is the mandatory contemporary phone-camera real slice.
    public let isContemporaryPhoneCameraSlice: Bool

    public init(
        id: ReleaseSliceID,
        schemaVersion: ArtifactSchemaVersion,
        eligibilityRule: EvidenceSource,
        outcomeMapping: EvidenceSource,
        metricDefinition: EvidenceSource,
        datasetComposition: EvidenceSource,
        degradationCondition: EvidenceSource,
        intervalMethod: ConfidenceIntervalMethod,
        confidenceLevel: UnitInterval,
        isContemporaryPhoneCameraSlice: Bool
    ) throws {
        guard confidenceLevel.value == FalseAccusationPassRule.requiredConfidenceLevel else {
            throw ArtifactSchemaError.fixedValueMismatch(
                field: "slice.confidenceLevel",
                expected: "\(FalseAccusationPassRule.requiredConfidenceLevel)",
                found: "\(confidenceLevel.value)"
            )
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.eligibilityRule = eligibilityRule
        self.outcomeMapping = outcomeMapping
        self.metricDefinition = metricDefinition
        self.datasetComposition = datasetComposition
        self.degradationCondition = degradationCondition
        self.intervalMethod = intervalMethod
        self.confidenceLevel = confidenceLevel
        self.isContemporaryPhoneCameraSlice = isContemporaryPhoneCameraSlice
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, eligibilityRule, outcomeMapping, metricDefinition
        case datasetComposition, degradationCondition, intervalMethod, confidenceLevel
        case isContemporaryPhoneCameraSlice
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ReleaseSliceID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                eligibilityRule: container.decode(EvidenceSource.self, forKey: .eligibilityRule),
                outcomeMapping: container.decode(EvidenceSource.self, forKey: .outcomeMapping),
                metricDefinition: container.decode(EvidenceSource.self, forKey: .metricDefinition),
                datasetComposition: container.decode(
                    EvidenceSource.self,
                    forKey: .datasetComposition
                ),
                degradationCondition: container.decode(
                    EvidenceSource.self,
                    forKey: .degradationCondition
                ),
                intervalMethod: container.decode(
                    ConfidenceIntervalMethod.self,
                    forKey: .intervalMethod
                ),
                confidenceLevel: container.decode(UnitInterval.self, forKey: .confidenceLevel),
                isContemporaryPhoneCameraSlice: container.decode(
                    Bool.self,
                    forKey: .isContemporaryPhoneCameraSlice
                )
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - Measured outcomes

/// Label counts for one slice, split by ground-truth population.
///
/// Insufficient counts are recorded separately and stay inside the rate
/// denominators, which is what makes abstention honest rather than free
/// (Requirements 5.16 through 5.18).
public struct SliceOutcomeCounts: Hashable, Codable, Sendable {
    public let eligibleRealImages: NonNegativeCount
    public let eligibleSyntheticImages: NonNegativeCount
    public let realPositiveLabels: NonNegativeCount
    public let realNonPositiveLabels: NonNegativeCount
    public let realInsufficientLabels: NonNegativeCount
    public let syntheticPositiveLabels: NonNegativeCount
    public let syntheticNonPositiveLabels: NonNegativeCount
    public let syntheticInsufficientLabels: NonNegativeCount

    /// Analysis Errors encountered while evaluating the slice (Requirement 5.19).
    public let errorCount: NonNegativeCount

    public init(
        eligibleRealImages: NonNegativeCount,
        eligibleSyntheticImages: NonNegativeCount,
        realPositiveLabels: NonNegativeCount,
        realNonPositiveLabels: NonNegativeCount,
        realInsufficientLabels: NonNegativeCount,
        syntheticPositiveLabels: NonNegativeCount,
        syntheticNonPositiveLabels: NonNegativeCount,
        syntheticInsufficientLabels: NonNegativeCount,
        errorCount: NonNegativeCount
    ) throws {
        let realTotal = realPositiveLabels.value + realNonPositiveLabels.value
            + realInsufficientLabels.value
        guard realTotal == eligibleRealImages.value else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "sliceCounts.realLabels",
                expected: "\(eligibleRealImages.value) eligible real images",
                found: "\(realTotal) labelled"
            )
        }
        let syntheticTotal = syntheticPositiveLabels.value + syntheticNonPositiveLabels.value
            + syntheticInsufficientLabels.value
        guard syntheticTotal == eligibleSyntheticImages.value else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "sliceCounts.syntheticLabels",
                expected: "\(eligibleSyntheticImages.value) eligible synthetic images",
                found: "\(syntheticTotal) labelled"
            )
        }
        self.eligibleRealImages = eligibleRealImages
        self.eligibleSyntheticImages = eligibleSyntheticImages
        self.realPositiveLabels = realPositiveLabels
        self.realNonPositiveLabels = realNonPositiveLabels
        self.realInsufficientLabels = realInsufficientLabels
        self.syntheticPositiveLabels = syntheticPositiveLabels
        self.syntheticNonPositiveLabels = syntheticNonPositiveLabels
        self.syntheticInsufficientLabels = syntheticInsufficientLabels
        self.errorCount = errorCount
    }

    private enum CodingKeys: String, CodingKey {
        case eligibleRealImages, eligibleSyntheticImages, realPositiveLabels
        case realNonPositiveLabels, realInsufficientLabels, syntheticPositiveLabels
        case syntheticNonPositiveLabels, syntheticInsufficientLabels, errorCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                eligibleRealImages: container.decode(
                    NonNegativeCount.self,
                    forKey: .eligibleRealImages
                ),
                eligibleSyntheticImages: container.decode(
                    NonNegativeCount.self,
                    forKey: .eligibleSyntheticImages
                ),
                realPositiveLabels: container.decode(
                    NonNegativeCount.self,
                    forKey: .realPositiveLabels
                ),
                realNonPositiveLabels: container.decode(
                    NonNegativeCount.self,
                    forKey: .realNonPositiveLabels
                ),
                realInsufficientLabels: container.decode(
                    NonNegativeCount.self,
                    forKey: .realInsufficientLabels
                ),
                syntheticPositiveLabels: container.decode(
                    NonNegativeCount.self,
                    forKey: .syntheticPositiveLabels
                ),
                syntheticNonPositiveLabels: container.decode(
                    NonNegativeCount.self,
                    forKey: .syntheticNonPositiveLabels
                ),
                syntheticInsufficientLabels: container.decode(
                    NonNegativeCount.self,
                    forKey: .syntheticInsufficientLabels
                ),
                errorCount: container.decode(NonNegativeCount.self, forKey: .errorCount)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// One computed interval on a measured rate.
///
/// The method is carried with the interval so a reader can see that the reported
/// interval used the predeclared method rather than one selected afterwards.
public struct ConfidenceIntervalResult: Hashable, Codable, Sendable {
    public let method: ConfidenceIntervalMethod
    public let confidenceLevel: UnitInterval
    public let lowerBound: UnitInterval
    public let upperBound: UnitInterval

    public init(
        method: ConfidenceIntervalMethod,
        confidenceLevel: UnitInterval,
        lowerBound: UnitInterval,
        upperBound: UnitInterval
    ) throws {
        guard lowerBound <= upperBound else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "interval",
                value: "\(lowerBound.value)...\(upperBound.value)",
                allowed: "a lower bound no greater than the upper bound"
            )
        }
        self.method = method
        self.confidenceLevel = confidenceLevel
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    private enum CodingKeys: String, CodingKey {
        case method, confidenceLevel, lowerBound, upperBound
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                method: container.decode(ConfidenceIntervalMethod.self, forKey: .method),
                confidenceLevel: container.decode(UnitInterval.self, forKey: .confidenceLevel),
                lowerBound: container.decode(UnitInterval.self, forKey: .lowerBound),
                upperBound: container.decode(UnitInterval.self, forKey: .upperBound)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// The measured result for one mandatory slice.
public struct CalibrationSliceResult: Hashable, Codable, Sendable {
    public let slice: ReleaseSliceID
    public let specification: EvidenceSource
    public let modelBundle: ModelBundleID
    public let calibrationPolicy: ArtifactID
    public let counts: SliceOutcomeCounts

    public let falsePositiveRate: UnitInterval
    public let truePositiveRate: UnitInterval
    public let coverage: UnitInterval
    public let falsePositiveRateInterval: ConfidenceIntervalResult

    /// The recorded pass or fail result for the budget rule on this slice.
    public let budgetOutcome: GateOutcome

    public init(
        slice: ReleaseSliceID,
        specification: EvidenceSource,
        modelBundle: ModelBundleID,
        calibrationPolicy: ArtifactID,
        counts: SliceOutcomeCounts,
        falsePositiveRate: UnitInterval,
        truePositiveRate: UnitInterval,
        coverage: UnitInterval,
        falsePositiveRateInterval: ConfidenceIntervalResult,
        budgetOutcome: GateOutcome
    ) {
        self.slice = slice
        self.specification = specification
        self.modelBundle = modelBundle
        self.calibrationPolicy = calibrationPolicy
        self.counts = counts
        self.falsePositiveRate = falsePositiveRate
        self.truePositiveRate = truePositiveRate
        self.coverage = coverage
        self.falsePositiveRateInterval = falsePositiveRateInterval
        self.budgetOutcome = budgetOutcome
    }
}

// MARK: - Population separation

/// The three populations that must stay separated (Requirement 5.5).
public enum CalibrationPopulation: String, Codable, Sendable, Hashable, CaseIterable {
    case knownModelTraining = "known-model-training"
    case heldOutCalibration = "held-out-calibration"
    case productThresholdEvaluation = "product-threshold-evaluation"
}

/// The verified separation result between two populations.
///
/// Requirements 5.5 and 5.23 require both sample-level and content-level separation,
/// verified rather than assumed, with a failure rejecting the policy. Both outcomes
/// are recorded so a contaminated pair is auditable instead of absent.
public struct PopulationSeparationResult: Hashable, Codable, Sendable {
    public let firstPopulation: CalibrationPopulation
    public let secondPopulation: CalibrationPopulation
    public let sampleLevelOutcome: GateOutcome
    public let contentLevelOutcome: GateOutcome
    public let evidence: EvidenceSource

    public init(
        firstPopulation: CalibrationPopulation,
        secondPopulation: CalibrationPopulation,
        sampleLevelOutcome: GateOutcome,
        contentLevelOutcome: GateOutcome,
        evidence: EvidenceSource
    ) throws {
        guard firstPopulation != secondPopulation else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "separation.secondPopulation",
                value: secondPopulation.rawValue,
                reason: "separation is recorded between two different populations"
            )
        }
        self.firstPopulation = firstPopulation
        self.secondPopulation = secondPopulation
        self.sampleLevelOutcome = sampleLevelOutcome
        self.contentLevelOutcome = contentLevelOutcome
        self.evidence = evidence
    }

    /// Whether both levels of separation passed for this pair.
    public var isSeparated: Bool {
        sampleLevelOutcome.isPassing && contentLevelOutcome.isPassing
    }

    private enum CodingKeys: String, CodingKey {
        case firstPopulation, secondPopulation, sampleLevelOutcome, contentLevelOutcome, evidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                firstPopulation: container.decode(
                    CalibrationPopulation.self,
                    forKey: .firstPopulation
                ),
                secondPopulation: container.decode(
                    CalibrationPopulation.self,
                    forKey: .secondPopulation
                ),
                sampleLevelOutcome: container.decode(GateOutcome.self, forKey: .sampleLevelOutcome),
                contentLevelOutcome: container.decode(
                    GateOutcome.self,
                    forKey: .contentLevelOutcome
                ),
                evidence: container.decode(EvidenceSource.self, forKey: .evidence)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// The dataset lineage record a calibration approval reads.
public struct DatasetLineageRecord: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion
    public let separationResults: [PopulationSeparationResult]

    /// Corrected corpus identifier evidence (Requirement 14.7).
    public let identifierCorrection: EvidenceSource

    /// Duplicate content-hash disposition record (Requirement 14.8).
    public let duplicateHashDisposition: EvidenceSource

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        separationResults: [PopulationSeparationResult],
        identifierCorrection: EvidenceSource,
        duplicateHashDisposition: EvidenceSource
    ) throws {
        try ArtifactSchemaValidation.requireNonEmpty(
            separationResults,
            field: "separationResults"
        )
        self.id = id
        self.schemaVersion = schemaVersion
        self.separationResults = separationResults
        self.identifierCorrection = identifierCorrection
        self.duplicateHashDisposition = duplicateHashDisposition
    }

    /// The unordered population pairs this record covers.
    public var coveredPairs: Set<Set<CalibrationPopulation>> {
        Set(separationResults.map { Set([$0.firstPopulation, $0.secondPopulation]) })
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, separationResults, identifierCorrection, duplicateHashDisposition
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                separationResults: container.decode(
                    [PopulationSeparationResult].self,
                    forKey: .separationResults
                ),
                identifierCorrection: container.decode(
                    EvidenceSource.self,
                    forKey: .identifierCorrection
                ),
                duplicateHashDisposition: container.decode(
                    EvidenceSource.self,
                    forKey: .duplicateHashDisposition
                )
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}
