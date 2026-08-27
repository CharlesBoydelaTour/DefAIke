import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeSharedTransfer

/// Share Extension activation, consent, and staging, against the real file system.
///
/// Every test here is about one of four sentences the requirements make mandatory:
///
///   * Exactly one provider offering exactly one item may be handed off, and any other count
///     is refused before a byte is read (Requirement 2.7).
///   * Nothing reads, copies, hashes, or writes a byte until the visible consent action has
///     been confirmed, which is asserted as a nonoccurrence rather than by inspection
///     (Requirements 2.2 and 11.10).
///   * Successful atomic publication is the only Share-route session-creation commit, and a
///     decline, cancellation, provider failure, resource breach, or interruption before it
///     leaves no staging directory, no session, and no evidence (Requirements 2.4 and 11.8).
///   * The handoff ends with an instruction to open DefAIke, never with a launch
///     (Requirement 11.11 and design fixed decision 4).
///
/// The real store and the real protection applier are used deliberately: publication is a
/// rename on a real file system, and a double that models a rename as a dictionary update
/// cannot show that an interrupted publication leaves nothing resumable.
@Suite("Share Extension ingest coordinator")
struct ShareExtensionIngestCoordinatorTests {

    // MARK: - Scaffolding

    private func makeFileStore(
        root: URL,
        capacityInBytes: UInt64 = testCapacityInBytes,
        containerProtection: FileProtectionLevel = .complete,
        protection: any DataProtectionApplying = PlatformDataProtection()
    ) -> ProtectedEphemeralFileStore {
        ProtectedEphemeralFileStore(
            configuration: .test(
                root: root,
                capacityInBytes: capacityInBytes,
                containerProtection: containerProtection
            ),
            protection: protection,
            clock: FixedClock(fixtureNow)
        )
    }

    private func makeCoordinator(
        access: any SharedItemRepresentationAccess,
        consentPresenter: any ShareConsentPresenting,
        transfers: SharedTransferStore,
        governor: any ResourceGoverning,
        budget: ResourceBudget = Sample.shareBudget(),
        instruction: ManualOpenInstruction = Sample.manualInstruction(),
        candidateSessions: any CandidateSessionIdentifierSource =
            FixedCandidateSessionIdentifierSource()
    ) throws -> ShareExtensionIngestCoordinator {
        try #require(
            ShareExtensionIngestCoordinator(
                access: access,
                consentPresenter: consentPresenter,
                transfers: transfers,
                governor: governor,
                budget: budget,
                instruction: instruction,
                candidateSessions: candidateSessions
            )
        )
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

    // MARK: - One provider at runtime

    @Test("Only one provider offering one item resolves to a candidate")
    func onlyOneProviderOfferingOneItemResolves() {
        // Zero and many are representable so they can be refused, exactly as a picker
        // selection leaves its count unconstrained (Requirement 2.7 and Property 4).
        let provider = Sample.sharedProvider()
        #expect(Sample.activation(provider).resolvedCandidate == .oneItem(provider))
        #expect(
            ShareActivation(providers: []).resolvedCandidate == .refused(.noProviderOffered)
        )
        #expect(
            Sample.activation(provider, Sample.sharedProvider(token: 2)).resolvedCandidate
                == .refused(.providerCountUnsupported(2))
        )
        #expect(
            Sample.activation(Sample.sharedProvider(itemCount: 0)).resolvedCandidate
                == .refused(.itemCountUnsupported(0))
        )
        #expect(
            Sample.activation(Sample.sharedProvider(itemCount: 2)).resolvedCandidate
                == .refused(.itemCountUnsupported(2))
        )
    }

    @Test(
        "A refused activation never presents consent, never touches the host, and stages nothing",
        arguments: [
            ShareActivation(providers: []),
            Sample.activation(Sample.sharedProvider(), Sample.sharedProvider(token: 2)),
            Sample.activation(Sample.sharedProvider(itemCount: 0)),
            Sample.activation(Sample.sharedProvider(itemCount: 3)),
        ]
    )
    func refusedActivationHasNoSideEffect(activation: ShareActivation) async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let access = FakeSharedItemAccess.lending(Sample.bytes(count: 1_024))
            let presenter = ScriptedConsentPresenter.confirming()
            let transfers = SharedTransferStore.test(over: fileStore)
            let coordinator = try makeCoordinator(
                access: access,
                consentPresenter: presenter,
                transfers: transfers,
                governor: ProgrammedShareResourceGovernor()
            )

            let outcome = await coordinator.handleActivation(activation)

            guard case .activationRefused = outcome else {
                Issue.record("expected a refused activation, got \(outcome)")
                return
            }
            // The refusal is decided before anything is asked of the host, so the consent
            // action never appeared and no byte of any item was read.
            #expect(await presenter.presentedRequests.isEmpty)
            #expect(await access.requestedProviders.isEmpty)
            #expect(await access.consumeCount == 0)
            #expect(await transferScopes(of: fileStore).isEmpty)
            #expect(try await transfers.readySlotState() == .empty)
        }
    }

    // MARK: - Consent gates the bytes

    @Test("Declining consent reads no byte, creates no session, and leaves nothing behind")
    func declinedConsentHasNoSideEffect() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let access = FakeSharedItemAccess.lending(Sample.bytes(count: 4_096))
            let presenter = ScriptedConsentPresenter.declining()
            let transfers = SharedTransferStore.test(over: fileStore)
            let coordinator = try makeCoordinator(
                access: access,
                consentPresenter: presenter,
                transfers: transfers,
                governor: ProgrammedShareResourceGovernor()
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))

            #expect(outcome == .declined)
            // The consent action was presented, and the provider was never asked for
            // anything: declining is refusal before the first byte, not cleanup afterwards
            // (Requirement 2.4).
            #expect(await presenter.presentedRequests.count == 1)
            #expect(await access.requestedProviders.isEmpty)
            #expect(await access.consumeCount == 0)
            #expect(await transferScopes(of: fileStore).isEmpty)
            #expect(try await fileStore.usedByteCount() == 0)
            #expect(try await transfers.readySlotState() == .empty)
            #expect(outcome.publishedTicket == nil)
        }
    }

    @Test("Cancelling the consent action reads no byte and is not an error")
    func cancelledConsentHasNoSideEffect() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let access = FakeSharedItemAccess.lending(Sample.bytes(count: 4_096))
            let transfers = SharedTransferStore.test(over: fileStore)
            let coordinator = try makeCoordinator(
                access: access,
                consentPresenter: ScriptedConsentPresenter.cancelling(),
                transfers: transfers,
                governor: ProgrammedShareResourceGovernor()
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))

            #expect(outcome == .cancelled)
            #expect(await access.requestedProviders.isEmpty)
            #expect(await transferScopes(of: fileStore).isEmpty)
            #expect(try await transfers.readySlotState() == .empty)
        }
    }

    @Test("The consent action names the presented provider and the bound policy version")
    func consentRequestNamesTheProviderAndTheBoundPolicy() async throws {
        try await withTemporaryRoot { root in
            let provider = Sample.sharedProvider()
            let presenter = ScriptedConsentPresenter.confirming()
            let transfers = SharedTransferStore.test(over: makeFileStore(root: root))
            let coordinator = try makeCoordinator(
                access: FakeSharedItemAccess.lending(Sample.bytes(count: 512)),
                consentPresenter: presenter,
                transfers: transfers,
                governor: ProgrammedShareResourceGovernor()
            )

            _ = await coordinator.handleActivation(Sample.activation(provider))

            let request = try #require(await presenter.presentedRequests.first)
            #expect(request.provider == provider)
            // Read from the store rather than from a second copy of the artifact, so a build
            // cannot stage under a policy version it is not bound to (Requirement 11.9).
            let boundPolicyID = await transfers.extensionExecutionPolicyID
            #expect(request.extensionExecutionPolicyID == boundPolicyID)
        }
    }

    @Test("Consent for another provider authorizes nothing and touches no byte")
    func consentForAnotherProviderAuthorizesNothing() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let access = FakeSharedItemAccess.lending(Sample.bytes(count: 512))
            let coordinator = try makeCoordinator(
                access: access,
                consentPresenter: ScriptedConsentPresenter.declining(),
                transfers: SharedTransferStore.test(over: fileStore),
                governor: ProgrammedShareResourceGovernor()
            )

            let outcome = await coordinator.attemptStaging(
                of: Sample.sharedProvider(token: 1),
                consent: Sample.consent(for: Sample.sharedProvider(token: 2))
            )

            #expect(outcome == .failure(.consentNotBound(.providerMismatch)))
            #expect(await access.requestedProviders.isEmpty)
            #expect(await transferScopes(of: fileStore).isEmpty)
        }
    }

    @Test("Consent under another policy version authorizes nothing")
    func consentUnderAnotherPolicyAuthorizesNothing() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let access = FakeSharedItemAccess.lending(Sample.bytes(count: 512))
            let provider = Sample.sharedProvider()
            let coordinator = try makeCoordinator(
                access: access,
                consentPresenter: ScriptedConsentPresenter.declining(),
                transfers: SharedTransferStore.test(over: fileStore),
                governor: ProgrammedShareResourceGovernor()
            )

            let outcome = await coordinator.attemptStaging(
                of: provider,
                consent: Sample.consent(
                    for: provider,
                    policyID: Sample.artifactID("extension-execution-9999")
                )
            )

            #expect(outcome == .failure(.consentNotBound(.unboundExtensionExecutionPolicy)))
            #expect(await access.requestedProviders.isEmpty)
            #expect(await transferScopes(of: fileStore).isEmpty)
        }
    }

    @Test("A consent token minted for a different provider is refused mid-flow")
    func roguePresenterTokenIsRefused() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let access = FakeSharedItemAccess.lending(Sample.bytes(count: 512))
            // The presenter answers with a token it did not mint for this request.
            let presenter = ScriptedConsentPresenter.confirming(
                with: Sample.consent(for: Sample.sharedProvider(token: 77))
            )
            let coordinator = try makeCoordinator(
                access: access,
                consentPresenter: presenter,
                transfers: SharedTransferStore.test(over: fileStore),
                governor: ProgrammedShareResourceGovernor()
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider(token: 1)))

            #expect(outcome == .failed(.consentNotBound(.providerMismatch)))
            #expect(await access.requestedProviders.isEmpty)
            #expect(await transferScopes(of: fileStore).isEmpty)
        }
    }

    // MARK: - One ticket, published atomically

    @Test("A consented handoff publishes one ticket under the allocated candidate identifier")
    func consentedHandoffPublishesOneTicket() async throws {
        try await withTemporaryRoot { root in
            let bytes = Sample.bytes(count: 30_007)
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let candidate = Sample.sessionID("session-share-candidate")
            let access = FakeSharedItemAccess.lending(bytes)
            let coordinator = try makeCoordinator(
                access: access,
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: transfers,
                governor: ProgrammedShareResourceGovernor(),
                candidateSessions: FixedCandidateSessionIdentifierSource(candidate)
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))

            guard case .published(let handoff) = outcome else {
                Issue.record("expected a published handoff, got \(outcome)")
                return
            }
            // The candidate the extension allocated is the pending session's identity, and
            // claim has to preserve it (Requirements 2.3 and 11.12).
            #expect(handoff.sessionID == candidate)
            #expect(handoff.ticket.route == .shareExtension)
            #expect(handoff.ticket.byteCount == UInt64(bytes.count))
            #expect(handoff.ticket.sha256 == StreamingSHA256.digest(of: Data(bytes)))
            #expect(handoff.ticket.extensionBuildID == Sample.buildID())
            #expect(handoff.ticket.contentTypeHint == Sample.contentTypeHint())

            // Exactly one ready transfer, holding the host's bytes byte for byte: nothing
            // between the host's file and the ready slot re-encoded or transcoded them.
            let published = try #require(await transfers.readySlotState().publishedTransfer)
            #expect(published.ticket == handoff.ticket)
            #expect(try await fileStore.read(published.storageKey) == bytes)
            #expect(
                await transferScopes(of: fileStore)
                    == [.transfer(handoff.ticket.transferID, .ready)]
            )
            #expect(await access.consumeCount == 1)
        }
    }

    @Test("A published handoff carries the manual instruction and no launch")
    func publishedHandoffCarriesTheManualInstruction() async throws {
        try await withTemporaryRoot { root in
            let key = Sample.copyKey("share.handoff.open-defaike.v1")
            let coordinator = try makeCoordinator(
                access: FakeSharedItemAccess.lending(Sample.bytes(count: 900)),
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: SharedTransferStore.test(over: makeFileStore(root: root)),
                governor: ProgrammedShareResourceGovernor(),
                instruction: Sample.manualInstruction(copyKey: key)
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))

            guard case .published(let handoff) = outcome else {
                Issue.record("expected a published handoff, got \(outcome)")
                return
            }
            // The instruction is a copy key, never a compiled-in English sentence: Version 1
            // wording is an unresolved approved-copy decision.
            #expect(handoff.instruction.copyKey == key)
            #expect(ManualOpenInstruction.launchMechanism == .manualUserAction)
        }
    }

    @Test("The host's representation is read only and left exactly as it was")
    func hostRepresentationIsUntouched() async throws {
        try await withTemporaryRoot { root in
            let bytes = Sample.bytes(count: 4_321)
            // Keeping the lent file is the only way to inspect it afterwards.
            let access = FakeSharedItemAccess.lending(bytes, reclaimsRepresentation: false)
            defer { Task { await access.cleanUp() } }
            let coordinator = try makeCoordinator(
                access: access,
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: SharedTransferStore.test(over: makeFileStore(root: root)),
                governor: ProgrammedShareResourceGovernor()
            )

            _ = await coordinator.handleActivation(Sample.activation(Sample.sharedProvider()))

            let lent = try #require(await access.lentFiles.first)
            #expect(FileManager.default.fileExists(atPath: lent.path))
            #expect(try Array(Data(contentsOf: lent)) == bytes)
        }
    }

    @Test(
        "Both provider answers record a conservative unknown status",
        arguments: SharedRepresentationForm.allCases
    )
    func statusIsConservativeForEveryProviderAnswer(
        form: SharedRepresentationForm
    ) async throws {
        try await withTemporaryRoot { root in
            let coordinator = try makeCoordinator(
                access: FakeSharedItemAccess.lending(Sample.bytes(count: 700), form: form),
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: SharedTransferStore.test(over: makeFileStore(root: root)),
                governor: ProgrammedShareResourceGovernor()
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))
            let ticket = try #require(outcome.publishedTicket)

            // A sharing application never declares byte originality and never declares a
            // transform, so neither answer can reach a stronger status (Requirement 2.11).
            #expect(ticket.preservationStatus == .unknown)
            #expect(ticket.preservationBasis == form.preservationBasis)
            #expect(ticket.preservationBasis.supports(ticket.preservationStatus))
            #expect(ticket.preservationStatus != .originalBytes)
            #expect(ticket.preservationStatus != .platformTransformedCopy)
        }
    }

    // MARK: - Protected only after consent

    @Test(
        "Bytes staged after consent carry the protection level the bound policy fixes",
        arguments: FileProtectionLevel.allCases
    )
    func consentedBytesCarryThePolicyProtectionLevel(
        level: FileProtectionLevel
    ) async throws {
        try await withTemporaryRoot { root in
            // Exercising all three levels is what makes this an assertion about the policy
            // rather than a coincidence with one preferred level. The store applies the
            // level (task 4.3); what this pins is that the *consented activation path* ends
            // in bytes carrying it, which is the "stream and protect" half of the handoff.
            let fileStore = makeFileStore(root: root, containerProtection: level)
            let transfers = SharedTransferStore.test(
                over: fileStore,
                extensionPolicy: Sample.extensionPolicy(stagedFileProtection: level)
            )
            let coordinator = try makeCoordinator(
                access: FakeSharedItemAccess.lending(Sample.bytes(count: 2_500)),
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: transfers,
                governor: ProgrammedShareResourceGovernor()
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))

            #expect(outcome.publishedTicket != nil)
            #expect(await transfers.stagedFileProtection == level)
            let published = try #require(await transfers.readySlotState().publishedTransfer)
            let receipt = try #require(await fileStore.receipt(for: published.storageKey))
            #expect(receipt.protection == level)
        }
    }

    @Test("A protection level that cannot be applied publishes nothing and is not loosened")
    func unappliableProtectionEndsTheActivationWithNoSession() async throws {
        try await withTemporaryRoot { root in
            // Requirement 9.6 has no unprotected fallback: staged encoded bytes either carry
            // the approved level or do not exist. The failure has to reach the user as a
            // handoff that did not complete — never as a downgrade, never as cancellation,
            // and never as a resource breach, which would misreport an unavailable
            // protection level as an exceeded budget.
            let fileStore = makeFileStore(
                root: root,
                protection: RefusingDataProtection(refusedLevel: .complete)
            )
            let governor = ProgrammedShareResourceGovernor()
            let transfers = SharedTransferStore.test(over: fileStore)
            let coordinator = try makeCoordinator(
                access: FakeSharedItemAccess.lending(Sample.bytes(count: 2_500)),
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: transfers,
                governor: governor
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))

            let failure = try #require(outcome.stagingFailure)
            #expect(failure.fault == .analysis(.handoffError, stage: .handoffVerification))
            #expect(outcome.publishedTicket == nil)
            #expect(try await transfers.readySlotState() == .empty)
            #expect(await transferScopes(of: fileStore).isEmpty)
            #expect(await governor.outstandingReservations().isEmpty)
        }
    }

    // MARK: - The pending ready slot

    @Test("A pending handoff is offered for recovery without touching the host again")
    func pendingHandoffIsOfferedForRecovery() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let first = try makeCoordinator(
                access: FakeSharedItemAccess.lending(Sample.bytes(count: 1_000)),
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: transfers,
                governor: ProgrammedShareResourceGovernor()
            )
            let pendingTicket = try #require(
                await first.handleActivation(Sample.activation(Sample.sharedProvider()))
                    .publishedTicket
            )

            let access = FakeSharedItemAccess.lending(Sample.bytes(count: 2_000))
            let presenter = ScriptedConsentPresenter.confirming()
            let second = try makeCoordinator(
                access: access,
                consentPresenter: presenter,
                transfers: transfers,
                governor: ProgrammedShareResourceGovernor(),
                candidateSessions: FixedCandidateSessionIdentifierSource(
                    Sample.sessionID("session-share-second")
                )
            )

            let outcome = await second
                .handleActivation(Sample.activation(Sample.sharedProvider(token: 9)))

            #expect(
                outcome
                    == .pendingHandoff(
                        PendingHandoffRecovery(
                            pendingTransfer: pendingTicket.transferID,
                            instruction: Sample.manualInstruction()
                        )
                    )
            )
            // A handoff the user already consented to is never replaced, and asking for
            // consent again would offer something that cannot be performed.
            #expect(await presenter.presentedRequests.isEmpty)
            #expect(await access.requestedProviders.isEmpty)
            #expect(
                try await transfers.readySlotState().publishedTransfer?.ticket == pendingTicket
            )
            #expect(await transferScopes(of: fileStore) == [
                .transfer(pendingTicket.transferID, .ready)
            ])
        }
    }

    // MARK: - Provider failure

    @Test(
        "A provider failure before any byte creates nothing",
        arguments: [
            SharedItemProviderFault.itemUnavailable,
            .representationUnavailable,
            .transferFailed,
        ]
    )
    func providerFailureCreatesNothing(fault: SharedItemProviderFault) async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let access = FakeSharedItemAccess.failing(fault)
            let transfers = SharedTransferStore.test(over: fileStore)
            let coordinator = try makeCoordinator(
                access: access,
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: transfers,
                governor: ProgrammedShareResourceGovernor()
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))

            #expect(outcome == .failed(.noRepresentationObtained(fault)))
            // The window closed with nothing in it, so the copy was never entered.
            #expect(await access.consumeCount == 0)
            #expect(await transferScopes(of: fileStore).isEmpty)
            #expect(try await fileStore.usedByteCount() == 0)
            #expect(try await transfers.readySlotState() == .empty)
        }
    }

    @Test("Provider cancellation is cancellation, never an error category")
    func providerCancellationIsNotAnError() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let coordinator = try makeCoordinator(
                access: FakeSharedItemAccess.failing(.cancelled),
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: SharedTransferStore.test(over: fileStore),
                governor: ProgrammedShareResourceGovernor()
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))

            #expect(outcome == .cancelled)
            #expect(await transferScopes(of: fileStore).isEmpty)
        }
    }

    // MARK: - Resource breach

    @Test("A representation over the encoded-input ceiling is refused before any byte is copied")
    func oversizedRepresentationIsRefusedBeforeTheCopy() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let governor = ProgrammedShareResourceGovernor()
            let transfers = SharedTransferStore.test(over: fileStore)
            let access = FakeSharedItemAccess.lending(Sample.bytes(count: 4_000))
            let coordinator = try makeCoordinator(
                access: access,
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: transfers,
                governor: governor,
                budget: Sample.shareBudget(encodedInputSizeBytes: 1_000)
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))

            #expect(outcome == .failed(.resourceBreach(.encodedInputSize)))
            // Stopped before the copy: no session, no ready ticket, and not one byte written
            // (Requirement 11.8).
            #expect(await transferScopes(of: fileStore).isEmpty)
            #expect(try await fileStore.usedByteCount() == 0)
            #expect(try await transfers.readySlotState() == .empty)
            #expect(await governor.outstandingReservations().isEmpty)
            let failure = try #require(outcome.stagingFailure)
            #expect(failure.fault == .analysis(.resourceLimit, stage: .handoffVerification))
        }
    }

    @Test("A temporary-storage breach returns the headroom already granted")
    func temporaryStorageBreachReleasesGrantedHeadroom() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let governor = ProgrammedShareResourceGovernor()
            let coordinator = try makeCoordinator(
                access: FakeSharedItemAccess.lending(Sample.bytes(count: 4_000)),
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: SharedTransferStore.test(over: fileStore),
                governor: governor,
                budget: Sample.shareBudget(
                    encodedInputSizeBytes: 1_000_000,
                    temporaryStorageBytes: 100
                )
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))

            #expect(outcome == .failed(.resourceBreach(.temporaryStorage)))
            // The encoded-input reservation was granted first; a partial reservation must
            // not leak when the second one is refused.
            #expect(await governor.outstandingReservations().isEmpty)
            #expect(await governor.releases.count == 1)
            #expect(await transferScopes(of: fileStore).isEmpty)
            #expect(try await fileStore.usedByteCount() == 0)
        }
    }

    @Test("Headroom already in use by another handoff refuses this one")
    func priorUseRefusesTheHandoff() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let governor = ProgrammedShareResourceGovernor()
            await governor.setPriorUse(900, for: .encodedInputSize)
            let coordinator = try makeCoordinator(
                access: FakeSharedItemAccess.lending(Sample.bytes(count: 500)),
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: SharedTransferStore.test(over: fileStore),
                governor: governor,
                budget: Sample.shareBudget(encodedInputSizeBytes: 1_000)
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))

            #expect(outcome == .failed(.resourceBreach(.encodedInputSize)))
            #expect(try await fileStore.usedByteCount() == 0)
        }
    }

    @Test("A refused reservation is a resource breach with no ready ticket")
    func refusedReservationIsAResourceBreach() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let governor = ProgrammedShareResourceGovernor()
            await governor.refuse(.encodedInputSize)
            let transfers = SharedTransferStore.test(over: fileStore)
            let coordinator = try makeCoordinator(
                access: FakeSharedItemAccess.lending(Sample.bytes(count: 512)),
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: transfers,
                governor: governor
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))

            #expect(outcome == .failed(.resourceBreach(.encodedInputSize)))
            #expect(try await transfers.readySlotState() == .empty)
            #expect(await governor.outstandingReservations().isEmpty)
        }
    }

    @Test("Headroom minted against another budget is refused rather than used")
    func substitutedBudgetIsRefused() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let governor = ProgrammedShareResourceGovernor()
            await governor.substituteBudget(Sample.artifactID("budget-someone-else-0001"))
            let coordinator = try makeCoordinator(
                access: FakeSharedItemAccess.lending(Sample.bytes(count: 512)),
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: SharedTransferStore.test(over: fileStore),
                governor: governor
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))

            // A substitution is not a breach of a number, and is refused for the same
            // reason: nothing may enforce one target's work against another's artifact
            // (Requirement 11.1).
            #expect(outcome == .failed(.resourceBreach(.encodedInputSize)))
            #expect(await governor.outstandingReservations().isEmpty)
            #expect(try await fileStore.usedByteCount() == 0)
        }
    }

    @Test("A budget with no comparable limit for a metric fails closed")
    func incomparableLimitFailsClosed() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let governor = ProgrammedShareResourceGovernor()
            let access = FakeSharedItemAccess.lending(Sample.bytes(count: 512))
            let coordinator = try makeCoordinator(
                access: access,
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: SharedTransferStore.test(over: fileStore),
                governor: governor,
                budget: Sample.shareBudgetWithMistypedEncodedInputLimit()
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))

            // A limit stated in another unit cannot bound a byte count. Treating that as
            // "unlimited" would make the budget advisory, so it fails closed and the
            // governor is never even asked.
            #expect(outcome == .failed(.resourceBreach(.encodedInputSize)))
            #expect(await governor.requests.isEmpty)
            #expect(try await fileStore.usedByteCount() == 0)
        }
    }

    @Test("A successful handoff returns every reservation it took")
    func successfulHandoffReturnsItsHeadroom() async throws {
        try await withTemporaryRoot { root in
            let governor = ProgrammedShareResourceGovernor()
            let coordinator = try makeCoordinator(
                access: FakeSharedItemAccess.lending(Sample.bytes(count: 2_048)),
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: SharedTransferStore.test(over: makeFileStore(root: root)),
                governor: governor
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))

            #expect(outcome.publishedTicket != nil)
            #expect(
                await governor.requests.map(\.metric)
                    == ShareExtensionIngestCoordinator.reservedHandoffMetrics
            )
            // Both reservations name the bytes about to be staged, in the budget's unit.
            for request in await governor.requests {
                #expect(request.unit == .bytes)
                #expect(request.amount.value == 2_048)
                #expect(request.stage == .handoffVerification)
            }
            #expect(await governor.outstandingReservations().isEmpty)
        }
    }

    // MARK: - Interruption and cancellation before publication

    @Test("A publication interrupted before the commit leaves no ready slot and no session")
    func interruptedPublicationLeavesNothing() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            // The copy completes and the promotion never happens: the closest a host can
            // come to an interruption between finalizing and committing.
            let transfers = SharedTransferStore.test(
                over: PromotionRefusingStore(underlying: fileStore)
            )
            let coordinator = try makeCoordinator(
                access: FakeSharedItemAccess.lending(Sample.bytes(count: 3_000)),
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: transfers,
                governor: ProgrammedShareResourceGovernor()
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))

            #expect(outcome == .failed(.stagingIncomplete(.store(.storeUnavailable))))
            #expect(outcome.publishedTicket == nil)
            #expect(try await transfers.readySlotState() == .empty)
            // Staging was removed, so nothing a later start could mistake for a session
            // survives (Requirement 2.4 and Property 7).
            #expect(await transferScopes(of: fileStore).isEmpty)
            #expect(try await fileStore.usedByteCount() == 0)
        }
    }

    @Test("Cancelling during the copy leaves nothing behind and is not an error")
    func cancellationDuringTheCopyLeavesNothing() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore, chunkSizeInBytes: 256)
            let coordinator = try makeCoordinator(
                access: FakeSharedItemAccess.lending(Sample.bytes(count: 400_000)),
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: transfers,
                governor: ProgrammedShareResourceGovernor()
            )

            let task = Task {
                await coordinator.handleActivation(Sample.activation(Sample.sharedProvider()))
            }
            task.cancel()
            let outcome = await task.value

            // Cancellation is a distinct terminal outcome, never an error category
            // (Requirement 11.17).
            #expect(outcome == .cancelled)
            #expect(outcome.publishedTicket == nil)
            #expect(try await transfers.readySlotState() == .empty)
            #expect(await transferScopes(of: fileStore).isEmpty)
            #expect(try await fileStore.usedByteCount() == 0)
        }
    }

    @Test("A bounded storage ceiling stops the copy with a resource-limit fault")
    func storageCeilingIsAResourceLimit() async throws {
        try await withTemporaryRoot { root in
            // The store's capacity comes from the approved temporary-storage limit, and a
            // breach of it is the one retention failure with a truthful category.
            let fileStore = makeFileStore(root: root, capacityInBytes: 512)
            let transfers = SharedTransferStore.test(over: fileStore, chunkSizeInBytes: 128)
            let coordinator = try makeCoordinator(
                access: FakeSharedItemAccess.lending(Sample.bytes(count: 8_000)),
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: transfers,
                governor: ProgrammedShareResourceGovernor()
            )

            let outcome = await coordinator
                .handleActivation(Sample.activation(Sample.sharedProvider()))

            let failure = try #require(outcome.stagingFailure)
            #expect(failure.fault == .analysis(.resourceLimit, stage: .handoffVerification))
            #expect(try await transfers.readySlotState() == .empty)
            #expect(await transferScopes(of: fileStore).isEmpty)
            #expect(try await fileStore.usedByteCount() == 0)
        }
    }

    // MARK: - The narrowed port view

    @Test("Cancellation never acquires an error category, whichever side it arrived from")
    func cancellationNeverBecomesAnErrorCategory() {
        for failure: ShareStagingFailure in [
            .cancelled,
            .noRepresentationObtained(.cancelled),
            .stagingIncomplete(.stagingFailed(.cancelled)),
        ] {
            #expect(failure.fault == .cancelled)
            #expect(failure.fault.analysisError == nil)
            #expect(failure.fault.stage == nil)
        }
    }

    @Test(
        "Every resource breach is exactly one resource-limit at the handoff stage",
        arguments: ResourceMetric.allCases
    )
    func resourceBreachesReportResourceLimit(metric: ResourceMetric) {
        #expect(
            ShareStagingFailure.resourceBreach(metric).fault
                == .analysis(.resourceLimit, stage: .handoffVerification)
        )
    }

    @Test("Every other failure reports one handoff error at the handoff stage")
    func otherFailuresReportHandoffError() {
        var failures: [ShareStagingFailure] = [
            .activationNotOneItem(itemCount: 0),
            .pendingHandoffExists(Sample.transferID()),
            .stagingIncomplete(.store(.storeUnavailable)),
            .stagingIncomplete(.ticketRejected),
            .stagingIncomplete(.manifestTooLarge(limitBytes: 10, actualBytes: 20)),
            .stagingIncomplete(.stagingFailed(.sourceUnreadable)),
            .stagingIncomplete(.stagingFailed(.emptySource)),
        ]
        for defect in ConsentBindingDefect.allCases {
            failures.append(.consentNotBound(defect))
        }
        for fault in SharedItemProviderFault.allCases where fault != .cancelled {
            failures.append(.noRepresentationObtained(fault))
        }
        for failure in failures {
            #expect(failure.fault == .analysis(.handoffError, stage: .handoffVerification))
        }
    }

    @Test("A bounded storage ceiling is the one staging failure with a resource category")
    func capacityStagingFailuresReportResourceLimit() {
        let scope = EphemeralStorageScope.transfer(Sample.transferID(), .staging)
        for failure: ShareStagingFailure in [
            .stagingIncomplete(.stagingFailed(.store(.capacityExceeded(scope: scope)))),
            .stagingIncomplete(.store(.capacityExceeded(scope: scope))),
        ] {
            #expect(failure.fault == .analysis(.resourceLimit, stage: .handoffVerification))
        }
    }

    @Test("The staging port throws the narrowed fault instead of returning a ticket")
    func portThrowsTheNarrowedFault() async throws {
        try await withTemporaryRoot { root in
            let provider = Sample.sharedProvider()
            let coordinator = try makeCoordinator(
                access: FakeSharedItemAccess.lending(Sample.bytes(count: 4_000)),
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: SharedTransferStore.test(over: makeFileStore(root: root)),
                governor: ProgrammedShareResourceGovernor(),
                budget: Sample.shareBudget(encodedInputSizeBytes: 1_000)
            )

            await #expect(
                throws: AnalysisFault.analysis(.resourceLimit, stage: .handoffVerification)
            ) {
                _ = try await coordinator.stageOne(
                    provider,
                    consent: Sample.consent(for: provider)
                )
            }
        }
    }

    @Test("A provider the consent does not name cannot be staged, whatever it offers")
    func portRefusesAProviderTheConsentDoesNotName() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let access = FakeSharedItemAccess.lending(Sample.bytes(count: 512))
            let coordinator = try makeCoordinator(
                access: access,
                consentPresenter: ScriptedConsentPresenter.declining(),
                transfers: SharedTransferStore.test(over: fileStore),
                governor: ProgrammedShareResourceGovernor()
            )
            let single = Sample.sharedProvider()
            let many = Sample.sharedProvider(itemCount: 4)

            // Consent can only exist for a one-item provider, so reaching the runtime check
            // requires handing the port a provider the consent does not name. Both refusals
            // happen before the host is touched.
            let outcome = await coordinator.attemptStaging(of: many, consent: Sample.consent(for: single))
            #expect(outcome == .failure(.consentNotBound(.providerMismatch)))
            #expect(await access.requestedProviders.isEmpty)
        }
    }

    // MARK: - Cross-target wiring

    @Test("Main-application resource wiring cannot construct an extension coordinator")
    func mainApplicationWiringIsRefused() async throws {
        try await withTemporaryRoot { root in
            let transfers = SharedTransferStore.test(over: makeFileStore(root: root))
            #expect(
                ShareExtensionIngestCoordinator(
                    access: FakeSharedItemAccess.lending([1, 2, 3]),
                    consentPresenter: ScriptedConsentPresenter.confirming(),
                    transfers: transfers,
                    governor: ProgrammedShareResourceGovernor(target: .mainApplication),
                    budget: Sample.shareBudget(),
                    instruction: Sample.manualInstruction()
                ) == nil
            )
            #expect(
                ShareExtensionIngestCoordinator(
                    access: FakeSharedItemAccess.lending([1, 2, 3]),
                    consentPresenter: ScriptedConsentPresenter.confirming(),
                    transfers: transfers,
                    governor: ProgrammedShareResourceGovernor(),
                    budget: Sample.budget(
                        temporaryStorageBytes: 1_000,
                        target: .mainApplication
                    ),
                    instruction: Sample.manualInstruction()
                ) == nil
            )
        }
    }

    // MARK: - Startup cleanup

    @Test("Startup cleanup keeps a consented pending handoff and removes nothing else")
    func startupCleanupKeepsThePendingHandoff() async throws {
        try await withTemporaryRoot { root in
            let fileStore = makeFileStore(root: root)
            let transfers = SharedTransferStore.test(over: fileStore)
            let coordinator = try makeCoordinator(
                access: FakeSharedItemAccess.lending(Sample.bytes(count: 1_500)),
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: transfers,
                governor: ProgrammedShareResourceGovernor()
            )
            let ticket = try #require(
                await coordinator
                    .handleActivation(Sample.activation(Sample.sharedProvider()))
                    .publishedTicket
            )

            try await coordinator.discardStagedMaterial(policy: Sample.lifecyclePolicy())
            // Idempotent: a second run removes nothing and still succeeds.
            try await coordinator.discardStagedMaterial(policy: Sample.lifecyclePolicy())

            #expect(try await transfers.readySlotState().publishedTransfer?.ticket == ticket)
        }
    }

    @Test("Cleanup under an unbound lifecycle policy is refused")
    func cleanupUnderAnUnboundPolicyIsRefused() async throws {
        try await withTemporaryRoot { root in
            let coordinator = try makeCoordinator(
                access: FakeSharedItemAccess.lending([1, 2, 3]),
                consentPresenter: ScriptedConsentPresenter.confirming(),
                transfers: SharedTransferStore.test(over: makeFileStore(root: root)),
                governor: ProgrammedShareResourceGovernor()
            )

            // The store's deadlines come from the artifact it was bound to, so cleaning up
            // "under" another version would audit the removal against a deadline that never
            // governed the material.
            await #expect(throws: EphemeralStoreError.storeUnavailable) {
                try await coordinator.discardStagedMaterial(
                    policy: Sample.distinctDeadlinePolicy()
                )
            }
        }
    }

    // MARK: - What the request may say

    @Test("The representation request names the supported containers, a copy, and one item")
    func requestIsFixed() {
        #expect(
            SharedItemRepresentationRequest.requestedContainers == [.jpeg, .png, .heic, .heif]
        )
        #expect(
            SharedItemRepresentationRequest.accessPolicy == .copyIntoAppControlledStorage
        )
        #expect(SharedItemRepresentationRequest.maximumActivationItemCount == 1)
    }

    @Test("Opening the host's file in place is not a representable request")
    func inPlaceAccessIsUnrepresentable() {
        // Analyzing a file the host still owns would let the bytes change underneath a
        // running analysis, so there is no value to pass that would ask for it.
        #expect(SharedItemAccessPolicy.allCases == [.copyIntoAppControlledStorage])
    }

    @Test("A programmatic launch of the containing application is not representable")
    func programmaticLaunchIsUnrepresentable() {
        // iOS does not support opening the containing application from the share extension
        // point, so a build that claimed otherwise would be claiming platform behavior Apple
        // does not document. The instruction is text; the user performs the action.
        #expect(HandoffLaunchMechanism.allCases == [.manualUserAction])
        #expect(ManualOpenInstruction.launchMechanism == .manualUserAction)
    }

    // MARK: - What the module may reach

    @Test("Nothing in the module performs inference or Content Credential analysis")
    func moduleRunsNoInferenceOrProvenanceAnalysis() throws {
        // Requirement 11.11 delegates all pixel inference to the main application, and the
        // extension composition links neither the model nor the validator. The way to keep
        // that true is for no inference or validation surface to exist in the module at all;
        // a later change that reaches for one fails here rather than quietly widening what
        // the extension does.
        try expectNoModuleSourceContains([
            "import CoreML",
            "import DefAIkeCoreML",
            "import Vision",
            "MLModel",
            "MLFeature",
            "MLMultiArray",
            "MLComputeUnits",
            "PixelModelLoading",
            "PixelAnalyzing",
            "PixelCalibrating",
            "RawLogit",
            "ModelImageInput",
            "BoundModelBundle",
            "ModelBundleManaging",
            "import DefAIkeProvenanceAPI",
            "import DefAIkeProvenanceC2PA",
            "ProvenanceAnalyzing",
            "C2PA",
            "ContentCredential",
        ])
    }

    @Test("Nothing in the module tries to launch the containing application")
    func moduleUsesNoApplicationLaunchWorkaround() throws {
        // The design permits no responder-chain or other unsupported launch workaround, and
        // an extension context is the Share Extension target's to hold, never this module's.
        // Every token here is a surface such a workaround would need.
        try expectNoModuleSourceContains([
            "UIApplication",
            "sharedApplication",
            "openURL",
            "canOpenURL",
            "LSApplicationWorkspace",
            "NSExtensionContext",
            "UIResponder",
            "nextResponder",
            "performSelector",
            "NSSelectorFromString",
            "dlopen",
        ])
    }

    /// Fails if any Swift file in the module contains any of `forbidden`.
    ///
    /// Enumerated recursively, and the enumeration is itself checked: a scan that silently
    /// covered nothing, or covered only a module's top level while a later change put a file
    /// in a subdirectory, would pass while asserting nothing. Requiring that this file's own
    /// module sources be present is what makes an empty or truncated walk a failure rather
    /// than a vacuous success.
    private func expectNoModuleSourceContains(
        _ forbidden: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DefAIkeSharedTransfer")
        let enumerator = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil),
            "the module's sources must be enumerable for this to mean anything",
            sourceLocation: sourceLocation
        )
        let files = enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        let scanned = Set(files.map(\.lastPathComponent))
        // The three files this task added, so a walk that misses the module's own subject
        // matter fails here instead of reporting a clean scan.
        for expected in [
            "ShareExtensionIngestCoordinator.swift",
            "ShareHandoffActivation.swift",
            "SharedItemProviderSeam.swift",
        ] {
            #expect(
                scanned.contains(expected),
                "the scan must cover \(expected)",
                sourceLocation: sourceLocation
            )
        }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                #expect(
                    !text.contains(token),
                    "\(file.lastPathComponent) must not reference \(token)",
                    sourceLocation: sourceLocation
                )
            }
        }
    }
}

extension ShareHandoffOutcome {
    /// The staging failure, or `nil` for every other outcome. Reads better than a `switch`
    /// inside an assertion.
    var stagingFailure: ShareStagingFailure? {
        guard case .failed(let failure) = self else { return nil }
        return failure
    }
}
