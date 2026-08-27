import Testing

@testable import DefAIkeDomain
@testable import DefAIkePresentation

// The second half of Requirement 8.1.
//
// ``ApprovedCopyBinding`` already refused a release whose catalogue omits a reachable
// surface, so after binding every reachable surface has a key. Whether that key has an
// approved English value is a separate question, and it is the one
// ``ResolvedCopyReference`` answers: "a lookup that finds no value there is a
// release-validation failure, never a reason to show this key to a user."
//
// These tests check both directions. A catalog that covers a binding passes; a catalog
// missing one value, carrying an unapproved review state, or carrying a blank sentence
// fails and names the key. And because reachability depends on the capability
// composition, the required key set grows when provenance and fusion are enabled - a
// pixel-only catalog is not failed for omitting provenance states, and a
// provenance-enabled one is failed for omitting even one.
//
// The last test is the honest one: the catalog this repository ships does not cover a
// synthetic release's keys, because the wording for every surface other than the three
// fixed pixel labels is still external approved content. The failure is a named list of
// keys rather than a blank screen, which is the whole point of the gate.

@Suite("Approved copy coverage")
struct StringCatalogCoverageTests {

    @Test("A catalog covering every resolvable key passes")
    func coveringCatalogPasses() throws {
        let binding = try CopyFixture.pixelOnlyBinding()
        let catalog = CatalogFixture.covering(binding)

        #expect(StringCatalogCoverage.missingValues(in: catalog, for: binding).isEmpty)
        try StringCatalogCoverage.audit(catalog, for: binding)
    }

    @Test("One missing value fails closed and names the key")
    func missingValueNamesTheKey() throws {
        let binding = try CopyFixture.pixelOnlyBinding()
        let omitted = CopyFixture.localizationKey(for: .evidenceScope)
        var strings = CatalogFixture.covering(binding).strings
        strings[omitted.rawValue] = nil
        let catalog = CatalogFixture.catalog(strings)

        #expect(StringCatalogCoverage.missingValues(in: catalog, for: binding) == [omitted])
        #expect(throws: StringCatalogError.missingApprovedValues([omitted])) {
            try StringCatalogCoverage.audit(catalog, for: binding)
        }
    }

    @Test("An unapproved review state counts as no value", arguments: ["new", "needs_review"])
    func unapprovedStateCountsAsMissing(state: String) throws {
        // A `new` or `needs_review` entry is wording nobody approved yet, so treating it
        // as coverage would let unapproved copy reach a user.
        let binding = try CopyFixture.pixelOnlyBinding()
        let key = CopyFixture.localizationKey(for: .privacyExplanation)
        var strings = CatalogFixture.covering(binding).strings
        strings[key.rawValue] = CatalogFixture.entry("Draft wording", state: state)

        #expect(
            StringCatalogCoverage.missingValues(
                in: CatalogFixture.catalog(strings),
                for: binding
            ) == [key]
        )
    }

    @Test("A blank value counts as no value")
    func blankValueCountsAsMissing() throws {
        let binding = try CopyFixture.pixelOnlyBinding()
        let key = CopyFixture.localizationKey(for: .modelInformation)
        var strings = CatalogFixture.covering(binding).strings
        strings[key.rawValue] = CatalogFixture.entry("   ")

        #expect(
            StringCatalogCoverage.missingValues(
                in: CatalogFixture.catalog(strings),
                for: binding
            ) == [key]
        )
    }

    @Test("A value in the wrong language does not count as coverage")
    func wrongLanguageCountsAsMissing() throws {
        let binding = try CopyFixture.pixelOnlyBinding()
        let key = CopyFixture.localizationKey(for: .correctionChannel)
        var strings = CatalogFixture.covering(binding).strings
        strings[key.rawValue] = CatalogFixture.entry("Valeur", language: "fr")

        #expect(
            StringCatalogCoverage.missingValues(
                in: CatalogFixture.catalog(strings),
                for: binding
            ) == [key]
        )
    }

    @Test("A pluralized entry is covered by its variations")
    func pluralizedEntryIsCovered() throws {
        let binding = try CopyFixture.pixelOnlyBinding()
        let key = CopyFixture.localizationKey(for: .evidenceScope)
        var strings = CatalogFixture.covering(binding).strings
        strings[key.rawValue] = CatalogFixture.pluralEntry(
            categories: ["one": "One scope statement", "other": "Several scope statements"]
        )

        #expect(
            StringCatalogCoverage.missingValues(
                in: CatalogFixture.catalog(strings),
                for: binding
            ).isEmpty
        )
    }

    @Test("Missing keys are reported in stable order")
    func missingKeysAreOrdered() throws {
        let binding = try CopyFixture.pixelOnlyBinding()
        let missing = CatalogFixture.resolvableKeys(of: binding)
        let empty = CatalogFixture.catalog([:])

        let reported = StringCatalogCoverage.missingValues(in: empty, for: binding)

        #expect(reported == missing)
        #expect(reported == reported.sorted { $0.rawValue < $1.rawValue })
        #expect(reported.isEmpty == false)
    }

    @Test("The required key set grows with the enabled capability set")
    func requiredKeysFollowReachability() throws {
        // Requirement 8.1 says "every reachable", and reachability is a fact about the
        // capability composition (Requirements 6.20, 7.10, and 7.16).
        let pixelOnly = CatalogFixture.resolvableKeys(of: try CopyFixture.pixelOnlyBinding())
        let provenance = CatalogFixture.resolvableKeys(of: try CopyFixture.provenanceBinding())
        let fusion = CatalogFixture.resolvableKeys(of: try CopyFixture.fusionBinding())

        #expect(Set(pixelOnly).isStrictSubset(of: Set(provenance)))
        #expect(Set(provenance).isStrictSubset(of: Set(fusion)))
    }

    @Test("A pixel-only catalog is not failed for omitting provenance states")
    func pixelOnlyCatalogNeedsNoProvenanceStates() throws {
        let pixelOnly = try CopyFixture.pixelOnlyBinding()
        let catalog = CatalogFixture.covering(pixelOnly)

        try StringCatalogCoverage.audit(catalog, for: pixelOnly)

        // The same catalog does not cover a provenance-enabled release.
        let provenance = try CopyFixture.provenanceBinding()
        #expect(StringCatalogCoverage.missingValues(in: catalog, for: provenance).isEmpty == false)
    }

    @Test("The shipped catalog does not yet cover a release's approved copy")
    func shippedCatalogCoversOnlyWhatIsFixed() throws {
        // Honest state of the repository: Requirement 8.2 fixes three display strings, and
        // every other Version 1 sentence is external approved content that has not been
        // decided. The gate reports the gap by key. It does not fill it, and nothing
        // renders a key in its place.
        let binding = try CopyFixture.pixelOnlyBinding()
        let shipped = try EnglishStringCatalog.loadShippedCatalog()

        let missing = StringCatalogCoverage.missingValues(in: shipped, for: binding)
        let fixedLabelKeys = Set(EnglishStringCatalog.fixedPixelLabelKeys.values)

        #expect(missing.isEmpty == false)
        #expect(Set(missing).isDisjoint(with: fixedLabelKeys))
        #expect(missing.contains(CopyFixture.localizationKey(for: .evidenceScope)))
        #expect(throws: StringCatalogError.missingApprovedValues(missing)) {
            try StringCatalogCoverage.audit(shipped, for: binding)
        }
    }
}
