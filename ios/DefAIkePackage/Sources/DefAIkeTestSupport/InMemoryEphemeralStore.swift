import DefAIkeDomain
import Foundation

/// A bounded in-memory ``EphemeralFileStoring`` with no file system.
///
/// Faithful to the parts of the contract domain logic depends on:
///
///   * keys are store-assigned and random-looking, never caller-supplied;
///   * an object that was created and never finalized is not readable, so an interrupted
///     copy cannot be analyzed or promoted;
///   * a finalized object is immutable, so analyzed bytes cannot change underneath a
///     handle;
///   * ``move(_:to:)`` is atomic, so an observer sees an object in exactly one scope;
///   * digests are real SHA-256 computed while the chunks stream past; and
///   * ``deleteAll(in:reason:)`` is idempotent, reporting zero removals the second time.
///
/// It is bounded on purpose. A hostile or buggy caller cannot make a test allocate an
/// attacker-selected size: exceeding ``capacityInBytes`` is
/// ``EphemeralStoreError/capacityExceeded(scope:)``, which is also how a test exercises a
/// storage-limit path without a real disk.
///
/// Faults are programmable through ``failNextOperation(with:)`` and
/// ``failAllProtectionRequests(_:)`` so fault-injection tests can interrupt a copy at any
/// chunk boundary.
public actor InMemoryEphemeralStore: EphemeralFileStoring {
    private struct Object {
        var scope: EphemeralStorageScope
        var protection: FileProtectionLevel
        var bytes: [UInt8]
        var hasher: TestSHA256.Hasher
        var receipt: EphemeralWriteReceipt?

        var isFinalized: Bool { receipt != nil }
    }

    /// Total bytes the store will hold across every scope.
    ///
    /// A safety bound for tests, not an approved Resource Budget value. Two megabytes
    /// comfortably holds the bounded byte arrays a property test generates.
    public let capacityInBytes: Int

    private let clock: VirtualSessionClock

    private var objects: [EphemeralStorageKey: Object] = [:]
    private var nextKeyNumber = 1
    private var queuedFailures: [EphemeralStoreError] = []
    private var protectionFailure: FileProtectionLevel?

    public init(
        clock: VirtualSessionClock = VirtualSessionClock(),
        capacityInBytes: Int = 2 * 1024 * 1024
    ) {
        self.clock = clock
        self.capacityInBytes = capacityInBytes
    }

    // MARK: - Fault injection

    /// Makes the next store operation fail with `error`.
    ///
    /// Queued, so several failures can be scheduled to hit successive chunk writes.
    public func failNextOperation(with error: EphemeralStoreError) {
        queuedFailures.append(error)
    }

    /// Makes every request for `level` fail, so the fail-closed protection path is
    /// reachable without a device that refuses the level.
    public func failAllProtectionRequests(_ level: FileProtectionLevel) {
        protectionFailure = level
    }

    private func takeQueuedFailure() -> EphemeralStoreError? {
        guard !queuedFailures.isEmpty else { return nil }
        return queuedFailures.removeFirst()
    }

    // MARK: - Inspection

    /// Total bytes currently held.
    public var usedByteCount: Int {
        objects.values.reduce(0) { $0 + $1.bytes.count }
    }

    /// Keys created but never finalized: the incomplete-copy set.
    public var unfinalizedKeys: Set<EphemeralStorageKey> {
        Set(objects.filter { !$0.value.isFinalized }.map(\.key))
    }

    /// Bytes of a finalized object, bypassing the port's error handling.
    ///
    /// For assertions only. Returns `nil` for an unknown or unfinalized key, so a test
    /// cannot accidentally assert on a partial copy.
    public func finalizedBytes(_ key: EphemeralStorageKey) -> [UInt8]? {
        guard let object = objects[key], object.isFinalized else { return nil }
        return object.bytes
    }

    // MARK: - EphemeralFileStoring

    public func create(
        in scope: EphemeralStorageScope,
        protection: FileProtectionLevel
    ) throws(EphemeralStoreError) -> EphemeralStorageKey {
        if let failure = takeQueuedFailure() { throw failure }
        if protectionFailure == protection {
            throw .protectionUnavailable(protection)
        }
        let key = makeKey()
        guard objects[key] == nil else { throw .keyAlreadyInUse(key) }
        objects[key] = Object(
            scope: scope,
            protection: protection,
            bytes: [],
            hasher: TestSHA256.Hasher(),
            receipt: nil
        )
        return key
    }

    public func append(
        _ chunk: [UInt8],
        to key: EphemeralStorageKey
    ) throws(EphemeralStoreError) {
        if let failure = takeQueuedFailure() { throw failure }
        guard var object = objects[key] else { throw .notFound(key) }
        guard !object.isFinalized else { throw .alreadyFinalized(key) }
        guard usedByteCount + chunk.count <= capacityInBytes else {
            throw .capacityExceeded(scope: object.scope)
        }
        object.bytes.append(contentsOf: chunk)
        object.hasher.update(chunk)
        objects[key] = object
    }

    public func finalize(
        _ key: EphemeralStorageKey
    ) throws(EphemeralStoreError) -> EphemeralWriteReceipt {
        if let failure = takeQueuedFailure() { throw failure }
        guard var object = objects[key] else { throw .notFound(key) }
        if let existing = object.receipt { return existing }
        let receipt = EphemeralWriteReceipt(
            key: key,
            scope: object.scope,
            byteCount: UInt64(object.bytes.count),
            sha256: object.hasher.finalize(),
            protection: object.protection
        )
        object.receipt = receipt
        objects[key] = object
        return receipt
    }

    public func read(_ key: EphemeralStorageKey) throws(EphemeralStoreError) -> [UInt8] {
        if let failure = takeQueuedFailure() { throw failure }
        guard let object = objects[key] else { throw .notFound(key) }
        guard object.isFinalized else { throw .notFinalized(key) }
        return object.bytes
    }

    public func receipt(for key: EphemeralStorageKey) -> EphemeralWriteReceipt? {
        objects[key]?.receipt
    }

    public func move(
        _ key: EphemeralStorageKey,
        to scope: EphemeralStorageScope
    ) throws(EphemeralStoreError) {
        if let failure = takeQueuedFailure() { throw failure }
        guard var object = objects[key] else { throw .notFound(key) }
        guard let receipt = object.receipt else { throw .notFinalized(key) }
        // One assignment: no observable state has the object in both scopes or neither.
        object.scope = scope
        object.receipt = EphemeralWriteReceipt(
            key: receipt.key,
            scope: scope,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256,
            protection: receipt.protection
        )
        objects[key] = object
    }

    public func keys(in scope: EphemeralStorageScope) -> Set<EphemeralStorageKey> {
        Set(objects.filter { $0.value.scope == scope }.map(\.key))
    }

    public func deleteAll(
        in scope: EphemeralStorageScope,
        reason: SessionCleanupReason
    ) throws(EphemeralStoreError) -> EphemeralDeletionReceipt {
        if let failure = takeQueuedFailure() { throw failure }
        let doomed = keys(in: scope)
        for key in doomed {
            objects.removeValue(forKey: key)
        }
        return EphemeralDeletionReceipt(
            scope: scope,
            reason: reason,
            removedObjectCount: doomed.count,
            completedAt: clock.wallClockNow
        )
    }

    public func occupiedScopes() -> Set<EphemeralStorageScope> {
        Set(objects.values.map(\.scope))
    }

    // MARK: - Helpers

    /// Writes one complete object in a single call, for tests that do not care about
    /// chunking. Returns the receipt so a handle can be built from it.
    public func writeComplete(
        _ bytes: [UInt8],
        in scope: EphemeralStorageScope,
        protection: FileProtectionLevel = .complete,
        chunkSize: Int = 64
    ) throws(EphemeralStoreError) -> EphemeralWriteReceipt {
        let key = try create(in: scope, protection: protection)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + max(chunkSize, 1), bytes.count)
            try append(Array(bytes[offset..<end]), to: key)
            offset = end
        }
        return try finalize(key)
    }

    private func makeKey() -> EphemeralStorageKey {
        // Deliberately opaque and non-user-derived, matching the real store's random
        // names. Sequential rather than random so failures reproduce.
        let raw = "eph-\(String(format: "%08x", nextKeyNumber))"
        nextKeyNumber += 1
        guard let key = EphemeralStorageKey(raw) else {
            preconditionFailure("generated store key is not canonical: \(raw)")
        }
        return key
    }
}
