import DefAIkeDomain
import Foundation

@testable import DefAIkeReleaseValidation

// Synthetic samples for the parity runners, and a bounded in-memory observation reader.
//
// Every value here is deliberately synthetic. None of these is an approved fixture, an
// approved reference output, an approved tolerance, an approved agreement ratio, an approved
// candidate configuration, or a real physical-device result. The tests build a structurally
// complete run and then change one thing at a time.
//
// Two things are worth being explicit about, because a reader could mistake either for a
// claim this suite is not making.
//
// **A sample observation that says `.physicalIPhone` is a claim, not evidence.**
// `ParityObservation` takes its environment as a parameter because the real caller is a
// device harness that knows where it ran. A test can therefore exercise the comparison
// arithmetic on a host. What a test cannot do is make a *gate* pass: `gateResult(for:)`
// consults `ObservedParityEnvironment.current`, which is compiled from the platform and has
// no parameter. So every gate in this suite fails, deliberately, and
// ``ParityPhysicalDeviceGateTests`` asserts exactly that.
//
// **The observed values are derived from the approved expectations.** The default store hands
// back what the catalogue declares, so an agreeing run really agrees rather than being
// stubbed to. The mutators below change one observation at a time.

extension Sample {

    // MARK: Plan

    /// Every comparison metric a complete parity run requires.
    ///
    /// All eight, including rank agreement and screenshot geometry, which no fixture
    /// expectation declares a value for but Requirements 13.7 and 13.9 require anyway.
    static let allParityComparisons: Set<ComparisonMetric> = Set(ComparisonMetric.allCases)

    /// A plan declaring an approved comparison for all eight metrics.
    static func parityPlan(
        comparisons: Set<ComparisonMetric>? = nil,
        rawLogitTolerance: NumericTolerance? = nil,
        rankTolerance: NumericTolerance? = nil,
        agreement: [ComparisonMetric: UnitInterval] = [:],
        fixtureSuite: String = "suite.fixtures",
        hardware overrideHardware: DeviceHardwareID? = nil
    ) throws -> DeviceValidationPlan {
        let metrics = (comparisons ?? allParityComparisons).sorted { $0.rawValue < $1.rawValue }
        let device = overrideHardware ?? hardware()
        return try DeviceValidationPlan(
            id: artifact("plan.device-validation"),
            schemaVersion: .v1,
            candidateConfigurations: [try candidateConfiguration(hardware: device)],
            fixtureSuite: artifact(fixtureSuite),
            modelBundle: bundle(),
            capabilityManifest: artifact("manifest.capability"),
            comparisons: try metrics.map { metric in
                try ComparisonSpecification(
                    metric: metric,
                    reference: evidence("evidence.reference.\(metric.rawValue)"),
                    tolerance: metric.isCategorical
                        ? nil
                        : try parityTolerance(
                            for: metric,
                            rawLogit: rawLogitTolerance,
                            rank: rankTolerance
                        ),
                    requiredAgreement: metric.isCategorical
                        ? (agreement[metric] ?? ratio(1))
                        : nil
                )
            },
            measurements: try parityMeasurements(hardware: device),
            missingResultRule: .treatAsFailure,
            approval: approval()
        )
    }

    static func parityTolerance(
        for metric: ComparisonMetric,
        rawLogit: NumericTolerance?,
        rank: NumericTolerance?
    ) throws -> NumericTolerance {
        switch metric {
        case .rawLogit:
            return try rawLogit
                ?? NumericTolerance(kind: .absolute, value: nonNegativeDecimal(1))
        case .rankAgreement:
            return try rank ?? NumericTolerance(kind: .absolute, value: nonNegativeDecimal(0))
        default:
            return try NumericTolerance(kind: .absolute, value: nonNegativeDecimal(1))
        }
    }

    static func candidateConfiguration(
        hardware device: DeviceHardwareID? = nil,
        appBuild build: AppBuildID? = nil
    ) throws -> CandidateDeviceConfiguration {
        try CandidateDeviceConfiguration(
            deviceModel: text("Sample iPhone"),
            hardwareIdentifier: device ?? hardware(),
            osVersion: .iOS17,
            appBuild: build ?? appBuild(),
            isAppleNeuralEngineCapable: true
        )
    }

    static func parityMeasurements(
        hardware device: DeviceHardwareID
    ) throws -> [ResourceMeasurementSpecification] {
        try ExecutionTarget.allCases.flatMap { target in
            try ResourceMetric.requiredMetrics(for: target)
                .sorted { $0.rawValue < $1.rawValue }
                .map { metric in
                    try ResourceMeasurementSpecification(
                        metric: metric,
                        target: target,
                        hardwareIdentifier: device,
                        osVersion: .iOS17,
                        appBuild: appBuild(),
                        workload: evidence("evidence.workload"),
                        warmth: .cold,
                        branchExecution: .serial,
                        startingThermalState: .nominal,
                        startingPowerCondition: .batteryUnplugged,
                        sampleCount: count(),
                        summaryStatistic: .median,
                        passLimit: limit(for: metric)
                    )
                }
        }
    }

    // MARK: Version tuple

    static func parityVersionTuple(
        provenanceEnabled: Bool = false,
        fixtureSuite: String = "suite.fixtures",
        validationPlan: String = "plan.device-validation",
        modelBundle overrideBundle: ModelBundleID? = nil,
        capabilityManifest: String = "manifest.capability",
        appBuild overrideBuild: AppBuildID? = nil
    ) throws -> ValidationVersionTuple {
        let capabilities: Set<CapabilityID> = provenanceEnabled
            ? [.pixelAnalysis, .contentCredentialValidation]
            : [.pixelAnalysis]
        return try ValidationVersionTuple(
            appBuild: overrideBuild ?? appBuild(),
            modelBundle: overrideBundle ?? bundle(),
            fixtureSuite: artifact(fixtureSuite),
            validationPlan: artifact(validationPlan),
            capabilityManifest: artifact(capabilityManifest),
            capabilities: capabilities,
            capabilityImplementationVersions: capabilities
                .sorted { $0.rawValue < $1.rawValue }
                .map { CapabilityImplementationEntry(capability: $0, version: version()) }
        )
    }

    // MARK: Catalogue with distinct approved logits

    /// Model-parity fixtures whose approved raw logits are all different.
    ///
    /// The default samples give every model-parity fixture the same approved logit, which
    /// makes every ordering pair a tie and rank agreement trivially satisfied. Distinct
    /// values are needed to observe a discordant pair at all.
    ///
    /// The values are `index - 48` in halves, so they straddle zero and no two agree. Nothing
    /// approved anywhere resembles them.
    static func distinctLogitParityFixtures(
        count fixtureCount: Int = ModelParityFixtureInventory.requiredReferenceCount
    ) throws -> [FixtureRecord] {
        try (0..<fixtureCount).map { index in
            let name = String(format: "%03d", index)
            return try fixtureRecord(
                family: .modelParity,
                identifier: "fixture.parity.\(name)",
                assetPath: "fixtures/parity/\(name).png",
                expectations: [
                    .rawLogit(
                        value: (Double(index) - 48) / 2,
                        tolerance: nonNegativeDecimal(1)
                    ),
                    .pixelLabel(.noStrongSignalDetected),
                ]
            )
        }
    }

    /// A complete catalogue whose model-parity family carries distinct approved logits.
    static func distinctLogitCatalog(
        provenanceApplicable: Bool = false
    ) throws -> FixtureCatalog {
        var fixtures = try distinctLogitParityFixtures()
        fixtures += try nonParityFamilyFixtures()
        if provenanceApplicable {
            fixtures += try provenanceFixtures()
        }
        let suite = try suite(provenanceApplicable: provenanceApplicable, fixtures: fixtures)
        return try FixtureCatalog(
            suite: suite,
            parityInventory: parityInventory(matching: suite.fixtures),
            fusionCoverage: .notApplicable(decision: approval(identifier: "approval.no-fusion"))
        )
    }

    // MARK: Binding

    static func parityBinding(
        provenanceApplicable: Bool = false,
        plan overridePlan: DeviceValidationPlan? = nil,
        catalog overrideCatalog: FixtureCatalog? = nil,
        configuration overrideConfiguration: CandidateDeviceConfiguration? = nil,
        versionTuple overrideTuple: ValidationVersionTuple? = nil
    ) throws -> ParityRunBinding {
        try ParityRunBinding(
            plan: overridePlan ?? parityPlan(),
            catalog: overrideCatalog ?? catalog(provenanceApplicable: provenanceApplicable),
            configuration: overrideConfiguration ?? candidateConfiguration(),
            versionTuple: overrideTuple
                ?? parityVersionTuple(provenanceEnabled: provenanceApplicable)
        )
    }
}

// MARK: - Read-only in-memory observation reader

/// A bounded in-memory ``ParityObservationReading`` for parity-runner tests.
///
/// Read-only, like the seam it implements. The mutators change what the store *already holds*
/// so a test can stage a missing, mismatched, or non-qualifying observation; the runner under
/// test never reaches them.
///
/// An empty store is the honest default state of this repository: nothing has been observed on
/// a physical iPhone, so every cell is missing. That is why ``empty`` is a named value rather
/// than something a test has to build.
struct FakeParityObservationStore: ParityObservationReading {
    var values: [ParityCell: ObservedParityValue] = [:]
    var environments: [ParityCell: ExecutionEnvironment] = [:]
    var configurations: [ParityCell: CandidateDeviceConfiguration] = [:]
    var versionTuples: [ParityCell: ValidationVersionTuple] = [:]
    var unreadableCells: Set<ParityCell> = []
    var isUnavailable = false

    /// The default environment, configuration, and tuple every observation claims.
    var defaultEnvironment: ExecutionEnvironment = .physicalIPhone
    var defaultConfiguration: CandidateDeviceConfiguration
    var defaultVersionTuple: ValidationVersionTuple

    /// A store holding nothing at all.
    static func empty(for binding: ParityRunBinding) -> FakeParityObservationStore {
        FakeParityObservationStore(
            defaultConfiguration: binding.configuration,
            defaultVersionTuple: binding.versionTuple
        )
    }

    /// A store whose observation for every readable cell is the approved expected value.
    ///
    /// Cells the seam is never asked for — rank agreement and screenshot geometry — are
    /// deliberately absent: the runner derives the first and refuses the second, so a store
    /// that held them would be describing a call that never happens.
    static func agreeing(with binding: ParityRunBinding) -> FakeParityObservationStore {
        var store = empty(for: binding)
        for cell in binding.requiredCells {
            guard let value = approvedValue(for: cell, in: binding) else { continue }
            store.values[cell] = value
        }
        return store
    }

    /// The approved expected value for one cell, in observed form.
    static func approvedValue(
        for cell: ParityCell,
        in binding: ParityRunBinding
    ) -> ObservedParityValue? {
        guard let fixtureID = cell.subject.fixture,
            let fixture = binding.catalog.suite.fixtures.first(where: { $0.id == fixtureID }),
            case let .expectationKind(kind) = cell.comparison.approvedExpectationSource,
            let expectation = fixture.expectations.first(where: { $0.kind == kind })
        else {
            return nil
        }
        switch expectation {
        case let .preprocessingOutputDigest(digest): return .preprocessingOutputDigest(digest)
        case let .retainedBytesDigest(digest): return .retainedBytesDigest(digest)
        case let .pixelLabel(label): return .pixelLabel(label)
        case let .bytePreservationStatus(status): return .bytePreservationStatus(status)
        case let .provenanceState(state): return .provenanceState(state)
        case let .rawLogit(value, _): return .rawLogit(value)
        case .analysisError: return nil
        }
    }

    // MARK: Staging

    mutating func remove(_ cell: ParityCell) {
        values.removeValue(forKey: cell)
    }

    mutating func set(_ value: ObservedParityValue, for cell: ParityCell) {
        values[cell] = value
    }

    mutating func setEnvironment(_ environment: ExecutionEnvironment, for cell: ParityCell) {
        environments[cell] = environment
    }

    mutating func setEnvironmentEverywhere(_ environment: ExecutionEnvironment) {
        defaultEnvironment = environment
    }

    mutating func setConfiguration(
        _ configuration: CandidateDeviceConfiguration,
        for cell: ParityCell
    ) {
        configurations[cell] = configuration
    }

    mutating func setVersionTuple(_ tuple: ValidationVersionTuple, for cell: ParityCell) {
        versionTuples[cell] = tuple
    }

    mutating func makeUnreadable(_ cell: ParityCell) {
        unreadableCells.insert(cell)
    }

    // MARK: Reading

    func observation(
        for cell: ParityCell
    ) throws(ParityObservationFault) -> ParityObservation {
        if isUnavailable { throw ParityObservationFault.storeUnavailable }
        if unreadableCells.contains(cell) { throw ParityObservationFault.observationUnreadable }
        guard let value = values[cell] else {
            throw ParityObservationFault.observationAbsent
        }
        return ParityObservation(
            cell: cell,
            value: value,
            environment: environments[cell] ?? defaultEnvironment,
            configuration: configurations[cell] ?? defaultConfiguration,
            versionTuple: versionTuples[cell] ?? defaultVersionTuple
        )
    }
}
