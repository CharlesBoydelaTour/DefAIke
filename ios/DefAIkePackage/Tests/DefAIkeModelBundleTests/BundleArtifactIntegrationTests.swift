import Foundation
import Testing

@testable import DefAIkeDomain
@testable import DefAIkeModelBundle

// Task 6.11, Model Bundle half: altered artifacts, missing self-tests, wrong compatibility,
// and corrupt models driven through the **whole** local verification path, plus the real
// immutable model weight blob when one is installed.
//
// **Nothing in this file is release evidence.** Every policy, key, digest, identifier, and
// fixture assembled below is synthetic and labelled as such, no real signature cryptography
// runs anywhere, and every run happens on a development host. Requirements 4.13 and 13.6
// through 13.9 are Device Validation Suite gates on an approved physical iPhone under an
// approved Device Validation Plan; a host pass satisfies none of them and none is claimed.
//
// # What this adds over the tests already in this target
//
// The verifier-level suites — `ManifestSignatureVerificationTests`,
// `ArtifactTreeVerificationTests`, `ModelIdentityAndCompatibilityTests`,
// `ReleaseSelfTestVerificationTests` — each call one verifier in isolation and assert which
// finding it produces. `ActivationAndRollbackTests` drives the activator, but only for an
// integrity failure inside the compiled-model tree, a weight-digest failure, and a self-test
// failure. Task 6.6's Property 2 quantifies sole-model identity over generated catalogs.
//
// What none of them says is what the *rest* of the tamper families cost end to end. That is
// what the table below asserts: for each one-thing-changed candidate, driven through
// `ModelBundleActivator.activate`, the exact finding, **and** that nothing became active,
// **and** that the record store was never asked for anything, **and** that no self-test case
// ever ran. A refusal that still wrote a receipt or still executed a fixture would pass every
// verifier-level test in this target and fail here.
//
// # The weight blob, and what changed
//
// Requirement 10.4 pins the model weight-blob SHA-256, so no *assembled* candidate can pass
// the weight measurement: `CompatibilityDoubles.swift` and `ActivationDoubles.swift` both
// record that an otherwise perfect synthetic candidate stops at
// `.modelWeightDigestMismatch`, and that refusal is this project's "every earlier check
// passed" signal. The compatibility verifier measures the weight blob **last**, after every
// declarative check and after the self-test artifacts resolve, so that reading is sound.
//
// It is also, until now, a ceiling. This file lifts it when the real blob is installed:
// ``RealModelWeightBlob`` locates the immutable artifact, and
// ``realWeightBlobPassesEveryCheckAndActivates`` assembles a candidate around **the real
// bytes** and requires the complete path — integrity, compatibility including the weight
// measurement, the offline self-test run, the receipt, and the atomic commit — to admit it.
// The expected digest is the production constant `RequiredPixelModel.identity`
// `.requiredWeightDigest`; the measured one comes from streaming real bytes through the real
// verifier. **No digest is fabricated**, here or anywhere below.
//
// The blob is not committed: `data/` is excluded by the repository's `.gitignore`, so a fresh
// clone has none. Those tests are therefore **skipped, with the reason visible in the run**,
// and ``absentRealWeightBlobIsRecorded`` runs in both worlds and pins the documented terminal.
//
// # The signature stand-in, stated plainly
//
// `FakeSignatureVerifier` is not cryptography: its "signature" is
// `sha256(keyMaterial || message)`. That makes a signature check byte-sensitive, which is all
// the verifier-level tests need, but it is **not** a signature scheme and there are **no
// approved known-answer vectors** in this repository for one.
// ``signatureStandInIsNotASignatureScheme`` demonstrates the gap rather than asserting it,
// and ``absentSignatureKnownAnswerVectorsAreRecorded`` records it against Requirements 10.6
// and 10.8. Nothing below claims a signature algorithm was exercised.

// MARK: - The real weight blob

/// Whether the immutable model weight blob is installed, and where it was looked for.
///
/// Deliberately not a `Bool`: a reader of a skipped run needs the searched paths, and an
/// audit needs the absence to be a recorded value rather than an inference from a test that
/// did not execute.
enum RealWeightBlobStatus: Equatable, CustomStringConvertible {
    /// No weight blob was found. Carries every location that was searched, in order.
    case absent(searchedPaths: [String])

    /// A weight blob is installed at this path.
    case present(path: String, byteCount: Int)

    /// The blob is installed but could not be read. A failure, never an absence.
    case unreadable(path: String, reason: String)

    var description: String {
        switch self {
        case let .absent(paths):
            "no model weight blob at: \(paths.joined(separator: ", "))"
        case let .present(path, byteCount):
            "model weight blob at \(path) (\(byteCount) bytes)"
        case let .unreadable(path, reason):
            "the model weight blob at \(path) could not be read: \(reason)"
        }
    }
}

/// Locates the immutable model weight blob, read-only.
///
/// Two search locations, in order, and nothing else:
///
///   1. the path in `DEFAIKE_MODEL_WEIGHT_BLOB`, for a runner that installs the artifact
///      outside the working tree; then
///   2. `data/coreml/commfor-lowq-384.mlmodelc/weights/weight.bin` inside the repository,
///      which is where the conversion tooling writes it and which `.gitignore` keeps out of
///      version control.
///
/// There is no third location, no bundled default, and no writer. A checkout that has not
/// been given the blob cannot obtain one here, which is what keeps a missing artifact a
/// reported absence rather than a fabricated digest.
enum RealModelWeightBlob {
    static let repositoryRelativePath =
        "data/coreml/commfor-lowq-384.mlmodelc/weights/weight.bin"

    static let environmentKey = "DEFAIKE_MODEL_WEIGHT_BLOB"

    /// Read once per process. Tens of megabytes, so this is deliberately not re-read per
    /// test.
    static let bytes: [UInt8]? = load()

    static let status: RealWeightBlobStatus = resolve()

    /// Whether the blob is installed, for a test's `.enabled(if:)` trait.
    static var isPresent: Bool {
        if case .present = status { return true }
        return false
    }

    /// Every location that was searched, in search order.
    static var searchedPaths: [String] {
        var paths: [String] = []
        if let installed = ProcessInfo.processInfo.environment[environmentKey] {
            paths.append(installed)
        }
        paths.append(repositoryBlobURL.path)
        return paths
    }

    /// Derived from this file's own path so it does not depend on a working directory: five
    /// levels up from `Tests/DefAIkeModelBundleTests/<file>` is the repository root.
    private static var repositoryBlobURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(repositoryRelativePath)
    }

    private static func resolve() -> RealWeightBlobStatus {
        for path in searchedPaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                return .present(path: path, byteCount: data.count)
            } catch {
                return .unreadable(path: path, reason: "\(error)")
            }
        }
        return .absent(searchedPaths: searchedPaths)
    }

    private static func load() -> [UInt8]? {
        for path in searchedPaths {
            guard FileManager.default.fileExists(atPath: path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            else {
                continue
            }
            return Array(data)
        }
        return nil
    }
}

// MARK: - The approved signature known-answer vectors

/// Whether approved signature known-answer vectors are installed, and where they were sought.
enum ApprovedSignatureVectorStatus: Equatable, CustomStringConvertible {
    case absent(searchedPaths: [String])
    case present(path: String)

    var description: String {
        switch self {
        case let .absent(paths):
            "no approved signature known-answer vectors at: \(paths.joined(separator: ", "))"
        case let .present(path):
            "approved signature known-answer vectors at \(path)"
        }
    }
}

/// Locates approved signature known-answer vectors, read-only.
///
/// Same search discipline as every other approved artifact in this package: an environment
/// override for a runner that installs artifacts outside the working tree, then
/// `ios/ApprovedFixtures/`. There is no bundled default and no writer, so a build that has
/// not been given approved vectors cannot obtain any — which is what keeps the absence a
/// reported gap instead of a stand-in wearing the name of a real algorithm.
enum ApprovedSignatureKnownAnswerVectors {
    static let fileName = "signature-known-answer-vectors.json"
    static let environmentKey = "DEFAIKE_APPROVED_FIXTURE_DIRECTORY"

    static let status: ApprovedSignatureVectorStatus = resolve()

    static var isPresent: Bool {
        if case .present = status { return true }
        return false
    }

    static var searchedPaths: [String] {
        var paths: [String] = []
        if let installed = ProcessInfo.processInfo.environment[environmentKey] {
            paths.append(URL(fileURLWithPath: installed).appendingPathComponent(fileName).path)
        }
        paths.append(repositoryDirectory.appendingPathComponent(fileName).path)
        return paths
    }

    private static var repositoryDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ApprovedFixtures")
    }

    private static func resolve() -> ApprovedSignatureVectorStatus {
        for path in searchedPaths where FileManager.default.fileExists(atPath: path) {
            return .present(path: path)
        }
        return .absent(searchedPaths: searchedPaths)
    }
}

// MARK: - One-thing-changed candidates

/// One tamper or incompatibility, applied to an otherwise structurally valid candidate.
///
/// Grouped by the four families task 6.11 names. Each case changes exactly one thing, so the
/// finding it produces names one cause.
enum BundleTamper: String, Hashable, Sendable, CaseIterable, CustomStringConvertible {
    // Altered artifacts.
    case signedManifestFieldRewritten = "signed-manifest-field-rewritten"
    case detachedSignatureAltered = "detached-signature-altered"
    case selfTestSpecificationBytesAltered = "self-test-specification-bytes-altered"
    case fixtureCatalogBytesAltered = "fixture-catalog-bytes-altered"
    case undeclaredArtifactAdded = "undeclared-artifact-added"

    // Missing or unresolvable release self-tests.
    case selfTestFixtureAssetRemoved = "self-test-fixture-asset-removed"
    case selfTestFixtureNotCatalogued = "self-test-fixture-not-catalogued"
    case selfTestFixtureBytesDisagreeWithCatalogue = "self-test-fixture-bytes-disagree"

    // Wrong compatibility.
    case applicationBuildNotListed = "application-build-not-listed"
    case operatingSystemBelowBundleMinimum = "operating-system-below-bundle-minimum"
    case requiredCapabilityNotCompiled = "required-capability-not-compiled"
    case boundComponentVersionWrong = "bound-component-version-wrong"

    // Corrupt models.
    case weightBlobAbsentFromTree = "weight-blob-absent-from-tree"

    var description: String { rawValue }

    /// Which of the four families this tamper belongs to, so a run reports coverage of all
    /// four rather than of whichever cases happened to be listed.
    var family: String {
        switch self {
        case .signedManifestFieldRewritten, .detachedSignatureAltered,
             .selfTestSpecificationBytesAltered, .fixtureCatalogBytesAltered,
             .undeclaredArtifactAdded:
            "altered-artifact"
        case .selfTestFixtureAssetRemoved, .selfTestFixtureNotCatalogued,
             .selfTestFixtureBytesDisagreeWithCatalogue:
            "missing-self-test"
        case .applicationBuildNotListed, .operatingSystemBelowBundleMinimum,
             .requiredCapabilityNotCompiled, .boundComponentVersionWrong:
            "wrong-compatibility"
        case .weightBlobAbsentFromTree:
            "corrupt-model"
        }
    }
}

/// One assembled candidate plus the finding the whole path must produce for it.
struct TamperedCandidate {
    var candidate: CompatibleCandidate
    var expectedFinding: ModelBundleVerificationError
}

/// Assembles the tampered candidates and the harness that drives them.
///
/// Everything here is synthetic. The one non-synthetic input the assembler can be given is
/// the real weight blob, and that arrives through ``RealModelWeightBlob`` rather than being
/// constructed.
enum BundleIntegrationScenario {
    /// The path a byte-level alteration targets inside the compiled-model tree.
    static let coreMLDataPath = "\(CompatibleBundleAssembler.modelTreePath)/coremldata.bin"

    /// The catalogued fixture asset path a case resolves to.
    static let fixtureAssetPath = "\(CompatibleBundleAssembler.fixtureRootPath)/sample.jpg"

    /// The path an undeclared artifact is added at. Under the declared `artifacts/`
    /// container but inside no declared artifact, which is exactly what "present but not
    /// declared" means.
    static let undeclaredPath = "\(CompatibleBundleAssembler.artifactsRoot)/extra.bin"

    /// A structurally valid candidate carrying `blob` as its model weight blob.
    ///
    /// `treeOverrides` runs before the manifest's digest records are computed, so the
    /// declared model-tree digest covers the substituted bytes and the integrity step still
    /// passes. That is what makes the weight measurement the only thing the substitution
    /// changes.
    static func candidate(weightBlob blob: [UInt8]) throws -> CompatibleCandidate {
        try CompatibleBundleAssembler.standard(
            treeOverrides: { tree in
                tree.removeEntry(CompatibleBundleAssembler.weightBlobPath)
                tree.addFile(CompatibleBundleAssembler.weightBlobPath, bytes: blob)
            }
        )
    }

    /// One tampered candidate and the finding it must produce.
    static func tampered(_ tamper: BundleTamper) throws -> TamperedCandidate {
        switch tamper {
        case .signedManifestFieldRewritten:
            var candidate = try CompatibleBundleAssembler.standard()
            // A signed component version rewritten in place: schema-valid, same length, and
            // not what was signed. The signature is not regenerated, which is the point.
            let rewritten = String(
                decoding: candidate.integrity.manifestBytes,
                as: UTF8.self
            )
            .replacingOccurrences(of: "\"policy.calibration\"", with: "\"policy.calibrat10n\"")
            let bytes = Array(rewritten.utf8)
            guard bytes.count == candidate.integrity.manifestBytes.count,
                  bytes != candidate.integrity.manifestBytes
            else {
                throw TamperNotApplicable.manifestFieldNotFound("policy.calibration")
            }
            candidate.integrity.tree.overwriteContent(
                ModelBundleManifest.manifestFileName,
                bytes: bytes
            )
            return TamperedCandidate(
                candidate: candidate,
                expectedFinding: .manifestSignatureDidNotVerify(key: Sample.signingKey())
            )

        case .detachedSignatureAltered:
            var candidate = try CompatibleBundleAssembler.standard()
            guard var signature = candidate.integrity.tree
                .fileBytes[ModelBundleManifest.signatureFileName], !signature.isEmpty
            else {
                throw TamperNotApplicable.fileNotFound(ModelBundleManifest.signatureFileName)
            }
            signature[0] ^= 0xFF
            candidate.integrity.tree.overwriteContent(
                ModelBundleManifest.signatureFileName,
                bytes: signature
            )
            return TamperedCandidate(
                candidate: candidate,
                expectedFinding: .manifestSignatureDidNotVerify(key: Sample.signingKey())
            )

        case .selfTestSpecificationBytesAltered:
            return try TamperedCandidate(
                candidate: byteAltered(CompatibleBundleAssembler.selfTestsPath),
                expectedFinding: .artifactDigestMismatch(
                    Sample.path(CompatibleBundleAssembler.selfTestsPath)
                )
            )

        case .fixtureCatalogBytesAltered:
            return try TamperedCandidate(
                candidate: byteAltered(CompatibleBundleAssembler.fixtureCatalogPath),
                expectedFinding: .artifactDigestMismatch(
                    Sample.path(CompatibleBundleAssembler.fixtureCatalogPath)
                )
            )

        case .undeclaredArtifactAdded:
            let candidate = try CompatibleBundleAssembler.standard(
                treeOverrides: { $0.addFile(undeclaredPath, text: "not-declared") }
            )
            return TamperedCandidate(
                candidate: candidate,
                expectedFinding: .undeclaredTreeEntry(Sample.path(undeclaredPath))
            )

        case .selfTestFixtureAssetRemoved:
            // The catalogued asset is gone, and another file takes its place under the
            // declared fixture root so the declared tree is neither empty nor
            // digest-mismatched. The only thing changed is that the fixture a case needs is
            // not there (Requirement 10.10).
            let candidate = try CompatibleBundleAssembler.standard(
                treeOverrides: { tree in
                    tree.removeEntry(fixtureAssetPath)
                    tree.addFile(
                        "\(CompatibleBundleAssembler.fixtureRootPath)/other.jpg",
                        text: "some-other-asset"
                    )
                }
            )
            return TamperedCandidate(
                candidate: candidate,
                expectedFinding: .selfTestFixtureAssetMissing(
                    fixture: Sample.fixtureID(),
                    path: Sample.path(fixtureAssetPath)
                )
            )

        case .selfTestFixtureNotCatalogued:
            // A catalogue carrying the identifier the specification names as its suite, but
            // not the fixture the case names. The bytes on disk are untouched: the case's
            // fixture is simply unresolvable.
            let stranger = SampleSelfTest(fixtureID: "fixture.stranger")
            let substitute = try ReleaseFixtureSuite(
                id: Sample.artifact("suite.fixtures"),
                schemaVersion: .v1,
                provenanceApplicability: .notApplicable(decision: Sample.approval()),
                fixtures: [try stranger.catalogueEntry()]
            )
            let candidate = try CompatibleBundleAssembler.standard(
                catalogOverride: try CompatibleBundleAssembler.encode(substitute)
            )
            return TamperedCandidate(
                candidate: candidate,
                expectedFinding: .selfTestFixtureNotCatalogued(
                    case: Sample.selfTestCaseID(),
                    fixture: Sample.fixtureID()
                )
            )

        case .selfTestFixtureBytesDisagreeWithCatalogue:
            // The catalogue declares a digest the asset's bytes do not produce, so the
            // fixture on disk is not the one the expected results were approved against.
            // The byte count still agrees, so only re-digesting can catch it.
            let candidate = try CompatibleBundleAssembler.standard(
                selfTests: [SampleSelfTest(declaredDigest: Sample.digest("9"))]
            )
            return TamperedCandidate(
                candidate: candidate,
                expectedFinding: .selfTestFixtureDigestMismatch(Sample.fixtureID())
            )

        case .applicationBuildNotListed:
            let candidate = try CompatibleBundleAssembler.standard(
                compatibleAppBuilds: [Sample.appBuild("build.other")]
            )
            return TamperedCandidate(
                candidate: candidate,
                expectedFinding: .appBuildNotCompatible(Sample.appBuild())
            )

        case .operatingSystemBelowBundleMinimum:
            let required = try PlatformVersion(validating: "18.0.0")
            let candidate = try CompatibleBundleAssembler.standard(
                bundleMinimumOS: required,
                contextOSVersion: .iOS17
            )
            return TamperedCandidate(
                candidate: candidate,
                expectedFinding: .operatingSystemBelowBundleMinimum(
                    required: required,
                    running: .iOS17
                )
            )

        case .requiredCapabilityNotCompiled:
            let candidate = try CompatibleBundleAssembler.standard(
                requiredCapabilities: [.pixelAnalysis, .contentCredentialValidation],
                contextCapabilities: [.pixelAnalysis]
            )
            return TamperedCandidate(
                candidate: candidate,
                expectedFinding: .requiredCapabilitiesNotCompiled(
                    [.contentCredentialValidation]
                )
            )

        case .boundComponentVersionWrong:
            let candidate = try CompatibleBundleAssembler.standard(
                componentVersions: Sample.compatibleComponentVersions(
                    preprocessing: "contract.other"
                )
            )
            return TamperedCandidate(
                candidate: candidate,
                expectedFinding: .componentVersionIncompatible(
                    component: .preprocessingContract,
                    expected: Sample.artifact("contract.preprocessing"),
                    found: Sample.artifact("contract.other")
                )
            )

        case .weightBlobAbsentFromTree:
            let candidate = try CompatibleBundleAssembler.standard(omitWeightBlob: true)
            return TamperedCandidate(
                candidate: candidate,
                expectedFinding: .modelWeightBlobNotFound(candidate.layout.modelWeightBlob)
            )
        }
    }

    /// A candidate whose file at `path` was rewritten to the same length after assembly, so
    /// its declared digest no longer covers its bytes.
    private static func byteAltered(_ path: String) throws -> CompatibleCandidate {
        var candidate = try CompatibleBundleAssembler.standard()
        guard var bytes = candidate.integrity.tree.fileBytes[path], !bytes.isEmpty else {
            throw TamperNotApplicable.fileNotFound(path)
        }
        bytes[bytes.count - 1] ^= 0x01
        candidate.integrity.tree.overwriteContent(path, bytes: bytes)
        return candidate
    }

    /// Why a tamper could not be applied at all.
    ///
    /// A thrown error rather than a silently skipped arm: an assembler change that moved a
    /// path or a field must fail the test rather than quietly stop exercising a family.
    enum TamperNotApplicable: Error, CustomStringConvertible {
        case fileNotFound(String)
        case manifestFieldNotFound(String)

        var description: String {
            switch self {
            case let .fileNotFound(path): "the assembled candidate has no file at \(path)"
            case let .manifestFieldNotFound(field):
                "the assembled manifest carries no rewritable \(field) field"
            }
        }
    }
}

/// The real activator over one candidate, with every observation point a refusal has to
/// leave untouched.
struct BundleIntegrationHarness {
    let bundleID: ModelBundleID
    let candidate: CompatibleCandidate
    let content: MultiBundleContentStore
    let readLog: BundleReadLog
    let store: FakeActivationRecordStore
    let executor: FakeSelfTestExecutor
    let activator: ModelBundleActivator
    let context: ReleaseContext

    /// Builds the harness over `candidate`, with the executor programmed to satisfy every
    /// expectation the candidate's own self-tests declare.
    ///
    /// The executor reports observations; the runner compares them. So a self-test run that
    /// reaches the executor and passes did so because the candidate's declared expectations
    /// were met, not because an executor decided its own run passed.
    init(_ candidate: CompatibleCandidate) {
        let log = BundleReadLog()
        let store = FakeActivationRecordStore()
        var observations: [String: SelfTestObservation] = [:]
        for test in candidate.selfTests {
            observations[test.fixtureID.rawValue] = SelfTestObservation(
                pixelLabel: .noStrongSignalDetected
            )
        }
        let executor = FakeSelfTestExecutor(observations: observations)
        let content = MultiBundleContentStore(
            trees: [candidate.integrity.bundleID.rawValue: candidate.integrity.tree],
            recorder: log
        )
        self.bundleID = candidate.integrity.bundleID
        self.candidate = candidate
        self.content = content
        self.readLog = log
        self.store = store
        self.executor = executor
        self.context = candidate.context
        self.activator = ActivationHarnessBuilder.activator(
            assembled: candidate,
            content: content,
            store: store,
            clock: SteppingClock(),
            executor: executor
        )
    }

    /// The finding the whole path produced, or `nil` when the candidate was activated.
    func finding() async -> ModelBundleVerificationError? {
        do {
            _ = try await activator.activate(bundleID, context: context)
            return nil
        } catch {
            return error
        }
    }

    /// How many times the candidate's weight blob was streamed.
    ///
    /// Two for a candidate that reaches the measurement: once while the integrity step
    /// hashes the declared model tree, once by the compatibility step's own measurement.
    /// Zero for a candidate refused earlier. The difference is what makes "the digest was
    /// measured from bytes rather than read from the manifest" observable rather than
    /// assumed.
    var weightBlobReadCount: Int {
        readLog.work.filter {
            $0 == "read:\(bundleID.rawValue):\(CompatibleBundleAssembler.weightBlobPath)"
        }
        .count
    }
}

// MARK: - Signature evidence, and the known-answer-vector gap

@Suite("Model Bundle signature evidence and the known-answer-vector gap")
struct BundleSignatureEvidenceIntegrationTests {
    /// The gap, demonstrated rather than asserted.
    ///
    /// `ManifestSignatureVerificationTests` shows that the verifier asks for exactly the
    /// algorithm the policy approves and refuses a build that does not implement it. What it
    /// cannot show, because the stand-in cannot support it, is that any *algorithm* was
    /// exercised: the stand-in's "signature" is `sha256(keyMaterial || message)`, so one set
    /// of bytes verifies under **every** algorithm identifier a policy could name.
    ///
    /// That is the whole reason approved known-answer vectors are required, and it is why the
    /// next test records their absence instead of this file inventing a vector.
    @Test("The signature stand-in is byte-sensitive but is not a signature scheme")
    func signatureStandInIsNotASignatureScheme() throws {
        let keyMaterial = Array("synthetic-public-key-material".utf8)
        let message = Array("synthetic-manifest-bytes".utf8)
        let signature = FakeSignatureVerifier.signature(
            over: message,
            keyMaterial: keyMaterial
        )
        let verifier = FakeSignatureVerifier(
            material: [Sample.signingKey().rawValue: keyMaterial]
        )

        // Byte-sensitive, which is what the verifier-level tests rely on.
        var altered = message
        altered[0] ^= 0x01
        #expect(
            verifier.verify(
                signature: signature,
                over: altered,
                using: .ed25519,
                publicKeyMaterial: keyMaterial
            ) == .notVerified
        )

        // And not a signature scheme: the algorithm identifier does not participate in the
        // bytes, so every algorithm accepts the same "signature" over the same message. A
        // real scheme would accept it under at most one.
        #expect(SignatureAlgorithm.allCases.count > 1, "one algorithm would make this vacuous")
        for algorithm in SignatureAlgorithm.allCases {
            #expect(
                verifier.verify(
                    signature: signature,
                    over: message,
                    using: algorithm,
                    publicKeyMaterial: keyMaterial
                ) == .verified,
                """
                \(algorithm.rawValue) accepted a stand-in signature that carries no algorithm; \
                nothing in this repository exercises real signature cryptography
                """
            )
        }
    }

    /// Requirements 10.6 and 10.8, recorded as a gap rather than filled in.
    ///
    /// A known-answer vector pins one algorithm's output for one input under one key. None is
    /// installed, and **inventing one would make a release signature gate pass against
    /// arithmetic this repository chose**. So the absence is named, the searched paths are
    /// named, and this test fails the moment vectors are installed — which is the signal to
    /// wire them to a real verifier conformance, not to keep skipping.
    @Test("Absent approved signature known-answer vectors are recorded and never substituted")
    func absentSignatureKnownAnswerVectorsAreRecorded() {
        switch ApprovedSignatureKnownAnswerVectors.status {
        case let .absent(searchedPaths):
            #expect(!searchedPaths.isEmpty, "an absence must name where it looked")
            let described = ApprovedSignatureKnownAnswerVectors.status.description
            #expect(searchedPaths.allSatisfy { described.contains($0) })

        case let .present(path):
            Issue.record(
                """
                approved signature known-answer vectors are now installed at \(path), but no \
                real signature verifier conformance exists to answer them; Requirements 10.6 \
                and 10.8 remain unexercised until one is wired up here
                """
            )
        }
    }

    /// Requirement 10.6 through the whole path.
    ///
    /// The verifier-level suite asserts that a rewritten signed field breaks the signature.
    /// The integration claim is stronger and is what this asserts: with the signature broken,
    /// `activate` refuses, nothing becomes active, the record store is never asked for
    /// anything at all, and no self-test case runs — so a tampered signature costs the
    /// candidate everything rather than only the signature check.
    @Test(
        "A candidate whose signature does not cover its manifest is refused before anything runs",
        arguments: [
            BundleTamper.signedManifestFieldRewritten,
            BundleTamper.detachedSignatureAltered,
        ]
    )
    func alteredSignatureRefusedBeforeAnythingRuns(tamper: BundleTamper) async throws {
        let tampered = try BundleIntegrationScenario.tampered(tamper)
        let harness = BundleIntegrationHarness(tampered.candidate)

        #expect(await harness.finding() == tampered.expectedFinding, "\(tamper)")
        #expect(await harness.activator.activeBundle() == nil)
        #expect(await harness.store.operations.isEmpty, "the record store was consulted")
        #expect(await harness.store.publishedBytes == nil)
        #expect(harness.executor.loadedContexts.isEmpty, "the candidate model was loaded")
        #expect(harness.executor.runFixtures.isEmpty, "a self-test case ran")
        // The weight blob was never streamed: the refusal came long before the measurement.
        #expect(harness.weightBlobReadCount == 0)
    }
}

// MARK: - Altered artifacts, missing self-tests, wrong compatibility, corrupt models

@Suite("One-thing-changed candidates through the complete local verification path")
struct BundleTamperIntegrationTests {
    /// The table, driven through `ModelBundleActivator.activate`.
    ///
    /// Four assertions per case, and the last three are the ones no verifier-level test in
    /// this target can make: the exact finding, nothing active, nothing written or even
    /// asked of the record store, and no self-test case executed.
    @Test(
        "Each tampered or incompatible candidate is refused by name with nothing written",
        arguments: BundleTamper.allCases
    )
    func tamperedCandidateRefusedByName(tamper: BundleTamper) async throws {
        let tampered = try BundleIntegrationScenario.tampered(tamper)
        let harness = BundleIntegrationHarness(tampered.candidate)

        #expect(
            await harness.finding() == tampered.expectedFinding,
            "\(tamper) [\(tamper.family)] must be refused by name"
        )
        #expect(await harness.activator.activeBundle() == nil, "\(tamper) activated something")
        #expect(
            await harness.store.operations.isEmpty,
            "\(tamper) reached the activation record store"
        )
        #expect(await harness.store.receipts.isEmpty, "\(tamper) wrote a receipt")
        #expect(await harness.store.publishedBytes == nil, "\(tamper) published a pointer")
        #expect(await harness.store.leakedStagedTokens().isEmpty)
        #expect(harness.executor.runFixtures.isEmpty, "\(tamper) ran a self-test case")
        #expect(harness.executor.outstandingLoads == 0, "\(tamper) left a model loaded")
    }

    /// The table covers all four families task 6.11 names.
    ///
    /// Without this, a family could quietly stop being exercised — by a case being renamed
    /// into another family, say — and the parameterised test above would still pass.
    @Test("The tamper table covers every family this task names")
    func tamperTableCoversEveryFamily() throws {
        let families = Set(BundleTamper.allCases.map(\.family))
        #expect(
            families == [
                "altered-artifact",
                "missing-self-test",
                "wrong-compatibility",
                "corrupt-model",
            ],
            "the table covers \(families.sorted())"
        )
        // Every expected finding in the table is distinct except the two signature
        // alterations, which are two different tampers that must produce the same refusal.
        // So a case cannot be silently duplicated into a second name.
        let findings = try BundleTamper.allCases.map {
            "\(try BundleIntegrationScenario.tampered($0).expectedFinding)"
        }
        #expect(
            Set(findings).count == BundleTamper.allCases.count - 1,
            "the table declares \(Set(findings).count) distinct findings for \(findings.count) cases"
        )
    }

    /// Every finding a session can see is one category, on this table rather than on a hand
    /// written list.
    ///
    /// `ModelIdentityAndCompatibilityTests` asserts this over a list of findings a test
    /// wrote. Asserting it over the findings the *path* actually produced is what rules out
    /// a tamper family whose refusal escapes the closed vocabulary.
    @Test("Every finding the path produces stays inside the closed session vocabulary")
    func everyFindingIsModelLoadError() async throws {
        for tamper in BundleTamper.allCases {
            let tampered = try BundleIntegrationScenario.tampered(tamper)
            let harness = BundleIntegrationHarness(tampered.candidate)
            let finding = try #require(await harness.finding(), "\(tamper) was admitted")
            #expect(
                finding.analysisFault == .analysis(.modelLoadError, stage: .modelLoad),
                "\(tamper) produced \(finding.analysisFault)"
            )
        }
    }
}

// MARK: - The real weight blob

@Suite("The real model weight blob through the complete local verification path")
struct RealWeightBlobIntegrationTests {
    /// Requirements 10.4, 10.8, 10.11, and 10.13, with the weight measurement passing.
    ///
    /// Where a candidate gets past the weight measurement by satisfying it, rather than by
    /// having its measured digest supplied through a module-internal initializer the way
    /// `ActivationAndRollbackTests` must. A candidate is assembled around **the real
    /// immutable blob** and the complete path has to admit it:
    /// integrity over real bytes, every declarative compatibility check, the weight
    /// measurement, the self-test artifact resolution, the offline self-test run, the
    /// receipt, and the atomic commit.
    ///
    /// The expected digest is the production constant, never a value chosen here. The
    /// measured one is streamed from real bytes by the real verifier, which the read count
    /// pins: two reads, one per step that hashes the blob.
    ///
    /// This is a host run and is **not** device evidence. It establishes that the local
    /// verification path admits the released artifact, and nothing about parity, latency,
    /// thermals, or Apple Neural Engine placement.
    @Test(
        "A candidate carrying the real weight blob passes every check and activates",
        .enabled(
            if: RealModelWeightBlob.isPresent,
            "no model weight blob is installed; data/ is not under version control"
        )
    )
    func realWeightBlobPassesEveryCheckAndActivates() async throws {
        let blob = try #require(RealModelWeightBlob.bytes)
        // The pinned expectation, read from the production constant that carries
        // Requirement 10.4's value. Nothing here computes what it should be.
        #expect(
            StreamingSHA256.digest(of: blob) == RequiredPixelModel.identity.requiredWeightDigest,
            """
            the installed weight blob is not the artifact Requirement 10.4 pins; \
            \(RealModelWeightBlob.status)
            """
        )

        let candidate = try BundleIntegrationScenario.candidate(weightBlob: blob)

        // Steps 1 through 5 in isolation first, so the finding — or its absence — names the
        // verification half rather than the activation half.
        #expect(
            candidate.compatibilityFinding() == nil,
            """
            a candidate carrying the real weight blob was still refused: \
            \(candidate.compatibilityFinding().map(\.description) ?? "none")
            """
        )
        let resolved = try candidate.resolve()
        #expect(resolved.measuredWeightDigest == RequiredPixelModel.identity.requiredWeightDigest)

        // Then the whole path.
        let harness = BundleIntegrationHarness(candidate)
        let bound = try await harness.activator.activate(harness.bundleID, context: harness.context)

        #expect(bound.bundleID == harness.bundleID)
        #expect(bound.modelIdentity == RequiredPixelModel.identity)
        #expect(await harness.activator.activeBundle() == bound)
        // One published pointer, and the self-test run really happened.
        #expect(await harness.store.publishedBytes != nil)
        #expect(await harness.store.receipts.count == 1)
        #expect(await harness.store.leakedStagedTokens().isEmpty)
        #expect(harness.executor.runFixtures == candidate.selfTests.map(\.fixtureID))
        #expect(harness.executor.outstandingLoads == 0, "the candidate model was left loaded")

        // Measured from bytes, twice: the integrity step hashing the declared model tree and
        // the compatibility step's own measurement. A digest read from the manifest instead
        // would show fewer.
        #expect(
            harness.weightBlobReadCount == 2,
            "the weight blob was streamed \(harness.weightBlobReadCount) time(s), expected 2"
        )
    }

    /// The measurement bites.
    ///
    /// One byte of the real blob flipped, everything else identical — including the declared
    /// tree digest, which is recomputed over the altered bytes so the integrity step still
    /// passes. The only check that can catch it is the weight measurement, and it does.
    @Test(
        "One flipped byte in the real weight blob is refused at the weight measurement",
        .enabled(
            if: RealModelWeightBlob.isPresent,
            "no model weight blob is installed; data/ is not under version control"
        )
    )
    func oneFlippedWeightByteIsRefused() async throws {
        var blob = try #require(RealModelWeightBlob.bytes)
        #expect(!blob.isEmpty)
        blob[blob.count / 2] ^= 0x01

        let candidate = try BundleIntegrationScenario.candidate(weightBlob: blob)
        let harness = BundleIntegrationHarness(candidate)

        #expect(
            await harness.finding() == .modelWeightDigestMismatch(candidate.layout.modelWeightBlob)
        )
        #expect(await harness.activator.activeBundle() == nil)
        #expect(await harness.store.operations.isEmpty)
        #expect(harness.executor.runFixtures.isEmpty, "a self-test ran on a corrupt model")
        // Still streamed twice: the measurement ran and disagreed, rather than the candidate
        // being refused before it.
        #expect(
            harness.weightBlobReadCount == 2,
            "the weight blob was streamed \(harness.weightBlobReadCount) time(s), expected 2"
        )
    }

    /// The absence of the real blob is recorded, and the documented terminal is pinned.
    ///
    /// Always runs. While the blob is absent it names where it looked and requires a purely
    /// synthetic candidate — one that is compatible in every respect a synthetic fixture can
    /// be — to stop at exactly `.modelWeightDigestMismatch` with nothing written. That is the
    /// "everything before it passed" signal the doubles document, and pinning it here is what
    /// keeps the skipped tests above wired to a real check.
    @Test("An absent weight blob is recorded and the synthetic terminal stays pinned")
    func absentRealWeightBlobIsRecorded() async throws {
        switch RealModelWeightBlob.status {
        case let .absent(searchedPaths):
            #expect(!searchedPaths.isEmpty, "an absence must name where it looked")
            let described = RealModelWeightBlob.status.description
            #expect(searchedPaths.allSatisfy { described.contains($0) })
            #expect(RealModelWeightBlob.bytes == nil)

        case let .present(path, byteCount):
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(byteCount > 0)
            #expect(RealModelWeightBlob.bytes?.count == byteCount)

        case let .unreadable(path, reason):
            Issue.record("the weight blob at \(path) is installed but unreadable: \(reason)")
        }

        // The documented terminal, whichever world this runs in. A synthetic blob cannot
        // digest to the pinned value, and that is the check working rather than a gap.
        let synthetic = try CompatibleBundleAssembler.standard()
        let harness = BundleIntegrationHarness(synthetic)
        #expect(
            await harness.finding()
                == .modelWeightDigestMismatch(synthetic.layout.modelWeightBlob)
        )
        #expect(await harness.activator.activeBundle() == nil)
        #expect(await harness.store.operations.isEmpty)
        #expect(harness.executor.runFixtures.isEmpty)
        #expect(
            harness.weightBlobReadCount == 2,
            "the weight blob was streamed \(harness.weightBlobReadCount) time(s), expected 2"
        )
        #expect(
            StreamingSHA256.digest(of: Array("weight-blob".utf8))
                != RequiredPixelModel.identity.requiredWeightDigest,
            "a synthetic placeholder must not satisfy the pinned digest"
        )
    }
}
