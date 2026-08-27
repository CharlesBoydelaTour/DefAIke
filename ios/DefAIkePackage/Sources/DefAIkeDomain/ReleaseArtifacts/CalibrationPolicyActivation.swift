import Foundation

// Activation-time validation of a Calibration Policy.
//
// This is the fourth fail-closed layer, and it exists because the first three cannot
// see what it checks:
//
//   * ``ArtifactEncodingProfile`` bounds the encoded bytes.
//   * ``CalibrationPolicy`` validates one artifact field by field: one budget no
//     greater than 1%, exactly the three labels and their fixed metric categories, a
//     finite half-width of at least 0.131 per boundary, the sub-440 rule, the
//     `calibration-input-error` rule for an uncovered required value, a nonempty
//     evidence list behind every abstention rule, and `1.390625` as metadata.
//   * ``ReleaseConfiguration`` resolves the policy's references inside the *policy*
//     set: the bound preprocessing contract, the bound verdict-copy compatibility
//     identifier, and the sole permitted model identity.
//
// What none of them can decide:
//
//   * whether the boundary *set* maps every finite logit to exactly one label. Each
//     boundary is individually valid while two of them overlap, contradict, or leave
//     a region no rule covers.
//   * whether the evidence a rule cites exists. A nonempty list of references is not
//     a resolved reference; Requirements 5.11 and 5.12 are about evidence that is
//     actually there.
//   * whether the policy matches the *Model Bundle* it would be activated with.
//     Requirement 5.13 is the Model Bundle Manager's rejection, and the bundle
//     manifest is not part of the policy set.
//   * whether every required quality feature is reachable by a rule, and whether a
//     rule's outcome is one the requirements permit for the condition it matches.
//
// ``ValidatedCalibrationPolicy`` is the only way to hold a policy that passed all of
// it, so "validated Calibration Policy" in Requirement 5.13 is a type rather than a
// convention. Nothing here chooses a boundary, a budget, a half-width, an additional
// quality rule, or an evidence record: it rejects sets that cannot be evaluated
// deterministically.

// MARK: - Release evidence index

/// The approved release evidence a policy's references may resolve to.
///
/// Requirement 5.11 binds every additional quality condition to release-validation
/// evidence and Requirement 5.12 rejects a policy whose condition lacks it. A
/// reference is only evidence if the release carries the artifact it names, at the
/// version and content digest it names, so validation needs the index as a required
/// input. There is no empty default and no "assume present" path: without an index no
/// policy can be activated at all.
public struct ReleaseEvidenceIndex: Hashable, Sendable {
    private let records: [ArtifactID: EvidenceSource]

    /// Builds the index, rejecting an empty set, a repeated artifact, or an
    /// undecided artifact reference.
    ///
    /// One artifact resolves to one approved version. Two records for the same
    /// artifact would let two references to "the same" evidence read as different
    /// content, which is the ambiguity a signed release exists to remove.
    public init(records: [EvidenceSource]) throws {
        try ArtifactSchemaValidation.requireNonEmpty(records, field: "evidenceIndex.records")
        try ArtifactSchemaValidation.requireUniqueKeys(
            records.map(\.artifact.rawValue),
            field: "evidenceIndex.records"
        )
        for record in records {
            try ArtifactSchemaValidation.requireDecidedReference(
                record.artifact,
                field: "evidenceIndex.records.artifact"
            )
        }
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.artifact, $0) })
    }

    /// The indexed record for one artifact, or `nil` when this release carries none.
    public func record(for artifact: ArtifactID) -> EvidenceSource? { records[artifact] }

    /// Whether `reference` names evidence this release carries at exactly that
    /// version and content digest.
    public func resolves(_ reference: EvidenceSource) -> Bool {
        records[reference.artifact] == reference
    }

    /// Requires `reference` to resolve, naming the specific disagreement otherwise.
    ///
    /// A wrong version or a wrong digest is a different audit finding from a
    /// reference to evidence that does not exist, so the two are reported
    /// separately rather than as one "invalid evidence".
    public func requireResolved(_ reference: EvidenceSource, field: String) throws {
        try ArtifactSchemaValidation.requireDecidedReference(
            reference.artifact,
            field: "\(field).artifact"
        )
        guard let indexed = records[reference.artifact] else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: field,
                keys: [reference.artifact.rawValue]
            )
        }
        guard indexed.version == reference.version else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).version",
                expected: indexed.version.description,
                found: reference.version.description
            )
        }
        guard indexed.contentDigest == reference.contentDigest else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).contentDigest",
                expected: indexed.contentDigest.hexadecimalString,
                found: reference.contentDigest.hexadecimalString
            )
        }
    }
}

// MARK: - Quality condition overlap

extension QualityCondition {
    /// One contiguous region of the ordered measured-value line.
    ///
    /// `Decimal` has no infinity, so an unbounded end is `nil` rather than a
    /// sentinel value a comparison could accidentally treat as a real threshold.
    private struct MeasuredRegion {
        let lower: Decimal?
        let lowerInclusive: Bool
        let upper: Decimal?
        let upperInclusive: Bool

        func intersects(_ other: MeasuredRegion) -> Bool {
            if let lower, let otherUpper = other.upper {
                if lower > otherUpper { return false }
                if lower == otherUpper, !(lowerInclusive && other.upperInclusive) { return false }
            }
            if let upper, let otherLower = other.lower {
                if otherLower > upper { return false }
                if otherLower == upper, !(upperInclusive && other.lowerInclusive) { return false }
            }
            return true
        }
    }

    /// The measured-value regions this condition matches, or an empty array when it
    /// matches an absent or unusable value instead of a measured one.
    private var measuredRegions: [MeasuredRegion] {
        switch self {
        case .valueMissing, .valueInvalid:
            return []
        case let .atOrBelow(threshold):
            return [
                MeasuredRegion(
                    lower: nil,
                    lowerInclusive: false,
                    upper: threshold,
                    upperInclusive: true
                )
            ]
        case let .atOrAbove(threshold):
            return [
                MeasuredRegion(
                    lower: threshold,
                    lowerInclusive: true,
                    upper: nil,
                    upperInclusive: false
                )
            ]
        case let .outsideClosedRange(lower, upper):
            return [
                MeasuredRegion(
                    lower: nil,
                    lowerInclusive: false,
                    upper: lower,
                    upperInclusive: false
                ),
                MeasuredRegion(
                    lower: upper,
                    lowerInclusive: false,
                    upper: nil,
                    upperInclusive: false
                ),
            ]
        }
    }

    /// Whether this condition matches only an absent or unusable value.
    var matchesUnusableValue: Bool {
        switch self {
        case .valueMissing, .valueInvalid: true
        case .atOrBelow, .atOrAbove, .outsideClosedRange: false
        }
    }

    /// Whether one observation of the same feature can match both conditions.
    ///
    /// Absent, unusable, and measured are three disjoint observations, so a missing
    /// rule and a threshold rule never collide. Two threshold rules collide exactly
    /// when their matched regions intersect.
    func canMatchSameObservation(as other: QualityCondition) -> Bool {
        switch (self, other) {
        case (.valueMissing, .valueMissing), (.valueInvalid, .valueInvalid):
            return true
        case (.valueMissing, _), (_, .valueMissing), (.valueInvalid, _), (_, .valueInvalid):
            return false
        default:
            for region in measuredRegions {
                for otherRegion in other.measuredRegions where region.intersects(otherRegion) {
                    return true
                }
            }
            return false
        }
    }

    /// Bounded rendering for an audit message. Not user-facing copy.
    var auditDescription: String {
        switch self {
        case .valueMissing: "value-missing"
        case .valueInvalid: "value-invalid"
        case let .atOrBelow(threshold): "at-or-below \(threshold)"
        case let .atOrAbove(threshold): "at-or-above \(threshold)"
        case let .outsideClosedRange(lower, upper): "outside \(lower)...\(upper)"
        }
    }
}

// MARK: - Validated policy

/// A Calibration Policy that passed activation validation against one Model Bundle.
///
/// Holding this value means every Requirement 5 activation condition was checked:
/// the field-level ones by ``CalibrationPolicy`` itself, which cannot represent a
/// budget above 1%, a label set other than the three fixed labels, a metric category
/// other than the fixed one, a nonfinite or under-0.131 half-width, a weakened
/// sub-440 rule, an abstention rule with no evidence list, an uncovered required
/// value that silently abstains, or an upstream boundary that is not `1.390625`
/// metadata; and the set-level ones here.
public struct ValidatedCalibrationPolicy: Hashable, Sendable {
    /// The policy, unchanged. Validation never repairs, normalizes, or fills a field.
    public let policy: CalibrationPolicy

    /// The Model Bundle this policy was validated as compatible with.
    public let modelBundle: ModelBundleID

    /// The boundaries in ascending raw-logit order, verified to leave every finite
    /// logit with exactly one decisive label or one closed abstention band.
    ///
    /// Evaluating a logit against them is a separate concern and belongs to the
    /// calibration evaluator; this is the validated schedule it reads.
    public let orderedBoundaries: [CategoryBoundary]

    /// Validates `policy` for activation with `bundle`.
    ///
    /// Fails closed with one ``ArtifactSchemaError`` naming the offending field, so a
    /// release audit can point at one position rather than reporting "invalid policy".
    /// A failure is never an ``AnalysisError``: a policy that does not activate keeps
    /// the affected bundle unusable instead of producing a user-facing verdict.
    public init(
        activating policy: CalibrationPolicy,
        for bundle: ModelBundleManifest,
        evidence index: ReleaseEvidenceIndex
    ) throws {
        try Self.validateCompatibility(policy, with: bundle)
        try Self.validateEvidence(policy, against: index)
        try Self.validateQualityRules(policy)
        self.orderedBoundaries = try Self.validatedBoundarySchedule(policy)
        self.policy = policy
        self.modelBundle = bundle.bundleID
    }

    /// The policy's artifact identifier, for a session binding or an audit record.
    public var id: ArtifactID { policy.id }

    // MARK: Compatibility

    /// Requirement 5.13: the bundle and the policy describe one unit.
    ///
    /// The Model Bundle Manager rejects a bundle whose named Calibration Policy is not
    /// this policy, whose preprocessing contract or verdict-copy compatibility
    /// identifier the policy was not calibrated against, or whose model is not the one
    /// the policy was calibrated on. Each is a combination in which measured
    /// calibration evidence describes different code or different pixels than the
    /// build would run.
    ///
    /// Requirement 5.14 needs nothing here: ``UpstreamBoundaryMetadata`` is the only
    /// way either side can carry the upstream value, and it admits exactly `1.390625`
    /// in the metadata-only role, so the two cannot disagree and neither can become a
    /// product-verdict boundary.
    private static func validateCompatibility(
        _ policy: CalibrationPolicy,
        with bundle: ModelBundleManifest
    ) throws {
        try ArtifactSchemaValidation.requireMatchingReference(
            bundle.componentVersions.calibrationPolicy,
            matches: policy.id,
            field: "activation.modelBundle.componentVersions.calibrationPolicy"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            policy.compatiblePreprocessing,
            matches: bundle.componentVersions.preprocessingContract,
            field: "activation.calibrationPolicy.compatiblePreprocessing"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            policy.compatibleVerdictCopy,
            matches: bundle.componentVersions.verdictCopyCompatibility,
            field: "activation.calibrationPolicy.compatibleVerdictCopy"
        )
        guard policy.compatibleModel == bundle.modelIdentity else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "activation.calibrationPolicy.compatibleModel",
                expected: bundle.modelIdentity.checkpointIdentifier.rawValue,
                found: policy.compatibleModel.checkpointIdentifier.rawValue
            )
        }
    }

    // MARK: Evidence

    /// Requirements 5.11 and 5.12: every citation resolves to evidence that exists.
    ///
    /// The schema requires an abstention rule to carry a nonempty evidence list.
    /// Activation requires each entry in that list, and each entry of the policy's own
    /// held-out calibration evidence, to name an artifact this release carries at
    /// exactly the version and digest cited. A rule citing evidence that is absent, a
    /// different version, or different content is the unevidenced abstention rule
    /// Requirement 5.12 rejects.
    private static func validateEvidence(
        _ policy: CalibrationPolicy,
        against index: ReleaseEvidenceIndex
    ) throws {
        for (offset, record) in policy.evidence.enumerated() {
            try index.requireResolved(
                record,
                field: "activation.calibrationPolicy.evidence[\(offset)]"
            )
        }
        for rule in policy.qualityRules {
            for (offset, record) in rule.evidence.enumerated() {
                try index.requireResolved(
                    record,
                    field: """
                        activation.calibrationPolicy.qualityRules[\(rule.id.rawValue)]\
                        .evidence[\(offset)]
                        """
                )
            }
        }
    }

    // MARK: Quality rules

    /// Every required feature is reachable, every rule is unambiguous, and no rule
    /// turns a valid measurement into an input error.
    ///
    /// Three faults the per-artifact schema cannot see:
    ///
    ///   * A required feature with no rule. The policy would demand a measurement
    ///     that can only ever produce `calibration-input-error` and can never affect
    ///     a label, which is a required-feature behavior no requirement describes.
    ///     A quality rule is the only thing that consumes a feature today; if an
    ///     approved policy later selects a boundary by quality tier (Requirement 5.6),
    ///     a feature consumed that way counts as covered and belongs in this check.
    ///   * Two rules on one feature that match the same observation with different
    ///     outcomes. Requirement 5.10 requires each insufficient outcome to come from
    ///     a deterministic rule, and a contradictory pair is not deterministic.
    ///   * A `calibration-input-error` outcome on a measured-value condition.
    ///     Requirement 5.4 maps every finite logit and validated record to one of the
    ///     three labels, and Requirement 5.25 reserves that error for a required value
    ///     that is missing or invalid, so a present, usable value may not produce it.
    private static func validateQualityRules(_ policy: CalibrationPolicy) throws {
        let covered = Set(policy.qualityRules.map(\.feature))
        let uncovered = policy.requiredQualityFeatures.subtracting(covered)
        guard uncovered.isEmpty else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: "activation.calibrationPolicy.qualityRules",
                keys: uncovered.map(\.rawValue).sorted()
            )
        }

        for rule in policy.qualityRules
        where rule.outcome == .calibrationInputError && !rule.condition.matchesUnusableValue {
            throw ArtifactSchemaError.forbiddenValue(
                field: "activation.calibrationPolicy.qualityRules[\(rule.id.rawValue)].outcome",
                value: rule.outcome.rawValue,
                reason: """
                    a present, usable measured value maps to one of the three labels; \
                    the input error is reserved for a missing or invalid required value
                    """
            )
        }

        for (offset, rule) in policy.qualityRules.enumerated() {
            for other in policy.qualityRules[policy.qualityRules.index(after: offset)...]
            where rule.feature == other.feature
                && rule.outcome != other.outcome
                && rule.condition.canMatchSameObservation(as: other.condition)
            {
                throw ArtifactSchemaError.forbiddenValue(
                    field: """
                        activation.calibrationPolicy.qualityRules[\(other.id.rawValue)]\
                        .condition
                        """,
                    value: other.condition.auditDescription,
                    reason: """
                        it can match the same \(other.feature.rawValue) observation as \
                        rule \(rule.id.rawValue) (\(rule.condition.auditDescription)) with a \
                        different outcome
                        """
                )
            }
        }
    }

    // MARK: Boundaries

    /// Requirement 5.7 and the totality Requirement 5.4 depends on: the boundary set
    /// is finite, nonambiguous, and leaves no region undecided.
    ///
    /// Sorted ascending, the boundaries must satisfy three set-level rules that no
    /// single boundary can:
    ///
    ///   * No decisive side may be the insufficient outcome. Requirement 5.10 derives
    ///     every insufficient result from a rule — a closed abstention band, the
    ///     sub-440 rule, or an evidenced quality rule — so an unconditional
    ///     abstention region is not one of them.
    ///   * Two boundaries may not sit at the same raw-logit value, and their closed
    ///     abstention bands may not touch or overlap. Overlapping bands leave the
    ///     decisive region between them empty, so a declared decision could never be
    ///     produced, and a logit in two bands belongs to two rules.
    ///   * Adjacent boundaries must agree about the region they share. Otherwise the
    ///     same logit carries two labels, which is exactly the ambiguity that would
    ///     let one input produce two verdicts.
    ///
    /// Those three together make the finite logit line a partition: below the first
    /// boundary, one region between each adjacent pair, above the last, plus the
    /// disjoint closed bands. Direction and count stay release decisions.
    private static func validatedBoundarySchedule(
        _ policy: CalibrationPolicy
    ) throws -> [CategoryBoundary] {
        let ordered = policy.boundaries.sorted { $0.rawLogitBoundary < $1.rawLogitBoundary }

        for boundary in ordered {
            for (side, label) in [
                ("lowerDecision", boundary.lowerDecision),
                ("upperDecision", boundary.upperDecision),
            ] where label == .notEnoughSignal {
                throw ArtifactSchemaError.forbiddenValue(
                    field: "activation.calibrationPolicy.boundaries.\(side)",
                    value: label.rawValue,
                    reason: """
                        an insufficient outcome comes from a closed abstention band, the \
                        sub-440 rule, or an evidenced quality rule, never from a decisive \
                        region
                        """
                )
            }
        }

        for (offset, boundary) in ordered.enumerated().dropFirst() {
            let previous = ordered[offset - 1]
            guard previous.rawLogitBoundary != boundary.rawLogitBoundary else {
                throw ArtifactSchemaError.duplicateEntry(
                    field: "activation.calibrationPolicy.boundaries",
                    key: "\(boundary.rawLogitBoundary)"
                )
            }
            guard previous.abstentionUpperBound < boundary.abstentionLowerBound else {
                throw ArtifactSchemaError.valueOutOfRange(
                    field: "activation.calibrationPolicy.boundaries.abstentionHalfWidth",
                    value: """
                        band \(previous.abstentionLowerBound)...\(previous.abstentionUpperBound) \
                        meets band \(boundary.abstentionLowerBound)...\
                        \(boundary.abstentionUpperBound)
                        """,
                    allowed: "closed abstention bands that leave a decisive region between them"
                )
            }
            guard previous.upperDecision == boundary.lowerDecision else {
                throw ArtifactSchemaError.inconsistentReference(
                    field: """
                        activation.calibrationPolicy.boundaries\
                        [\(boundary.rawLogitBoundary)].lowerDecision
                        """,
                    expected: previous.upperDecision.rawValue,
                    found: boundary.lowerDecision.rawValue
                )
            }
        }

        return ordered
    }
}
