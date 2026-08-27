import DefAIkeDomain
import Foundation

@testable import DefAIkeSharedTransfer

// Structurally valid, deliberately synthetic values the shared-transfer tests need as
// arguments, plus the temporary-directory scaffolding the real store requires.
//
// **No number here is an approved release value.** The capacity, the chunk sizes, and the
// budget limits are test scaffolding for an unresolved external decision; nothing here may
// be copied into a shipping artifact.

enum Sample {
    static func sessionID(_ raw: String = "session-0001") -> AnalysisSessionID {
        guard let id = AnalysisSessionID(raw) else {
            preconditionFailure("session identifier is not canonical: \(raw)")
        }
        return id
    }

    static func transferID(_ raw: String = "transfer-0001") -> ShareTransferID {
        guard let id = ShareTransferID(raw) else {
            preconditionFailure("transfer identifier is not canonical: \(raw)")
        }
        return id
    }

    static func artifactID(_ raw: String) -> ArtifactID {
        guard let id = ArtifactID(raw) else {
            preconditionFailure("artifact identifier is not canonical: \(raw)")
        }
        return id
    }

    static func contentTypeHint(_ raw: String = "public.jpeg") -> ContentTypeHint {
        guard let hint = ContentTypeHint(raw) else {
            preconditionFailure("content type hint is not valid: \(raw)")
        }
        return hint
    }

    /// A deterministic byte sequence. Reproducible so a failure can be replayed.
    static func bytes(count: Int, seed: UInt8 = 1) -> [UInt8] {
        var value = seed
        return (0..<count).map { _ in
            value = value &* 31 &+ 17
            return value
        }
    }

    /// A budget whose `temporary-storage` limit is `temporaryStorageBytes`.
    ///
    /// Structurally valid and entirely synthetic: it exists so the budget-derived store
    /// configuration can be called at all.
    static func budget(
        temporaryStorageBytes: Decimal,
        target: ExecutionTarget = .shareExtension,
        temporaryStorageUnit: ResourceLimitUnit = .bytes
    ) -> ResourceBudget {
        do {
            return try ResourceBudget(
                id: artifactID("budget-\(target.rawValue)"),
                schemaVersion: .v1,
                target: target,
                hardLimits: try ResourceMetric.requiredMetrics(for: target)
                    .sorted { $0.rawValue < $1.rawValue }
                    .map { metric in
                        try ResourceLimitEntry(
                            metric: metric,
                            limit: try limit(
                                for: metric,
                                temporaryStorageBytes: temporaryStorageBytes,
                                temporaryStorageUnit: temporaryStorageUnit
                            ),
                            measurementConditions: evidence("measurement-\(metric.rawValue)")
                        )
                    },
                validationPlan: artifactID("validation-plan-0001")
            )
        } catch {
            preconditionFailure("the budget fixture must be schema-valid: \(error)")
        }
    }

    private static func limit(
        for metric: ResourceMetric,
        temporaryStorageBytes: Decimal,
        temporaryStorageUnit: ResourceLimitUnit
    ) throws -> ValidatedLimit {
        if metric.isCategorical { return .thermal(maximumState: .fair) }
        if metric == .temporaryStorage {
            return .numeric(
                value: try PositiveDecimal(validating: temporaryStorageBytes),
                unit: temporaryStorageUnit
            )
        }
        return .numeric(
            value: try PositiveDecimal(validating: 1_000),
            unit: unit(for: metric)
        )
    }

    private static func unit(for metric: ResourceMetric) -> ResourceLimitUnit {
        switch metric {
        case .decodedPixelCount: .pixels
        case .encodedInputSize, .peakResidentMemory, .temporaryStorage: .bytes
        case .coldModelLoadTime, .warmAnalysisLatency, .handoffLatency: .milliseconds
        case .energyImpact: .milliwattHours
        case .thermalState: .bytes
        }
    }

    static func evidence(_ artifact: String) -> EvidenceSource {
        do {
            return EvidenceSource(
                artifact: artifactID(artifact),
                version: try SchemaSemanticVersion(validating: "1.0.0"),
                contentDigest: StreamingSHA256.digest(of: Data(artifact.utf8))
            )
        } catch {
            preconditionFailure("the evidence fixture must be schema-valid: \(error)")
        }
    }
}

// MARK: - Temporary roots and source files

/// Runs `body` with a fresh empty directory and removes it afterwards.
///
/// The store owns its root completely, so each test gets its own: a leaked root would let
/// one test's leftover objects satisfy another test's capacity or cleanup assertion.
func withTemporaryRoot<T>(
    _ body: (URL) async throws -> T
) async throws -> T {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appending(path: "defaike-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}

/// A test capacity in bytes. Test scaffolding, not an approved Resource Budget value.
let testCapacityInBytes: UInt64 = 1 << 20

extension ProtectedEphemeralFileStore.Configuration {
    /// A configuration rooted at `root` with a generous test capacity.
    static func test(
        root: URL,
        capacityInBytes: UInt64 = testCapacityInBytes,
        containerProtection: FileProtectionLevel = .complete
    ) -> Self {
        Self(
            rootDirectory: root,
            capacityInBytes: capacityInBytes,
            containerProtection: containerProtection
        )
    }
}

/// Writes `bytes` to a file that stands in for a provider's temporary representation.
///
/// Deliberately outside the store's root: the retainer must copy across that boundary and
/// must leave this file untouched.
func makeProviderFile(
    _ bytes: [UInt8],
    named name: String = "provider-representation.bin"
) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appending(path: "defaike-provider-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name, directoryHint: .notDirectory)
    try Data(bytes).write(to: url)
    return url
}

/// Removes a provider file's enclosing directory.
func removeProviderFile(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

// MARK: - Protection doubles

/// Refuses one protection level, so the fail-closed path is reachable without a device
/// that rejects a level.
struct RefusingDataProtection: DataProtectionApplying {
    let refusedLevel: FileProtectionLevel
    let underlying = PlatformDataProtection()

    var enforcesDataProtection: Bool { underlying.enforcesDataProtection }

    func createProtectedDirectory(
        at url: URL,
        level: FileProtectionLevel
    ) throws(EphemeralStoreError) {
        guard level != refusedLevel else { throw .protectionUnavailable(level) }
        try underlying.createProtectedDirectory(at: url, level: level)
    }

    func createProtectedFile(
        at url: URL,
        level: FileProtectionLevel
    ) throws(EphemeralStoreError) {
        guard level != refusedLevel else { throw .protectionUnavailable(level) }
        try underlying.createProtectedFile(at: url, level: level)
    }

    func appliedLevel(ofItemAt url: URL) -> FileProtectionLevel? {
        underlying.appliedLevel(ofItemAt: url)
    }
}

// MARK: - Store doubles

/// A store whose reads fail and whose every other operation is the real one.
///
/// Narrow on purpose. Resolving a published slot has to read the manifest, so refusing only
/// reads reaches the "material exists but the store cannot say what it is" path without
/// changing how anything was written.
struct FailingReadStore: EphemeralFileStoring {
    let underlying: ProtectedEphemeralFileStore
    let fault: EphemeralStoreError = .storeUnavailable

    func create(
        in scope: EphemeralStorageScope,
        protection: FileProtectionLevel
    ) async throws(EphemeralStoreError) -> EphemeralStorageKey {
        try await underlying.create(in: scope, protection: protection)
    }

    func append(
        _ chunk: [UInt8],
        to key: EphemeralStorageKey
    ) async throws(EphemeralStoreError) {
        try await underlying.append(chunk, to: key)
    }

    func finalize(
        _ key: EphemeralStorageKey
    ) async throws(EphemeralStoreError) -> EphemeralWriteReceipt {
        try await underlying.finalize(key)
    }

    func read(_ key: EphemeralStorageKey) async throws(EphemeralStoreError) -> [UInt8] {
        throw fault
    }

    func receipt(for key: EphemeralStorageKey) async -> EphemeralWriteReceipt? {
        await underlying.receipt(for: key)
    }

    func move(
        _ key: EphemeralStorageKey,
        to scope: EphemeralStorageScope
    ) async throws(EphemeralStoreError) {
        try await underlying.move(key, to: scope)
    }

    func keys(in scope: EphemeralStorageScope) async -> Set<EphemeralStorageKey> {
        await underlying.keys(in: scope)
    }

    func deleteAll(
        in scope: EphemeralStorageScope,
        reason: SessionCleanupReason
    ) async throws(EphemeralStoreError) -> EphemeralDeletionReceipt {
        try await underlying.deleteAll(in: scope, reason: reason)
    }

    func occupiedScopes() async -> Set<EphemeralStorageScope> {
        await underlying.occupiedScopes()
    }
}

/// A fixed wall clock, so deletion receipt timestamps are deterministic.
struct FixedClock: SessionClock {
    let instant: Date

    init(_ instant: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.instant = instant
    }

    var wallClockNow: Date { instant }

    var monotonicNow: ContinuousClock.Instant { ContinuousClock.now }
}

// MARK: - Transfer-store fixtures

extension Sample {
    static func buildID(_ raw: String = "build-pixel-only-0001") -> AppBuildID {
        guard let id = AppBuildID(raw) else {
            preconditionFailure("build identifier is not canonical: \(raw)")
        }
        return id
    }

    static func approverID(_ raw: String = "approver-release-owner") -> ApproverID {
        guard let id = ApproverID(raw) else {
            preconditionFailure("approver identifier is not canonical: \(raw)")
        }
        return id
    }

    static func approval(_ artifact: String) -> ApprovalRecord {
        ApprovalRecord(
            source: evidence(artifact),
            decision: .approved,
            approver: approverID(),
            decidedAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
    }

    /// A lifecycle policy whose every deadline is `milliseconds`.
    ///
    /// Structurally valid and entirely synthetic. The real numbers are an unresolved
    /// external decision (D7); nothing here may be copied into a shipping artifact. The
    /// abandoned deadline is the one the transfer store reads, so tests set it explicitly
    /// and leave the rest at the same value to keep the fixture unambiguous.
    static func lifecyclePolicy(
        abandonedMilliseconds: UInt64 = 60_000,
        otherMilliseconds: UInt64 = 60_000
    ) -> DataLifecyclePolicy {
        do {
            return try DataLifecyclePolicy(
                id: artifactID("data-lifecycle-0001"),
                schemaVersion: .v1,
                deadlines: try SessionCleanupReason.allCases.map { reason in
                    DataLifecyclePolicy.Deadline(
                        reason: reason,
                        deadline: try ValidatedDuration(
                            validating: reason == .abandoned
                                ? abandonedMilliseconds
                                : otherMilliseconds
                        )
                    )
                },
                approval: approval("data-lifecycle-approval")
            )
        } catch {
            preconditionFailure("the lifecycle policy fixture must be schema-valid: \(error)")
        }
    }

    /// A lifecycle policy whose five deadlines are all different.
    ///
    /// Structurally valid and entirely synthetic; the real numbers are an unresolved external
    /// decision (D7). Distinctness is the point rather than the values: a receipt that read
    /// the wrong reason's entry would carry a number this fixture can name, so the assertion
    /// bites instead of passing because every deadline happens to be equal.
    static func distinctDeadlinePolicy() -> DataLifecyclePolicy {
        let milliseconds: [SessionCleanupReason: UInt64] = [
            .completed: 1_000,
            .cancelled: 2_000,
            .errorTerminated: 3_000,
            .interrupted: 4_000,
            .abandoned: 5_000,
        ]
        do {
            return try DataLifecyclePolicy(
                id: artifactID("data-lifecycle-distinct-0001"),
                schemaVersion: .v1,
                deadlines: try SessionCleanupReason.allCases.map { reason in
                    DataLifecyclePolicy.Deadline(
                        reason: reason,
                        deadline: try ValidatedDuration(
                            // Force-unwrap-free: the table covers the closed reason set, and
                            // a missing entry must fail the fixture rather than default.
                            validating: milliseconds[reason] ?? 0
                        )
                    )
                },
                approval: approval("data-lifecycle-distinct-approval")
            )
        } catch {
            preconditionFailure("the lifecycle policy fixture must be schema-valid: \(error)")
        }
    }

    /// An extension execution policy with the given staged protection level.
    ///
    /// The pending-handoff behavior is not a parameter: the schema rejects
    /// `replaceSilently`, so a valid policy can only ask for a recovery instruction.
    static func extensionPolicy(
        stagedFileProtection: FileProtectionLevel = .complete
    ) -> ExtensionExecutionPolicy {
        do {
            return try ExtensionExecutionPolicy(
                id: artifactID("extension-execution-0001"),
                schemaVersion: .v1,
                requiresVisibleConsent: true,
                delegatesInferenceToMainApplication: true,
                stagedFileProtection: stagedFileProtection,
                pendingHandoffPolicy: .instructRecovery,
                protectionEvidence: evidence("extension-protection-measurement")
            )
        } catch {
            preconditionFailure("the extension policy fixture must be schema-valid: \(error)")
        }
    }

    /// Consent for one provider offering exactly one item.
    static func consent(
        contentTypeHint: ContentTypeHint? = Sample.contentTypeHint(),
        confirmedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ConfirmedConsent {
        guard let provider = SharedItemProvider(
            token: ProviderToken(rawValue: 1),
            itemCount: 1,
            contentTypeHint: contentTypeHint
        ) else {
            preconditionFailure("a one-item provider fixture must be constructible")
        }
        guard let consent = ConfirmedConsent(
            provider: provider,
            extensionExecutionPolicyID: artifactID("extension-execution-0001"),
            confirmedAt: confirmedAt
        ) else {
            preconditionFailure("consent for a one-item provider must be constructible")
        }
        return consent
    }

    /// A ticket whose fields are all supplied, for encoding and mutation tests.
    static func ticket(
        transferID: ShareTransferID = Sample.transferID(),
        sessionID: AnalysisSessionID = Sample.sessionID(),
        contentTypeHint: ContentTypeHint? = Sample.contentTypeHint(),
        byteCount: UInt64 = 1_024,
        sha256: DefAIkeDomain.SHA256Digest? = nil,
        preservationBasis: PreservationBasis = .providerDeclaredCurrentRepresentationOnly,
        extensionBuildID: AppBuildID = Sample.buildID(),
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ShareTransferTicket {
        guard let ticket = ShareTransferTicket(
            transferID: transferID,
            sessionID: sessionID,
            contentTypeHint: contentTypeHint,
            byteCount: byteCount,
            sha256: sha256 ?? StreamingSHA256.digest(of: Data("payload".utf8)),
            preservationStatus: preservationBasis.mostConservativeStatus,
            preservationBasis: preservationBasis,
            extensionBuildID: extensionBuildID,
            createdAt: createdAt
        ) else {
            preconditionFailure("the ticket fixture must be internally consistent")
        }
        return ticket
    }

    /// A storage key of the exact shape the real store generates.
    static func storageKey(_ raw: String) -> EphemeralStorageKey {
        guard let key = EphemeralStorageKey(raw) else {
            preconditionFailure("storage key is not canonical: \(raw)")
        }
        return key
    }
}

/// The wall-clock instant the transfer-store fixtures treat as "now".
let fixtureNow = Date(timeIntervalSince1970: 1_700_000_000)

extension SharedTransferStore {
    /// A transfer store over `store`, with synthetic policies and a fixed clock.
    static func test(
        over store: any EphemeralFileStoring,
        lifecyclePolicy: DataLifecyclePolicy = Sample.lifecyclePolicy(),
        extensionPolicy: ExtensionExecutionPolicy = Sample.extensionPolicy(),
        buildID: AppBuildID = Sample.buildID(),
        now: Date = fixtureNow,
        chunkSizeInBytes: Int = 64
    ) -> SharedTransferStore {
        SharedTransferStore(
            store: store,
            lifecyclePolicy: lifecyclePolicy,
            extensionPolicy: extensionPolicy,
            buildID: buildID,
            clock: FixedClock(now),
            chunkSizeInBytes: chunkSizeInBytes
        )
    }
}
