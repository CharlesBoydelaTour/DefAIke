import Foundation

// The calibration release-approval gate.
//
// This is the layer above ``ReleaseSliceMeasurement``, and it answers the questions one
// slice cannot: whether the populations behind the policy were separated, whether the
// mandatory slice set is the predeclared one and includes the contemporary phone-camera
// real slice, whether every recorded report is the measurement it claims to be, and
// whether every mandatory slice actually satisfied the predeclared budget rule. Holding
// an ``ApprovedCalibrationRelease`` is what "this bundle-policy combination is approved
// for distribution on calibration grounds" means; there is no partial form, because
// Requirements 5.22 and 5.23 block the affected combination rather than downgrade it.
//
// What the layers below cannot decide:
//
//   * ``CalibrationPolicy`` validates one artifact, and ``ValidatedCalibrationPolicy``
//     validates the boundary set, the evidence citations, and compatibility with one
//     Model Bundle. Neither has any dataset in view, so neither can see contamination.
//   * ``ReleaseSliceMeasurement`` measures one slice against one policy. It cannot know
//     whether the slice set is complete, whether the mandatory phone-camera slice is in
//     it, or whether a recorded report describes the run it came from — those need the
//     whole set at once.
//   * ``DatasetLineageRecord`` carries separation *results*. A record with one passing
//     pair in it is a syntactically valid record and covers none of the other two pairs.
//
// # What the separation check actually proves, and what it does not
//
// Requirement 5.5 requires sample-level *and content-level* separation among the three
// populations, and Requirement 5.23 rejects the policy when either level is missing or
// fails. This module holds no corpus: it has no image, no identifier list, and no content
// hash, so it cannot compare two populations itself. What it can do, and does, is refuse
// every way the *record* of that comparison falls short:
//
//   * a population pair with no recorded result at all, or a second contradictory result
//     for the same pair — every one of the three unordered pairs has to appear exactly
//     once, so a lineage record covering only the pair someone cared about is refused;
//   * a pair whose sample-level or content-level outcome is anything but a pass, `not
//     executed` included, because an unrun comparison is not a passed one;
//   * a pair whose cited evidence does not resolve to an artifact this release carries at
//     the cited version and digest, so a recorded pass with no findable evidence behind it
//     is refused rather than believed;
//   * a missing corrected-identifier record or duplicate-content-hash disposition, which
//     are the two artifacts that make a content-level claim checkable by anyone at all
//     (Requirements 14.7 and 14.8).
//
// So the honest statement is: **this gate proves that the release recorded, evidenced, and
// passed a content-level separation verification for every population pair. It does not
// re-perform the content comparison, and it cannot.** Whether the cited verification was
// competent is a property of the cited artifact, not of this code, which is exactly why
// the citation has to resolve before the recorded pass counts for anything.
//
// One disjointness fact *is* decided here rather than read, because the artifacts support
// it: Requirement 5.6 requires the boundaries to come from held-out calibration data
// separate from the product-threshold evaluation data, and both sides are named by
// artifact. If one artifact is cited both as the policy's held-out calibration evidence
// and as a mandatory slice's dataset composition, then one record describes both
// populations and they are not separate. That check is identifier-level: it catches the
// two roles naming one artifact, and it cannot catch two differently named artifacts that
// happen to share images. The recorded content-level verification above is what covers
// the second case.
//
// # What this file deliberately does not do
//
// It chooses no threshold, budget, additional quality rule, interval, interval method, or
// confidence level. The budget and the pass rule are read from the validated policy, the
// interval and its method were predeclared on the slice and consumed by
// ``ReleaseSliceMeasurement``, and this file names no ``ConfidenceIntervalMethod`` case
// and constructs no ``ConfidenceIntervalResult`` — the source audit in the slice-metric
// tests asserts that for the whole module. It also reaches no legal, governance, device,
// or bundle-integrity conclusion: those are separate gates, and ``EligibleRelease`` is
// where a distribution decision is assembled from all of them.

// MARK: - Population pairs

extension CalibrationPopulation {
    /// Every unordered pair of distinct populations Requirement 5.5 requires separated.
    ///
    /// Derived from ``CaseIterable`` rather than listed, so adding a population makes the
    /// required pair set grow instead of leaving the new population unchecked.
    static var requiredSeparationPairs: [Set<CalibrationPopulation>] {
        let populations = allCases
        var pairs: [Set<CalibrationPopulation>] = []
        for (offset, first) in populations.enumerated() {
            for second in populations[populations.index(after: offset)...] {
                pairs.append([first, second])
            }
        }
        return pairs
    }

    /// A stable key for one unordered pair, for coverage checks and audit messages.
    ///
    /// Sorted, so the same two populations produce one key whichever order a record
    /// happens to list them in — otherwise a release could satisfy the coverage check
    /// twice for one pair and never for another.
    static func pairKey(_ pair: Set<CalibrationPopulation>) -> String {
        pair.map(\.rawValue).sorted().joined(separator: "|")
    }
}

extension PopulationSeparationResult {
    /// The unordered pair this result answers for.
    var pair: Set<CalibrationPopulation> { [firstPopulation, secondPopulation] }
}

extension ReleaseSliceMeasurement {
    /// Whether both ground-truth populations are nonempty, so every rate Requirement 5.19
    /// reports has a measured value.
    ///
    /// A ``CalibrationSliceResult`` states each rate as a required ``UnitInterval``, so it
    /// can only describe a slice for which this is true.
    var statesEveryMeasuredRate: Bool {
        falsePositiveRate != nil && truePositiveRate != nil
    }
}

// MARK: - Approved calibration release

/// A Model Bundle and Calibration Policy combination whose calibration evidence is
/// complete, uncontaminated, and passing.
///
/// Holding this value means every one of the following was checked, and any single
/// failure refused construction outright:
///
///   * All three population pairs carry a recorded sample-level and content-level
///     separation pass, each citing evidence this release resolves (Requirements 5.5 and
///     5.23), the policy's own held-out calibration evidence resolves in this release's
///     index (Requirements 5.11 and 5.12), and no artifact serves as both held-out
///     calibration evidence and a slice's evaluation dataset composition (Requirement 5.6).
///   * The measured slice set is exactly the predeclared mandatory set, each measurement
///     carries the predeclared specification unchanged, and at least one slice is the
///     contamination-controlled contemporary phone-camera real-image subset with a
///     nonempty real population (Requirements 5.15 and 5.20).
///   * Every measurement was taken against *this* validated policy and its Model Bundle,
///     and every predeclared reference on every slice resolves in this release's evidence
///     index.
///   * Every recorded ``CalibrationSliceResult`` is the measurement it claims to be, and
///     one exists for every mandatory slice it can describe without fabricating a number.
///   * Every mandatory slice satisfied the predeclared False Accusation Budget pass rule
///     (Requirement 5.22), and a slice the rule could not be applied to blocks rather
///     than passes.
///
/// Construction refuses rather than reporting a status, for the same reason
/// ``EligibleRelease`` does: Requirements 5.22 and 5.23 block the affected Model Bundle
/// and application combination, and there is no reduced calibration a release falls back
/// to. What blocks it stays readable on the inputs, which are unchanged.
public struct ApprovedCalibrationRelease: Hashable, Sendable {
    /// The validated policy this approval answers for, unchanged.
    ///
    /// Holding a ``ValidatedCalibrationPolicy`` is already the Requirement 5.13 exact
    /// compatibility guarantee — it cannot exist without matching one Model Bundle
    /// manifest's calibration policy, preprocessing contract, verdict-copy compatibility
    /// identifier, and model identity — so approval reads that fact rather than
    /// re-deriving it from a manifest.
    public let policy: ValidatedCalibrationPolicy

    /// The dataset lineage record whose separation results were verified.
    public let lineage: DatasetLineageRecord

    /// The mandatory slice measurements, ordered by slice identifier.
    ///
    /// Ordered so an audit trail is reproducible: the measurements arrive as a list and
    /// Swift `Set` iteration order is not stable across processes.
    public let measurements: [ReleaseSliceMeasurement]

    /// The recorded slice reports that reconciled against those measurements, ordered by
    /// slice identifier.
    ///
    /// Possibly shorter than ``measurements``: see ``ApprovedCalibrationRelease/init``.
    public let reports: [CalibrationSliceResult]

    /// Approves one bundle-policy combination on calibration grounds, or refuses.
    ///
    /// Fails closed with one ``ArtifactSchemaError`` naming the offending slice, pair, or
    /// field, so an audit can point at one position rather than reporting "calibration
    /// blocked". A failure is never an ``AnalysisError``: an unapproved combination is not
    /// distributed, rather than producing anything a user could see.
    ///
    /// `predeclaredMandatorySlices` is the authority for what the mandatory set is
    /// (Requirement 5.15 predeclares it before evaluation begins), and `measurements` has
    /// to cover it exactly. `recordedReports` are the recorded ``CalibrationSliceResult``
    /// artifacts this release carries.
    ///
    /// **Why a report is required for some slices and refused for others.** Requirement
    /// 5.19 requires the false-positive rate, true-positive rate, coverage, error count,
    /// composition, degradation condition, and interval reported for *every* mandatory
    /// slice, and every mandatory slice here has all of that in its
    /// ``ReleaseSliceMeasurement`` — including a rate that is absent because its
    /// ground-truth population is empty. ``CalibrationSliceResult`` cannot express that:
    /// each rate is a required ``UnitInterval``, so a record for a slice with an empty
    /// population would have to put a number where no image was examined. Requirement 5.20
    /// makes a real-image-only slice mandatory, so this is not a hypothetical. The
    /// resolution is that a recorded report is required for every mandatory slice it can
    /// describe truthfully and refused for the rest, and the measurement is the complete
    /// report in both cases. Fabricating a rate would be worse than omitting the redundant
    /// record.
    public init(
        approving policy: ValidatedCalibrationPolicy,
        predeclaredMandatorySlices predeclared: [ReleaseGatingSliceSpecification],
        measurements: [ReleaseSliceMeasurement],
        recordedReports: [CalibrationSliceResult],
        lineage: DatasetLineageRecord,
        evidence index: ReleaseEvidenceIndex
    ) throws {
        try Self.validateSeparation(lineage, against: index)
        let ordered = try Self.validatedSliceSet(
            predeclared: predeclared,
            measurements: measurements,
            policy: policy,
            against: index
        )
        try Self.validateHeldOutCalibrationEvidence(
            policy,
            measurements: ordered,
            against: index
        )
        let reports = try Self.reconciled(
            recordedReports,
            with: ordered,
            policy: policy,
            against: index
        )
        try Self.validateBudgetOutcomes(ordered, policy: policy)

        self.policy = policy
        self.lineage = lineage
        self.measurements = ordered
        self.reports = reports
    }

    // MARK: Separation

    /// Requirements 5.5, 5.23, 14.7, and 14.8: the separation verification was performed,
    /// evidenced, and passed for every population pair.
    ///
    /// Coverage is required to be exact rather than merely present. A record listing one
    /// pair twice would let a second, contradictory result for that pair sit beside a
    /// passing one, and a record listing a pair the vocabulary does not contain is a record
    /// this build cannot interpret — ``ArtifactSchemaValidation/requireExactCoverage``
    /// reports the missing, duplicated, and unexpected cases separately, which is what an
    /// audit needs to hear.
    ///
    /// Both levels are checked separately and neither is derived from the other.
    /// Requirement 5.5 names them as two verifications: identical sample identifiers and
    /// identical content are different kinds of contamination, and a release that checked
    /// only identifiers has not established content-level separation.
    private static func validateSeparation(
        _ lineage: DatasetLineageRecord,
        against index: ReleaseEvidenceIndex
    ) throws {
        try ArtifactSchemaValidation.requireDecidedReference(
            lineage.id,
            field: "approval.datasetLineage.id"
        )
        let field = "approval.datasetLineage.separationResults"
        try ArtifactSchemaValidation.requireExactCoverage(
            lineage.separationResults.map { CalibrationPopulation.pairKey($0.pair) },
            required: Set(
                CalibrationPopulation.requiredSeparationPairs.map(CalibrationPopulation.pairKey)
            ),
            field: field
        )

        for result in lineage.separationResults.sorted(by: {
            CalibrationPopulation.pairKey($0.pair) < CalibrationPopulation.pairKey($1.pair)
        }) {
            let pair = "\(field)[\(CalibrationPopulation.pairKey(result.pair))]"
            try index.requireResolved(result.evidence, field: "\(pair).evidence")
            for (level, outcome) in [
                ("sampleLevelOutcome", result.sampleLevelOutcome),
                ("contentLevelOutcome", result.contentLevelOutcome),
            ] where !outcome.isPassing {
                throw ArtifactSchemaError.forbiddenValue(
                    field: "\(pair).\(level)",
                    value: outcome.rawValue,
                    reason: """
                        missing or failed sample-level or content-level separation rejects \
                        the affected Calibration Policy
                        """
                )
            }
        }

        for (name, reference) in [
            ("identifierCorrection", lineage.identifierCorrection),
            ("duplicateHashDisposition", lineage.duplicateHashDisposition),
        ] {
            try index.requireResolved(
                reference,
                field: "approval.datasetLineage.\(name)"
            )
        }
    }

    /// Requirements 5.6, 5.11, and 5.12: the calibration evidence exists in *this* release,
    /// and it is not the product-threshold evaluation data.
    ///
    /// The resolution half is not a repeat of activation. ``ValidatedCalibrationPolicy``
    /// required these references to resolve against the index it was handed and keeps no
    /// record of which index that was, so a policy activated against one release's evidence
    /// can be presented for approval alongside another's. Requiring them again here is what
    /// makes "the release carries the evidence" a fact about the release being approved.
    ///
    /// The disjointness half is decided from the artifacts rather than read from a recorded
    /// outcome, because here the artifacts say enough on their own.
    /// ``CalibrationPolicy/evidence`` is the held-out calibration evidence the boundaries
    /// were derived from, and a mandatory slice's `datasetComposition` is the record of what
    /// its evaluation population contains. One artifact in both roles means one record
    /// describes both populations, which is Requirement 5.6's fault stated in artifact terms.
    ///
    /// Only the dataset-composition reference is compared. A slice's eligibility rule,
    /// outcome mapping, metric definition, and degradation condition are rules and
    /// definitions rather than populations, and sharing one metric definition between
    /// calibration and evaluation is not contamination — it is the same metric measured
    /// twice, which is what makes the two comparable. Quality-rule evidence is left out of
    /// the comparison for the same reason: Requirement 5.11 binds it to release-validation
    /// evidence, not to a population. It still has to resolve.
    private static func validateHeldOutCalibrationEvidence(
        _ policy: ValidatedCalibrationPolicy,
        measurements: [ReleaseSliceMeasurement],
        against index: ReleaseEvidenceIndex
    ) throws {
        for (offset, record) in policy.policy.evidence.enumerated() {
            try index.requireResolved(
                record,
                field: "approval.calibrationPolicy.evidence[\(offset)]"
            )
        }
        for rule in policy.policy.qualityRules {
            for (offset, record) in rule.evidence.enumerated() {
                try index.requireResolved(
                    record,
                    field: """
                        approval.calibrationPolicy.qualityRules[\(rule.id.rawValue)]\
                        .evidence[\(offset)]
                        """
                )
            }
        }

        let heldOutCalibration = Set(policy.policy.evidence.map(\.artifact))
        for measurement in measurements {
            let composition = measurement.specification.datasetComposition
            guard !heldOutCalibration.contains(composition.artifact) else {
                throw ArtifactSchemaError.forbiddenValue(
                    field: """
                        approval.slice[\(measurement.slice.rawValue)].datasetComposition
                        """,
                    value: composition.artifact.rawValue,
                    reason: """
                        it is also held-out calibration evidence this policy's boundaries \
                        were derived from, so one record describes both the calibration and \
                        the product-threshold evaluation population
                        """
                )
            }
        }
    }

    // MARK: The mandatory slice set

    /// Requirements 5.15 and 5.20, plus exact compatibility and resolvable predeclarations.
    ///
    /// Five separate refusals, because each is a different way a slice set stops answering
    /// for this release:
    ///
    ///   * The predeclared set is empty, or names one slice twice. An empty mandatory set
    ///     makes every later check vacuous, and a repeated identifier means two
    ///     specifications claim one slice.
    ///   * The measured set is not exactly the predeclared set. A predeclared slice with no
    ///     measurement is an unevaluated mandatory slice; a measurement for a slice nobody
    ///     predeclared is a slice chosen after evaluation began, which is what Requirement
    ///     5.15 exists to forbid.
    ///   * A measurement's specification is not the predeclared one under that identifier.
    ///     Same identifier, different eligibility rule, outcome mapping, interval method,
    ///     or phone-camera designation is the predeclaration being edited to fit the
    ///     result, and it is the fault most worth naming precisely.
    ///   * No slice is the contamination-controlled contemporary phone-camera real-image
    ///     subset, or one that is designated as such holds no eligible real image.
    ///     Requirement 5.20 makes that subset mandatory, and a real-image subset with no
    ///     real image in it is that subset in name only. Several are permitted: two
    ///     phone-camera slices under different degradation conditions are both legitimate,
    ///     so requiring exactly one would refuse an honest release.
    ///   * A measurement was taken against another policy or another bundle, or one of the
    ///     slice's five predeclared references does not resolve to evidence this release
    ///     carries. A predeclaration nobody can find is not a predeclaration.
    private static func validatedSliceSet(
        predeclared: [ReleaseGatingSliceSpecification],
        measurements: [ReleaseSliceMeasurement],
        policy: ValidatedCalibrationPolicy,
        against index: ReleaseEvidenceIndex
    ) throws -> [ReleaseSliceMeasurement] {
        let field = "approval.mandatorySlices"
        try ArtifactSchemaValidation.requireNonEmpty(predeclared, field: field)
        try ArtifactSchemaValidation.requireUniqueKeys(
            predeclared.map(\.id.rawValue),
            field: field
        )
        try ArtifactSchemaValidation.requireExactCoverage(
            measurements.map(\.slice.rawValue),
            required: Set(predeclared.map(\.id.rawValue)),
            field: "approval.sliceMeasurements"
        )
        guard predeclared.contains(where: \.isContemporaryPhoneCameraSlice) else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: field,
                keys: [
                    "a dedicated contamination-controlled contemporary phone-camera "
                        + "real-image slice"
                ]
            )
        }

        let specifications = Dictionary(
            uniqueKeysWithValues: predeclared.map { ($0.id, $0) }
        )
        let ordered = measurements.sorted { $0.slice.rawValue < $1.slice.rawValue }
        for measurement in ordered {
            let slice = "approval.slice[\(measurement.slice.rawValue)]"
            // Total: exact coverage above already required one predeclared specification
            // per measured slice.
            guard let declared = specifications[measurement.slice] else {
                throw ArtifactSchemaError.missingRequiredEntries(
                    field: field,
                    keys: [measurement.slice.rawValue]
                )
            }
            guard measurement.specification == declared else {
                throw ArtifactSchemaError.inconsistentReference(
                    field: "\(slice).specification",
                    expected: "the specification predeclared for this slice",
                    found: "a specification that differs from it"
                )
            }
            if measurement.isContemporaryPhoneCameraSlice {
                guard measurement.counts.eligibleRealImages.value > 0 else {
                    throw ArtifactSchemaError.nonPositiveValue(
                        field: "\(slice).counts.eligibleRealImages",
                        value: "\(measurement.counts.eligibleRealImages.value)"
                    )
                }
            }
            try Self.validateMeasuredAgainstThisRelease(measurement, policy: policy, field: slice)
            try Self.validatePredeclarationsResolve(
                measurement.specification,
                field: slice,
                against: index
            )
        }
        return ordered
    }

    /// Every measurement answers for this release's policy and bundle.
    ///
    /// Three refusals rather than one equality check, because they are three different
    /// findings. A different policy identifier is a measurement of other thresholds; a
    /// different bundle identifier is a measurement of other code; and the same identifier
    /// carrying different content is worse than either — two policies claiming one version,
    /// which means the budget the slice was measured against is not the budget this release
    /// ships.
    private static func validateMeasuredAgainstThisRelease(
        _ measurement: ReleaseSliceMeasurement,
        policy: ValidatedCalibrationPolicy,
        field: String
    ) throws {
        try ArtifactSchemaValidation.requireMatchingReference(
            measurement.calibrationPolicy,
            matches: policy.id,
            field: "\(field).calibrationPolicy"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            measurement.modelBundle,
            matches: policy.modelBundle,
            field: "\(field).modelBundle"
        )
        guard measurement.policy == policy else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).policy",
                expected: "the validated policy under approval",
                found: """
                    another policy recorded under \(measurement.calibrationPolicy.rawValue)
                    """
            )
        }
    }

    /// Requirement 5.15: every predeclared reference on the slice resolves.
    ///
    /// The confidence-interval method and level are not in this list because they are not
    /// references: they are predeclared values, and ``ReleaseSliceMeasurement`` already
    /// refused an interval whose method or level was not the predeclared one.
    private static func validatePredeclarationsResolve(
        _ specification: ReleaseGatingSliceSpecification,
        field: String,
        against index: ReleaseEvidenceIndex
    ) throws {
        for (name, reference) in [
            ("eligibilityRule", specification.eligibilityRule),
            ("outcomeMapping", specification.outcomeMapping),
            ("metricDefinition", specification.metricDefinition),
            ("datasetComposition", specification.datasetComposition),
            ("degradationCondition", specification.degradationCondition),
        ] {
            try index.requireResolved(reference, field: "\(field).\(name)")
        }
    }

    // MARK: Recorded reports

    /// Every recorded report is the measurement it claims to be, and every slice that can
    /// carry one does.
    ///
    /// Reconciliation runs before the budget sweep on purpose. A report that disagrees with
    /// its measurement is a separate and more serious finding than a slice that honestly
    /// failed, and an audit should hear about the disagreement even when the same slice
    /// would have failed anyway.
    private static func reconciled(
        _ reports: [CalibrationSliceResult],
        with measurements: [ReleaseSliceMeasurement],
        policy: ValidatedCalibrationPolicy,
        against index: ReleaseEvidenceIndex
    ) throws -> [CalibrationSliceResult] {
        let field = "approval.sliceReports"
        try ArtifactSchemaValidation.requireUniqueKeys(
            reports.map(\.slice.rawValue),
            field: field
        )
        let measured = Dictionary(uniqueKeysWithValues: measurements.map { ($0.slice, $0) })
        let ordered = reports.sorted { $0.slice.rawValue < $1.slice.rawValue }
        for report in ordered {
            guard let measurement = measured[report.slice] else {
                throw ArtifactSchemaError.unexpectedEntries(
                    field: field,
                    keys: [report.slice.rawValue]
                )
            }
            try Self.reconcile(report, with: measurement, policy: policy, against: index)
        }

        let recorded = Set(ordered.map(\.slice))
        let unreported = measurements
            .filter { $0.statesEveryMeasuredRate && !recorded.contains($0.slice) }
            .map(\.slice.rawValue)
            .sorted()
        guard unreported.isEmpty else {
            throw ArtifactSchemaError.missingRequiredEntries(field: field, keys: unreported)
        }
        return ordered
    }

    /// One recorded report against one measurement.
    ///
    /// The counts and the interval are compared exactly, and that is where the
    /// reconciliation gets its force: every rate in the report is a function of the counts,
    /// so a report whose nine counts and whose predeclared interval are the measured ones is
    /// a report of that run. The rates themselves are compared only where the counts pin
    /// them exactly, for the reason ``ValidatedBenchmarkClaim`` gives about coverage — a
    /// non-terminating quotient has no exact `Decimal` form, so recomputing the ratio here
    /// would either invent a rounding convention or reject an honestly rounded value.
    private static func reconcile(
        _ report: CalibrationSliceResult,
        with measurement: ReleaseSliceMeasurement,
        policy: ValidatedCalibrationPolicy,
        against index: ReleaseEvidenceIndex
    ) throws {
        let field = "approval.sliceReports[\(report.slice.rawValue)]"
        try index.requireResolved(report.specification, field: "\(field).specification")
        try ArtifactSchemaValidation.requireMatchingReference(
            report.calibrationPolicy,
            matches: policy.id,
            field: "\(field).calibrationPolicy"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            report.modelBundle,
            matches: policy.modelBundle,
            field: "\(field).modelBundle"
        )
        try Self.reconcileCounts(report.counts, with: measurement.counts, field: field)

        guard report.falsePositiveRateInterval == measurement.falsePositiveRateInterval else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).falsePositiveRateInterval",
                expected: """
                    \(measurement.falsePositiveRateInterval.method.rawValue) \
                    \(measurement.falsePositiveRateInterval.lowerBound.description)...\
                    \(measurement.falsePositiveRateInterval.upperBound.description)
                    """,
                found: """
                    \(report.falsePositiveRateInterval.method.rawValue) \
                    \(report.falsePositiveRateInterval.lowerBound.description)...\
                    \(report.falsePositiveRateInterval.upperBound.description)
                    """
            )
        }

        switch measurement.budgetOutcome {
        case let .evaluated(outcome):
            guard report.budgetOutcome == outcome else {
                throw ArtifactSchemaError.inconsistentReference(
                    field: "\(field).budgetOutcome",
                    expected: outcome.rawValue,
                    found: report.budgetOutcome.rawValue
                )
            }
        case .noObservedFalsePositiveRate:
            // The record's `budgetOutcome` is a single ``GateOutcome`` and none of its three
            // values says "the rule could not run": `passed` and `failed` both report a
            // result that does not exist, and `not-executed` reports a gate someone skipped
            // rather than a rule with nothing to read. This is the branch that fires for a
            // slice with no eligible held-out real image, before its absent rate is reached
            // below, and the slice blocks in the budget sweep either way.
            throw ArtifactSchemaError.forbiddenValue(
                field: "\(field).budgetOutcome",
                value: report.budgetOutcome.rawValue,
                reason: """
                    the slice holds no eligible held-out real image, so the predeclared \
                    pass rule produced no result for this record to state
                    """
            )
        }

        try Self.reconcileRate(
            report.falsePositiveRate,
            with: measurement.falsePositiveRate,
            population: "eligible held-out real image",
            field: "\(field).falsePositiveRate"
        )
        try Self.reconcileRate(
            report.truePositiveRate,
            with: measurement.truePositiveRate,
            population: "eligible held-out synthetic image",
            field: "\(field).truePositiveRate"
        )
        try Self.reconcileRate(
            report.coverage,
            with: measurement.coverage,
            population: "eligible image",
            field: "\(field).coverage"
        )
        try Self.reconcileBudgetComparison(report, with: measurement, policy: policy, field: field)
    }

    /// The nine label and error counts, compared exactly, one field at a time.
    ///
    /// Integers, so this needs no tolerance and admits no rounding. Reported one field at a
    /// time so an audit hears which count disagrees rather than "the counts differ".
    private static func reconcileCounts(
        _ reported: SliceOutcomeCounts,
        with measured: SliceOutcomeCounts,
        field: String
    ) throws {
        for (name, measuredValue, reportedValue) in [
            (
                "eligibleRealImages", measured.eligibleRealImages.value,
                reported.eligibleRealImages.value
            ),
            (
                "eligibleSyntheticImages", measured.eligibleSyntheticImages.value,
                reported.eligibleSyntheticImages.value
            ),
            (
                "realPositiveLabels", measured.realPositiveLabels.value,
                reported.realPositiveLabels.value
            ),
            (
                "realNonPositiveLabels", measured.realNonPositiveLabels.value,
                reported.realNonPositiveLabels.value
            ),
            (
                "realInsufficientLabels", measured.realInsufficientLabels.value,
                reported.realInsufficientLabels.value
            ),
            (
                "syntheticPositiveLabels", measured.syntheticPositiveLabels.value,
                reported.syntheticPositiveLabels.value
            ),
            (
                "syntheticNonPositiveLabels", measured.syntheticNonPositiveLabels.value,
                reported.syntheticNonPositiveLabels.value
            ),
            (
                "syntheticInsufficientLabels", measured.syntheticInsufficientLabels.value,
                reported.syntheticInsufficientLabels.value
            ),
            ("errorCount", measured.errorCount.value, reported.errorCount.value),
        ] where measuredValue != reportedValue {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).counts.\(name)",
                expected: "\(measuredValue)",
                found: "\(reportedValue)"
            )
        }
    }

    /// One reported rate against the exact measured ratio.
    ///
    /// An absent measured rate is refused outright: the record's field is a required
    /// ``UnitInterval``, so whatever it holds is a number for a population no image was
    /// examined in, and zero-as-unknown is the specific reading this whole layer exists to
    /// reject. Where the rate exists, the two endpoints are the only positions the counts
    /// pin exactly, so they are the only ones compared — a reported 0 with a nonzero
    /// measurement, or a reported 1 while some image fell outside the measured category,
    /// are both statements the counts contradict outright rather than round.
    private static func reconcileRate(
        _ reported: UnitInterval,
        with measured: MeasuredRate?,
        population: String,
        field: String
    ) throws {
        guard let measured else {
            throw ArtifactSchemaError.forbiddenValue(
                field: field,
                value: reported.description,
                reason: """
                    the slice holds no \(population), so this rate was never measured and a \
                    number here is not a measurement
                    """
            )
        }
        guard (reported == .zero) == measured.isZero else {
            throw ArtifactSchemaError.inconsistentReference(
                field: field,
                expected: measured.isZero
                    ? "0, the measured \(measured.description)"
                    : "above 0, because the measured rate is \(measured.description)",
                found: reported.description
            )
        }
        guard (reported == .one) == measured.isOne else {
            throw ArtifactSchemaError.inconsistentReference(
                field: field,
                expected: measured.isOne
                    ? "1, the measured \(measured.description)"
                    : "below 1, because the measured rate is \(measured.description)",
                found: reported.description
            )
        }
    }

    /// The reported false-positive rate has to answer the budget question the way the exact
    /// measured rate does.
    ///
    /// Between the two endpoints the reported decimal is a rounding this module may not
    /// second-guess, but one comparison against it is exact and is the one that matters:
    /// whether it satisfies the budget. A report stating a rate inside the budget while the
    /// measured ratio exceeds it is a published number that would have passed a gate the
    /// measurement fails, which is the specific harm Requirement 5.22 blocks. Decided by
    /// ``MeasuredRate/isAtMost(_:)`` on the measured side, so the measured half is never a
    /// rounded quotient.
    private static func reconcileBudgetComparison(
        _ report: CalibrationSliceResult,
        with measurement: ReleaseSliceMeasurement,
        policy: ValidatedCalibrationPolicy,
        field: String
    ) throws {
        guard let measured = measurement.falsePositiveRate else { return }
        let budget = policy.policy.falseAccusationBudget
        let measuredSatisfies = measured.isAtMost(budget.rate)
        guard (report.falsePositiveRate.value <= budget.rate) == measuredSatisfies else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).falsePositiveRate",
                expected: measuredSatisfies
                    ? "at most the \(budget.description) budget, like the measured "
                        + measured.description
                    : "above the \(budget.description) budget, like the measured "
                        + measured.description,
                found: report.falsePositiveRate.description
            )
        }
    }

    // MARK: The budget sweep

    /// Requirement 5.22: any mandatory slice that does not satisfy the predeclared rule
    /// blocks the affected Model Bundle and application combination.
    ///
    /// The rule itself was applied by ``ReleaseSliceMeasurement`` from the validated
    /// policy's budget and statistic; this reads the result. The switch is exhaustive with
    /// no `default`, so a future ``BudgetRuleOutcome`` case is a compile error here rather
    /// than an outcome that silently passes the gate.
    ///
    /// **A slice the rule could not be applied to blocks, and is reported as missing
    /// evidence rather than as a failure.** Requirement 5.1 scopes the budget to every
    /// mandatory slice *containing held-out real images*, so a mandatory slice with none of
    /// them is arguably outside Requirement 5.22's trigger — it neither exceeds the budget
    /// nor fails the interval rule, because neither test can run. That reading is why this
    /// is a decision rather than an obvious consequence, and it is refused anyway: an unrun
    /// test is not a passed test, which is the same rule that makes
    /// ``GateOutcome/notExecuted`` non-passing and makes ``EligibleRelease`` refuse an
    /// applicable gate with no executed result. Approving a mandatory slice that
    /// contributed no false-accusation evidence would let the mandatory set grow without
    /// the budget covering it. The finding is ``ArtifactSchemaError/missingRequiredEntries``
    /// rather than ``ArtifactSchemaError/forbiddenValue`` so that "this slice failed the
    /// budget" and "this slice had no budget result" stay distinguishable, which is the
    /// distinction ``BudgetRuleOutcome`` was given two cases for. If a release genuinely
    /// needs a mandatory slice with no held-out real images, that is a change to the
    /// approved mandatory set or to the pass rule's scope, and it belongs to the release
    /// owner rather than to a default in this file.
    private static func validateBudgetOutcomes(
        _ measurements: [ReleaseSliceMeasurement],
        policy: ValidatedCalibrationPolicy
    ) throws {
        for measurement in measurements {
            let field = "approval.slice[\(measurement.slice.rawValue)].budgetOutcome"
            switch measurement.budgetOutcome {
            case .evaluated(.passed):
                continue
            case let .evaluated(outcome):
                throw ArtifactSchemaError.forbiddenValue(
                    field: field,
                    value: outcome.rawValue,
                    reason: """
                        a mandatory slice that exceeds the \
                        \(policy.policy.falseAccusationBudget.description) False Accusation \
                        Budget or fails the predeclared \
                        \(policy.policy.releasePassRule.statistic.rawValue) pass rule blocks \
                        distribution of the affected Model Bundle and application combination
                        """
                )
            case .noObservedFalsePositiveRate:
                throw ArtifactSchemaError.missingRequiredEntries(
                    field: field,
                    keys: ["an observed false-positive rate for the predeclared pass rule to read"]
                )
            }
        }
    }
}

// MARK: - Approved accessors

extension ApprovedCalibrationRelease {
    /// The Calibration Policy this approval answers for.
    public var calibrationPolicy: ArtifactID { policy.id }

    /// The Model Bundle this approval answers for.
    public var modelBundle: ModelBundleID { policy.modelBundle }

    /// The dataset lineage record behind the separation verification.
    public var datasetLineage: ArtifactID { lineage.id }

    /// The False Accusation Budget every mandatory slice satisfied. Read from the policy.
    public var falseAccusationBudget: FalseAccusationBudget {
        policy.policy.falseAccusationBudget
    }

    /// The predeclared pass rule that was applied (Requirement 5.21).
    public var releasePassRule: FalseAccusationPassRule { policy.policy.releasePassRule }

    /// The predeclared mandatory slice identifiers, in the order the measurements are held.
    public var mandatorySlices: [ReleaseSliceID] { measurements.map(\.slice) }

    /// Every mandatory slice designated as the contamination-controlled contemporary
    /// phone-camera real-image subset (Requirement 5.20).
    ///
    /// Never empty, and every entry has a nonempty eligible real population: reaching this
    /// value required both.
    public var contemporaryPhoneCameraSlices: [ReleaseSliceMeasurement] {
        measurements.filter(\.isContemporaryPhoneCameraSlice)
    }

    /// The measurement for one slice, or `nil` when it is not in the mandatory set.
    ///
    /// `nil` is never "measured but unchecked": an unchecked measurement keeps the whole
    /// combination from being approved.
    public func measurement(for slice: ReleaseSliceID) -> ReleaseSliceMeasurement? {
        measurements.first { $0.slice == slice }
    }

    /// The reconciled recorded report for one slice, or `nil` when the release carries
    /// none.
    ///
    /// `nil` here means the record could not state the slice's measurement without
    /// fabricating a rate, so no record exists by design; the measurement carries the
    /// complete report.
    public func report(for slice: ReleaseSliceID) -> CalibrationSliceResult? {
        reports.first { $0.slice == slice }
    }

    /// The verified separation result for one population pair.
    ///
    /// Total for two different populations: reaching this value required a passing,
    /// evidenced result for every unordered pair. `nil` only for a pair of one population
    /// with itself, which is not a separation question.
    public func separation(
        between first: CalibrationPopulation,
        and second: CalibrationPopulation
    ) -> PopulationSeparationResult? {
        lineage.separationResults.first { $0.pair == [first, second] }
    }

    /// The held-out calibration evidence the boundaries were derived from
    /// (Requirement 5.6).
    public var heldOutCalibrationEvidence: [EvidenceSource] { policy.policy.evidence }

    /// The evaluation dataset composition record of every mandatory slice, verified
    /// disjoint from ``heldOutCalibrationEvidence`` at the artifact level.
    public var evaluationDatasetCompositions: Set<EvidenceSource> {
        Set(measurements.map(\.specification.datasetComposition))
    }
}
