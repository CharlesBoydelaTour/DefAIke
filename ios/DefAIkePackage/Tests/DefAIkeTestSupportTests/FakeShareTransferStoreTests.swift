import DefAIkeDomain
import Testing

@testable import DefAIkeTestSupport

/// Checks the transfer double against the handoff behavior later properties assert on.
///
/// These are tests of the double. Real App Group coordination, real file protection, and
/// real process termination are integration and physical-device concerns (task 4.10).
@Suite("Fake Share transfer store")
struct FakeShareTransferStoreTests {

    private struct Harness {
        let store: InMemoryEphemeralStore
        let clock: VirtualSessionClock
        let recorder: PortCallRecorder
        let transfer: FakeShareTransferStore
        let buildID: AppBuildID
        let policyID: ArtifactID
    }

    private func makeHarness(bytes: [UInt8]) async -> (Harness, SharedItemProvider) {
        let store = InMemoryEphemeralStore()
        let clock = VirtualSessionClock()
        let recorder = PortCallRecorder()
        let buildID = PortValue.appBuildID()
        let policyID = PortValue.artifactID("extension-execution-0001")
        let transfer = FakeShareTransferStore(
            store: store,
            clock: clock,
            extensionBuildID: buildID,
            extensionExecutionPolicyID: policyID,
            recorder: recorder
        )
        let provider = PortValue.sharedItemProvider()
        await transfer.setProviderBytes(bytes, for: provider.token)
        return (
            Harness(
                store: store,
                clock: clock,
                recorder: recorder,
                transfer: transfer,
                buildID: buildID,
                policyID: policyID
            ),
            provider
        )
    }

    @Test("A consented handoff publishes one ready ticket and preserves the bytes")
    func consentedHandoffPreservesBytes() async throws {
        let bytes = PortValue.bytes(count: 500)
        let (harness, provider) = await makeHarness(bytes: bytes)
        let consent = try #require(
            PortValue.consent(for: provider, policyID: harness.policyID)
        )

        let ticket = try await harness.transfer.stageOne(provider, consent: consent)

        #expect(ticket.route == .shareExtension)
        #expect(ticket.byteCount == UInt64(bytes.count))
        #expect(ticket.sha256 == TestSHA256.digest(of: bytes))
        #expect(await harness.transfer.slotState(of: ticket.transferID) == .ready)
        #expect(await harness.transfer.readyTransferIDs() == [ticket.transferID])
    }

    @Test("A claim resumes the same session and yields the identical bytes")
    func claimPreservesSessionAndBytes() async throws {
        let bytes = PortValue.bytes(count: 321)
        let (harness, provider) = await makeHarness(bytes: bytes)
        let consent = try #require(
            PortValue.consent(for: provider, policyID: harness.policyID)
        )
        let ticket = try await harness.transfer.stageOne(provider, consent: consent)

        let asset = try #require(
            await harness.transfer.claimReadyTransfer(claimingBuildID: harness.buildID)
        )

        #expect(asset.sessionID == ticket.sessionID)
        #expect(asset.route == .shareExtension)
        #expect(asset.byteCount == ticket.byteCount)
        #expect(asset.sha256 == ticket.sha256)
        #expect(asset.preservationStatus == ticket.preservationStatus)
        #expect(try await harness.store.read(asset.handle.storageKey) == bytes)
    }

    @Test("A tampered payload is handoff-error and deletes the transfer")
    func tamperedPayloadFailsClosed() async throws {
        let bytes = PortValue.bytes(count: 200)
        let (harness, provider) = await makeHarness(bytes: bytes)
        let consent = try #require(
            PortValue.consent(for: provider, policyID: harness.policyID)
        )
        let ticket = try await harness.transfer.stageOne(provider, consent: consent)
        await harness.transfer.tamperPayload(
            of: ticket.transferID,
            with: PortValue.bytes(count: 200, seed: 7)
        )

        await #expect(throws: AnalysisFault.analysis(.handoffError, stage: .handoffVerification)) {
            _ = try await harness.transfer.claimReadyTransfer(claimingBuildID: harness.buildID)
        }

        #expect(await harness.transfer.slotState(of: ticket.transferID) == nil)
        #expect(await harness.store.occupiedScopes().isEmpty)
        #expect(harness.recorder.producedNoEvidenceWork)
    }

    @Test("A claim from a different build is handoff-error")
    func mismatchedBuildFailsClosed() async throws {
        let (harness, provider) = await makeHarness(bytes: PortValue.bytes(count: 100))
        let consent = try #require(
            PortValue.consent(for: provider, policyID: harness.policyID)
        )
        _ = try await harness.transfer.stageOne(provider, consent: consent)

        await #expect(throws: AnalysisFault.analysis(.handoffError, stage: .handoffVerification)) {
            _ = try await harness.transfer.claimReadyTransfer(
                claimingBuildID: PortValue.appBuildID("build-9999")
            )
        }
        #expect(harness.recorder.producedNoEvidenceWork)
    }

    @Test(
        "Interruption before publication leaves no ready slot, no ticket, and no bytes",
        arguments: [
            StagingInterruption.beforeCreate,
            .duringCopy,
            .beforeFinalize,
            .beforePublication,
        ]
    )
    func prepublicationInterruptionHasNoSideEffect(
        interruption: StagingInterruption
    ) async throws {
        let (harness, provider) = await makeHarness(bytes: PortValue.bytes(count: 300))
        let consent = try #require(
            PortValue.consent(for: provider, policyID: harness.policyID)
        )
        await harness.transfer.interruptStaging(at: interruption)

        await #expect(throws: AnalysisFault.cancelled) {
            _ = try await harness.transfer.stageOne(provider, consent: consent)
        }

        let pending = try await harness.transfer.peekReadyTransfer()
        #expect(await harness.transfer.readyTransferIDs().isEmpty)
        #expect(await harness.store.occupiedScopes().isEmpty)
        #expect(pending == nil)
        #expect(harness.recorder.producedNoEvidenceWork)
    }

    @Test("A provider that fails before any byte creates no transfer")
    func providerFailureCreatesNothing() async throws {
        let (harness, provider) = await makeHarness(bytes: PortValue.bytes(count: 50))
        let consent = try #require(
            PortValue.consent(for: provider, policyID: harness.policyID)
        )
        await harness.transfer.failProvider(provider.token)

        await #expect(throws: AnalysisFault.analysis(.handoffError, stage: .handoffVerification)) {
            _ = try await harness.transfer.stageOne(provider, consent: consent)
        }
        #expect(await harness.store.occupiedScopes().isEmpty)
    }

    @Test("A second staging attempt while a transfer is pending is refused")
    func onlyOneReadySlotExists() async throws {
        let (harness, provider) = await makeHarness(bytes: PortValue.bytes(count: 80))
        let consent = try #require(
            PortValue.consent(for: provider, policyID: harness.policyID)
        )
        _ = try await harness.transfer.stageOne(provider, consent: consent)

        await #expect(throws: AnalysisFault.analysis(.handoffError, stage: .handoffVerification)) {
            _ = try await harness.transfer.stageOne(provider, consent: consent)
        }
        #expect(await harness.transfer.readyTransferIDs().count == 1)
    }

    @Test("Consent for one provider cannot be replayed for another")
    func consentIsBoundToItsProvider() async throws {
        let (harness, provider) = await makeHarness(bytes: PortValue.bytes(count: 60))
        let consent = try #require(
            PortValue.consent(for: provider, policyID: harness.policyID)
        )
        let other = PortValue.sharedItemProvider(token: 99)
        await harness.transfer.setProviderBytes(PortValue.bytes(count: 60), for: other.token)

        await #expect(throws: AnalysisFault.analysis(.handoffError, stage: .handoffVerification)) {
            _ = try await harness.transfer.stageOne(other, consent: consent)
        }
        #expect(await harness.store.occupiedScopes().isEmpty)
    }

    @Test("A multi-item activation can never produce consent")
    func multipleItemsCannotConsent() {
        #expect(PortValue.consent(for: PortValue.sharedItemProvider(itemCount: 2)) == nil)
        #expect(PortValue.consent(for: PortValue.sharedItemProvider(itemCount: 0)) == nil)
        #expect(PortValue.consent(for: PortValue.sharedItemProvider(itemCount: 1)) != nil)
    }

    @Test("Claiming an empty ready slot returns nothing")
    func emptySlotClaimsNothing() async throws {
        let (harness, _) = await makeHarness(bytes: [])

        let pending = try await harness.transfer.peekReadyTransfer()
        let claimed = try await harness.transfer.claimReadyTransfer(
            claimingBuildID: harness.buildID
        )
        #expect(pending == nil)
        #expect(claimed == nil)
    }

    @Test("Discarding staged material removes leftovers and is idempotent")
    func discardIsIdempotent() async throws {
        let (harness, provider) = await makeHarness(bytes: PortValue.bytes(count: 128))
        let consent = try #require(
            PortValue.consent(for: provider, policyID: harness.policyID)
        )
        await harness.transfer.interruptStaging(at: .afterPublication)
        _ = try await harness.transfer.stageOne(provider, consent: consent)
        let policy = LifecycleFixture.policy()

        try await harness.transfer.discardStagedMaterial(policy: policy)
        try await harness.transfer.discardStagedMaterial(policy: policy)

        // The published transfer is ready, not staging, so discarding staging leaves it.
        #expect(await harness.transfer.readyTransferIDs().count == 1)
    }
}
