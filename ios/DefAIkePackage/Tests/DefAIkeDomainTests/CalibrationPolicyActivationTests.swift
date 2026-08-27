import Foundation
import Testing

@testable import DefAIkeDomain

// Activation-time validation of a Calibration Policy.
//
// Every policy in this file is schema-valid: `CalibrationPolicy` already rejects a
// budget above 1%, a label set other than the three fixed labels, a wrong metric
// category, a nonfinite or under-0.131 half-width, a weakened sub-440 rule, an
// abstention rule with an empty evidence list, an uncovered required value that
// abstains, and an upstream boundary that is not `1.390625` metadata. Those checks
// have their own tests in `ReleaseArtifactSchemaTests`.
//
// What is under test here is what one valid artifact cannot see: a boundary *set*
// that is ambiguous or leaves a region undecided, an evidence citation that resolves
// to nothing, a policy that does not match the Model Bundle it would activate with,
// a required quality feature no rule can reach, and a rule outcome the requirements
// do not permit for the condition it matches.
//
// No value here is an approved boundary, budget, half-width, quality rule, or
// evidence record. Each test mutates one condition of a synthetic policy and asserts
// that activation fails closed at a named field.

extension Sample {
    /// The evidence records the calibration samples cite, as an approved index.
    static func evidenceIndex(
        records: [EvidenceSource]? = nil
    ) throws -> ReleaseEvidenceIndex {
        try ReleaseEvidenceIndex(
            records: records ?? [evidence("evidence.calibration"), evidence("evidence.quality")]
        )
    }

    /// A policy whose required quality features are all covered, so activation turns
    /// on the condition each test mutates rather than on rule coverage.
    static func activatablePolicy(
        identifier: String = "policy.calibration",
        boundaries: [CategoryBoundary]? = nil,
        qualityRules: [QualityDecisionRule] = [],
        requiredQualityFeatures: Set<QualityFeatureID> = [],
        compatibleModel: ModelIdentity = RequiredPixelModel.identity,
        compatiblePreprocessing: String = "contract.preprocessing",
        compatibleVerdictCopy: String = "copy.compatibility",
        budget: FalseAccusationBudget? = nil,
        passRule: FalseAccusationPassRule? = nil,
        evidenceRecords: [EvidenceSource] = [evidence("evidence.calibration")]
    ) throws -> CalibrationPolicy {
        try calibrationPolicy(
            identifier: identifier,
            boundaries: boundaries,
            qualityRules: qualityRules,
            requiredQualityFeatures: requiredQualityFeatures,
            compatibleModel: compatibleModel,
            compatiblePreprocessing: compatiblePreprocessing,
            compatibleVerdictCopy: compatibleVerdictCopy,
            budget: budget,
            passRule: passRule,
            evidenceRecords: evidenceRecords
        )
    }

    /// Activates `policy` against the sample bundle manifest and evidence index.
    static func activate(
        _ policy: CalibrationPolicy,
        bundle: ModelBundleManifest? = nil,
        index: ReleaseEvidenceIndex? = nil
    ) throws -> ValidatedCalibrationPolicy {
        try ValidatedCalibrationPolicy(
            activating: policy,
            for: try bundle ?? manifest(),
            evidence: try index ?? evidenceIndex()
        )
    }
}

/// Asserts that `build` fails with a schema error naming `field`.
private func rejects(
    _ field: String,
    _ build: () throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        try build()
        Issue.record("activation accepted a policy it must reject", sourceLocation: sourceLocation)
    } catch let error as ArtifactSchemaError {
        #expect(
            error.description.contains(field),
            "\(error.description) does not name \(field)",
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record(
            "unexpected error \(error)",
            sourceLocation: sourceLocation
        )
    }
}

@Suite("Calibration Policy activation")
struct CalibrationPolicyActivationTests {
    @Test("A schema-valid, compatible, evidenced policy activates")
    func validPolicyActivates() throws {
        let policy = try Sample.activatablePolicy()
        let validated = try Sample.activate(policy)

        #expect(validated.policy == policy)
        #expect(validated.id == policy.id)
        #expect(validated.modelBundle == Sample.bundle())
        #expect(validated.orderedBoundaries == policy.boundaries)
    }

    @Test("Boundaries are exposed in ascending raw-logit order")
    func boundariesAreOrdered() throws {
        let upper = try Sample.boundary(
            position: 2.5,
            lower: .signalsConsistentWithAIGeneration,
            upper: .noStrongSignalDetected
        )
        let lower = try Sample.boundary(
            position: 0.0,
            lower: .noStrongSignalDetected,
            upper: .signalsConsistentWithAIGeneration
        )
        let validated = try Sample.activate(
            try Sample.activatablePolicy(boundaries: [upper, lower])
        )

        #expect(validated.orderedBoundaries.map(\.rawLogitBoundary) == [0.0, 2.5])
    }
}

@Suite("Calibration boundary sets")
struct CalibrationBoundarySetTests {
    @Test("A decisive region is never the insufficient outcome")
    func decisiveRegionIsNeverAbstention() throws {
        let sides: [(String, CategoryBoundary)] = [
            (
                "lowerDecision",
                try Sample.boundary(lower: .notEnoughSignal, upper: .noStrongSignalDetected)
            ),
            (
                "upperDecision",
                try Sample.boundary(lower: .noStrongSignalDetected, upper: .notEnoughSignal)
            ),
        ]
        for (side, boundary) in sides {
            rejects("activation.calibrationPolicy.boundaries.\(side) value not-enough-signal") {
                _ = try Sample.activate(try Sample.activatablePolicy(boundaries: [boundary]))
            }
        }
    }

    @Test("Two boundaries cannot sit at the same raw-logit value")
    func duplicateBoundaryPositionRejected() throws {
        let first = try Sample.boundary(position: 1.0)
        let second = try Sample.boundary(
            position: 1.0,
            lower: .signalsConsistentWithAIGeneration,
            upper: .noStrongSignalDetected
        )

        rejects("boundaries declares \"1.0\" more than once") {
            _ = try Sample.activate(try Sample.activatablePolicy(boundaries: [first, second]))
        }
    }

    @Test("Closed abstention bands must leave a decisive region between them")
    func touchingBandsRejected() throws {
        // Bands [0.7, 1.3] and [1.3, 1.9] share exactly one point, so the region
        // between the two boundaries is empty and its declared label is unreachable.
        let first = try Sample.boundary(position: 1.0, halfWidth: 0.3)
        let second = try Sample.boundary(
            position: 1.6,
            halfWidth: 0.3,
            lower: .signalsConsistentWithAIGeneration,
            upper: .noStrongSignalDetected
        )

        rejects("abstentionHalfWidth") {
            _ = try Sample.activate(try Sample.activatablePolicy(boundaries: [first, second]))
        }
    }

    @Test("Overlapping abstention bands are rejected")
    func overlappingBandsRejected() throws {
        let first = try Sample.boundary(position: 1.0, halfWidth: 0.5)
        let second = try Sample.boundary(
            position: 1.2,
            halfWidth: 0.5,
            lower: .signalsConsistentWithAIGeneration,
            upper: .noStrongSignalDetected
        )

        rejects("abstentionHalfWidth") {
            _ = try Sample.activate(try Sample.activatablePolicy(boundaries: [first, second]))
        }
    }

    @Test("Adjacent boundaries must agree about the region they share")
    func disagreeingAdjacentRegionsRejected() throws {
        // Both boundaries put the non-positive label above themselves, so the region
        // between them is non-positive by one and positive by the other.
        let first = try Sample.boundary(
            position: 0.0,
            lower: .noStrongSignalDetected,
            upper: .signalsConsistentWithAIGeneration
        )
        let second = try Sample.boundary(
            position: 2.0,
            lower: .noStrongSignalDetected,
            upper: .signalsConsistentWithAIGeneration
        )

        rejects("lowerDecision") {
            _ = try Sample.activate(try Sample.activatablePolicy(boundaries: [first, second]))
        }
    }

    @Test("A chained, separated multi-boundary set activates")
    func chainedBoundariesActivate() throws {
        let first = try Sample.boundary(
            position: 0.0,
            lower: .noStrongSignalDetected,
            upper: .signalsConsistentWithAIGeneration
        )
        let second = try Sample.boundary(
            position: 1.0,
            lower: .signalsConsistentWithAIGeneration,
            upper: .noStrongSignalDetected
        )

        let validated = try Sample.activate(
            try Sample.activatablePolicy(boundaries: [first, second])
        )
        #expect(validated.orderedBoundaries == [first, second])
    }
}

@Suite("Calibration evidence resolution")
struct CalibrationEvidenceResolutionTests {
    @Test("An index rejects an empty, repeated, or undecided record set")
    func indexRejectsUnusableRecords() throws {
        #expect(throws: ArtifactSchemaError.emptyValue(field: "evidenceIndex.records")) {
            try ReleaseEvidenceIndex(records: [])
        }
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseEvidenceIndex(
                records: [Sample.evidence("evidence.one"), Sample.evidence("evidence.one")]
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try ReleaseEvidenceIndex(records: [Sample.evidence("tbd")])
        }
    }

    @Test("A policy citing evidence the release does not carry is rejected")
    func missingEvidenceReferenceRejected() throws {
        rejects("evidence.absent") {
            _ = try Sample.activate(
                try Sample.activatablePolicy(
                    evidenceRecords: [Sample.evidence("evidence.absent")]
                )
            )
        }
    }

    @Test("A placeholder evidence reference is not a citation")
    func placeholderEvidenceReferenceRejected() throws {
        rejects("placeholder") {
            _ = try Sample.activate(
                try Sample.activatablePolicy(evidenceRecords: [Sample.evidence("tbd")])
            )
        }
    }

    @Test("An evidence citation must match the indexed version and content digest")
    func evidenceVersionAndDigestMustMatch() throws {
        let indexed = Sample.evidence("evidence.calibration")

        rejects("version") {
            _ = try Sample.activate(
                try Sample.activatablePolicy(
                    evidenceRecords: [
                        EvidenceSource(
                            artifact: indexed.artifact,
                            version: Sample.version("2.0.0"),
                            contentDigest: indexed.contentDigest
                        )
                    ]
                )
            )
        }
        rejects("contentDigest") {
            _ = try Sample.activate(
                try Sample.activatablePolicy(
                    evidenceRecords: [
                        EvidenceSource(
                            artifact: indexed.artifact,
                            version: indexed.version,
                            contentDigest: Sample.digest("b")
                        )
                    ]
                )
            )
        }
    }

    @Test("An abstention rule citing unresolvable evidence is rejected")
    func abstentionRuleEvidenceMustResolve() throws {
        let rule = try Sample.qualityRule(
            evidenceRecords: [Sample.evidence("evidence.never-produced")]
        )

        rejects("evidence.never-produced") {
            _ = try Sample.activate(
                try Sample.activatablePolicy(
                    qualityRules: [rule],
                    requiredQualityFeatures: [Sample.qualityFeature()]
                )
            )
        }
    }

    @Test("An index reports resolution without throwing")
    func indexResolutionIsQueryable() throws {
        let index = try Sample.evidenceIndex()

        #expect(index.resolves(Sample.evidence("evidence.calibration")))
        #expect(!index.resolves(Sample.evidence("evidence.absent")))
        #expect(index.record(for: Sample.artifact("evidence.quality")) != nil)
        #expect(index.record(for: Sample.artifact("evidence.absent")) == nil)
    }
}

@Suite("Calibration quality-rule coverage")
struct CalibrationQualityRuleCoverageTests {
    @Test("Every required quality feature must be reachable by a rule")
    func uncoveredRequiredFeatureRejected() throws {
        rejects("quality.short-edge") {
            _ = try Sample.activate(
                try Sample.activatablePolicy(
                    qualityRules: [],
                    requiredQualityFeatures: [Sample.qualityFeature()]
                )
            )
        }
    }

    @Test("A covered required feature activates")
    func coveredRequiredFeatureActivates() throws {
        let policy = try Sample.activatablePolicy(
            qualityRules: [try Sample.qualityRule()],
            requiredQualityFeatures: [Sample.qualityFeature()]
        )

        #expect(try Sample.activate(policy).policy == policy)
    }

    @Test("A usable measured value cannot produce the calibration input error")
    func measuredValueCannotProduceInputError() throws {
        let rule = try Sample.qualityRule(
            condition: .atOrBelow(10),
            outcome: .calibrationInputError,
            evidenceRecords: []
        )

        rejects("calibration-input-error") {
            _ = try Sample.activate(
                try Sample.activatablePolicy(
                    qualityRules: [rule],
                    requiredQualityFeatures: [Sample.qualityFeature()]
                )
            )
        }
    }

    @Test("Two rules on one feature cannot contradict each other")
    func contradictoryRulesRejected() throws {
        let abstain = try Sample.qualityRule(
            identifier: "rule.abstain",
            condition: .valueMissing,
            outcome: .insufficientSignal
        )
        let error = try Sample.qualityRule(
            identifier: "rule.error",
            condition: .valueMissing,
            outcome: .calibrationInputError,
            evidenceRecords: []
        )

        rejects("rule.error") {
            _ = try Sample.activate(
                try Sample.activatablePolicy(
                    qualityRules: [abstain, error],
                    requiredQualityFeatures: [Sample.qualityFeature()]
                )
            )
        }
    }

    @Test("Rules on different features never collide")
    func differentFeaturesDoNotCollide() throws {
        let other = Sample.qualityFeature("quality.other")
        let missing = try Sample.qualityRule(
            identifier: "rule.missing",
            condition: .valueMissing,
            outcome: .insufficientSignal
        )
        let otherFeature = try Sample.qualityRule(
            identifier: "rule.other",
            feature: other,
            condition: .valueMissing,
            outcome: .calibrationInputError,
            evidenceRecords: []
        )

        let policy = try Sample.activatablePolicy(
            qualityRules: [missing, otherFeature],
            requiredQualityFeatures: [Sample.qualityFeature(), other]
        )
        #expect(try Sample.activate(policy).policy == policy)
    }

    @Test("Disjoint conditions on one feature activate")
    func disjointConditionsActivate() throws {
        let missing = try Sample.qualityRule(
            identifier: "rule.missing",
            condition: .valueMissing,
            outcome: .insufficientSignal
        )
        let invalid = try Sample.qualityRule(
            identifier: "rule.invalid",
            condition: .valueInvalid,
            outcome: .calibrationInputError,
            evidenceRecords: []
        )
        let low = try Sample.qualityRule(
            identifier: "rule.low",
            condition: .atOrBelow(10),
            outcome: .insufficientSignal
        )

        let policy = try Sample.activatablePolicy(
            qualityRules: [missing, invalid, low],
            requiredQualityFeatures: [Sample.qualityFeature()]
        )
        #expect(try Sample.activate(policy).policy == policy)
    }

    @Test("Overlapping conditions that agree on the outcome activate")
    func agreeingOverlapActivates() throws {
        let low = try Sample.qualityRule(
            identifier: "rule.low",
            condition: .atOrBelow(10),
            outcome: .insufficientSignal
        )
        let lower = try Sample.qualityRule(
            identifier: "rule.lower",
            condition: .atOrBelow(5),
            outcome: .insufficientSignal
        )

        let policy = try Sample.activatablePolicy(
            qualityRules: [low, lower],
            requiredQualityFeatures: [Sample.qualityFeature()]
        )
        #expect(try Sample.activate(policy).policy == policy)
    }
}

@Suite("Quality condition overlap")
struct QualityConditionOverlapTests {
    @Test("Absent, unusable, and measured are three disjoint observations")
    func unusableObservationsAreDisjoint() {
        #expect(QualityCondition.valueMissing.canMatchSameObservation(as: .valueMissing))
        #expect(QualityCondition.valueInvalid.canMatchSameObservation(as: .valueInvalid))
        #expect(!QualityCondition.valueMissing.canMatchSameObservation(as: .valueInvalid))
        #expect(!QualityCondition.valueMissing.canMatchSameObservation(as: .atOrBelow(1)))
        #expect(!QualityCondition.valueInvalid.canMatchSameObservation(as: .atOrAbove(1)))
    }

    @Test("Threshold conditions overlap exactly when their regions intersect")
    func thresholdOverlap() {
        #expect(QualityCondition.atOrBelow(5).canMatchSameObservation(as: .atOrAbove(5)))
        #expect(!QualityCondition.atOrBelow(5).canMatchSameObservation(as: .atOrAbove(6)))
        #expect(QualityCondition.atOrBelow(5).canMatchSameObservation(as: .atOrBelow(100)))
        #expect(QualityCondition.atOrAbove(5).canMatchSameObservation(as: .atOrAbove(100)))
    }

    @Test("An outside-range condition is unbounded on both sides")
    func outsideRangeOverlap() {
        let outside = QualityCondition.outsideClosedRange(lower: 10, upper: 20)

        #expect(outside.canMatchSameObservation(as: .atOrBelow(5)))
        #expect(outside.canMatchSameObservation(as: .atOrAbove(50)))
        // 0 is below the range's lower bound, so even a threshold inside the range
        // shares observations with it.
        #expect(outside.canMatchSameObservation(as: .atOrBelow(15)))
        #expect(outside.canMatchSameObservation(as: .outsideClosedRange(lower: 0, upper: 1)))
        #expect(!outside.canMatchSameObservation(as: .valueMissing))
    }
}

@Suite("Calibration and Model Bundle compatibility")
struct CalibrationBundleCompatibilityTests {
    @Test("The bundle must name this exact Calibration Policy")
    func bundleMustNameThePolicy() throws {
        rejects("activation.modelBundle.componentVersions.calibrationPolicy") {
            _ = try Sample.activate(try Sample.activatablePolicy(identifier: "policy.other"))
        }
    }

    @Test("The policy's preprocessing contract must be the bundle's")
    func preprocessingMustMatch() throws {
        rejects("activation.calibrationPolicy.compatiblePreprocessing") {
            _ = try Sample.activate(
                try Sample.activatablePolicy(compatiblePreprocessing: "contract.other")
            )
        }
    }

    @Test("The policy's verdict-copy compatibility must be the bundle's")
    func verdictCopyMustMatch() throws {
        rejects("activation.calibrationPolicy.compatibleVerdictCopy") {
            _ = try Sample.activate(
                try Sample.activatablePolicy(compatibleVerdictCopy: "copy.other")
            )
        }
    }

    @Test("A policy calibrated on another model cannot activate")
    func modelIdentityMustMatch() throws {
        let otherModel = ModelIdentity(
            checkpointIdentifier: try #require(ModelCheckpointIdentifier("Other/model-2026-01")),
            requiredWeightDigest: Sample.digest("f")
        )

        rejects("activation.calibrationPolicy.compatibleModel") {
            _ = try Sample.activate(try Sample.activatablePolicy(compatibleModel: otherModel))
        }
    }
}
