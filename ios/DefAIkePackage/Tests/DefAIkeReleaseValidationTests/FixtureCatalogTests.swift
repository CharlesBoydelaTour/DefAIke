import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// Fixture-catalog schema tests.
//
// Each test builds a structurally complete catalog and removes or mutates exactly one
// thing: a parity reference, a family, an expected result, a fusion combination, or a
// cross-artifact reference. The catalog has to refuse every one of them, because the
// alternative to refusing is running a release gate against fixtures whose expected
// results were never approved.

@Suite("Immutable fixture catalog")
struct FixtureCatalogTests {
    // MARK: Complete catalogs

    @Test("A complete pixel-only catalog validates")
    func completePixelOnlyCatalog() throws {
        let catalog = try Sample.catalog()

        #expect(catalog.suite.hasCompleteModelParityCoverage)
        #expect(catalog.suite.missingFamilies.isEmpty)
        #expect(catalog.parityInventory.references.count == 96)
        #expect(!catalog.hasFusionCoverage)
        #expect(catalog.suite.fixtures(in: .provenanceValidSigned).isEmpty)
    }

    @Test("A complete provenance catalog with fusion coverage validates")
    func completeProvenanceCatalog() throws {
        let catalog = try Sample.catalog(provenanceApplicable: true, withFusionCoverage: true)

        #expect(catalog.suite.missingFamilies.isEmpty)
        #expect(catalog.hasFusionCoverage)
        for family in FixtureFamily.provenanceFamilies {
            #expect(!catalog.suite.fixtures(in: family).isEmpty)
        }
        let coverage = try #require(catalog.fusionCoverage.boundReference)
        #expect(coverage.expectations.count == FusionLaneCombination.requiredCombinationCount)

        // Lookup is total over the 3 x 5 key space by construction.
        for combination in FusionLaneCombination.allCombinations {
            let expectation = coverage.expectation(for: combination)
            #expect(expectation.combination == combination)
            let named = try #require(
                catalog.suite.fixtures.first { $0.id == expectation.fixture }
            )
            #expect(named.family.isProvenanceConditional)
        }
    }

    // MARK: Model-parity reference inventory

    @Test("The parity inventory holds exactly the existing reference count")
    func parityInventoryCountIsFixed() throws {
        let fixtures = try Sample.parityFixtures(count: 95)
        #expect(
            throws: FixtureCatalogError.parityReferenceCountMismatch(expected: 96, found: 95)
        ) {
            try Sample.parityInventory(matching: fixtures)
        }
        #expect(ModelParityFixtureInventory.requiredReferenceCount == 96)
    }

    @Test("An unapproved parity inventory is refused")
    func parityInventoryNeedsApproval() throws {
        let fixtures = try Sample.parityFixtures()
        #expect(
            throws: FixtureCatalogError.parityInventoryNotApproved(
                Sample.artifact("inventory.model-parity")
            )
        ) {
            try Sample.parityInventory(matching: fixtures, approval: .rejected)
        }
    }

    @Test("A duplicated parity reference is refused")
    func duplicateParityReferenceRefused() throws {
        let fixtures = try Sample.parityFixtures()
        var references = fixtures.dropLast().map {
            ModelParityReference(fixture: $0.id, contentDigest: $0.contentDigest)
        }
        references.append(references[0])

        #expect(
            throws: FixtureCatalogError.duplicateParityReference(references[0].fixture)
        ) {
            try Sample.parityInventory(matching: fixtures, references: references)
        }
    }

    @Test("A referenced parity fixture the catalog omits is refused")
    func parityReferenceWithoutFixtureRefused() throws {
        let suite = try Sample.suite()
        let parity = suite.fixtures.filter { $0.family == .modelParity }
        var references = parity.dropLast().map {
            ModelParityReference(fixture: $0.id, contentDigest: $0.contentDigest)
        }
        let absent = Sample.fixture("fixture.parity.absent")
        references.append(ModelParityReference(fixture: absent, contentDigest: Sample.digest(7)))

        #expect(throws: FixtureCatalogError.parityFixtureNotCatalogued([absent])) {
            try FixtureCatalog(
                suite: suite,
                parityInventory: try Sample.parityInventory(
                    matching: suite.fixtures,
                    references: references
                ),
                fusionCoverage: .notApplicable(decision: Sample.approval())
            )
        }
    }

    @Test("A catalogued parity fixture the inventory omits is refused")
    func parityFixtureWithoutReferenceRefused() throws {
        var fixtures = try Sample.parityFixtures(count: 97)
        let unreferenced = fixtures.removeLast()
        let references = fixtures.map {
            ModelParityReference(fixture: $0.id, contentDigest: $0.contentDigest)
        }
        let suite = try Sample.suite(
            fixtures: fixtures + [unreferenced] + (try Sample.nonParityFamilyFixtures())
        )

        #expect(throws: FixtureCatalogError.parityFixtureNotInInventory([unreferenced.id])) {
            try FixtureCatalog(
                suite: suite,
                parityInventory: try Sample.parityInventory(
                    matching: suite.fixtures,
                    references: references
                ),
                fusionCoverage: .notApplicable(decision: Sample.approval())
            )
        }
    }

    @Test("A parity fixture whose digest differs from the inventory is refused")
    func parityDigestMismatchRefused() throws {
        let suite = try Sample.suite()
        let parity = suite.fixtures.filter { $0.family == .modelParity }
        var references = parity.map {
            ModelParityReference(fixture: $0.id, contentDigest: $0.contentDigest)
        }
        references[0] = ModelParityReference(
            fixture: references[0].fixture,
            contentDigest: Sample.digest(0xBAD)
        )

        #expect(throws: FixtureCatalogError.parityDigestMismatch(references[0].fixture)) {
            try FixtureCatalog(
                suite: suite,
                parityInventory: try Sample.parityInventory(
                    matching: suite.fixtures,
                    references: references
                ),
                fusionCoverage: .notApplicable(decision: Sample.approval())
            )
        }
    }

    // MARK: Family completeness

    @Test("A required unconditional family with no fixture is refused")
    func missingUnconditionalFamilyRefused() throws {
        let suite = try Sample.suite(
            fixtures: try Sample.completeFixtures(excluding: [.malformedInput])
        )

        #expect(throws: FixtureCatalogError.requiredFamilyEmpty(.malformedInput)) {
            try FixtureCatalog(
                suite: suite,
                parityInventory: try Sample.parityInventory(matching: suite.fixtures),
                fusionCoverage: .notApplicable(decision: Sample.approval())
            )
        }
    }

    @Test("A provenance family with no fixture is refused once provenance applies")
    func missingProvenanceFamilyRefused() throws {
        let suite = try Sample.suite(
            provenanceApplicable: true,
            fixtures: try Sample.completeFixtures(
                provenanceApplicable: true,
                excluding: [.provenanceTampered]
            )
        )

        #expect(throws: FixtureCatalogError.requiredFamilyEmpty(.provenanceTampered)) {
            try FixtureCatalog(
                suite: suite,
                parityInventory: try Sample.parityInventory(matching: suite.fixtures),
                fusionCoverage: .notApplicable(decision: Sample.approval())
            )
        }
    }

    // MARK: Expected results

    @Test("A fixture missing an expected result its family is compared on is refused")
    func missingExpectationKindRefused() throws {
        var fixtures = try Sample.completeFixtures()
        let incomplete = try Sample.fixtureRecord(
            family: .photosPickerRoute,
            identifier: "fixture.photos-picker-route",
            assetPath: "fixtures/photos-picker-route.bin",
            expectations: [.retainedBytesDigest(Sample.digest(0x2003))]
        )
        fixtures.removeAll { $0.family == .photosPickerRoute }
        fixtures.append(incomplete)
        let suite = try Sample.suite(fixtures: fixtures)

        #expect(
            throws: FixtureCatalogError.expectationKindsMissing(
                fixture: incomplete.id,
                kinds: [.bytePreservationStatus]
            )
        ) {
            try FixtureCatalog(
                suite: suite,
                parityInventory: try Sample.parityInventory(matching: suite.fixtures),
                fusionCoverage: .notApplicable(decision: Sample.approval())
            )
        }
    }

    @Test("A fixture declaring one expected-result kind twice is refused")
    func duplicateExpectationKindRefused() throws {
        var fixtures = try Sample.completeFixtures()
        let original = fixtures[0]
        let ambiguous = try Sample.fixtureRecord(
            family: .modelParity,
            identifier: original.id.rawValue,
            assetPath: original.assetPath.rawValue,
            expectations: [
                .rawLogit(value: 1.5, tolerance: Sample.nonNegativeDecimal()),
                .pixelLabel(.noStrongSignalDetected),
                .pixelLabel(.signalsConsistentWithAIGeneration),
            ]
        )
        fixtures[0] = ambiguous
        let suite = try Sample.suite(fixtures: fixtures)

        #expect(
            throws: FixtureCatalogError.duplicateExpectationKind(
                fixture: ambiguous.id,
                kind: .pixelLabel
            )
        ) {
            try FixtureCatalog(
                suite: suite,
                parityInventory: try Sample.parityInventory(matching: suite.fixtures),
                fusionCoverage: .notApplicable(decision: Sample.approval())
            )
        }
    }

    @Test("Every family states the expected results it is compared on")
    func expectationRulesAreTotal() {
        for family in FixtureFamily.allCases {
            #expect(!family.requiredExpectationKinds.isEmpty)
        }
        #expect(FixtureFamily.modelParity.requiredExpectationKinds == [.rawLogit, .pixelLabel])
        #expect(FixtureFamily.malformedInput.requiredExpectationKinds == [.analysisError])
        for family in FixtureFamily.provenanceFamilies {
            #expect(family.requiredExpectationKinds == [.provenanceState])
        }
    }

    @Test("Expected-result kinds and plan comparisons map one way each")
    func expectationKindMapping() {
        let expectations: [FixtureExpectation] = [
            .pixelLabel(.notEnoughSignal),
            .rawLogit(value: 0, tolerance: Sample.nonNegativeDecimal()),
            .preprocessingOutputDigest(Sample.digest(1)),
            .retainedBytesDigest(Sample.digest(2)),
            .bytePreservationStatus(.unknown),
            .provenanceState(.absent),
            .analysisError(.decodingError),
        ]
        #expect(Set(expectations.map(\.kind)) == Set(FixtureExpectationKind.allCases))

        for expectation in expectations where expectation.kind != .analysisError {
            #expect(expectation.referenceComparison != nil)
        }
        // A malformed-input fixture asserts a terminal error rather than comparing
        // against a reference artifact, so it maps to no plan comparison.
        #expect(FixtureExpectation.analysisError(.decodingError).referenceComparison == nil)
    }

    @Test("Each provenance state names the families that demonstrate it")
    func demonstratingFamiliesPartitionProvenanceFamilies() {
        var covered = Set<FixtureFamily>()
        for state in ProvenanceStateKey.allCases {
            let families = state.demonstratingFamilies
            #expect(!families.isEmpty)
            #expect(families.filter { !$0.isProvenanceConditional }.isEmpty)
            #expect(covered.intersection(families).isEmpty)
            covered.formUnion(families)
        }
        #expect(covered == FixtureFamily.provenanceFamilies)
        #expect(ProvenanceStateKey.invalid.demonstratingFamilies.count == 2)
    }

    // MARK: Fusion coverage

    @Test("Fusion coverage is refused when the provenance lane is unavailable")
    func fusionCoverageNeedsProvenanceLane() throws {
        let suite = try Sample.suite()

        #expect(throws: FixtureCatalogError.fusionCoverageWithoutProvenance) {
            try FixtureCatalog(
                suite: suite,
                parityInventory: try Sample.parityInventory(matching: suite.fixtures),
                fusionCoverage: .bound(try Sample.fusionCoverage())
            )
        }
    }

    @Test("Unapproved fusion coverage is refused")
    func fusionCoverageNeedsApproval() {
        #expect(
            throws: FixtureCatalogError.fusionCoverageNotApproved(
                Sample.artifact("coverage.fusion-fixtures")
            )
        ) {
            try Sample.fusionCoverage(approval: .rejected)
        }
    }

    @Test("Fusion coverage missing any of the 15 combinations is refused")
    func incompleteFusionCoverageRefused() throws {
        let dropped = FusionLaneCombination.allCombinations[0]
        let combinations = FusionLaneCombination.allCombinations.filter { $0 != dropped }

        #expect(
            throws: FixtureCatalogError.fusionCombinationsMissing([dropped.description])
        ) {
            try Sample.fusionCoverage(
                expectations: Sample.fusionExpectations(combinations: combinations)
            )
        }
        #expect(FusionLaneCombination.requiredCombinationCount == 15)
    }

    @Test("A repeated fusion combination or fixture is refused")
    func duplicateFusionEntriesRefused() throws {
        var expectations = Sample.fusionExpectations()
        expectations.append(expectations[0])
        #expect(
            throws: FixtureCatalogError.duplicateFusionCombination(
                expectations[0].combination.description
            )
        ) {
            try Sample.fusionCoverage(expectations: expectations)
        }

        var reused = Sample.fusionExpectations()
        reused[1] = FusionFixtureExpectation(
            combination: reused[1].combination,
            fixture: reused[0].fixture,
            expectedDisposition: reused[1].expectedDisposition,
            source: reused[1].source
        )
        #expect(throws: FixtureCatalogError.duplicateFusionFixture(reused[0].fixture)) {
            try Sample.fusionCoverage(expectations: reused)
        }
    }

    @Test("A fusion combination naming an uncatalogued fixture is refused")
    func fusionFixtureMustBeCatalogued() throws {
        let suite = try Sample.suite(provenanceApplicable: true)
        var expectations = Sample.fusionExpectations()
        let absent = Sample.fixture("fixture.fusion.absent")
        expectations[0] = FusionFixtureExpectation(
            combination: expectations[0].combination,
            fixture: absent,
            expectedDisposition: expectations[0].expectedDisposition,
            source: expectations[0].source
        )

        #expect(throws: FixtureCatalogError.fusionFixtureNotCatalogued(absent)) {
            try FixtureCatalog(
                suite: suite,
                parityInventory: try Sample.parityInventory(matching: suite.fixtures),
                fusionCoverage: .bound(try Sample.fusionCoverage(expectations: expectations))
            )
        }
    }

    @Test("A fusion fixture whose family cannot demonstrate the state is refused")
    func fusionFixtureFamilyMustMatch() throws {
        let suite = try Sample.suite(provenanceApplicable: true)
        var expectations = Sample.fusionExpectations()
        let validated = try #require(
            expectations.firstIndex { $0.combination.provenance == .validated }
        )
        let tampered = Sample.fixture(Sample.tamperedFixtureIdentifier)
        expectations[validated] = FusionFixtureExpectation(
            combination: expectations[validated].combination,
            fixture: tampered,
            expectedDisposition: expectations[validated].expectedDisposition,
            source: expectations[validated].source
        )

        #expect(
            throws: FixtureCatalogError.fusionFixtureFamilyMismatch(
                fixture: tampered,
                family: .provenanceTampered,
                expected: .validated
            )
        ) {
            try FixtureCatalog(
                suite: suite,
                parityInventory: try Sample.parityInventory(matching: suite.fixtures),
                fusionCoverage: .bound(try Sample.fusionCoverage(expectations: expectations))
            )
        }
    }

    @Test("A fusion fixture that does not expect both lane results is refused")
    func fusionFixtureMustExpectBothLanes() throws {
        // A valid-signed fixture that declares only its provenance lane. It satisfies
        // Requirement 6.18 on its own but cannot demonstrate a lane combination.
        let oneLane = try Sample.fixtureRecord(
            family: .provenanceValidSigned,
            identifier: "fixture.provenance-valid-signed.no-pixel-lane",
            assetPath: "fixtures/provenance/valid-signed-no-pixel-lane.jpg",
            expectations: [.provenanceState(.validated)]
        )
        let suite = try Sample.suite(
            provenanceApplicable: true,
            fixtures: try Sample.completeFixtures(provenanceApplicable: true) + [oneLane]
        )
        var expectations = Sample.fusionExpectations()
        let validated = try #require(
            expectations.firstIndex { $0.combination.provenance == .validated }
        )
        let combination = expectations[validated].combination
        expectations[validated] = FusionFixtureExpectation(
            combination: combination,
            fixture: oneLane.id,
            expectedDisposition: expectations[validated].expectedDisposition,
            source: expectations[validated].source
        )

        #expect(
            throws: FixtureCatalogError.fusionFixtureExpectationMismatch(
                fixture: oneLane.id,
                combination: combination.description
            )
        ) {
            try FixtureCatalog(
                suite: suite,
                parityInventory: try Sample.parityInventory(matching: suite.fixtures),
                fusionCoverage: .bound(try Sample.fusionCoverage(expectations: expectations))
            )
        }
    }

    // MARK: Reconciliation

    @Test("A plan naming a different fixture suite is refused")
    func planMustNameThisSuite() throws {
        let catalog = try Sample.catalog()
        let plan = try Sample.plan(fixtureSuite: "suite.other-fixtures")

        #expect(
            throws: FixtureCatalogError.planFixtureSuiteMismatch(
                expected: Sample.artifact("suite.fixtures"),
                found: Sample.artifact("suite.other-fixtures")
            )
        ) {
            try catalog.reconcile(with: plan)
        }
    }

    @Test("A plan omitting a comparison the fixtures expect is refused")
    func planMustDeclareEveryExpectedComparison() throws {
        let catalog = try Sample.catalog()
        let expected = catalog.expectedReferenceComparisons
        #expect(expected.contains(.retainedBytes))
        #expect(!expected.contains(.provenanceState))

        let plan = try Sample.plan(comparisons: expected.subtracting([.retainedBytes]))
        #expect(throws: FixtureCatalogError.planComparisonMissing(.retainedBytes)) {
            try catalog.reconcile(with: plan)
        }

        try catalog.reconcile(with: try Sample.plan(comparisons: expected))
    }

    @Test("A provenance catalog expects the provenance-state comparison")
    func provenanceCatalogExpectsProvenanceComparison() throws {
        let catalog = try Sample.catalog(provenanceApplicable: true, withFusionCoverage: true)
        #expect(catalog.expectedReferenceComparisons.contains(.provenanceState))
        try catalog.reconcile(with: try Sample.plan(comparisons: Sample.expectedComparisons))
    }

    @Test("Provenance applicability must agree with the release capability set")
    func capabilityReconciliationIsTwoWay() throws {
        let pixelOnly = try Sample.catalog()
        try pixelOnly.reconcile(withCapabilities: [.pixelAnalysis])
        #expect(
            throws: FixtureCatalogError.provenanceApplicabilityMismatch(
                suiteApplicable: false,
                capabilityEnabled: true
            )
        ) {
            try pixelOnly.reconcile(
                withCapabilities: [.pixelAnalysis, .contentCredentialValidation]
            )
        }

        let withProvenance = try Sample.catalog(provenanceApplicable: true)
        try withProvenance.reconcile(
            withCapabilities: [.pixelAnalysis, .contentCredentialValidation]
        )
        #expect(
            throws: FixtureCatalogError.provenanceApplicabilityMismatch(
                suiteApplicable: true,
                capabilityEnabled: false
            )
        ) {
            try withProvenance.reconcile(withCapabilities: [.pixelAnalysis])
        }
    }

    // MARK: Coding

    @Test("The parity inventory and fusion coverage round-trip through JSON")
    func catalogRecordsRoundTrip() throws {
        let suite = try Sample.suite(provenanceApplicable: true)
        let inventory = try Sample.parityInventory(matching: suite.fixtures)
        let coverage = try Sample.fusionCoverage()

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(
            try decoder.decode(
                ModelParityFixtureInventory.self,
                from: try encoder.encode(inventory)
            ) == inventory
        )
        #expect(
            try decoder.decode(
                FusionFixtureCoverage.self,
                from: try encoder.encode(coverage)
            ) == coverage
        )
    }

    @Test("Decoding applies the same completeness rules as construction")
    func decodingIsValidated() throws {
        let suite = try Sample.suite()
        let inventory = try Sample.parityInventory(matching: suite.fixtures)
        let encoded = try JSONEncoder().encode(inventory)
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var references = try #require(object["references"] as? [Any])
        references.removeLast()
        object["references"] = references
        let trimmed = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ModelParityFixtureInventory.self, from: trimmed)
        }
    }
}
