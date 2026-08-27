import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain

// Design Property 28: resource and validation plans are complete and authoritative.
//
// The design states it as: for any candidate Resource Budgets and Device Validation
// Plan, activation succeeds only when separate main-app and Share Extension budgets
// contain every required numeric metric, every measurement declares its full
// configuration and method, and analysis-time/resource limits come only from that bound
// plan; missing, placeholder, nonpositive, or cross-target values invalidate the
// artifacts.
//
// Quantified here as one property with six arms over every generated shape:
//
//   * valid — a complete, coherent shape activates, and every limit the activated plan
//     reports is exactly the number the generated plan measured for that metric and
//     target, `nil` only where the metric does not belong to the target;
//   * authority — a budget number the plan did not measure is refused, which is what
//     Requirements 15.8 and 15.9 mean by the plan being the source of every limit;
//   * missing — an absent required metric, predeclared measurement, measurement
//     condition, or predeclared comparison is refused;
//   * placeholder — a value that looks supplied but carries no measurement is refused;
//   * nonpositive — zero and negative limits and sample counts are unrepresentable, so
//     no budget can carry one as a floor;
//   * cross-target — a budget or measurement belonging to the other target is refused,
//     in both directions.
//
// ``ResourcePlanValidationTests`` pins each of these refusals at one field with one
// example. This file quantifies the same statement over generated shapes. The two other
// properties that touch this area belong to their own tasks: Property 29 is runtime
// enforcement of a limit, and Property 32 is referential completeness of recorded
// results.
//
// No value here is an approved budget, limit, deadline, device, or decision. Every
// number is generated from a synthetic range, every identifier carries the generated
// seed, and the whole shape exists so that validation can be asked to refuse it.

extension Tag {
    /// Design Property 28.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property28ResourcePlanAuthority: Self
}

@Suite(
    "Property 28: resource and validation plans are complete and authoritative",
    .tags(.property28ResourcePlanAuthority)
)
struct ResourcePlanAuthorityPropertyTests {
    /// Runs at the library default of 100 generated cases with shrinking, which is the
    /// minimum the design requires; `PropertyToolchainWiringTests` pins that default.
    ///
    /// **Validates: Requirements 11.1, 11.2, 11.3, 11.4, 15.8, 15.9**
    @Test("Activation is complete and authoritative over generated budgets and plans")
    func resourcePlansAreCompleteAndAuthoritative() async {
        let witness = ResourcePlanVariationWitness()

        await propertyCheck(input: ResourcePlanShape.generator) { shape in
            witness.record(shape)
            let scenario = ResourcePlanScenario(shape: shape)

            scenario.checkCoherentShapeActivates()
            scenario.checkPlanIsTheOnlySourceOfALimit()
            scenario.checkMissingValuesAreRefused()
            scenario.checkPlaceholderValuesAreRefused()
            scenario.checkNonpositiveValuesAreUnrepresentable()
            scenario.checkCrossTargetValuesAreRefused()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - Generated shape

/// One target and one metric. The budget layer is per target and the metric sets differ,
/// so the pair is the key everything else is indexed by.
private struct TargetMetric: Hashable, Sendable {
    let target: ExecutionTarget
    let metric: ResourceMetric
}

/// One candidate iPhone configuration, as plain data.
private struct DeviceShape: Sendable {
    let hardwareDigit: Int
    let osMinor: Int
    let osPatch: Int
}

/// One generated numeric limit magnitude.
///
/// Split into a whole part and thousandths so generated limits are exact non-integer
/// decimals rather than round numbers: a limit that only ever lands on an integer would
/// not exercise the exact-decimal equality the authority check depends on.
private struct Magnitude: Sendable {
    let whole: Int
    let thousandths: Int

    var value: Decimal { Decimal(whole) + Decimal(thousandths) / 1_000 }
}

/// The measurement method Requirement 11.4 requires every measurement to declare.
private struct MethodShape: Sendable {
    let sampleCount: Int
    let statisticIndex: Int
    let concurrent: Bool
    let pluggedIn: Bool
    let startingThermalIndex: Int
}

/// Which member of each enumerable set a mutation arm breaks.
///
/// Generated rather than enumerated so the shrinker can reduce a failing arm to one
/// metric or comparison, and so 100 cases spread across the sets instead of every case
/// paying for all of them.
private struct Selectors: Sendable {
    let metric: Int
    let comparison: Int
    let device: Int
    let placeholderToken: Int
}

/// Everything the resource-plan layer reads, as plain data.
///
/// The generator produces data only. Artifacts are built from it inside the property
/// body, where a construction that unexpectedly throws is recorded as a failure rather
/// than escaping: `propertyCheck` discards an error thrown by its body, so a refusal that
/// escaped as a throw would pass vacuously.
///
/// ## How the baseline varies
///
/// A property whose baseline is one constant with a mutation applied asserts one example
/// a hundred times over, so every dimension the arms depend on is generated rather than
/// fixed:
///
///   * every numeric limit is its own generated exact decimal, one per
///     `(target, metric)` pair, so the two targets carry different numbers for the four
///     metrics they share and no two metrics of one target agree by construction;
///   * the thermal ceiling is generated per target over the three admissible states;
///   * one to three candidate configurations, each with its own hardware identifier and
///     operating-system version;
///   * both capability sets, which changes the required comparison set;
///   * sample count, summary statistic, branch execution, starting thermal state, and
///     starting power condition;
///   * every identifier, version, and content digest, from ``seed``. Deriving the whole
///     reference set from one number keeps it coherent without a cross-reference table
///     while still varying each reference between cases.
///
/// ``ResourcePlanVariationWitness`` checks after the run that this actually happened.
private struct ResourcePlanShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic identifier, version, and digest, so the whole reference set
    /// varies together and stays coherent without a cross-reference table.
    let seed: Int

    let provenanceEnabled: Bool
    let devices: [DeviceShape]

    /// One magnitude per numeric `(target, metric)` pair, in ``numericPairs`` order.
    let magnitudes: [Magnitude]

    /// One thermal ceiling per target, never `critical`.
    let thermalCeilings: [ThermalState]

    let method: MethodShape
    let selectors: Selectors

    /// Thermal ceilings a budget may carry. `critical` is excluded because it admits
    /// every observation; the placeholder arm generates it deliberately.
    static let admissibleThermalStates: [ThermalState] = [.nominal, .fair, .serious]

    /// Every numeric `(target, metric)` pair a budget pair has to carry, in a fixed
    /// order so a generated magnitude array indexes into it deterministically.
    static let numericPairs: [TargetMetric] = ExecutionTarget.allCases.flatMap { target in
        ResourceMetric.requiredMetrics(for: target)
            .filter { !$0.isCategorical }
            .sorted { $0.rawValue < $1.rawValue }
            .map { TargetMetric(target: target, metric: $0) }
    }

    var description: String {
        "seed \(seed), \(devices.count) device(s), provenance \(provenanceEnabled), "
            + "ceilings \(thermalCeilings.map(\.rawValue))"
    }

    // MARK: Generators

    static var generator: Generator<ResourcePlanShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.bool,
            devices,
            magnitudes,
            thermalCeilings,
            method,
            selectors
        )
        .map { raw in
            ResourcePlanShape(
                seed: raw.0,
                provenanceEnabled: raw.1,
                devices: raw.2,
                magnitudes: raw.3,
                thermalCeilings: raw.4,
                method: raw.5,
                selectors: raw.6
            )
        }
        .eraseToAny()
    }

    private static var devices: Generator<[DeviceShape], AnySequence<Any>> {
        zip(Gen.int(in: 0...9), Gen.int(in: 0...9), Gen.int(in: 0...9))
            .map { DeviceShape(hardwareDigit: $0.0, osMinor: $0.1, osPatch: $0.2) }
            .array(of: 1...3)
            .eraseToAny()
    }

    private static var magnitudes: Generator<[Magnitude], AnySequence<Any>> {
        zip(Gen.int(in: 1...1_000_000), Gen.int(in: 0...999))
            .map { Magnitude(whole: $0.0, thousandths: $0.1) }
            .array(of: numericPairs.count)
            .eraseToAny()
    }

    private static var thermalCeilings: Generator<[ThermalState], AnySequence<Any>> {
        Gen.int(in: 0...(admissibleThermalStates.count - 1))
            .map { admissibleThermalStates[$0] }
            .array(of: ExecutionTarget.allCases.count)
            .eraseToAny()
    }

    private static var method: Generator<MethodShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 1...50),
            Gen.int(in: 0...(SummaryStatistic.allCases.count - 1)),
            Gen.bool,
            Gen.bool,
            Gen.int(in: 0...(admissibleThermalStates.count - 1))
        )
        .map {
            MethodShape(
                sampleCount: $0.0,
                statisticIndex: $0.1,
                concurrent: $0.2,
                pluggedIn: $0.3,
                startingThermalIndex: $0.4
            )
        }
        .eraseToAny()
    }

    private static var selectors: Generator<Selectors, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...99),
            Gen.int(in: 0...99),
            Gen.int(in: 0...99),
            Gen.int(in: 0...99)
        )
        .map {
            Selectors(
                metric: $0.0,
                comparison: $0.1,
                device: $0.2,
                placeholderToken: $0.3
            )
        }
        .eraseToAny()
    }
}

// MARK: - Scenario

/// A generated shape and the artifacts built from it.
///
/// Every arm mutates one plain data table — the limit table, the conditions table, the
/// measurement list, or the comparison list — and lets the artifacts be rebuilt from it,
/// so a mutation cannot leave two parts of the shape disagreeing about anything except
/// the one thing the arm is about.
private struct ResourcePlanScenario {
    let shape: ResourcePlanShape

    // MARK: Identifiers, evidence, and scalars

    private var seed: Int { shape.seed }

    private func artifact(_ raw: String) -> ArtifactID { ArtifactID(raw)! }

    var planID: ArtifactID { artifact("plan.device-validation-\(seed)") }
    var mainBudgetID: ArtifactID { artifact("budget.main-application-\(seed)") }
    var extensionBudgetID: ArtifactID { artifact("budget.share-extension-\(seed)") }
    var manifestID: ArtifactID { artifact("manifest.capability-\(seed)") }
    var suiteID: ArtifactID { artifact("suite.fixtures-\(seed)") }

    var conditionsID: ArtifactID { artifact("evidence.measurement-conditions-\(seed)") }
    var workloadID: ArtifactID { artifact("evidence.workload-\(seed)") }
    var referenceID: ArtifactID { artifact("evidence.comparison-reference-\(seed)") }
    var approvalID: ArtifactID { artifact("evidence.plan-approval-\(seed)") }

    /// A decided artifact this release does not carry, for the missing-condition arm.
    var unindexedID: ArtifactID { artifact("evidence.not-carried-\(seed)") }

    /// A placeholder token where a decided artifact reference belongs.
    ///
    /// Drawn from the schema's own placeholder vocabulary, filtered to the tokens that are
    /// canonical identifiers: `??` is refused one layer lower, by identifier syntax, so it
    /// would test the wrong thing here.
    var placeholderID: ArtifactID {
        let tokens = ArtifactSchemaValidation.placeholderTokens.sorted().compactMap(ArtifactID.init)
        return tokens[shape.selectors.placeholderToken % tokens.count]
    }

    var bundleID: ModelBundleID { ModelBundleID("bundle.model-\(seed)")! }
    var appBuildID: AppBuildID { AppBuildID("build.app-\(seed)")! }

    private var version: SchemaSemanticVersion {
        try! SchemaSemanticVersion(validating: "1.\(seed % 1_000).0")
    }

    private var contentDigest: SHA256Digest {
        let hexadecimal = String(seed, radix: 16)
        return SHA256Digest(
            hexadecimal: String(repeating: "0", count: 64 - hexadecimal.count) + hexadecimal
        )!
    }

    /// Evidence at this shape's version and digest, so a reference built the same way
    /// resolves and one built against another artifact does not.
    func evidence(_ artifact: ArtifactID) -> EvidenceSource {
        EvidenceSource(artifact: artifact, version: version, contentDigest: contentDigest)
    }

    var summaryStatistic: SummaryStatistic {
        SummaryStatistic.allCases[shape.method.statisticIndex]
    }

    var startingThermalState: ThermalState {
        ResourcePlanShape.admissibleThermalStates[shape.method.startingThermalIndex]
    }

    var branchExecution: EvidenceBranchExecution {
        shape.method.concurrent ? .concurrent : .serial
    }

    static func requiredMetrics(_ target: ExecutionTarget) -> [ResourceMetric] {
        ResourceMetric.requiredMetrics(for: target).sorted { $0.rawValue < $1.rawValue }
    }

    /// The required metric this case's mutation arms break, for one target.
    func selectedMetric(_ target: ExecutionTarget) -> ResourceMetric {
        let metrics = Self.requiredMetrics(target)
        return metrics[shape.selectors.metric % metrics.count]
    }

    /// The required numeric metric this case's authority and cross-target arms break.
    func selectedNumericMetric(_ target: ExecutionTarget) -> ResourceMetric {
        let metrics = Self.requiredMetrics(target).filter { !$0.isCategorical }
        return metrics[shape.selectors.metric % metrics.count]
    }

    func selectedComparison(_ metrics: Set<ComparisonMetric>) -> ComparisonMetric {
        let sorted = metrics.sorted { $0.rawValue < $1.rawValue }
        return sorted[shape.selectors.comparison % sorted.count]
    }

    var selectedDevice: DeviceShape {
        shape.devices[shape.selectors.device % shape.devices.count]
    }

    // MARK: Baseline tables

    /// The generated limit for every required `(target, metric)` pair.
    ///
    /// Numeric limits come from the generated magnitude array, one magnitude per pair, so
    /// the two targets carry different numbers for the metrics they share and no two
    /// metrics of one target share a number by construction. The categorical metric takes
    /// that target's generated thermal ceiling.
    func baselineLimits() throws -> [TargetMetric: ValidatedLimit] {
        var table: [TargetMetric: ValidatedLimit] = [:]
        for (offset, pair) in ResourcePlanShape.numericPairs.enumerated() {
            table[pair] = .numeric(
                value: try PositiveDecimal(validating: shape.magnitudes[offset].value),
                unit: pair.metric.requiredUnit!
            )
        }
        for (offset, target) in ExecutionTarget.allCases.enumerated() {
            table[TargetMetric(target: target, metric: .thermalState)] = .thermal(
                maximumState: shape.thermalCeilings[offset]
            )
        }
        return table
    }

    /// The measurement conditions every limit cites (Requirement 11.4).
    func baselineConditions() -> [TargetMetric: ArtifactID] {
        var table: [TargetMetric: ArtifactID] = [:]
        for target in ExecutionTarget.allCases {
            for metric in Self.requiredMetrics(target) {
                table[TargetMetric(target: target, metric: metric)] = conditionsID
            }
        }
        return table
    }

    var requiredComparisons: Set<ComparisonMetric> {
        ComparisonMetric.requiredComparisons(provenanceEnabled: shape.provenanceEnabled)
    }

    // MARK: Builders

    func budget(
        target: ExecutionTarget,
        limits: [TargetMetric: ValidatedLimit],
        conditions: [TargetMetric: ArtifactID],
        identifier: ArtifactID? = nil,
        validationPlan: ArtifactID? = nil,
        omitting omitted: ResourceMetric? = nil,
        adding borrowed: ResourceMetric? = nil
    ) throws -> ResourceBudget {
        var metrics = Self.requiredMetrics(target).filter { $0 != omitted }
        if let borrowed { metrics.append(borrowed) }

        let entries = try metrics.map { metric -> ResourceLimitEntry in
            let key = TargetMetric(target: target, metric: metric)
            // A metric borrowed from the other target has no limit of this target's own,
            // so it carries the other target's number: that is exactly the confusion
            // Requirement 11.1's separation exists to prevent.
            let other = TargetMetric(target: target.otherTarget, metric: metric)
            guard let limit = limits[key] ?? limits[other] else {
                throw ArtifactSchemaError.missingRequiredEntries(
                    field: "test.limits",
                    keys: [metric.rawValue]
                )
            }
            return try ResourceLimitEntry(
                metric: metric,
                limit: limit,
                measurementConditions: evidence(
                    conditions[key] ?? conditions[other] ?? conditionsID
                )
            )
        }

        return try ResourceBudget(
            id: identifier ?? defaultBudgetID(target),
            schemaVersion: .v1,
            target: target,
            hardLimits: entries,
            validationPlan: validationPlan ?? planID
        )
    }

    func defaultBudgetID(_ target: ExecutionTarget) -> ArtifactID {
        switch target {
        case .mainApplication: mainBudgetID
        case .shareExtension: extensionBudgetID
        }
    }

    func budgets(
        limits: [TargetMetric: ValidatedLimit],
        conditions: [TargetMetric: ArtifactID]
    ) throws -> ResourceBudgetSet {
        try ResourceBudgetSet(
            mainApplication: budget(
                target: .mainApplication,
                limits: limits,
                conditions: conditions
            ),
            shareExtension: budget(
                target: .shareExtension,
                limits: limits,
                conditions: conditions
            )
        )
    }

    func configuration(_ device: DeviceShape, offset: Int) throws -> CandidateDeviceConfiguration {
        try CandidateDeviceConfiguration(
            deviceModel: Sample.text("Synthetic iPhone \(seed)-\(offset)"),
            hardwareIdentifier: DeviceHardwareID("iPhone\(17 + offset).\(device.hardwareDigit)")!,
            osVersion: try PlatformVersion(
                validating: "\(17 + offset).\(device.osMinor).\(device.osPatch)"
            ),
            appBuild: appBuildID,
            isAppleNeuralEngineCapable: true
        )
    }

    func configurations() throws -> [CandidateDeviceConfiguration] {
        try shape.devices.enumerated().map { try configuration($0.element, offset: $0.offset) }
    }

    func measurement(
        _ metric: ResourceMetric,
        target: ExecutionTarget,
        configuration: CandidateDeviceConfiguration,
        limits: [TargetMetric: ValidatedLimit]
    ) throws -> ResourceMeasurementSpecification {
        let key = TargetMetric(target: target, metric: metric)
        guard let passLimit = limits[key] else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: "test.limits",
                keys: [metric.rawValue]
            )
        }
        return try ResourceMeasurementSpecification(
            metric: metric,
            target: target,
            hardwareIdentifier: configuration.hardwareIdentifier,
            osVersion: configuration.osVersion,
            appBuild: configuration.appBuild,
            workload: evidence(workloadID),
            warmth: metric == .coldModelLoadTime ? .cold : .warm,
            branchExecution: branchExecution,
            startingThermalState: startingThermalState,
            startingPowerCondition: shape.method.pluggedIn
                ? .batteryPluggedIn
                : .batteryUnplugged,
            sampleCount: try PositiveCount(validating: shape.method.sampleCount),
            summaryStatistic: summaryStatistic,
            passLimit: passLimit
        )
    }

    /// Every candidate, target, and required metric, minus one when an arm omits it.
    func measurements(
        configurations: [CandidateDeviceConfiguration],
        limits: [TargetMetric: ValidatedLimit],
        omitting omitted: (device: DeviceShape, target: ExecutionTarget, metric: ResourceMetric)?
            = nil
    ) throws -> [ResourceMeasurementSpecification] {
        var declared: [ResourceMeasurementSpecification] = []
        for (offset, configuration) in configurations.enumerated() {
            for target in ExecutionTarget.allCases {
                for metric in Self.requiredMetrics(target) {
                    if let omitted,
                       omitted.target == target,
                       omitted.metric == metric,
                       omitted.device.hardwareDigit == shape.devices[offset].hardwareDigit,
                       omitted.device.osMinor == shape.devices[offset].osMinor,
                       omitted.device.osPatch == shape.devices[offset].osPatch
                    {
                        continue
                    }
                    declared.append(
                        try measurement(
                            metric,
                            target: target,
                            configuration: configuration,
                            limits: limits
                        )
                    )
                }
            }
        }
        return declared
    }

    func comparisons(omitting omitted: ComparisonMetric? = nil) throws -> [ComparisonSpecification] {
        try requiredComparisons
            .subtracting(omitted.map { [$0] } ?? [])
            .sorted { $0.rawValue < $1.rawValue }
            .map { metric in
                try ComparisonSpecification(
                    metric: metric,
                    reference: evidence(referenceID),
                    tolerance: metric.isCategorical
                        ? nil
                        : try NumericTolerance(
                            kind: .absolute,
                            value: try NonNegativeDecimal(
                                validating: Decimal(seed % 10) / 100
                            )
                        ),
                    // Every categorical comparison here is an identity claim, and
                    // Requirement 13.8 fixes the Pixel Evidence outcome ratio at 100%.
                    requiredAgreement: metric.isCategorical ? .one : nil
                )
            }
    }

    func plan(
        limits: [TargetMetric: ValidatedLimit],
        omittingMeasurement omittedMeasurement: (
            device: DeviceShape, target: ExecutionTarget, metric: ResourceMetric
        )? = nil,
        omittingComparison omittedComparison: ComparisonMetric? = nil,
        approvalArtifact: ArtifactID? = nil
    ) throws -> DeviceValidationPlan {
        let candidates = try configurations()
        return try DeviceValidationPlan(
            id: planID,
            schemaVersion: .v1,
            candidateConfigurations: candidates,
            fixtureSuite: suiteID,
            modelBundle: bundleID,
            capabilityManifest: manifestID,
            comparisons: try comparisons(omitting: omittedComparison),
            measurements: try measurements(
                configurations: candidates,
                limits: limits,
                omitting: omittedMeasurement
            ),
            missingResultRule: .treatAsFailure,
            approval: ApprovalRecord(
                source: evidence(approvalArtifact ?? approvalID),
                decision: .approved,
                approver: Sample.approver(),
                decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
    }

    func capabilityManifest() throws -> ReleaseCapabilityManifest {
        let capabilities: Set<CapabilityID> = shape.provenanceEnabled
            ? [.pixelAnalysis, .contentCredentialValidation]
            : [.pixelAnalysis]
        return try ReleaseCapabilityManifest(
            id: manifestID,
            schemaVersion: .v1,
            appBuild: appBuildID,
            compositionIdentifier: Sample.text(
                shape.provenanceEnabled ? "pixel-plus-provenance" : "pixel-only"
            ),
            compiledCapabilities: capabilities,
            implementationVersions: capabilities.sorted { $0.rawValue < $1.rawValue }.map {
                CapabilityImplementationEntry(capability: $0, version: Sample.version())
            },
            approvedConfigurationAllowlist: Sample.artifact("allowlist.devices"),
            approvedBundleCatalog: [bundleID],
            policyCompatibility: try Sample.policyCompatibility(
                provenance: shape.provenanceEnabled
                    ? .bound(Sample.artifact("policy.provenance"))
                    : .notApplicable(decision: Sample.approval())
            ),
            approval: Sample.approval()
        )
    }

    func evidenceIndex() throws -> ReleaseEvidenceIndex {
        try ReleaseEvidenceIndex(
            records: [conditionsID, workloadID, referenceID, approvalID].map { evidence($0) }
        )
    }

    func activate(
        plan: DeviceValidationPlan,
        budgets: ResourceBudgetSet
    ) throws -> ValidatedResourcePlan {
        try ValidatedResourcePlan(
            activating: plan,
            budgets: budgets,
            fixtureSuite: try ResourcePlanSample.fixtureSuite(
                identifier: suiteID.rawValue,
                provenanceEnabled: shape.provenanceEnabled
            ),
            capabilityManifest: try capabilityManifest(),
            evidence: try evidenceIndex()
        )
    }

    /// The coherent baseline, built from the unmutated tables.
    func activateBaseline() throws -> ValidatedResourcePlan {
        let limits = try baselineLimits()
        return try activate(
            plan: try plan(limits: limits),
            budgets: try budgets(limits: limits, conditions: baselineConditions())
        )
    }

    // MARK: Valid arm

    /// A complete, coherent shape activates, and every limit it reports is the number the
    /// plan measured for that metric and target.
    ///
    /// Without this arm the property would pass by refusing everything.
    func checkCoherentShapeActivates() {
        let limits: [TargetMetric: ValidatedLimit]
        let activated: ValidatedResourcePlan
        do {
            limits = try baselineLimits()
            activated = try activateBaseline()
        } catch {
            Issue.record("a coherent generated plan was refused: \(error) [\(shape)]")
            return
        }

        #expect(activated.id == planID)
        #expect(activated.enablesProvenance == shape.provenanceEnabled)
        #expect(activated.missingResultRule == .treatAsFailure)
        #expect(activated.candidateConfigurations.count == shape.devices.count)

        for target in ExecutionTarget.allCases {
            // Total over the target's own metric set, and `nil` for every metric of the
            // other target: Requirement 11.1's separation read back through the accessor.
            for metric in ResourceMetric.allCases {
                let key = TargetMetric(target: target, metric: metric)
                let reported = activated.hardLimit(metric, for: target)
                if ResourceMetric.requiredMetrics(for: target).contains(metric) {
                    #expect(reported == limits[key], "\(target.rawValue)/\(metric.rawValue)")
                } else {
                    #expect(reported == nil, "\(target.rawValue)/\(metric.rawValue)")
                }

                // Requirements 15.8 and 15.9: an analysis-time limit exists exactly for an
                // elapsed-time metric of that target, and it is the plan's own number.
                let elapsed = activated.analysisTimeLimitMilliseconds(metric, for: target)
                if metric.measuresElapsedTime,
                   ResourceMetric.requiredMetrics(for: target).contains(metric)
                {
                    #expect(elapsed?.value == shape.magnitude(for: key))
                } else {
                    #expect(elapsed == nil, "\(target.rawValue)/\(metric.rawValue)")
                }
            }
        }

        // Requirement 11.4 lists concurrency among the declared conditions, so the
        // approved execution policy is read back from the plan rather than chosen.
        for configuration in activated.candidateConfigurations {
            #expect(
                activated.approvesConcurrentEvidenceBranches(for: configuration)
                    == shape.method.concurrent
            )
        }
    }

    // MARK: Authority arm

    /// A budget number the plan did not measure is refused.
    ///
    /// The budget's hard limit and the plan's declared pass limit are independent fields,
    /// so a number typed into a budget reads exactly like a measured one. Requiring them
    /// to agree is what makes the plan the only source of a limit.
    func checkPlanIsTheOnlySourceOfALimit() {
        let metric = selectedNumericMetric(.mainApplication)
        let key = TargetMetric(target: .mainApplication, metric: metric)

        expectRefused("a budget number the plan did not measure", .inconsistentReference) {
            let measured = try self.baselineLimits()
            var shipped = measured
            shipped[key] = .numeric(
                value: try PositiveDecimal(
                    validating: self.shape.magnitude(for: key)! + 1
                ),
                unit: metric.requiredUnit!
            )
            _ = try self.activate(
                plan: try self.plan(limits: measured),
                budgets: try self.budgets(limits: shipped, conditions: self.baselineConditions())
            )
        }
    }

    // MARK: Missing arm

    /// An absent required metric, measurement, measurement condition, or predeclared
    /// comparison is refused.
    ///
    /// "Absent" is the representable form in each case. A metric or a measurement can be
    /// dropped from its list; measurement conditions are a non-optional field, so the
    /// representable absence is a reference to evidence this release does not carry.
    func checkMissingValuesAreRefused() {
        for target in ExecutionTarget.allCases {
            let metric = selectedMetric(target)

            expectRefused(
                "a \(target.rawValue) budget missing \(metric.rawValue)",
                .missingRequiredEntries
            ) {
                _ = try self.budget(
                    target: target,
                    limits: try self.baselineLimits(),
                    conditions: self.baselineConditions(),
                    omitting: metric
                )
            }

            expectRefused(
                "a plan missing the \(target.rawValue)/\(metric.rawValue) measurement",
                .missingRequiredEntries
            ) {
                _ = try self.plan(
                    limits: try self.baselineLimits(),
                    omittingMeasurement: (self.selectedDevice, target, metric)
                )
            }
        }

        let key = TargetMetric(
            target: .shareExtension,
            metric: selectedMetric(.shareExtension)
        )
        expectRefused("measurement conditions the release does not carry", .missingRequiredEntries) {
            let limits = try self.baselineLimits()
            var conditions = self.baselineConditions()
            conditions[key] = self.unindexedID
            _ = try self.activate(
                plan: try self.plan(limits: limits),
                budgets: try self.budgets(limits: limits, conditions: conditions)
            )
        }

        let comparison = selectedComparison(requiredComparisons)
        expectRefused(
            "a plan missing the \(comparison.rawValue) comparison",
            .missingRequiredEntries
        ) {
            let limits = try self.baselineLimits()
            _ = try self.activate(
                plan: try self.plan(limits: limits, omittingComparison: comparison),
                budgets: try self.budgets(limits: limits, conditions: self.baselineConditions())
            )
        }
    }

    // MARK: Placeholder arm

    /// A value that looks supplied but carries no measurement is refused.
    ///
    /// Two forms, and they are different faults:
    ///
    ///   * a lexical placeholder token where a decided artifact reference belongs. The
    ///     field is populated and syntactically valid, so nothing below this layer
    ///     objects, but `tbd` names no evidence and never will. The tokens come from the
    ///     schema's own vocabulary rather than a list invented here.
    ///   * a thermal ceiling of `critical`. `critical` is the hottest state, so the limit
    ///     admits every observation: it is the categorical form of zero-as-unknown, and a
    ///     gate that cannot be exceeded records no measurement. This one is generated as
    ///     a fully coherent shape — the plan measures `critical` and the budget ships
    ///     `critical` — so the refusal is about the value and not about a disagreement.
    func checkPlaceholderValuesAreRefused() {
        let key = TargetMetric(target: .mainApplication, metric: selectedMetric(.mainApplication))
        expectRefused("a placeholder token for measurement conditions", .placeholderValue) {
            let limits = try self.baselineLimits()
            var conditions = self.baselineConditions()
            conditions[key] = self.placeholderID
            _ = try self.activate(
                plan: try self.plan(limits: limits),
                budgets: try self.budgets(limits: limits, conditions: conditions)
            )
        }

        expectRefused("a placeholder token for the plan approval", .placeholderValue) {
            let limits = try self.baselineLimits()
            _ = try self.activate(
                plan: try self.plan(limits: limits, approvalArtifact: self.placeholderID),
                budgets: try self.budgets(limits: limits, conditions: self.baselineConditions())
            )
        }

        for target in ExecutionTarget.allCases {
            expectRefused(
                "a \(target.rawValue) thermal ceiling of critical", .forbiddenValue
            ) {
                var limits = try self.baselineLimits()
                limits[TargetMetric(target: target, metric: .thermalState)] = .thermal(
                    maximumState: .critical
                )
                _ = try self.activate(
                    plan: try self.plan(limits: limits),
                    budgets: try self.budgets(
                        limits: limits,
                        conditions: self.baselineConditions()
                    )
                )
            }
        }
    }

    // MARK: Nonpositive arm

    /// Zero and negative limits and sample counts are refused rather than treated as a
    /// floor.
    ///
    /// The refusal is at the scalar layer, which is the strongest available form: a
    /// numeric ``ValidatedLimit`` carries a ``PositiveDecimal`` and a measurement carries a
    /// ``PositiveCount``, so a nonpositive limit or sample count cannot be placed in a
    /// budget or a plan at all. Asserting it here rather than at the budget is deliberate
    /// — there is no budget to build.
    func checkNonpositiveValuesAreUnrepresentable() {
        let magnitude = shape.magnitudes[0].value
        for nonpositive in [Decimal(0), -magnitude, -1] {
            expectRefused("a limit of \(nonpositive)", .nonPositiveValue) {
                _ = try PositiveDecimal(validating: nonpositive)
            }
        }
        for nonpositive in [0, -shape.method.sampleCount] {
            expectRefused("a sample count of \(nonpositive)", .nonPositiveValue) {
                _ = try PositiveCount(validating: nonpositive)
            }
        }
    }

    // MARK: Cross-target arm

    /// A budget or measurement belonging to the other target is refused, in both
    /// directions.
    ///
    /// Requirement 11.1 separates the two budgets, and the point of the separation is
    /// that neither one can stand in for the other. Three forms, each asserted both ways:
    /// a budget carrying a metric only the other target measures; a budget pair holding
    /// two budgets of the same target; and a measurement of a metric its target does not
    /// measure.
    func checkCrossTargetValuesAreRefused() {
        for target in ExecutionTarget.allCases {
            let other = target.otherTarget
            let borrowed = selectedForeignMetric(for: target)

            expectRefused(
                "a \(target.rawValue) budget carrying \(borrowed.rawValue)", .unexpectedEntries
            ) {
                _ = try self.budget(
                    target: target,
                    limits: try self.baselineLimits(),
                    conditions: self.baselineConditions(),
                    adding: borrowed
                )
            }

            // A pair whose two budgets both describe `other`: the slot for `target` holds a
            // budget of the wrong target, which is the direction this iteration asserts.
            expectRefused(
                "a \(other.rawValue) budget in the \(target.rawValue) slot", .fixedValueMismatch
            ) {
                let limits = try self.baselineLimits()
                let conditions = self.baselineConditions()
                let substitute = try self.budget(
                    target: other,
                    limits: limits,
                    conditions: conditions,
                    identifier: self.artifact("budget.substitute-\(self.seed)")
                )
                let own = try self.budget(target: other, limits: limits, conditions: conditions)
                _ = try ResourceBudgetSet(
                    mainApplication: target == .mainApplication ? substitute : own,
                    shareExtension: target == .mainApplication ? own : substitute
                )
            }

            expectRefused(
                "a \(target.rawValue) measurement of \(borrowed.rawValue)", .forbiddenValue
            ) {
                var limits = try self.baselineLimits()
                limits[TargetMetric(target: target, metric: borrowed)] =
                    limits[TargetMetric(target: other, metric: borrowed)]
                _ = try self.measurement(
                    borrowed,
                    target: target,
                    configuration: try self.configuration(self.selectedDevice, offset: 0),
                    limits: limits
                )
            }
        }
    }

    /// A required metric of the other target that this target does not measure.
    func selectedForeignMetric(for target: ExecutionTarget) -> ResourceMetric {
        let own = ResourceMetric.requiredMetrics(for: target)
        let foreign = Self.requiredMetrics(target.otherTarget).filter { !own.contains($0) }
        return foreign[shape.selectors.metric % foreign.count]
    }

    // MARK: Refusal helper

    /// Requires `build` to refuse with a specific fault, recording an issue otherwise.
    ///
    /// Never rethrows. `propertyCheck` discards an error thrown by its body without
    /// recording an issue, so a refusal that escaped as a throw would make this property
    /// pass vacuously.
    func expectRefused(
        _ what: String,
        _ expected: ResourcePlanFault,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ build: () throws -> Void
    ) {
        do {
            try build()
            Issue.record("\(what) was accepted [\(shape)]", sourceLocation: sourceLocation)
        } catch let error as ArtifactSchemaError {
            #expect(
                ResourcePlanFault(error) == expected,
                "\(what) was refused as \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
        } catch {
            Issue.record(
                "\(what) failed with a non-schema error \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
        }
    }
}

extension ExecutionTarget {
    /// The other execution target. There are exactly two, and every cross-target
    /// assertion needs both directions.
    fileprivate var otherTarget: ExecutionTarget {
        switch self {
        case .mainApplication: .shareExtension
        case .shareExtension: .mainApplication
        }
    }
}

extension ResourcePlanShape {
    /// The generated magnitude for one numeric pair, or `nil` for the categorical metric.
    fileprivate func magnitude(for pair: TargetMetric) -> Decimal? {
        guard let offset = Self.numericPairs.firstIndex(of: pair) else { return nil }
        return magnitudes[offset].value
    }
}

// MARK: - Fault classification

/// Which ``ArtifactSchemaError`` a refusal reported, without its field strings.
///
/// Asserting the case rather than the whole value keeps the property about *why* an
/// artifact was refused while leaving the audit message free to change. Asserting nothing
/// about the case would let an unrelated fault stand in for the one an arm is about.
private enum ResourcePlanFault: Equatable {
    case emptyValue
    case placeholderValue
    case noncanonicalValue
    case valueOutOfRange
    case nonPositiveValue
    case nonFiniteValue
    case duplicateEntry
    case missingRequiredEntries
    case unexpectedEntries
    case fixedValueMismatch
    case forbiddenValue
    case inconsistentReference

    init(_ error: ArtifactSchemaError) {
        switch error {
        case .emptyValue: self = .emptyValue
        case .placeholderValue: self = .placeholderValue
        case .noncanonicalValue: self = .noncanonicalValue
        case .valueOutOfRange: self = .valueOutOfRange
        case .nonPositiveValue: self = .nonPositiveValue
        case .nonFiniteValue: self = .nonFiniteValue
        case .duplicateEntry: self = .duplicateEntry
        case .missingRequiredEntries: self = .missingRequiredEntries
        case .unexpectedEntries: self = .unexpectedEntries
        case .fixedValueMismatch: self = .fixedValueMismatch
        case .forbiddenValue: self = .forbiddenValue
        case .inconsistentReference: self = .inconsistentReference
        }
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator actually produced, so the property cannot pass by
/// generating one fixed shape a hundred times.
///
/// A property whose baseline never varies asserts one example a hundred times over. This
/// collects the dimensions the arms depend on and requires each to have been exercised
/// with more than one value. The thresholds are far below what 100 uniform draws produce,
/// so this witnesses variation rather than pinning a distribution.
private final class ResourcePlanVariationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var limitValues = Set<Decimal>()
    private var deviceCounts = Set<Int>()
    private var provenanceFlags = Set<Bool>()
    private var thermalCeilings = Set<ThermalState>()
    private var statistics = Set<Int>()
    private var cases = 0

    func record(_ shape: ResourcePlanShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        limitValues.formUnion(shape.magnitudes.map(\.value))
        deviceCounts.insert(shape.devices.count)
        provenanceFlags.insert(shape.provenanceEnabled)
        thermalCeilings.formUnion(shape.thermalCeilings)
        statistics.insert(shape.method.statisticIndex)
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases")
        // One shape carries 11 numeric limits, so a constant baseline would show 11.
        #expect(limitValues.count >= 100, "generated limit values: \(limitValues.count)")
        #expect(deviceCounts == [1, 2, 3], "generated candidate counts: \(deviceCounts.sorted())")
        #expect(provenanceFlags == [false, true], "both capability sets are generated")
        #expect(
            thermalCeilings == Set(ResourcePlanShape.admissibleThermalStates),
            "generated thermal ceilings: \(thermalCeilings.map(\.rawValue).sorted())"
        )
        #expect(
            statistics.count == SummaryStatistic.allCases.count,
            "generated summary statistics: \(statistics.sorted())"
        )
    }
}
