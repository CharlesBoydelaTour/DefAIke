import Foundation
import Testing

@testable import DefAIkeDomain

// Schema tests for the versioned policy and release artifacts.
//
// The shape of every test is the same: build a structurally valid sample, mutate exactly
// one field, and assert the schema refuses the mutation. That is the property these
// schemas exist to have, because a release artifact that can hold a placeholder, an
// incomplete map, or an unexplained "not applicable" is an artifact that can quietly
// approve something nobody decided.

@Suite("Artifact schema primitives")
struct ArtifactSchemaPrimitiveTests {
    @Test("A placeholder token is not a decided value")
    func placeholderRejected() {
        for token in ["TBD", "todo", "  n/a  ".trimmingCharacters(in: .whitespaces), "PLACEHOLDER"] {
            #expect(throws: ArtifactSchemaError.self) {
                try ArtifactSchemaValidation.requireDecidedValue(token, field: "sample")
            }
        }
    }

    @Test("Empty and padded values are rejected")
    func emptyAndPaddedRejected() {
        #expect(throws: ArtifactSchemaError.emptyValue(field: "sample")) {
            try ArtifactSchemaValidation.requireDecidedValue("", field: "sample")
        }
        #expect(throws: ArtifactSchemaError.noncanonicalValue(field: "sample", value: " x ")) {
            try ArtifactSchemaValidation.requireDecidedValue(" x ", field: "sample")
        }
    }

    @Test("An identifier holding a placeholder is not a decided reference")
    func placeholderReferenceRejected() {
        #expect(throws: ArtifactSchemaError.self) {
            try ArtifactSchemaValidation.requireDecidedReference(
                Sample.artifact("tbd"),
                field: "policy"
            )
        }
        #expect(throws: Never.self) {
            try ArtifactSchemaValidation.requireDecidedReference(
                Sample.artifact(),
                field: "policy"
            )
        }
    }

    @Test("Schema versions are positive and no greater than the supported maximum")
    func schemaVersionBounds() throws {
        #expect(try ArtifactSchemaVersion(validating: 1) == .v1)
        #expect(throws: ArtifactSchemaError.self) { try ArtifactSchemaVersion(validating: 0) }
        #expect(throws: ArtifactSchemaError.self) {
            try ArtifactSchemaVersion(validating: ArtifactSchemaVersion.maximumSupported + 1)
        }
    }

    @Test("Semantic versions are canonical and never all zero")
    func semanticVersionForm() throws {
        let version = try SchemaSemanticVersion(validating: "1.2.3")
        #expect(version.rawSchemaValue == "1.2.3")
        #expect(try version > SchemaSemanticVersion(validating: "1.2.2"))
        for malformed in ["0.0.0", "1.2", "1.02.0", "v1.2.3", "1.2.3.4", "1.2.-1"] {
            #expect(throws: ArtifactSchemaError.self) {
                try SchemaSemanticVersion(validating: malformed)
            }
        }
    }

    @Test("Platform versions compare and expose the iOS 17 minimum")
    func platformVersionComparison() throws {
        #expect(PlatformVersion.iOS17.description == "17.0.0")
        #expect(try PlatformVersion(validating: "17.4.1") > .iOS17)
        #expect(try PlatformVersion(validating: "16.7.0") < .iOS17)
        #expect(PlatformVersion.iOS17.majorVersion == 17)
    }

    @Test("A deadline is positive, bounded, and converts exactly")
    func durationBounds() throws {
        let deadline = try ValidatedDuration(validating: 30_000)
        #expect(deadline.duration == .seconds(30))
        #expect(throws: ArtifactSchemaError.self) { try ValidatedDuration(validating: 0) }
        #expect(throws: ArtifactSchemaError.self) {
            try ValidatedDuration(validating: ValidatedDuration.maximumMilliseconds + 1)
        }
    }

    @Test("Bounded counts, budgets, and ratios reject unusable values")
    func numericBounds() {
        #expect(throws: ArtifactSchemaError.self) { try PositiveCount(validating: 0) }
        #expect(throws: ArtifactSchemaError.self) { try PositiveByteCount(validating: 0) }
        #expect(throws: ArtifactSchemaError.self) { try PositiveDecimal(validating: 0) }
        #expect(throws: ArtifactSchemaError.self) { try NonNegativeCount(validating: -1) }
        #expect(throws: ArtifactSchemaError.self) { try UnitInterval(validating: Decimal(2)) }
        #expect(throws: ArtifactSchemaError.self) { try UnitInterval(validating: Decimal(-1)) }
    }

    @Test("Bounded text rejects control characters and overlong values")
    func textBounds() {
        #expect(throws: ArtifactSchemaError.self) {
            try ArtifactText(validating: "line\nbreak")
        }
        #expect(throws: ArtifactSchemaError.self) {
            try ArtifactText(validating: String(repeating: "x", count: 257))
        }
    }

    @Test("A scalar decodes through the same validation as construction")
    func scalarDecodingValidates() throws {
        let encoded = Data(#""0.0.0""#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SchemaSemanticVersion.self, from: encoded)
        }
        let valid = Data(#""2.1.0""#.utf8)
        #expect(try JSONDecoder().decode(SchemaSemanticVersion.self, from: valid).major == 2)
    }
}

@Suite("Applicability, outcomes, and approvals")
struct ApplicabilityTests {
    @Test("A missing gate result is not a pass")
    func missingIsNotPass() {
        #expect(GateOutcome.passed.isPassing)
        #expect(!GateOutcome.failed.isPassing)
        #expect(!GateOutcome.notExecuted.isPassing)
    }

    @Test("A rejected approval record does not approve")
    func rejectedApprovalDoesNotApprove() {
        #expect(Sample.approval(.approved).isApproved)
        #expect(!Sample.approval(.rejected).isApproved)
    }

    @Test("Not applicable carries its decision rather than being an absence")
    func inapplicabilityCarriesDecision() {
        let applicability = Sample.notApplicable()
        #expect(!applicability.isApplicable)
        #expect(applicability.inapplicabilityDecision?.isApproved == true)
        #expect(GateApplicability.applicable.inapplicabilityDecision == nil)
    }

    @Test("A conditional binding is either bound or an approved decision not to bind")
    func conditionalBinding() {
        let bound = ConditionalArtifactBinding.bound(Sample.artifact("policy.provenance"))
        #expect(bound.isBound)
        #expect(bound.boundReference == Sample.artifact("policy.provenance"))
        let unbound = ConditionalArtifactBinding<ArtifactID>.notApplicable(
            decision: Sample.approval()
        )
        #expect(!unbound.isBound)
        #expect(unbound.boundReference == nil)
    }
}

@Suite("Preprocessing Contract")
struct PreprocessingContractTests {
    @Test("A metadata rule map must cover every state exactly once")
    func metadataMapTotality() throws {
        let rules = try Sample.orientationRules()
        for state in ImageMetadataState.allCases {
            #expect(rules.action(for: state) == .applyDeclaredOrientation)
        }

        #expect(throws: ArtifactSchemaError.self) {
            try MetadataStateRules(
                rules: [
                    .init(state: .valid, action: OrientationAction.applyDeclaredOrientation),
                    .init(state: .absent, action: OrientationAction.ignoreDeclaredOrientation),
                    .init(state: .malformed, action: OrientationAction.rejectAsPreprocessingError),
                ]
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try MetadataStateRules(
                rules: ImageMetadataState.allCases.map {
                    MetadataStateRules<OrientationAction>.Rule(
                        state: $0,
                        action: .applyDeclaredOrientation
                    )
                } + [.init(state: .valid, action: OrientationAction.ignoreDeclaredOrientation)]
            )
        }
    }

    @Test("An incomplete metadata map cannot be decoded either")
    func metadataMapDecodingValidates() throws {
        let complete = try Sample.orientationRules()
        let encoded = try JSONEncoder().encode(complete)
        let roundTripped = try JSONDecoder().decode(
            MetadataStateRules<OrientationAction>.self,
            from: encoded
        )
        #expect(roundTripped == complete)

        let partial = Data(#"[{"state":"valid","action":"apply-declared-orientation"}]"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MetadataStateRules<OrientationAction>.self, from: partial)
        }
    }

    @Test("Resize keeps the fixed 440 short edge")
    func resizeShortEdgeFixed() throws {
        #expect(try Sample.resize().targetShortEdge == 440)
        #expect(throws: ArtifactSchemaError.self) { try Sample.resize(targetShortEdge: 439) }
        #expect(throws: ArtifactSchemaError.self) { try Sample.resize(targetShortEdge: 0) }
    }

    @Test("Center crop keeps the fixed 384 by 384 geometry")
    func cropGeometryFixed() throws {
        #expect(try Sample.crop().width == 384)
        #expect(throws: ArtifactSchemaError.self) { try Sample.crop(width: 383) }
        #expect(throws: ArtifactSchemaError.self) { try Sample.crop(height: 512) }
    }

    @Test("Model input is UInt8 RGB with no app-side normalization")
    func modelInputFixed() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.modelInput(appliesAppSideNormalization: true)
        }
        #expect(throws: ArtifactSchemaError.self) { try Sample.modelInput(elementType: .float32) }
    }

    @Test("Model output is one floating-point scalar named logit")
    func modelOutputFixed() throws {
        #expect(try Sample.modelOutput().featureName.value == "logit")
        #expect(throws: ArtifactSchemaError.self) { try Sample.modelOutput(featureName: "score") }
        #expect(throws: ArtifactSchemaError.self) {
            try ModelOutputContract(
                featureName: Sample.text("logit"),
                elementType: .uint8,
                isPositiveGoing: true
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try ModelOutputContract(
                featureName: Sample.text("logit"),
                elementType: .float32,
                isPositiveGoing: false
            )
        }
    }

    @Test("A contract supports exactly the four Supported Static Image containers")
    func supportedContainersFixed() throws {
        _ = try Sample.preprocessingContract()
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.preprocessingContract(supportedContainers: [.jpeg, .png])
        }
    }

    @Test("A contract round trips through JSON")
    func contractRoundTrip() throws {
        let contract = try Sample.preprocessingContract()
        let encoded = try JSONEncoder().encode(contract)
        #expect(try JSONDecoder().decode(PreprocessingContract.self, from: encoded) == contract)
    }
}

@Suite("Calibration Policy")
struct CalibrationPolicyTests {
    @Test("The budget is positive and no greater than one percent")
    func budgetBounds() throws {
        _ = try Sample.budget(Decimal(sign: .plus, exponent: -2, significand: 1))
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.budget(Decimal(sign: .plus, exponent: -2, significand: 2))
        }
        #expect(throws: ArtifactSchemaError.self) { try Sample.budget(0) }
    }

    @Test("The pass rule uses the predeclared 95 percent level")
    func passRuleLevelFixed() throws {
        _ = try Sample.passRule()
        #expect(throws: ArtifactSchemaError.self) {
            try FalseAccusationPassRule(
                statistic: .observedRate,
                intervalMethod: .wilsonScore,
                confidenceLevel: Sample.ratio(Decimal(sign: .plus, exponent: -1, significand: 9))
            )
        }
    }

    @Test("A boundary needs a finite half-width of at least 0.131 and two labels")
    func boundaryConstraints() throws {
        _ = try Sample.boundary(halfWidth: 0.131)
        #expect(throws: ArtifactSchemaError.self) { try Sample.boundary(halfWidth: 0.13) }
        #expect(throws: ArtifactSchemaError.self) { try Sample.boundary(halfWidth: .nan) }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.boundary(lower: .notEnoughSignal, upper: .notEnoughSignal)
        }
        #expect(throws: ArtifactSchemaError.self) {
            try CategoryBoundary(
                rawLogitBoundary: .infinity,
                abstentionHalfWidth: 0.2,
                lowerDecision: .noStrongSignalDetected,
                upperDecision: .signalsConsistentWithAIGeneration
            )
        }
    }

    @Test("The abstention band is closed around the boundary")
    func abstentionBandIsClosed() throws {
        let boundary = try Sample.boundary(halfWidth: 0.2)
        #expect(boundary.abstentionLowerBound == 2.3)
        #expect(boundary.abstentionUpperBound == 2.7)
    }

    @Test("The three labels carry their fixed metric categories")
    func metricCategoriesFixed() throws {
        #expect(
            PixelLabelKey.signalsConsistentWithAIGeneration.requiredMetricCategory == .positive
        )
        #expect(PixelLabelKey.noStrongSignalDetected.requiredMetricCategory == .nonPositive)
        #expect(PixelLabelKey.notEnoughSignal.requiredMetricCategory == .insufficient)

        #expect(throws: ArtifactSchemaError.self) {
            try Sample.calibrationPolicy(
                metricCategories: [
                    MetricCategoryAssignment(label: .notEnoughSignal, category: .nonPositive),
                    MetricCategoryAssignment(
                        label: .signalsConsistentWithAIGeneration,
                        category: .positive
                    ),
                    MetricCategoryAssignment(
                        label: .noStrongSignalDetected,
                        category: .nonPositive
                    ),
                ]
            )
        }
    }

    @Test("The sub-440 rule and the uncovered-input rule cannot be weakened")
    func abstentionRulesFixed() throws {
        _ = try Sample.calibrationPolicy()
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.calibrationPolicy(minimumShortEdge: 439)
        }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.calibrationPolicy(belowMinimumShortEdgeLabel: .noStrongSignalDetected)
        }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.calibrationPolicy(uncoveredBehavior: .insufficientSignal)
        }
    }

    @Test("An abstention quality rule must cite release evidence")
    func abstentionRuleNeedsEvidence() throws {
        _ = try Sample.qualityRule()
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.qualityRule(outcome: .insufficientSignal, evidenceRecords: [])
        }
        // An error-producing rule adds no abstention, so it needs no abstention evidence.
        _ = try Sample.qualityRule(outcome: .calibrationInputError, evidenceRecords: [])
    }

    @Test("A quality rule must name a required quality feature")
    func qualityRuleNeedsDeclaredFeature() throws {
        let rule = try Sample.qualityRule()
        _ = try Sample.calibrationPolicy(qualityRules: [rule])
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.calibrationPolicy(qualityRules: [rule], requiredQualityFeatures: [])
        }
    }

    @Test("The upstream boundary stays metadata at its exact value")
    func upstreamBoundaryIsMetadata() throws {
        _ = try Sample.upstreamMetadata()
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.upstreamMetadata(role: .productDecisionBoundary)
        }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.upstreamMetadata(value: Decimal(sign: .plus, exponent: -1, significand: 14))
        }
    }

    @Test("A policy round trips through JSON")
    func policyRoundTrip() throws {
        let policy = try Sample.calibrationPolicy(qualityRules: [Sample.qualityRule()])
        let encoded = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(CalibrationPolicy.self, from: encoded) == policy)
    }

    @Test("A weakened policy cannot be decoded either")
    func policyDecodingValidates() throws {
        let policy = try Sample.calibrationPolicy()
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy))
                as? [String: Any]
        )
        object["minimumShortEdge"] = 200
        let mutated = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CalibrationPolicy.self, from: mutated)
        }
    }
}

@Suite("Calibration release evidence")
struct CalibrationReleaseEvidenceTests {
    @Test("Slice counts must add up to the eligible population")
    func countsMustBalance() throws {
        _ = try Sample.outcomeCounts()
        #expect(throws: ArtifactSchemaError.self) {
            try SliceOutcomeCounts(
                eligibleRealImages: Sample.nonNegative(100),
                eligibleSyntheticImages: Sample.nonNegative(80),
                realPositiveLabels: Sample.nonNegative(1),
                realNonPositiveLabels: Sample.nonNegative(85),
                realInsufficientLabels: Sample.nonNegative(0),
                syntheticPositiveLabels: Sample.nonNegative(60),
                syntheticNonPositiveLabels: Sample.nonNegative(10),
                syntheticInsufficientLabels: Sample.nonNegative(10),
                errorCount: Sample.nonNegative(0)
            )
        }
    }

    @Test("An interval's bounds are ordered")
    func intervalOrdered() throws {
        _ = try Sample.interval()
        #expect(throws: ArtifactSchemaError.self) {
            try ConfidenceIntervalResult(
                method: .wilsonScore,
                confidenceLevel: Sample.ratio(FalseAccusationPassRule.requiredConfidenceLevel),
                lowerBound: Sample.ratio(Decimal(sign: .plus, exponent: -1, significand: 5)),
                upperBound: Sample.ratio(Decimal(sign: .plus, exponent: -1, significand: 1))
            )
        }
    }

    @Test("Separation is recorded between two different populations, at both levels")
    func separationRecord() throws {
        let separated = try PopulationSeparationResult(
            firstPopulation: .heldOutCalibration,
            secondPopulation: .productThresholdEvaluation,
            sampleLevelOutcome: .passed,
            contentLevelOutcome: .passed,
            evidence: Sample.evidence()
        )
        #expect(separated.isSeparated)

        let contentContaminated = try PopulationSeparationResult(
            firstPopulation: .knownModelTraining,
            secondPopulation: .heldOutCalibration,
            sampleLevelOutcome: .passed,
            contentLevelOutcome: .failed,
            evidence: Sample.evidence()
        )
        #expect(!contentContaminated.isSeparated)

        let unverified = try PopulationSeparationResult(
            firstPopulation: .knownModelTraining,
            secondPopulation: .heldOutCalibration,
            sampleLevelOutcome: .passed,
            contentLevelOutcome: .notExecuted,
            evidence: Sample.evidence()
        )
        #expect(!unverified.isSeparated)

        #expect(throws: ArtifactSchemaError.self) {
            try PopulationSeparationResult(
                firstPopulation: .heldOutCalibration,
                secondPopulation: .heldOutCalibration,
                sampleLevelOutcome: .passed,
                contentLevelOutcome: .passed,
                evidence: Sample.evidence()
            )
        }
    }

    @Test("A slice specification uses the predeclared 95 percent level")
    func sliceLevelFixed() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseGatingSliceSpecification(
                id: Sample.slice(),
                schemaVersion: .v1,
                eligibilityRule: Sample.evidence(),
                outcomeMapping: Sample.evidence(),
                metricDefinition: Sample.evidence(),
                datasetComposition: Sample.evidence(),
                degradationCondition: Sample.evidence(),
                intervalMethod: .clopperPearson,
                confidenceLevel: Sample.ratio(Decimal(sign: .plus, exponent: -1, significand: 9)),
                isContemporaryPhoneCameraSlice: true
            )
        }
    }
}

@Suite("Provenance Policy")
struct ProvenancePolicyTests {
    @Test("An unresolved revocation answer is never validated")
    func revocationCannotBeValidated() throws {
        _ = try Sample.revocationBehavior(unavailableAnswerState: .indeterminate)
        _ = try Sample.revocationBehavior(unavailableAnswerState: .unsupported)
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.revocationBehavior(unavailableAnswerState: .validated)
        }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.revocationBehavior(unavailableAnswerState: .absent)
        }
    }

    @Test("Validation never permits a network revocation check")
    func revocationIsOffline() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.revocationBehavior(permitsNetwork: true)
        }
    }

    @Test("The trust store is offline and non-empty")
    func trustStoreOffline() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ProvenanceTrustStoreDescriptor(
                store: Sample.evidence(),
                anchorCount: Sample.count(),
                isOfflineOnly: false
            )
        }
        #expect(throws: ArtifactSchemaError.self) { try PositiveCount(validating: 0) }
    }

    @Test("A policy configures only the provenance capability")
    func policyCapabilityFixed() throws {
        _ = try Sample.provenancePolicy()
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.provenancePolicy(capability: .pixelAnalysis)
        }
    }

    @Test("An unmapped validator status has no state rather than a default")
    func unmappedStatusHasNoState() throws {
        let policy = try Sample.provenancePolicy()
        #expect(policy.state(for: Sample.validatorStatus()) == .validated)
        #expect(policy.state(for: Sample.validatorStatus("status.unknown")) == nil)
    }
}

@Suite("Evidence Fusion Rule")
struct EvidenceFusionRuleTests {
    @Test("The enabled lane space has exactly fifteen combinations")
    func combinationCount() {
        #expect(FusionLaneCombination.requiredCombinationCount == 15)
        #expect(Set(FusionLaneCombination.allCombinations).count == 15)
    }

    @Test("The unavailable lane is not part of the fusion key space")
    func unavailableLaneIsNotAKey() {
        #expect(ProvenanceStateKey.allCases.count == 5)
        #expect(!ProvenanceStateKey.allCases.map(\.rawValue).contains("unavailable"))
    }

    @Test("A rule needs every combination exactly once")
    func ruleMustBeExhaustive() throws {
        _ = try Sample.fusionRule()

        let dropped = FusionLaneCombination(pixel: .notEnoughSignal, provenance: .absent)
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.fusionRule(entries: Sample.fusionEntries(dropping: dropped))
        }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.fusionRule(entries: Sample.fusionEntries(duplicating: dropped))
        }
        #expect(throws: ArtifactSchemaError.self) { try Sample.fusionRule(entries: []) }
    }

    @Test("Lookup is total and omission is explicit")
    func lookupIsTotal() throws {
        var entries = Sample.fusionEntries()
        let omitted = FusionLaneCombination(pixel: .notEnoughSignal, provenance: .indeterminate)
        entries = entries.map {
            $0.combination == omitted
                ? FusionEntry(combination: omitted, disposition: .omit, fixture: $0.fixture)
                : $0
        }
        let rule = try Sample.fusionRule(entries: entries)

        for combination in FusionLaneCombination.allCombinations {
            _ = rule.disposition(for: combination)
        }
        #expect(rule.disposition(pixel: .notEnoughSignal, provenance: .indeterminate) == .omit)
        if case .show = rule.disposition(pixel: .notEnoughSignal, provenance: .absent) {
        } else {
            Issue.record("Expected a shown disposition for a declared entry")
        }
    }

    @Test("A rule round trips through JSON")
    func ruleRoundTrip() throws {
        let rule = try Sample.fusionRule()
        let encoded = try JSONEncoder().encode(rule)
        #expect(try JSONDecoder().decode(EvidenceFusionRule.self, from: encoded) == rule)
    }
}

@Suite("Lifecycle and extension execution")
struct LifecycleTests {
    @Test("Every cleanup reason has exactly one deadline")
    func lifecycleCoverage() throws {
        let policy = try Sample.lifecyclePolicy()
        for reason in SessionCleanupReason.allCases {
            #expect(policy.deadline(for: reason).milliseconds == 30_000)
        }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.lifecyclePolicy(reasons: [.completed, .cancelled])
        }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.lifecyclePolicy(reasons: SessionCleanupReason.allCases + [.completed])
        }
    }

    @Test("The extension policy cannot waive consent, delegation, or the ready slot")
    func extensionPolicyInvariants() throws {
        func policy(
            consent: Bool = true,
            delegates: Bool = true,
            pending: PendingHandoffPolicy = .instructRecovery
        ) throws -> ExtensionExecutionPolicy {
            try ExtensionExecutionPolicy(
                id: Sample.artifact("policy.extension-execution"),
                schemaVersion: .v1,
                requiresVisibleConsent: consent,
                delegatesInferenceToMainApplication: delegates,
                stagedFileProtection: .complete,
                pendingHandoffPolicy: pending,
                protectionEvidence: Sample.evidence()
            )
        }
        _ = try policy()
        #expect(throws: ArtifactSchemaError.self) { try policy(consent: false) }
        #expect(throws: ArtifactSchemaError.self) { try policy(delegates: false) }
        #expect(throws: ArtifactSchemaError.self) { try policy(pending: .replaceSilently) }
    }
}

@Suite("Resource budgets")
struct ResourceBudgetTests {
    @Test("Each target requires its own exact metric set")
    func metricSetsDiffer() throws {
        let main = ResourceMetric.requiredMetrics(for: .mainApplication)
        let extensionMetrics = ResourceMetric.requiredMetrics(for: .shareExtension)
        #expect(main.contains(.decodedPixelCount))
        #expect(!extensionMetrics.contains(.decodedPixelCount))
        #expect(extensionMetrics.contains(.encodedInputSize))
        #expect(!main.contains(.encodedInputSize))
        #expect(main.contains(.thermalState) && extensionMetrics.contains(.thermalState))
    }

    @Test("A budget missing a required metric is rejected")
    func missingMetricRejected() throws {
        _ = try Sample.resourceBudget(target: .mainApplication)
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.resourceBudget(
                target: .mainApplication,
                metrics: ResourceMetric.requiredMetrics(for: .mainApplication)
                    .subtracting([.energyImpact])
            )
        }
    }

    @Test("A budget carrying the other target's metric is rejected")
    func crossTargetMetricRejected() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.resourceBudget(
                target: .shareExtension,
                metrics: ResourceMetric.requiredMetrics(for: .shareExtension)
                    .union([.decodedPixelCount])
            )
        }
    }

    @Test("A limit's kind must match its metric")
    func limitKindMatchesMetric() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ResourceLimitEntry(
                metric: .thermalState,
                limit: .numeric(value: Sample.positiveDecimal(), unit: .milliseconds),
                measurementConditions: Sample.evidence()
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try ResourceLimitEntry(
                metric: .peakResidentMemory,
                limit: .thermal(maximumState: .fair),
                measurementConditions: Sample.evidence()
            )
        }
    }

    @Test("A budget set needs both targets, distinctly measured")
    func budgetSetNeedsBothTargets() throws {
        let set = try Sample.budgetSet()
        #expect(set.budget(for: .mainApplication).target == .mainApplication)
        #expect(set.budget(for: .shareExtension).target == .shareExtension)

        #expect(throws: ArtifactSchemaError.self) {
            try ResourceBudgetSet(
                mainApplication: Sample.resourceBudget(target: .shareExtension),
                shareExtension: Sample.resourceBudget(target: .shareExtension)
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try ResourceBudgetSet(
                mainApplication: Sample.resourceBudget(
                    target: .mainApplication,
                    identifier: "budget.shared"
                ),
                shareExtension: Sample.resourceBudget(
                    target: .shareExtension,
                    identifier: "budget.shared"
                )
            )
        }
    }

    @Test("Thermal states are ordered from nominal to critical")
    func thermalOrdering() {
        #expect(ThermalState.nominal < .fair)
        #expect(ThermalState.serious < .critical)
    }
}

@Suite("Model Bundle manifest and verification")
struct ModelBundleTests {
    @Test("The required pixel-model identity is the Lowq checkpoint and weight digest")
    func requiredIdentityConstants() {
        #expect(
            RequiredPixelModel.identity.checkpointIdentifier.rawValue
                == "Thermostatic/community-forensics-low-quality-detector-2026-08"
        )
        #expect(
            RequiredPixelModel.identity.requiredWeightDigest.hexadecimalString
                == "f073f8a325f63e35ef0668c985ac762486a1b50e57dcf5ae33d4647bd26d4c1e"
        )
    }

    @Test("A manifest may declare only the required model identity")
    func manifestIdentityFixed() throws {
        _ = try Sample.manifest()
        let otherIdentity = ModelIdentity(
            checkpointIdentifier: ModelCheckpointIdentifier("Other/detector-2026-01")!,
            requiredWeightDigest: Sample.digest("9")
        )
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.manifest(modelIdentity: otherIdentity)
        }
        let wrongDigest = ModelIdentity(
            checkpointIdentifier: RequiredPixelModel.identity.checkpointIdentifier,
            requiredWeightDigest: Sample.digest("0")
        )
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.manifest(modelIdentity: wrongDigest)
        }
    }

    @Test("Artifact declarations are unique, nonempty, and never self-referential")
    func manifestArtifactRules() throws {
        #expect(throws: ArtifactSchemaError.self) { try Sample.manifest(artifacts: []) }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.manifest(artifacts: [Sample.digestRecord(), Sample.digestRecord()])
        }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.manifest(
                artifacts: [Sample.digestRecord(path: ModelBundleManifest.manifestFileName)]
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.manifest(artifacts: [Sample.digestRecord(byteCount: 0)])
        }
    }

    @Test("The model format is an FP16 mlprogram targeting iOS 17.0")
    func modelFormatFixed() throws {
        _ = try Sample.modelFormat()
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.modelFormat(programKind: .neuralNetwork)
        }
        #expect(throws: ArtifactSchemaError.self) { try Sample.modelFormat(precision: .float32) }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.modelFormat(minimumOS: Sample.platform("18.0.0"))
        }
    }

    @Test("Compatibility requires pixel analysis, a build, and iOS 17 or later")
    func compatibilityMatrixRules() throws {
        _ = try Sample.compatibilityMatrix()
        #expect(throws: ArtifactSchemaError.self) {
            try CompatibilityMatrix(
                compatibleAppBuilds: [],
                requiredCapabilities: [.pixelAnalysis],
                minimumOS: .iOS17
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.compatibilityMatrix(capabilities: [.contentCredentialValidation])
        }
        #expect(throws: ArtifactSchemaError.self) {
            try CompatibilityMatrix(
                compatibleAppBuilds: [Sample.appBuild()],
                requiredCapabilities: [.pixelAnalysis],
                minimumOS: Sample.platform("16.0.0")
            )
        }
    }

    @Test("A self-test case declares at least one finite expectation")
    func selfTestCaseRules() throws {
        _ = try SelfTestCase(
            id: Sample.selfTestCase(),
            fixture: Sample.fixture(),
            expectations: [.pixelLabel(.notEnoughSignal)]
        )
        #expect(throws: ArtifactSchemaError.self) {
            try SelfTestCase(
                id: Sample.selfTestCase(),
                fixture: Sample.fixture(),
                expectations: []
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try SelfTestCase(
                id: Sample.selfTestCase(),
                fixture: Sample.fixture(),
                expectations: [.rawLogit(value: .nan, tolerance: Sample.nonNegativeDecimal())]
            )
        }
    }

    @Test("A verification policy needs an active key and refuses to assume trust")
    func verificationPolicyRules() throws {
        _ = try Sample.verificationPolicy()
        #expect(throws: ArtifactSchemaError.self) { try Sample.verificationPolicy(trustedKeys: []) }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.verificationPolicy(trustedKeys: [Sample.trustedKey(status: .revoked)])
        }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.verificationPolicy(
                trustedKeys: [Sample.trustedKey(algorithm: .ecdsaP256SHA256)]
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.verificationPolicy(revocationBehavior: .treatAsTrusted)
        }
    }

    @Test("Only an active trusted key may verify")
    func keyStatusGovernsVerification() {
        #expect(SigningKeyStatus.active.permitsVerification)
        #expect(!SigningKeyStatus.retired.permitsVerification)
        #expect(!SigningKeyStatus.revoked.permitsVerification)
    }

    @Test("An unknown signing key is not trusted")
    func unknownKeyNotTrusted() throws {
        let policy = try Sample.verificationPolicy()
        #expect(policy.trustedKey(Sample.signingKey()) != nil)
        #expect(policy.trustedKey(Sample.signingKey("key.other")) == nil)
    }

    @Test("A receipt is bindable only when signature and self-tests both passed")
    func receiptBindability() throws {
        #expect(try Sample.activationReceipt().isBindable)
        #expect(try !Sample.activationReceipt(selfTestOutcome: .failed).isBindable)
        #expect(try !Sample.activationReceipt(selfTestOutcome: .notExecuted).isBindable)
        #expect(try !Sample.activationReceipt(signatureOutcome: .notExecuted).isBindable)
    }
}

@Suite("Release Capability Manifest")
struct ReleaseCapabilityManifestTests {
    @Test("Pixel analysis is always compiled")
    func pixelAnalysisRequired() throws {
        _ = try Sample.capabilityManifest()
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.capabilityManifest(capabilities: [.shareExtensionHandoff])
        }
    }

    @Test("Every compiled capability declares exactly one implementation version")
    func implementationVersionCoverage() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.capabilityManifest(
                capabilities: [.pixelAnalysis, .shareExtensionHandoff],
                implementationVersions: [
                    CapabilityImplementationEntry(
                        capability: .pixelAnalysis,
                        version: Sample.version()
                    )
                ]
            )
        }
    }

    @Test("Provenance capability and Provenance Policy binding must agree")
    func provenanceBindingMustAgree() throws {
        // Compiled validator with no bound policy.
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.capabilityManifest(
                capabilities: [.pixelAnalysis, .contentCredentialValidation]
            )
        }
        // Bound policy in a pixel-only build.
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.capabilityManifest(
                capabilities: [.pixelAnalysis],
                policyCompatibility: Sample.policyCompatibility(
                    provenance: .bound(Sample.artifact("policy.provenance"))
                )
            )
        }
        // Agreeing provenance-enabled manifest.
        let manifest = try Sample.capabilityManifest(
            capabilities: [.pixelAnalysis, .contentCredentialValidation],
            policyCompatibility: Sample.policyCompatibility(
                provenance: .bound(Sample.artifact("policy.provenance"))
            )
        )
        #expect(manifest.enablesProvenance)
        #expect(!manifest.enablesFusion)
    }

    @Test("Fusion cannot be enabled without provenance")
    func fusionRequiresProvenance() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.capabilityManifest(
                capabilities: [.pixelAnalysis, .evidenceFusion],
                policyCompatibility: Sample.policyCompatibility(
                    fusion: .bound(Sample.artifact("rule.fusion"))
                )
            )
        }
        let manifest = try Sample.capabilityManifest(
            capabilities: [.pixelAnalysis, .contentCredentialValidation, .evidenceFusion],
            policyCompatibility: Sample.policyCompatibility(
                provenance: .bound(Sample.artifact("policy.provenance")),
                fusion: .bound(Sample.artifact("rule.fusion"))
            )
        )
        #expect(manifest.enablesFusion)
    }

    @Test("The two resource budgets cannot be the same artifact")
    func budgetsMustDiffer() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try PolicyCompatibilitySet(
                preprocessingContract: Sample.artifact(),
                calibrationPolicy: Sample.artifact(),
                lifecyclePolicy: Sample.artifact(),
                extensionExecutionPolicy: Sample.artifact(),
                mainApplicationResourceBudget: Sample.artifact("budget.shared"),
                shareExtensionResourceBudget: Sample.artifact("budget.shared"),
                bundleVerificationPolicy: Sample.artifact(),
                verdictCopyCompatibility: Sample.artifact(),
                provenancePolicy: .notApplicable(decision: Sample.approval()),
                fusionRule: .notApplicable(decision: Sample.approval())
            )
        }
    }
}

@Suite("Device gates, configurations, and allowlist")
struct DeviceAllowlistTests {
    @Test("A candidate is an Apple Neural Engine iPhone on iOS 17 or later")
    func candidateConstraints() throws {
        _ = try Sample.candidate()
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.candidate(osVersion: Sample.platform("16.7.0"))
        }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.candidate(appleNeuralEngineCapable: false)
        }
    }

    @Test("A gate cannot pass on a simulator or a development Mac")
    func nonDeviceEvidenceRejected() throws {
        for environment in [ExecutionEnvironment.iOSSimulator, .developmentMac] {
            #expect(throws: ArtifactSchemaError.self) {
                try GateResultReference(
                    gate: .warmAnalysisLatency,
                    applicability: .applicable,
                    outcome: .passed,
                    result: Sample.evidence(),
                    environment: environment
                )
            }
        }
        // Recording a failure from a development environment stays representable.
        let recorded = try GateResultReference(
            gate: .warmAnalysisLatency,
            applicability: .applicable,
            outcome: .failed,
            result: Sample.evidence(),
            environment: .developmentMac
        )
        #expect(!recorded.isSatisfied)
    }

    @Test("An inapplicable gate carries no result")
    func inapplicableGateHasNoResult() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try GateResultReference(
                gate: .provenanceFixtures,
                applicability: Sample.notApplicable(),
                outcome: .passed,
                result: Sample.evidence(),
                environment: .physicalIPhone
            )
        }
        let skipped = try GateResultReference(
            gate: .provenanceFixtures,
            applicability: Sample.notApplicable(),
            outcome: .notExecuted,
            result: Sample.evidence(),
            environment: .physicalIPhone
        )
        #expect(skipped.isSatisfied)

        let unapproved = try GateResultReference(
            gate: .provenanceFixtures,
            applicability: Sample.notApplicable(.rejected),
            outcome: .notExecuted,
            result: Sample.evidence(),
            environment: .physicalIPhone
        )
        #expect(!unapproved.isSatisfied)
    }

    @Test("An entry records every mandatory gate exactly once")
    func entryGateCoverage() throws {
        let entry = try Sample.approvedConfiguration()
        #expect(entry.gateEvidence.count == DeviceGate.allCases.count)
        #expect(entry.unsatisfiedGates.isEmpty)

        #expect(throws: ArtifactSchemaError.self) {
            try ApprovedDeviceConfiguration(
                id: Sample.configuration(),
                configuration: Sample.candidate(),
                versionTuple: Sample.versionTuple(),
                gateEvidence: Sample.gateReferences(gates: [.coldModelLoad])
            )
        }
    }

    @Test("A failing gate leaves the entry unsatisfied")
    func failingGateSurfaces() throws {
        let entry = try Sample.approvedConfiguration(failing: [.rawLogitParity])
        #expect(entry.unsatisfiedGates == [.rawLogitParity])
    }

    @Test("Provenance gate applicability must match the capability set")
    func provenanceApplicabilityMatchesCapabilities() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ApprovedDeviceConfiguration(
                id: Sample.configuration(),
                configuration: Sample.candidate(),
                versionTuple: Sample.versionTuple(
                    capabilities: [.pixelAnalysis, .contentCredentialValidation]
                ),
                gateEvidence: Sample.gateReferences(provenanceEnabled: false)
            )
        }
        _ = try Sample.approvedConfiguration(provenanceEnabled: true)
    }

    @Test("An empty allowlist blocks distribution without being invalid")
    func emptyAllowlistBlocks() throws {
        let empty = try Sample.allowlist(entries: [])
        #expect(!empty.permitsDistribution)

        let populated = try Sample.allowlist(entries: [Sample.approvedConfiguration()])
        #expect(populated.permitsDistribution)

        let failing = try Sample.allowlist(
            entries: [Sample.approvedConfiguration(failing: [.interruptionCleanup])]
        )
        #expect(!failing.permitsDistribution)
    }

    @Test("Allowlist lookup matches the exact device, version, and build")
    func allowlistLookupIsExact() throws {
        let allowlist = try Sample.allowlist(entries: [Sample.approvedConfiguration()])
        #expect(
            allowlist.entry(
                hardwareIdentifier: Sample.hardware(),
                osVersion: .iOS17,
                appBuild: Sample.appBuild()
            ) != nil
        )
        #expect(
            allowlist.entry(
                hardwareIdentifier: Sample.hardware("iPhone99.9"),
                osVersion: .iOS17,
                appBuild: Sample.appBuild()
            ) == nil
        )
        #expect(
            allowlist.entry(
                hardwareIdentifier: Sample.hardware(),
                osVersion: Sample.platform("17.4.0"),
                appBuild: Sample.appBuild()
            ) == nil
        )
    }
}

@Suite("Device validation plan and results")
struct DeviceValidationTests {
    @Test("A missing device result can only be treated as a failure")
    func missingResultRuleFixed() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try DeviceValidationPlan(
                id: Sample.artifact("plan.device-validation"),
                schemaVersion: .v1,
                candidateConfigurations: [Sample.candidate()],
                fixtureSuite: Sample.artifact("suite.fixtures"),
                modelBundle: Sample.bundle(),
                capabilityManifest: Sample.artifact("manifest.capability"),
                comparisons: [
                    try ComparisonSpecification(
                        metric: .categoricalOutcome,
                        reference: Sample.evidence(),
                        tolerance: nil,
                        requiredAgreement: .one
                    )
                ],
                measurements: try Self.measurements(),
                missingResultRule: .treatAsPass,
                approval: Sample.approval()
            )
        }
    }

    @Test("A plan declares every metric for both targets on every candidate")
    func planCoversBothTargets() throws {
        _ = try Self.plan()
        #expect(throws: ArtifactSchemaError.self) {
            try Self.plan(measurements: Self.measurements(targets: [.mainApplication]))
        }
    }

    @Test("Categorical Pixel Evidence agreement is fixed at 100 percent")
    func categoricalAgreementFixed() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ComparisonSpecification(
                metric: .categoricalOutcome,
                reference: Sample.evidence(),
                tolerance: nil,
                requiredAgreement: Sample.ratio(
                    Decimal(sign: .plus, exponent: -2, significand: 99)
                )
            )
        }
    }

    @Test("A comparison declares either a tolerance or an agreement ratio")
    func comparisonKindMatchesMetric() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ComparisonSpecification(
                metric: .rawLogit,
                reference: Sample.evidence(),
                tolerance: nil,
                requiredAgreement: .one
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try ComparisonSpecification(
                metric: .provenanceState,
                reference: Sample.evidence(),
                tolerance: try NumericTolerance(
                    kind: .absolute,
                    value: Sample.nonNegativeDecimal(1)
                ),
                requiredAgreement: nil
            )
        }
    }

    @Test("An exact tolerance carries no slack")
    func exactToleranceIsZero() throws {
        _ = try NumericTolerance(kind: .exact, value: Sample.nonNegativeDecimal(0))
        #expect(throws: ArtifactSchemaError.self) {
            try NumericTolerance(kind: .exact, value: Sample.nonNegativeDecimal(1))
        }
    }

    @Test("An executed measurement retains its raw samples")
    func measurementRetainsRawValues() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try MeasurementRecord(
                metric: .warmAnalysisLatency,
                target: .mainApplication,
                specification: Sample.evidence(),
                rawValues: [],
                summaryStatistic: .median,
                summaryValue: 120,
                limit: Sample.limit(for: .warmAnalysisLatency),
                outcome: .passed
            )
        }
        let record = try MeasurementRecord(
            metric: .warmAnalysisLatency,
            target: .mainApplication,
            specification: Sample.evidence(),
            rawValues: [110, 120, 130],
            summaryStatistic: .median,
            summaryValue: 120,
            limit: Sample.limit(for: .warmAnalysisLatency),
            outcome: .passed
        )
        #expect(record.rawValues.count == 3)
    }

    @Test("A measurement cannot claim the other target's metric")
    func measurementTargetMatchesMetric() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try MeasurementRecord(
                metric: .decodedPixelCount,
                target: .shareExtension,
                specification: Sample.evidence(),
                rawValues: [1],
                summaryStatistic: .maximum,
                summaryValue: 1,
                limit: Sample.limit(for: .decodedPixelCount),
                outcome: .passed
            )
        }
    }

    @Test("A comparison record cannot claim more agreement than it compared")
    func comparisonCountsBounded() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ComparisonRecord(
                metric: .categoricalOutcome,
                specification: Sample.evidence(),
                comparedFixtureCount: Sample.nonNegative(10),
                agreeingFixtureCount: Sample.nonNegative(11),
                maximumDeviation: nil,
                outcome: .passed
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try ComparisonRecord(
                metric: .categoricalOutcome,
                specification: Sample.evidence(),
                comparedFixtureCount: Sample.nonNegative(0),
                agreeingFixtureCount: Sample.nonNegative(0),
                maximumDeviation: nil,
                outcome: .passed
            )
        }
    }

    @Test("A simulator result set is honest about not being device evidence")
    func simulatorResultSetNotDeviceEvidence() throws {
        let simulated = try DeviceValidationResultSet(
            id: Sample.artifact("results.simulator"),
            schemaVersion: .v1,
            configuration: Sample.candidate(),
            versionTuple: Sample.versionTuple(),
            environment: .iOSSimulator,
            gateResults: try Self.gateRecords()
        )
        #expect(!simulated.isPhysicalDeviceEvidence)
        #expect(simulated.unsatisfiedGates.count == DeviceGate.allCases.count - 1)

        let onDevice = try DeviceValidationResultSet(
            id: Sample.artifact("results.device"),
            schemaVersion: .v1,
            configuration: Sample.candidate(),
            versionTuple: Sample.versionTuple(),
            environment: .physicalIPhone,
            gateResults: try Self.gateRecords()
        )
        #expect(onDevice.isPhysicalDeviceEvidence)
        #expect(onDevice.unsatisfiedGates.isEmpty)
    }

    // MARK: Helpers

    private static func measurements(
        targets: [ExecutionTarget] = ExecutionTarget.allCases
    ) throws -> [ResourceMeasurementSpecification] {
        try targets.flatMap { target in
            try ResourceMetric.requiredMetrics(for: target)
                .sorted { $0.rawValue < $1.rawValue }
                .map { metric in
                    try ResourceMeasurementSpecification(
                        metric: metric,
                        target: target,
                        hardwareIdentifier: Sample.hardware(),
                        osVersion: .iOS17,
                        appBuild: Sample.appBuild(),
                        workload: Sample.evidence(),
                        warmth: .cold,
                        branchExecution: .serial,
                        startingThermalState: .nominal,
                        startingPowerCondition: .batteryUnplugged,
                        sampleCount: Sample.count(),
                        summaryStatistic: .median,
                        passLimit: Sample.limit(for: metric)
                    )
                }
        }
    }

    private static func plan(
        measurements: [ResourceMeasurementSpecification]? = nil
    ) throws -> DeviceValidationPlan {
        try DeviceValidationPlan(
            id: Sample.artifact("plan.device-validation"),
            schemaVersion: .v1,
            candidateConfigurations: [Sample.candidate()],
            fixtureSuite: Sample.artifact("suite.fixtures"),
            modelBundle: Sample.bundle(),
            capabilityManifest: Sample.artifact("manifest.capability"),
            comparisons: [
                try ComparisonSpecification(
                    metric: .categoricalOutcome,
                    reference: Sample.evidence(),
                    tolerance: nil,
                    requiredAgreement: .one
                )
            ],
            measurements: try measurements ?? Self.measurements(),
            missingResultRule: .treatAsFailure,
            approval: Sample.approval()
        )
    }

    private static func gateRecords() throws -> [DeviceGateResultRecord] {
        try DeviceGate.allCases.map { gate in
            let applicable = !gate.isProvenanceConditional
            return try DeviceGateResultRecord(
                gate: gate,
                applicability: applicable ? .applicable : Sample.notApplicable(),
                outcome: applicable ? .passed : .notExecuted,
                measurements: [],
                comparisons: applicable
                    ? [
                        try ComparisonRecord(
                            metric: .categoricalOutcome,
                            specification: Sample.evidence(),
                            comparedFixtureCount: Sample.nonNegative(96),
                            agreeingFixtureCount: Sample.nonNegative(96),
                            maximumDeviation: nil,
                            outcome: .passed
                        )
                    ]
                    : []
            )
        }
    }
}

@Suite("Fixture suite")
struct FixtureSuiteTests {
    @Test("Provenance families need an applicable provenance decision")
    func provenanceFixturesNeedApplicability() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.fixtureSuite(
                provenanceApplicability: Sample.notApplicable(),
                fixtures: [try Sample.fixtureRecord(family: .provenanceValidSigned)]
            )
        }
        _ = try Sample.fixtureSuite(
            provenanceApplicability: .applicable,
            fixtures: [try Sample.fixtureRecord(family: .provenanceValidSigned)]
        )
    }

    @Test("A provenance fixture declares its expected state and others cannot")
    func provenanceExpectationRules() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.fixtureRecord(
                family: .provenanceAbsent,
                expectations: [.pixelLabel(.notEnoughSignal)]
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.fixtureRecord(
                family: .modelParity,
                expectations: [.provenanceState(.absent)]
            )
        }
    }

    @Test("A fixture declares at least one expectation")
    func fixtureNeedsExpectation() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.fixtureRecord(expectations: [])
        }
    }

    @Test("Missing families and incomplete parity coverage are reported")
    func suiteCompletenessReported() throws {
        let suite = try Sample.fixtureSuite()
        #expect(suite.missingFamilies.contains(.malformedInput))
        #expect(!suite.missingFamilies.contains(.modelParity))
        #expect(!suite.missingFamilies.contains(.provenanceAbsent))
        #expect(!suite.hasCompleteModelParityCoverage)
        #expect(ReleaseFixtureSuite.requiredModelParityFixtureCount == 96)
    }

    @Test("Fixture identifiers and asset paths are unique")
    func fixtureUniqueness() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.fixtureSuite(
                fixtures: [
                    try Sample.fixtureRecord(identifier: "fixture.a", assetPath: "fixtures/a.jpg"),
                    try Sample.fixtureRecord(identifier: "fixture.a", assetPath: "fixtures/b.jpg"),
                ]
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.fixtureSuite(
                fixtures: [
                    try Sample.fixtureRecord(identifier: "fixture.a", assetPath: "fixtures/a.jpg"),
                    try Sample.fixtureRecord(identifier: "fixture.b", assetPath: "fixtures/a.jpg"),
                ]
            )
        }
    }
}

@Suite("Approved Verdict Copy catalog")
struct ApprovedVerdictCopyTests {
    @Test("Version 1 copy is English")
    func languageFixed() throws {
        _ = try Sample.copyCatalog()
        #expect(throws: ArtifactSchemaError.self) { try Sample.copyCatalog(languageTag: "fr") }
    }

    @Test("The catalogue stores keys, and every reachable surface needs one")
    func surfaceCoverage() throws {
        let complete = try Sample.copyCatalog()
        #expect(complete.missingUnconditionalSurfaces.isEmpty)
        #expect(complete.localizationKey(for: .evidenceScope) != nil)
        #expect(
            complete.localizationKey(
                for: .pixelLabel(.signalsConsistentWithAIGeneration)
            ) != nil
        )

        let partial = try Sample.copyCatalog(
            entries: Sample.copyEntries(
                surfaces: VerdictCopySurface.unconditionalSurfaces
                    .subtracting([.correctionChannel])
            )
        )
        #expect(partial.missingUnconditionalSurfaces == [.correctionChannel])
        #expect(partial.localizationKey(for: .correctionChannel) == nil)
    }

    @Test("Enabled provenance adds its own required surfaces")
    func provenanceSurfacesConditional() throws {
        let catalog = try Sample.copyCatalog()
        #expect(catalog.missingProvenanceSurfaces(isProvenanceEnabled: false).isEmpty)
        #expect(catalog.missingProvenanceSurfaces(isProvenanceEnabled: true).count == 5)
    }

    @Test("Surfaces and localization keys are unique")
    func catalogUniqueness() throws {
        let duplicated = Sample.copyEntries() + [
            VerdictCopyEntry(surface: .evidenceScope, localizationKey: Sample.copyKey("copy.other"))
        ]
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.copyCatalog(entries: duplicated)
        }
        let reusedKey = [
            VerdictCopyEntry(surface: .evidenceScope, localizationKey: Sample.copyKey()),
            VerdictCopyEntry(surface: .falseResultLimitation, localizationKey: Sample.copyKey()),
        ]
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.copyCatalog(entries: reusedKey)
        }
    }

    @Test("Every pixel label and error category has a required surface")
    func requiredSurfacesEnumerated() {
        let surfaces = VerdictCopySurface.unconditionalSurfaces
        for label in PixelLabelKey.allCases {
            #expect(surfaces.contains(.pixelLabel(label)))
            #expect(surfaces.contains(.pixelExplanation(label)))
        }
        for error in AnalysisErrorKey.allCases {
            #expect(surfaces.contains(.analysisError(error)))
            #expect(surfaces.contains(.errorRecovery(error)))
        }
        #expect(surfaces.contains(.provenanceUnavailable))
        #expect(!surfaces.contains(.provenanceState(.validated)))
    }
}

@Suite("Accessibility and localization matrices")
struct AccessibilityMatrixTests {
    @Test("A complete matrix passes and a missing cell does not")
    func matrixCompleteness() throws {
        let complete = try Sample.accessibilityMatrix()
        #expect(complete.missingCellKeys.isEmpty)
        #expect(complete.failingCellKeys.isEmpty)
        #expect(complete.isComplete)

        let partial = try Sample.accessibilityMatrix(
            workflows: AccessibilityWorkflow.allCases.filter { $0 != .retry }
        )
        #expect(!partial.missingCellKeys.isEmpty)
        #expect(!partial.isComplete)
    }

    @Test("A failing cell blocks the matrix")
    func failingCellBlocks() throws {
        let failing = try Sample.accessibilityMatrix(failing: true)
        #expect(failing.missingCellKeys.isEmpty)
        #expect(!failing.failingCellKeys.isEmpty)
        #expect(!failing.isComplete)
    }

    @Test("A manual pass needs approved imported evidence")
    func manualPassNeedsApproval() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.accessibilityMatrix(manualWithoutApproval: true)
        }
        _ = try AccessibilityResultCell(
            workflow: .retry,
            condition: .switchControl,
            osMajorVersion: 17,
            configuration: Sample.configuration(),
            outcome: .passed,
            execution: .manual(importedEvidence: Sample.approval()),
            evidence: Sample.evidence()
        )
    }

    @Test("A matrix cell cannot claim an unsupported iOS major version")
    func cellVersionBounded() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityResultCell(
                workflow: .analysis,
                condition: .voiceOver,
                osMajorVersion: 16,
                configuration: Sample.configuration(),
                outcome: .passed,
                execution: .automated,
                evidence: Sample.evidence()
            )
        }
    }
}

@Suite("Release readiness record")
struct ReleaseReadinessTests {
    @Test("A complete passing record has nothing unresolved or failing")
    func completeRecord() throws {
        let record = try Sample.releaseRecord()
        #expect(record.unresolvedMandatoryGates.isEmpty)
        #expect(record.failingMandatoryGates.isEmpty)
        #expect(!record.enablesProvenance)
        #expect(!record.enablesFusion)
    }

    @Test("Every mandatory gate is recorded exactly once")
    func gateCoverage() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.releaseRecord(
                gateRecords: Sample.gateRecords(gates: [.privacyAudit, .archiveAudit])
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try Sample.releaseRecord(
                gateRecords: Sample.gateRecords(gates: ReleaseGate.allCases + [.privacyAudit])
            )
        }
    }

    @Test("A missing result blocks rather than passing")
    func missingResultBlocks() throws {
        let record = try Sample.releaseRecord(overrides: [.deviceAllowlist: .notExecuted])
        #expect(record.unresolvedMandatoryGates == [.deviceAllowlist])
        #expect(!record.record(for: .deviceAllowlist).isSatisfied)
    }

    @Test("A failing result is reported as failing")
    func failingResultBlocks() throws {
        let record = try Sample.releaseRecord(overrides: [.repositoryCodeLicense: .failed])
        #expect(record.failingMandatoryGates == [.repositoryCodeLicense])
    }

    @Test("An unconditional gate cannot be declared not applicable")
    func unconditionalGateCannotBeWaived() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseGateRecord(
                gate: .privacyAudit,
                applicability: Sample.notApplicable(),
                outcome: .notExecuted,
                evidence: Sample.evidence()
            )
        }
        // The two capability gates may be declared not applicable.
        _ = try ReleaseGateRecord(
            gate: .provenanceFeasibility,
            applicability: Sample.notApplicable(),
            outcome: .notExecuted,
            evidence: Sample.evidence()
        )
    }

    @Test("A pixel-only record is valid, and fusion cannot outlive provenance")
    func conditionalGateCoupling() throws {
        let pixelOnly = try Sample.releaseRecord(
            provenanceApplicable: false,
            fusionApplicable: false
        )
        #expect(pixelOnly.unresolvedMandatoryGates.isEmpty)

        #expect(throws: ArtifactSchemaError.self) {
            try Sample.releaseRecord(provenanceApplicable: false, fusionApplicable: true)
        }

        let both = try Sample.releaseRecord(provenanceApplicable: true, fusionApplicable: true)
        #expect(both.enablesProvenance && both.enablesFusion)
    }

    @Test("A rejected inapplicability decision does not satisfy a conditional gate")
    func rejectedWaiverDoesNotSatisfy() throws {
        let rejected = try ReleaseGateRecord(
            gate: .fusionRuleApproval,
            applicability: Sample.notApplicable(.rejected),
            outcome: .notExecuted,
            evidence: Sample.evidence()
        )
        #expect(!rejected.isSatisfied)

        var records = try Sample.gateRecords()
        records = records.map { $0.gate == .fusionRuleApproval ? rejected : $0 }
        let record = try Sample.releaseRecord(gateRecords: records)
        #expect(record.failingMandatoryGates.contains(.fusionRuleApproval))
    }

    @Test("Distribution rights need both decisions")
    func distributionRightsNeedBoth() {
        #expect(Sample.distributionRights().isResolved)
        #expect(!Sample.distributionRights(code: .rejected).isResolved)
        #expect(!Sample.distributionRights(data: .rejected).isResolved)
    }

    @Test("Governance discloses invalid red-team status and carries an explicit decision")
    func governanceDisclosure() throws {
        let record = try Sample.governance()
        #expect(!record.redTeamValidationValid)
        #expect(record.inheritedRedTeamStatus == .invalidNoReportInherited)
        #expect(record.decision.isApproved)
        #expect(try !Sample.governance(decision: .rejected).decision.isApproved)

        #expect(throws: ArtifactSchemaError.self) {
            try ModelGovernanceDecisionRecord(
                modelIdentity: RequiredPixelModel.identity,
                isIndependentNonPeerReviewed: true,
                redTeamValidationValid: false,
                inheritedRedTeamStatus: .validReportInherited,
                decision: Sample.approval()
            )
        }
    }

    @Test("A record round trips through JSON")
    func recordRoundTrip() throws {
        let record = try Sample.releaseRecord()
        let encoded = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(ReleaseReadinessRecord.self, from: encoded) == record)
    }

    @Test("A benchmark claim carries every required binding")
    func benchmarkClaimBindings() throws {
        let claim = BenchmarkClaimRecord(
            id: Sample.artifact("claim.sample"),
            dataset: Sample.evidence("evidence.dataset"),
            datasetComposition: Sample.evidence("evidence.composition"),
            degradationCondition: Sample.evidence("evidence.degradation"),
            modelIdentity: RequiredPixelModel.identity,
            modelBundle: Sample.bundle(),
            calibrationPolicy: Sample.artifact("policy.calibration"),
            counts: try Sample.outcomeCounts(),
            coverage: Sample.ratio(Decimal(sign: .plus, exponent: -2, significand: 86)),
            metricDefinition: Sample.evidence("evidence.metric"),
            evidenceProvenance: Sample.evidence("evidence.run"),
            uncertaintyInterval: try Sample.interval(),
            activeLimitations: Sample.evidence("evidence.limitations"),
            correctionChannel: Sample.evidence("evidence.correction-channel")
        )
        let encoded = try JSONEncoder().encode(claim)
        #expect(try JSONDecoder().decode(BenchmarkClaimRecord.self, from: encoded) == claim)
    }
}
