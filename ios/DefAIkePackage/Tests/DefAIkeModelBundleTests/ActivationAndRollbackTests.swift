import Foundation
import Testing

@testable import DefAIkeDomain
@testable import DefAIkeModelBundle

// Step 7 of the fixed verification order: the immutable receipt, the atomic commit, and
// rollback through the identical path.
//
// Ordinary unit tests, deliberately. Property 27 generates activation and rollback histories
// and injects failures at every boundary; that belongs to task 6.10. What is asserted here is
// the behaviour that property will quantify over: which boundary produces which finding, that
// the prior bundle survives each one byte for byte, that a receipt is written once and never
// rewritten, and that rollback has no path of its own to take.
//
// Two facts about the fixtures shape everything below. Requirement 10.4 pins the weight-blob
// digest, so a synthetic candidate always stops at `.modelWeightDigestMismatch` — which is
// this project's "every other check passed" signal, and is what the path-identity assertions
// compare. Step 7 itself is driven over a `SelfTestedBundleCandidate` built through the
// module-internal initializers, because the alternative would be faking the one digest that
// pins model identity.
@Suite("Model Bundle receipts, activation, and rollback")
struct ActivationAndRollbackTests {

    // MARK: - The receipt

    @Test("An activation writes a receipt whose digests are the measured ones")
    func receiptRecordsMeasurements() async throws {
        let harness = try ActivationHarnessBuilder.standard()
        let tested = try harness.selfTested(harness.candidateID)
        let bound = try await harness.activator.commit(tested, context: harness.context)

        let written = await harness.store.receiptWriteOrder
        #expect(written.count == 1)
        let receipt = try #require(await harness.store.receipt(bound.integrity.activationReceiptID))

        // Measurements, not claims: the digests come from the verified tree, which holds what
        // streaming actually observed.
        #expect(receipt.verifiedManifestDigest == tested.candidate.tree.manifestDigest)
        #expect(receipt.verifiedArtifactDigests == tested.candidate.tree.verifiedArtifacts)
        #expect(receipt.verificationPolicy == tested.candidate.tree.verificationPolicyID)
        #expect(receipt.bundleID == harness.candidateID)
        #expect(receipt.deviceContext == harness.context.device)
        // Both gates recorded as separate results, and both passed — which is the only reason
        // the receipt is bindable at all.
        #expect(receipt.signatureOutcome == .passed)
        #expect(receipt.selfTestOutcome == .passed)
        #expect(receipt.isBindable)
        #expect(receipt.activationGeneration.value == 1)
    }

    @Test("A receipt carries identifiers, artifact digests, counts, and instants only")
    func receiptCarriesNoUserMaterial() async throws {
        // The retention rule from task 10.3: a receipt is the one thing that survives a
        // session, so what it may contain is a privacy question and not only a schema one.
        // Encoding it and reading the keys back is the assertion, because a later field
        // addition would show up here rather than in a comment.
        let harness = try ActivationHarnessBuilder.standard()
        let tested = try harness.selfTested(harness.candidateID)
        let bound = try await harness.activator.commit(tested, context: harness.context)
        let receipt = try #require(await harness.store.receipt(bound.integrity.activationReceiptID))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let object = try JSONSerialization.jsonObject(with: try encoder.encode(receipt))
        let fields = try #require(object as? [String: Any])
        #expect(
            Set(fields.keys) == [
                "id", "schemaVersion", "bundleID", "verificationPolicy",
                "verifiedManifestDigest", "verifiedArtifactDigests", "signatureOutcome",
                "selfTestOutcome", "deviceContext", "activationGeneration", "activatedAt",
            ]
        )
        // Every declared digest names a path inside the bundle's own artifact tree. None of
        // them is derived from an image, and no field carries a session identity.
        let declared = Set(tested.candidate.tree.verifiedArtifacts.map(\.path))
        #expect(Set(receipt.verifiedArtifactDigests.map(\.path)) == declared)
        #expect(!declared.isEmpty)
    }

    @Test("Two activations write two receipts and neither rewrites the other")
    func receiptsAreImmutable() async throws {
        let harness = try ActivationHarnessBuilder.standard()
        let first = try await harness.activator.commit(
            try harness.selfTested(harness.priorID),
            context: harness.context
        )
        let second = try await harness.activator.commit(
            try harness.selfTested(harness.candidateID),
            context: harness.context
        )

        #expect(first.integrity.activationReceiptID != second.integrity.activationReceiptID)
        let order = await harness.store.receiptWriteOrder
        #expect(order == [first.integrity.activationReceiptID, second.integrity.activationReceiptID])

        // The first receipt is still exactly what it was: the second activation added a
        // record rather than editing one.
        let retained = try #require(await harness.store.receipt(first.integrity.activationReceiptID))
        #expect(retained.bundleID == harness.priorID)
        #expect(retained.activationGeneration.value == 1)
        #expect(second.activationGeneration.value == 2)
    }

    @Test("A store that refuses to rewrite a receipt refuses the activation")
    func receiptConflictRefusesActivation() async throws {
        let harness = try ActivationHarnessBuilder.standard()
        let prior = try await harness.activator.commit(
            try harness.selfTested(harness.priorID),
            context: harness.context
        )
        let published = await harness.store.publishedBytes
        let retained = await harness.store.receipts

        // The identifier the next attempt will derive, declared as already holding different
        // bytes. Peeked rather than read, so naming it does not move the clock the activation
        // is about to read. Immutability wins: the record stands, the activation is refused.
        let next = try #require(
            ModelBundleActivator.receiptIdentity(
                bundle: harness.candidateID,
                generation: try PositiveCount(validating: 2),
                at: harness.clock.nextReading
            )
        )
        await harness.store.declareConflict(for: next)

        #expect(
            await harness.finding(committing: harness.candidateID)
                == .activationReceiptConflict(next)
        )
        // The write was attempted under exactly that identifier, so the refusal is about the
        // record rather than about some other identifier the attempt happened to derive.
        #expect(await harness.store.attemptedReceiptIdentifiers.last == next)

        // The prior activation is untouched: same active tuple, same pointer bytes, and no
        // persisted receipt was added or edited.
        #expect(await harness.activator.activeBundle() == prior)
        #expect(await harness.store.publishedBytes == published)
        #expect(await harness.store.receipts == retained)
    }

    @Test("A receipt identifier that is not canonical refuses the activation")
    func noncanonicalReceiptIdentityRefused() throws {
        // A bundle identifier long enough to push the derived receipt identifier past the
        // canonical ceiling. Fail closed: no receipt, no activation.
        let overlong = String(repeating: "b", count: 250)
        let bundle = try #require(ModelBundleID(overlong))
        #expect(
            ModelBundleActivator.receiptIdentity(
                bundle: bundle,
                generation: try PositiveCount(validating: 1),
                at: Date(timeIntervalSince1970: 1_700_000_000)
            ) == nil
        )
        // The same derivation for an ordinary identifier is canonical, so the refusal above
        // is about length rather than about the shape of the derived text.
        #expect(
            ModelBundleActivator.receiptIdentity(
                bundle: Sample.bundle(),
                generation: try PositiveCount(validating: 1),
                at: Date(timeIntervalSince1970: 1_700_000_000)
            ) != nil
        )
    }

    // MARK: - The commit is atomic

    @Test("Activation replaces the published pointer once, after the receipt is written")
    func pointerIsReplacedAfterEveryCheck() async throws {
        let harness = try ActivationHarnessBuilder.standard()
        let bound = try await harness.activator.commit(
            try harness.selfTested(harness.candidateID),
            context: harness.context
        )

        // The order the design fixes: read the generation, write the receipt, stage,
        // synchronize, then replace.
        #expect(
            await harness.store.operations
                == ["activePointer", "persistReceipt", "stage", "synchronize", "publish"]
        )
        let pointer = try #require(await harness.store.publishedPointer())
        #expect(pointer.bundleID == harness.candidateID)
        #expect(pointer.receiptID == bound.integrity.activationReceiptID)
        #expect(pointer.activationGeneration == bound.activationGeneration)
        #expect(await harness.store.leakedStagedTokens().isEmpty)
    }

    @Test("Every published value is a complete pointer, never a mixture")
    func observersSeeOnlyCompletePointers() async throws {
        let harness = try ActivationHarnessBuilder.standard()
        _ = try await harness.activator.commit(
            try harness.selfTested(harness.priorID),
            context: harness.context
        )
        _ = try await harness.activator.commit(
            try harness.selfTested(harness.candidateID),
            context: harness.context
        )

        // The published slot has held exactly three values: nothing, the prior pointer, the
        // new one. Each non-nil value decodes to a complete pointer, so no observer could
        // have read a half-written one.
        let history = await harness.store.publishedHistory
        #expect(history.count == 3)
        #expect(history[0] == nil, "the slot starts empty on a clean install")
        var seen: [ModelBundleID] = []
        for bytes in history.dropFirst() {
            let pointer = try FakeActivationRecordStore.decode(try #require(bytes))
            seen.append(pointer.bundleID)
        }
        #expect(seen == [harness.priorID, harness.candidateID])
    }

    @Test(
        "A failure at any step-7 boundary leaves the prior bundle active and its pointer bytes unchanged",
        arguments: FakeActivationRecordStore.FailurePoint.allCases
    )
    func stepSevenFailuresLeavePriorBundleUntouched(
        point: FakeActivationRecordStore.FailurePoint
    ) async throws {
        let harness = try ActivationHarnessBuilder.standard()
        let prior = try await harness.activator.commit(
            try harness.selfTested(harness.priorID),
            context: harness.context
        )
        let publishedBefore = await harness.store.publishedBytes
        let priorTreeBefore = try #require(harness.content.trees[harness.priorID.rawValue])

        // Named before the attempt, because the receipt identifier a write failure reports
        // carries the instant that attempt reads and the peeked clock is only correct until
        // something consumes it.
        let expected = harness.expectedFinding(for: point)
        await harness.store.fail(at: point)
        #expect(await harness.finding(committing: harness.candidateID) == expected)

        // The active tuple is the complete prior one, unchanged.
        #expect(await harness.activator.activeBundle() == prior)
        // The durable pointer is byte-for-byte what it was.
        #expect(await harness.store.publishedBytes == publishedBefore)
        // And so are the prior bundle's own bytes: the verification path only reads.
        let priorTreeAfter = try #require(harness.content.trees[harness.priorID.rawValue])
        #expect(priorTreeAfter.fileBytes == priorTreeBefore.fileBytes)
        #expect(priorTreeAfter.treeEntries == priorTreeBefore.treeEntries)
        // Nothing staged was left behind for a later launch to mistake for a pointer.
        #expect(await harness.store.leakedStagedTokens().isEmpty)
    }

    @Test("An interruption between synchronization and the pointer write publishes nothing")
    func interruptionBeforePointerWritePublishesNothing() async throws {
        let harness = try ActivationHarnessBuilder.standard()
        let prior = try await harness.activator.commit(
            try harness.selfTested(harness.priorID),
            context: harness.context
        )
        let publishedBefore = await harness.store.publishedBytes

        // Staged and synchronized, then the process never gets to the rename.
        await harness.store.fail(at: .publish)
        #expect(
            await harness.finding(committing: harness.candidateID)
                == .activationPointerNotReplaced(harness.candidateID)
        )

        // The published pointer never moved, so a later launch reads the prior activation.
        #expect(await harness.store.publishedBytes == publishedBefore)
        let pointer = try #require(await harness.store.publishedPointer())
        #expect(pointer.bundleID == harness.priorID)
        #expect(pointer.receiptID == prior.integrity.activationReceiptID)
        #expect(await harness.activator.activeBundle() == prior)
        // The staged state was dropped rather than left to be published by accident.
        #expect(await harness.store.leakedStagedTokens().isEmpty)
        #expect(await harness.store.publishedHistory.count == 2)
    }

    @Test("A receipt written before an interrupted publish stays and is not the active one")
    func orphanReceiptDoesNotBecomeActive() async throws {
        let harness = try ActivationHarnessBuilder.standard()
        let prior = try await harness.activator.commit(
            try harness.selfTested(harness.priorID),
            context: harness.context
        )
        await harness.store.fail(at: .publish)
        _ = await harness.finding(committing: harness.candidateID)

        // Two receipts exist; the pointer names the first. A persisted receipt on its own
        // activates nothing.
        #expect(await harness.store.receiptWriteOrder.count == 2)
        let pointer = try #require(await harness.store.publishedPointer())
        #expect(pointer.receiptID == prior.integrity.activationReceiptID)
        #expect(await harness.activator.activeBundle()?.bundleID == harness.priorID)
    }

    @Test("A failed candidate never becomes active on a clean install")
    func failedCandidateLeavesNothingActiveOnCleanInstall() async throws {
        let harness = try ActivationHarnessBuilder.standard()
        await harness.store.fail(at: .persistReceipt)
        _ = await harness.finding(committing: harness.candidateID)

        // Nothing was active before and nothing is now: a failure does not fall through to
        // some other asset (Requirement 10.12).
        #expect(await harness.activator.activeBundle() == nil)
        #expect(await harness.store.publishedBytes == nil)
        #expect(await harness.store.publishedHistory == [nil])
    }

    @Test("An unreadable published pointer refuses the activation rather than guessing")
    func unreadablePointerRefusesActivation() async throws {
        let harness = try ActivationHarnessBuilder.standard()
        await harness.store.fail(at: .readPointer)
        #expect(
            await harness.finding(committing: harness.candidateID)
                == .activationRecordStoreUnavailable
        )
        #expect(await harness.activator.activeBundle() == nil)
    }

    @Test("Two activations that overlap still publish two distinguishable generations")
    func overlappingActivationsStayDistinguishable() async throws {
        // An actor serializes each contiguous run of synchronous work, not a whole method that
        // suspends. Step 7 suspends at least four times, so two overlapping activations can
        // interleave, and the one thing that has to survive that is the generation: it is what
        // makes two published activations tellable apart (Requirement 10.13).
        let harness = try ActivationHarnessBuilder.standard()
        let first = try harness.selfTested(harness.priorID)
        let second = try harness.selfTested(harness.candidateID)
        let activator = harness.activator
        let context = harness.context

        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await activator.commit(first, context: context) }
            group.addTask { _ = try? await activator.commit(second, context: context) }
        }

        // Two receipts, two generations, and no generation used twice.
        let receipts = await harness.store.receipts
        #expect(receipts.count == 2)
        #expect(Set(receipts.values.map(\.activationGeneration.value)) == [1, 2])

        // The published slot moved twice and every value it held is a complete pointer whose
        // generation matches its own receipt, so neither activation published a pointer
        // describing the other one's record.
        let history = await harness.store.publishedHistory
        #expect(history.count == 3)
        for bytes in history.dropFirst() {
            let pointer = try FakeActivationRecordStore.decode(try #require(bytes))
            let receipt = try #require(receipts[pointer.receiptID.rawValue])
            #expect(pointer.bundleID == receipt.bundleID)
            #expect(pointer.activationGeneration == receipt.activationGeneration)
        }

        // The in-memory tuple and the durable pointer agree on which activation won.
        let published = try #require(await harness.store.publishedPointer())
        let active = try #require(await activator.activeBundle())
        #expect(active.bundleID == published.bundleID)
        #expect(active.activationGeneration == published.activationGeneration)
        #expect(active.activationGeneration.value == 2)
    }

    @Test("A generation no successor is representable for refuses the activation")
    func exhaustedGenerationRefusesActivation() async throws {
        // The pointer is what distinguishes two activations, so an activation that could not
        // be told apart from the published one is refused rather than published anyway. Not a
        // reachable state in a release — it takes `Int.max` published activations — but the
        // arithmetic has a boundary and fail-closed means the boundary refuses.
        let harness = try ActivationHarnessBuilder.standard()
        try await harness.store.seedPublished(
            try harness.receipt(
                harness.priorID,
                id: Sample.artifact("receipt.exhausted"),
                generation: try PositiveCount(validating: .max)
            )
        )
        let publishedBefore = await harness.store.publishedBytes

        #expect(
            await harness.finding(committing: harness.candidateID)
                == .activationGenerationExhausted
        )
        // Refused before anything was written: no receipt, no staging, no pointer move.
        #expect(await harness.store.attemptedReceiptIdentifiers.isEmpty)
        #expect(await harness.store.publishedBytes == publishedBefore)
        #expect(await harness.activator.activeBundle() == nil)
    }

    // MARK: - Failures before step 7 leave the prior bundle alone

    @Test("A verification failure leaves the prior bundle active and never reaches the store")
    func verificationFailureLeavesPriorBundleActive() async throws {
        // The whole path, not just step 7. A synthetic candidate stops at the weight
        // measurement — step 5 — which is this project's "every earlier check passed" signal
        // and, for this test, an ordinary verification failure with a prior bundle active.
        let harness = try ActivationHarnessBuilder.standard()
        let prior = try await harness.activator.commit(
            try harness.selfTested(harness.priorID),
            context: harness.context
        )
        let publishedBefore = await harness.store.publishedBytes
        let operationsBefore = await harness.store.operations
        let receiptsBefore = await harness.store.receipts

        #expect(
            await harness.finding(activating: harness.candidateID)
                == .modelWeightDigestMismatch(harness.assembled.layout.modelWeightBlob)
        )

        // Unchanged, and unchanged without the store having been asked anything: a candidate
        // that fails verification never gets as far as a record, so there is nothing for a
        // later launch to find (Requirement 10.12).
        #expect(await harness.activator.activeBundle() == prior)
        #expect(await harness.store.publishedBytes == publishedBefore)
        #expect(await harness.store.operations == operationsBefore)
        #expect(await harness.store.receipts == receiptsBefore)
        #expect(await harness.store.leakedStagedTokens().isEmpty)
    }

    @Test("An integrity failure leaves the prior bundle active and its bytes unread-from")
    func integrityFailureLeavesPriorBundleActive() async throws {
        // Failure at the earliest boundary this file depends on, so the finding names step 3
        // rather than step 5 and the "nothing was written" claim is not resting on one
        // particular step happening to fail.
        let harness = try ActivationHarnessBuilder.standard()
        let prior = try await harness.activator.commit(
            try harness.selfTested(harness.priorID),
            context: harness.context
        )
        let publishedBefore = await harness.store.publishedBytes
        let operationsBefore = await harness.store.operations
        let priorTreeBefore = try #require(harness.content.trees[harness.priorID.rawValue])

        // A same-length mutation inside the compiled-model tree, so no cheap size check can
        // catch it: only re-digesting the declared tree can. The finding names the declared
        // artifact — the tree — rather than the file, because the tree digest is what covers
        // its contents.
        let declaredTree = CompatibleBundleAssembler.modelTreePath
        let activator = harness.activator(overriding: {
            $0.trees[harness.candidateID.rawValue]?.overwriteContent(
                "\(declaredTree)/coremldata.bin",
                text: "core-ml-DATA"
            )
        })
        let observed = await Self.finding {
            try await activator.activate(harness.candidateID, context: harness.context)
        }
        #expect(observed == .artifactDigestMismatch(Sample.path(declaredTree)))

        #expect(await harness.activator.activeBundle() == prior)
        #expect(await harness.store.publishedBytes == publishedBefore)
        #expect(await harness.store.operations == operationsBefore)
        // The prior bundle's own bytes are what they were: verifying a candidate reads the
        // candidate, and nothing in the path can write anywhere.
        let priorTreeAfter = try #require(harness.content.trees[harness.priorID.rawValue])
        #expect(priorTreeAfter.fileBytes == priorTreeBefore.fileBytes)
        #expect(priorTreeAfter.treeEntries == priorTreeBefore.treeEntries)
    }

    @Test("A self-test failure writes no receipt and leaves the prior bundle active")
    func selfTestFailureWritesNoReceipt() async throws {
        // Step 6 driven directly, because step 5 stops a synthetic candidate before the
        // runner is reached. What matters for this task is not which self-test finding is
        // produced — task 6.2 owns that — but that a run which did not complete never becomes
        // a receipt, and that the bundle already active stays active (Requirement 10.12).
        let harness = try ActivationHarnessBuilder.standard()
        let prior = try await harness.activator.commit(
            try harness.selfTested(harness.priorID),
            context: harness.context
        )
        let publishedBefore = await harness.store.publishedBytes
        let operationsBefore = await harness.store.operations

        let executor = FakeSelfTestExecutor()
        executor.loadFault = .modelLoadFailed
        let runner = harness.selfTestRunner(executor: executor)
        let candidate = try harness.compatible(harness.candidateID)

        await #expect(throws: ModelBundleVerificationError.self) {
            _ = try await runner.run(candidate)
        }

        // No `SelfTestedBundleCandidate` exists, so step 7 is unreachable for this candidate:
        // the type system carries the ordering, and the store confirms nothing slipped past.
        #expect(await harness.activator.activeBundle() == prior)
        #expect(await harness.store.publishedBytes == publishedBefore)
        #expect(await harness.store.operations == operationsBefore)
        #expect(await harness.store.receiptWriteOrder.count == 1)
    }

    // MARK: - Rollback is the same path

    @Test("Rollback and activation perform identical verification work and reach the same finding")
    func rollbackRunsTheIdenticalVerificationPath() async throws {
        // Two activators over identical stores. One is driven through the activation entry
        // point, the other through rollback, over the same bundle from the same starting
        // state. Both are expected to stop at the weight measurement, which is where a
        // synthetic candidate always stops, and the recorded reads are the evidence that the
        // steps before it were the same steps.
        let activation = try ActivationHarnessBuilder.standard()
        let rollback = try ActivationHarnessBuilder.standard()

        let activationFault = await activation.fault {
            try await activation.activator.activateLocalCandidate(
                activation.priorID,
                context: activation.context
            )
        }
        let rollbackFault = await rollback.fault {
            try await rollback.activator.rollback(
                to: rollback.priorID,
                context: rollback.context
            )
        }

        #expect(activationFault == .analysis(.modelLoadError, stage: .modelLoad))
        #expect(rollbackFault == activationFault)
        #expect(!activation.readLog.work.isEmpty)
        #expect(rollback.readLog.work == activation.readLog.work)

        // The same finding underneath the user-facing category, at the same step.
        let activationFinding = await activation.finding(activating: activation.priorID)
        let rollbackFinding = await rollback.finding(rollingBackTo: rollback.priorID)
        #expect(activationFinding == .modelWeightDigestMismatch(activation.assembled.layout.modelWeightBlob))
        #expect(rollbackFinding == activationFinding)
    }

    @Test("Rollback re-verifies a prior bundle rather than trusting that it was once active")
    func rollbackGivesPriorBundleNoFreePass() async throws {
        let harness = try ActivationHarnessBuilder.standard()
        // The prior bundle is active through a completed run.
        let prior = try await harness.activator.commit(
            try harness.selfTested(harness.priorID),
            context: harness.context
        )
        #expect(await harness.activator.activeBundle() == prior)

        let publishedBefore = await harness.store.publishedBytes

        // Now its bytes change on disk. A rollback to it has to notice, which it can only do
        // by streaming and digesting the tree again — a cached verification, a receipt lookup,
        // or an "it was active a moment ago" shortcut would all miss this.
        // Same length as before, so the change is invisible to anything short of a digest.
        let declaredTree = CompatibleBundleAssembler.modelTreePath
        let activator = harness.activator(overriding: {
            $0.trees[harness.priorID.rawValue]?.overwriteContent(
                "\(declaredTree)/coremldata.bin",
                text: "core-ml-DATA"
            )
        })
        #expect(
            await Self.fault {
                try await activator.rollback(to: harness.priorID, context: harness.context)
            } == .analysis(.modelLoadError, stage: .modelLoad)
        )
        // The exact step that refused it: the measured digest of the changed artifact
        // disagrees with the signed manifest. Naming the step is what distinguishes
        // re-measurement from a rollback that failed for some unrelated reason.
        let observed = await Self.finding {
            try await activator.activate(harness.priorID, context: harness.context)
        }
        #expect(observed == .artifactDigestMismatch(Sample.path(declaredTree)))
        // And the prior activation survives its own failed rollback untouched.
        #expect(await harness.activator.activeBundle() == prior)
        #expect(await harness.store.publishedBytes == publishedBefore)
    }

    @Test("Rollback to a bundle outside the approved catalogue is refused")
    func rollbackToUnapprovedBundleRefused() async throws {
        let harness = try ActivationHarnessBuilder.standard()
        let unlisted = Sample.bundle("bundle.unlisted")
        #expect(
            await Self.fault {
                try await harness.activator.rollback(to: unlisted, context: harness.context)
            } == .analysis(.modelLoadError, stage: .modelLoad)
        )
        #expect(await harness.activator.activeBundle() == nil)
    }

    // MARK: - Using the active bundle

    @Test("No active bundle prevents inference with model-load-error")
    func noActiveBundleIsModelLoadError() async throws {
        let harness = try ActivationHarnessBuilder.standard()
        #expect(await harness.activator.activeBundle() == nil)
        #expect(
            await Self.fault {
                try await harness.activator.verifiedActiveBundle(for: harness.context)
            } == .analysis(.modelLoadError, stage: .modelLoad)
        )
        #expect(await harness.activeFinding() == .noActiveModelBundle)
    }

    @Test("A persisted receipt alone never makes a bundle active")
    func persistedReceiptIsNotAVerificationShortcut() async throws {
        // A launch that finds a durable pointer and a bindable receipt on disk. Both are
        // records that a verification run once happened; neither is a substitute for one, so
        // nothing is active until the full path runs in this process.
        let harness = try ActivationHarnessBuilder.standard()
        let receipt = try harness.receipt(
            harness.priorID,
            id: Sample.artifact("receipt.seeded"),
            generation: try PositiveCount(validating: 7)
        )
        #expect(receipt.isBindable)
        try await harness.store.seedPublished(receipt)

        #expect(await harness.activator.activeBundle() == nil)
        #expect(await harness.activeFinding() == .noActiveModelBundle)

        // The seeded generation is still respected, so a new activation cannot reuse a
        // generation an earlier launch already published.
        let bound = try await harness.activator.commit(
            try harness.selfTested(harness.candidateID),
            context: harness.context
        )
        #expect(bound.activationGeneration.value == 8)
    }

    @Test("An active bundle incompatible with the running context is model-load-error")
    func activeBundleRecheckedAgainstTheRunningContext() async throws {
        let harness = try ActivationHarnessBuilder.standard()
        let bound = try await harness.activator.commit(
            try harness.selfTested(harness.candidateID),
            context: harness.context
        )
        #expect(try await harness.activator.verifiedActive(for: harness.context) == bound)

        // The same bundle, a build it was never declared compatible with. Nothing falls back
        // to an older asset; the answer is model-load-error.
        let otherBuild = Sample.releaseContext(appBuild: Sample.appBuild("build.other"))
        #expect(
            await Self.fault {
                try await harness.activator.verifiedActiveBundle(for: otherBuild)
            } == .analysis(.modelLoadError, stage: .modelLoad)
        )
        #expect(
            await harness.activeFinding(for: otherBuild)
                == .activeModelBundleNotCompatible(harness.candidateID)
        )
        // Still active and unchanged: an incompatible query is not a deactivation.
        #expect(await harness.activator.activeBundle() == bound)
    }

    @Test("A bound bundle exposes the receipt projection a session binding carries")
    func boundBundleCarriesTheIntegrityProjection() async throws {
        let harness = try ActivationHarnessBuilder.standard()
        let tested = try harness.selfTested(harness.candidateID)
        let bound = try await harness.activator.commit(tested, context: harness.context)

        #expect(bound.integrity.status == .verified)
        #expect(bound.integrity.verificationPolicyID == tested.candidate.tree.verificationPolicyID)
        #expect(bound.integrity.verifiedManifestDigest == tested.candidate.tree.manifestDigest)
        #expect(bound.integrity.verifiedArtifactDigests == tested.candidate.tree.verifiedArtifacts)
        #expect(bound.componentVersions == tested.candidate.componentVersions)
        #expect(bound.modelIdentity == RequiredPixelModel.identity)
    }

    // MARK: - No model-update channel

    @Test("Nothing in the module's sources can reach a network or name a remote bundle")
    func moduleHasNoModelUpdateChannel() throws {
        // Requirements 10.19 and 10.21 make "Remote Model Updates stay disabled" a fact about
        // the module rather than a runtime setting: bundles ship inside the application
        // version, so there is no update channel for a request to travel over. The sibling
        // scan in `ReleaseSelfTestExecutionTests` covers the framework imports; this one adds
        // the vocabulary a model-update client would need, so a later change that reaches for
        // one fails here.
        //
        // Comments are stripped before the scan, because the module's own documentation
        // discusses the absence of these things by name and a naive substring match would
        // flag that prose.
        let forbidden = [
            "URLSession", "URLRequest", "URLComponents", "NSURLConnection", "NWConnection",
            "NWPathMonitor", "NWEndpoint", "import Network", "import FoundationNetworking",
            "import CFNetwork", "dataTask", "download", "upload", "http", "CFSocket",
            "getaddrinfo", "fetch",
        ]
        for file in try Self.moduleSourceFiles() {
            let code = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            for token in forbidden {
                #expect(
                    !code.contains(token),
                    "\(file.lastPathComponent) must not reference \(token)"
                )
            }
        }
    }

    @Test("The activation store seam has no member that could fetch or update a bundle")
    func activationStoreSeamHasNoUpdateMember() throws {
        // The port-level version of the same requirement: a member that resolved, discovered,
        // or downloaded a bundle would be visible here as a declaration. Scanning the
        // declaration text keeps the guarantee where a reviewer looks for it.
        let source = try Self.moduleSource(named: "ActivationRecordStore.swift")
        let code = Self.strippingComments(source)
        for token in ["func fetch", "func download", "func discover", "func resolve", "URL"] {
            #expect(!code.contains(token), "the store seam must not declare \(token)")
        }
        // And nothing in it can remove or edit a persisted receipt.
        for token in ["func delete", "func remove", "func update", "func overwrite"] {
            #expect(!code.contains(token), "the store seam must not declare \(token)")
        }
    }

    // MARK: - Helpers

    private static func moduleSourceFiles() throws -> [URL] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DefAIkeModelBundle")
        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "the module's sources must be readable for this to mean anything")
        return files
    }

    private static func moduleSource(named name: String) throws -> String {
        let file = try #require(try moduleSourceFiles().first { $0.lastPathComponent == name })
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Removes `//` comment text so a scan reads code rather than documentation.
    ///
    /// No source in this module puts `//` inside a string literal, and the scan asserts the
    /// absence of exactly the tokens that would appear in one, so a simple split is enough
    /// and its failure mode is a false pass on a file that does not exist.
    private static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let marker = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<marker.lowerBound])
            }
            .joined(separator: "\n")
    }

    private static func fault(
        _ body: () async throws -> BoundModelBundle
    ) async -> AnalysisFault? {
        do {
            _ = try await body()
            return nil
        } catch let fault as AnalysisFault {
            return fault
        } catch {
            return nil
        }
    }

    /// The exact verification finding one call produced, or `nil` when it succeeded.
    ///
    /// The audit-trail view of the same refusal ``fault(_:)`` reports as one category. Which
    /// step refused a candidate is the thing a release needs to know, and asserting it is how
    /// these tests distinguish "the tamper was measured" from "something else went wrong"
    /// (Requirement 11.17).
    private static func finding(
        _ body: () async throws -> BoundModelBundle
    ) async -> ModelBundleVerificationError? {
        do {
            _ = try await body()
            return nil
        } catch let finding as ModelBundleVerificationError {
            return finding
        } catch {
            return nil
        }
    }
}

// MARK: - Harness conveniences

extension ActivationHarness {
    /// The finding step 7 produced for one bundle, or `nil` when it succeeded.
    func finding(committing bundle: ModelBundleID) async -> ModelBundleVerificationError? {
        do {
            _ = try await activator.commit(try selfTested(bundle), context: context)
            return nil
        } catch let error as ModelBundleVerificationError {
            return error
        } catch {
            return nil
        }
    }

    /// The finding the whole path produced for an activation.
    func finding(activating bundle: ModelBundleID) async -> ModelBundleVerificationError? {
        do {
            _ = try await activator.activate(bundle, context: context)
            return nil
        } catch {
            return error
        }
    }

    /// The finding the whole path produced for a rollback, reached through
    /// ``ModelBundleActivator/activate(_:context:)`` so the exact finding survives.
    func finding(rollingBackTo bundle: ModelBundleID) async -> ModelBundleVerificationError? {
        await finding(activating: bundle)
    }

    /// The finding reading the active bundle produced.
    func activeFinding(for release: ReleaseContext? = nil) async -> ModelBundleVerificationError? {
        do {
            _ = try await activator.verifiedActive(for: release ?? context)
            return nil
        } catch {
            return error
        }
    }

    func fault(_ body: () async throws -> BoundModelBundle) async -> AnalysisFault? {
        do {
            _ = try await body()
            return nil
        } catch let fault as AnalysisFault {
            return fault
        } catch {
            return nil
        }
    }

    /// The finding each programmed store failure is expected to produce.
    func expectedFinding(
        for point: FakeActivationRecordStore.FailurePoint
    ) -> ModelBundleVerificationError {
        switch point {
        case .readPointer: .activationRecordStoreUnavailable
        case .persistReceipt: .activationReceiptNotPersisted(expectedReceiptID())
        case .stagePointer: .activationPointerNotStaged(candidateID)
        case .synchronize: .activationStateNotSynchronized(candidateID)
        case .publish: .activationPointerNotReplaced(candidateID)
        }
    }

    /// The receipt identifier the next attempt will derive.
    ///
    /// Peeked from the same clock the activation reads, so it is the identifier that attempt
    /// will actually use rather than a guess about it. Only correct while nothing has consumed
    /// a reading since, which is why callers name it before the attempt they are describing.
    private func expectedReceiptID() -> ArtifactID {
        // A receipt-write failure happens after the generation was read, so the generation is
        // one past the currently published one, and the instant is the next reading.
        guard let id = ModelBundleActivator.receiptIdentity(
            bundle: candidateID,
            generation: try! PositiveCount(validating: 2),
            at: clock.nextReading
        ) else {
            fatalError("A sample bundle identifier must derive a canonical receipt identifier.")
        }
        return id
    }
}
