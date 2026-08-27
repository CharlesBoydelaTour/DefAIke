import DefAIkeDomain
import CryptoKit
import Foundation

@testable import DefAIkeReleaseValidation

// Synthetic fixture-catalog samples and a read-only in-memory asset store.
//
// Every value here is deliberately synthetic. None of these is an approved fixture, an
// approved expected result, an approved tolerance, or an approved provenance or fusion
// decision: the tests build a structurally complete catalog and then mutate one field
// at a time to check that the catalog refuses the mutation.
//
// Asset bytes are derived from the asset path, so a fixture's declared digest is the
// real SHA-256 of the bytes the store will hand back. That keeps the verifier tests
// honest: a passing digest comparison is an actual hash agreement, not a stubbed one.

enum Sample {
    // MARK: Identifiers and scalars

    static func artifact(_ value: String) -> ArtifactID {
        ArtifactID(value)!
    }

    static func fixture(_ value: String) -> FixtureID {
        FixtureID(value)!
    }

    static func path(_ value: String) -> CanonicalRelativePath {
        CanonicalRelativePath(value)!
    }

    static func copyKey(_ value: String) -> ApprovedCopyKey {
        ApprovedCopyKey(value)!
    }

    static func approver() -> ApproverID {
        ApproverID("role.release-owner")!
    }

    static func hardware() -> DeviceHardwareID {
        DeviceHardwareID("iPhone17.1")!
    }

    static func appBuild() -> AppBuildID {
        AppBuildID("build.sample")!
    }

    static func bundle() -> ModelBundleID {
        ModelBundleID("bundle.sample")!
    }

    static func version(_ value: String = "1.0.0") -> SchemaSemanticVersion {
        try! SchemaSemanticVersion(validating: value)
    }

    static func text(_ value: String) -> ArtifactText {
        try! ArtifactText(validating: value)
    }

    static func count(_ value: Int = 5) -> PositiveCount {
        try! PositiveCount(validating: value)
    }

    static func byteCount(_ value: UInt64) -> PositiveByteCount {
        try! PositiveByteCount(validating: value)
    }

    static func positiveDecimal(_ value: Decimal = 100) -> PositiveDecimal {
        try! PositiveDecimal(validating: value)
    }

    static func nonNegativeDecimal(_ value: Decimal = 0) -> NonNegativeDecimal {
        try! NonNegativeDecimal(validating: value)
    }

    static func ratio(_ value: Decimal) -> UnitInterval {
        try! UnitInterval(validating: value)
    }

    /// A distinct synthetic digest, for cases that need a value that is not the digest
    /// of any asset.
    static func digest(_ index: Int) -> DefAIkeDomain.SHA256Digest {
        DefAIkeDomain.SHA256Digest(hexadecimal: String(format: "%064x", index))!
    }

    static func evidence(_ identifier: String) -> EvidenceSource {
        EvidenceSource(
            artifact: artifact(identifier),
            version: version(),
            contentDigest: digest(0xE1)
        )
    }

    static func approval(
        _ decision: ApprovalDecision = .approved,
        identifier: String = "approval.sample"
    ) -> ApprovalRecord {
        ApprovalRecord(
            source: evidence(identifier),
            decision: decision,
            approver: approver(),
            decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    static func notApplicable(_ decision: ApprovalDecision = .approved) -> GateApplicability {
        .notApplicable(decision: approval(decision))
    }

    // MARK: Asset bytes

    /// Deterministic synthetic bytes for one asset path.
    ///
    /// Derived from the path so that two fixtures never share bytes and so the store
    /// and the catalog agree without either recording an index.
    static func assetBytes(forPath path: String) -> [UInt8] {
        Array("defaike.fixture.asset:\(path)\n".utf8)
    }

    /// Real SHA-256 over `bytes`.
    static func digest(of bytes: [UInt8]) -> DefAIkeDomain.SHA256Digest {
        DefAIkeDomain.SHA256Digest(bytes: Array(CryptoKit.SHA256.hash(data: Data(bytes))))!
    }

    // MARK: Expected results

    /// Expected results covering exactly the kinds a family is compared on.
    static func expectations(
        for family: FixtureFamily,
        pixel: PixelLabelKey = .noStrongSignalDetected,
        provenance: ProvenanceStateKey = .absent,
        declaresPixelLane: Bool = false
    ) -> [FixtureExpectation] {
        switch family {
        case .modelParity:
            return [.rawLogit(value: 1.5, tolerance: nonNegativeDecimal()), .pixelLabel(pixel)]
        case .orientation, .colorSpace, .alpha, .aspectRatio, .jpegContainer, .pngContainer,
             .heifContainer:
            return [.preprocessingOutputDigest(digest(0x2001))]
        case .physicalScreenshot:
            return [
                .preprocessingOutputDigest(digest(0x2002)),
                .rawLogit(value: -0.75, tolerance: nonNegativeDecimal()),
            ]
        case .malformedInput:
            return [.analysisError(.decodingError)]
        case .photosPickerRoute, .shareExtensionRoute:
            return [
                .retainedBytesDigest(digest(0x2003)),
                .bytePreservationStatus(.originalBytes),
            ]
        case .provenanceValidSigned, .provenanceTampered, .provenanceInvalid, .provenanceAbsent,
             .provenanceUnsupported, .provenanceIndeterminate:
            return declaresPixelLane
                ? [.provenanceState(provenance), .pixelLabel(pixel)]
                : [.provenanceState(provenance)]
        }
    }

    // MARK: Fixtures

    static func fixtureRecord(
        family: FixtureFamily,
        identifier: String,
        assetPath: String,
        expectations: [FixtureExpectation]? = nil,
        contentDigest: DefAIkeDomain.SHA256Digest? = nil
    ) throws -> FixtureRecord {
        let bytes = assetBytes(forPath: assetPath)
        return try FixtureRecord(
            id: fixture(identifier),
            family: family,
            assetPath: path(assetPath),
            contentDigest: contentDigest ?? digest(of: bytes),
            byteCount: byteCount(UInt64(bytes.count)),
            source: evidence("evidence.fixture"),
            expectations: expectations ?? self.expectations(for: family)
        )
    }

    /// Synthetic stand-ins for the existing model-parity fixture references.
    static func parityFixtures(
        count: Int = ModelParityFixtureInventory.requiredReferenceCount
    ) throws -> [FixtureRecord] {
        try (0..<count).map { index in
            let name = String(format: "%03d", index)
            return try fixtureRecord(
                family: .modelParity,
                identifier: "fixture.parity.\(name)",
                assetPath: "fixtures/parity/\(name).png"
            )
        }
    }

    /// One fixture for every unconditional family other than model parity.
    static func nonParityFamilyFixtures(
        excluding excluded: Set<FixtureFamily> = []
    ) throws -> [FixtureRecord] {
        let families = FixtureFamily.unconditionalFamilies
            .subtracting([.modelParity])
            .subtracting(excluded)
            .sorted { $0.rawValue < $1.rawValue }
        return try families.map { family in
            try fixtureRecord(
                family: family,
                identifier: "fixture.\(family.rawValue)",
                assetPath: "fixtures/\(family.rawValue).bin"
            )
        }
    }

    /// The family that demonstrates one provenance state in these samples.
    ///
    /// `invalid` has two demonstrating families; the samples use the invalid family for
    /// fusion coverage and keep a separate tampered fixture so all six families are
    /// populated.
    static func provenanceFamily(for state: ProvenanceStateKey) -> FixtureFamily {
        switch state {
        case .validated: .provenanceValidSigned
        case .invalid: .provenanceInvalid
        case .absent: .provenanceAbsent
        case .unsupported: .provenanceUnsupported
        case .indeterminate: .provenanceIndeterminate
        }
    }

    static func fusionFixtureIdentifier(for combination: FusionLaneCombination) -> String {
        "fixture.fusion.\(combination.pixel.rawValue).\(combination.provenance.rawValue)"
    }

    /// The tampered fixture identifier, which no fusion combination names.
    static let tamperedFixtureIdentifier = "fixture.provenance-tampered"

    /// One fixture per lane combination plus one tampered fixture.
    static func provenanceFixtures(
        excluding excluded: Set<FixtureFamily> = []
    ) throws -> [FixtureRecord] {
        var records: [FixtureRecord] = []
        for combination in FusionLaneCombination.allCombinations {
            let family = provenanceFamily(for: combination.provenance)
            guard !excluded.contains(family) else { continue }
            let identifier = fusionFixtureIdentifier(for: combination)
            records.append(
                try fixtureRecord(
                    family: family,
                    identifier: identifier,
                    assetPath: "fixtures/provenance/\(identifier).jpg",
                    expectations: expectations(
                        for: family,
                        pixel: combination.pixel,
                        provenance: combination.provenance,
                        declaresPixelLane: true
                    )
                )
            )
        }
        if !excluded.contains(.provenanceTampered) {
            records.append(
                try fixtureRecord(
                    family: .provenanceTampered,
                    identifier: tamperedFixtureIdentifier,
                    assetPath: "fixtures/provenance/tampered.jpg",
                    expectations: expectations(for: .provenanceTampered, provenance: .invalid)
                )
            )
        }
        return records
    }

    /// Every fixture a complete suite carries.
    static func completeFixtures(
        provenanceApplicable: Bool = false,
        excluding excluded: Set<FixtureFamily> = []
    ) throws -> [FixtureRecord] {
        var records = try parityFixtures()
        records += try nonParityFamilyFixtures(excluding: excluded)
        if provenanceApplicable {
            records += try provenanceFixtures(excluding: excluded)
        }
        return records
    }

    // MARK: Suite, inventory, coverage, catalog

    static func suite(
        provenanceApplicable: Bool = false,
        identifier: String = "suite.fixtures",
        fixtures: [FixtureRecord]? = nil
    ) throws -> ReleaseFixtureSuite {
        try ReleaseFixtureSuite(
            id: artifact(identifier),
            schemaVersion: .v1,
            provenanceApplicability: provenanceApplicable ? .applicable : notApplicable(),
            fixtures: try fixtures ?? completeFixtures(provenanceApplicable: provenanceApplicable)
        )
    }

    static func parityInventory(
        matching fixtures: [FixtureRecord],
        references: [ModelParityReference]? = nil,
        approval decision: ApprovalDecision = .approved
    ) throws -> ModelParityFixtureInventory {
        let derived = fixtures
            .filter { $0.family == .modelParity }
            .map { ModelParityReference(fixture: $0.id, contentDigest: $0.contentDigest) }
        return try ModelParityFixtureInventory(
            id: artifact("inventory.model-parity"),
            schemaVersion: .v1,
            source: evidence("evidence.coreml-parity"),
            references: references ?? derived,
            approval: approval(decision, identifier: "approval.parity-inventory")
        )
    }

    static func fusionExpectations(
        combinations: [FusionLaneCombination] = FusionLaneCombination.allCombinations
    ) -> [FusionFixtureExpectation] {
        combinations.map { combination in
            FusionFixtureExpectation(
                combination: combination,
                fixture: fixture(fusionFixtureIdentifier(for: combination)),
                expectedDisposition: combination.provenance == .absent
                    ? .omit
                    : .show(copyKey("copy.fusion.\(combination.pixel.rawValue)")),
                source: evidence("evidence.fusion-fixtures")
            )
        }
    }

    static func fusionCoverage(
        expectations: [FusionFixtureExpectation]? = nil,
        approval decision: ApprovalDecision = .approved
    ) throws -> FusionFixtureCoverage {
        try FusionFixtureCoverage(
            id: artifact("coverage.fusion-fixtures"),
            schemaVersion: .v1,
            fusionRule: artifact("rule.fusion"),
            expectations: expectations ?? fusionExpectations(),
            approval: approval(decision, identifier: "approval.fusion-coverage")
        )
    }

    static func catalog(
        provenanceApplicable: Bool = false,
        withFusionCoverage: Bool = false
    ) throws -> FixtureCatalog {
        let suite = try suite(provenanceApplicable: provenanceApplicable)
        return try FixtureCatalog(
            suite: suite,
            parityInventory: parityInventory(matching: suite.fixtures),
            fusionCoverage: withFusionCoverage
                ? .bound(try fusionCoverage())
                : .notApplicable(decision: approval(identifier: "approval.no-fusion"))
        )
    }

    // MARK: Device Validation Plan

    /// Comparison metrics the complete sample catalog expects values for.
    static let expectedComparisons: Set<ComparisonMetric> = [
        .categoricalOutcome,
        .rawLogit,
        .preprocessingOutput,
        .retainedBytes,
        .bytePreservationStatus,
        .provenanceState,
    ]

    static func comparison(_ metric: ComparisonMetric) throws -> ComparisonSpecification {
        try ComparisonSpecification(
            metric: metric,
            reference: evidence("evidence.reference.\(metric.rawValue)"),
            tolerance: metric.isCategorical
                ? nil
                : try NumericTolerance(kind: .absolute, value: nonNegativeDecimal(1)),
            requiredAgreement: metric.isCategorical ? ratio(1) : nil
        )
    }

    static func measurements() throws -> [ResourceMeasurementSpecification] {
        try ExecutionTarget.allCases.flatMap { target in
            try ResourceMetric.requiredMetrics(for: target)
                .sorted { $0.rawValue < $1.rawValue }
                .map { metric in
                    try ResourceMeasurementSpecification(
                        metric: metric,
                        target: target,
                        hardwareIdentifier: hardware(),
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

    static func limit(for metric: ResourceMetric) -> ValidatedLimit {
        metric.isCategorical
            ? .thermal(maximumState: .fair)
            : .numeric(value: positiveDecimal(), unit: unit(for: metric))
    }

    static func unit(for metric: ResourceMetric) -> ResourceLimitUnit {
        switch metric {
        case .decodedPixelCount: .pixels
        case .peakResidentMemory, .temporaryStorage, .encodedInputSize: .bytes
        case .coldModelLoadTime, .warmAnalysisLatency, .handoffLatency: .milliseconds
        case .energyImpact: .milliwattHours
        case .thermalState: .milliseconds
        }
    }

    static func plan(
        fixtureSuite: String = "suite.fixtures",
        comparisons: Set<ComparisonMetric>? = nil
    ) throws -> DeviceValidationPlan {
        let metrics = (comparisons ?? expectedComparisons).sorted { $0.rawValue < $1.rawValue }
        return try DeviceValidationPlan(
            id: artifact("plan.device-validation"),
            schemaVersion: .v1,
            candidateConfigurations: [
                try CandidateDeviceConfiguration(
                    deviceModel: text("Sample iPhone"),
                    hardwareIdentifier: hardware(),
                    osVersion: .iOS17,
                    appBuild: appBuild(),
                    isAppleNeuralEngineCapable: true
                )
            ],
            fixtureSuite: artifact(fixtureSuite),
            modelBundle: bundle(),
            capabilityManifest: artifact("manifest.capability"),
            comparisons: try metrics.map { try comparison($0) },
            measurements: try measurements(),
            missingResultRule: .treatAsFailure,
            approval: approval()
        )
    }
}

// MARK: - Read-only in-memory asset store

/// A bounded in-memory ``FixtureAssetReading`` for verifier tests.
///
/// Read-only, like the seam it implements: the mutators below change what the store
/// *already holds* so a test can stage a missing, mutated, or unreadable asset. The
/// verifier under test never reaches them.
struct FakeFixtureAssetStore: FixtureAssetReading {
    struct Asset {
        /// What enumeration reports. Held separately from `bytes` so a test can stage a
        /// store whose enumerated size understates the real content.
        var kind: FixtureAssetKind
        var bytes: [UInt8]
        var isReadable: Bool
    }

    var assets: [String: Asset] = [:]
    var isUnavailable = false

    /// A store holding exactly the bytes every catalogued fixture declares.
    static func complete(for suite: ReleaseFixtureSuite) -> FakeFixtureAssetStore {
        var store = FakeFixtureAssetStore()
        for fixture in suite.fixtures {
            let bytes = Sample.assetBytes(forPath: fixture.assetPath.rawValue)
            store.assets[fixture.assetPath.rawValue] = Asset(
                kind: .file(byteCount: UInt64(bytes.count)),
                bytes: bytes,
                isReadable: true
            )
        }
        return store
    }

    mutating func removeAsset(at path: CanonicalRelativePath) {
        assets.removeValue(forKey: path.rawValue)
    }

    /// Replaces the bytes and the enumerated size together, as a real edit would.
    mutating func replaceBytes(at path: CanonicalRelativePath, with bytes: [UInt8]) {
        assets[path.rawValue] = Asset(
            kind: .file(byteCount: UInt64(bytes.count)),
            bytes: bytes,
            isReadable: true
        )
    }

    /// Replaces the bytes while leaving the enumerated size unchanged.
    mutating func replaceBytesKeepingEnumeratedSize(
        at path: CanonicalRelativePath,
        with bytes: [UInt8]
    ) {
        guard let existing = assets[path.rawValue] else { return }
        assets[path.rawValue] = Asset(
            kind: existing.kind,
            bytes: bytes,
            isReadable: existing.isReadable
        )
    }

    mutating func setKind(_ kind: FixtureAssetKind, at path: CanonicalRelativePath) {
        guard let existing = assets[path.rawValue] else { return }
        assets[path.rawValue] = Asset(
            kind: kind,
            bytes: existing.bytes,
            isReadable: existing.isReadable
        )
    }

    mutating func makeUnreadable(at path: CanonicalRelativePath) {
        guard let existing = assets[path.rawValue] else { return }
        assets[path.rawValue] = Asset(
            kind: existing.kind,
            bytes: existing.bytes,
            isReadable: false
        )
    }

    func kind(
        at path: CanonicalRelativePath,
        in suite: ArtifactID
    ) throws(FixtureAssetFault) -> FixtureAssetKind {
        if isUnavailable { throw FixtureAssetFault.storeUnavailable }
        guard let asset = assets[path.rawValue] else { throw FixtureAssetFault.assetMissing }
        return asset.kind
    }

    func readAsset(
        at path: CanonicalRelativePath,
        in suite: ArtifactID,
        chunkByteCount: Int,
        into sink: (ArraySlice<UInt8>) -> FixtureAssetReadDisposition
    ) throws(FixtureAssetFault) -> Void {
        if isUnavailable { throw FixtureAssetFault.storeUnavailable }
        guard let asset = assets[path.rawValue] else { throw FixtureAssetFault.assetMissing }
        guard asset.isReadable else { throw FixtureAssetFault.assetUnreadable }
        var index = asset.bytes.startIndex
        while index < asset.bytes.endIndex {
            let end = min(index + chunkByteCount, asset.bytes.endIndex)
            if sink(asset.bytes[index..<end]) == .stop { return }
            index = end
        }
    }
}
