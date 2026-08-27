import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeSharedTransfer

/// The main app's claim, against the real file system and two real protected stores.
///
/// Every test here is a pair of statements, because the requirements are: what the session
/// gets when the handoff verified, and what is left behind when it did not. A claim that
/// reported `handoff-error` and still left encoded bytes in the App Group container, or a
/// half-written copy in app-private storage, would satisfy the error requirement and violate
/// the cleanup one.
///
/// Two stores are used deliberately. The claim's whole point is that the verified bytes end
/// up somewhere the Share Extension cannot reach, so the App Group store and the app-private
/// store are separate roots and the tests assert on both. A single store would let a test
/// pass while the bytes never left the shared container.
///
/// **Nothing here is release evidence.** No protection level, deadline, or capacity in this
/// file is an approved value, and a host result is not evidence for the data-protection
/// behavior or the cross-process rename these paths depend on.
@Suite("Share handoff claim adapter")
struct ShareHandoffClaimAdapterTests {

    // MARK: - Scaffolding

    /// The two roots one claim spans: the shared container and the app's own.
    private struct Roots {
        let appGroup: URL
        let appPrivate: URL
    }

    /// Runs `body` with two fresh empty roots and removes them afterwards.
    private func withRoots<T>(_ body: (Roots) async throws -> T) async throws -> T {
        try await withTemporaryRoot { root in
            try await body(
                Roots(
                    appGroup: root.appending(path: "appgroup", directoryHint: .isDirectory),
                    appPrivate: root.appending(path: "private", directoryHint: .isDirectory)
                )
            )
        }
    }

    private func makeFileStore(
        root: URL,
        capacityInBytes: UInt64 = testCapacityInBytes,
        protection: any DataProtectionApplying = PlatformDataProtection()
    ) -> ProtectedEphemeralFileStore {
        ProtectedEphemeralFileStore(
            configuration: .test(root: root, capacityInBytes: capacityInBytes),
            protection: protection,
            clock: FixedClock(fixtureNow)
        )
    }

    /// Writes one complete object directly, bypassing the transfer protocol.
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
    /// The store's own publication path is all-or-nothing, so this is the only way to reach
    /// the partial and incoherent states an interrupted or corrupted process leaves.
    @discardableResult
    private func plantReadySlot(
        transferID: ShareTransferID,
        payload: [UInt8],
        ticketByteCount: UInt64? = nil,
        createdAt: Date = fixtureNow,
        includeManifest: Bool = true,
        in store: ProtectedEphemeralFileStore
    ) async throws -> ShareTransferTicket {
        let scope = EphemeralStorageScope.transfer(transferID, .ready)
        let payloadReceipt = try await writeObject(payload, in: scope, to: store)
        let ticket = Sample.ticket(
            transferID: transferID,
            byteCount: ticketByteCount ?? payloadReceipt.byteCount,
            sha256: payloadReceipt.sha256,
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

    /// Every transfer scope the App Group store still owns.
    private func transferScopes(
        of store: ProtectedEphemeralFileStore
    ) async -> Set<EphemeralStorageScope> {
        await store.occupiedScopes().filter {
            if case .transfer = $0 { return true }
            return false
        }
    }

    /// Every session scope the app-private store still owns.
    private func sessionScopes(
        of store: ProtectedEphemeralFileStore
    ) async -> Set<EphemeralStorageScope> {
        await store.occupiedScopes().filter {
            if case .session = $0 { return true }
            return false
        }
    }

    /// The single object one session scope holds, or `nil`.
    private func soleSessionObject(
        of sessionID: AnalysisSessionID,
        in store: ProtectedEphemeralFileStore
    ) async throws -> (receipt: EphemeralWriteReceipt, bytes: [UInt8])? {
        let keys = await store.keys(in: .session(sessionID))
        guard keys.count == 1, let key = keys.first else { return nil }
        guard let receipt = await store.receipt(for: key) else { return nil }
        return (receipt, try await store.read(key))
    }

    /// One fully wired claim adapter over `appGroup` and `appPrivate`.
    private func makeAdapter(
        appGroupStore: any EphemeralFileStoring,
        sessionStore: any EphemeralFileStoring,
        sessionFileProtection: FileProtectionLevel = .complete,
        now: Date = fixtureNow,
        lifecyclePolicy: DataLifecyclePolicy = Sample.lifecyclePolicy(),
        buildID: AppBuildID = Sample.buildID(),
        chunkSizeInBytes: Int = 64
    ) -> ShareHandoffClaimAdapter {
        ShareHandoffClaimAdapter(
            transfers: SharedTransferStore.test(
                over: appGroupStore,
                lifecyclePolicy: lifecyclePolicy,
                buildID: buildID,
                now: now
            ),
            sessionStore: sessionStore,
            sessionFileProtection: sessionFileProtection,
            chunkSizeInBytes: chunkSizeInBytes
        )
    }

    /// Publishes one transfer through the real staging path and returns its ticket.
    private func publish(
        _ bytes: [UInt8],
        sessionID: AnalysisSessionID,
        basis: PreservationBasis = .preservationHistoryNotEstablished,
        over appGroupStore: any EphemeralFileStoring,
        buildID: AppBuildID = Sample.buildID()
    ) async throws -> ShareTransferTicket {
        let source = try makeProviderFile(bytes)
        defer { removeProviderFile(source) }
        let extensionSide = SharedTransferStore.test(over: appGroupStore, buildID: buildID)
        return try await extensionSide.publishTransfer(
            ofFileAt: source,
            consent: Sample.consent(),
            sessionID: sessionID,
            basis: basis
        )
    }

    // MARK: - Nothing pending

    @Test("An empty ready slot is nothing pending, not a failed handoff")
    func emptySlotIsNothingPending() async throws {
        try await withRoots { roots in
            // The distinction the whole main-app path depends on: an ordinary launch with
            // no handoff must never present the `handoff-error` a mismatch produces.
            let appGroup = makeFileStore(root: roots.appGroup)
            let sessions = makeFileStore(root: roots.appPrivate)
            let adapter = makeAdapter(appGroupStore: appGroup, sessionStore: sessions)

            #expect(await adapter.attemptClaim(claimingBuildID: Sample.buildID())
                == .nothingPending)
            // Through the port, "nothing pending" is `nil` and never a thrown fault.
            let claimed = try await adapter.claimReadyTransfer(
                claimingBuildID: Sample.buildID()
            )
            #expect(claimed == nil)
            #expect(await sessionScopes(of: sessions).isEmpty)
        }
    }

    @Test("Peeking reports the pending transfer without claiming it")
    func peekTakesNoOwnership() async throws {
        try await withRoots { roots in
            let appGroup = makeFileStore(root: roots.appGroup)
            let sessions = makeFileStore(root: roots.appPrivate)
            let ticket = try await publish(
                Sample.bytes(count: 900),
                sessionID: Sample.sessionID("session-peeked-0001"),
                over: appGroup
            )
            let adapter = makeAdapter(appGroupStore: appGroup, sessionStore: sessions)

            let firstPeek = try await adapter.peekReadyTransfer()
            let secondPeek = try await adapter.peekReadyTransfer()
            #expect(firstPeek?.ticket == ticket)
            #expect(secondPeek?.ticket == ticket)
            // Two peeks left it claimable, and no session bytes were written by either.
            #expect(await sessionScopes(of: sessions).isEmpty)
            #expect(await adapter.attemptClaim(claimingBuildID: Sample.buildID())
                .verifiedHandoff?.sessionID == Sample.sessionID("session-peeked-0001"))
        }
    }

    @Test("A claimed handoff cannot be claimed twice")
    func claimIsExclusive() async throws {
        try await withRoots { roots in
            let appGroup = makeFileStore(root: roots.appGroup)
            let sessions = makeFileStore(root: roots.appPrivate)
            _ = try await publish(
                Sample.bytes(count: 640),
                sessionID: Sample.sessionID(),
                over: appGroup
            )
            let adapter = makeAdapter(appGroupStore: appGroup, sessionStore: sessions)

            #expect(await adapter.attemptClaim(claimingBuildID: Sample.buildID())
                .verifiedHandoff != nil)
            #expect(await adapter.attemptClaim(claimingBuildID: Sample.buildID())
                == .nothingPending)
        }
    }

    // MARK: - The verified handoff

    @Test("A verified claim resumes the same session with byte-identical encoded bytes")
    func verifiedClaimResumesTheSameSession() async throws {
        try await withRoots { roots in
            let appGroup = makeFileStore(root: roots.appGroup)
            let sessions = makeFileStore(root: roots.appPrivate)
            let bytes = Sample.bytes(count: 3_333)
            let session = Sample.sessionID("session-carried-0001")
            let ticket = try await publish(bytes, sessionID: session, over: appGroup)
            let adapter = makeAdapter(appGroupStore: appGroup, sessionStore: sessions)

            let handoff = try #require(
                await adapter.attemptClaim(claimingBuildID: Sample.buildID()).verifiedHandoff
            )

            // The identifier the extension allocated under `staging`, unchanged
            // (Requirements 2.3 and 11.12).
            #expect(handoff.sessionID == session)
            #expect(handoff.transferID == ticket.transferID)
            #expect(handoff.asset.route == .shareExtension)
            #expect(handoff.asset.byteCount == ticket.byteCount)
            #expect(handoff.asset.sha256 == ticket.sha256)
            #expect(handoff.asset.contentTypeHint == ticket.contentTypeHint)

            // The bytes are in app-private storage and are the staged bytes exactly.
            let stored = try #require(try await soleSessionObject(of: session, in: sessions))
            #expect(stored.bytes == bytes)
            #expect(stored.receipt.byteCount == UInt64(bytes.count))
            #expect(stored.receipt.scope == .session(session))
            #expect(handoff.asset.handle.storageKey == stored.receipt.key)

            // The shared container keeps nothing once the session owns the bytes.
            #expect(await transferScopes(of: appGroup).isEmpty)
        }
    }

    @Test(
        "A verified claim carries the preservation status and basis across unchanged",
        arguments: PreservationBasis.allCases
    )
    func verifiedClaimPreservesTheStatus(basis: PreservationBasis) async throws {
        try await withRoots { roots in
            // Requirement 11.12 transfers the *unchanged* status. Nothing on the claiming
            // side re-derives it from the bytes, and every basis has to survive the trip,
            // including the one that establishes original bytes.
            let appGroup = makeFileStore(root: roots.appGroup)
            let sessions = makeFileStore(root: roots.appPrivate)
            let session = Sample.sessionID("session-\(basis.rawValue.prefix(12))")
            let ticket = try await publish(
                Sample.bytes(count: 512),
                sessionID: session,
                basis: basis,
                over: appGroup
            )
            let adapter = makeAdapter(appGroupStore: appGroup, sessionStore: sessions)

            let handoff = try #require(
                await adapter.attemptClaim(claimingBuildID: Sample.buildID()).verifiedHandoff
            )

            #expect(handoff.asset.preservationBasis == basis)
            #expect(handoff.asset.preservationStatus == basis.mostConservativeStatus)
            #expect(handoff.asset.preservationStatus == ticket.preservationStatus)
        }
    }

    @Test(
        "Chunk size changes nothing about the recopied bytes or their measurements",
        arguments: [1, 7, 512, 1_000, 4_096]
    )
    func chunkSizeDoesNotChangeTheResult(chunkSize: Int) async throws {
        try await withRoots { roots in
            // The buffer size is a structural I/O bound, not a limit on what may be
            // claimed, so an arbitrary partition of the same payload verifies the same.
            let appGroup = makeFileStore(root: roots.appGroup)
            let sessions = makeFileStore(root: roots.appPrivate)
            let bytes = Sample.bytes(count: 1_000, seed: 7)
            let session = Sample.sessionID("session-chunked-0001")
            let ticket = try await publish(bytes, sessionID: session, over: appGroup)
            let adapter = makeAdapter(
                appGroupStore: appGroup,
                sessionStore: sessions,
                chunkSizeInBytes: chunkSize
            )

            let handoff = try #require(
                await adapter.attemptClaim(claimingBuildID: Sample.buildID()).verifiedHandoff
            )

            #expect(handoff.asset.sha256 == ticket.sha256)
            #expect(handoff.asset.byteCount == UInt64(bytes.count))
            let stored = try #require(try await soleSessionObject(of: session, in: sessions))
            #expect(stored.bytes == bytes)
        }
    }

    // MARK: - Protection

    @Test("Recopied session bytes carry the requested data-protection level")
    func recopiedBytesAreProtected() async throws {
        try await withRoots { roots in
            let appGroup = makeFileStore(root: roots.appGroup)
            let sessions = makeFileStore(root: roots.appPrivate)
            let session = Sample.sessionID("session-protected-0001")
            _ = try await publish(Sample.bytes(count: 256), sessionID: session, over: appGroup)
            let adapter = makeAdapter(
                appGroupStore: appGroup,
                sessionStore: sessions,
                sessionFileProtection: .completeUnlessOpen
            )

            let handoff = try #require(
                await adapter.attemptClaim(claimingBuildID: Sample.buildID()).verifiedHandoff
            )

            #expect(handoff.asset.handle.protection == .completeUnlessOpen)
            let stored = try #require(try await soleSessionObject(of: session, in: sessions))
            #expect(stored.receipt.protection == .completeUnlessOpen)
        }
    }

    @Test("A data-protection level that cannot be applied fails the claim closed")
    func unavailableProtectionFailsClosed() async throws {
        try await withRoots { roots in
            // Unprotected bytes are never an acceptable fallback (Requirement 9.6). The
            // session ends without evidence and nothing is retained anywhere.
            let appGroup = makeFileStore(root: roots.appGroup)
            let sessions = makeFileStore(
                root: roots.appPrivate,
                protection: RefusingDataProtection(refusedLevel: .complete)
            )
            let session = Sample.sessionID("session-unprotected-0001")
            _ = try await publish(Sample.bytes(count: 256), sessionID: session, over: appGroup)
            let adapter = makeAdapter(appGroupStore: appGroup, sessionStore: sessions)

            let failed = try #require(
                await adapter.attemptClaim(claimingBuildID: Sample.buildID()).failedHandoff
            )

            #expect(failed.sessionID == session)
            #expect(failed.failure == .recopyRefused(.protectionUnavailable(.complete)))
            #expect(failed.fault == .analysis(.handoffError, stage: .handoffVerification))
            #expect(await transferScopes(of: appGroup).isEmpty)
            #expect(await sessionScopes(of: sessions).isEmpty)
        }
    }

    // MARK: - Mismatches

    @Test("A ticket staged by another build is refused before any payload byte is read")
    func foreignStagingBuildIsRefusedWithoutReadingThePayload() async throws {
        try await withRoots { roots in
            // Two installed compositions share no App Group, so a ticket from another
            // build should be impossible. It is still checked, and checked first: nothing
            // is read or copied for a handoff that cannot be this build's.
            //
            // The payload is deliberately larger than the manifest ceiling. Resolving a
            // slot reads every small object in it looking for the one that names itself as
            // the manifest, so a payload under that ceiling is read by the *store* and the
            // assertion below could not tell that from a read by the adapter. Above the
            // ceiling, resolution skips it, and any read of it would be the adapter's.
            let appGroup = makeFileStore(root: roots.appGroup)
            let observed = ReadRecordingStore(underlying: appGroup)
            let sessions = makeFileStore(root: roots.appPrivate)
            let session = Sample.sessionID("session-foreign-build-0001")
            let ticket = try await publish(
                Sample.bytes(count: Int(TransferManifestCoding.maximumEncodedByteCount) * 2),
                sessionID: session,
                over: observed,
                buildID: Sample.buildID("build-pixel-only-0001")
            )
            let payloadKey = try #require(
                try await SharedTransferStore.test(over: observed)
                    .readySlotState().publishedTransfer?.storageKey
            )
            await observed.forgetReads()
            let adapter = makeAdapter(appGroupStore: observed, sessionStore: sessions)

            let failed = try #require(
                await adapter
                    .attemptClaim(claimingBuildID: Sample.buildID("build-provenance-0001"))
                    .failedHandoff
            )

            #expect(failed.sessionID == ticket.sessionID)
            #expect(failed.failure == .mismatch(.stagingBuildIdentity))
            #expect(failed.fault == .analysis(.handoffError, stage: .handoffVerification))
            // The nonoccurrence: the manifest had to be read to resolve the slot, the
            // payload did not, and it was not.
            let reads = await observed.readKeys()
            #expect(!reads.contains(payloadKey))
            #expect(!reads.isEmpty)
            #expect(await sessionScopes(of: sessions).isEmpty)
            #expect(await transferScopes(of: appGroup).isEmpty)
        }
    }

    @Test("Payload bytes that changed after staging are handoff-error, not a weaker result")
    func corruptedPayloadIsHandoffError() async throws {
        try await withRoots { roots in
            // The one thing the claiming process cannot rule out by construction: the
            // bytes changing after the extension finalized them, while the measurements it
            // recorded stay as written. Same length, different content, so only the
            // recomputed digest can catch it.
            let appGroup = makeFileStore(root: roots.appGroup)
            let substituting = ReadRecordingStore(underlying: appGroup)
            let sessions = makeFileStore(root: roots.appPrivate)
            let session = Sample.sessionID("session-corrupted-0001")
            let bytes = Sample.bytes(count: 1_024)
            _ = try await publish(bytes, sessionID: session, over: substituting)
            let payloadKey = try #require(
                try await SharedTransferStore.test(over: substituting)
                    .readySlotState().publishedTransfer?.storageKey
            )
            await substituting.substitute(
                Sample.bytes(count: bytes.count, seed: 200),
                for: payloadKey
            )
            let adapter = makeAdapter(appGroupStore: substituting, sessionStore: sessions)

            let failed = try #require(
                await adapter.attemptClaim(claimingBuildID: Sample.buildID()).failedHandoff
            )

            #expect(failed.sessionID == session)
            #expect(failed.failure == .mismatch(.digest))
            #expect(failed.fault == .analysis(.handoffError, stage: .handoffVerification))
            // The failed transfer and the copy it produced are both gone.
            #expect(await transferScopes(of: appGroup).isEmpty)
            #expect(await sessionScopes(of: sessions).isEmpty)
        }
    }

    @Test("A payload shorter than the ticket describes is handoff-error")
    func truncatedPayloadIsHandoffError() async throws {
        try await withRoots { roots in
            let appGroup = makeFileStore(root: roots.appGroup)
            let substituting = ReadRecordingStore(underlying: appGroup)
            let sessions = makeFileStore(root: roots.appPrivate)
            let session = Sample.sessionID("session-truncated-0001")
            _ = try await publish(
                Sample.bytes(count: 1_024),
                sessionID: session,
                over: substituting
            )
            let payloadKey = try #require(
                try await SharedTransferStore.test(over: substituting)
                    .readySlotState().publishedTransfer?.storageKey
            )
            await substituting.substitute(Sample.bytes(count: 1_000), for: payloadKey)
            let adapter = makeAdapter(appGroupStore: substituting, sessionStore: sessions)

            let failed = try #require(
                await adapter.attemptClaim(claimingBuildID: Sample.buildID()).failedHandoff
            )

            #expect(failed.failure == .mismatch(.byteCount))
            #expect(failed.fault == .analysis(.handoffError, stage: .handoffVerification))
            #expect(await sessionScopes(of: sessions).isEmpty)
            #expect(await transferScopes(of: appGroup).isEmpty)
        }
    }

    @Test("A ticket that no longer describes its payload terminates that same session")
    func defectiveSlotTerminatesThePendingSession() async throws {
        try await withRoots { roots in
            // This publication committed, so the session exists in `AwaitingMainApp` and
            // the app has to resume exactly it in order to end it (Requirement 2.19).
            let appGroup = makeFileStore(root: roots.appGroup)
            let sessions = makeFileStore(root: roots.appPrivate)
            let transferID = Sample.transferID("eeee0000eeee0000eeee0000eeee0000")
            let ticket = try await plantReadySlot(
                transferID: transferID,
                payload: Sample.bytes(count: 500),
                ticketByteCount: 499,
                in: appGroup
            )
            let adapter = makeAdapter(appGroupStore: appGroup, sessionStore: sessions)

            let failed = try #require(
                await adapter.attemptClaim(claimingBuildID: Sample.buildID()).failedHandoff
            )

            #expect(failed.sessionID == ticket.sessionID)
            #expect(failed.transferID == transferID)
            #expect(
                failed.failure == .slotNotResumable(
                    .defective(
                        DefectiveTransfer(
                            transferID: transferID,
                            pendingSession: ticket.sessionID,
                            defect: .measurementMismatch
                        )
                    )
                )
            )
            #expect(failed.fault == .analysis(.handoffError, stage: .handoffVerification))
            #expect(await transferScopes(of: appGroup).isEmpty)
            #expect(await sessionScopes(of: sessions).isEmpty)
        }
    }

    @Test("Every mismatch reaches the port as exactly handoff-error")
    func everyMismatchIsHandoffErrorAtThePort() async throws {
        try await withRoots { roots in
            let appGroup = makeFileStore(root: roots.appGroup)
            let substituting = ReadRecordingStore(underlying: appGroup)
            let sessions = makeFileStore(root: roots.appPrivate)
            _ = try await publish(
                Sample.bytes(count: 700),
                sessionID: Sample.sessionID("session-port-0001"),
                over: substituting
            )
            let payloadKey = try #require(
                try await SharedTransferStore.test(over: substituting)
                    .readySlotState().publishedTransfer?.storageKey
            )
            await substituting.substitute(
                Sample.bytes(count: 700, seed: 99),
                for: payloadKey
            )
            let adapter = makeAdapter(appGroupStore: substituting, sessionStore: sessions)

            await #expect(
                throws: AnalysisFault.analysis(.handoffError, stage: .handoffVerification)
            ) {
                _ = try await adapter.claimReadyTransfer(claimingBuildID: Sample.buildID())
            }
        }
    }

    // MARK: - Material that never was a session

    @Test("A publication that never committed is discarded without failing a session")
    func uncommittedPublicationIsDiscarded() async throws {
        try await withRoots { roots in
            // A payload no manifest names: the state an interruption between the two
            // renames leaves. No ticket was readable, so no session was ever created and
            // there is nothing to terminate with an error.
            let appGroup = makeFileStore(root: roots.appGroup)
            let sessions = makeFileStore(root: roots.appPrivate)
            let transferID = Sample.transferID("dddd0000dddd0000dddd0000dddd0000")
            try await plantReadySlot(
                transferID: transferID,
                payload: Sample.bytes(count: 500),
                includeManifest: false,
                in: appGroup
            )
            let adapter = makeAdapter(appGroupStore: appGroup, sessionStore: sessions)

            #expect(
                await adapter.attemptClaim(claimingBuildID: Sample.buildID())
                    == .discarded(
                        .defective(
                            DefectiveTransfer(
                                transferID: transferID,
                                pendingSession: nil,
                                defect: .manifestMissing
                            )
                        )
                    )
            )
            // Through the port this is `nil`, never `handoff-error`: there is no session.
            let claimed = try await adapter.claimReadyTransfer(
                claimingBuildID: Sample.buildID()
            )
            #expect(claimed == nil)
            #expect(await transferScopes(of: appGroup).isEmpty)
            #expect(await sessionScopes(of: sessions).isEmpty)
        }
    }

    @Test("An expired pending handoff is discarded rather than failed")
    func expiredPendingHandoffIsDiscarded() async throws {
        try await withRoots { roots in
            // Expiry is the injected lifecycle policy's deadline measured from the ticket's
            // own timestamp. An expired handoff is discarded under that policy, not
            // reported as a failed analysis.
            let appGroup = makeFileStore(root: roots.appGroup)
            let sessions = makeFileStore(root: roots.appPrivate)
            let transferID = Sample.transferID("bbbb0000bbbb0000bbbb0000bbbb0000")
            try await plantReadySlot(
                transferID: transferID,
                payload: Sample.bytes(count: 400),
                createdAt: fixtureNow,
                in: appGroup
            )
            let adapter = makeAdapter(
                appGroupStore: appGroup,
                sessionStore: sessions,
                now: fixtureNow.addingTimeInterval(120),
                lifecyclePolicy: Sample.lifecyclePolicy(abandonedMilliseconds: 60_000)
            )

            #expect(await adapter.attemptClaim(claimingBuildID: Sample.buildID())
                == .discarded(.expired(transferID)))
            #expect(await transferScopes(of: appGroup).isEmpty)
            #expect(await sessionScopes(of: sessions).isEmpty)
        }
    }

    @Test("A slot the store cannot resolve names no session")
    func unresolvableSlotNamesNoSession() async throws {
        try await withRoots { roots in
            // Reads fail, so the manifest cannot be resolved and no ticket is readable.
            // Fail closed without attributing a failure to a session that may not exist.
            let appGroup = makeFileStore(root: roots.appGroup)
            let sessions = makeFileStore(root: roots.appPrivate)
            try await plantReadySlot(
                transferID: Sample.transferID("cccc0000cccc0000cccc0000cccc0000"),
                payload: Sample.bytes(count: 300),
                in: appGroup
            )
            let adapter = makeAdapter(
                appGroupStore: FailingReadStore(underlying: appGroup),
                sessionStore: sessions
            )

            let outcome = await adapter.attemptClaim(claimingBuildID: Sample.buildID())

            #expect(outcome.verifiedHandoff == nil)
            #expect(outcome.failedHandoff == nil)
            guard case .unresolvable = outcome else {
                Issue.record("an unreadable slot must be unresolvable, got \(outcome)")
                return
            }
            let claimed = try await adapter.claimReadyTransfer(
                claimingBuildID: Sample.buildID()
            )
            #expect(claimed == nil)
            #expect(await sessionScopes(of: sessions).isEmpty)
        }
    }

    // MARK: - Resource ceilings

    @Test("A bounded storage ceiling is resource-limit rather than a handoff mismatch")
    func storageCeilingIsResourceLimit() async throws {
        try await withRoots { roots in
            // A ceiling that was actually reached is not a corrupted transfer. Reporting it
            // as `handoff-error` would tell a user their image changed in transit when it
            // did not; the same rule the Photos route and the staging path apply.
            let appGroup = makeFileStore(root: roots.appGroup)
            let sessions = makeFileStore(root: roots.appPrivate, capacityInBytes: 64)
            let session = Sample.sessionID("session-ceiling-0001")
            _ = try await publish(Sample.bytes(count: 4_096), sessionID: session, over: appGroup)
            let adapter = makeAdapter(appGroupStore: appGroup, sessionStore: sessions)

            let failed = try #require(
                await adapter.attemptClaim(claimingBuildID: Sample.buildID()).failedHandoff
            )

            #expect(failed.sessionID == session)
            #expect(
                failed.failure
                    == .recopyRefused(.capacityExceeded(scope: .session(session)))
            )
            #expect(failed.fault == .analysis(.resourceLimit, stage: .handoffVerification))
            #expect(await transferScopes(of: appGroup).isEmpty)
            #expect(await sessionScopes(of: sessions).isEmpty)
        }
    }

    // MARK: - Vocabulary

    @Test("Every mismatch the claim can report has a distinct stable key")
    func mismatchKeysAreDistinct() {
        // The keys appear in audit records, so a collision would make two different
        // findings indistinguishable after the fact.
        let keys = HandoffMismatch.allCases.map(\.rawValue)
        #expect(Set(keys).count == HandoffMismatch.allCases.count)
        #expect(keys.allSatisfy { !$0.isEmpty })
    }
}

// MARK: - The corruption and observation double

/// A store that records which objects were read and can substitute one object's bytes.
///
/// Two capabilities, because the claim path has two things a real store cannot be made to
/// demonstrate on a host:
///
///   * **Substitution** models the one failure the design says the claim exists to catch:
///     the payload's bytes changing after the extension finalized them, while the
///     measurements the extension recorded stay as written. There is no other way to reach
///     it — the store hashes during the write, so a coherent slot's bytes always hash to
///     its own ticket, and a test that could not corrupt them could only ever assert that
///     a correct handoff verifies.
///   * **Read recording** turns "no byte of the payload was read" into an assertion. That
///     ordering claim is most of what the cheap checks are for, and it is a nonoccurrence,
///     so it cannot be observed from the result.
///
/// Everything else forwards to the real store, so publication, promotion, claim, and
/// deletion are the real renames on the real file system.
actor ReadRecordingStore: EphemeralFileStoring {
    private let underlying: ProtectedEphemeralFileStore
    private var substitutions: [EphemeralStorageKey: [UInt8]] = [:]
    private var reads: Set<EphemeralStorageKey> = []

    init(underlying: ProtectedEphemeralFileStore) {
        self.underlying = underlying
    }

    // MARK: Programming and inspection

    /// Makes reads of `key` return `bytes` instead of what is on disk.
    func substitute(_ bytes: [UInt8], for key: EphemeralStorageKey) {
        substitutions[key] = bytes
    }

    /// Every object read so far.
    func readKeys() -> Set<EphemeralStorageKey> { reads }

    /// Forgets the reads recorded so far, so a test can scope its assertion to one call.
    func forgetReads() {
        reads.removeAll()
    }

    // MARK: EphemeralFileStoring

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
        reads.insert(key)
        if let substituted = substitutions[key] { return substituted }
        return try await underlying.read(key)
    }

    /// Deliberately the real receipt, never the substituted length.
    ///
    /// That asymmetry is the whole point: the recorded measurements are what the extension
    /// wrote, and the bytes are what the claiming process finds. A double that adjusted the
    /// receipt to match the substitution would describe a coherent object and prove
    /// nothing.
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
