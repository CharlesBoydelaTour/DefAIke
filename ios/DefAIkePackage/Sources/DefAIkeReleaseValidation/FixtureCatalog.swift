import DefAIkeDomain

// The immutable fixture catalog: the Release Fixture Suite plus the approved records
// that make it complete and reconcilable.
//
// The suite itself is a signed domain artifact. It already binds every fixture to a
// content digest, an approved source artifact and version, and its declared expected
// results, and it already refuses a provenance fixture in a release that has not
// decided provenance applies. What it deliberately does not do is decide whether the
// catalogue is *complete*: its own documentation defers the reconciliation against the
// existing 96 model-parity references to a runner. This is that runner's schema.
//
// Three records join here, and each answers a question the suite alone cannot:
//
//   * ``ModelParityFixtureInventory`` — which fixture references the existing parity
//     evidence actually covers, so 96 is a reconciliation against an approved list
//     rather than a count the catalogue can satisfy with any 96 files
//     (Requirement 13.4).
//   * the suite's per-family expected results — whether each fixture declares the
//     expected outputs its family is compared on (Requirements 4.13, 6.18, 13.4,
//     13.5).
//   * ``FusionFixtureCoverage`` — whether all 15 lane combinations have an approved
//     fixture result, or whether fusion is not part of this release at all
//     (Requirements 7.14 and 7.16).
//
// Every expected value in the catalog arrives from an approved artifact. Nothing in
// this file computes, defaults, or infers one, and the asset seam this module reads
// through cannot write, so a fixture whose asset is missing fails rather than being
// completed from the implementation under test.

// MARK: - Model-parity reference inventory

/// One reference the existing model-parity evidence covers.
///
/// The digest is what makes this a reference to fixed bytes rather than to whatever
/// currently sits under the same fixture identifier.
public struct ModelParityReference: Hashable, Codable, Sendable {
    public let fixture: FixtureID

    /// Digest of the bytes the existing parity measurement ran against.
    public let contentDigest: SHA256Digest

    public init(fixture: FixtureID, contentDigest: SHA256Digest) {
        self.fixture = fixture
        self.contentDigest = contentDigest
    }
}

/// The approved inventory of existing model-parity fixture references.
///
/// Requirement 13.4 fixes the count at the 96 fixtures the existing PyTorch/Core ML
/// parity evidence was measured on. The identities and digests are an external
/// approved input: this record carries them so a catalogue can be reconciled against
/// them exactly, in both directions.
public struct ModelParityFixtureInventory: Hashable, Codable, Sendable {
    /// The number of references the existing evidence covers.
    ///
    /// Read from the domain artifact rather than restated, so the two cannot drift.
    public static let requiredReferenceCount = ReleaseFixtureSuite
        .requiredModelParityFixtureCount

    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// The immutable evidence artifact these references were read from.
    public let source: EvidenceSource

    /// Exactly ``requiredReferenceCount`` references, each fixture once.
    public let references: [ModelParityReference]

    /// The decision that approved this inventory. Presence is not approval.
    public let approval: ApprovalRecord

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        source: EvidenceSource,
        references: [ModelParityReference],
        approval: ApprovalRecord
    ) throws(FixtureCatalogError) {
        guard approval.isApproved else {
            throw FixtureCatalogError.parityInventoryNotApproved(id)
        }
        guard references.count == Self.requiredReferenceCount else {
            throw FixtureCatalogError.parityReferenceCountMismatch(
                expected: Self.requiredReferenceCount,
                found: references.count
            )
        }
        var seen = Set<FixtureID>()
        for reference in references where !seen.insert(reference.fixture).inserted {
            throw FixtureCatalogError.duplicateParityReference(reference.fixture)
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.source = source
        self.references = references
        self.approval = approval
    }

    /// The declared digest for one reference, or `nil` when the inventory omits it.
    public func contentDigest(for fixture: FixtureID) -> SHA256Digest? {
        references.first { $0.fixture == fixture }?.contentDigest
    }

    /// Every referenced fixture identity.
    public var referencedFixtures: Set<FixtureID> {
        Set(references.map(\.fixture))
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, source, references, approval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                source: container.decode(EvidenceSource.self, forKey: .source),
                references: container.decode([ModelParityReference].self, forKey: .references),
                approval: container.decode(ApprovalRecord.self, forKey: .approval)
            )
        } catch let error as FixtureCatalogError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - Fusion fixture coverage

/// The approved fixture result for one enabled lane combination.
public struct FusionFixtureExpectation: Hashable, Codable, Sendable {
    public let combination: FusionLaneCombination

    /// The catalogued fixture that demonstrates this combination.
    public let fixture: FixtureID

    /// The Combined Summary behavior approved for this combination, including explicit
    /// omission (Requirement 7.12).
    public let expectedDisposition: FusionDisposition

    /// The immutable artifact this expected behavior was read from.
    public let source: EvidenceSource

    public init(
        combination: FusionLaneCombination,
        fixture: FixtureID,
        expectedDisposition: FusionDisposition,
        source: EvidenceSource
    ) {
        self.combination = combination
        self.fixture = fixture
        self.expectedDisposition = expectedDisposition
        self.source = source
    }
}

/// Fixture results for all 15 lane combinations of one Evidence Fusion Rule.
///
/// Requirement 7.14 requires the approved Combined Summary behavior to be verified with
/// fixtures for all 15 combinations, and Requirement 7.15 prevents use of a rule that
/// lacks an approved fixture result for any of them. Coverage is therefore exact or the
/// record does not exist: a release with no fusion carries an approved not-applicable
/// decision instead, which Requirement 7.16 permits.
public struct FusionFixtureCoverage: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// The rule whose behavior these fixtures demonstrate.
    public let fusionRule: ArtifactID

    /// Exactly one expectation per lane combination, each naming its own fixture.
    public let expectations: [FusionFixtureExpectation]

    /// The decision that approved this coverage record.
    public let approval: ApprovalRecord

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        fusionRule: ArtifactID,
        expectations: [FusionFixtureExpectation],
        approval: ApprovalRecord
    ) throws(FixtureCatalogError) {
        guard approval.isApproved else {
            throw FixtureCatalogError.fusionCoverageNotApproved(id)
        }
        var seenCombinations = Set<String>()
        var seenFixtures = Set<FixtureID>()
        for expectation in expectations {
            guard seenCombinations.insert(expectation.combination.description).inserted else {
                throw FixtureCatalogError.duplicateFusionCombination(
                    expectation.combination.description
                )
            }
            guard seenFixtures.insert(expectation.fixture).inserted else {
                throw FixtureCatalogError.duplicateFusionFixture(expectation.fixture)
            }
        }
        let required = Set(FusionLaneCombination.allCombinations.map(\.description))
        let missing = required.subtracting(seenCombinations)
        guard missing.isEmpty else {
            throw FixtureCatalogError.fusionCombinationsMissing(missing.sorted())
        }
        // Unexpected keys cannot arise: `FusionLaneCombination` is the closed product
        // of the three pixel labels and the five enabled provenance states, and the
        // unavailable lane has no representation in it at all.
        self.id = id
        self.schemaVersion = schemaVersion
        self.fusionRule = fusionRule
        self.expectations = expectations
        self.approval = approval
    }

    /// The approved expectation for one combination. Total by construction.
    public func expectation(for combination: FusionLaneCombination) -> FusionFixtureExpectation {
        // Safe: the initializer proved every combination appears exactly once.
        expectations.first { $0.combination == combination }!
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, fusionRule, expectations, approval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                fusionRule: container.decode(ArtifactID.self, forKey: .fusionRule),
                expectations: container.decode(
                    [FusionFixtureExpectation].self,
                    forKey: .expectations
                ),
                approval: container.decode(ApprovalRecord.self, forKey: .approval)
            )
        } catch let error as FixtureCatalogError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - Catalog

/// The validated join of a Release Fixture Suite and its approved completeness records.
///
/// Construction is the completeness gate. A value of this type means: the catalogued
/// model-parity family reconciles exactly with the approved reference inventory in both
/// directions, every family the release requires has at least one fixture, every
/// fixture declares the expected results its family is compared on, and fusion is
/// either fixtured for all 15 combinations or carries an approved not-applicable
/// decision.
///
/// It does not mean the assets exist. That is a separate step, because it needs the
/// bytes: see ``FixtureCatalogVerifier``.
public struct FixtureCatalog: Hashable, Sendable {
    /// The signed, immutable fixture suite.
    public let suite: ReleaseFixtureSuite

    /// The approved inventory the model-parity family reconciles against.
    public let parityInventory: ModelParityFixtureInventory

    /// Fusion coverage, or the approved decision that this release has no fusion.
    public let fusionCoverage: ConditionalArtifactBinding<FusionFixtureCoverage>

    public init(
        suite: ReleaseFixtureSuite,
        parityInventory: ModelParityFixtureInventory,
        fusionCoverage: ConditionalArtifactBinding<FusionFixtureCoverage>
    ) throws(FixtureCatalogError) {
        try Self.reconcileParityFamily(suite: suite, inventory: parityInventory)
        try Self.requirePopulatedFamilies(suite)
        try Self.requireCompleteExpectations(suite)
        try Self.reconcileFusionCoverage(suite: suite, coverage: fusionCoverage.boundReference)
        self.suite = suite
        self.parityInventory = parityInventory
        self.fusionCoverage = fusionCoverage
    }

    // MARK: Reconciliation against other approved records

    /// Checks this catalog against the plan that would run it.
    ///
    /// Requirement 4.13 makes the approved Device Validation Plan the source of the
    /// preprocessing and logit parity limits, and Requirement 13.3 requires every
    /// comparison metric and tolerance to be declared before validation begins. A
    /// fixture that expects a comparison the plan never declared would run against no
    /// approved tolerance or agreement ratio, so it is a finding rather than a
    /// comparison this module bounds itself.
    public func reconcile(with plan: DeviceValidationPlan) throws(FixtureCatalogError) {
        guard plan.fixtureSuite == suite.id else {
            throw FixtureCatalogError.planFixtureSuiteMismatch(
                expected: suite.id,
                found: plan.fixtureSuite
            )
        }
        for metric in expectedReferenceComparisons.sorted(by: { $0.rawValue < $1.rawValue })
        where plan.comparison(for: metric) == nil {
            throw FixtureCatalogError.planComparisonMissing(metric)
        }
    }

    /// Checks this catalog's provenance applicability against a release capability set.
    ///
    /// The two records have to agree in both directions. A provenance-enabled release
    /// whose suite declares provenance inapplicable has no provenance fixtures at all
    /// (Requirement 13.5); a pixel-only release whose suite declares it applicable
    /// carries fixtures for a lane it will never produce (Requirements 6.19 and 6.20).
    public func reconcile(
        withCapabilities capabilities: Set<CapabilityID>
    ) throws(FixtureCatalogError) {
        let capabilityEnabled = capabilities.contains(.contentCredentialValidation)
        let suiteApplicable = suite.provenanceApplicability.isApplicable
        guard capabilityEnabled == suiteApplicable else {
            throw FixtureCatalogError.provenanceApplicabilityMismatch(
                suiteApplicable: suiteApplicable,
                capabilityEnabled: capabilityEnabled
            )
        }
    }

    // MARK: Projections

    /// Plan comparisons the catalogued expected results supply values for.
    public var expectedReferenceComparisons: Set<ComparisonMetric> {
        Set(suite.fixtures.flatMap { $0.expectations.compactMap(\.referenceComparison) })
    }

    /// Whether this catalog carries approved fusion coverage for all 15 combinations.
    public var hasFusionCoverage: Bool { fusionCoverage.isBound }

    // MARK: Validation steps

    private static func reconcileParityFamily(
        suite: ReleaseFixtureSuite,
        inventory: ModelParityFixtureInventory
    ) throws(FixtureCatalogError) {
        let catalogued = suite.fixtures(in: .modelParity)
        let cataloguedIdentities = Set(catalogued.map(\.id))
        let referenced = inventory.referencedFixtures

        let notCatalogued = referenced.subtracting(cataloguedIdentities)
        guard notCatalogued.isEmpty else {
            throw FixtureCatalogError.parityFixtureNotCatalogued(
                notCatalogued.sorted { $0.rawValue < $1.rawValue }
            )
        }
        let notReferenced = cataloguedIdentities.subtracting(referenced)
        guard notReferenced.isEmpty else {
            throw FixtureCatalogError.parityFixtureNotInInventory(
                notReferenced.sorted { $0.rawValue < $1.rawValue }
            )
        }
        for fixture in catalogued.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            guard inventory.contentDigest(for: fixture.id) == fixture.contentDigest else {
                throw FixtureCatalogError.parityDigestMismatch(fixture.id)
            }
        }
    }

    private static func requirePopulatedFamilies(
        _ suite: ReleaseFixtureSuite
    ) throws(FixtureCatalogError) {
        let missing = suite.missingFamilies.sorted { $0.rawValue < $1.rawValue }
        if let family = missing.first {
            throw FixtureCatalogError.requiredFamilyEmpty(family)
        }
    }

    private static func requireCompleteExpectations(
        _ suite: ReleaseFixtureSuite
    ) throws(FixtureCatalogError) {
        for fixture in suite.fixtures {
            var declared = Set<FixtureExpectationKind>()
            for expectation in fixture.expectations {
                guard declared.insert(expectation.kind).inserted else {
                    throw FixtureCatalogError.duplicateExpectationKind(
                        fixture: fixture.id,
                        kind: expectation.kind
                    )
                }
            }
            let missing = fixture.family.requiredExpectationKinds.subtracting(declared)
            guard missing.isEmpty else {
                throw FixtureCatalogError.expectationKindsMissing(
                    fixture: fixture.id,
                    kinds: missing.sorted { $0.rawValue < $1.rawValue }
                )
            }
        }
    }

    private static func reconcileFusionCoverage(
        suite: ReleaseFixtureSuite,
        coverage: FusionFixtureCoverage?
    ) throws(FixtureCatalogError) {
        guard let coverage else { return }
        guard suite.provenanceApplicability.isApplicable else {
            throw FixtureCatalogError.fusionCoverageWithoutProvenance
        }
        let ordered = coverage.expectations.sorted {
            $0.combination.description < $1.combination.description
        }
        for expectation in ordered {
            guard let fixture = suite.fixtures.first(where: { $0.id == expectation.fixture }) else {
                throw FixtureCatalogError.fusionFixtureNotCatalogued(expectation.fixture)
            }
            let state = expectation.combination.provenance
            guard state.demonstratingFamilies.contains(fixture.family) else {
                throw FixtureCatalogError.fusionFixtureFamilyMismatch(
                    fixture: fixture.id,
                    family: fixture.family,
                    expected: state
                )
            }
            let declaresLanes = fixture.expectations.contains(.provenanceState(state))
                && fixture.expectations.contains(.pixelLabel(expectation.combination.pixel))
            guard declaresLanes else {
                throw FixtureCatalogError.fusionFixtureExpectationMismatch(
                    fixture: fixture.id,
                    combination: expectation.combination.description
                )
            }
        }
    }
}
