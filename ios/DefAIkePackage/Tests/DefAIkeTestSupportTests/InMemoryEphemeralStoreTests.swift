import DefAIkeDomain
import Testing

@testable import DefAIkeTestSupport

/// Checks the store double actually enforces the contract later properties lean on.
///
/// A fake that quietly let a partial copy be read, or that lost bytes across a scope move,
/// would make Properties 5, 6, and 25 pass for the wrong reason. These are tests of the
/// double, not of Foundation: real file coordination and real data protection are
/// integration concerns (task 4.10).
@Suite("In-memory ephemeral store")
struct InMemoryEphemeralStoreTests {

    private func sessionScope(
        _ raw: String = "session-0001"
    ) -> EphemeralStorageScope {
        .session(PortValue.sessionID(raw))
    }

    @Test("A finalized object reports the bytes and digest that were written")
    func finalizedReceiptDescribesWrittenBytes() async throws {
        let store = InMemoryEphemeralStore()
        let bytes = PortValue.bytes(count: 300)

        let receipt = try await store.writeComplete(bytes, in: sessionScope())

        #expect(receipt.byteCount == 300)
        #expect(receipt.sha256 == TestSHA256.digest(of: bytes))
        #expect(receipt.protection == .complete)
        #expect(try await store.read(receipt.key) == bytes)
    }

    @Test("An unfinalized object is not readable")
    func unfinalizedObjectIsNotReadable() async throws {
        let store = InMemoryEphemeralStore()
        let key = try await store.create(in: sessionScope(), protection: .complete)
        try await store.append(PortValue.bytes(count: 64), to: key)

        await #expect(throws: EphemeralStoreError.notFinalized(key)) {
            _ = try await store.read(key)
        }
        #expect(await store.unfinalizedKeys == [key])
        #expect(await store.receipt(for: key) == nil)
    }

    @Test("A finalized object cannot be appended to")
    func finalizedObjectIsImmutable() async throws {
        let store = InMemoryEphemeralStore()
        let receipt = try await store.writeComplete(PortValue.bytes(count: 32), in: sessionScope())

        await #expect(throws: EphemeralStoreError.alreadyFinalized(receipt.key)) {
            try await store.append([0xFF], to: receipt.key)
        }
    }

    @Test("Exceeding capacity fails rather than allocating")
    func capacityIsBounded() async throws {
        let store = InMemoryEphemeralStore(capacityInBytes: 128)
        let scope = sessionScope()

        await #expect(throws: EphemeralStoreError.capacityExceeded(scope: scope)) {
            _ = try await store.writeComplete(PortValue.bytes(count: 200), in: scope)
        }
    }

    @Test("A requested protection level that cannot be applied fails closed")
    func unavailableProtectionFailsClosed() async throws {
        let store = InMemoryEphemeralStore()
        await store.failAllProtectionRequests(.complete)

        await #expect(throws: EphemeralStoreError.protectionUnavailable(.complete)) {
            _ = try await store.create(in: sessionScope(), protection: .complete)
        }
        #expect(await store.occupiedScopes().isEmpty)
    }

    @Test("Moving an object changes its owner without changing its bytes or digest")
    func moveIsAtomicAndLossless() async throws {
        let store = InMemoryEphemeralStore()
        let bytes = PortValue.bytes(count: 256)
        let transferID = PortValue.transferID()
        let staging = EphemeralStorageScope.transfer(transferID, .staging)
        let ready = EphemeralStorageScope.transfer(transferID, .ready)

        let receipt = try await store.writeComplete(bytes, in: staging)
        try await store.move(receipt.key, to: ready)

        #expect(await store.keys(in: staging).isEmpty)
        #expect(await store.keys(in: ready) == [receipt.key])
        let moved = try #require(await store.receipt(for: receipt.key))
        #expect(moved.sha256 == receipt.sha256)
        #expect(moved.byteCount == receipt.byteCount)
        #expect(moved.scope == ready)
        #expect(try await store.read(receipt.key) == bytes)
    }

    @Test("An unfinalized object cannot be promoted")
    func unfinalizedObjectCannotBePromoted() async throws {
        let store = InMemoryEphemeralStore()
        let transferID = PortValue.transferID()
        let key = try await store.create(
            in: .transfer(transferID, .staging),
            protection: .complete
        )
        try await store.append(PortValue.bytes(count: 16), to: key)

        await #expect(throws: EphemeralStoreError.notFinalized(key)) {
            try await store.move(key, to: .transfer(transferID, .ready))
        }
        #expect(await store.keys(in: .transfer(transferID, .ready)).isEmpty)
    }

    @Test("Deleting a scope empties it and repeating the deletion removes nothing")
    func deletionIsCompleteAndIdempotent() async throws {
        let store = InMemoryEphemeralStore()
        let scope = sessionScope()
        _ = try await store.writeComplete(PortValue.bytes(count: 64), in: scope)
        _ = try await store.writeComplete(PortValue.bytes(count: 64, seed: 9), in: scope)

        let first = try await store.deleteAll(in: scope, reason: .completed)
        #expect(first.removedObjectCount == 2)
        #expect(await store.keys(in: scope).isEmpty)
        #expect(await store.occupiedScopes().isEmpty)

        let second = try await store.deleteAll(in: scope, reason: .completed)
        #expect(second.removedObjectCount == 0)
    }

    @Test("Deleting one scope leaves other scopes untouched")
    func deletionIsScoped() async throws {
        let store = InMemoryEphemeralStore()
        let kept = sessionScope("session-0002")
        _ = try await store.writeComplete(PortValue.bytes(count: 16), in: sessionScope())
        let keptReceipt = try await store.writeComplete(PortValue.bytes(count: 16), in: kept)

        _ = try await store.deleteAll(in: sessionScope(), reason: .cancelled)

        #expect(await store.keys(in: kept) == [keptReceipt.key])
    }

    @Test("A queued failure interrupts a copy and leaves the object unfinalized")
    func injectedFailureLeavesIncompleteCopy() async throws {
        let store = InMemoryEphemeralStore()
        let scope = sessionScope()
        let key = try await store.create(in: scope, protection: .complete)
        await store.failNextOperation(with: .storeUnavailable)

        await #expect(throws: EphemeralStoreError.storeUnavailable) {
            try await store.append(PortValue.bytes(count: 8), to: key)
        }
        #expect(await store.unfinalizedKeys == [key])
        #expect(await store.finalizedBytes(key) == nil)
    }

    @Test("Store-assigned keys are unique")
    func keysAreUnique() async throws {
        let store = InMemoryEphemeralStore()
        let scope = sessionScope()
        var keys: Set<EphemeralStorageKey> = []
        for _ in 0..<25 {
            keys.insert(try await store.create(in: scope, protection: .complete))
        }
        #expect(keys.count == 25)
    }
}
