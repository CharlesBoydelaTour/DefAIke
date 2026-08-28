import CryptoKit
import Foundation
import Testing

@testable import DefAIkeDomain
@testable import DefAIkeProvenanceAPI
@testable import DefAIkeProvenanceC2PA

// Task 9.9, provenance half: approved offline fixtures driven through the real adapter.
//
// This file is an *integration* test, not a property test. Properties 19 through 22 already
// quantify the vendor-independent claims over generated inputs, and this file references
// them rather than restating them:
//
//   * **Property 19** (`ProvenanceCapabilitySelectionPropertyTests`) owns capability
//     selection and the pixel-only omission of the Combined Summary.
//   * **Property 20** (`ProvenanceMappingExclusivityPropertyTests`) owns the five-state
//     mapping, its exclusivity and totality, and the bounded allowlisted display
//     projection. Where a claim below touches a displayed field, it does so once, as the
//     end-to-end form of a claim that file already quantifies.
//   * **Property 21** owns lane immutability and noninterference.
//   * **Property 22** owns the 15-combination table, its exhaustiveness and determinism,
//     and the refusal of invalid tables. The fusion half of task 9.9 lives in
//     `DefAIkeApplicationTests/FusionFixtureLaneIntegrationTests.swift`, which drives the
//     approved dispositions through the lane-to-report pipeline rather than re-validating
//     tables here.
//
// What is added here is the part none of them can do: real byte sequences through the real
// `C2PALibraryReader` and the real `C2PAProvenanceValidator`, offline.
//
// # The line this file does not cross
//
// A trust store, a revocation answer, a signer policy, an assertion policy, and the
// expected state of any approved fixture are **approved external inputs**. None of them is
// chosen here. In particular this file never runs the validator against a fixture, records
// what it said, and enshrines that as the expected outcome — that would manufacture the
// evidence the Provenance Feasibility Gate exists to collect.
//
// So the claims split in two, and the split is deliberate and visible:
//
//   * **Checkable with no approved expectation.** Validation reaches no network client. No
//     network-capable library setting is left on a library default. The bytes handed to the
//     validator are exactly the retained bytes, by count and by a *real* SHA-256 recomputed
//     in the test. A container the adapter does not recognize never reaches the library. An
//     unsafe detail is refused rather than shown or silently dropped. The byte-preservation
//     status travels with the inspection and does not change the state. The approved copy a
//     transformed-byte limitation and a screenshot explanation need exists. And the real
//     validator never manufactures the `validated` state for bytes that carry no signature.
//   * **Needs an approved expected outcome.** "This fixture is validly signed", "this
//     tampered fixture is invalid", and the other four families (Requirements 6.18 and
//     13.11). Those are wired to ``ApprovedProvenanceFixtureCatalogue`` and are **skipped,
//     loudly, while the approved artifacts are absent** — never completed from the
//     implementation under test. ``ProvenanceFixtureComparison`` has no member that can
//     produce an expected state; the expected value is read from the fixture record's own
//     approved `provenanceState` expectation or the comparison fails.
//
// # The boundary a host run reaches, stated plainly
//
// The approved offline trust store is an approved artifact and is also absent. The reviewed
// validator refuses to be configured with the synthetic anchor bytes this target carries, so
// **every real read here stops at configuration and reports
// `ProvenanceFeasibilityFinding.validatorNotConfigurable`**. The library's manifest-reading
// path is therefore not reachable from this target today, and the runtime half of
// Requirements 6.7 and 6.8 past configuration is not established here. That boundary is
// pinned as its own assertion rather than left implicit: see
// `realLibraryReportsNoStateWithoutApprovedTrustAnchors`. Nothing below substitutes a state
// for it.
//
// The approved fixture suite and its assets are **absent from this repository** at the time
// of writing. That is a recorded state, not a silent one: `catalogueAbsenceIsRecorded`
// fails if an empty comparison ever reports a pass, and `comparisonReportsDisagreement`
// proves the skipped comparison would bite the moment the artifacts land.
//
// # What a host run is not
//
// These tests run on the development host and, under `build-ios.sh`, compile for the
// simulator. Neither is physical-device evidence. Requirement 13.11 is a *Device
// Validation Suite* gate on an approved iPhone under an approved Device Validation Plan;
// what this file establishes is that the comparison exists, is wired to approved inputs,
// and refuses to invent one. Task 14.2 owns the nonshipping parity runners that consume a
// physical-device result.
//
// # The recorded `ProvenanceAnalyzing` conformance gap
//
// `C2PAProvenanceValidator` deliberately does not conform to `ProvenanceAnalyzing`: the
// port returns `ProvenanceEvidence` unconditionally and cannot express a Provenance
// Feasibility Gate finding. That is an open spec-level question, not a defect, and it is
// why every test below calls `inspect(_:)` on the adapter directly instead of resolving a
// `ProvenanceLaneProvider` around it. The consequence for this file is recorded rather than
// worked around: **an approved fixture cannot currently be driven through the provider and
// into an Evidence Report in one call**, so the lane-level integration lives in the fusion
// file against the port, and the byte-level integration lives here against the adapter.
//
// **No policy, mapping, copy key, or trust value in this file is an approved release
// input.** They come from `C2PAAdapterFixtures.swift`, which says the same, and they exist
// so a seam that takes signed artifacts can be called at all.

// MARK: - The approved fixture catalogue

/// Whether the approved provenance fixture artifacts are installed, and where they were
/// looked for.
///
/// Deliberately not a `Bool`. A reader of a skipped test needs to know which paths were
/// searched, and an audit needs the absence to be a recorded value rather than an inference
/// from a test that did not run.
enum ApprovedFixtureCatalogueStatus: Equatable, CustomStringConvertible {
    /// No approved suite was found. Carries every location that was searched.
    case absent(searchedPaths: [String])

    /// An approved suite was found, and its assets are rooted at `assetRoot`.
    case present(suite: ReleaseFixtureSuite, assetRoot: URL)

    /// The suite was found but could not be read as one. A failure, never an absence:
    /// a malformed approved artifact is not the same as an uninstalled one.
    case unreadable(path: String, reason: String)

    var description: String {
        switch self {
        case let .absent(paths):
            "no approved provenance fixture suite at: \(paths.joined(separator: ", "))"
        case let .present(suite, root):
            "approved fixture suite \(suite.id.rawValue) with assets under \(root.path)"
        case let .unreadable(path, reason):
            "the approved fixture suite at \(path) could not be read: \(reason)"
        }
    }
}

/// Locates the approved Release Fixture Suite and its assets, read-only.
///
/// Two search locations, in order, and nothing else:
///
///   1. the path in `DEFAIKE_APPROVED_FIXTURE_SUITE`, for a runner that installs the
///      approved artifacts outside the working tree; then
///   2. `ios/ApprovedFixtures/release-fixture-suite.json` inside the repository.
///
/// There is no third location, no bundled default, and no writer. A build that has not been
/// given the approved artifacts cannot obtain them from here, which is what keeps a missing
/// asset a reported absence rather than a fabricated baseline (task 14.1's rule).
enum ApprovedProvenanceFixtureCatalogue {
    /// The suite file name inside the in-repository search location.
    static let suiteFileName = "release-fixture-suite.json"

    /// The environment variable a runner uses to point at an installed suite.
    static let environmentKey = "DEFAIKE_APPROVED_FIXTURE_SUITE"

    /// Resolved once per process: the search is filesystem work and its answer cannot
    /// change during a run.
    static let status: ApprovedFixtureCatalogueStatus = resolve()

    /// Whether the approved artifacts are installed, for a test's `.enabled(if:)` trait.
    static var isPresent: Bool {
        if case .present = status { return true }
        return false
    }

    /// The approved suite, or `nil` while the artifacts are absent or unreadable.
    static var suite: ReleaseFixtureSuite? {
        guard case let .present(suite, _) = status else { return nil }
        return suite
    }

    /// Every location that was searched, in search order.
    static var searchedPaths: [String] {
        var paths: [String] = []
        if let installed = ProcessInfo.processInfo.environment[environmentKey] {
            paths.append(installed)
        }
        paths.append(repositorySuiteURL.path)
        return paths
    }

    /// The in-repository search location.
    ///
    /// Derived from this file's own path so it does not depend on a working directory: four
    /// levels up from `Tests/DefAIkeProvenanceC2PATests/<file>` is `ios/`.
    private static var repositorySuiteURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ApprovedFixtures")
            .appendingPathComponent(suiteFileName)
    }

    private static func resolve() -> ApprovedFixtureCatalogueStatus {
        for path in searchedPaths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let data = try Data(contentsOf: url)
                let suite = try JSONDecoder().decode(ReleaseFixtureSuite.self, from: data)
                return .present(suite: suite, assetRoot: url.deletingLastPathComponent())
            } catch {
                return .unreadable(path: path, reason: "\(error)")
            }
        }
        return .absent(searchedPaths: searchedPaths)
    }
}

// MARK: - The comparison

/// One fixture's approved expected state beside the state the adapter actually produced.
///
/// The expected value has exactly one source: the fixture record's approved
/// `provenanceState` expectation. There is no initializer, no default, and no fallback that
/// could supply one from `observed`, which is what makes this a comparison rather than a
/// recording.
struct ProvenanceFixtureComparison: Equatable, CustomStringConvertible {
    /// Why a comparison could not be made at all.
    enum Obstruction: Equatable, CustomStringConvertible {
        /// The fixture declares no approved provenance state, so there is nothing to
        /// compare against. A failure, never a pass: filling it in from the adapter is the
        /// circularity this file exists to avoid.
        case approvedStateNotDeclared

        /// The fixture asset is not installed.
        case assetMissing(path: String)

        /// The adapter produced a Provenance Feasibility Gate finding instead of a state.
        case feasibilityFinding(String)

        var description: String {
            switch self {
            case .approvedStateNotDeclared:
                "the fixture declares no approved provenance state"
            case let .assetMissing(path):
                "the fixture asset is absent at \(path)"
            case let .feasibilityFinding(finding):
                "the adapter reported a feasibility finding: \(finding)"
            }
        }
    }

    let fixture: FixtureID
    let family: FixtureFamily

    /// The approved expected state, read from the fixture record.
    let approved: ProvenanceStateKey?

    /// The state the adapter produced, or `nil` when it produced none.
    let observed: ProvenanceStateKey?

    /// What stopped the comparison, or `nil` when both values are present.
    let obstruction: Obstruction?

    /// Whether the observed state is the approved one.
    ///
    /// False whenever either side is missing. An absent expectation and an absent
    /// observation are both failures to compare, not agreements.
    var agrees: Bool {
        guard let approved, let observed, obstruction == nil else { return false }
        return approved == observed
    }

    var description: String {
        if let obstruction {
            return "\(fixture.rawValue) [\(family.rawValue)]: \(obstruction)"
        }
        let approvedText = approved?.rawValue ?? "none"
        let observedText = observed?.rawValue ?? "none"
        return "\(fixture.rawValue) [\(family.rawValue)]: approved \(approvedText), "
            + "observed \(observedText)"
    }
}

/// The result of comparing every provenance fixture in one suite.
struct ProvenanceFixtureComparisonReport: Equatable {
    let comparisons: [ProvenanceFixtureComparison]

    var disagreements: [ProvenanceFixtureComparison] {
        comparisons.filter { !$0.agrees }
    }

    /// The families the compared fixtures covered.
    var coveredFamilies: Set<FixtureFamily> {
        Set(comparisons.map(\.family))
    }

    /// Whether every provenance fixture reached its approved state.
    ///
    /// An empty report is **not** a pass. A comparison that compared nothing has
    /// established nothing, and treating it as passing is exactly how a partially
    /// populated suite would slip through (Requirement 13.19's shape, applied to this
    /// comparison).
    var outcome: GateOutcome {
        comparisons.isEmpty || !disagreements.isEmpty ? .failed : .passed
    }
}

/// Runs the provenance families of one suite through a validator, comparing declared with
/// observed.
///
/// The reader is injected so the same harness serves the real library and a recording
/// double: the approved comparison uses `C2PALibraryReader`, and the non-vacuity witness
/// uses a stub whose answer the test chose. Either way the *expected* value comes from the
/// fixture record.
struct ProvenanceFixtureRunner {
    /// Bytes for one fixture, or `nil` when the asset is not installed.
    typealias AssetLoader = (FixtureRecord) -> [UInt8]?

    let policy: ProvenancePolicy
    let makeReader: (FixtureRecord) -> any C2PAManifestReading
    let loadAsset: AssetLoader

    func run(_ suite: ReleaseFixtureSuite) async -> ProvenanceFixtureComparisonReport {
        var comparisons: [ProvenanceFixtureComparison] = []
        for fixture in suite.fixtures where fixture.family.isProvenanceConditional {
            comparisons.append(await compare(fixture))
        }
        return ProvenanceFixtureComparisonReport(comparisons: comparisons)
    }

    private func compare(_ fixture: FixtureRecord) async -> ProvenanceFixtureComparison {
        let approved = fixture.approvedProvenanceState
        guard approved != nil else {
            return ProvenanceFixtureComparison(
                fixture: fixture.id,
                family: fixture.family,
                approved: nil,
                observed: nil,
                obstruction: .approvedStateNotDeclared
            )
        }
        guard let bytes = loadAsset(fixture) else {
            return ProvenanceFixtureComparison(
                fixture: fixture.id,
                family: fixture.family,
                approved: approved,
                observed: nil,
                obstruction: .assetMissing(path: fixture.assetPath.rawValue)
            )
        }

        // The digest is recomputed from the bytes the test is about to hand over, so the
        // adapter's exact-retained-bytes check runs against a true SHA-256 rather than a
        // placeholder (Requirement 6.6).
        let digest = TrueDigest.of(bytes)
        let asset = RealByteInspection.asset(
            fixture: fixture,
            byteCount: UInt64(bytes.count),
            digest: digest
        )
        let store = StubFinalizedObjectStore()
        await store.store(
            key: asset.handle.storageKey,
            session: asset.sessionID,
            bytes: bytes,
            declaredDigest: digest
        )
        let validator = C2PAProvenanceValidator(
            store: store,
            reader: makeReader(fixture),
            clock: SteppingClock(step: .milliseconds(1)),
            configuration: TrustSample.configuration(for: policy)
        )

        do {
            let evidence = try await validator.inspect(asset)
            return ProvenanceFixtureComparison(
                fixture: fixture.id,
                family: fixture.family,
                approved: approved,
                observed: evidence.stateKey,
                obstruction: nil
            )
        } catch {
            return ProvenanceFixtureComparison(
                fixture: fixture.id,
                family: fixture.family,
                approved: approved,
                observed: nil,
                obstruction: .feasibilityFinding("\(error)")
            )
        }
    }
}

extension FixtureRecord {
    /// The single approved provenance state this fixture declares, or `nil`.
    ///
    /// `nil` for a fixture that declares none and for one that declares two different
    /// ones: choosing between two approved answers by iteration order would decide in code
    /// what a release approved.
    var approvedProvenanceState: ProvenanceStateKey? {
        var declared: Set<ProvenanceStateKey> = []
        for expectation in expectations {
            if case let .provenanceState(state) = expectation { declared.insert(state) }
        }
        return declared.count == 1 ? declared.first : nil
    }
}

// MARK: - Real bytes and real digests

/// A real SHA-256 over test bytes.
///
/// `DefAIkeProvenanceC2PA` has no cryptographic implementation by design, and the adapter
/// documents that it does not recompute a digest. That makes the *test* the only place the
/// declared digest can be shown to be the true one, so this exists rather than another
/// `Sample.digest(_:)` placeholder.
enum TrueDigest {
    static func of(_ bytes: [UInt8]) -> DefAIkeDomain.SHA256Digest {
        guard let digest = DefAIkeDomain.SHA256Digest(
            bytes: Array(CryptoKit.SHA256.hash(data: Data(bytes)))
        ) else {
            preconditionFailure("SHA-256 is fixed at the width the domain value requires")
        }
        return digest
    }
}

/// Byte sequences the adapter's container table recognizes, built here rather than shipped.
///
/// These are **not fixtures and carry no Content Credential**. They exist so the real
/// library reader can be driven over each container the release accepts, and so the
/// assertions about them can only ever be negative or structural: nothing below claims a
/// trust outcome for them.
enum SyntheticContainerBytes {
    /// A JPEG start-of-image marker followed by filler.
    static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF] + Array(repeating: 0x00, count: 61)

    /// The eight-byte PNG signature followed by filler.
    static let png: [UInt8] =
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x00, count: 56)

    /// An ISO base media header whose brand the adapter groups as HEIC.
    static let heic: [UInt8] =
        [0x00, 0x00, 0x00, 0x18] + Array("ftyp".utf8) + Array("heic".utf8)
        + Array(repeating: 0x00, count: 48)

    /// An ISO base media header whose brand the adapter groups as HEIF.
    static let heif: [UInt8] =
        [0x00, 0x00, 0x00, 0x18] + Array("ftyp".utf8) + Array("mif1".utf8)
        + Array(repeating: 0x00, count: 48)

    /// Bytes matching no accepted container signature.
    static let unrecognized: [UInt8] = Array("not-an-accepted-container".utf8)

    /// Every recognized container, with the case the adapter must classify it as.
    static let recognized: [(name: String, bytes: [UInt8], container: StaticContainer)] = [
        ("jpeg", jpeg, .jpeg),
        ("png", png, .png),
        ("heic", heic, .heic),
        ("heif", heif, .heif),
    ]
}

/// Assembles one inspection over real bytes with a real digest.
enum RealByteInspection {
    /// An accepted ingest describing `byteCount` bytes with digest `digest`.
    static func asset(
        session identifier: String = "session.real-bytes",
        storage: String = "object.real-bytes",
        byteCount: UInt64,
        digest: DefAIkeDomain.SHA256Digest,
        preservation: BytePreservationStatus = .originalBytes,
        basis: PreservationBasis = .providerDeclaredOriginalRepresentation
    ) -> ImportedEncodedAsset {
        guard let sessionID = AnalysisSessionID(identifier),
              let storageKey = EphemeralStorageKey(storage),
              let handle = EncodedAssetHandle(
                  sessionID: sessionID,
                  storageKey: storageKey,
                  byteCount: byteCount,
                  sha256: digest,
                  protection: .complete
              ),
              let asset = ImportedEncodedAsset(
                  route: .photosPicker,
                  handle: handle,
                  preservationStatus: preservation,
                  preservationBasis: basis,
                  contentTypeHint: ContentTypeHint("public.jpeg")
              )
        else {
            preconditionFailure("an inspection over real bytes must be representable")
        }
        return asset
    }

    /// An accepted ingest for one catalogued fixture.
    ///
    /// The fixture identifier seeds the session and object keys so a suite of fixtures
    /// produces distinct sessions, and nothing else about the fixture reaches the asset:
    /// the preservation status comes from the fixture's own approved expectation when it
    /// declares one.
    static func asset(
        fixture: FixtureRecord,
        byteCount: UInt64,
        digest: DefAIkeDomain.SHA256Digest
    ) -> ImportedEncodedAsset {
        var preservation = BytePreservationStatus.originalBytes
        var basis = PreservationBasis.providerDeclaredOriginalRepresentation
        for expectation in fixture.expectations {
            guard case let .bytePreservationStatus(key) = expectation else { continue }
            switch key {
            case .originalBytes:
                preservation = .originalBytes
            case .platformTransformedCopy:
                preservation = .platformTransformedCopy
                basis = .providerDeclaredTransformedRepresentation
            case .unknown:
                preservation = .unknown
                basis = .preservationHistoryNotEstablished
            }
        }
        return asset(
            session: "session.\(fixture.id.rawValue)",
            storage: "object.\(fixture.id.rawValue)",
            byteCount: byteCount,
            digest: digest,
            preservation: preservation,
            basis: basis
        )
    }

    /// A validator over a store already holding `bytes`, with a true digest.
    static func validator(
        policy: ProvenancePolicy,
        reader: any C2PAManifestReading,
        bytes: [UInt8]
    ) async -> (C2PAProvenanceValidator, ImportedEncodedAsset, DefAIkeDomain.SHA256Digest) {
        let digest = TrueDigest.of(bytes)
        let asset = asset(byteCount: UInt64(bytes.count), digest: digest)
        let store = StubFinalizedObjectStore()
        await store.store(
            key: asset.handle.storageKey,
            session: asset.sessionID,
            bytes: bytes,
            declaredDigest: digest
        )
        let validator = C2PAProvenanceValidator(
            store: store,
            reader: reader,
            clock: SteppingClock(step: .milliseconds(1)),
            configuration: TrustSample.configuration(for: policy)
        )
        return (validator, asset, digest)
    }
}

// MARK: - Approved fixture comparison

@Suite("Approved provenance fixtures through the real validator")
struct ApprovedProvenanceFixtureIntegrationTests {
    /// The six families Requirement 13.5 requires of a provenance-enabled release.
    static let requiredFamilies = FixtureFamily.provenanceFamilies

    /// Requirements 6.18 and 13.11.
    ///
    /// Skipped, with its reason visible in the run, while the approved artifacts are
    /// absent. When they are installed this drives every catalogued provenance fixture's
    /// real bytes through the real `C2PALibraryReader` and compares the produced state with
    /// the state the fixture record approves — under whichever signed Provenance Policy the
    /// installed suite is bound to, never under the synthetic sample below.
    ///
    /// A host or simulator pass here is a development check. Requirement 13.11 is satisfied
    /// only by a run on an approved physical iPhone under the approved Device Validation
    /// Plan, which task 14.2 owns.
    @Test(
        "Every approved provenance fixture reaches its approved exclusive state",
        .enabled(
            if: ApprovedProvenanceFixtureCatalogue.isPresent,
            "the approved provenance fixture suite is not installed"
        )
    )
    func approvedFixturesReachTheirApprovedState() async throws {
        let suite = try #require(
            ApprovedProvenanceFixtureCatalogue.suite,
            "the presence condition guarantees a decoded suite"
        )
        guard case let .present(_, assetRoot) = ApprovedProvenanceFixtureCatalogue.status else {
            Issue.record("the presence condition guarantees an asset root")
            return
        }

        // Requirement 13.5: a provenance-enabled suite carries all six families. A suite
        // missing one is a failing gate, not a shorter comparison.
        let catalogued = Set(
            suite.fixtures.filter(\.family.isProvenanceConditional).map(\.family)
        )
        #expect(
            Self.requiredFamilies.subtracting(catalogued).isEmpty,
            "the approved suite must catalogue every provenance family"
        )

        let runner = ProvenanceFixtureRunner(
            policy: PolicySample.policy(),
            makeReader: { _ in C2PALibraryReader() },
            loadAsset: { fixture in
                let url = assetRoot.appendingPathComponent(fixture.assetPath.rawValue)
                guard let data = try? Data(contentsOf: url) else { return nil }
                return [UInt8](data)
            }
        )
        let report = await runner.run(suite)

        #expect(
            report.outcome == .passed,
            Comment(
                rawValue: "every provenance fixture must reach its approved state; "
                    + "disagreements: "
                    + report.disagreements.map(\.description).joined(separator: "; ")
            )
        )
    }

    /// The absence of the approved artifacts is a recorded state, not a silent skip.
    ///
    /// Always runs, and asserts something in both worlds. While the artifacts are absent it
    /// requires the absence to name the paths that were searched, and requires a comparison
    /// over an empty suite to be a *failure* rather than a vacuous pass. When they are
    /// installed it requires the six families to be catalogued, so the same test keeps
    /// meaning after they land.
    @Test("An absent approved fixture suite is recorded and never reports a pass")
    func catalogueAbsenceIsRecorded() {
        switch ApprovedProvenanceFixtureCatalogue.status {
        case let .absent(searchedPaths):
            #expect(!searchedPaths.isEmpty, "an absence must name where it looked")
            #expect(
                searchedPaths.contains { $0.hasSuffix(
                    ApprovedProvenanceFixtureCatalogue.suiteFileName
                ) },
                "the in-repository location must be one of the searched paths"
            )
            // The absence describes itself, so an investigator reading a skipped run learns
            // what was looked for without reading this file.
            #expect(
                ApprovedProvenanceFixtureCatalogue.status.description
                    .contains(ApprovedProvenanceFixtureCatalogue.suiteFileName)
            )
            // A comparison that compared nothing has established nothing.
            let empty = ProvenanceFixtureComparisonReport(comparisons: [])
            #expect(empty.outcome == .failed)
            #expect(empty.coveredFamilies.isEmpty)

        case let .present(suite, _):
            let catalogued = Set(
                suite.fixtures.filter(\.family.isProvenanceConditional).map(\.family)
            )
            #expect(Self.requiredFamilies.subtracting(catalogued).isEmpty)

        case let .unreadable(path, reason):
            Issue.record(
                "the approved fixture suite at \(path) is installed but unreadable: \(reason)"
            )
        }
    }

    /// The comparison bites.
    ///
    /// Without this the skipped comparison above could be wired to nothing and nobody would
    /// know. A clearly synthetic suite declares one approved state per family; a stub reader
    /// returns a condition the synthetic policy maps to a *chosen* state; and the harness
    /// has to report agreement where the two coincide and disagreement where they do not,
    /// naming the fixture.
    ///
    /// **Nothing here is an approved expectation.** The declared states are the test's own
    /// arguments, and the assertion is about the harness, not about any fixture.
    @Test("A declared state the adapter does not reach is reported as a disagreement")
    func comparisonReportsDisagreement() async throws {
        let policy = PolicySample.policy()

        // The synthetic policy maps `noManifestFound` onto `absent`. A suite whose fixtures
        // all declare `absent` therefore agrees, and the same suite with one fixture
        // declaring `validated` must disagree at exactly that fixture.
        let agreeing = try SyntheticProvenanceSuite.suite(declaring: .absent)
        let runner = ProvenanceFixtureRunner(
            policy: policy,
            makeReader: { _ in
                StubManifestReader(
                    returning: C2PAReadOutcome(
                        status: .readerCondition(.noManifestFound),
                        binding: .notDetermined
                    )
                )
            },
            loadAsset: { _ in SyntheticContainerBytes.jpeg }
        )

        let agreement = await runner.run(agreeing)
        #expect(agreement.outcome == .passed)
        #expect(agreement.coveredFamilies == Self.requiredFamilies)
        #expect(agreement.comparisons.allSatisfy { $0.observed == .absent })

        let disagreeing = try SyntheticProvenanceSuite.suite(
            declaring: .absent,
            overriding: [.provenanceValidSigned: .validated]
        )
        let disagreement = await runner.run(disagreeing)
        #expect(disagreement.outcome == .failed)
        #expect(disagreement.disagreements.count == 1)
        let reported = try #require(disagreement.disagreements.first)
        #expect(reported.family == .provenanceValidSigned)
        #expect(reported.approved == .validated)
        #expect(reported.observed == .absent)
    }

    /// A fixture whose asset is missing fails; it is never completed from the adapter.
    ///
    /// Task 14.1's governing rule at the level of this comparison: an absent asset is a
    /// failing fixture, not an absent one, and the failure names the path.
    @Test("A missing fixture asset is a failure that names the path")
    func missingAssetIsAFailure() async throws {
        let suite = try SyntheticProvenanceSuite.suite(declaring: .absent)
        let runner = ProvenanceFixtureRunner(
            policy: PolicySample.policy(),
            makeReader: { _ in
                StubManifestReader(
                    returning: C2PAReadOutcome(
                        status: .readerCondition(.noManifestFound),
                        binding: .notDetermined
                    )
                )
            },
            loadAsset: { _ in nil }
        )

        let report = await runner.run(suite)

        #expect(report.outcome == .failed)
        #expect(report.comparisons.count == Self.requiredFamilies.count)
        for comparison in report.comparisons {
            #expect(comparison.observed == nil, "no state may be recorded for absent bytes")
            guard case .assetMissing = comparison.obstruction else {
                Issue.record("expected a missing-asset obstruction, got \(comparison)")
                continue
            }
        }
    }

    /// A Provenance Feasibility Gate finding is carried as a failure, not as a state.
    ///
    /// The adapter's second outcome class reaches the comparison too. A finding cannot be
    /// resolved into an approved state here any more than it can in the adapter.
    @Test("A feasibility finding is a comparison failure rather than a substituted state")
    func feasibilityFindingIsAFailure() async throws {
        let suite = try SyntheticProvenanceSuite.suite(declaring: .absent)
        let runner = ProvenanceFixtureRunner(
            policy: PolicySample.policy(),
            makeReader: { _ in StubManifestReader(failingWith: .validatorNotConfigurable) },
            loadAsset: { _ in SyntheticContainerBytes.jpeg }
        )

        let report = await runner.run(suite)

        #expect(report.outcome == .failed)
        for comparison in report.comparisons {
            #expect(comparison.observed == nil)
            guard case .feasibilityFinding = comparison.obstruction else {
                Issue.record("expected a feasibility-finding obstruction, got \(comparison)")
                continue
            }
        }
    }
}

// MARK: - Offline validation

@Suite("Offline Content Credential validation")
struct OfflineContentCredentialValidationTests {
    /// Requirements 6.7 and 6.8, structurally.
    ///
    /// Neither provenance module may reach a network client. The tokens below are the
    /// surfaces one would need; the settings names the adapter turns *off* are deliberately
    /// not among them, since naming a setting is how it gets disabled.
    @Test("Neither provenance module names a network client")
    func provenanceModulesNameNoNetworkClient() throws {
        for module in ["DefAIkeProvenanceAPI", "DefAIkeProvenanceC2PA"] {
            try expectNoSourceInModule(
                module,
                contains: [
                    "URLSession",
                    "URLRequest",
                    "URLConnection",
                    "URLDownload",
                    "import Network",
                    "NWConnection",
                    "NWEndpoint",
                    "CFNetwork",
                    "CFSocket",
                    "getaddrinfo",
                    "SocketPort",
                    "http://",
                    "https://",
                ]
            )
        }
    }

    /// No network-capable library setting is left running on the library's own default.
    ///
    /// A value-level check on the adapter's own published list of settings it deliberately
    /// does not decide. Every entry there is a Provenance Feasibility Gate review item, and
    /// a *network* setting must never be one of them: leaving one on a default would make
    /// Requirement 6.8 depend on what the vendor happened to choose.
    @Test("No network-capable library setting is left on a library default")
    func networkSettingsAreNotLeftUnreviewed() {
        let networkMarkers = ["network", "ocsp", "remote", "fetch", "host", "url"]
        for setting in C2PALibraryReader.unreviewedLibraryDefaults {
            let lowered = setting.lowercased()
            for marker in networkMarkers {
                #expect(
                    !lowered.contains(marker),
                    "\(setting) is network-capable and must not run on a library default"
                )
            }
        }
        #expect(
            !C2PALibraryReader.unreviewedLibraryDefaults.isEmpty,
            "the reviewed-defaults list must be nonempty for this check to mean anything"
        )
    }

    /// Requirements 6.19 and 6.20: which products may reach the validator module.
    ///
    /// A value-level check on the package manifest, which is where the compositions are
    /// declared. The application composition is the one product that adds the adapter; the
    /// Share Extension composition must not reach it, or `DefAIkeProvenanceAPI`, at all.
    /// `check-module-boundaries.py` enforces the same rule over the whole graph and
    /// `build-ios.sh` compiles the app; this is the test-suite-visible form, so a change to
    /// product membership fails here rather than only in a script.
    ///
    /// The Share Extension assertion carries more weight than it used to. While a pixel-only
    /// application product existed, *it* was the archive-level proof that a DefAIke build
    /// could ship without a Content Credential validator. That product is gone, so the
    /// extension is the only shipping module closure whose exclusion of the validator can
    /// still be measured — which is what keeps the application product's positive membership
    /// a measurement rather than the only observation in the run.
    @Test("Only the application composition product includes the validator module")
    func onlyTheApplicationProductIncludesTheValidatorModule() throws {
        let text = try packageManifestText()

        let app = try #require(
            productDeclaration(named: "DefAIkeAppKit", in: text),
            "the manifest must declare the application composition product"
        )
        #expect(
            app.contains("DefAIkeProvenanceC2PA"),
            "the application composition is the one that adds the validator module"
        )
        #expect(
            app.contains("sharedAppModules"),
            "the application composition is the shared module list plus the adapter"
        )

        #expect(
            productDeclaration(named: "DefAIkePixelOnly", in: text) == nil,
            "the pixel-only composition product was merged into the application composition"
        )

        let shareExtension = try #require(
            productDeclaration(named: "DefAIkeShareExtensionKit", in: text)
        )
        #expect(!shareExtension.contains("DefAIkeProvenanceC2PA"))
        #expect(!shareExtension.contains("DefAIkeProvenanceAPI"))
    }

    /// The reviewed implementation version is the exact-pinned dependency.
    ///
    /// `ProvenanceLaneProvider` compares a policy's declared validator implementation
    /// version against the manifest before enabling a lane, so the constant the adapter
    /// publishes has to be the version the package actually resolves. Read from
    /// `Package.swift` rather than restated, so the two cannot drift.
    @Test("The reviewed validator version is the exact-pinned dependency version")
    func reviewedVersionMatchesThePin() throws {
        let text = try packageManifestText()

        #expect(text.contains("c2pa-swift"), "the manifest must declare the validator package")
        #expect(
            text.contains("exact: \"\(C2PALibraryReader.reviewedImplementationVersion)\""),
            "the manifest must exact-pin \(C2PALibraryReader.reviewedImplementationVersion)"
        )
    }

    /// Requirement 6.8's observable half, through the real library.
    ///
    /// Each accepted container's bytes go through the real `C2PALibraryReader` and the real
    /// `C2PAProvenanceValidator`. The claims are deliberately one-sided:
    ///
    ///   * the inspection *completes* and yields either one enabled state or one
    ///     feasibility finding, with no network reachable from either module; and
    ///   * it never yields `validated`.
    ///
    /// The second is the claim that matters and the only one that can be made without an
    /// approved expectation: these bytes carry no signature, so a `validated` state would be
    /// manufactured. Which of the remaining states the synthetic policy maps the library's
    /// answer onto is not asserted — that mapping is an approved release input.
    ///
    /// Written as a disjunction on purpose, so it keeps holding once the approved trust
    /// store lands and the library's reading path becomes reachable. What that path does
    /// *today*, with no approved anchors, is pinned separately by
    /// `realLibraryReportsNoStateWithoutApprovedTrustAnchors`.
    @Test(
        "The real validator completes offline and never manufactures a validated state",
        arguments: SyntheticContainerBytes.recognized.map(\.name)
    )
    func realValidatorNeverManufacturesValidated(container name: String) async throws {
        let sample = try #require(
            SyntheticContainerBytes.recognized.first { $0.name == name }
        )
        let (validator, asset, digest) = await RealByteInspection.validator(
            policy: PolicySample.policy(),
            reader: C2PALibraryReader(),
            bytes: sample.bytes
        )

        // The request the adapter derives describes exactly these bytes.
        let request = ProvenanceInspectionRequest(asset: asset, policy: validator.policy)
        #expect(request.inspectsExactly(byteCount: UInt64(sample.bytes.count), sha256: digest))

        // Exactly one of the two outcome classes, and the state class is constrained.
        // A feasibility finding is the legitimate second outcome and is *not* resolved
        // into a state here, so it is recorded rather than asserted about: which findings
        // the reviewed library reaches over unsigned bytes is Provenance Feasibility Gate
        // evidence, not something this file may fix in advance.
        var producedState: ProvenanceCategory?
        var producedFinding: ProvenanceFeasibilityFinding?
        do {
            producedState = try await validator.inspect(asset).category
        } catch {
            // `inspect` throws exactly `ProvenanceFeasibilityFinding`, so no cast is needed
            // and none is written: a cast here would compile away and assert nothing.
            producedFinding = error
        }

        #expect(
            (producedState == nil) != (producedFinding == nil),
            "an inspection produces exactly one state or exactly one finding"
        )
        #expect(
            producedState != .validated,
            "bytes carrying no signature must never reach the validated state"
        )
    }

    /// Without the approved trust anchors, the real library reports no state at all.
    ///
    /// This is the honest boundary of what a host run can establish today, and it is worth
    /// pinning rather than papering over. The synthetic anchor bytes in `TrustSample` are the
    /// string `synthetic-test-anchors`; they are not a certificate, and the reviewed library
    /// refuses to be configured with them. The adapter therefore reports
    /// ``ProvenanceFeasibilityFinding/validatorNotConfigurable`` and never a state, which is
    /// exactly the fail-closed direction the adapter documents: an unconfigured validator has
    /// not evaluated the approved trust store, so no answer it gives describes the policy
    /// that was supposed to be in force.
    ///
    /// **Recorded consequence:** the library's manifest-*reading* path is unreachable from
    /// this target until the approved offline trust store artifact is installed. So the
    /// runtime half of Requirements 6.7 and 6.8 past configuration is not established here;
    /// it is established by `approvedFixturesReachTheirApprovedState`, which is skipped while
    /// the approved artifacts are absent. Nothing in this file substitutes for that.
    ///
    /// If a future validator version accepted arbitrary anchor bytes, this test would fail —
    /// correctly. Silently accepting an unapproved trust store is a behavior change that has
    /// to be seen rather than absorbed.
    @Test(
        "Without approved trust anchors the real library reports no state at all",
        arguments: SyntheticContainerBytes.recognized.map(\.name)
    )
    func realLibraryReportsNoStateWithoutApprovedTrustAnchors(
        container name: String
    ) async throws {
        let sample = try #require(
            SyntheticContainerBytes.recognized.first { $0.name == name }
        )
        #expect(
            C2PAContainerSignature.container(of: sample.bytes) == sample.container,
            "the container has to be recognized, or this asserts nothing about configuration"
        )

        let (validator, asset, _) = await RealByteInspection.validator(
            policy: PolicySample.policy(),
            reader: C2PALibraryReader(),
            bytes: sample.bytes
        )

        let finding = await capturedFinding { try await validator.inspect(asset) }
        #expect(finding == .validatorNotConfigurable)
    }

    /// A container the adapter does not recognize never reaches the library.
    ///
    /// Pure adapter logic, so it is deterministic and needs no approved input: the container
    /// table yields nothing, and the real reader reports the structural condition rather
    /// than guessing a format or handing unknown bytes to a parser. Note that this outcome
    /// is produced *before* the configuration step, which is why it is reachable while
    /// `realLibraryReportsNoStateWithoutApprovedTrustAnchors` is not.
    @Test("An unrecognized container is refused before the library is reached")
    func unrecognizedContainerNeverReachesTheLibrary() throws {
        #expect(C2PAContainerSignature.container(of: SyntheticContainerBytes.unrecognized) == nil)

        let outcome = try C2PALibraryReader().read(
            exactBytes: SyntheticContainerBytes.unrecognized,
            limits: PolicySample.policy().processingLimits,
            trust: TrustSample.material(for: PolicySample.policy())
        )

        #expect(outcome.status == .readerCondition(.containerNotSupported))
        #expect(outcome.binding == .notDetermined)
        #expect(outcome.manifestByteCount == nil)
        #expect(outcome.signerDetails.isEmpty)
        #expect(outcome.assertionLabels.isEmpty)
    }

    /// The package manifest's text, read from this file's own location.
    private func packageManifestText() throws -> String {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        return try String(contentsOf: manifest, encoding: .utf8)
    }

    /// The text of one `.library(name: "<name>", targets: …)` declaration, or `nil`.
    ///
    /// A deliberately narrow scan: from the product's name to the closing bracket of its
    /// target list. Returning `nil` rather than an empty string when the product is absent is
    /// what makes a renamed or removed product a failure instead of a vacuous pass.
    private func productDeclaration(named name: String, in manifest: String) -> String? {
        guard let nameRange = manifest.range(of: "name: \"\(name)\"") else { return nil }
        let remainder = manifest[nameRange.upperBound...]
        guard let targetsStart = remainder.range(of: "targets:") else { return nil }
        let afterTargets = remainder[targetsStart.upperBound...]
        guard let terminator = afterTargets.firstIndex(where: { $0 == ")" }) else { return nil }
        return String(afterTargets[..<terminator])
    }

    /// Fails if any Swift file in `module` contains any of `forbidden`.
    ///
    /// The enumeration is itself checked. A scan that silently covered nothing, or covered a
    /// module's top level while a later change put a file in a subdirectory, would pass
    /// while asserting nothing, so the module's own file list has to come back nonempty and
    /// has to include the file that carries the vendor API.
    private func expectNoSourceInModule(
        _ module: String,
        contains forbidden: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent(module)
        let enumerator = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil),
            "the sources of \(module) must be enumerable for this to mean anything",
            sourceLocation: sourceLocation
        )
        let files = enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "the scan of \(module) must cover files", sourceLocation: sourceLocation)
        if module == "DefAIkeProvenanceC2PA" {
            #expect(
                files.contains { $0.lastPathComponent == "C2PALibraryReader.swift" },
                "the scan must cover the one file that imports the validator",
                sourceLocation: sourceLocation
            )
        }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                #expect(
                    !text.contains(token),
                    "\(module)/\(file.lastPathComponent) must not reference \(token)",
                    sourceLocation: sourceLocation
                )
            }
        }
    }
}

// MARK: - Exact bytes, bounded display, and the byte-status limitation

@Suite("Exact retained bytes and bounded provenance display")
struct RetainedByteAndDisplayIntegrationTests {
    /// Requirement 6.6, against a true digest.
    ///
    /// The existing adapter suite proves a truncated or mismeasured object is refused, using
    /// placeholder digests. What is added here is the identity claim those cannot make: the
    /// bytes the validator receives are byte-for-byte the retained object, and their real
    /// SHA-256 is the digest the request carries.
    @Test("The validator receives exactly the retained bytes, by count and by true digest")
    func validatorReceivesTheRetainedBytesWithATrueDigest() async throws {
        let reader = StubManifestReader(
            returning: C2PAReadOutcome(
                status: .readerCondition(.noManifestFound),
                binding: .notDetermined
            )
        )
        let bytes = SyntheticContainerBytes.jpeg
        let (validator, asset, digest) = await RealByteInspection.validator(
            policy: PolicySample.policy(),
            reader: reader,
            bytes: bytes
        )

        _ = try await validator.inspect(asset)

        let received = try #require(reader.lastReadBytes)
        #expect(received == bytes, "the inspected bytes must be the retained bytes")
        #expect(TrueDigest.of(received) == digest, "and must digest to the recorded digest")
        #expect(UInt64(received.count) == asset.byteCount)
        #expect(asset.sha256 == digest)
    }

    /// The byte-preservation status travels with the inspection and does not move the state.
    ///
    /// Requirement 6.15 makes a transformed or unknown status add a required presentation
    /// limitation, and Requirement 13.11 compares that limitation against an approved
    /// result. The half that belongs in this module is the one asserted here: the status
    /// reaches the inspection unchanged, and the evidence state is the same for all three
    /// statuses. If a transformed status quietly changed the state, the limitation would be
    /// describing a different finding than the one produced.
    ///
    /// Displaying the limitation is the Result Presenter's duty and belongs to task 11.3.
    @Test(
        "Byte-preservation status reaches the inspection and does not change the state",
        arguments: [
            (
                BytePreservationStatus.originalBytes,
                PreservationBasis.providerDeclaredOriginalRepresentation
            ),
            (
                BytePreservationStatus.platformTransformedCopy,
                PreservationBasis.providerDeclaredTransformedRepresentation
            ),
            (
                BytePreservationStatus.unknown,
                PreservationBasis.preservationHistoryNotEstablished
            ),
        ]
    )
    func preservationStatusTravelsWithoutChangingTheState(
        status: BytePreservationStatus,
        basis: PreservationBasis
    ) async throws {
        let policy = PolicySample.policy()
        let bytes = SyntheticContainerBytes.jpeg
        let digest = TrueDigest.of(bytes)
        let asset = RealByteInspection.asset(
            session: "session.\(status.statusKey.rawValue)",
            storage: "object.\(status.statusKey.rawValue)",
            byteCount: UInt64(bytes.count),
            digest: digest,
            preservation: status,
            basis: basis
        )
        let store = StubFinalizedObjectStore()
        await store.store(
            key: asset.handle.storageKey,
            session: asset.sessionID,
            bytes: bytes,
            declaredDigest: digest
        )
        let validator = C2PAProvenanceValidator(
            store: store,
            reader: StubManifestReader(
                returning: C2PAReadOutcome(
                    status: .readerCondition(.noManifestFound),
                    binding: .notDetermined
                )
            ),
            clock: SteppingClock(step: .milliseconds(1)),
            configuration: TrustSample.configuration(for: policy)
        )

        let request = ProvenanceInspectionRequest(asset: asset, policy: policy)
        #expect(request.preservationStatus == status)

        // The same read condition under every preservation status: the state follows the
        // signed mapping, not the byte history.
        #expect(try await validator.inspect(asset) == .absent)
    }

    /// The approved copy a transformed-byte limitation and a screenshot explanation need
    /// exists in a provenance-enabled build.
    ///
    /// Requirements 6.15 and 6.16 are presentation duties, and this is the precondition they
    /// rest on: the surfaces are in the closed copy vocabulary and a catalogue approves a
    /// key for each. Nothing about the *wording* is asserted — that is unresolved approved
    /// copy — and nothing here renders anything.
    ///
    /// The absent state is the one a screenshot with no Content Credential reaches, and it
    /// carries no payload at all, so the explanation cannot come from the evidence value. It
    /// has to come from approved copy, which is exactly why the key has to exist.
    @Test("Approved copy exists for every byte-status limitation and for the screenshot case")
    func approvedCopyCoversTheRequiredProvenanceLimitations() throws {
        let catalog = CopySample.catalog()

        for status in BytePreservationStatusKey.allCases {
            #expect(
                catalog.localizationKey(for: .bytePreservationLimitation(status)) != nil,
                "a \(status.rawValue) byte status needs approved limitation copy"
            )
        }
        #expect(catalog.localizationKey(for: .screenshotProvenanceExplanation) != nil)

        // The absent state carries nothing an explanation could be built from: it is the
        // one enabled state with no payload at all, so the screenshot explanation has to be
        // approved copy rather than something projected from the evidence.
        let evidence = ProvenanceEvidence.absent
        #expect(evidence.stateKey == .absent)
        #expect(evidence == .absent)
    }

    /// A detail that is not display-safe is refused end to end, not shown and not dropped.
    ///
    /// The general claim — every displayed field is bounded, allowlisted, and display-safe
    /// for any generated outcome — is Property 20's third arm. This is the one end-to-end
    /// example through the real adapter, which that file cannot reach: a hostile signer
    /// field arriving from a read becomes a named feasibility finding rather than a
    /// validated credential with a silently missing row.
    @Test("An unsafe signer detail becomes a named finding rather than a displayed field")
    func unsafeDetailIsANamedFindingEndToEnd() async throws {
        let (validator, _, asset) = await InspectionSample.validator(
            policy: PolicySample.policy(),
            outcome: C2PAReadOutcome(
                status: .readerCondition(.allChecksPassed),
                binding: .boundToInspectedBytes,
                signerDetails: [
                    // A right-to-left override inside an otherwise ordinary signer name.
                    C2PARawDetail(field: .signerIdentity, rawValue: "CN=Ex\u{202E}ample")
                ]
            )
        )

        let finding = await capturedFinding { try await validator.inspect(asset) }
        #expect(finding == .validatorDetailNotDisplaySafe(field: .signerIdentity))
    }

    /// Only allowlisted fields survive the whole chain, in the policy's field order.
    ///
    /// One end-to-end example beside Property 20's generated form: a read reporting three
    /// signer fields under a policy that permits two produces exactly the two, and the
    /// permitted-but-unreported field contributes nothing.
    @Test("Only fields the policy permits reach the validated state, in fixed field order")
    func onlyAllowlistedFieldsReachTheState() async throws {
        let policy = PolicySample.policy(
            displayableFields: [.signerIdentity, .claimGenerator]
        )
        let (validator, _, asset) = await InspectionSample.validator(
            policy: policy,
            outcome: C2PAReadOutcome(
                status: .readerCondition(.allChecksPassed),
                binding: .boundToInspectedBytes,
                signerDetails: [
                    C2PARawDetail(field: .claimGenerator, rawValue: "Example Generator/1.0"),
                    C2PARawDetail(field: .signerIdentity, rawValue: "CN=Example Signer"),
                    C2PARawDetail(field: .validationTime, rawValue: "recorded"),
                ],
                assertionLabels: ["c2pa.actions"]
            )
        )

        let evidence = try await validator.inspect(asset)

        guard case let .validated(summary) = evidence else {
            Issue.record("expected the validated state, got \(evidence.category)")
            return
        }
        // Field order follows `ProvenanceDisplayField.allCases`, not the read order.
        #expect(summary.signerFields.map(\.value.rawValue) == [
            "CN=Example Signer", "Example Generator/1.0",
        ])
        #expect(
            summary.signerFields.allSatisfy {
                $0.value.rawValue.count <= DisplaySafeText.maximumCharacterCount
            }
        )
        // The policy does not permit assertion labels here, so none is displayed.
        #expect(summary.assertionFields.isEmpty)
    }
}

// MARK: - Synthetic suites

/// A clearly synthetic provenance fixture suite, for proving the comparison harness works.
///
/// **Nothing here is an approved fixture.** The identifiers, digests, byte counts, asset
/// paths, and declared states are the tests' own arguments. They exist only so the harness
/// can be exercised while the approved artifacts are absent, and no test claims any of them
/// is a correct expected result.
enum SyntheticProvenanceSuite {
    /// One synthetic fixture per provenance family.
    ///
    /// Every fixture declares `declared` as its provenance state, except the families named
    /// in `overriding`, which declare their own. That is what lets one test show agreement
    /// and disagreement against the same reader.
    static func suite(
        declaring declared: ProvenanceStateKey,
        overriding overrides: [FixtureFamily: ProvenanceStateKey] = [:]
    ) throws -> ReleaseFixtureSuite {
        let families = FixtureFamily.provenanceFamilies.sorted { $0.rawValue < $1.rawValue }
        let fixtures = try families.map { family in
            try FixtureRecord(
                id: fixtureID(for: family),
                family: family,
                assetPath: assetPath(for: family),
                contentDigest: Sample.digest("e"),
                byteCount: try PositiveByteCount(validating: 64),
                source: Sample.evidence("evidence.synthetic-fixture"),
                expectations: [.provenanceState(overrides[family] ?? declared)]
            )
        }
        return try ReleaseFixtureSuite(
            id: Sample.artifact("suite.synthetic"),
            schemaVersion: .v1,
            provenanceApplicability: .applicable,
            fixtures: fixtures
        )
    }

    private static func fixtureID(for family: FixtureFamily) -> FixtureID {
        guard let id = FixtureID("fixture.synthetic.\(family.rawValue)") else {
            preconditionFailure("the synthetic fixture identifier must be canonical")
        }
        return id
    }

    private static func assetPath(for family: FixtureFamily) -> CanonicalRelativePath {
        guard let path = CanonicalRelativePath("synthetic/\(family.rawValue).jpg") else {
            preconditionFailure("the synthetic fixture asset path must be canonical")
        }
        return path
    }
}
