import DefAIkeDomain

// Why a fixture catalog is not a usable release input.
//
// Separate from `ArtifactSchemaError`, which says one artifact is malformed, and from
// the closed `AnalysisError` set, which a user can see. A catalog finding is a release
// audit finding: it names the one reconciliation that failed so an auditor can point
// at a fixture, a family, or a combination rather than at "bad fixtures".
//
// Two rules shape every case:
//
//   * No case means "catalogued with a warning". A catalog either validates or
//     produces one of these findings.
//   * No case can be resolved by generating something. There is no "expected result
//     absent, will be recorded on first run": a fixture that does not declare its
//     approved expected result is a finding, because the alternative is letting the
//     implementation under test define its own expected output.

/// Why a fixture catalog, or one fixture in it, is not usable release evidence.
public enum FixtureCatalogError: Error, Equatable, Sendable, CustomStringConvertible {
    // MARK: Model-parity reference inventory

    /// The inventory that lists the existing model-parity fixture references carries a
    /// rejection rather than an approval. Presence is not approval.
    case parityInventoryNotApproved(ArtifactID)

    /// The inventory does not list exactly the number of existing model-parity
    /// fixtures Requirement 13.4 fixes.
    case parityReferenceCountMismatch(expected: Int, found: Int)

    /// The inventory lists the same fixture reference twice, so "the digest of this
    /// reference" is ambiguous.
    case duplicateParityReference(FixtureID)

    /// The inventory lists a reference the catalogued suite does not carry a fixture
    /// for. An unaccounted-for reference is a gap, never an implicit exclusion.
    case parityFixtureNotCatalogued([FixtureID])

    /// The suite catalogues a model-parity fixture the approved inventory does not
    /// list, so its expected results have no approved source.
    case parityFixtureNotInInventory([FixtureID])

    /// A catalogued model-parity fixture's content digest disagrees with the inventory,
    /// so the catalogued asset is not the bytes the existing parity evidence measured.
    case parityDigestMismatch(FixtureID)

    // MARK: Family completeness

    /// A required family has no catalogued fixture (Requirements 13.4 and 13.5).
    case requiredFamilyEmpty(FixtureFamily)

    /// The catalogued suite declares provenance applicable but the release's capability
    /// set does not enable provenance, or the reverse. Applicability is a decision and
    /// has to agree between the two records.
    case provenanceApplicabilityMismatch(suiteApplicable: Bool, capabilityEnabled: Bool)

    // MARK: Expected results

    /// A fixture does not declare every expected result its family is compared on.
    case expectationKindsMissing(fixture: FixtureID, kinds: [FixtureExpectationKind])

    /// A fixture declares two expected results of the same kind, so the approved
    /// expectation is ambiguous.
    case duplicateExpectationKind(fixture: FixtureID, kind: FixtureExpectationKind)

    // MARK: Fusion coverage

    /// Fusion fixture coverage is bound while the provenance lane is not applicable. A
    /// Combined Summary needs both lanes, so an unavailable lane cannot be fixtured
    /// (Requirements 7.10 and 7.16).
    case fusionCoverageWithoutProvenance

    /// The fusion coverage record carries a rejection rather than an approval.
    case fusionCoverageNotApproved(ArtifactID)

    /// Fusion coverage omits lane combinations. Requirement 7.14 requires a fixture
    /// result for all 15, and an omitted combination is not an implicit omission
    /// disposition.
    case fusionCombinationsMissing([String])

    /// Fusion coverage declares the same lane combination twice.
    case duplicateFusionCombination(String)

    /// Two fusion combinations name the same fixture. One fixture declares one
    /// expected pixel label and one expected provenance state, so it can demonstrate
    /// exactly one combination.
    case duplicateFusionFixture(FixtureID)

    /// A fusion combination names a fixture the suite does not catalogue.
    case fusionFixtureNotCatalogued(FixtureID)

    /// A fusion combination names a fixture whose family does not demonstrate that
    /// combination's provenance state.
    case fusionFixtureFamilyMismatch(
        fixture: FixtureID,
        family: FixtureFamily,
        expected: ProvenanceStateKey
    )

    /// A fusion combination names a fixture whose approved expected lane results are
    /// not the combination's, so the fixture does not demonstrate that combination.
    case fusionFixtureExpectationMismatch(fixture: FixtureID, combination: String)

    // MARK: Device Validation Plan reconciliation

    /// The plan under which the catalog would run names a different fixture suite.
    case planFixtureSuiteMismatch(expected: ArtifactID, found: ArtifactID)

    /// The catalog's fixtures expect a comparison the plan does not declare, so the
    /// comparison would run with no approved tolerance or agreement ratio.
    case planComparisonMissing(ComparisonMetric)

    public var description: String {
        switch self {
        case let .parityInventoryNotApproved(inventory):
            return "the model-parity reference inventory \(inventory.rawValue) is not approved"
        case let .parityReferenceCountMismatch(expected, found):
            return """
                the model-parity reference inventory lists \(found) references; the existing \
                evidence covers exactly \(expected)
                """
        case let .duplicateParityReference(fixture):
            return "the model-parity inventory lists \(fixture.rawValue) more than once"
        case let .parityFixtureNotCatalogued(fixtures):
            return """
                the catalog carries no model-parity fixture for referenced \
                \(fixtures.map(\.rawValue))
                """
        case let .parityFixtureNotInInventory(fixtures):
            return """
                model-parity fixtures \(fixtures.map(\.rawValue)) are catalogued but absent \
                from the approved reference inventory
                """
        case let .parityDigestMismatch(fixture):
            return """
                catalogued fixture \(fixture.rawValue) does not match the content digest the \
                approved parity inventory records
                """
        case let .requiredFamilyEmpty(family):
            return "the \(family.rawValue) fixture family is required and has no fixture"
        case let .provenanceApplicabilityMismatch(suiteApplicable, capabilityEnabled):
            return """
                the fixture suite declares provenance \
                \(suiteApplicable ? "applicable" : "not applicable") while the release \
                capability set \(capabilityEnabled ? "enables" : "does not enable") it
                """
        case let .expectationKindsMissing(fixture, kinds):
            return """
                fixture \(fixture.rawValue) declares no \(kinds.map(\.rawValue)) expected \
                result, which its family is compared on
                """
        case let .duplicateExpectationKind(fixture, kind):
            return "fixture \(fixture.rawValue) declares \(kind.rawValue) more than once"
        case .fusionCoverageWithoutProvenance:
            return """
                fusion fixture coverage is bound while the provenance lane is unavailable; a \
                Combined Summary needs both lanes
                """
        case let .fusionCoverageNotApproved(coverage):
            return "the fusion fixture coverage record \(coverage.rawValue) is not approved"
        case let .fusionCombinationsMissing(combinations):
            return "fusion fixture coverage omits the lane combinations \(combinations)"
        case let .duplicateFusionCombination(combination):
            return "fusion fixture coverage declares \(combination) more than once"
        case let .duplicateFusionFixture(fixture):
            return """
                fixture \(fixture.rawValue) is named for more than one lane combination; one \
                fixture demonstrates one combination
                """
        case let .fusionFixtureNotCatalogued(fixture):
            return "fusion fixture \(fixture.rawValue) is not catalogued in this suite"
        case let .fusionFixtureFamilyMismatch(fixture, family, expected):
            return """
                fusion fixture \(fixture.rawValue) is in the \(family.rawValue) family, which \
                does not demonstrate the \(expected.rawValue) provenance state
                """
        case let .fusionFixtureExpectationMismatch(fixture, combination):
            return """
                fusion fixture \(fixture.rawValue) does not expect the lane results of \
                \(combination)
                """
        case let .planFixtureSuiteMismatch(expected, found):
            return """
                the Device Validation Plan names fixture suite \(found.rawValue); this catalog \
                is \(expected.rawValue)
                """
        case let .planComparisonMissing(metric):
            return """
                the Device Validation Plan declares no \(metric.rawValue) comparison, which \
                catalogued fixtures expect
                """
        }
    }
}

extension FixtureCatalogError {
    /// Surfaces a catalog finding as a decoding failure.
    ///
    /// The catalog records decode by delegating to their validating initializers, so a
    /// signed catalog artifact cannot introduce a combination that in-process
    /// construction would reject.
    public func asDecodingError(codingPath: [any CodingKey]) -> DecodingError {
        DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: description,
                underlyingError: self
            )
        )
    }
}
