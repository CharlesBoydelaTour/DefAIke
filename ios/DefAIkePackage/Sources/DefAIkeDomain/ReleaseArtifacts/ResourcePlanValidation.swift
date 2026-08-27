import Foundation

// Completeness and authority validation for the Resource Budgets and the Device
// Validation Plan.
//
// The layers below this one cannot see what it checks:
//
//   * ``ResourceBudget`` and ``ResourceBudgetSet`` validate one budget pair field by
//     field: exactly the metric set each target's requirements fix, a positive
//     unit-carrying numeric limit or a thermal state for each, named measurement
//     conditions, and two distinct artifacts with the two different targets.
//   * ``DeviceValidationPlan`` validates one plan field by field: a nonempty list of
//     Apple Neural Engine iPhones at iOS 17 or later, one comparison per declared metric
//     carrying either a tolerance or an agreement ratio, a measurement for every
//     candidate and target and required metric with all of Requirement 11.4's conditions
//     present, and a missing-result rule that can only be `treat-as-failure`.
//   * ``ReleaseConfiguration`` resolves the budget identifiers the signed capability
//     manifest names, and requires both budgets to cite the *same* Device Validation
//     Plan.
//   * ``StartupPreflight`` binds the running target's budget and requires the plan that
//     budget cites to be the matched allowlist entry's plan.
//
// What none of them can decide:
//
//   * Whether the plan is approved. ``DeviceValidationPlan`` carries an
//     ``ApprovalRecord`` and never reads its decision, so a rejected plan is still a
//     valid plan artifact.
//   * Whether a budget number came from the plan. A budget's hard limit and a plan's
//     declared pass limit are independent fields, so a number typed into a budget reads
//     exactly like a measured one. Comparing them is what Requirements 15.8 and 15.9
//     mean by the plan being the authoritative source.
//   * Whether the plan predeclares every comparison the release needs. Nonemptiness and
//     per-metric uniqueness admit a plan that declares one comparison and stops.
//   * Whether a measurement describes a candidate this plan covers, at that candidate's
//     application build. Plan coverage is checked one way only — every candidate has its
//     metrics — so a measurement for an unlisted device or a different build is accepted.
//   * Whether a recorded result answers the plan. A result set validates internally and
//     is never compared against the plan that predeclared it, so a missing measurement,
//     a limit that differs from the declared one, or a pass claimed above the limit all
//     survive.
//
// ``ValidatedResourcePlan`` is the only way to hold a budget pair and plan that passed
// all of it, and its accessors are the only path to an analysis-time or resource limit.
// ``AdmissibleDeviceValidationResult`` is the only way to hold a result set that answers
// such a plan. Neither type chooses a number, a device, a tolerance, or an approval: an
// absent value stays absent and fails the gate.
//
// Deliberately absent from both: any timeout, deadline, or maximum-duration value that is
// not a limit the bound plan measured. There is no unmeasured analysis timeout, so there
// is no member that could supply one (Requirements 15.9 and 15.10).

// MARK: - Metric units, time metrics, and required comparisons

extension ResourceMetric {
    /// The unit a numeric limit for this metric has to be expressed in, or `nil` for a
    /// categorical metric.
    ///
    /// A limit in the wrong unit is not a limit: it cannot be compared to a measurement
    /// of the metric it is attached to, and Requirement 15.2 only permits determinate
    /// progress when completed and total work describe the same measured unit. The
    /// pairing is fixed by what each metric measures, not by a release decision, so it
    /// belongs here rather than in an artifact.
    public var requiredUnit: ResourceLimitUnit? {
        switch self {
        case .decodedPixelCount: .pixels
        case .encodedInputSize, .peakResidentMemory, .temporaryStorage: .bytes
        case .coldModelLoadTime, .warmAnalysisLatency, .handoffLatency: .milliseconds
        case .energyImpact: .milliwattHours
        case .thermalState: nil
        }
    }

    /// Whether this metric measures elapsed time, and so carries one of the numeric
    /// analysis-time limits Requirement 15.8 requires the plan to establish.
    public var measuresElapsedTime: Bool { requiredUnit == .milliseconds }
}

extension ComparisonMetric {
    /// Whether this comparison applies only when Provenance Capability is enabled.
    public var isProvenanceConditional: Bool { self == .provenanceState }

    /// Every comparison a plan must predeclare before validation begins.
    ///
    /// Requirements 13.6 through 13.11 name the comparisons a fixture run performs:
    /// preprocessing output, raw logits, rank agreement, categorical Pixel Evidence
    /// outcomes, retained encoded bytes, Byte Preservation Status, and screenshot
    /// behavior, plus the provenance state exactly when the capability is enabled.
    /// Coverage is exact in both directions: a pixel-only release that predeclares a
    /// provenance comparison is describing evidence it will never produce.
    public static func requiredComparisons(provenanceEnabled: Bool) -> Set<ComparisonMetric> {
        provenanceEnabled
            ? Set(allCases)
            : Set(allCases.filter { !$0.isProvenanceConditional })
    }
}

extension ValidatedLimit {
    /// Bounded rendering for an audit message. Not user-facing copy.
    var auditDescription: String {
        switch self {
        case let .numeric(value, unit): "\(value) \(unit.rawValue)"
        case let .thermal(maximumState): "at most \(maximumState.rawValue)"
        }
    }

    /// The numeric ceiling, or `nil` for a categorical limit.
    var numericValue: PositiveDecimal? {
        switch self {
        case let .numeric(value, _): value
        case .thermal: nil
        }
    }
}

// MARK: - Validated plan

/// A Device Validation Plan and the Resource Budget pair it measured, validated
/// together.
///
/// Holding this value means the plan is approved, its references resolve to the
/// artifacts it names, it predeclares every required comparison and every measurement
/// condition, and each target's budget carries exactly the limits the plan measured. The
/// accessors are therefore authoritative by construction: there is no path to a resource
/// or analysis-time limit that does not start at this plan.
public struct ValidatedResourcePlan: Hashable, Sendable {
    /// The plan, unchanged. Validation never repairs, normalizes, or fills a field.
    public let plan: DeviceValidationPlan

    /// Both target budgets, verified to carry the plan's measured limits.
    public let budgets: ResourceBudgetSet

    /// Whether this release's plan covers the provenance lane.
    public let enablesProvenance: Bool

    /// Validates `plan` and `budgets` against the artifacts they reference.
    ///
    /// Fails closed with one ``ArtifactSchemaError`` naming the offending field, so an
    /// audit can point at one position rather than reporting "invalid plan". A failure is
    /// never an ``AnalysisError``: a plan that does not validate leaves the release
    /// without approved limits instead of producing a user-facing verdict.
    public init(
        activating plan: DeviceValidationPlan,
        budgets: ResourceBudgetSet,
        fixtureSuite: ReleaseFixtureSuite,
        capabilityManifest: ReleaseCapabilityManifest,
        evidence index: ReleaseEvidenceIndex
    ) throws {
        let provenanceEnabled = capabilityManifest.enablesProvenance
        try Self.validateApproval(plan, against: index)
        try Self.validateReferences(
            plan,
            budgets: budgets,
            fixtureSuite: fixtureSuite,
            capabilityManifest: capabilityManifest,
            provenanceEnabled: provenanceEnabled
        )
        try Self.validateComparisons(
            plan,
            provenanceEnabled: provenanceEnabled,
            against: index
        )
        try Self.validateMeasurements(plan, against: index)
        try Self.validateAuthoritativeLimits(plan, budgets: budgets, against: index)

        self.plan = plan
        self.budgets = budgets
        self.enablesProvenance = provenanceEnabled
    }

    // MARK: Approval

    /// Requirements 13.3 and 15.9: the plan is a release decision, not a document.
    ///
    /// A plan is predeclared *and approved* before validation begins, and its approval
    /// record has to name evidence this release carries. Presence of a record is not
    /// approval, and a reference to an approval nobody can find is not evidence.
    private static func validateApproval(
        _ plan: DeviceValidationPlan,
        against index: ReleaseEvidenceIndex
    ) throws {
        guard plan.approval.isApproved else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "plan.approval.decision",
                value: plan.approval.decision.rawValue,
                reason: "an unapproved plan supplies no release limit and no gate"
            )
        }
        try index.requireResolved(plan.approval.source, field: "plan.approval.source")
    }

    // MARK: References

    /// Requirements 13.17 and 13.20: every version reference is exact.
    ///
    /// The plan names a fixture suite, a Model Bundle, and a capability manifest, and
    /// each budget names the plan that measured it. Each of those has to be the artifact
    /// actually bound to this release; otherwise the plan predeclares work against
    /// fixtures, a model, or a capability set the release does not ship, and its numbers
    /// describe a different build.
    private static func validateReferences(
        _ plan: DeviceValidationPlan,
        budgets: ResourceBudgetSet,
        fixtureSuite: ReleaseFixtureSuite,
        capabilityManifest: ReleaseCapabilityManifest,
        provenanceEnabled: Bool
    ) throws {
        try ArtifactSchemaValidation.requireMatchingReference(
            plan.capabilityManifest,
            matches: capabilityManifest.id,
            field: "plan.capabilityManifest"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            plan.fixtureSuite,
            matches: fixtureSuite.id,
            field: "plan.fixtureSuite"
        )
        guard capabilityManifest.approvedBundleCatalog.contains(plan.modelBundle) else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "plan.modelBundle",
                expected: "one of "
                    + "\(capabilityManifest.approvedBundleCatalog.map(\.rawValue).sorted())",
                found: plan.modelBundle.rawValue
            )
        }

        // The fixture suite decides whether the provenance families exist, and the
        // manifest decides whether the capability is compiled. Two answers to one
        // question means the plan cannot say which comparisons it needs
        // (Requirements 6.2 and 13.5).
        guard fixtureSuite.provenanceApplicability.isApplicable == provenanceEnabled else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "plan.fixtureSuite.provenanceApplicability",
                expected: provenanceEnabled ? "applicable" : "not applicable",
                found: fixtureSuite.provenanceApplicability.isApplicable
                    ? "applicable"
                    : "not applicable"
            )
        }

        for (offset, configuration) in plan.candidateConfigurations.enumerated() {
            try ArtifactSchemaValidation.requireMatchingReference(
                configuration.appBuild,
                matches: capabilityManifest.appBuild,
                field: "plan.candidateConfigurations[\(offset)].appBuild"
            )
        }

        // Requirement 15.9. ``ReleaseConfiguration`` requires the two budgets to cite
        // one plan; this requires that plan to be *this* plan. Without it a coherent
        // budget pair can cite a plan that measured a different release.
        for target in ExecutionTarget.allCases {
            try ArtifactSchemaValidation.requireMatchingReference(
                budgets.budget(for: target).validationPlan,
                matches: plan.id,
                field: "budgets.\(target.rawValue).validationPlan"
            )
        }
    }

    // MARK: Comparisons

    /// Requirement 13.3: the comparison set is complete before validation begins.
    private static func validateComparisons(
        _ plan: DeviceValidationPlan,
        provenanceEnabled: Bool,
        against index: ReleaseEvidenceIndex
    ) throws {
        try ArtifactSchemaValidation.requireExactCoverage(
            plan.comparisons.map(\.metric.rawValue),
            required: Set(
                ComparisonMetric.requiredComparisons(provenanceEnabled: provenanceEnabled)
                    .map(\.rawValue)
            ),
            field: "plan.comparisons"
        )
        for comparison in plan.comparisons {
            try index.requireResolved(
                comparison.reference,
                field: "plan.comparisons[\(comparison.metric.rawValue)].reference"
            )
        }
    }

    // MARK: Measurements

    /// Requirements 11.4 and 13.20: every measurement describes a candidate of this
    /// plan, at that candidate's application build, against a workload this release
    /// carries.
    ///
    /// The plan schema checks coverage in one direction: every candidate, target, and
    /// required metric has a measurement. This checks the other direction. A measurement
    /// for a device the plan does not list produces numbers nobody asked for, and a
    /// measurement at a different application build is the version mixing
    /// Requirement 13.20 excludes — recorded under a candidate's hardware identifier, it
    /// would otherwise read as that candidate's evidence.
    private static func validateMeasurements(
        _ plan: DeviceValidationPlan,
        against index: ReleaseEvidenceIndex
    ) throws {
        for measurement in plan.measurements {
            let position = "\(measurement.target.rawValue)/\(measurement.metric.rawValue)"
                + "/\(measurement.hardwareIdentifier.rawValue)"
            guard let candidate = plan.candidateConfigurations.first(where: {
                $0.hardwareIdentifier == measurement.hardwareIdentifier
                    && $0.osVersion == measurement.osVersion
            }) else {
                throw ArtifactSchemaError.inconsistentReference(
                    field: "plan.measurements[\(position)].hardwareIdentifier",
                    expected: "a candidate configuration of this plan",
                    found: "\(measurement.hardwareIdentifier.rawValue)"
                        + "@\(measurement.osVersion.description)"
                )
            }
            try ArtifactSchemaValidation.requireMatchingReference(
                measurement.appBuild,
                matches: candidate.appBuild,
                field: "plan.measurements[\(position)].appBuild"
            )
            try index.requireResolved(
                measurement.workload,
                field: "plan.measurements[\(position)].workload"
            )
        }
    }

    // MARK: Authoritative limits

    /// Requirements 11.2, 11.3, 15.8, and 15.9: each budget number is the number the
    /// plan measured, in the unit the metric is measured in, and it is a limit that can
    /// be exceeded.
    ///
    /// Three separate faults, all invisible to the budget schema alone:
    ///
    ///   * A hard limit that differs from the plan's declared pass limit. The budget is
    ///     what the Resource Controller enforces at runtime and the plan is what physical
    ///     measurement established; when they disagree the app enforces a number no
    ///     device evidence supports. Equality is required across every candidate the plan
    ///     covers, because one budget governs every allowlisted configuration — a
    ///     per-device relaxation would let an approved device run past the limit the app
    ///     enforces, and picking one of the two numbers here would be this code choosing
    ///     a release value.
    ///   * A numeric limit in the wrong unit, which cannot be compared to a measurement
    ///     of its own metric.
    ///   * A thermal limit of `critical`. Critical is the hottest state, so such a limit
    ///     admits every observation: it is the categorical form of zero-as-unknown, and a
    ///     gate that cannot fail is not evidence (Requirements 13.14 and 13.15).
    private static func validateAuthoritativeLimits(
        _ plan: DeviceValidationPlan,
        budgets: ResourceBudgetSet,
        against index: ReleaseEvidenceIndex
    ) throws {
        for target in ExecutionTarget.allCases {
            let budget = budgets.budget(for: target)
            for entry in budget.hardLimits {
                let position = "budgets.\(target.rawValue).hardLimits[\(entry.metric.rawValue)]"
                try Self.validateUnit(entry, field: position)
                try index.requireResolved(
                    entry.measurementConditions,
                    field: "\(position).measurementConditions"
                )
                for measurement in plan.measurements
                where measurement.target == target && measurement.metric == entry.metric {
                    guard measurement.passLimit == entry.limit else {
                        throw ArtifactSchemaError.inconsistentReference(
                            field: "\(position).limit",
                            expected: measurement.passLimit.auditDescription
                                + " measured on \(measurement.hardwareIdentifier.rawValue)",
                            found: entry.limit.auditDescription
                        )
                    }
                }
            }
        }
    }

    /// The unit and severity rules one limit entry has to satisfy.
    private static func validateUnit(_ entry: ResourceLimitEntry, field: String) throws {
        switch entry.limit {
        case let .numeric(_, unit):
            guard let required = entry.metric.requiredUnit else {
                // Unreachable: ``ValidatedLimit/matches(_:)`` already rejects a numeric
                // limit on a categorical metric. Kept as a refusal rather than a
                // force-unwrap.
                throw ArtifactSchemaError.fixedValueMismatch(
                    field: "\(field).limit",
                    expected: "a thermal-state limit",
                    found: "a numeric limit in \(unit.rawValue)"
                )
            }
            guard unit == required else {
                throw ArtifactSchemaError.fixedValueMismatch(
                    field: "\(field).limit.unit",
                    expected: required.rawValue,
                    found: unit.rawValue
                )
            }
        case let .thermal(maximumState):
            guard maximumState != .critical else {
                throw ArtifactSchemaError.forbiddenValue(
                    field: "\(field).limit.maximumState",
                    value: maximumState.rawValue,
                    reason: """
                        critical is the hottest state, so this limit admits every \
                        observation and cannot be exceeded
                        """
                )
            }
        }
    }
}

// MARK: - Authoritative accessors

extension ValidatedResourcePlan {
    /// The plan's artifact identifier, for a session binding or an audit record.
    public var id: ArtifactID { plan.id }

    /// Candidate configurations this plan covers.
    public var candidateConfigurations: [CandidateDeviceConfiguration] {
        plan.candidateConfigurations
    }

    /// What a missing mandatory result means. Only failure is representable.
    public var missingResultRule: MissingResultRule { plan.missingResultRule }

    /// The approved hard limit for one metric on one target.
    ///
    /// `nil` only where the metric does not apply to that target, which the budget
    /// schema already fixes. It is never "no limit was decided": reaching this value
    /// required the limit to equal the one the plan measured.
    public func hardLimit(
        _ metric: ResourceMetric,
        for target: ExecutionTarget
    ) -> ValidatedLimit? {
        budgets.budget(for: target).limit(for: metric)
    }

    /// The approved numeric analysis-time limit for one metric, in milliseconds.
    ///
    /// The only path to a time limit, and it starts at the bound approved plan
    /// (Requirements 15.8 and 15.9). `nil` means this metric is not an elapsed-time
    /// metric of that target, and a caller that receives `nil` has no approved limit:
    /// the correct response is to let the work continue under the remaining budget, never
    /// to synthesize a timeout (Requirement 15.10).
    public func analysisTimeLimitMilliseconds(
        _ metric: ResourceMetric,
        for target: ExecutionTarget
    ) -> PositiveDecimal? {
        guard metric.measuresElapsedTime else { return nil }
        return hardLimit(metric, for: target)?.numericValue
    }

    /// Whether the plan measured concurrent pixel and provenance execution as acceptable
    /// for one exact configuration.
    ///
    /// The design runs the two evidence branches concurrently only where the bound plan
    /// and the main-application budget approve that execution policy for the exact
    /// configuration, because lower wall time is not automatically safer than lower peak
    /// memory or energy. Serial is the answer whenever the plan's main-application
    /// measurements for that configuration do not all declare concurrent execution: an
    /// unmeasured or partially measured policy is not an approved one.
    public func approvesConcurrentEvidenceBranches(
        for configuration: CandidateDeviceConfiguration
    ) -> Bool {
        let measurements = plan.measurements.filter {
            $0.target == .mainApplication
                && $0.hardwareIdentifier == configuration.hardwareIdentifier
                && $0.osVersion == configuration.osVersion
        }
        guard !measurements.isEmpty else { return false }
        return measurements.allSatisfy { $0.branchExecution == .concurrent }
    }

    /// The measurement specification for one metric on one target and configuration, or
    /// `nil` when this plan does not cover that configuration.
    public func measurement(
        _ metric: ResourceMetric,
        for target: ExecutionTarget,
        on configuration: CandidateDeviceConfiguration
    ) -> ResourceMeasurementSpecification? {
        plan.measurements.first {
            $0.target == target
                && $0.metric == metric
                && $0.hardwareIdentifier == configuration.hardwareIdentifier
                && $0.osVersion == configuration.osVersion
        }
    }
}

// MARK: - Admissible result set

/// A device validation result set that answers the plan which predeclared it.
///
/// Admissibility and passing are separate questions, and conflating them is how a
/// missing result becomes a pass. This type decides only the first: the run happened on a
/// physical iPhone, under exactly this plan's versions, on a configuration this plan
/// covers, and it recorded a result for every measurement and comparison the plan
/// predeclared. A recorded *failure* is admissible evidence — it excludes the
/// configuration from the allowlist, which is the allowlist's decision to make. A missing
/// or unexecuted mandatory result is not evidence at all, and the plan's missing-result
/// rule can only call it a failure (Requirements 13.17 and 13.19).
public struct AdmissibleDeviceValidationResult: Hashable, Sendable {
    /// The result set, unchanged.
    public let results: DeviceValidationResultSet

    /// The plan this result set was admitted against.
    public let plan: ArtifactID

    /// Validates `results` against `plan`.
    public init(
        admitting results: DeviceValidationResultSet,
        under plan: ValidatedResourcePlan
    ) throws {
        try Self.validateEnvironment(results)
        let configuration = try Self.validateBinding(results, under: plan)
        try Self.validateMeasurements(results, under: plan, on: configuration)
        try Self.validateComparisons(results, under: plan)
        try Self.validateGateOutcomes(results)

        self.results = results
        self.plan = plan.id
    }

    /// Whether every mandatory gate is satisfied for this configuration.
    ///
    /// Admission does not imply this. A configuration whose gates are not all satisfied
    /// is excluded from the Release Approved iPhone Allowlist (Requirements 13.19
    /// and 13.21), which is the allowlist's decision to make rather than admission's.
    public var satisfiesEveryMandatoryGate: Bool { results.unsatisfiedGates.isEmpty }

    /// The configuration these results describe.
    public var configuration: CandidateDeviceConfiguration { results.configuration }

    // MARK: Environment

    /// Requirement 13.16: only physical-iPhone results are release evidence.
    ///
    /// ``DeviceValidationResultSet`` deliberately represents a simulator or development
    /// Mac run so a runner can record what it observed. Admission is the point where a
    /// recording would become evidence, so it is where the environment is refused.
    private static func validateEnvironment(_ results: DeviceValidationResultSet) throws {
        guard results.isPhysicalDeviceEvidence else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "results.environment",
                value: results.environment.rawValue,
                reason: "only physical-iPhone results are release evidence"
            )
        }
    }

    // MARK: Binding

    /// Requirements 13.17 and 13.20: the result set is bound to this exact plan, its
    /// versions, and one configuration the plan covers.
    private static func validateBinding(
        _ results: DeviceValidationResultSet,
        under plan: ValidatedResourcePlan
    ) throws -> CandidateDeviceConfiguration {
        let tuple = results.versionTuple
        try ArtifactSchemaValidation.requireMatchingReference(
            tuple.validationPlan,
            matches: plan.id,
            field: "results.versionTuple.validationPlan"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            tuple.fixtureSuite,
            matches: plan.plan.fixtureSuite,
            field: "results.versionTuple.fixtureSuite"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            tuple.modelBundle,
            matches: plan.plan.modelBundle,
            field: "results.versionTuple.modelBundle"
        )
        try ArtifactSchemaValidation.requireMatchingReference(
            tuple.capabilityManifest,
            matches: plan.plan.capabilityManifest,
            field: "results.versionTuple.capabilityManifest"
        )
        guard tuple.enablesProvenance == plan.enablesProvenance else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "results.versionTuple.capabilities",
                expected: plan.enablesProvenance
                    ? "the provenance capability"
                    : "no provenance capability",
                found: tuple.capabilities.map(\.rawValue).sorted().joined(separator: ",")
            )
        }

        // Value equality, not identifier equality: the recorded device model, hardware
        // identifier, operating-system version, and build all participate, so a result
        // recorded against a near-match of a listed candidate is not that candidate.
        guard plan.candidateConfigurations.contains(results.configuration) else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "results.configuration",
                expected: "a candidate configuration of plan \(plan.id.rawValue)",
                found: "\(results.configuration.hardwareIdentifier.rawValue)"
                    + "@\(results.configuration.osVersion.description)"
                    + "/\(results.configuration.appBuild.rawValue)"
            )
        }
        return results.configuration
    }

    // MARK: Measurements

    /// Requirements 11.19, 13.12, 13.13, and 13.17: every predeclared measurement has a
    /// recorded result, taken against the declared limit and statistic, and its pass
    /// follows from the measurement rather than being asserted next to it.
    ///
    /// Both targets are required separately, because Requirement 11.19 reports the
    /// main-application set and the Share Extension set as separate measurement sets with
    /// separate gate results, and the metric sets are different.
    ///
    /// The recorded summary statistic is not recomputed from the raw samples: the plan
    /// fixes *which* statistic, and for `percentile-95` it fixes no interpolation
    /// convention, so recomputing would invent one. What is checked instead is
    /// convention-free and still catches a fabricated summary — the summary of a set of
    /// samples lies between the smallest and largest of them, whichever of the four
    /// statistics is used.
    private static func validateMeasurements(
        _ results: DeviceValidationResultSet,
        under plan: ValidatedResourcePlan,
        on configuration: CandidateDeviceConfiguration
    ) throws {
        let recorded = results.gateResults.flatMap(\.measurements)
        for target in ExecutionTarget.allCases {
            for metric in ResourceMetric.requiredMetrics(for: target)
                .sorted(by: { $0.rawValue < $1.rawValue })
            {
                let position = "results.measurements[\(target.rawValue)/\(metric.rawValue)]"
                guard let specification = plan.measurement(
                    metric,
                    for: target,
                    on: configuration
                ) else {
                    // Unreachable: the plan schema requires every candidate to carry
                    // every required metric for both targets, and the configuration was
                    // shown to be one of this plan's candidates.
                    throw ArtifactSchemaError.missingRequiredEntries(
                        field: "plan.measurements",
                        keys: ["\(target.rawValue)/\(metric.rawValue)"]
                    )
                }
                let matching = recorded.filter { $0.target == target && $0.metric == metric }
                guard !matching.isEmpty else {
                    throw Self.missingResult(field: position, under: plan)
                }
                for record in matching {
                    guard record.outcome != .notExecuted else {
                        throw Self.missingResult(field: position, under: plan)
                    }
                    try ArtifactSchemaValidation.requireMatchingReference(
                        record.specification.artifact,
                        matches: plan.id,
                        field: "\(position).specification"
                    )
                    guard record.limit == specification.passLimit else {
                        throw ArtifactSchemaError.inconsistentReference(
                            field: "\(position).limit",
                            expected: specification.passLimit.auditDescription,
                            found: record.limit.auditDescription
                        )
                    }
                    guard record.summaryStatistic == specification.summaryStatistic else {
                        throw ArtifactSchemaError.inconsistentReference(
                            field: "\(position).summaryStatistic",
                            expected: specification.summaryStatistic.rawValue,
                            found: record.summaryStatistic.rawValue
                        )
                    }
                    try Self.validateSummary(record, field: position)
                    try Self.validateOutcome(record, field: position)
                }
            }
        }
    }

    /// The recorded summary lies inside the range of the samples it summarizes.
    private static func validateSummary(_ record: MeasurementRecord, field: String) throws {
        guard let smallest = record.rawValues.min(), let largest = record.rawValues.max() else {
            // Unreachable: ``MeasurementRecord`` requires a nonempty sample list for an
            // executed measurement, and an unexecuted one was already refused.
            throw ArtifactSchemaError.emptyValue(field: "\(field).rawValues")
        }
        guard record.summaryValue >= smallest, record.summaryValue <= largest else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "\(field).summaryValue",
                value: "\(record.summaryValue)",
                allowed: "within the observed samples \(smallest)...\(largest)"
            )
        }
    }

    /// A numeric pass follows from the summary and the declared limit.
    ///
    /// Every numeric metric here is a ceiling — pixels, bytes, milliseconds, and
    /// milliwatt-hours are all "at most" limits — so the comparison is total for them. A
    /// thermal limit is skipped: the schema stores a thermal observation as a `Decimal`
    /// alongside a categorical limit without fixing how a state maps to a number, and
    /// inventing that mapping here would decide the gate rather than check it.
    private static func validateOutcome(_ record: MeasurementRecord, field: String) throws {
        guard let ceiling = record.limit.numericValue else { return }
        let withinLimit = record.summaryValue <= ceiling.value
        guard record.outcome.isPassing == withinLimit else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).outcome",
                expected: withinLimit ? GateOutcome.passed.rawValue : GateOutcome.failed.rawValue,
                found: record.outcome.rawValue
            )
        }
    }

    // MARK: Comparisons

    /// Requirements 13.6 through 13.11 and 13.21: every predeclared comparison has a
    /// recorded result, and its pass follows from the declared tolerance or agreement
    /// ratio.
    private static func validateComparisons(
        _ results: DeviceValidationResultSet,
        under plan: ValidatedResourcePlan
    ) throws {
        let recorded = results.gateResults.flatMap(\.comparisons)
        for specification in plan.plan.comparisons {
            let position = "results.comparisons[\(specification.metric.rawValue)]"
            let matching = recorded.filter { $0.metric == specification.metric }
            guard !matching.isEmpty else {
                throw Self.missingResult(field: position, under: plan)
            }
            for record in matching {
                guard record.outcome != .notExecuted else {
                    throw Self.missingResult(field: position, under: plan)
                }
                try ArtifactSchemaValidation.requireMatchingReference(
                    record.specification.artifact,
                    matches: plan.id,
                    field: "\(position).specification"
                )
                try Self.validateComparisonOutcome(
                    record,
                    specification: specification,
                    field: position
                )
            }
        }
    }

    /// A comparison's pass follows from what it measured.
    ///
    /// A categorical comparison passes exactly when the agreeing fixtures meet the
    /// declared ratio, which Requirement 13.8 fixes at 100% for Pixel Evidence outcomes.
    /// A numeric comparison has to report the deviation it observed — a numeric parity
    /// claim with no measured deviation records no measured value at all — and passes
    /// exactly when that deviation is within the declared tolerance.
    ///
    /// The ratio comparison is a cross-multiplication rather than a division, so an exact
    /// 100% requirement stays exact instead of depending on a rounded quotient.
    private static func validateComparisonOutcome(
        _ record: ComparisonRecord,
        specification: ComparisonSpecification,
        field: String
    ) throws {
        let satisfied: Bool
        if let requiredAgreement = specification.requiredAgreement {
            satisfied = Decimal(record.agreeingFixtureCount.value)
                >= requiredAgreement.value * Decimal(record.comparedFixtureCount.value)
        } else if let tolerance = specification.tolerance {
            guard let deviation = record.maximumDeviation else {
                throw ArtifactSchemaError.missingRequiredEntries(
                    field: field,
                    keys: ["maximumDeviation"]
                )
            }
            satisfied = deviation.value <= tolerance.value.value
        } else {
            // Unreachable: ``ComparisonSpecification`` requires exactly one of the two.
            throw ArtifactSchemaError.missingRequiredEntries(
                field: "plan.comparisons[\(specification.metric.rawValue)]",
                keys: ["tolerance or requiredAgreement"]
            )
        }
        guard record.outcome.isPassing == satisfied else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).outcome",
                expected: satisfied ? GateOutcome.passed.rawValue : GateOutcome.failed.rawValue,
                found: record.outcome.rawValue
            )
        }
    }

    // MARK: Gate outcomes

    /// Requirement 13.17: a gate's recorded pass or fail follows from the results it
    /// carries.
    ///
    /// The gate outcome and the outcomes of its measurements and comparisons are stored
    /// separately, which is what keeps a raw value from being overwritten by a verdict.
    /// The cost is that they can disagree, and a passing gate carrying a failed
    /// measurement is the disagreement that matters: the allowlist reads gate outcomes,
    /// so it would admit a configuration whose own evidence records a breach.
    private static func validateGateOutcomes(_ results: DeviceValidationResultSet) throws {
        for record in results.gateResults where record.applicability.isApplicable {
            guard record.outcome != .notExecuted else { continue }
            let carried = record.measurements.map(\.outcome) + record.comparisons.map(\.outcome)
            let allPassing = carried.allSatisfy(\.isPassing)
            guard record.outcome.isPassing == allPassing else {
                throw ArtifactSchemaError.inconsistentReference(
                    field: "results.gateResults[\(record.gate.rawValue)].outcome",
                    expected: allPassing
                        ? GateOutcome.passed.rawValue
                        : GateOutcome.failed.rawValue,
                    found: record.outcome.rawValue
                )
            }
        }
    }

    // MARK: Missing results

    /// The fault for a mandatory result the plan predeclared and the record omits.
    ///
    /// Routed through the plan's declared rule rather than around it, so the reason an
    /// audit is given is the rule the release approved. The rule vocabulary can express
    /// `treat-as-pass` and the plan schema refuses it, which is why this is a refusal in
    /// both branches rather than a conditional: a missing result never passes
    /// (Requirement 13.19).
    private static func missingResult(
        field: String,
        under plan: ValidatedResourcePlan
    ) -> ArtifactSchemaError {
        switch plan.missingResultRule {
        case .treatAsFailure:
            .missingRequiredEntries(field: field, keys: ["a recorded result"])
        case .treatAsPass:
            .forbiddenValue(
                field: "plan.missingResultRule",
                value: MissingResultRule.treatAsPass.rawValue,
                reason: "a missing mandatory result at \(field) can only be a failure"
            )
        }
    }
}
