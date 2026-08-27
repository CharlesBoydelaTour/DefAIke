import Foundation

@testable import DefAIkeDomain
@testable import DefAIkeModelBundle

// Doubles for step 7: the record store, a multi-bundle content store, and an assembler that
// produces the value activation consumes.
//
// One thing here needs stating up front, because it shapes every test in
// `ActivationAndRollbackTests`. Requirement 10.4 pins the weight-blob digest to a specific
// SHA-256 value, so no synthetic bundle can pass the weight measurement: an otherwise
// perfect assembled candidate stops at ``ModelBundleVerificationError/modelWeightDigestMismatch(_:)``.
// Steps 1 through 5 are therefore exercised end to end through the real verifiers — that is
// how the tests know rollback runs the same path — while the ``SelfTestedBundleCandidate``
// that step 7 consumes is constructed through its internal initializer, which is possible
// only because these tests live inside the module. The alternative would be faking a weight
// digest, which would weaken the one check that pins model identity.

// MARK: - Record store

/// An in-memory activation record store that records everything it was asked to do.
///
/// Faithful to the three parts atomicity depends on:
///
///   * receipts are immutable — a byte-identical rewrite is a no-op, a different receipt
///     under an existing identifier is refused;
///   * staging never touches the published slot, so an interrupted activation leaves the
///     published pointer alone; and
///   * publishing replaces the published slot in one assignment, and every value that slot
///     has ever held is recorded, so a test can assert an observer never saw a mixture.
///
/// The published pointer is held as encoded bytes rather than as a value. That is what makes
/// "byte-for-byte unchanged" assertable rather than merely "equal": a store that rewrote the
/// pointer with different bytes that happen to decode equally would still be caught.
actor FakeActivationRecordStore: ActivationRecordStoring {
    /// Where a programmed store failure lands.
    ///
    /// Named after the operations the design's step 7 performs, so a fault-injection test
    /// states the boundary it means.
    enum FailurePoint: String, Hashable, Sendable, CaseIterable {
        case readPointer
        case persistReceipt
        case stagePointer
        case synchronize
        case publish
    }

    private(set) var receipts: [String: ActivationReceipt] = [:]
    private(set) var receiptWriteOrder: [ArtifactID] = []

    /// Every receipt identifier a write was attempted for, including refused ones.
    ///
    /// Recorded so a fault-injection test can name the identifier the activation derived
    /// instead of predicting it: the identifier carries the attempt instant, and a test that
    /// read the clock to guess it would advance the clock and guess wrong.
    private(set) var attemptedReceiptIdentifiers: [ArtifactID] = []

    /// Encoded published pointer. Replaced in one assignment, never edited in place.
    private(set) var publishedBytes: [UInt8]?

    /// Every value the published slot has held, oldest first, including its initial one.
    private(set) var publishedHistory: [[UInt8]?] = []

    private(set) var stagedBytes: [UInt64: [UInt8]] = [:]
    private(set) var synchronizedTokens: Set<UInt64> = []
    private(set) var discardedTokens: [UInt64] = []
    private(set) var operations: [String] = []

    private var nextToken: UInt64 = 1
    private var failures: Set<FailurePoint> = []

    /// Identifiers a different receipt already occupies.
    private var conflictingIdentifiers: Set<String> = []

    init() {
        publishedHistory = [nil]
    }

    // MARK: Programming

    func fail(at point: FailurePoint) {
        failures.insert(point)
    }

    func succeed(at point: FailurePoint) {
        failures.remove(point)
    }

    /// Declares that `id` already holds a different persisted receipt.
    ///
    /// The one situation immutability exists for: an activation derives an identifier a
    /// record already occupies with bytes that are not the ones it is about to write. The
    /// store keeps the record and refuses the write.
    ///
    /// Declared as an identifier rather than seeded as a receipt on purpose. A real store is
    /// keyed by identifier, so it cannot hold a receipt whose own `id` disagrees with its
    /// key; seeding one to provoke the conflict would model a store that cannot exist. What
    /// a test needs to say here is "these bytes are already taken", and that is exactly what
    /// this records.
    func declareConflict(for id: ArtifactID) {
        conflictingIdentifiers.insert(id.rawValue)
    }

    /// Seeds a published pointer and its receipt without running an activation.
    ///
    /// Models a launch that finds durable records already on disk. It deliberately makes
    /// nothing active: a persisted receipt is a record, not a certificate.
    func seedPublished(_ receipt: ActivationReceipt) throws {
        receipts[receipt.id.rawValue] = receipt
        receiptWriteOrder.append(receipt.id)
        let bytes = try Self.encode(ActiveBundlePointer(receipt: receipt))
        publishedBytes = bytes
        publishedHistory.append(bytes)
    }

    // MARK: Inspection

    /// The published pointer as a value, or `nil` when nothing is published.
    func publishedPointer() throws -> ActiveBundlePointer? {
        guard let publishedBytes else { return nil }
        return try Self.decode(publishedBytes)
    }

    /// Staged tokens that were neither published nor discarded.
    func leakedStagedTokens() -> [UInt64] {
        stagedBytes.keys.filter { !discardedTokens.contains($0) }.sorted()
    }

    // MARK: ActivationRecordStoring

    func activePointer() async throws(ActivationStoreFault) -> ActiveBundlePointer? {
        operations.append("activePointer")
        guard !failures.contains(.readPointer) else { throw .storeUnavailable }
        guard let publishedBytes else { return nil }
        guard let pointer = try? Self.decode(publishedBytes) else {
            throw .storeUnavailable
        }
        return pointer
    }

    func receipt(_ id: ArtifactID) async throws(ActivationStoreFault) -> ActivationReceipt? {
        operations.append("receipt")
        return receipts[id.rawValue]
    }

    func persistReceipt(_ receipt: ActivationReceipt) async throws(ActivationStoreFault) {
        operations.append("persistReceipt")
        attemptedReceiptIdentifiers.append(receipt.id)
        guard !failures.contains(.persistReceipt) else { throw .writeFailed }
        guard !conflictingIdentifiers.contains(receipt.id.rawValue) else {
            throw .receiptConflict
        }
        if let existing = receipts[receipt.id.rawValue] {
            // Immutability: the same bytes again change nothing, different bytes are refused.
            guard existing == receipt else { throw .receiptConflict }
            return
        }
        receipts[receipt.id.rawValue] = receipt
        receiptWriteOrder.append(receipt.id)
    }

    func stage(
        _ pointer: ActiveBundlePointer
    ) async throws(ActivationStoreFault) -> StagedActivationToken {
        operations.append("stage")
        guard !failures.contains(.stagePointer) else { throw .writeFailed }
        guard let bytes = try? Self.encode(pointer) else { throw .writeFailed }
        let token = nextToken
        nextToken += 1
        stagedBytes[token] = bytes
        return StagedActivationToken(rawValue: token)
    }

    func synchronize(_ staged: StagedActivationToken) async throws(ActivationStoreFault) {
        operations.append("synchronize")
        guard !failures.contains(.synchronize) else { throw .synchronizationFailed }
        guard stagedBytes[staged.rawValue] != nil else { throw .synchronizationFailed }
        synchronizedTokens.insert(staged.rawValue)
    }

    func publish(_ staged: StagedActivationToken) async throws(ActivationStoreFault) {
        operations.append("publish")
        guard !failures.contains(.publish) else { throw .replacementFailed }
        guard let bytes = stagedBytes[staged.rawValue],
              synchronizedTokens.contains(staged.rawValue)
        else {
            throw .replacementFailed
        }
        // The atomic replacement: one assignment of the complete staged value. There is no
        // read-modify-write of the published slot anywhere in this type.
        publishedBytes = bytes
        publishedHistory.append(bytes)
        stagedBytes.removeValue(forKey: staged.rawValue)
        synchronizedTokens.remove(staged.rawValue)
    }

    func discard(_ staged: StagedActivationToken) async {
        operations.append("discard")
        stagedBytes.removeValue(forKey: staged.rawValue)
        synchronizedTokens.remove(staged.rawValue)
        discardedTokens.append(staged.rawValue)
    }

    // MARK: Coding

    static func encode(_ pointer: ActiveBundlePointer) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Array(try encoder.encode(pointer))
    }

    static func decode(_ bytes: [UInt8]) throws -> ActiveBundlePointer {
        try JSONDecoder().decode(ActiveBundlePointer.self, from: Data(bytes))
    }
}

// MARK: - Multi-bundle content store

/// Serves two or more candidate trees from one content seam, dispatching by bundle
/// identifier, and records every path read against the bundle it was read from.
///
/// Two bundles are the minimum an activation test needs: activation and rollback are about
/// replacing one with the other, and a single-bundle store cannot express "the prior bundle
/// is unchanged".
///
/// It has no write member at all, which is the seam's own guarantee rather than this
/// double's choice: nothing in the verification path can alter a candidate's bytes.
struct MultiBundleContentStore: ModelBundleContentReading {
    var trees: [String: FakeBundleTree]
    let recorder: BundleReadLog

    func entries(in bundle: ModelBundleID) throws(BundleContentFault) -> [BundleTreeEntry] {
        guard let tree = trees[bundle.rawValue] else { throw .storeUnavailable }
        recorder.recordEnumeration(of: bundle)
        return try tree.entries(in: bundle)
    }

    func readFile(
        at path: CanonicalRelativePath,
        in bundle: ModelBundleID,
        chunkByteCount: Int,
        into sink: (ArraySlice<UInt8>) -> BundleReadDisposition
    ) throws(BundleContentFault) {
        guard let tree = trees[bundle.rawValue] else { throw .storeUnavailable }
        recorder.recordRead(of: path, in: bundle)
        try tree.readFile(
            at: path,
            in: bundle,
            chunkByteCount: chunkByteCount,
            into: sink
        )
    }
}

/// Records the verification work one run performed, in order.
///
/// The comparison oracle for "rollback runs the identical verification path": two runs whose
/// recorded work is equal did the same reads in the same order over the same bundle.
final class BundleReadLog: @unchecked Sendable {
    private(set) var work: [String] = []

    func recordEnumeration(of bundle: ModelBundleID) {
        work.append("enumerate:\(bundle.rawValue)")
    }

    func recordRead(of path: CanonicalRelativePath, in bundle: ModelBundleID) {
        work.append("read:\(bundle.rawValue):\(path.rawValue)")
    }
}

// MARK: - An activatable pair

/// Two assembled candidates that share one approved configuration, plus the activator over
/// them.
///
/// `prior` stands in for the bundle a release installed or a rollback returns to; `candidate`
/// for the one being activated. Both are structurally valid and verify identically, so any
/// asymmetry a test observes comes from the code under test rather than from the fixtures.
struct ActivationHarness {
    let priorID: ModelBundleID
    let candidateID: ModelBundleID
    var content: MultiBundleContentStore
    let readLog: BundleReadLog
    let store: FakeActivationRecordStore
    let clock: SteppingClock
    let activator: ModelBundleActivator
    let context: ReleaseContext
    let assembled: CompatibleCandidate

    /// An activator over the same store and clock but a mutated content store.
    ///
    /// Used to change a bundle's bytes *after* it was activated, which is the only way to ask
    /// whether rollback re-measures a prior bundle or takes its word for it.
    func activator(
        overriding mutate: (inout MultiBundleContentStore) -> Void
    ) -> ModelBundleActivator {
        var mutated = content
        mutate(&mutated)
        return ActivationHarnessBuilder.activator(
            assembled: assembled,
            content: mutated,
            store: store,
            clock: clock
        )
    }

    /// The verified tree of one bundle, run through the real integrity verifier.
    func verifiedTree(
        _ bundle: ModelBundleID
    ) throws(ModelBundleVerificationError) -> VerifiedBundleArtifactTree {
        try integrityVerifier.verify(bundle)
    }

    var integrityVerifier: ModelBundleIntegrityVerifier {
        ModelBundleIntegrityVerifier(
            content: content,
            signatures: assembled.integrity.signatures,
            policy: assembled.integrity.policy,
            canonicalization: assembled.integrity.canonicalization
        )
    }

    /// The value steps 4 and 5 would produce for one bundle, built through the
    /// module-internal initializer.
    ///
    /// Necessary rather than convenient: Requirement 10.4 pins the weight-blob digest, so
    /// running the real compatibility verifier over a synthetic bundle always stops at the
    /// weight measurement. Steps 1 through 3 are still real — the tree comes from the actual
    /// integrity verifier over the actual bytes — so every digest a receipt records is a
    /// measurement rather than a fixture constant.
    func compatible(
        _ bundle: ModelBundleID
    ) throws(ModelBundleVerificationError) -> CompatibleBundleCandidate {
        CompatibleBundleCandidate(
            tree: try verifiedTree(bundle),
            layout: assembled.layout,
            capabilityManifestID: assembled.configuration.capabilityManifest.id,
            appBuild: context.device.appBuild,
            measuredWeightDigest: RequiredPixelModel.identity.requiredWeightDigest,
            selfTests: assembled.plan()
        )
    }

    /// The value step 7 consumes for one bundle.
    func selfTested(
        _ bundle: ModelBundleID
    ) throws -> SelfTestedBundleCandidate {
        let candidate = try compatible(bundle)
        let plan = candidate.selfTests
        return SelfTestedBundleCandidate(
            candidate: candidate,
            report: SelfTestRunReport(
                specificationID: plan.specificationID,
                executedCases: plan.cases.map(\.id),
                comparedExpectationCount: plan.cases.reduce(0) { $0 + $1.expectations.count },
                resourceBudgetID: assembled.configuration.resourceBudgets.mainApplication.id,
                unmeasurableMetrics: []
            )
        )
    }

    /// A bindable receipt for one bundle, carrying the same measurements an activation would
    /// record.
    ///
    /// For seeding durable records a launch would find already on disk. Built from the
    /// verified tree rather than from constants, so a seeded record is indistinguishable from
    /// one this code wrote — which matters for the tests that expect a persisted receipt to be
    /// ignored, because an obviously synthetic record could be ignored for the wrong reason.
    func receipt(
        _ bundle: ModelBundleID,
        id: ArtifactID,
        generation: PositiveCount,
        at instant: Date = Date(timeIntervalSince1970: 1_600_000_000)
    ) throws -> ActivationReceipt {
        let candidate = try compatible(bundle)
        return try ActivationReceipt(
            id: id,
            schemaVersion: .v1,
            bundleID: bundle,
            verificationPolicy: candidate.tree.verificationPolicyID,
            verifiedManifestDigest: candidate.tree.manifestDigest,
            verifiedArtifactDigests: candidate.tree.verifiedArtifacts,
            signatureOutcome: .passed,
            selfTestOutcome: .passed,
            deviceContext: context.device,
            activationGeneration: generation,
            activatedAt: instant
        )
    }

    /// A self-test runner over this harness's fixtures whose executor a test programs.
    ///
    /// Step 6 is not reachable through ``ModelBundleActivator/activate(_:context:)`` for a
    /// synthetic bundle, because step 5 stops at the weight measurement first. Driving the
    /// runner directly is the only way to ask what a self-test failure leaves behind, and the
    /// answer that matters is that it reaches step 7 with nothing written.
    func selfTestRunner(executor: FakeSelfTestExecutor) -> ReleaseSelfTestRunner {
        ReleaseSelfTestRunner(
            execution: executor,
            content: content,
            resources: StubResourceGovernor(),
            budget: assembled.configuration.resourceBudgets.mainApplication
        )
    }
}

/// A wall clock that advances one fixed step per reading.
///
/// Distinct instants matter here: a receipt identifier carries the attempt instant, so a
/// frozen clock would make two attempts collide and hide the immutability behaviour under
/// test rather than exercising it.
final class SteppingClock: SessionClock, @unchecked Sendable {
    private let start: Date
    private let step: TimeInterval
    private var readings = 0

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000), step: TimeInterval = 1) {
        self.start = start
        self.step = step
    }

    var wallClockNow: Date {
        defer { readings += 1 }
        return nextReading
    }

    /// The instant the next reading will return, without consuming it.
    ///
    /// A receipt identifier carries the attempt instant, so a test that wants to name the
    /// identifier an activation is about to derive has to know which instant that activation
    /// will read. Reading `wallClockNow` to find out would consume the reading and make the
    /// prediction wrong by exactly one step, so peeking is a separate accessor rather than a
    /// convention about when to read.
    var nextReading: Date { start.addingTimeInterval(step * Double(readings)) }

    var monotonicNow: ContinuousClock.Instant { ContinuousClock.now }
}

enum ActivationHarnessBuilder {
    static let priorBundle = "bundle.prior"
    static let candidateBundle = "bundle.candidate"

    /// Assembles two candidates, one approved configuration listing both, and an activator.
    static func standard(
        selfTests: [SampleSelfTest] = [SampleSelfTest()]
    ) throws -> ActivationHarness {
        let prior = Sample.bundle(priorBundle)
        let candidate = Sample.bundle(candidateBundle)
        // One assembler run per bundle so each carries a manifest declaring its own
        // identity, and one configuration whose approved catalogue lists both.
        let assembledPrior = try CompatibleBundleAssembler.standard(
            bundleID: prior,
            selfTests: selfTests,
            bundleCatalog: [prior, candidate]
        )
        let assembledCandidate = try CompatibleBundleAssembler.standard(
            bundleID: candidate,
            selfTests: selfTests,
            bundleCatalog: [prior, candidate]
        )
        let readLog = BundleReadLog()
        let content = MultiBundleContentStore(
            trees: [
                prior.rawValue: assembledPrior.integrity.tree,
                candidate.rawValue: assembledCandidate.integrity.tree,
            ],
            recorder: readLog
        )
        let store = FakeActivationRecordStore()
        let clock = SteppingClock()
        return ActivationHarness(
            priorID: prior,
            candidateID: candidate,
            content: content,
            readLog: readLog,
            store: store,
            clock: clock,
            activator: activator(
                assembled: assembledCandidate,
                content: content,
                store: store,
                clock: clock
            ),
            context: assembledCandidate.context,
            assembled: assembledCandidate
        )
    }

    /// An activator over one content store, wired to the real verifiers.
    static func activator(
        assembled: CompatibleCandidate,
        content: any ModelBundleContentReading,
        store: any ActivationRecordStoring,
        clock: any SessionClock,
        executor: FakeSelfTestExecutor = FakeSelfTestExecutor(),
        governor: StubResourceGovernor = StubResourceGovernor()
    ) -> ModelBundleActivator {
        ModelBundleActivator(
            integrity: ModelBundleIntegrityVerifier(
                content: content,
                signatures: assembled.integrity.signatures,
                policy: assembled.integrity.policy,
                canonicalization: assembled.integrity.canonicalization
            ),
            compatibility: ModelBundleCompatibilityVerifier(
                content: content,
                configuration: assembled.configuration,
                evidenceScope: assembled.evidenceScope,
                layout: assembled.layout
            ),
            selfTests: ReleaseSelfTestRunner(
                execution: executor,
                content: content,
                resources: governor,
                budget: assembled.configuration.resourceBudgets.mainApplication
            ),
            store: store,
            clock: clock
        )
    }
}
