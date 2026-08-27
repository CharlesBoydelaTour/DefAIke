import DefAIkeDomain
import Foundation

/// Where a fake staging run stops, for interruption tests.
///
/// The Share Extension can be interrupted at any point, and the requirement is that
/// nothing before atomic publication leaves a session, a ready slot, or any evidence
/// behind (Requirement 2.4 and Property 7). Each case names one boundary the interruption
/// can land on, and ``publication`` is the only one after which a ready slot may exist.
public enum StagingInterruption: String, Hashable, Sendable, CaseIterable {
    /// Before the store object is created.
    case beforeCreate
    /// After creation, part-way through streaming the bytes.
    case duringCopy
    /// After the last chunk, before the object is finalized.
    case beforeFinalize
    /// After finalize, before the atomic promotion to `ready`.
    case beforePublication
    /// After the atomic promotion. The transfer exists from here.
    case afterPublication
}

/// An in-memory ``ShareTransferStaging`` and ``ShareTransferClaiming`` pair.
///
/// Backed by ``InMemoryEphemeralStore``, so it needs no App Group, no
/// `NSFileCoordinator`, and no file system, and the whole `staging` → `ready` → `claimed`
/// progression is observable through ``slotState(of:)``.
///
/// What it models faithfully:
///
///   * consent is required by the port signature, so bytes cannot be read without it;
///   * exactly one ready slot, so a second staging attempt while one is pending fails
///     rather than replacing a handoff the user already consented to;
///   * promotion is one atomic move, so an interruption before it leaves no ready slot,
///     no session, and no evidence;
///   * a claim recopies, recomputes the digest and byte count, and compares them against
///     the ticket before returning anything; and
///   * any mismatch is `handoff-error` and deletes the failed transfer.
///
/// What it does not model: real file coordination, real data protection, and real process
/// termination. Those are integration and physical-device concerns (task 4.10).
public actor FakeShareTransferStore: ShareTransferStaging, ShareTransferClaiming {
    private let store: InMemoryEphemeralStore
    private let clock: VirtualSessionClock
    private let recorder: PortCallRecorder?
    private let extensionBuildID: AppBuildID
    private let extensionExecutionPolicyID: ArtifactID
    private let stagedProtection: FileProtectionLevel

    /// Bytes the fake provider will hand over, keyed by provider token.
    private var providerBytes: [ProviderToken: [UInt8]] = [:]
    private var providerFailures: Set<ProviderToken> = []
    private var preservation: (status: BytePreservationStatus, basis: PreservationBasis)
    private var tickets: [ShareTransferID: ShareTransferTicket] = [:]
    private var slotKeys: [ShareTransferID: EphemeralStorageKey] = [:]
    private var slotStates: [ShareTransferID: TransferSlotState] = [:]
    private var interruption: StagingInterruption?
    private var nextTransferNumber = 1

    /// Bytes the claiming process will observe, when a test wants them to differ from
    /// what was staged. Simulates corruption across the process boundary.
    private var tamperedBytes: [ShareTransferID: [UInt8]] = [:]

    public init(
        store: InMemoryEphemeralStore,
        clock: VirtualSessionClock,
        extensionBuildID: AppBuildID,
        extensionExecutionPolicyID: ArtifactID,
        stagedProtection: FileProtectionLevel = .complete,
        recorder: PortCallRecorder? = nil
    ) {
        self.store = store
        self.clock = clock
        self.extensionBuildID = extensionBuildID
        self.extensionExecutionPolicyID = extensionExecutionPolicyID
        self.stagedProtection = stagedProtection
        self.recorder = recorder
        self.preservation = (
            status: .unknown,
            basis: .preservationHistoryNotEstablished
        )
    }

    // MARK: - Programming

    /// Registers the bytes a provider token will supply.
    public func setProviderBytes(_ bytes: [UInt8], for token: ProviderToken) {
        providerBytes[token] = bytes
    }

    /// Makes a provider fail before any byte is held.
    public func failProvider(_ token: ProviderToken) {
        providerFailures.insert(token)
    }

    /// Sets the preservation status and basis staging will record.
    ///
    /// The pair is validated by ``ShareTransferTicket`` and ``ImportedEncodedAsset``, so a
    /// status a basis does not support cannot be staged even from a test.
    public func setPreservation(
        status: BytePreservationStatus,
        basis: PreservationBasis
    ) {
        preservation = (status: status, basis: basis)
    }

    /// Stops the next staging run at `interruption`.
    public func interruptStaging(at interruption: StagingInterruption?) {
        self.interruption = interruption
    }

    /// Replaces the bytes the claiming process will read for `transferID`.
    ///
    /// The single mutation lever for Property 6: the digest recomputed on claim will not
    /// match the ticket.
    public func tamperPayload(of transferID: ShareTransferID, with bytes: [UInt8]) {
        tamperedBytes[transferID] = bytes
    }

    /// Replaces a published ticket, for field-level mutation tests.
    ///
    /// Only a structurally valid ticket can be installed, which is the point: the
    /// invariants ``ShareTransferTicket`` enforces are unreachable mutations, and this
    /// covers the ones that are reachable.
    public func replaceTicket(_ ticket: ShareTransferTicket) {
        tickets[ticket.transferID] = ticket
    }

    // MARK: - Inspection

    public func slotState(of transferID: ShareTransferID) -> TransferSlotState? {
        slotStates[transferID]
    }

    /// Transfers currently in the ready slot. At most one, always.
    public func readyTransferIDs() -> Set<ShareTransferID> {
        Set(slotStates.filter { $0.value == .ready }.map(\.key))
    }

    public func ticket(for transferID: ShareTransferID) -> ShareTransferTicket? {
        tickets[transferID]
    }

    // MARK: - ShareTransferStaging

    public func stageOne(
        _ provider: SharedItemProvider,
        consent: ConfirmedConsent
    ) async throws(AnalysisFault) -> ShareTransferTicket {
        guard consent.provider == provider else {
            // Consent for one provider cannot be replayed for another.
            throw .analysis(.handoffError, stage: .handoffVerification)
        }
        guard consent.extensionExecutionPolicyID == extensionExecutionPolicyID else {
            throw .analysis(.handoffError, stage: .handoffVerification)
        }
        guard readyTransferIDs().isEmpty else {
            // One ready slot. A consented pending handoff is never replaced silently.
            throw .analysis(.handoffError, stage: .handoffVerification)
        }
        guard !providerFailures.contains(provider.token) else {
            // Provider failure before any byte is held: no session, no ready slot.
            throw .analysis(.handoffError, stage: .handoffVerification)
        }

        let transferID = makeTransferID()
        let sessionID = makeSessionID(for: transferID)
        recorder?.record(.shareStage(transferID))

        if interruption == .beforeCreate {
            return try interrupted()
        }

        let bytes = providerBytes[provider.token] ?? []
        let stagingScope = EphemeralStorageScope.transfer(transferID, .staging)

        let key: EphemeralStorageKey
        do {
            key = try await store.create(in: stagingScope, protection: stagedProtection)
        } catch {
            throw .analysis(.resourceLimit, stage: .handoffVerification)
        }
        slotKeys[transferID] = key
        slotStates[transferID] = .staging

        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 64, bytes.count)
            if interruption == .duringCopy, offset > 0 {
                await discardStaging(transferID)
                return try interrupted()
            }
            do {
                try await store.append(Array(bytes[offset..<end]), to: key)
            } catch {
                await discardStaging(transferID)
                throw .analysis(.resourceLimit, stage: .handoffVerification)
            }
            offset = end
        }

        if interruption == .beforeFinalize {
            await discardStaging(transferID)
            return try interrupted()
        }

        let receipt: EphemeralWriteReceipt
        do {
            receipt = try await store.finalize(key)
        } catch {
            await discardStaging(transferID)
            throw .analysis(.resourceLimit, stage: .handoffVerification)
        }

        guard let ticket = ShareTransferTicket(
            transferID: transferID,
            sessionID: sessionID,
            contentTypeHint: provider.contentTypeHint,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256,
            preservationStatus: preservation.status,
            preservationBasis: preservation.basis,
            extensionBuildID: extensionBuildID,
            createdAt: clock.wallClockNow
        ) else {
            // An empty or inconsistent payload is not publishable.
            await discardStaging(transferID)
            throw .analysis(.handoffError, stage: .handoffVerification)
        }

        if interruption == .beforePublication {
            await discardStaging(transferID)
            return try interrupted()
        }

        // The commit point: one atomic move, after which a pending session exists.
        do {
            try await store.move(key, to: .transfer(transferID, .ready))
        } catch {
            await discardStaging(transferID)
            throw .analysis(.handoffError, stage: .handoffVerification)
        }
        slotStates[transferID] = .ready
        tickets[transferID] = ticket
        return ticket
    }

    public func discardStagedMaterial(
        policy: DataLifecyclePolicy
    ) async throws(EphemeralStoreError) -> Void {
        recorder?.record(.shareDiscardStaged)
        for transferID in slotStates.filter({ $0.value == .staging }).map(\.key) {
            _ = try await store.deleteAll(
                in: .transfer(transferID, .staging),
                reason: .interrupted
            )
            slotStates.removeValue(forKey: transferID)
            slotKeys.removeValue(forKey: transferID)
            tickets.removeValue(forKey: transferID)
        }
    }

    // MARK: - ShareTransferClaiming

    public func peekReadyTransfer() async throws(EphemeralStoreError) -> ReadyTransfer? {
        recorder?.record(.sharePeek)
        guard let transferID = readyTransferIDs().first,
              let ticket = tickets[transferID],
              let key = slotKeys[transferID]
        else {
            return nil
        }
        return ReadyTransfer(ticket: ticket, storageKey: key)
    }

    public func claimReadyTransfer(
        claimingBuildID: AppBuildID
    ) async throws(AnalysisFault) -> ImportedEncodedAsset? {
        recorder?.record(.shareClaim)
        guard let transferID = readyTransferIDs().first,
              let ticket = tickets[transferID],
              let stagedKey = slotKeys[transferID]
        else {
            return nil
        }

        // Take ownership first, so a second claimer cannot also claim it.
        do {
            try await store.move(stagedKey, to: .transfer(transferID, .claimed))
        } catch {
            throw .analysis(.handoffError, stage: .handoffVerification)
        }
        slotStates[transferID] = .claimed

        // Recopy into session-owned storage and recompute both measurements.
        var observed: [UInt8]
        if let tampered = tamperedBytes[transferID] {
            observed = tampered
        } else {
            observed = (try? await store.read(stagedKey)) ?? []
        }
        let sessionScope = EphemeralStorageScope.session(ticket.sessionID)
        let receipt: EphemeralWriteReceipt
        do {
            receipt = try await store.writeComplete(observed, in: sessionScope)
        } catch {
            await deleteFailedTransfer(transferID, sessionID: ticket.sessionID)
            throw .analysis(.resourceLimit, stage: .handoffVerification)
        }

        guard ticket.matches(
            recomputedByteCount: receipt.byteCount,
            recomputedDigest: receipt.sha256,
            claimingBuildID: claimingBuildID
        ) else {
            await deleteFailedTransfer(transferID, sessionID: ticket.sessionID)
            throw .analysis(.handoffError, stage: .handoffVerification)
        }

        guard let handle = EncodedAssetHandle(sessionID: ticket.sessionID, receipt: receipt),
              let asset = ImportedEncodedAsset(
                  route: ticket.route,
                  handle: handle,
                  preservationStatus: ticket.preservationStatus,
                  preservationBasis: ticket.preservationBasis,
                  contentTypeHint: ticket.contentTypeHint
              )
        else {
            await deleteFailedTransfer(transferID, sessionID: ticket.sessionID)
            throw .analysis(.handoffError, stage: .handoffVerification)
        }

        // The transfer slot is done; the session now owns the bytes.
        _ = try? await store.deleteAll(in: .transfer(transferID, .claimed), reason: .completed)
        slotStates.removeValue(forKey: transferID)
        slotKeys.removeValue(forKey: transferID)
        tickets.removeValue(forKey: transferID)
        return asset
    }

    // MARK: - Helpers

    private func interrupted() throws(AnalysisFault) -> ShareTransferTicket {
        // An interruption is not a user-facing error and not a session: the extension
        // simply stops. Modelled as cancellation so no Analysis Error is invented.
        throw .cancelled
    }

    private func discardStaging(_ transferID: ShareTransferID) async {
        _ = try? await store.deleteAll(in: .transfer(transferID, .staging), reason: .interrupted)
        slotStates.removeValue(forKey: transferID)
        slotKeys.removeValue(forKey: transferID)
        tickets.removeValue(forKey: transferID)
    }

    private func deleteFailedTransfer(
        _ transferID: ShareTransferID,
        sessionID: AnalysisSessionID
    ) async {
        for state in TransferSlotState.allCases {
            _ = try? await store.deleteAll(
                in: .transfer(transferID, state),
                reason: .errorTerminated
            )
        }
        _ = try? await store.deleteAll(in: .session(sessionID), reason: .errorTerminated)
        slotStates.removeValue(forKey: transferID)
        slotKeys.removeValue(forKey: transferID)
        tickets.removeValue(forKey: transferID)
    }

    private func makeTransferID() -> ShareTransferID {
        let raw = "transfer-\(String(format: "%04d", nextTransferNumber))"
        nextTransferNumber += 1
        guard let id = ShareTransferID(raw) else {
            preconditionFailure("generated transfer identifier is not canonical: \(raw)")
        }
        return id
    }

    private func makeSessionID(for transferID: ShareTransferID) -> AnalysisSessionID {
        let raw = "session-\(transferID.rawValue)"
        guard let id = AnalysisSessionID(raw) else {
            preconditionFailure("generated session identifier is not canonical: \(raw)")
        }
        return id
    }
}
