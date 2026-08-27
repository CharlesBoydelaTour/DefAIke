import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeSharedTransfer

/// The `staging` → `ready` → `claimed` protocol, against the real file system.
///
/// Every test here is about one sentence: successful atomic publication is the only Share
/// session-creation commit. So the assertions come in pairs — what exists after a success,
/// and what does *not* exist after every kind of failure — because "creates no session" is
/// only meaningful if nothing is left that a later start could mistake for one.
///
/// The real store and the real protection applier are used deliberately. Publication and
/// claim are renames on a real file system, and a double that models a rename as a
/// dictionary update cannot show that an interrupted publication is unresolvable.
@Suite("Shared transfer store")
struct SharedTransferStoreTests {

    // MARK: - Scaffolding

    private func makeFileStore(
        root: URL,
        containerProtection: FileProtectionLevel = .complete,
        protection: any DataProtectionApplying = PlatformDataProtection()
    ) -> ProtectedEphemeralFileStore {
        ProtectedEphemeralFileStore(
            configuration: .test(root: root, containerProtection: containerProtection),
            protection: protection,
            clock: FixedClock(fixtureNow)
        )
    }

    /// Writes one complete object directly, bypassing the transfer protocol.
    ///
    /// Used to plant the partial states an interrupted process leaves behind. There is no
    /// other way to reach them: the store's own publication path is all-or-nothing.
    private func writeObject(
        _ bytes: [UInt8],
        in scope: EphemeralStorageScope,
        to store: ProtectedEphemeralFileStore
    ) async throws -> EphemeralWriteReceipt {
        let key = try await store.create(in: scope, protection: .complete)
        try await store.append(bytes, to: key)
        return try await store.finalize(key)
    }

    /// Plants a ready slot with control over what disagrees with what.
    ///
    /// - Parameters:
    ///   - ticketByteCount: Overrides the ticket's byte count, to model a ticket that no
    ///     longer describes its payload.
    ///   - includeManifest: When `false`, plants a payload with nothing naming it: the state
    ///     an interruption between the two renames leaves.
    @discardableResult
    private func plantReadySlot(
        transferID: ShareTransferID,
        payload: [UInt8],
        ticketByteCount: UInt64? = nil,
        ticketDigest: DefAIkeDomain.SHA256Digest? = nil,
        createdAt: Date = fixtureNow,
        includeManifest: Bool = true,
        in store: ProtectedEphemeralFileStore
    ) async throws -> ShareTransferTicket {
        let scope = EphemeralStorageScope.transfer(transferID, .ready)
        let payloadReceipt = try await writeObject(payload, in: scope, to: store)
        let ticket = Sample.ticket(
            transferID: transferID,
            byteCount: ticketByteCount ?? payloadReceipt.byteCount,
            sha256: ticketDigest ?? payloadReceipt.sha256,
            createdAt: createdAt
        )
        guard includeManifest else { return ticket }

        let manifestKey = try await store.create(in: scope, protection: .complete)
        guard let manifest = TransferManifest(
            ticket: ticket,
            manifestKey: manifestKey,
            payloadKey: payloadReceipt.key
        ) else {
            preconditionFailure("the planted manifest must be internally consistent")
        }
        try await store.append(try TransferManifestCoding.encode(manifest), to: manifestKey)
        _ = try await store.finalize(manifestKey)
        return ticket
    }

    /// Every transfer scope the underlying store still owns.
    private func transferScopes(
        of store: ProtectedEphemeralFileStore
    ) async -> Set<EphemeralStorageScope> {
        await store.occupiedScopes().filter {
            if case .transfer = $0 { return true }
            return false
        }
    }

    // MARK: - Publication is the commit

    @Test("Publication commits exactly one ready transfer describing the staged bytes")
    func publicationCommitsOneReadyTransfer() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let bytes = Sample.bytes(count: 3_000)
            let source = try makeProviderFile(bytes)
            defer { removeProviderFile(source) }

            let ticket = try await transfers.publishTransfer(
                ofFileAt: source,
                consent: Sample.consent(),
                sessionID: Sample.sessionID("session-share-0001"),
                basis: .providerDeclaredOriginalRepresentation
            )

            #expect(ticket.route == .shareExtension)
            #expect(ticket.sessionID == Sample.sessionID("session-share-0001"))
            #expect(ticket.byteCount == 3_000)
            #expect(ticket.sha256 == StreamingSHA256.digest(of: Data(bytes)))
            #expect(ticket.preservationStatus == .originalBytes)
            #expect(ticket.preservationBasis == .providerDeclaredOriginalRepresentation)
            #expect(ticket.contentTypeHint == Sample.contentTypeHint())
            #expect(ticket.extensionBuildID == Sample.buildID())
            #expect(ticket.createdAt == fixtureNow)

            let published = try await transfers.readySlotState().publishedTransfer
            #expect(published?.ticket == ticket)
            // The published payload is the source, byte for byte. Nothing between the
            // provider file and the ready slot may rewrite it.
            let storedKey = try #require(published?.storageKey)
            #expect(try await fileStore.read(storedKey) == bytes)
        }
    }

    @Test("Nothing remains under staging once a transfer is published")
    func publicationLeavesNoStagedMaterial() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let source = try makeProviderFile(Sample.bytes(count: 512))
            defer { removeProviderFile(source) }

            let ticket = try await transfers.publishTransfer(
                ofFileAt: source,
                consent: Sample.consent(),
                sessionID: Sample.sessionID(),
                basis: .preservationHistoryNotEstablished
            )

            #expect(
                await transferScopes(of: fileStore) == [.transfer(ticket.transferID, .ready)]
            )
        }
    }

    @Test("The provider's representation is left untouched")
    func providerFileIsNotConsumed() async throws {
        try await withTemporaryRoot { root in
            let transfers = SharedTransferStore.test(over: makeFileStore(root: root))
            let bytes = Sample.bytes(count: 800)
            let source = try makeProviderFile(bytes)
            defer { removeProviderFile(source) }

            _ = try await transfers.publishTransfer(
                ofFileAt: source,
                consent: Sample.consent(),
                sessionID: Sample.sessionID(),
                basis: .providerDeclaredTransformedRepresentation
            )

            #expect(try Array(Data(contentsOf: source)) == bytes)
        }
    }

    @Test(
        "Published material carries the protection level the Extension Execution Policy fixes",
        arguments: FileProtectionLevel.allCases
    )
    func publishedMaterialCarriesThePolicyProtectionLevel(
        level: FileProtectionLevel
    ) async throws {
        try await withTemporaryRoot { root in
            // The level is read from the policy, so exercising all three proves the store is
            // not quietly applying one it prefers.
            let fileStore = makeFileStore(root: root, containerProtection: level)
            let transfers = SharedTransferStore.test(
                over: fileStore,
                extensionPolicy: Sample.extensionPolicy(stagedFileProtection: level)
            )
            let source = try makeProviderFile(Sample.bytes(count: 256))
            defer { removeProviderFile(source) }

            _ = try await transfers.publishTransfer(
                ofFileAt: source,
                consent: Sample.consent(),
                sessionID: Sample.sessionID(),
                basis: .preservationHistoryNotEstablished
            )

            #expect(await transfers.stagedFileProtection == level)
            let published = try #require(try await transfers.readySlotState().publishedTransfer)
            let receipt = try #require(await fileStore.receipt(for: published.storageKey))
            #expect(receipt.protection == level)
        }
    }

    @Test("A protection level that cannot be applied publishes nothing")
    func unappliableProtectionPublishesNothing() async throws {
        try await withTemporaryRoot { root in
            // Requirement 9.6 has no unprotected fallback: staged encoded bytes either carry
            // the approved level or do not exist.
            let fileStore = makeFileStore(
                root: root,
                protection: RefusingDataProtection(refusedLevel: .complete)
            )
            let transfers = SharedTransferStore.test(over: fileStore)
            let source = try makeProviderFile(Sample.bytes(count: 256))
            defer { removeProviderFile(source) }

            await #expect(throws: TransferStoreError.self) {
                _ = try await transfers.publishTransfer(
                    ofFileAt: source,
                    consent: Sample.consent(),
                    sessionID: Sample.sessionID(),
                    basis: .preservationHistoryNotEstablished
                )
            }

            #expect(try await transfers.readySlotState() == .empty)
            #expect(await transferScopes(of: fileStore).isEmpty)
        }
    }

    // MARK: - Failure before the commit creates nothing

    @Test("An unreadable provider representation creates no session and no material")
    func unreadableSourceCreatesNothing() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let missing = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "absent-\(UUID().uuidString).bin", directoryHint: .notDirectory)

            let fault = await publicationFault(
                of: transfers,
                source: missing,
                sessionID: Sample.sessionID()
            )

            let state = try await transfers.readySlotState()
            #expect(fault == .stagingFailed(.sourceUnreadable))
            #expect(state == .empty)
            #expect(await transferScopes(of: fileStore).isEmpty)
        }
    }

    @Test("An empty provider representation creates no session and no material")
    func emptySourceCreatesNothing() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let source = try makeProviderFile([])
            defer { removeProviderFile(source) }

            let fault = await publicationFault(
                of: transfers,
                source: source,
                sessionID: Sample.sessionID()
            )

            #expect(fault == .stagingFailed(.emptySource))
            #expect(try await transfers.readySlotState() == .empty)
            #expect(await transferScopes(of: fileStore).isEmpty)
        }
    }

    @Test("Cancelling before the commit creates no session and no material")
    func cancellationBeforeCommitCreatesNothing() async throws {
        try await withTemporaryRoot { root in
            // Requirement 2.4 in its most literal form: a handoff cancelled before
            // publication leaves no ready directory, no session, and no evidence. The copy
            // is long enough that cancellation lands inside it rather than before it.
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore, chunkSizeInBytes: 256)
            let source = try makeProviderFile(Sample.bytes(count: 200_000))
            defer { removeProviderFile(source) }

            let task = Task {
                try await transfers.publishTransfer(
                    ofFileAt: source,
                    consent: Sample.consent(),
                    sessionID: Sample.sessionID(),
                    basis: .preservationHistoryNotEstablished
                )
            }
            task.cancel()

            await #expect(throws: TransferStoreError.stagingFailed(.cancelled)) {
                _ = try await task.value
            }
            #expect(try await transfers.readySlotState() == .empty)
            #expect(await transferScopes(of: fileStore).isEmpty)
            #expect(try await fileStore.usedByteCount() == 0)
        }
    }

    @Test("A payload over the store's capacity creates no session and no material")
    func capacityBreachCreatesNothing() async throws {
        try await withTemporaryRoot { root in
            // The extension's resource-limit path: the ceiling comes from the injected
            // capacity, and a breach must leave no staged bytes to be promoted later.
            let fileStore = ProtectedEphemeralFileStore(
                configuration: .test(root: root, capacityInBytes: 128),
                protection: PlatformDataProtection(),
                clock: FixedClock(fixtureNow)
            )
            let transfers = SharedTransferStore.test(over: fileStore)
            let source = try makeProviderFile(Sample.bytes(count: 4_096))
            defer { removeProviderFile(source) }

            let fault = await publicationFault(
                of: transfers,
                source: source,
                sessionID: Sample.sessionID()
            )

            guard case .some(.stagingFailed(.store(.capacityExceeded))) = fault else {
                Issue.record("expected a capacity breach, got \(String(describing: fault))")
                return
            }
            #expect(try await transfers.readySlotState() == .empty)
            #expect(await transferScopes(of: fileStore).isEmpty)
        }
    }

    // MARK: - The single ready slot

    @Test("A second publication does not replace a pending handoff")
    func pendingHandoffIsNotReplaced() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let first = try makeProviderFile(Sample.bytes(count: 700, seed: 3))
            let second = try makeProviderFile(Sample.bytes(count: 900, seed: 9))
            defer {
                removeProviderFile(first)
                removeProviderFile(second)
            }

            let pending = try await transfers.publishTransfer(
                ofFileAt: first,
                consent: Sample.consent(),
                sessionID: Sample.sessionID("session-first-0001"),
                basis: .providerDeclaredOriginalRepresentation
            )
            let fault = await publicationFault(
                of: transfers,
                source: second,
                sessionID: Sample.sessionID("session-second-0001")
            )

            #expect(fault == .pendingHandoffExists(pending.transferID))
            // The refused invocation is not merely unsuccessful: the consented handoff has
            // to be exactly as it was, still resumable, and no second slot may exist.
            #expect(
                try await transfers.readySlotState().publishedTransfer?.ticket == pending
            )
            #expect(
                await transferScopes(of: fileStore) == [.transfer(pending.transferID, .ready)]
            )
        }
    }

    @Test("A refused publication stages nothing at all")
    func refusedPublicationStagesNothing() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let pending = try await plantReadySlot(
                transferID: Sample.transferID("aaaa0000aaaa0000aaaa0000aaaa0000"),
                payload: Sample.bytes(count: 400),
                in: fileStore
            )
            let source = try makeProviderFile(Sample.bytes(count: 4_000))
            defer { removeProviderFile(source) }
            let usedBefore = try await fileStore.usedByteCount()

            let fault = await publicationFault(
                of: transfers,
                source: source,
                sessionID: Sample.sessionID()
            )

            #expect(fault == .pendingHandoffExists(pending.transferID))
            // Not one byte of the second image was written: the slot is checked before the
            // copy starts, not after it finishes.
            #expect(try await fileStore.usedByteCount() == usedBefore)
        }
    }

    @Test("An expired pending handoff is cleared and does not block a new one")
    func expiredPendingHandoffIsCleared() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let policy = Sample.lifecyclePolicy(abandonedMilliseconds: 60_000)
            let stale = try await plantReadySlot(
                transferID: Sample.transferID("bbbb0000bbbb0000bbbb0000bbbb0000"),
                payload: Sample.bytes(count: 400),
                createdAt: fixtureNow,
                in: fileStore
            )
            // A later process start. Expiry is the injected policy's deadline measured from
            // the ticket's own timestamp; nothing here names a number of its own.
            let later = SharedTransferStore.test(
                over: fileStore,
                lifecyclePolicy: policy,
                now: fixtureNow.addingTimeInterval(120)
            )
            let source = try makeProviderFile(Sample.bytes(count: 600))
            defer { removeProviderFile(source) }

            #expect(
                try await later.readySlotState()
                    == .unusable(.expired(stale.transferID))
            )
            let fresh = try await later.publishTransfer(
                ofFileAt: source,
                consent: Sample.consent(),
                sessionID: Sample.sessionID("session-fresh-0001"),
                basis: .preservationHistoryNotEstablished
            )

            #expect(try await later.readySlotState().publishedTransfer?.ticket == fresh)
            #expect(await transferScopes(of: fileStore) == [.transfer(fresh.transferID, .ready)])
        }
    }

    @Test("A pending handoff inside its deadline is still resumable")
    func currentPendingHandoffSurvives() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let ticket = try await plantReadySlot(
                transferID: Sample.transferID("cccc0000cccc0000cccc0000cccc0000"),
                payload: Sample.bytes(count: 400),
                createdAt: fixtureNow,
                in: fileStore
            )
            let barelyInside = SharedTransferStore.test(
                over: fileStore,
                lifecyclePolicy: Sample.lifecyclePolicy(abandonedMilliseconds: 60_000),
                now: fixtureNow.addingTimeInterval(59)
            )

            let published = try #require(
                try await barelyInside.readySlotState().publishedTransfer
            )
            #expect(published.ticket == ticket)
        }
    }

    // MARK: - Unresolvable ready material

    @Test("A payload no manifest names is not a session")
    func interruptedPublicationIsNotASession() async throws {
        try await withTemporaryRoot { root in
            // The state an interruption between the payload rename and the manifest rename
            // leaves. It has complete bytes, and it is still not a pending session.
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let transferID = Sample.transferID("dddd0000dddd0000dddd0000dddd0000")
            try await plantReadySlot(
                transferID: transferID,
                payload: Sample.bytes(count: 500),
                includeManifest: false,
                in: fileStore
            )

            // No readable ticket, so no session was ever committed and there is nothing for
            // the main app to resume and terminate.
            #expect(
                try await transfers.readySlotState()
                    == .unusable(.defective(
                        DefectiveTransfer(
                            transferID: transferID,
                            pendingSession: nil,
                            defect: .manifestMissing
                        )
                    ))
            )
        }
    }

    @Test("A ticket that no longer describes its payload names the session it broke")
    func measurementMismatchIsNotASession() async throws {
        try await withTemporaryRoot { root in
            // The other side of the distinction: this publication *did* commit, so the
            // session exists and the main app has to resume exactly it in order to end it
            // with `handoff-error`.
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let transferID = Sample.transferID("eeee0000eeee0000eeee0000eeee0000")
            let ticket = try await plantReadySlot(
                transferID: transferID,
                payload: Sample.bytes(count: 500),
                ticketByteCount: 499,
                in: fileStore
            )

            #expect(
                try await transfers.readySlotState()
                    == .unusable(.defective(
                        DefectiveTransfer(
                            transferID: transferID,
                            pendingSession: ticket.sessionID,
                            defect: .measurementMismatch
                        )
                    ))
            )
        }
    }

    @Test("A ticket whose digest disagrees with its payload is not a session")
    func digestMismatchIsNotASession() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let transferID = Sample.transferID("ffff0000ffff0000ffff0000ffff0000")
            let ticket = try await plantReadySlot(
                transferID: transferID,
                payload: Sample.bytes(count: 500),
                ticketDigest: StreamingSHA256.digest(of: Data("not these bytes".utf8)),
                in: fileStore
            )

            #expect(
                try await transfers.readySlotState()
                    == .unusable(.defective(
                        DefectiveTransfer(
                            transferID: transferID,
                            pendingSession: ticket.sessionID,
                            defect: .measurementMismatch
                        )
                    ))
            )
        }
    }

    @Test("Two ready slots are ambiguous rather than resolved by preference")
    func twoReadySlotsAreAmbiguous() async throws {
        try await withTemporaryRoot { root in
            // The single ready-slot rule exists to prevent ambiguous multiple pending
            // images. Picking one would be exactly the harm it prevents.
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            try await plantReadySlot(
                transferID: Sample.transferID("1111000011110000111100001111aaaa"),
                payload: Sample.bytes(count: 300, seed: 2),
                in: fileStore
            )
            try await plantReadySlot(
                transferID: Sample.transferID("2222000022220000222200002222bbbb"),
                payload: Sample.bytes(count: 300, seed: 5),
                in: fileStore
            )

            #expect(try await transfers.readySlotState() == .unusable(.ambiguousSlotCount(2)))
        }
    }

    // MARK: - Claim

    @Test("Claiming transfers ownership and preserves the session identifier")
    func claimPreservesTheSessionIdentifier() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let bytes = Sample.bytes(count: 2_500)
            let source = try makeProviderFile(bytes)
            defer { removeProviderFile(source) }
            let ticket = try await transfers.publishTransfer(
                ofFileAt: source,
                consent: Sample.consent(),
                sessionID: Sample.sessionID("session-carried-0001"),
                basis: .providerDeclaredOriginalRepresentation
            )

            guard case .claimed(let claimed) = try await transfers.claimReadyTransfer() else {
                Issue.record("a published transfer must be claimable")
                return
            }

            #expect(claimed.ticket == ticket)
            #expect(claimed.sessionID == Sample.sessionID("session-carried-0001"))
            #expect(claimed.scope == .transfer(ticket.transferID, .claimed))
            // Ownership moved; the bytes did not change.
            #expect(try await fileStore.read(claimed.payloadKey) == bytes)
            #expect(await fileStore.keys(in: .transfer(ticket.transferID, .ready)).isEmpty)
        }
    }

    @Test("A claimed transfer cannot be claimed twice")
    func claimIsExclusive() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let source = try makeProviderFile(Sample.bytes(count: 640))
            defer { removeProviderFile(source) }
            _ = try await transfers.publishTransfer(
                ofFileAt: source,
                consent: Sample.consent(),
                sessionID: Sample.sessionID(),
                basis: .preservationHistoryNotEstablished
            )
            _ = try await transfers.claimReadyTransfer()

            #expect(try await transfers.claimReadyTransfer() == .nothingToClaim)
        }
    }

    @Test("An empty ready slot is nothing to claim, not a failed handoff")
    func emptySlotIsNothingToClaim() async throws {
        try await withTemporaryRoot { root in
            // The distinction the main app depends on: "no pending image" must never be
            // presented as the `handoff-error` a mismatch produces.
            let transfers = SharedTransferStore.test(over: makeFileStore(root: root))

            let outcome = try await transfers.claimReadyTransfer()
            #expect(outcome == .nothingToClaim)
        }
    }

    @Test("Claiming unresolvable material reports it and removes it")
    func claimRejectsAndRemovesUnresolvableMaterial() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let transferID = Sample.transferID("3333000033330000333300003333cccc")
            let ticket = try await plantReadySlot(
                transferID: transferID,
                payload: Sample.bytes(count: 500),
                ticketByteCount: 12,
                in: fileStore
            )

            let outcome = try await transfers.claimReadyTransfer()

            #expect(
                outcome == .rejected(.defective(
                    DefectiveTransfer(
                        transferID: transferID,
                        pendingSession: ticket.sessionID,
                        defect: .measurementMismatch
                    )
                ))
            )
            // Removed, not left for the next start to trip over: a failed transfer's bytes
            // have no owner and no purpose.
            #expect(await transferScopes(of: fileStore).isEmpty)
            #expect(try await transfers.readySlotState() == .empty)
        }
    }

    // MARK: - Startup cleanup

    @Test("Startup cleanup removes staging and claimed residue")
    func startupCleanupRemovesTransientStates() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let staged = Sample.transferID("4444000044440000444400004444dddd")
            let claimed = Sample.transferID("5555000055550000555500005555eeee")
            _ = try await writeObject(
                Sample.bytes(count: 300),
                in: .transfer(staged, .staging),
                to: fileStore
            )
            _ = try await writeObject(
                Sample.bytes(count: 300),
                in: .transfer(claimed, .claimed),
                to: fileStore
            )

            let report = try await transfers.runStartupCleanup()

            #expect(report.retainedTransfer == nil)
            #expect(report.removedObjectCount == 2)
            #expect(report.receipts.allSatisfy { $0.reason == .interrupted })
            #expect(await transferScopes(of: fileStore).isEmpty)
        }
    }

    @Test("Startup cleanup keeps a pending handoff inside its deadline")
    func startupCleanupKeepsACurrentPendingHandoff() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let pending = Sample.transferID("6666000066660000666600006666ffff")
            let ticket = try await plantReadySlot(
                transferID: pending,
                payload: Sample.bytes(count: 300),
                in: fileStore
            )
            _ = try await writeObject(
                Sample.bytes(count: 100),
                in: .transfer(pending, .staging),
                to: fileStore
            )

            let report = try await transfers.runStartupCleanup()

            #expect(report.retainedTransfer == pending)
            // The consented handoff survives; the interrupted staging residue beside it does
            // not.
            #expect(try await transfers.readySlotState().publishedTransfer?.ticket == ticket)
            #expect(await transferScopes(of: fileStore) == [.transfer(pending, .ready)])
        }
    }

    @Test("Startup cleanup removes an expired pending handoff")
    func startupCleanupRemovesAnExpiredPendingHandoff() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let expired = Sample.transferID("7777000077770000777700007777aaaa")
            try await plantReadySlot(
                transferID: expired,
                payload: Sample.bytes(count: 300),
                createdAt: fixtureNow,
                in: fileStore
            )
            let later = SharedTransferStore.test(
                over: fileStore,
                lifecyclePolicy: Sample.lifecyclePolicy(abandonedMilliseconds: 30_000),
                now: fixtureNow.addingTimeInterval(60)
            )

            let report = try await later.runStartupCleanup()

            #expect(report.retainedTransfer == nil)
            #expect(report.receipts.contains { $0.reason == .abandoned })
            #expect(await transferScopes(of: fileStore).isEmpty)
        }
    }

    @Test("Startup cleanup removes unresolvable ready material")
    func startupCleanupRemovesUnresolvableReadyMaterial() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            try await plantReadySlot(
                transferID: Sample.transferID("8888000088880000888800008888bbbb"),
                payload: Sample.bytes(count: 300),
                includeManifest: false,
                in: fileStore
            )

            let report = try await transfers.runStartupCleanup()

            #expect(report.retainedTransfer == nil)
            #expect(await transferScopes(of: fileStore).isEmpty)
        }
    }

    @Test("Startup cleanup leaves session material alone")
    func startupCleanupIgnoresSessionScopes() async throws {
        try await withTemporaryRoot { root in
            // The main app can root both lifecycles at one store. Transfer cleanup deleting
            // session bytes would destroy the analysis it is preparing for.
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let session = EphemeralStorageScope.session(Sample.sessionID("session-active-0001"))
            let receipt = try await writeObject(
                Sample.bytes(count: 300),
                in: session,
                to: fileStore
            )

            _ = try await transfers.runStartupCleanup()

            #expect(await fileStore.keys(in: session) == [receipt.key])
        }
    }

    @Test("Startup cleanup is idempotent")
    func startupCleanupIsIdempotent() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            _ = try await writeObject(
                Sample.bytes(count: 300),
                in: .transfer(Sample.transferID("9999000099990000999900009999cccc"), .staging),
                to: fileStore
            )

            let first = try await transfers.runStartupCleanup()
            let second = try await transfers.runStartupCleanup()

            #expect(first.removedObjectCount == 1)
            #expect(second.removedObjectCount == 0)
            #expect(second.retainedTransfer == nil)
        }
    }

    // MARK: - Removal

    @Test("Discarding a transfer removes every one of its states and repeats safely")
    func discardRemovesEveryStateIdempotently() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let transferID = Sample.transferID("abcd0000abcd0000abcd0000abcd0000")
            for state in TransferSlotState.allCases {
                _ = try await writeObject(
                    Sample.bytes(count: 120),
                    in: .transfer(transferID, state),
                    to: fileStore
                )
            }

            let first = try await transfers.discardTransfer(transferID, reason: .errorTerminated)
            let second = try await transfers.discardTransfer(transferID, reason: .errorTerminated)

            #expect(first.reduce(0) { $0 + $1.removedObjectCount } == 3)
            #expect(second.reduce(0) { $0 + $1.removedObjectCount } == 0)
            #expect(first.allSatisfy { $0.reason == .errorTerminated })
            #expect(await transferScopes(of: fileStore).isEmpty)
        }
    }

    // MARK: - Helpers

    /// The fault a publication produces, or `nil` when it succeeds.
    private func publicationFault(
        of transfers: SharedTransferStore,
        source: URL,
        sessionID: AnalysisSessionID,
        basis: PreservationBasis = .preservationHistoryNotEstablished
    ) async -> TransferStoreError? {
        do {
            _ = try await transfers.publishTransfer(
                ofFileAt: source,
                consent: Sample.consent(),
                sessionID: sessionID,
                basis: basis
            )
            return nil
        } catch {
            return error
        }
    }
}
