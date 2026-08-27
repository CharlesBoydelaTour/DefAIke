import DefAIkeDomain
import DefAIkeTestSupport
import Foundation

/// Structurally valid, deliberately synthetic policy values the doubles need as arguments.
///
/// **No number, action, boundary, mapping, or limit here is an approved release value.**
/// Every one of them is an unresolved external decision; these fixtures exist only so a
/// port that takes a policy can be called at all. Nothing here may be copied into a
/// shipping artifact, and no test asserts that a value here is correct — the artifact
/// schema tests do that against the schema, and release validation does it against
/// approved records.
enum PreprocessingFixture {
    static func contract(id: String = "preprocessing-0001") -> PreprocessingContract {
        do {
            return try PreprocessingContract(
                id: PortValue.artifactID(id),
                schemaVersion: .v1,
                supportedContainers: Set(StaticContainer.allCases),
                orientationRules: MetadataStateRules(
                    rules: ImageMetadataState.allCases.map {
                        .init(state: $0, action: .applyDeclaredOrientation)
                    }
                ),
                colorProfileRules: MetadataStateRules(
                    rules: ImageMetadataState.allCases.map {
                        .init(state: $0, action: .convertToWorkingSpace)
                    }
                ),
                alphaRules: MetadataStateRules(
                    rules: ImageMetadataState.allCases.map {
                        .init(state: $0, action: .discardAlphaChannel)
                    }
                ),
                rgbWorkingSpace: ColorSpaceDescriptor(
                    identifier: try ArtifactText(validating: "Fixture RGB working space"),
                    profileDigest: nil
                ),
                resize: try ResizeContract(
                    interpolation: .bilinear,
                    targetShortEdge: ResizeContract.requiredShortEdge,
                    rounding: .halfUp,
                    edgeRule: .clampToEdge,
                    pixelCenterConvention: .halfPixelCenters
                ),
                crop: try CenterCropContract(
                    width: CenterCropContract.requiredEdge,
                    height: CenterCropContract.requiredEdge,
                    offsetRule: .floorHalfDifference
                ),
                modelInput: try ModelInputContract(
                    featureName: try ArtifactText(validating: "image"),
                    width: CenterCropContract.requiredEdge,
                    height: CenterCropContract.requiredEdge,
                    channelOrder: .rgb,
                    elementType: .uint8,
                    appliesAppSideNormalization: false
                )
            )
        } catch {
            preconditionFailure("the preprocessing fixture must be schema-valid: \(error)")
        }
    }

    static func modelOutputContract() -> ModelOutputContract {
        do {
            return try ModelOutputContract(
                featureName: try ArtifactText(
                    validating: ModelOutputContract.requiredFeatureName
                ),
                elementType: .float32,
                isPositiveGoing: true
            )
        } catch {
            preconditionFailure("the model output fixture must be schema-valid: \(error)")
        }
    }
}

/// Structurally valid resource budgets. Not approved limits: see the note above.
enum ResourceFixture {
    static func budget(
        for target: ExecutionTarget,
        id: String? = nil,
        limitValue: Decimal = 1_000_000
    ) -> ResourceBudget {
        do {
            return try ResourceBudget(
                id: PortValue.artifactID(id ?? "budget-\(target.rawValue)"),
                schemaVersion: .v1,
                target: target,
                hardLimits: try ResourceMetric.requiredMetrics(for: target).map { metric in
                    try ResourceLimitEntry(
                        metric: metric,
                        limit: metric.isCategorical
                            ? .thermal(maximumState: .fair)
                            : .numeric(value: positive(limitValue), unit: unit(for: metric)),
                        measurementConditions: LifecycleFixture.evidence(
                            "measurement-\(metric.rawValue)"
                        )
                    )
                },
                validationPlan: PortValue.artifactID("validation-plan-0001")
            )
        } catch {
            preconditionFailure("the resource budget fixture must be schema-valid: \(error)")
        }
    }

    static func budgetSet() -> ResourceBudgetSet {
        do {
            return try ResourceBudgetSet(
                mainApplication: budget(for: .mainApplication),
                shareExtension: budget(for: .shareExtension)
            )
        } catch {
            preconditionFailure("the budget set fixture must be schema-valid: \(error)")
        }
    }

    static func positive(_ value: Decimal) -> PositiveDecimal {
        do {
            return try PositiveDecimal(validating: value)
        } catch {
            preconditionFailure("\(value) is not a positive decimal: \(error)")
        }
    }

    /// A unit that matches each metric's dimension.
    ///
    /// Only the pairing has to be coherent for a fixture; which number belongs there is a
    /// measured release decision.
    static func unit(for metric: ResourceMetric) -> ResourceLimitUnit {
        switch metric {
        case .decodedPixelCount: .pixels
        case .encodedInputSize, .peakResidentMemory, .temporaryStorage: .bytes
        case .coldModelLoadTime, .warmAnalysisLatency, .handoffLatency: .milliseconds
        case .energyImpact: .milliwattHours
        case .thermalState: .milliseconds
        }
    }
}

/// A structurally valid Provenance Policy. Not an approved trust policy: see the note
/// above. In particular the trust store, revocation behavior, and status mapping here are
/// placeholders for schema shape, and the Provenance Feasibility Gate has not passed.
enum ProvenanceFixture {
    static func policy(id: String = "provenance-0001") -> ProvenancePolicy {
        do {
            return try ProvenancePolicy(
                id: PortValue.artifactID(id),
                schemaVersion: .v1,
                capability: .contentCredentialValidation,
                validatorImplementationVersion: try SchemaSemanticVersion(validating: "0.0.12"),
                validatorBinaryDigest: TestSHA256.digest(ofUTF8: "fixture-validator"),
                supportedSpecification: LifecycleFixture.evidence("c2pa-specification"),
                trustStore: try ProvenanceTrustStoreDescriptor(
                    store: LifecycleFixture.evidence("trust-store"),
                    anchorCount: try PositiveCount(validating: 1),
                    isOfflineOnly: true
                ),
                revocationBehavior: try ProvenanceRevocationBehavior(
                    permitsNetworkRevocationCheck: false,
                    unavailableAnswerState: .indeterminate,
                    approval: LifecycleFixture.approval()
                ),
                supportedAssertionLabels: [try ArtifactText(validating: "c2pa.actions")],
                displayableFields: [.signerIdentity],
                processingLimits: ProvenanceProcessingLimits(
                    maximumManifestByteCount: try PositiveByteCount(validating: 65_536),
                    maximumAssertionCount: try PositiveCount(validating: 32),
                    maximumNestingDepth: try PositiveCount(validating: 4),
                    maximumProcessingDuration: LifecycleFixture.duration(5_000)
                ),
                resourceBudget: PortValue.artifactID("budget-main-application"),
                statusMappings: [
                    ProvenanceStatusMapping(
                        status: validatorStatus("status.signature-valid"),
                        state: .validated
                    )
                ],
                feasibilityApproval: LifecycleFixture.approval()
            )
        } catch {
            preconditionFailure("the provenance policy fixture must be schema-valid: \(error)")
        }
    }

    static func validatorStatus(_ raw: String) -> ProvenanceValidatorStatusID {
        guard let id = ProvenanceValidatorStatusID(raw) else {
            preconditionFailure("validator status identifier is not canonical: \(raw)")
        }
        return id
    }
}

/// A structurally valid Calibration Policy, so a calibration double can be called.
///
/// **The boundary, half-width, budget, and pass rule here are not approved values.**
/// They are the smallest numbers the schema accepts. The real boundary and budget are
/// unresolved release decisions backed by held-out evidence, and the calibration
/// boundary and metric tests in tasks 7.5 through 7.9 assert against approved policies
/// rather than against this fixture.
enum CalibrationFixture {
    static func policy(id: String = "calibration-0001") -> CalibrationPolicy {
        do {
            return try CalibrationPolicy(
                id: PortValue.artifactID(id),
                schemaVersion: .v1,
                compatibleModel: RequiredPixelModel.identity,
                compatiblePreprocessing: PortValue.artifactID("preprocessing-0001"),
                compatibleVerdictCopy: PortValue.artifactID("copy-0001"),
                falseAccusationBudget: try FalseAccusationBudget(
                    validating: Decimal(sign: .plus, exponent: -3, significand: 5)
                ),
                releasePassRule: try FalseAccusationPassRule(
                    statistic: .observedRateAndIntervalUpperBound,
                    intervalMethod: .wilsonScore,
                    confidenceLevel: try UnitInterval(
                        validating: FalseAccusationPassRule.requiredConfidenceLevel
                    )
                ),
                outputLabels: Set(PixelLabelKey.allCases),
                metricCategories: PixelLabelKey.allCases.map {
                    MetricCategoryAssignment(label: $0, category: $0.requiredMetricCategory)
                },
                boundaries: [
                    try CategoryBoundary(
                        rawLogitBoundary: 0,
                        abstentionHalfWidth: CategoryBoundary.minimumAbstentionHalfWidth,
                        lowerDecision: .noStrongSignalDetected,
                        upperDecision: .signalsConsistentWithAIGeneration
                    )
                ],
                minimumShortEdge: CalibrationPolicy.requiredMinimumShortEdge,
                belowMinimumShortEdgeLabel: .notEnoughSignal,
                requiredQualityFeatures: [],
                qualityRules: [],
                uncoveredQualityInputBehavior: .calibrationInputError,
                evidence: [LifecycleFixture.evidence("calibration-evidence")],
                upstreamBoundaryMetadata: BundleFixture.upstreamMetadata()
            )
        } catch {
            preconditionFailure("the calibration policy fixture must be schema-valid: \(error)")
        }
    }
}
