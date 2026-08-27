import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeSharedTransfer

// MARK: - Namespace doubles

/// A namespace that refuses to clear one session, so the fail-closed path is reachable
/// without a file system that rejects a removal.
///
/// It wraps a real store, so everything except the refusal behaves exactly as the shipping
/// namespace does. That matters: a double that also faked the listing could not show that a
/// failed removal leaves the material *findable* by the next start.
struct RefusingSessionNamespace: SessionStorageNamespace {
    let underlying: ProtectedEphemeralFileStore
    let refusedSession: AnalysisSessionID
    let fault: EphemeralStoreError

    func sessionsWithStoredMaterial() async -> Set<AnalysisSessionID> {
        await underlying.sessionsWithStoredMaterial()
    }

    func clearSessionMaterial(
        for sessionID: AnalysisSessionID,
        reason: SessionCleanupReason
    ) async throws(EphemeralStoreError) -> EphemeralDeletionReceipt {
        guard sessionID != refusedSession else { throw fault }
        return try await underlying.clearSessionMaterial(for: sessionID, reason: reason)
    }
}

/// A namespace that reports a removal it did not perform.
///
/// Stands in for a store whose deletion silently left something behind. The deleter has to
/// catch that itself, because a caller only ever sees the receipt.
struct DishonestSessionNamespace: SessionStorageNamespace {
    let underlying: ProtectedEphemeralFileStore

    func sessionsWithStoredMaterial() async -> Set<AnalysisSessionID> {
        await underlying.sessionsWithStoredMaterial()
    }

    func clearSessionMaterial(
        for sessionID: AnalysisSessionID,
        reason: SessionCleanupReason
    ) async throws(EphemeralStoreError) -> EphemeralDeletionReceipt {
        // Removes nothing and claims success.
        EphemeralDeletionReceipt(
            scope: .session(sessionID),
            reason: reason,
            removedObjectCount: 1,
            completedAt: fixtureNow
        )
    }
}

// MARK: - Suite

/// The Privacy Controller's deletion adapter, against the real file system.
///
/// The subject is what is *left*, not what was attempted, so most assertions here look at
/// the namespaces after the call rather than at its return value. Requirement 9.17 is
/// satisfied by an empty file system, and a receipt is only an audit trail for it.
///
/// The real store and real protection applier are used deliberately: session cleanup deletes
/// directories, and a dictionary-backed double cannot show that a scope marker went with
/// them.
@Suite("Protected session data deleter")
struct ProtectedSessionDataDeleterTests {

    // MARK: - Scaffolding

    private func makeStore(root: URL) -> ProtectedEphemeralFileStore {
        ProtectedEphemeralFileStore(
            configuration: .test(root: root),
            protection: PlatformDataProtection(),
            clock: FixedClock(fixtureNow)
        )
    }

    private func makeDeleter(
        namespaces: [any SessionStorageNamespace],
        transfers: SharedTransferStore? = nil
    ) -> ProtectedSessionDataDeleter {
        ProtectedSessionDataDeleter(
            namespaces: namespaces,
            transfers: transfers,
            clock: FixedClock(fixtureNow)
        )
    }

    /// Writes one complete object into a session's scope.
    @discardableResult
    private func writeSessionObject(
        _ bytes: [UInt8],
        for sessionID: AnalysisSessionID,
        to store: ProtectedEphemeralFileStore
    ) async throws -> EphemeralWriteReceipt {
        let key = try await store.create(in: .session(sessionID), protection: .complete)
        try await store.append(bytes, to: key)
        return try await store.finalize(key)
    }

    /// Every regular file under `root`, which is what "nothing is left" has to be measured
    /// against. An empty directory holds no data; a file does.
    private func remainingFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        return walker.compactMap { entry in
            guard let url = entry as? URL,
                (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else {
                return nil
            }
            return url
        }
    }

    // MARK: - Roots

    @Test("The app-private session root sits inside the process's own container")
    func appPrivateRootIsInsideTheContainer() throws {
        let temporaryDirectory = URL(fileURLWithPath: "/private/app/tmp", isDirectory: true)
        let root = SessionStorageRoots.appPrivateRoot(temporaryDirectory: temporaryDirectory)

        #expect(root.deletingLastPathComponent().path == temporaryDirectory.path)
        #expect(root.lastPathComponent == SessionStorageRoots.sessionDirectoryName)
        // The root is named, not created: the store applies the protection level at
        // creation, so nothing may exist before it does.
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("The session and transfer subtrees are siblings, not one shared directory")
    func sessionAndTransferSubtreesAreDistinct() {
        #expect(
            SessionStorageRoots.sessionDirectoryName
                != AppGroupContainer.transferDirectoryName
        )
    }

    @Test("The App Group session root is inside the container, never a process fallback")
    func appGroupRootHasNoFallback() throws {
        // The unavailable-container branch is not reachable on a development host: macOS
        // answers `containerURL(forSecurityApplicationGroupIdentifier:)` for any identifier,
        // whereas iOS answers `nil` without the entitlement. So what is checkable here is
        // the other half of "no fallback": when a container does resolve, the session root
        // is inside it, and nothing in this path can substitute a process-private
        // directory. The `nil` branch itself needs a device.
        let appGroupID = "group.dev.defaike.host.\(UUID().uuidString)"
        let container = try AppGroupContainer.container(forAppGroup: appGroupID)
        let root = try SessionStorageRoots.appGroupRoot(forAppGroup: appGroupID)

        #expect(root.deletingLastPathComponent().path == container.path)
        #expect(root.lastPathComponent == SessionStorageRoots.sessionDirectoryName)
        #expect(
            root.path
                != SessionStorageRoots.appPrivateRoot(
                    temporaryDirectory: FileManager.default.temporaryDirectory
                ).path
        )
        // Named, not created: the store applies the protection level at creation.
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - Terminal deletion

    @Test(
        "Every terminal reason removes the session and is audited against its own deadline",
        arguments: [
            (SessionEndReason.completed, SessionCleanupReason.completed, UInt64(1_000)),
            (SessionEndReason.cancelled, SessionCleanupReason.cancelled, UInt64(2_000)),
            (SessionEndReason.error, SessionCleanupReason.errorTerminated, UInt64(3_000)),
        ]
    )
    func terminalDeletionUsesTheReasonsOwnDeadline(
        endReason: SessionEndReason,
        cleanupReason: SessionCleanupReason,
        milliseconds: UInt64
    ) async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let deleter = makeDeleter(namespaces: [store])
            let session = Sample.sessionID()
            let policy = Sample.distinctDeadlinePolicy()
            try await writeSessionObject(Sample.bytes(count: 256), for: session, to: store)

            let receipt = try await deleter.deleteSession(
                session,
                reason: endReason,
                policy: policy
            )

            #expect(receipt.sessionID == session)
            #expect(receipt.reason == cleanupReason)
            #expect(receipt.removedObjectCount == 1)
            #expect(receipt.lifecyclePolicyID == policy.id)
            // The deadline is the policy's entry for this reason, read rather than chosen:
            // the fixture gives every reason a different number, so a mapping that picked
            // the wrong key would show up here.
            #expect(receipt.deadline.milliseconds == milliseconds)
            #expect(receipt.deadline == policy.deadline(for: cleanupReason))
            #expect(receipt.completedAt == fixtureNow)
            #expect(await store.knownScopes().isEmpty)
            #expect(remainingFiles(under: root).isEmpty)
        }
    }

    @Test("A terminal deletion removes every object the session owned, complete or not")
    func terminalDeletionRemovesIncompleteCopiesToo() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let deleter = makeDeleter(namespaces: [store])
            let session = Sample.sessionID()
            try await writeSessionObject(Sample.bytes(count: 128), for: session, to: store)
            try await writeSessionObject(
                Sample.bytes(count: 128, seed: 7),
                for: session,
                to: store
            )
            // An interrupted copy: created, appended to, never finalized.
            let partial = try await store.create(in: .session(session), protection: .complete)
            try await store.append(Sample.bytes(count: 64), to: partial)

            let receipt = try await deleter.deleteSession(
                session,
                reason: .error,
                policy: Sample.lifecyclePolicy()
            )

            #expect(receipt.removedObjectCount == 3)
            #expect(await store.unfinalizedKeys.isEmpty)
            #expect(try await store.usedByteCount() == 0)
            #expect(remainingFiles(under: root).isEmpty)
        }
    }

    @Test("A terminal deletion clears every app-controlled namespace, not just one")
    func terminalDeletionSpansEveryNamespace() async throws {
        try await withTemporaryRoot { appPrivate in
            try await withTemporaryRoot { appGroup in
                let privateStore = makeStore(root: appPrivate)
                let groupStore = makeStore(root: appGroup)
                let deleter = makeDeleter(namespaces: [privateStore, groupStore])
                let session = Sample.sessionID()
                // A resumed handoff owns material in both containers at once.
                try await writeSessionObject(
                    Sample.bytes(count: 100),
                    for: session,
                    to: privateStore
                )
                try await writeSessionObject(
                    Sample.bytes(count: 200),
                    for: session,
                    to: groupStore
                )

                let receipt = try await deleter.deleteSession(
                    session,
                    reason: .completed,
                    policy: Sample.lifecyclePolicy()
                )

                #expect(receipt.removedObjectCount == 2)
                #expect(await privateStore.knownScopes().isEmpty)
                #expect(await groupStore.knownScopes().isEmpty)
                #expect(remainingFiles(under: appPrivate).isEmpty)
                #expect(remainingFiles(under: appGroup).isEmpty)
            }
        }
    }

    @Test("Deleting one session leaves another session's material untouched")
    func terminalDeletionIsScopedToOneSession() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let deleter = makeDeleter(namespaces: [store])
            let doomed = Sample.sessionID("session-0001")
            let kept = Sample.sessionID("session-0002")
            try await writeSessionObject(Sample.bytes(count: 32), for: doomed, to: store)
            let keptReceipt = try await writeSessionObject(
                Sample.bytes(count: 32),
                for: kept,
                to: store
            )

            _ = try await deleter.deleteSession(
                doomed,
                reason: .cancelled,
                policy: Sample.lifecyclePolicy()
            )

            #expect(await store.keys(in: .session(kept)) == [keptReceipt.key])
            #expect(await store.knownScopes() == [.session(kept)])
        }
    }

    @Test("Repeating a terminal deletion removes nothing and still succeeds")
    func terminalDeletionIsIdempotent() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let deleter = makeDeleter(namespaces: [store])
            let session = Sample.sessionID()
            let policy = Sample.lifecyclePolicy()
            try await writeSessionObject(Sample.bytes(count: 64), for: session, to: store)

            let first = try await deleter.deleteSession(
                session,
                reason: .completed,
                policy: policy
            )
            let second = try await deleter.deleteSession(
                session,
                reason: .completed,
                policy: policy
            )
            let third = try await deleter.deleteSession(
                session,
                reason: .completed,
                policy: policy
            )

            #expect(first.removedObjectCount == 1)
            // A zero count is how an audit tells a repeated deletion from the first one.
            #expect(second.removedObjectCount == 0)
            #expect(third.removedObjectCount == 0)
            // Nothing was resurrected and nothing partially reappeared.
            #expect(second.deadline == first.deadline)
            #expect(third.reason == first.reason)
            #expect(await store.knownScopes().isEmpty)
            #expect(remainingFiles(under: root).isEmpty)
        }
    }

    @Test("A namespace that refuses a removal fails the deletion rather than reporting one")
    func refusedRemovalFailsClosed() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let session = Sample.sessionID()
            try await writeSessionObject(Sample.bytes(count: 48), for: session, to: store)
            let deleter = makeDeleter(namespaces: [
                RefusingSessionNamespace(
                    underlying: store,
                    refusedSession: session,
                    fault: .storeUnavailable
                )
            ])

            await #expect(throws: EphemeralStoreError.storeUnavailable) {
                _ = try await deleter.deleteSession(
                    session,
                    reason: .completed,
                    policy: Sample.lifecyclePolicy()
                )
            }
            // No receipt was issued for a deletion that did not happen, and the material is
            // still findable so the next start removes it as abandoned.
            #expect(await deleter.retainedRecords().sessionReceipts.isEmpty)
            #expect(await store.knownScopes() == [.session(session)])
        }
    }

    @Test("One refusing namespace does not stop the others from being emptied")
    func refusalStillClearsEveryOtherNamespace() async throws {
        try await withTemporaryRoot { refusing in
            try await withTemporaryRoot { cooperating in
                let refusingStore = makeStore(root: refusing)
                let cooperatingStore = makeStore(root: cooperating)
                let session = Sample.sessionID()
                try await writeSessionObject(
                    Sample.bytes(count: 40),
                    for: session,
                    to: refusingStore
                )
                try await writeSessionObject(
                    Sample.bytes(count: 40),
                    for: session,
                    to: cooperatingStore
                )
                let deleter = makeDeleter(namespaces: [
                    RefusingSessionNamespace(
                        underlying: refusingStore,
                        refusedSession: session,
                        fault: .storeUnavailable
                    ),
                    cooperatingStore,
                ])

                await #expect(throws: EphemeralStoreError.storeUnavailable) {
                    _ = try await deleter.deleteSession(
                        session,
                        reason: .completed,
                        policy: Sample.lifecyclePolicy()
                    )
                }
                // Partial removal leaves strictly less on disk than stopping would.
                #expect(await cooperatingStore.knownScopes().isEmpty)
                #expect(await refusingStore.knownScopes() == [.session(session)])
            }
        }
    }

    @Test("A namespace that reports a removal it did not perform fails the deletion")
    func incompleteRemovalIsDetected() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let session = Sample.sessionID()
            try await writeSessionObject(Sample.bytes(count: 24), for: session, to: store)
            let deleter = makeDeleter(namespaces: [
                DishonestSessionNamespace(underlying: store)
            ])

            // The namespace returned a receipt claiming one object was removed. Requirement
            // 9.17 is about what is left, so the deleter checks rather than believing it.
            await #expect(throws: EphemeralStoreError.storeUnavailable) {
                _ = try await deleter.deleteSession(
                    session,
                    reason: .completed,
                    policy: Sample.lifecyclePolicy()
                )
            }
            #expect(await deleter.retainedRecords().sessionReceipts.isEmpty)
        }
    }

    // MARK: - Startup cleanup

    @Test("Startup cleanup removes every session found with no live session")
    func startupCleanupRemovesAbandonedSessions() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let deleter = makeDeleter(namespaces: [store])
            let policy = Sample.distinctDeadlinePolicy()
            let first = Sample.sessionID("session-0001")
            let second = Sample.sessionID("session-0002")
            try await writeSessionObject(Sample.bytes(count: 64), for: first, to: store)
            try await writeSessionObject(Sample.bytes(count: 64), for: second, to: store)
            // An interrupted copy is abandoned material too.
            let partial = try await store.create(in: .session(second), protection: .complete)
            try await store.append(Sample.bytes(count: 16), to: partial)

            let receipts = try await deleter.deleteAbandonedData(policy: policy)

            #expect(receipts.map(\.sessionID) == [first, second])
            #expect(receipts.allSatisfy { $0.reason == .abandoned })
            // `StartupPreflight` checks the reason and the deadline on every startup
            // receipt, so both have to come from the abandoned entry specifically.
            #expect(receipts.allSatisfy { $0.deadline == policy.deadline(for: .abandoned) })
            #expect(receipts.allSatisfy { $0.lifecyclePolicyID == policy.id })
            #expect(receipts.map(\.removedObjectCount) == [1, 2])
            #expect(await store.knownScopes().isEmpty)
            #expect(remainingFiles(under: root).isEmpty)
        }
    }

    @Test("Startup cleanup removes an emptied scope directory's marker too")
    func startupCleanupRemovesScopeResidue() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let deleter = makeDeleter(namespaces: [store])
            let session = Sample.sessionID()
            // A create that failed leaves the scope directory and its marker with no
            // objects in it. It holds no bytes, but it does name the session.
            _ = try await store.create(in: .session(session), protection: .complete)
            _ = try await store.deleteAll(in: .session(session), reason: .interrupted)
            _ = try await store.create(in: .session(session), protection: .complete)
            #expect(!remainingFiles(under: root).isEmpty)

            let receipts = try await deleter.deleteAbandonedData(policy: Sample.lifecyclePolicy())

            #expect(receipts.count == 1)
            #expect(await store.knownScopes().isEmpty)
            #expect(remainingFiles(under: root).isEmpty)
        }
    }

    @Test("Startup cleanup with nothing abandoned succeeds and reports nothing")
    func startupCleanupOnAnEmptyStoreSucceeds() async throws {
        try await withTemporaryRoot { root in
            let deleter = makeDeleter(namespaces: [makeStore(root: root)])

            let receipts = try await deleter.deleteAbandonedData(policy: Sample.lifecyclePolicy())

            // Empty means there was nothing to remove, which is a success. It never means
            // cleanup was skipped.
            #expect(receipts.isEmpty)
        }
    }

    @Test("Repeating startup cleanup removes nothing and still succeeds")
    func startupCleanupIsIdempotent() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let deleter = makeDeleter(namespaces: [store])
            let policy = Sample.lifecyclePolicy()
            try await writeSessionObject(
                Sample.bytes(count: 96),
                for: Sample.sessionID(),
                to: store
            )

            let first = try await deleter.deleteAbandonedData(policy: policy)
            let second = try await deleter.deleteAbandonedData(policy: policy)
            let third = try await deleter.deleteAbandonedData(policy: policy)

            #expect(first.count == 1)
            #expect(second.isEmpty)
            #expect(third.isEmpty)
            #expect(await store.knownScopes().isEmpty)
            #expect(remainingFiles(under: root).isEmpty)
        }
    }

    @Test("One session's material is merged into one receipt across namespaces")
    func startupCleanupMergesNamespacesPerSession() async throws {
        try await withTemporaryRoot { appPrivate in
            try await withTemporaryRoot { appGroup in
                let privateStore = makeStore(root: appPrivate)
                let groupStore = makeStore(root: appGroup)
                let deleter = makeDeleter(namespaces: [privateStore, groupStore])
                let session = Sample.sessionID()
                try await writeSessionObject(
                    Sample.bytes(count: 32),
                    for: session,
                    to: privateStore
                )
                try await writeSessionObject(
                    Sample.bytes(count: 32),
                    for: session,
                    to: groupStore
                )

                let receipts = try await deleter.deleteAbandonedData(
                    policy: Sample.lifecyclePolicy()
                )

                // One session is one receipt, whichever containers it was spread across.
                #expect(receipts.count == 1)
                #expect(receipts.first?.removedObjectCount == 2)
                #expect(await privateStore.knownScopes().isEmpty)
                #expect(await groupStore.knownScopes().isEmpty)
            }
        }
    }

    @Test("A refused startup removal fails the whole cleanup")
    func refusedStartupRemovalFailsClosed() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let session = Sample.sessionID()
            try await writeSessionObject(Sample.bytes(count: 80), for: session, to: store)
            let deleter = makeDeleter(namespaces: [
                RefusingSessionNamespace(
                    underlying: store,
                    refusedSession: session,
                    fault: .storeUnavailable
                )
            ])

            // The throw is the mechanism that keeps ingest closed: `StartupPreflight` turns
            // it into `startupCleanupFailed`, and `ReleaseAdmission` — the only value that
            // permits ingest — is never produced.
            await #expect(throws: EphemeralStoreError.storeUnavailable) {
                _ = try await deleter.deleteAbandonedData(policy: Sample.lifecyclePolicy())
            }
            #expect(await deleter.retainedRecords().sessionReceipts.isEmpty)
            #expect(await store.knownScopes() == [.session(session)])
        }
    }

    @Test("A startup removal that only claims to have happened fails the cleanup")
    func incompleteStartupRemovalFailsClosed() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let session = Sample.sessionID()
            try await writeSessionObject(Sample.bytes(count: 72), for: session, to: store)
            let deleter = makeDeleter(namespaces: [
                DishonestSessionNamespace(underlying: store)
            ])

            // This is the case that would otherwise pass the startup gate: no namespace
            // refused, so nothing threw, and the receipts would look like a clean start with
            // analyzable bytes still on disk. The completeness check is what stops it.
            await #expect(throws: EphemeralStoreError.storeUnavailable) {
                _ = try await deleter.deleteAbandonedData(policy: Sample.lifecyclePolicy())
            }
            #expect(await deleter.retainedRecords().sessionReceipts.isEmpty)
            #expect(await store.knownScopes() == [.session(session)])
        }
    }

    @Test("A deleter that owns no namespace removes nothing and claims nothing")
    func emptyNamespaceListIsHonest() async throws {
        let deleter = makeDeleter(namespaces: [])

        let receipts = try await deleter.deleteAbandonedData(policy: Sample.lifecyclePolicy())
        let terminal = try await deleter.deleteSession(
            Sample.sessionID(),
            reason: .completed,
            policy: Sample.lifecyclePolicy()
        )

        #expect(receipts.isEmpty)
        #expect(terminal.removedObjectCount == 0)
    }

    // MARK: - Namespace separation

    @Test("Session cleanup never touches transfer material in a shared root")
    func sessionCleanupLeavesTransferScopesAlone() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let deleter = makeDeleter(namespaces: [store])
            let session = Sample.sessionID()
            let transfer = Sample.transferID()
            try await writeSessionObject(Sample.bytes(count: 32), for: session, to: store)
            let staged = try await store.create(
                in: .transfer(transfer, .ready),
                protection: .complete
            )
            try await store.append(Sample.bytes(count: 32), to: staged)
            _ = try await store.finalize(staged)

            _ = try await deleter.deleteAbandonedData(policy: Sample.lifecyclePolicy())

            // The handoff lifecycle owns transfer scopes. A session sweep that removed them
            // would delete a pending handoff the user already consented to.
            #expect(await store.knownScopes() == [.transfer(transfer, .ready)])
            #expect(await store.keys(in: .transfer(transfer, .ready)) == [staged])
        }
    }

    @Test("Startup cleanup sweeps the transfer namespace through the transfer store")
    func startupCleanupSweepsTheTransferNamespace() async throws {
        try await withTemporaryRoot { sessions in
            try await withTemporaryRoot { transfersRoot in
                let sessionStore = makeStore(root: sessions)
                let transferStore = makeStore(root: transfersRoot)
                let transfers = SharedTransferStore.test(over: transferStore)
                let deleter = makeDeleter(
                    namespaces: [sessionStore],
                    transfers: transfers
                )
                // Staging residue an interrupted extension left behind.
                let staged = try await transferStore.create(
                    in: .transfer(Sample.transferID(), .staging),
                    protection: .complete
                )
                try await transferStore.append(Sample.bytes(count: 64), to: staged)
                _ = try await transferStore.finalize(staged)

                let receipts = try await deleter.deleteAbandonedData(
                    policy: Sample.lifecyclePolicy()
                )

                // A transfer slot names no session, so it produces a scope receipt rather
                // than a session receipt.
                #expect(receipts.isEmpty)
                let retained = await deleter.retainedRecords()
                #expect(retained.transferReceipts.count == 1)
                #expect(retained.transferReceipts.first?.reason == .interrupted)
                #expect(await transferStore.knownScopes().isEmpty)
                #expect(remainingFiles(under: transfersRoot).isEmpty)
            }
        }
    }

    @Test("A failing transfer namespace blocks startup cleanup too")
    func transferCleanupFailureFailsClosed() async throws {
        try await withTemporaryRoot { sessions in
            try await withTemporaryRoot { transfersRoot in
                let transferStore = makeStore(root: transfersRoot)
                // The published payload is readable, but reading the manifest to resolve the
                // slot fails, so the transfer store cannot decide what to keep.
                let key = try await transferStore.create(
                    in: .transfer(Sample.transferID(), .ready),
                    protection: .complete
                )
                try await transferStore.append(Sample.bytes(count: 32), to: key)
                _ = try await transferStore.finalize(key)
                let deleter = makeDeleter(
                    namespaces: [makeStore(root: sessions)],
                    transfers: SharedTransferStore.test(
                        over: FailingReadStore(underlying: transferStore)
                    )
                )

                await #expect(throws: EphemeralStoreError.storeUnavailable) {
                    _ = try await deleter.deleteAbandonedData(policy: Sample.lifecyclePolicy())
                }
                #expect(await deleter.retainedRecords().transferReceipts.isEmpty)
            }
        }
    }

    // MARK: - Retention allowlist

    @Test("Only non-image receipts survive a cleanup")
    func onlyReceiptsSurviveCleanup() async throws {
        try await withTemporaryRoot { root in
            let store = makeStore(root: root)
            let deleter = makeDeleter(namespaces: [store])
            let session = Sample.sessionID()
            try await writeSessionObject(Sample.bytes(count: 512), for: session, to: store)

            _ = try await deleter.deleteSession(
                session,
                reason: .completed,
                policy: Sample.lifecyclePolicy()
            )

            // Nothing image-derived is left on disk.
            #expect(remainingFiles(under: root).isEmpty)

            // And nothing image-derived is representable in what survives in memory. The
            // field names are pinned so a later field carrying bytes, dimensions, a digest
            // of user content, or evidence fails this test rather than passing silently.
            let retained = await deleter.retainedRecords()
            #expect(Self.fieldNames(of: retained) == ["sessionReceipts", "transferReceipts"])
            let receipt = try #require(retained.sessionReceipts.first)
            #expect(
                Self.fieldNames(of: receipt) == [
                    "completedAt",
                    "deadline",
                    "lifecyclePolicyID",
                    "reason",
                    "removedObjectCount",
                    "sessionID",
                ]
            )
        }
    }

    @Test("A scope deletion receipt carries no image-derived field either")
    func scopeReceiptsCarryNoImageMaterial() {
        let receipt = EphemeralDeletionReceipt(
            scope: .transfer(Sample.transferID(), .staging),
            reason: .interrupted,
            removedObjectCount: 1,
            completedAt: fixtureNow
        )
        #expect(
            Self.fieldNames(of: receipt) == [
                "completedAt",
                "reason",
                "removedObjectCount",
                "scope",
            ]
        )
    }

    /// Stored property names of `value`, sorted.
    private static func fieldNames(of value: Any) -> [String] {
        Mirror(reflecting: value).children.compactMap(\.label).sorted()
    }
}
