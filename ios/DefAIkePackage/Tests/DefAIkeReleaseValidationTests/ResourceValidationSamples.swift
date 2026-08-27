import DefAIkeDomain
import Foundation

@testable import DefAIkeReleaseValidation

// Synthetic samples for the resource-measurement runners, and a bounded in-memory sample
// reader.
//
// Every value here is deliberately synthetic. None of these is an approved Device Validation
// Plan, an approved Resource Budget, an approved sample count, an approved summary statistic, an
// approved measurement condition, an approved pass limit, an approved candidate configuration,
// or a real physical-device measurement. The tests build a structurally complete run and then
// change one thing at a time.
//
// Three things are worth being explicit about, because a reader could mistake any of them for a
// claim this suite is not making.
//
// **A sample that says `.physicalIPhone` is a claim, not evidence.** `ResourceSample` takes its
// environment as a parameter because the real caller is a device harness that knows where it
// ran. A test can therefore exercise the comparison arithmetic on a host. What a test cannot do
// is make a *gate* pass: `gateResult(for:)` consults `ObservedParityEnvironment.current`, which
// is compiled from the platform and has no parameter. So every gate in this suite fails,
// deliberately, and ``ResourcePhysicalDeviceGateTests`` asserts exactly that.
//
// **A sample that says `.mainApplication` is also a claim.** The store lets a test file a
// main-application sample against a Share Extension cell, which is how the target-separation
// refusal is exercised at all. The runner refuses it.
//
// **Most cells in a "complete" store hold nothing, and that is correct.** Five budget metrics
// have no measurement path in this repository — temporary storage, all three latencies, and
// energy — and cancellation residual work and interruption cleanup cannot be predeclared at
// all. The runner refuses those seven before reading, so a store that held samples for them
// would be describing calls that never happen. Only decoded pixel count or encoded input size,
// peak resident memory, and thermal state are ever read.

extension Sample {

    // MARK: Plan

    /// A plan declaring a complete measurement specification for both targets on one candidate
    /// configuration.
    ///
    /// The thermal statistic is `.maximum` rather than the `.median` the parity samples use,
    /// because a nonordinal statistic over a categorical metric is a binding error and `.median`
    /// happens to be ordinal — the tests exercise both deliberately rather than by accident.
    static func resourcePlan(
        hardware overrideHardware: DeviceHardwareID? = nil,
        appBuild overrideBuild: AppBuildID? = nil,
        sampleCount samples: PositiveCount? = nil,
        thermalStatistic: SummaryStatistic = .maximum,
        numericStatistic: SummaryStatistic = .median,
        limits: [ResourceMetric: ValidatedLimit] = [:],
        planIdentifier: String = "plan.device-validation",
        measurementAppBuild: AppBuildID? = nil,
        extraConfigurations: [CandidateDeviceConfiguration] = []
    ) throws -> DeviceValidationPlan {
        let device = overrideHardware ?? hardware()
        let build = overrideBuild ?? appBuild()
        let configuration = try candidateConfiguration(hardware: device, appBuild: build)
        return try DeviceValidationPlan(
            id: artifact(planIdentifier),
            schemaVersion: .v1,
            candidateConfigurations: [configuration] + extraConfigurations,
            fixtureSuite: artifact("suite.fixtures"),
            modelBundle: bundle(),
            capabilityManifest: artifact("manifest.capability"),
            comparisons: try ComparisonMetric.allCases
                .sorted { $0.rawValue < $1.rawValue }
                .map { metric in
                    try ComparisonSpecification(
                        metric: metric,
                        reference: evidence("evidence.reference.\(metric.rawValue)"),
                        tolerance: metric.isCategorical
                            ? nil
                            : try NumericTolerance(kind: .absolute, value: nonNegativeDecimal(1)),
                        requiredAgreement: metric.isCategorical ? ratio(1) : nil
                    )
                },
            measurements: try (
                [configuration] + extraConfigurations
            ).flatMap { candidate in
                try ExecutionTarget.allCases.flatMap { target in
                    try ResourceMetric.requiredMetrics(for: target)
                        .sorted { $0.rawValue < $1.rawValue }
                        .map { metric in
                            try ResourceMeasurementSpecification(
                                metric: metric,
                                target: target,
                                hardwareIdentifier: candidate.hardwareIdentifier,
                                osVersion: candidate.osVersion,
                                appBuild: measurementAppBuild ?? candidate.appBuild,
                                workload: evidence(
                                    "evidence.workload.\(target.rawValue).\(metric.rawValue)"
                                ),
                                warmth: metric == .coldModelLoadTime ? .cold : .warm,
                                branchExecution: .serial,
                                startingThermalState: .nominal,
                                startingPowerCondition: .batteryUnplugged,
                                sampleCount: samples ?? count(5),
                                summaryStatistic: metric.isCategorical
                                    ? thermalStatistic
                                    : numericStatistic,
                                passLimit: limits[metric] ?? limit(for: metric)
                            )
                        }
                }
            },
            missingResultRule: .treatAsFailure,
            approval: approval()
        )
    }

    // MARK: Budgets

    /// A budget pair whose hard limits are the plan's declared pass limits.
    ///
    /// They have to agree: the plan is the authoritative release source for numeric limits
    /// (Requirement 15.9), and ``ResourceBindingError/passLimitDisagreesWithBudget(_:_:)``
    /// refuses a pair that publishes two different numbers for one metric.
    static func resourceBudgets(
        validationPlan: String = "plan.device-validation",
        limits: [ResourceMetric: ValidatedLimit] = [:],
        mainApplicationIdentifier: String = "budget.main-application",
        shareExtensionIdentifier: String = "budget.share-extension"
    ) throws -> ResourceBudgetSet {
        try ResourceBudgetSet(
            mainApplication: try resourceBudget(
                target: .mainApplication,
                identifier: mainApplicationIdentifier,
                validationPlan: validationPlan,
                limits: limits
            ),
            shareExtension: try resourceBudget(
                target: .shareExtension,
                identifier: shareExtensionIdentifier,
                validationPlan: validationPlan,
                limits: limits
            )
        )
    }

    static func resourceBudget(
        target: ExecutionTarget,
        identifier: String,
        validationPlan: String = "plan.device-validation",
        limits: [ResourceMetric: ValidatedLimit] = [:]
    ) throws -> ResourceBudget {
        try ResourceBudget(
            id: artifact(identifier),
            schemaVersion: .v1,
            target: target,
            hardLimits: try ResourceMetric.requiredMetrics(for: target)
                .sorted { $0.rawValue < $1.rawValue }
                .map { metric in
                    try ResourceLimitEntry(
                        metric: metric,
                        limit: limits[metric] ?? limit(for: metric),
                        measurementConditions: evidence(
                            "evidence.conditions.\(target.rawValue).\(metric.rawValue)"
                        )
                    )
                },
            validationPlan: artifact(validationPlan)
        )
    }

    // MARK: Version tuple

    static func resourceVersionTuple(
        provenanceEnabled: Bool = false,
        validationPlan: String = "plan.device-validation",
        appBuild overrideBuild: AppBuildID? = nil
    ) throws -> ValidationVersionTuple {
        try parityVersionTuple(
            provenanceEnabled: provenanceEnabled,
            validationPlan: validationPlan,
            appBuild: overrideBuild
        )
    }

    // MARK: Bindings

    static func resourceTargetBinding(
        target: ExecutionTarget,
        plan overridePlan: DeviceValidationPlan? = nil,
        budgets overrideBudgets: ResourceBudgetSet? = nil,
        configuration overrideConfiguration: CandidateDeviceConfiguration? = nil,
        versionTuple overrideTuple: ValidationVersionTuple? = nil
    ) throws -> ResourceTargetBinding {
        try ResourceTargetBinding(
            target: target,
            plan: overridePlan ?? resourcePlan(),
            budgets: overrideBudgets ?? resourceBudgets(),
            configuration: overrideConfiguration ?? candidateConfiguration(),
            versionTuple: overrideTuple ?? resourceVersionTuple()
        )
    }

    static func resourceRunBinding(
        plan overridePlan: DeviceValidationPlan? = nil,
        budgets overrideBudgets: ResourceBudgetSet? = nil,
        configuration overrideConfiguration: CandidateDeviceConfiguration? = nil,
        versionTuple overrideTuple: ValidationVersionTuple? = nil
    ) throws -> ResourceValidationRunBinding {
        try ResourceValidationRunBinding(
            plan: overridePlan ?? resourcePlan(),
            budgets: overrideBudgets ?? resourceBudgets(),
            configuration: overrideConfiguration ?? candidateConfiguration(),
            versionTuple: overrideTuple ?? resourceVersionTuple()
        )
    }

    // MARK: Values

    /// A magnitude comfortably inside ``Sample/limit(for:)``'s ceiling of 100.
    ///
    /// Varies with the sample position so a series is not a constant, which is what lets the
    /// median, maximum, and percentile tests distinguish the statistics from one another.
    static func withinLimitMagnitude(at ordinal: Int) -> Decimal {
        Decimal(10 + ordinal)
    }

    /// A within-limit sample value for one metric.
    static func withinLimitValue(for metric: ResourceMetric, at ordinal: Int) -> ObservedResourceValue
    {
        metric.isCategorical
            ? .thermalState(.nominal)
            : .quantity(withinLimitMagnitude(at: ordinal), unit: unit(for: metric))
    }

    /// The cells of one binding the runner actually reads samples for.
    ///
    /// The three whose metric has a measurement path in this repository. Everything else is
    /// refused before the seam is touched.
    static func readableCells(of binding: ResourceTargetBinding) -> [ResourceCell] {
        binding.requiredCells.filter { cell in
            guard cell.metric != nil else { return false }
            return !cell.standingMeasurementLimits.contains { $0.blocksMeasurement }
        }
    }

    /// The cells of one binding the runner refuses before touching the seam.
    static func blockedCells(of binding: ResourceTargetBinding) -> [ResourceCell] {
        binding.requiredCells.filter { cell in
            cell.standingMeasurementLimits.contains { $0.blocksMeasurement }
        }
    }
}

// MARK: - Read-only in-memory sample reader

/// A bounded in-memory ``ResourceSampleReading`` for resource-runner tests.
///
/// Read-only, like the seam it implements. The mutators change what the store *already holds* so
/// a test can stage a missing, short, cross-target, wrong-unit, or non-qualifying series; the
/// runner under test never reaches them.
///
/// An empty store is the honest default state of this repository: nothing has been measured on a
/// physical iPhone, so every position is missing. That is why ``empty`` is a named value rather
/// than something a test has to build.
struct FakeResourceSampleStore: ResourceSampleReading {
    /// The value at each declared position.
    var values: [ResourceCell: [Int: ObservedResourceValue]] = [:]

    /// Per-cell overrides for the conditions a sample claims.
    var targets: [ResourceCell: ExecutionTarget] = [:]
    var environments: [ResourceCell: ExecutionEnvironment] = [:]
    var configurations: [ResourceCell: CandidateDeviceConfiguration] = [:]
    var versionTuples: [ResourceCell: ValidationVersionTuple] = [:]

    /// Positions that exist but cannot be read, and metrics the environment cannot measure.
    var unreadable: Set<ResourceCellPosition> = []
    var notMeasurable: Set<ResourceCell> = []
    var isUnavailable = false

    /// The default conditions every sample claims.
    var defaultTarget: ExecutionTarget
    var defaultEnvironment: ExecutionEnvironment = .physicalIPhone
    var defaultConfiguration: CandidateDeviceConfiguration
    var defaultVersionTuple: ValidationVersionTuple

    /// One cell and one position, so a test can stage a single sample of a series.
    struct ResourceCellPosition: Hashable {
        let cell: ResourceCell
        let ordinal: Int
    }

    /// A store holding nothing at all.
    static func empty(for binding: ResourceTargetBinding) -> FakeResourceSampleStore {
        FakeResourceSampleStore(
            defaultTarget: binding.target,
            defaultConfiguration: binding.configuration,
            defaultVersionTuple: binding.versionTuple
        )
    }

    /// A store whose every declared position of every readable cell holds a within-limit value.
    ///
    /// "Readable" is not a choice this helper makes: it is the cells the runner asks about at
    /// all, which is every cell whose standing limits do not block the measurement. The other
    /// seven per target are refused before the seam.
    static func complete(for binding: ResourceTargetBinding) -> FakeResourceSampleStore {
        var store = empty(for: binding)
        for cell in binding.requiredCells {
            guard let metric = cell.metric else { continue }
            guard !cell.standingMeasurementLimits.contains(where: { $0.blocksMeasurement }) else {
                continue
            }
            let declared = binding.declaredSampleCount(for: cell)
            var series: [Int: ObservedResourceValue] = [:]
            for ordinal in 0..<declared {
                series[ordinal] = Sample.withinLimitValue(for: metric, at: ordinal)
            }
            store.values[cell] = series
        }
        return store
    }

    /// A store covering both targets of one run binding.
    static func complete(for binding: ResourceValidationRunBinding) -> FakeResourceSampleStore {
        var store = complete(for: binding.mainApplication)
        let extensionStore = complete(for: binding.shareExtension)
        for (cell, series) in extensionStore.values {
            store.values[cell] = series
        }
        // Each sample reports the process its own cell names, which is what a real pair of
        // harnesses would do. A cross-target test overrides one cell explicitly.
        for cell in binding.shareExtension.requiredCells {
            store.targets[cell] = .shareExtension
        }
        for cell in binding.mainApplication.requiredCells {
            store.targets[cell] = .mainApplication
        }
        return store
    }

    // MARK: Staging

    mutating func removeSample(_ cell: ResourceCell, at ordinal: Int) {
        values[cell]?.removeValue(forKey: ordinal)
    }

    mutating func removeSeries(_ cell: ResourceCell) {
        values.removeValue(forKey: cell)
    }

    mutating func truncateSeries(_ cell: ResourceCell, keeping kept: Int) {
        guard var series = values[cell] else { return }
        for ordinal in series.keys where ordinal >= kept {
            series.removeValue(forKey: ordinal)
        }
        values[cell] = series
    }

    mutating func setValue(_ value: ObservedResourceValue, for cell: ResourceCell, at ordinal: Int) {
        values[cell, default: [:]][ordinal] = value
    }

    mutating func setValueEverywhere(_ value: ObservedResourceValue, for cell: ResourceCell) {
        guard let series = values[cell] else { return }
        var replaced: [Int: ObservedResourceValue] = [:]
        for ordinal in series.keys { replaced[ordinal] = value }
        values[cell] = replaced
    }

    mutating func makeUnreadable(_ cell: ResourceCell, at ordinal: Int) {
        unreadable.insert(ResourceCellPosition(cell: cell, ordinal: ordinal))
    }

    mutating func makeNotMeasurable(_ cell: ResourceCell) {
        notMeasurable.insert(cell)
    }

    mutating func setTarget(_ target: ExecutionTarget, for cell: ResourceCell) {
        targets[cell] = target
    }

    mutating func setEnvironment(_ environment: ExecutionEnvironment, for cell: ResourceCell) {
        environments[cell] = environment
    }

    mutating func setEnvironmentEverywhere(_ environment: ExecutionEnvironment) {
        defaultEnvironment = environment
        environments.removeAll()
    }

    mutating func setConfiguration(
        _ configuration: CandidateDeviceConfiguration,
        for cell: ResourceCell
    ) {
        configurations[cell] = configuration
    }

    mutating func setVersionTuple(_ tuple: ValidationVersionTuple, for cell: ResourceCell) {
        versionTuples[cell] = tuple
    }

    // MARK: Reading

    func sample(
        for cell: ResourceCell,
        at index: ResourceSampleIndex
    ) throws(ResourceSampleFault) -> ResourceSample {
        if isUnavailable { throw ResourceSampleFault.storeUnavailable }
        if notMeasurable.contains(cell) {
            throw ResourceSampleFault.metricNotMeasurableInEnvironment
        }
        if unreadable.contains(ResourceCellPosition(cell: cell, ordinal: index.ordinal)) {
            throw ResourceSampleFault.sampleUnreadable
        }
        guard let value = values[cell]?[index.ordinal] else {
            throw ResourceSampleFault.sampleAbsent
        }
        return ResourceSample(
            cell: cell,
            index: index,
            value: value,
            target: targets[cell] ?? defaultTarget,
            environment: environments[cell] ?? defaultEnvironment,
            configuration: configurations[cell] ?? defaultConfiguration,
            versionTuple: versionTuples[cell] ?? defaultVersionTuple
        )
    }
}
