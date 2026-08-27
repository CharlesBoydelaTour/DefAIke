import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeSharedTransfer

/// The streaming copy that turns a provider representation into retained encoded bytes.
///
/// The rules under test are the ones Requirements 2.9 through 2.13 make structural: the copy
/// is byte-for-byte identical, the provider's file is untouched, the preservation status is
/// the most conservative one its basis supports, the result is a handle rather than bytes,
/// and a failed copy leaves nothing behind.
@Suite("Encoded asset retention")
struct EncodedAssetRetentionTests {

    private func makeStore(
        root: URL,
        capacityInBytes: UInt64 = testCapacityInBytes
    ) -> ProtectedEphemeralFileStore {
        ProtectedEphemeralFileStore(
            configuration: .test(root: root, capacityInBytes: capacityInBytes),
            protection: PlatformDataProtection(),
            clock: FixedClock()
        )
    }

    // MARK: - Byte identity

    @Test("The retained copy is byte-for-byte identical to the provider representation")
    func copyIsByteForByteIdentical() async throws {
        try await withTemporaryRoot { root in
            let bytes = Sample.bytes(count: 200_000)
            let source = try makeProviderFile(bytes)
            defer { removeProviderFile(source) }

            let store = makeStore(root: root)
            let retainer = EncodedAssetRetainer(store: store)
            let asset = try await retainer.retainAsset(
                ofFileAt: source,
                route: .photosPicker,
                for: Sample.sessionID(),
                basis: .providerDeclaredOriginalRepresentation,
                contentTypeHint: Sample.contentTypeHint(),
                protection: .complete
            )

            #expect(asset.byteCount == UInt64(bytes.count))
            #expect(asset.sha256 == StreamingSHA256.digest(of: Data(bytes)))
            #expect(try await store.read(asset.handle.storageKey) == bytes)
        }
    }

    @Test(
        "Every buffer size produces the same retained bytes, count, and digest",
        arguments: [1, 7, 64, 1_024, 65_536, 1_000_000]
    )
    func bufferSizeDoesNotChangeTheCopy(chunkSize: Int) async throws {
        try await withTemporaryRoot { root in
            let bytes = Sample.bytes(count: 20_001)
            let source = try makeProviderFile(bytes)
            defer { removeProviderFile(source) }

            let store = makeStore(root: root)
            let retainer = EncodedAssetRetainer(store: store, chunkSizeInBytes: chunkSize)
            let receipt = try await retainer.retainCopy(
                ofFileAt: source,
                into: .session(Sample.sessionID()),
                protection: .complete
            )

            #expect(receipt.byteCount == UInt64(bytes.count))
            #expect(receipt.sha256 == StreamingSHA256.digest(of: Data(bytes)))
            #expect(try await store.read(receipt.key) == bytes)
        }
    }

    @Test("A nonpositive buffer size still terminates and copies correctly")
    func nonpositiveBufferSizeIsClamped() async throws {
        try await withTemporaryRoot { root in
            let bytes = Sample.bytes(count: 300)
            let source = try makeProviderFile(bytes)
            defer { removeProviderFile(source) }

            let store = makeStore(root: root)
            let retainer = EncodedAssetRetainer(store: store, chunkSizeInBytes: 0)
            let receipt = try await retainer.retainCopy(
                ofFileAt: source,
                into: .session(Sample.sessionID()),
                protection: .complete
            )

            #expect(receipt.byteCount == 300)
            #expect(try await store.read(receipt.key) == bytes)
        }
    }

    @Test("The provider representation is left exactly as it was")
    func providerRepresentationIsUnchanged() async throws {
        try await withTemporaryRoot { root in
            let bytes = Sample.bytes(count: 5_000)
            let source = try makeProviderFile(bytes)
            defer { removeProviderFile(source) }
            let before = try FileManager.default.attributesOfItem(atPath: source.path)

            let retainer = EncodedAssetRetainer(store: makeStore(root: root))
            _ = try await retainer.retainCopy(
                ofFileAt: source,
                into: .session(Sample.sessionID()),
                protection: .complete
            )

            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(try Array(Data(contentsOf: source)) == bytes)
            let after = try FileManager.default.attributesOfItem(atPath: source.path)
            #expect(after[.size] as? NSNumber == before[.size] as? NSNumber)
            #expect(after[.modificationDate] as? Date == before[.modificationDate] as? Date)
        }
    }

    @Test("The retained object is protected at the requested level")
    func retainedObjectIsProtected() async throws {
        try await withTemporaryRoot { root in
            let source = try makeProviderFile(Sample.bytes(count: 128))
            defer { removeProviderFile(source) }

            let retainer = EncodedAssetRetainer(store: makeStore(root: root))
            let receipt = try await retainer.retainCopy(
                ofFileAt: source,
                into: .transfer(Sample.transferID(), .staging),
                protection: .completeUnlessOpen
            )

            #expect(receipt.protection == .completeUnlessOpen)
            let payloads = FileManager.default
                .enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.lastPathComponent == "payload" } ?? []
            #expect(payloads.count == 1)
            for payload in payloads {
                #expect(
                    PlatformDataProtection().appliedLevel(ofItemAt: payload)
                        == .completeUnlessOpen
                )
            }
        }
    }

    // MARK: - Handles, not bytes

    @Test("Retention yields a handle whose measurements match the stored object")
    func retentionYieldsAHandle() async throws {
        try await withTemporaryRoot { root in
            let bytes = Sample.bytes(count: 4_096)
            let source = try makeProviderFile(bytes)
            defer { removeProviderFile(source) }

            let session = Sample.sessionID()
            let store = makeStore(root: root)
            let retainer = EncodedAssetRetainer(store: store)
            let asset = try await retainer.retainAsset(
                ofFileAt: source,
                route: .shareExtension,
                for: session,
                basis: .preservationHistoryNotEstablished,
                contentTypeHint: nil,
                protection: .complete
            )

            #expect(asset.handle.sessionID == session)
            #expect(asset.route == .shareExtension)
            #expect(asset.contentTypeHint == nil)
            // The handle's measurements are the store's, so they cannot drift from the
            // object they name.
            let stored = try #require(await store.receipt(for: asset.handle.storageKey))
            #expect(stored.byteCount == asset.byteCount)
            #expect(stored.sha256 == asset.sha256)
            #expect(stored.protection == asset.handle.protection)
            #expect(stored.scope == .session(session))
        }
    }

    @Test("Both downstream consumers read one object, so the sequences cannot diverge")
    func oneObjectServesEveryConsumer() async throws {
        try await withTemporaryRoot { root in
            let bytes = Sample.bytes(count: 9_000)
            let source = try makeProviderFile(bytes)
            defer { removeProviderFile(source) }

            let store = makeStore(root: root)
            let retainer = EncodedAssetRetainer(store: store)
            let asset = try await retainer.retainAsset(
                ofFileAt: source,
                route: .photosPicker,
                for: Sample.sessionID(),
                basis: .providerDeclaredOriginalRepresentation,
                contentTypeHint: Sample.contentTypeHint(),
                protection: .complete
            )

            // Stands in for the Input Validator and the Provenance Analyzer: one key, one
            // finalized immutable object, and only one object in the session's scope.
            let validatorBytes = try await store.read(asset.handle.storageKey)
            let provenanceBytes = try await store.read(asset.handle.storageKey)
            #expect(validatorBytes == provenanceBytes)
            #expect(validatorBytes == bytes)
            #expect(await store.keys(in: .session(asset.sessionID)) == [asset.handle.storageKey])
        }
    }

    // MARK: - Conservative preservation status

    @Test(
        "The recorded status is the most conservative one the basis supports",
        arguments: PreservationBasis.allCases
    )
    func statusIsDerivedFromTheBasis(basis: PreservationBasis) async throws {
        try await withTemporaryRoot { root in
            let source = try makeProviderFile(Sample.bytes(count: 512))
            defer { removeProviderFile(source) }

            let retainer = EncodedAssetRetainer(store: makeStore(root: root))
            let asset = try await retainer.retainAsset(
                ofFileAt: source,
                route: .photosPicker,
                for: Sample.sessionID(),
                basis: basis,
                contentTypeHint: nil,
                protection: .complete
            )

            #expect(asset.preservationBasis == basis)
            #expect(asset.preservationStatus == basis.mostConservativeStatus)
            #expect(basis.supports(asset.preservationStatus))
        }
    }

    @Test("Only an explicit original-representation basis reaches original bytes")
    func originalBytesRequiresAnOriginalBasis() async throws {
        try await withTemporaryRoot { root in
            let source = try makeProviderFile(Sample.bytes(count: 64))
            defer { removeProviderFile(source) }

            let retainer = EncodedAssetRetainer(store: makeStore(root: root))
            var statusesByBasis: [PreservationBasis: BytePreservationStatus] = [:]
            for (index, basis) in PreservationBasis.allCases.enumerated() {
                let asset = try await retainer.retainAsset(
                    ofFileAt: source,
                    route: .photosPicker,
                    for: Sample.sessionID("session-\(index)"),
                    basis: basis,
                    contentTypeHint: nil,
                    protection: .complete
                )
                statusesByBasis[basis] = asset.preservationStatus
            }

            #expect(statusesByBasis[.providerDeclaredOriginalRepresentation] == .originalBytes)
            #expect(
                statusesByBasis[.providerDeclaredTransformedRepresentation]
                    == .platformTransformedCopy
            )
            #expect(statusesByBasis[.providerDeclaredCurrentRepresentationOnly] == .unknown)
            #expect(statusesByBasis[.preservationHistoryNotEstablished] == .unknown)
        }
    }

    // MARK: - Failure leaves nothing behind

    @Test("An empty provider representation is refused and stores nothing")
    func emptySourceIsRefused() async throws {
        try await withTemporaryRoot { root in
            let source = try makeProviderFile([])
            defer { removeProviderFile(source) }

            let store = makeStore(root: root)
            let retainer = EncodedAssetRetainer(store: store)
            let scope = EphemeralStorageScope.session(Sample.sessionID())

            await #expect(throws: EncodedAssetRetentionError.emptySource) {
                _ = try await retainer.retainCopy(
                    ofFileAt: source,
                    into: scope,
                    protection: .complete
                )
            }
            #expect(await store.occupiedScopes().isEmpty)
            #expect(await store.keys(in: scope).isEmpty)
        }
    }

    @Test("A missing provider representation is refused and stores nothing")
    func missingSourceIsRefused() async throws {
        try await withTemporaryRoot { root in
            let source = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "absent-\(UUID().uuidString).bin")

            let store = makeStore(root: root)
            let retainer = EncodedAssetRetainer(store: store)

            await #expect(throws: EncodedAssetRetentionError.sourceUnreadable) {
                _ = try await retainer.retainCopy(
                    ofFileAt: source,
                    into: .session(Sample.sessionID()),
                    protection: .complete
                )
            }
            #expect(await store.occupiedScopes().isEmpty)
        }
    }

    @Test("A directory is not a provider representation")
    func directorySourceIsRefused() async throws {
        try await withTemporaryRoot { root in
            let source = try makeProviderFile(Sample.bytes(count: 8))
            defer { removeProviderFile(source) }

            let retainer = EncodedAssetRetainer(store: makeStore(root: root))
            await #expect(throws: EncodedAssetRetentionError.sourceUnreadable) {
                _ = try await retainer.retainCopy(
                    ofFileAt: source.deletingLastPathComponent(),
                    into: .session(Sample.sessionID()),
                    protection: .complete
                )
            }
        }
    }

    @Test("A copy that exceeds capacity leaves no partial object behind")
    func capacityBreachCleansUp() async throws {
        try await withTemporaryRoot { root in
            let source = try makeProviderFile(Sample.bytes(count: 4_000))
            defer { removeProviderFile(source) }

            let store = makeStore(root: root, capacityInBytes: 1_000)
            let retainer = EncodedAssetRetainer(store: store, chunkSizeInBytes: 256)
            let scope = EphemeralStorageScope.session(Sample.sessionID())

            await #expect(
                throws: EncodedAssetRetentionError.store(.capacityExceeded(scope: scope))
            ) {
                _ = try await retainer.retainCopy(
                    ofFileAt: source,
                    into: scope,
                    protection: .complete
                )
            }
            #expect(await store.keys(in: scope).isEmpty)
            #expect(await store.unfinalizedKeys.isEmpty)
            let used = try await store.usedByteCount()
            #expect(used == 0)
        }
    }

    @Test("A protection level that cannot be applied leaves nothing behind")
    func protectionFailureCleansUp() async throws {
        try await withTemporaryRoot { root in
            let source = try makeProviderFile(Sample.bytes(count: 512))
            defer { removeProviderFile(source) }

            let store = ProtectedEphemeralFileStore(
                configuration: .test(root: root, containerProtection: .completeUnlessOpen),
                protection: RefusingDataProtection(refusedLevel: .complete),
                clock: FixedClock()
            )
            let retainer = EncodedAssetRetainer(store: store)
            let scope = EphemeralStorageScope.session(Sample.sessionID())

            await #expect(
                throws: EncodedAssetRetentionError.store(.protectionUnavailable(.complete))
            ) {
                _ = try await retainer.retainCopy(
                    ofFileAt: source,
                    into: scope,
                    protection: .complete
                )
            }
            #expect(await store.keys(in: scope).isEmpty)
        }
    }

    @Test("Cancelling during the copy leaves no partial object behind")
    func cancellationCleansUp() async throws {
        try await withTemporaryRoot { root in
            let source = try makeProviderFile(Sample.bytes(count: 200_000))
            defer { removeProviderFile(source) }

            let store = makeStore(root: root)
            let retainer = EncodedAssetRetainer(store: store, chunkSizeInBytes: 512)
            let scope = EphemeralStorageScope.session(Sample.sessionID())

            let task = Task {
                try await retainer.retainCopy(
                    ofFileAt: source,
                    into: scope,
                    protection: .complete
                )
            }
            task.cancel()

            await #expect(throws: EncodedAssetRetentionError.cancelled) {
                _ = try await task.value
            }
            #expect(await store.keys(in: scope).isEmpty)
            #expect(await store.unfinalizedKeys.isEmpty)
            let used = try await store.usedByteCount()
            #expect(used == 0)
        }
    }

    @Test("Cleaning up an incomplete copy is idempotent")
    func cleanupIsIdempotent() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let retainer = EncodedAssetRetainer(store: store)
            let scope = EphemeralStorageScope.session(Sample.sessionID())

            // An interrupted copy: created, partly written, never finalized.
            let key = try await store.create(in: scope, protection: .complete)
            try await store.append(Sample.bytes(count: 2_048), to: key)

            let first = try await retainer.discardIncompleteCopy(in: scope, reason: .interrupted)
            #expect(first.removedObjectCount == 1)
            #expect(await store.keys(in: scope).isEmpty)

            // Repeated cleanup, and cleanup of a scope that never existed, both succeed
            // with nothing to remove.
            let second = try await retainer.discardIncompleteCopy(in: scope, reason: .interrupted)
            #expect(second.removedObjectCount == 0)
            let third = try await retainer.discardIncompleteCopy(in: scope, reason: .abandoned)
            #expect(third.removedObjectCount == 0)
            let never = try await retainer.discardIncompleteCopy(
                in: .session(Sample.sessionID("session-never-used")),
                reason: .abandoned
            )
            #expect(never.removedObjectCount == 0)
        }
    }

    @Test("A successful retention leaves exactly one object and no partial copy")
    func successLeavesOneObject() async throws {
        try await withTemporaryRoot { root in
            let source = try makeProviderFile(Sample.bytes(count: 12_345))
            defer { removeProviderFile(source) }

            let store = makeStore(root: root)
            let retainer = EncodedAssetRetainer(store: store, chunkSizeInBytes: 1_000)
            let scope = EphemeralStorageScope.session(Sample.sessionID())
            let receipt = try await retainer.retainCopy(
                ofFileAt: source,
                into: scope,
                protection: .complete
            )

            #expect(await store.keys(in: scope) == [receipt.key])
            #expect(await store.unfinalizedKeys.isEmpty)
            let used = try await store.usedByteCount()
            #expect(used == 12_345)
            let payloads = FileManager.default
                .enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.lastPathComponent.hasPrefix("payload") } ?? []
            #expect(payloads.map(\.lastPathComponent) == ["payload"])
        }
    }
}
