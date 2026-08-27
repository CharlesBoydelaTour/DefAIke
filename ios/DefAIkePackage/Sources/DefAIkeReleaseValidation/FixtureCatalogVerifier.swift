import DefAIkeDomain
import CryptoKit

// Checking that a catalogued fixture's asset is the bytes the catalog declares.
//
// The verifier does exactly one thing: for each catalogued fixture, read the bytes at
// its canonical asset path and compare their size and SHA-256 against the values the
// signed catalog records. It has no other job, and in particular:
//
//   * it never produces an expected result. It compares declared against observed, so
//     a catalog with no approved expectation cannot be completed by running it;
//   * it never skips. A missing asset is a failing fixture, not an absent one, so a
//     partially populated suite cannot pass by having fewer fixtures to check
//     (Requirements 13.19 and 14.15);
//   * it never writes. The store seam has no member that could create the asset it
//     just failed to find.
//
// A pass here is not release evidence on its own. It says the catalogued bytes are the
// approved bytes. Running those fixtures on an approved physical iPhone under the
// approved plan is tasks 14.2 and 14.3, and only a physical-device result can satisfy a
// device gate (Requirement 13.16).

// MARK: - Findings

/// Why one catalogued fixture's asset does not match its catalog entry.
public enum FixtureAssetFinding: Hashable, Sendable, CustomStringConvertible {
    /// Nothing exists at the catalogued path.
    case assetMissing

    /// The path exists but is not a regular file.
    case assetNotAFile

    /// The path is a symbolic link. A fixture asset is fixed bytes; a link can point at
    /// different bytes than the ones the catalog was signed over.
    case assetIsSymbolicLink

    /// The asset exists but its bytes could not be read.
    case assetUnreadable

    /// The asset store itself is unavailable, so nothing was checked.
    case storeUnavailable

    /// Observed bytes disagree with the catalogued byte count.
    case byteCountMismatch(declared: UInt64, found: UInt64)

    /// The asset kept producing bytes past the count the catalog declares. Reading
    /// stopped at that bound, so the true size is unknown and is not guessed.
    case readExceededDeclaredByteCount(declared: UInt64)

    /// The asset's bytes digest to a different value than the catalog declares.
    case digestMismatch

    public var description: String {
        switch self {
        case .assetMissing:
            return "the catalogued asset is absent"
        case .assetNotAFile:
            return "the catalogued path is not a regular file"
        case .assetIsSymbolicLink:
            return "the catalogued path is a symbolic link"
        case .assetUnreadable:
            return "the catalogued asset could not be read"
        case .storeUnavailable:
            return "the fixture asset store is unavailable"
        case let .byteCountMismatch(declared, found):
            return "the asset holds \(found) bytes; the catalog declares \(declared)"
        case let .readExceededDeclaredByteCount(declared):
            return "the asset runs past its declared \(declared) bytes"
        case .digestMismatch:
            return "the asset does not match its declared content digest"
        }
    }
}

// MARK: - Results

/// The result of checking one catalogued fixture's asset.
public struct FixtureAssetVerification: Hashable, Sendable {
    public let fixture: FixtureID
    public let family: FixtureFamily
    public let assetPath: CanonicalRelativePath

    /// Every finding, empty when the asset matched its entry exactly.
    public let findings: [FixtureAssetFinding]

    public init(
        fixture: FixtureID,
        family: FixtureFamily,
        assetPath: CanonicalRelativePath,
        findings: [FixtureAssetFinding]
    ) {
        self.fixture = fixture
        self.family = family
        self.assetPath = assetPath
        self.findings = findings
    }

    /// The outcome, derived from the findings.
    ///
    /// Only ``GateOutcome/passed`` and ``GateOutcome/failed`` are reachable. There is
    /// deliberately no path to ``GateOutcome/notExecuted``: every catalogued fixture is
    /// checked, so an absent asset is a failure rather than a fixture that quietly did
    /// not participate.
    public var outcome: GateOutcome { findings.isEmpty ? .passed : .failed }
}

/// The result of checking every catalogued fixture in one catalog.
public struct FixtureCatalogVerification: Hashable, Sendable {
    /// The suite that was checked.
    public let suite: ArtifactID

    /// One result per catalogued fixture, in catalogue order.
    public let results: [FixtureAssetVerification]

    public init(suite: ArtifactID, results: [FixtureAssetVerification]) {
        self.suite = suite
        self.results = results
    }

    /// Fixtures whose asset did not match its catalog entry.
    public var failures: [FixtureAssetVerification] {
        results.filter { !$0.outcome.isPassing }
    }

    /// Fixtures whose asset is absent.
    public var missingAssets: [FixtureID] {
        results.filter { $0.findings.contains(.assetMissing) }.map(\.fixture)
    }

    /// The overall outcome. Passing requires every catalogued fixture to match.
    ///
    /// An empty result set fails: a verification that checked nothing is not a pass.
    public var outcome: GateOutcome {
        results.isEmpty || !failures.isEmpty ? .failed : .passed
    }
}

// MARK: - Verifier

/// Compares each catalogued fixture's asset against its catalog entry.
public struct FixtureCatalogVerifier: Sendable {
    /// Streaming granularity. A memory decision: chunk boundaries cannot change a
    /// digest, so this is not part of any approved value.
    public static let defaultChunkByteCount = 64 * 1024

    private let store: any FixtureAssetReading
    private let chunkByteCount: Int

    public init(
        store: any FixtureAssetReading,
        chunkByteCount: Int = FixtureCatalogVerifier.defaultChunkByteCount
    ) {
        self.store = store
        self.chunkByteCount = max(1, chunkByteCount)
    }

    /// Checks every fixture the catalog declares.
    public func verify(_ catalog: FixtureCatalog) -> FixtureCatalogVerification {
        FixtureCatalogVerification(
            suite: catalog.suite.id,
            results: catalog.suite.fixtures.map { verify($0, in: catalog.suite.id) }
        )
    }

    private func verify(
        _ fixture: FixtureRecord,
        in suite: ArtifactID
    ) -> FixtureAssetVerification {
        FixtureAssetVerification(
            fixture: fixture.id,
            family: fixture.family,
            assetPath: fixture.assetPath,
            findings: findings(for: fixture, in: suite)
        )
    }

    private func findings(
        for fixture: FixtureRecord,
        in suite: ArtifactID
    ) -> [FixtureAssetFinding] {
        let kind: FixtureAssetKind
        do {
            kind = try store.kind(at: fixture.assetPath, in: suite)
        } catch {
            return [Self.finding(for: error)]
        }

        let declared = fixture.byteCount.value
        switch kind {
        case .directory, .other:
            return [.assetNotAFile]
        case .symbolicLink:
            return [.assetIsSymbolicLink]
        case let .file(byteCount):
            guard byteCount == declared else {
                return [.byteCountMismatch(declared: declared, found: byteCount)]
            }
        }

        var hasher = CryptoKit.SHA256()
        var readByteCount: UInt64 = 0
        var exceededDeclaredBound = false
        do {
            try store.readAsset(
                at: fixture.assetPath,
                in: suite,
                chunkByteCount: chunkByteCount
            ) { chunk in
                guard !chunk.isEmpty else { return .proceed }
                guard readByteCount + UInt64(chunk.count) <= declared else {
                    exceededDeclaredBound = true
                    return .stop
                }
                readByteCount += UInt64(chunk.count)
                chunk.withUnsafeBufferPointer { buffer in
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
                }
                // Reading continues past the declared count deliberately. Stopping the
                // moment the declared bytes are consumed would make an understated
                // enumerated size undetectable, so the next chunk is what trips the
                // bound above.
                return .proceed
            }
        } catch {
            return [Self.finding(for: error)]
        }

        if exceededDeclaredBound {
            return [.readExceededDeclaredByteCount(declared: declared)]
        }
        guard readByteCount == declared else {
            return [.byteCountMismatch(declared: declared, found: readByteCount)]
        }
        guard let observed = DefAIkeDomain.SHA256Digest(bytes: Array(hasher.finalize())) else {
            // Unreachable: SHA-256 is fixed at the digest width the domain value requires.
            return [.digestMismatch]
        }
        return observed == fixture.contentDigest ? [] : [.digestMismatch]
    }

    private static func finding(for fault: FixtureAssetFault) -> FixtureAssetFinding {
        switch fault {
        case .assetMissing: .assetMissing
        case .assetUnreadable: .assetUnreadable
        case .storeUnavailable: .storeUnavailable
        }
    }
}
