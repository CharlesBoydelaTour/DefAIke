import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeSharedTransfer

/// The real store against the same contract the in-memory double satisfies.
///
/// The double is what domain properties run against, so the two must agree on every rule
/// those properties lean on: an unfinalized object is unreadable and unpromotable, a
/// finalized one is immutable, a move is lossless, and deletion is idempotent. Anything the
/// double enforces and the adapter does not would make those properties pass for the wrong
/// reason.
///
/// These tests use the real file system and the real protection applier. That is the point:
/// `PlatformDataProtection` is the shipping code path, and running it here means it is
/// compiled and exercised rather than hidden behind conditional compilation.
@Suite("Protected ephemeral file store")
struct ProtectedEphemeralFileStoreTests {

    private func makeStore(root: URL) -> ProtectedEphemeralFileStore {
        ProtectedEphemeralFileStore(
            configuration: .test(root: root),
            protection: PlatformDataProtection(),
            clock: FixedClock()
        )
    }

    /// Writes one complete object through the three-step streaming sequence.
    private func writeComplete(
        _ bytes: [UInt8],
        in scope: EphemeralStorageScope,
        to store: ProtectedEphemeralFileStore,
        protection: FileProtectionLevel = .complete,
        chunkSize: Int = 64
    ) async throws -> EphemeralWriteReceipt {
        let key = try await store.create(in: scope, protection: protection)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + max(chunkSize, 1), bytes.count)
            try await store.append(Array(bytes[offset..<end]), to: key)
            offset = end
        }
        return try await store.finalize(key)
    }

    // MARK: - Measurement

    @Test("A finalized object reports the bytes and digest that were written")
    func finalizedReceiptDescribesWrittenBytes() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let scope = EphemeralStorageScope.session(Sample.sessionID())
            let bytes = Sample.bytes(count: 3_000)

            let receipt = try await writeComplete(bytes, in: scope, to: store)

            #expect(receipt.byteCount == 3_000)
            #expect(receipt.sha256 == StreamingSHA256.digest(of: Data(bytes)))
            #expect(receipt.scope == scope)
            #expect(receipt.protection == .complete)
            #expect(try await store.read(receipt.key) == bytes)
        }
    }

    @Test(
        "Chunk boundaries do not change the finalized bytes, count, or digest",
        arguments: [1, 3, 17, 256, 4_096, 9_999]
    )
    func chunkingDoesNotChangeTheObject(chunkSize: Int) async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let bytes = Sample.bytes(count: 2_048)

            let receipt = try await writeComplete(
                bytes,
                in: .session(Sample.sessionID()),
                to: store,
                chunkSize: chunkSize
            )

            #expect(receipt.byteCount == 2_048)
            #expect(receipt.sha256 == StreamingSHA256.digest(of: Data(bytes)))
            #expect(try await store.read(receipt.key) == bytes)
        }
    }

    @Test("Store-assigned keys are unique and reveal nothing about their scope")
    func keysAreRandomAndUnique() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let session = Sample.sessionID("session-secret-0001")
            var keys: Set<EphemeralStorageKey> = []
            for _ in 0..<25 {
                keys.insert(try await store.create(in: .session(session), protection: .complete))
            }
            #expect(keys.count == 25)
            for key in keys {
                let isHexadecimal = key.rawValue.allSatisfy { $0.isHexDigit }
                #expect(key.rawValue.count == 32)
                #expect(isHexadecimal)
                #expect(!key.rawValue.contains(session.rawValue))
            }
        }
    }

    @Test("No stored path contains the scope identifier")
    func pathsAreNotIdentifierDerived() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let session = Sample.sessionID("session-correlatable-0001")
            _ = try await writeComplete(
                Sample.bytes(count: 32),
                in: .session(session),
                to: store
            )

            let contents = FileManager.default
                .enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { ($0 as? URL)?.path } ?? []
            #expect(!contents.isEmpty)
            for path in contents {
                #expect(!path.contains(session.rawValue))
            }
        }
    }

    // MARK: - Incomplete copies

    @Test("An unfinalized object is not readable and has no receipt")
    func unfinalizedObjectIsNotReadable() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let scope = EphemeralStorageScope.session(Sample.sessionID())
            let key = try await store.create(in: scope, protection: .complete)
            try await store.append(Sample.bytes(count: 64), to: key)

            await #expect(throws: EphemeralStoreError.notFinalized(key)) {
                _ = try await store.read(key)
            }
            #expect(await store.receipt(for: key) == nil)
            #expect(await store.unfinalizedKeys == [key])
            // The key is still owned, so cleanup can find and remove it.
            #expect(await store.keys(in: scope) == [key])
        }
    }

    @Test("An unfinalized object cannot be promoted to another scope")
    func unfinalizedObjectCannotBePromoted() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let transfer = Sample.transferID()
            let key = try await store.create(
                in: .transfer(transfer, .staging),
                protection: .complete
            )
            try await store.append(Sample.bytes(count: 16), to: key)

            await #expect(throws: EphemeralStoreError.notFinalized(key)) {
                try await store.move(key, to: .transfer(transfer, .ready))
            }
            #expect(await store.keys(in: .transfer(transfer, .ready)).isEmpty)
        }
    }

    @Test("A finalized object cannot be appended to")
    func finalizedObjectIsImmutable() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let receipt = try await writeComplete(
                Sample.bytes(count: 32),
                in: .session(Sample.sessionID()),
                to: store
            )

            await #expect(throws: EphemeralStoreError.alreadyFinalized(receipt.key)) {
                try await store.append([0xFF], to: receipt.key)
            }
            #expect(try await store.read(receipt.key) == Sample.bytes(count: 32))
        }
    }

    @Test("Finalizing twice returns the same receipt")
    func finalizeIsIdempotent() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let bytes = Sample.bytes(count: 128)
            let first = try await writeComplete(bytes, in: .session(Sample.sessionID()), to: store)
            let second = try await store.finalize(first.key)
            #expect(first == second)
        }
    }

    @Test("An abandoned partial object cannot be finalized by a later attempt")
    func abandonedPartialObjectCannotBeFinalized() async throws {
        try await withTemporaryRoot { root in
            let writer = makeStore(root: root)
            let scope = EphemeralStorageScope.session(Sample.sessionID())
            let key = try await writer.create(in: scope, protection: .complete)
            try await writer.append(Sample.bytes(count: 128), to: key)

            // Stands in for the process that was terminated mid-copy: the object is on
            // disk, but the hash that describes it is not.
            let reader = makeStore(root: root)
            await #expect(throws: EphemeralStoreError.notFinalized(key)) {
                _ = try await reader.finalize(key)
            }
            #expect(await reader.receipt(for: key) == nil)
            // Still owned, so cleanup removes it.
            #expect(await reader.keys(in: scope) == [key])
        }
    }

    @Test("An unknown key is not found rather than fabricated")
    func unknownKeyIsNotFound() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let unknown = try #require(EphemeralStorageKey("0123456789abcdef0123456789abcdef"))

            await #expect(throws: EphemeralStoreError.notFound(unknown)) {
                _ = try await store.read(unknown)
            }
            #expect(await store.receipt(for: unknown) == nil)
            await #expect(throws: EphemeralStoreError.notFound(unknown)) {
                try await store.append([1], to: unknown)
            }
        }
    }

    @Test(
        "A traversal-shaped key addresses nothing",
        arguments: ["..", ".", "../../etc/passwd", "0123456789abcdef0123456789abcdeg"]
    )
    func traversalShapedKeyIsRejected(raw: String) async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            _ = try await writeComplete(
                Sample.bytes(count: 16),
                in: .session(Sample.sessionID()),
                to: store
            )
            // A canonical identifier may contain `.` and `/`, so these are constructible.
            // They must still resolve to nothing rather than to a path outside a scope.
            let key = try #require(EphemeralStorageKey(raw))

            await #expect(throws: EphemeralStoreError.notFound(key)) {
                _ = try await store.read(key)
            }
            #expect(await store.receipt(for: key) == nil)
        }
    }

    // MARK: - Protection

    @Test(
        "Every object carries the protection level it was created with",
        arguments: FileProtectionLevel.allCases
    )
    func protectionIsAppliedAndReported(level: FileProtectionLevel) async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let receipt = try await writeComplete(
                Sample.bytes(count: 64),
                in: .session(Sample.sessionID()),
                to: store,
                protection: level
            )
            #expect(receipt.protection == level)

            let applier = PlatformDataProtection()
            let files = FileManager.default
                .enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []
            let payloads = files.filter { $0.lastPathComponent == "payload" }
            #expect(payloads.count == 1)
            for payload in payloads {
                #expect(applier.appliedLevel(ofItemAt: payload) == level)
            }
        }
    }

    @Test("A protection level that cannot be applied fails closed and stores nothing")
    func unavailableProtectionFailsClosed() async throws {
        try await withTemporaryRoot { root in
            let store = ProtectedEphemeralFileStore(
                configuration: .test(root: root, containerProtection: .completeUnlessOpen),
                protection: RefusingDataProtection(refusedLevel: .complete),
                clock: FixedClock()
            )
            let scope = EphemeralStorageScope.session(Sample.sessionID())

            await #expect(throws: EphemeralStoreError.protectionUnavailable(.complete)) {
                _ = try await store.create(in: scope, protection: .complete)
            }
            #expect(await store.keys(in: scope).isEmpty)
            #expect(await store.occupiedScopes().isEmpty)
        }
    }

    @Test("The store reports honestly whether the platform enforces data protection")
    func enforcementIsReportedHonestly() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            #if targetEnvironment(simulator)
            // The Simulator accepts the attribute and reports no protection key back, so it
            // enforces nothing. Asserted separately from the device case rather than folded into
            // `os(iOS)`: a simulator run must never satisfy a device privacy gate, and this is
            // the property `ShareExtensionStartupGate`'s gate 7 reads to refuse there.
            #expect(await store.enforcesDataProtection == false)
            #elseif os(iOS)
            #expect(await store.enforcesDataProtection)
            #else
            // A development host accepts and reports the attribute without enforcing it, so
            // a host run is never Requirement 9.6 evidence.
            #expect(await store.enforcesDataProtection == false)
            #endif
        }
    }

    // MARK: - Ownership

    @Test("Moving an object changes its owner without changing its bytes or digest")
    func moveIsLossless() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let transfer = Sample.transferID()
            let staging = EphemeralStorageScope.transfer(transfer, .staging)
            let ready = EphemeralStorageScope.transfer(transfer, .ready)
            let bytes = Sample.bytes(count: 1_500)

            let receipt = try await writeComplete(bytes, in: staging, to: store)
            try await store.move(receipt.key, to: ready)

            #expect(await store.keys(in: staging).isEmpty)
            #expect(await store.keys(in: ready) == [receipt.key])
            let moved = try #require(await store.receipt(for: receipt.key))
            #expect(moved.scope == ready)
            #expect(moved.sha256 == receipt.sha256)
            #expect(moved.byteCount == receipt.byteCount)
            #expect(moved.protection == receipt.protection)
            #expect(try await store.read(receipt.key) == bytes)
        }
    }

    @Test("An object is never visible in two scopes at once")
    func moveLeavesExactlyOneOwner() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let transfer = Sample.transferID()
            let receipt = try await writeComplete(
                Sample.bytes(count: 200),
                in: .transfer(transfer, .staging),
                to: store
            )

            try await store.move(receipt.key, to: .transfer(transfer, .ready))
            #expect(await store.occupiedScopes() == [.transfer(transfer, .ready)])

            try await store.move(receipt.key, to: .transfer(transfer, .claimed))
            #expect(await store.occupiedScopes() == [.transfer(transfer, .claimed)])
        }
    }

    // MARK: - Capacity

    @Test("Exceeding capacity fails rather than writing past the limit")
    func capacityIsBounded() async throws {
        try await withTemporaryRoot { root in
            let store = ProtectedEphemeralFileStore(
                configuration: .test(root: root, capacityInBytes: 128),
                protection: PlatformDataProtection(),
                clock: FixedClock()
            )
            let scope = EphemeralStorageScope.session(Sample.sessionID())

            await #expect(throws: EphemeralStoreError.capacityExceeded(scope: scope)) {
                _ = try await writeComplete(
                    Sample.bytes(count: 400),
                    in: scope,
                    to: store,
                    chunkSize: 64
                )
            }
            let used = try await store.usedByteCount()
            #expect(used <= 128)
        }
    }

    @Test("A budget with a byte temporary-storage limit configures the capacity")
    func capacityComesFromTheBudget() async throws {
        try await withTemporaryRoot { root in
            let configuration = try ProtectedEphemeralFileStore.configuration(
                rootDirectory: root,
                budget: Sample.budget(temporaryStorageBytes: 4_096.75),
                containerProtection: .complete
            )
            // Truncated, never rounded up: an enforced ceiling must not exceed the
            // approved one.
            #expect(configuration.capacityInBytes == 4_096)
            #expect(configuration.rootDirectory == root)
        }
    }

    @Test("A budget whose temporary-storage limit is not in bytes configures nothing")
    func nonByteLimitIsRefused() async throws {
        try await withTemporaryRoot { root in
            let budget = Sample.budget(
                temporaryStorageBytes: 4_096,
                temporaryStorageUnit: .milliseconds
            )
            #expect(
                throws: ProtectedEphemeralFileStore.ConfigurationError
                    .temporaryStorageLimitUnavailable(budget.id)
            ) {
                _ = try ProtectedEphemeralFileStore.configuration(
                    rootDirectory: root,
                    budget: budget,
                    containerProtection: .complete
                )
            }
        }
    }

    @Test("A sub-byte temporary-storage limit configures nothing")
    func subByteLimitIsRefused() async throws {
        try await withTemporaryRoot { root in
            let budget = Sample.budget(temporaryStorageBytes: 0.5)
            #expect(
                throws: ProtectedEphemeralFileStore.ConfigurationError
                    .temporaryStorageLimitUnavailable(budget.id)
            ) {
                _ = try ProtectedEphemeralFileStore.configuration(
                    rootDirectory: root,
                    budget: budget,
                    containerProtection: .complete
                )
            }
        }
    }

    // MARK: - Deletion

    @Test("Deleting a scope empties it and repeating the deletion removes nothing")
    func deletionIsCompleteAndIdempotent() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let scope = EphemeralStorageScope.session(Sample.sessionID())
            _ = try await writeComplete(Sample.bytes(count: 64), in: scope, to: store)
            _ = try await writeComplete(
                Sample.bytes(count: 64, seed: 9),
                in: scope,
                to: store
            )

            let first = try await store.deleteAll(in: scope, reason: .completed)
            #expect(first.removedObjectCount == 2)
            #expect(first.reason == .completed)
            #expect(first.completedAt == FixedClock().instant)
            #expect(await store.keys(in: scope).isEmpty)
            #expect(await store.occupiedScopes().isEmpty)

            let second = try await store.deleteAll(in: scope, reason: .completed)
            #expect(second.removedObjectCount == 0)
            let third = try await store.deleteAll(in: scope, reason: .abandoned)
            #expect(third.removedObjectCount == 0)
        }
    }

    @Test("Deleting a scope removes an incomplete copy too")
    func deletionRemovesIncompleteCopies() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let scope = EphemeralStorageScope.session(Sample.sessionID())
            let key = try await store.create(in: scope, protection: .complete)
            try await store.append(Sample.bytes(count: 100), to: key)

            let receipt = try await store.deleteAll(in: scope, reason: .interrupted)

            #expect(receipt.removedObjectCount == 1)
            #expect(await store.unfinalizedKeys.isEmpty)
            #expect(await store.keys(in: scope).isEmpty)
            let used = try await store.usedByteCount()
            #expect(used == 0)
        }
    }

    @Test("Deleting one scope leaves other scopes untouched")
    func deletionIsScoped() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let doomed = EphemeralStorageScope.session(Sample.sessionID("session-0001"))
            let kept = EphemeralStorageScope.session(Sample.sessionID("session-0002"))
            _ = try await writeComplete(Sample.bytes(count: 16), in: doomed, to: store)
            let keptReceipt = try await writeComplete(
                Sample.bytes(count: 16),
                in: kept,
                to: store
            )

            _ = try await store.deleteAll(in: doomed, reason: .cancelled)

            #expect(await store.keys(in: kept) == [keptReceipt.key])
            #expect(await store.occupiedScopes() == [kept])
        }
    }

    @Test("Startup cleanup removes every scope and is idempotent")
    func deleteEverythingClearsTheStore() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            _ = try await writeComplete(
                Sample.bytes(count: 32),
                in: .session(Sample.sessionID()),
                to: store
            )
            _ = try await writeComplete(
                Sample.bytes(count: 32),
                in: .transfer(Sample.transferID(), .ready),
                to: store
            )

            let receipts = try await store.deleteEverything(reason: .abandoned)
            #expect(receipts.count == 2)
            #expect(receipts.allSatisfy { $0.reason == .abandoned })
            #expect(await store.occupiedScopes().isEmpty)
            let used = try await store.usedByteCount()
            #expect(used == 0)

            #expect(try await store.deleteEverything(reason: .abandoned).isEmpty)
        }
    }

    // MARK: - Cross-process visibility

    @Test("A second store over the same root sees finalized objects but not partial ones")
    func finishedObjectsSurviveANewStoreInstance() async throws {
        try await withTemporaryRoot { root in
            let writer = makeStore(root: root)
            let scope = EphemeralStorageScope.session(Sample.sessionID())
            let bytes = Sample.bytes(count: 900)
            let receipt = try await writeComplete(bytes, in: scope, to: writer)
            let partialKey = try await writer.create(in: scope, protection: .complete)
            try await writer.append(Sample.bytes(count: 50), to: partialKey)

            // Stands in for the claiming process: same root, no shared memory.
            let reader = makeStore(root: root)

            #expect(await reader.occupiedScopes() == [scope])
            #expect(await reader.keys(in: scope) == [receipt.key, partialKey])
            #expect(try await reader.read(receipt.key) == bytes)
            #expect(await reader.receipt(for: receipt.key) == receipt)

            await #expect(throws: EphemeralStoreError.notFinalized(partialKey)) {
                _ = try await reader.read(partialKey)
            }
            // The partial object's in-flight hash belonged to the writer, so it cannot be
            // finished by anyone else.
            await #expect(throws: EphemeralStoreError.storeUnavailable) {
                try await reader.append([1, 2, 3], to: partialKey)
            }
        }
    }
}
