import DefAIkeDomain
import Testing

@testable import DefAIkeReleaseValidation

// Asset verification tests.
//
// The behavior under test is narrow and the important half of it is negative: a
// catalogued fixture whose asset is absent, mutated, or unreadable has to fail, and
// there must be no path by which it is quietly not counted. Nothing here lets the
// verifier supply the bytes or the expected result it failed to find.

@Suite("Fixture asset verification")
struct FixtureCatalogVerifierTests {
    @Test("A complete asset store passes every catalogued fixture")
    func completeStorePasses() throws {
        let catalog = try Sample.catalog(provenanceApplicable: true, withFusionCoverage: true)
        let verification = FixtureCatalogVerifier(
            store: FakeFixtureAssetStore.complete(for: catalog.suite)
        ).verify(catalog)

        #expect(verification.outcome == .passed)
        #expect(verification.failures.isEmpty)
        #expect(verification.missingAssets.isEmpty)
        #expect(verification.results.count == catalog.suite.fixtures.count)
        #expect(verification.suite == catalog.suite.id)
        #expect(verification.results.allSatisfy { $0.findings.isEmpty })
    }

    @Test("A missing asset fails rather than being skipped")
    func missingAssetFails() throws {
        let catalog = try Sample.catalog()
        let target = catalog.suite.fixtures[0]
        var store = FakeFixtureAssetStore.complete(for: catalog.suite)
        store.removeAsset(at: target.assetPath)

        let verification = FixtureCatalogVerifier(store: store).verify(catalog)
        let result = try #require(verification.results.first { $0.fixture == target.id })

        #expect(result.findings == [.assetMissing])
        // The fixture is still reported, with a failing outcome. There is no
        // "not executed" result that a gate could then ignore.
        #expect(result.outcome == .failed)
        #expect(verification.missingAssets == [target.id])
        #expect(verification.failures.count == 1)
        #expect(verification.outcome == .failed)
        #expect(verification.results.count == catalog.suite.fixtures.count)
    }

    @Test("Mutated bytes of the same length fail on the digest")
    func digestMismatchFails() throws {
        let catalog = try Sample.catalog()
        let target = catalog.suite.fixtures[3]
        var store = FakeFixtureAssetStore.complete(for: catalog.suite)
        var mutated = Sample.assetBytes(forPath: target.assetPath.rawValue)
        mutated[0] ^= 0xFF
        store.replaceBytes(at: target.assetPath, with: mutated)

        let verification = FixtureCatalogVerifier(store: store).verify(catalog)
        let result = try #require(verification.results.first { $0.fixture == target.id })

        #expect(result.findings == [.digestMismatch])
        #expect(verification.outcome == .failed)
        #expect(verification.missingAssets.isEmpty)
    }

    @Test("A different byte count fails before the bytes are hashed")
    func byteCountMismatchFails() throws {
        let catalog = try Sample.catalog()
        let target = catalog.suite.fixtures[1]
        let declared = target.byteCount.value
        var store = FakeFixtureAssetStore.complete(for: catalog.suite)
        store.replaceBytes(
            at: target.assetPath,
            with: Sample.assetBytes(forPath: target.assetPath.rawValue) + [0x00]
        )

        let verification = FixtureCatalogVerifier(store: store).verify(catalog)
        let result = try #require(verification.results.first { $0.fixture == target.id })

        #expect(
            result.findings == [.byteCountMismatch(declared: declared, found: declared + 1)]
        )
        #expect(verification.outcome == .failed)
    }

    @Test("An understated enumerated size is caught while streaming")
    func understatedSizeFails() throws {
        let catalog = try Sample.catalog()
        let target = catalog.suite.fixtures[2]
        var store = FakeFixtureAssetStore.complete(for: catalog.suite)
        // The store reports the declared size but hands back more bytes.
        store.replaceBytesKeepingEnumeratedSize(
            at: target.assetPath,
            with: Sample.assetBytes(forPath: target.assetPath.rawValue) + Array(repeating: 0x41, count: 32)
        )

        let verification = FixtureCatalogVerifier(store: store).verify(catalog)
        let result = try #require(verification.results.first { $0.fixture == target.id })

        #expect(
            result.findings == [
                .readExceededDeclaredByteCount(declared: target.byteCount.value)
            ]
        )
        #expect(verification.outcome == .failed)
    }

    @Test("Truncated content fails on the observed byte count")
    func truncatedContentFails() throws {
        let catalog = try Sample.catalog()
        let target = catalog.suite.fixtures[4]
        let declared = target.byteCount.value
        var store = FakeFixtureAssetStore.complete(for: catalog.suite)
        store.replaceBytesKeepingEnumeratedSize(
            at: target.assetPath,
            with: Array(Sample.assetBytes(forPath: target.assetPath.rawValue).dropLast(4))
        )

        let verification = FixtureCatalogVerifier(store: store).verify(catalog)
        let result = try #require(verification.results.first { $0.fixture == target.id })

        #expect(
            result.findings == [.byteCountMismatch(declared: declared, found: declared - 4)]
        )
    }

    @Test("A directory or a symbolic link is not a fixture asset")
    func nonFileEntriesFail() throws {
        let catalog = try Sample.catalog()
        let directoryTarget = catalog.suite.fixtures[5]
        let linkTarget = catalog.suite.fixtures[6]
        var store = FakeFixtureAssetStore.complete(for: catalog.suite)
        store.setKind(.directory, at: directoryTarget.assetPath)
        store.setKind(.symbolicLink, at: linkTarget.assetPath)

        let verification = FixtureCatalogVerifier(store: store).verify(catalog)

        #expect(
            try #require(verification.results.first { $0.fixture == directoryTarget.id })
                .findings == [.assetNotAFile]
        )
        #expect(
            try #require(verification.results.first { $0.fixture == linkTarget.id })
                .findings == [.assetIsSymbolicLink]
        )
        #expect(verification.failures.count == 2)
    }

    @Test("An unreadable asset fails")
    func unreadableAssetFails() throws {
        let catalog = try Sample.catalog()
        let target = catalog.suite.fixtures[7]
        var store = FakeFixtureAssetStore.complete(for: catalog.suite)
        store.makeUnreadable(at: target.assetPath)

        let verification = FixtureCatalogVerifier(store: store).verify(catalog)
        let result = try #require(verification.results.first { $0.fixture == target.id })

        #expect(result.findings == [.assetUnreadable])
        #expect(verification.outcome == .failed)
    }

    @Test("An unavailable store fails every fixture")
    func unavailableStoreFailsEverything() throws {
        let catalog = try Sample.catalog()
        var store = FakeFixtureAssetStore.complete(for: catalog.suite)
        store.isUnavailable = true

        let verification = FixtureCatalogVerifier(store: store).verify(catalog)

        #expect(verification.outcome == .failed)
        #expect(verification.failures.count == catalog.suite.fixtures.count)
        #expect(verification.results.allSatisfy { $0.findings == [.storeUnavailable] })
        #expect(verification.missingAssets.isEmpty)
    }

    @Test("Chunk boundaries do not change the result")
    func chunkBoundariesAreIrrelevant() throws {
        let catalog = try Sample.catalog()
        let store = FakeFixtureAssetStore.complete(for: catalog.suite)

        for chunkByteCount in [1, 3, 7, 4096] {
            let verification = FixtureCatalogVerifier(
                store: store,
                chunkByteCount: chunkByteCount
            ).verify(catalog)
            #expect(verification.outcome == .passed)
        }
    }

    @Test("A verification that checked nothing is not a pass")
    func emptyVerificationFails() {
        let verification = FixtureCatalogVerification(
            suite: Sample.artifact("suite.fixtures"),
            results: []
        )
        #expect(verification.outcome == .failed)
    }
}
