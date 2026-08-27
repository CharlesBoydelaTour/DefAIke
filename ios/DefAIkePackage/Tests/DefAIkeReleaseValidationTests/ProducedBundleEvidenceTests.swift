import DefAIkeDomain
import Testing

@testable import DefAIkeModelBundle
@testable import DefAIkeReleaseValidation

/// Verifying a tool-produced bundle with the runtime's own checks, and recording the result.
///
/// The point of every test here is that the checks are not this module's. A bundle the builder
/// produced is handed to ``ModelBundleIntegrityVerifier`` and
/// ``ModelBundleCompatibilityVerifier`` unchanged, and what they say is what gets recorded. So
/// these tests are simultaneously about the builder — its digests, ordering, and layout are
/// right only if the verifier accepts them — and about the recorder, which must attribute what
/// the verifier said without softening it.
///
/// ## The ceiling, stated once
///
/// Requirement 10.4 pins the model weight-blob digest to
/// `f073f8a3…d26d4c1e`, and that 43 MB blob is not in this repository. So the synthetic staged
/// content here can carry every artifact except the one whose bytes are pinned, and the
/// reachable ceiling is exact:
///
///   * integrity verification passes **completely** — manifest, detached signature, and every
///     declared artifact digest including both directory-tree digests; and
///   * compatibility verification passes every declarative check and stops at the weight
///     measurement, which it deliberately performs last.
///
/// `stopsExactlyAtTheApprovedWeightBlob` asserts that, naming the finding. No test here
/// substitutes a weight digest, relaxes the check, or reports the ceiling as a pass:
/// `compatibility` stays ``GateOutcome/failed`` throughout, and the gate that would have to be
/// weakened to change that lives in `DefAIkeModelBundle`, which this task does not touch.
@Suite("Produced bundle verification and evidence")
struct ProducedBundleEvidenceTests {
    // MARK: - The runtime accepts what the builder produced

    @Test("The runtime integrity verifier accepts a tool-produced bundle in full")
    func runtimeIntegrityVerificationPasses() throws {
        // Steps 1 through 3 of the fixed verification order over the builder's own output: the
        // manifest parses under the policy ceiling with no duplicate key, the detached
        // signature verifies over the exact manifest bytes under a trusted key, and every
        // declared artifact matches its declared size and digest with nothing missing and
        // nothing undeclared.
        let produced = try SampleRelease.produce()
        let tree = try produced.integrityVerifier.verify(produced.built.bundleID)

        #expect(tree.bundleID == produced.built.bundleID)
        #expect(tree.manifest == produced.built.manifest)
        #expect(tree.signingKey == produced.built.signingRequest.designatedKey)
        #expect(tree.verificationPolicyID == produced.request.configuration.bundleVerificationPolicy.id)
    }

    @Test("What the runtime measured is exactly what the build declared")
    func measuredInventoryEqualsDeclaredInventory() throws {
        // The strongest single statement that there is one implementation of the digest rules
        // rather than two: the inventory the build wrote into the manifest and the inventory
        // streaming re-derived from the bytes are the same records in the same order.
        let produced = try SampleRelease.produce()
        let tree = try produced.integrityVerifier.verify(produced.built.bundleID)

        #expect(tree.verifiedArtifacts == produced.built.digestInventory)
        #expect(tree.manifestDigest == produced.built.manifestDigest)
        #expect(tree.manifestDigest == produced.built.signingRequest.messageDigest)
    }

    @Test("The recorded verification stops exactly at the approved weight blob")
    func stopsExactlyAtTheApprovedWeightBlob() throws {
        let produced = try SampleRelease.produce()
        let verification = produced.verification()

        #expect(verification.releaseSignature == .passed)
        #expect(verification.perArtifactDigests == .passed)
        #expect(verification.compatibility == .failed)
        #expect(verification.finding == produced.approvedWeightBlobCeiling)
        #expect(verification.stoppedAtApprovedWeightBlob)
        #expect(verification.passedEveryCheckBeforeTheWeightBlob)

        // The ceiling is a recorded refusal, never a pass. Both readings are asserted so a
        // future change cannot quietly turn the convenience projection into a green result.
        #expect(verification.compatibility.isPassing == false)
        #expect(verification.verifiedArtifactDigests == produced.built.digestInventory)
        #expect(verification.signingKey == Sample.signingKey())
    }

    // MARK: - Any perturbation is rejected

    @Test(
        "Perturbing any declared artifact makes the runtime reject the bundle",
        arguments: [
            StagedLayout.compiledModel,
            StagedLayout.fixtureRoot,
            StagedLayout.noticeRoot,
            StagedLayout.selfTestSpecification,
            StagedLayout.fixtureCatalog,
            StagedLayout.noticeIndex,
        ]
    )
    func perturbedArtifactIsRejected(declared: String) throws {
        // One edit per artifact, same byte count, so the finding is a digest disagreement
        // rather than a size disagreement. A tree artifact is perturbed through one of its
        // members, which is what an edited file inside the compiled model or the fixture
        // directory actually looks like.
        var produced = try SampleRelease.produce()
        let path = Sample.path(declared)
        let target = try Self.perturbationTarget(in: produced.tree, declared: declared)
        let original = try #require(produced.tree.files[target])
        produced.tree.replaceBytes(
            at: target,
            with: Array(repeating: UInt8(ascii: "x"), count: original.count)
        )

        #expect(produced.finding() == .artifactDigestMismatch(path))
        let verification = produced.verification()
        #expect(verification.releaseSignature == .passed)
        #expect(verification.perArtifactDigests == .failed)
        #expect(verification.compatibility == .notExecuted)
        #expect(verification.stoppedAtApprovedWeightBlob == false)
    }

    @Test("Removing a declared artifact makes the runtime reject the bundle")
    func removedArtifactIsRejected() throws {
        var produced = try SampleRelease.produce()
        produced.tree.removeFile(at: StagedLayout.noticeIndex)
        #expect(produced.finding() == .declaredArtifactMissing(Sample.path(StagedLayout.noticeIndex)))
    }

    @Test("Adding content the manifest does not declare makes the runtime reject the bundle")
    func undeclaredContentIsRejected() throws {
        // The other half of mutation sensitivity: an added file is a finding even though every
        // declared digest still matches.
        var produced = try SampleRelease.produce()
        produced.tree.addUndeclaredFile(at: "artifacts/leftover.tmp", text: "staging residue")
        #expect(produced.finding() == .undeclaredTreeEntry(Sample.path("artifacts/leftover.tmp")))
    }

    @Test("A signature over other bytes makes the runtime reject the bundle")
    func signatureOverOtherBytesIsRejected() throws {
        let produced = try SampleRelease.produce(keyMaterial: Array("other-key-material".utf8))
        #expect(produced.finding() == .manifestSignatureDidNotVerify(key: Sample.signingKey()))

        let verification = produced.verification()
        #expect(verification.releaseSignature == .failed)
        #expect(verification.perArtifactDigests == .notExecuted)
        #expect(verification.compatibility == .notExecuted)
        #expect(verification.verifiedArtifactDigests.isEmpty)
        #expect(verification.verifiedManifestDigest == nil)
    }

    @Test("An absent detached signature makes the runtime reject the bundle")
    func absentSignatureIsRejected() throws {
        var produced = try SampleRelease.produce()
        produced.tree.removeFile(at: ModelBundleManifest.signatureFileName)
        #expect(produced.finding() == .reservedFileMissing(ModelBundleManifest.signatureFileName))

        // Reached before either gate produces a result, so neither is recorded as passing.
        let verification = produced.verification()
        #expect(verification.releaseSignature == .notExecuted)
        #expect(verification.perArtifactDigests == .notExecuted)
    }

    @Test("Rewriting the manifest makes the runtime reject the bundle")
    func rewrittenManifestIsRejected() throws {
        // The signature covers the exact bytes, so a rewrite is caught whether or not the
        // rewritten bytes are still valid JSON. Either finding refuses the bundle; what matters
        // is that no rewrite reaches a passing signature gate.
        var produced = try SampleRelease.produce()
        let original = try #require(produced.tree.files[ModelBundleManifest.manifestFileName])
        produced.tree.replaceBytes(
            at: ModelBundleManifest.manifestFileName,
            with: Array(repeating: UInt8(ascii: " "), count: original.count)
        )
        #expect(produced.finding() != nil)
        #expect(produced.verification().releaseSignature.isPassing == false)
    }

    // MARK: - Activation and rollback evidence (Requirements 14.13 and 10.17)

    @Test("A completed activation and rollback are recorded with their receipts")
    func activationAndRollbackAreRecorded() async throws {
        // The bundle manager here is the **port double**, standing in for the approved
        // activation step. That is the only way to exercise a completed step 7 in this
        // repository: no synthetic bundle can reach it through the real path, because the
        // weight measurement stops first. So this record mixes real verification results with
        // a stubbed activation, and the assertions below say so explicitly — the verification
        // gates in the same record are still at the ceiling.
        let produced = try SampleRelease.produce()
        let prior = try SampleRelease.build(
            request: try SampleBuildRequest.standard(bundleID: Sample.rollbackBundle())
        )
        let manager = FakeBundleManager(
            activated: try Sample.boundBundle(manifest: produced.built.manifest, generation: 4),
            rolledBack: try Sample.boundBundle(
                manifest: prior.manifest,
                receiptIdentifier: "receipt.rollback",
                generation: 5
            )
        )

        let evidence = await produced.recorder(bundles: manager).recordActivationEvidence(
            of: produced.built.bundleID,
            rollingBackTo: Sample.rollbackBundle(),
            for: produced.context
        )

        #expect(evidence.releaseSelfTests == .passed)
        #expect(evidence.atomicActivation == .passed)
        #expect(evidence.verifiedRollback == .passed)
        #expect(evidence.rollbackTarget == Sample.rollbackBundle())
        #expect(evidence.activationFault == nil)
        #expect(evidence.rollbackFault == nil)

        let activated = try #require(evidence.activated)
        #expect(activated.bundleID == produced.built.bundleID)
        #expect(activated.receiptID == Sample.artifact("receipt.sample"))
        #expect(activated.activationGeneration.value == 4)
        #expect(activated.integrityStatus == .verified)
        #expect(activated.componentVersions == produced.built.manifest.componentVersions)

        let rolledBack = try #require(evidence.rolledBack)
        #expect(rolledBack.bundleID == Sample.rollbackBundle())
        #expect(rolledBack.activationGeneration.value == 5)

        // Both port members ran, in order, and rollback named the supplied target rather than
        // one the recorder chose.
        #expect(
            manager.log.calls == [
                "activate(\(produced.built.bundleID.rawValue))",
                "rollback(\(Sample.rollbackBundle().rawValue))",
            ]
        )

        // And the verification half of the same record is still at the ceiling, so the record
        // cannot be read as a fully passing bundle.
        #expect(evidence.stoppedAtApprovedWeightBlob)
        #expect(evidence.gatesWithoutAPassingResult == [.compatibility])
    }

    @Test("A refused activation records no self-test result and never attempts a rollback")
    func refusedActivationRecordsNoDownstreamResult() async throws {
        // What the real activator does over this content: the one verification path refuses the
        // candidate at the weight measurement, so nothing is active. A rollback with nothing to
        // leave in place demonstrates nothing about Requirement 10.17, so it is recorded as
        // missing rather than as a failure of a gate that never ran — and it is genuinely not
        // attempted, which the call log shows.
        let produced = try SampleRelease.produce()
        let manager = FakeBundleManager()

        let evidence = await produced.recorder(bundles: manager).recordActivationEvidence(
            of: produced.built.bundleID,
            rollingBackTo: Sample.rollbackBundle(),
            for: produced.context
        )

        #expect(evidence.atomicActivation == .failed)
        #expect(evidence.releaseSelfTests == .notExecuted)
        #expect(evidence.verifiedRollback == .notExecuted)
        #expect(evidence.activated == nil)
        #expect(evidence.rolledBack == nil)
        #expect(evidence.activationFault == .analysis(.modelLoadError, stage: .modelLoad))
        #expect(evidence.rollbackFault == nil)
        #expect(manager.log.calls == ["activate(\(produced.built.bundleID.rawValue))"])

        // The precise finding is in the verification half, because the port's vocabulary is the
        // closed set a session can see and says only `model-load-error`.
        #expect(evidence.verification.finding == produced.approvedWeightBlobCeiling)
    }

    @Test("A refused rollback is recorded without disturbing the activation result")
    func refusedRollbackIsRecordedOnItsOwn() async throws {
        let produced = try SampleRelease.produce()
        let manager = FakeBundleManager(
            activated: try Sample.boundBundle(manifest: produced.built.manifest),
            rolledBack: nil
        )

        let evidence = await produced.recorder(bundles: manager).recordActivationEvidence(
            of: produced.built.bundleID,
            rollingBackTo: Sample.rollbackBundle(),
            for: produced.context
        )

        #expect(evidence.atomicActivation == .passed)
        #expect(evidence.releaseSelfTests == .passed)
        #expect(evidence.verifiedRollback == .failed)
        #expect(evidence.rolledBack == nil)
        #expect(evidence.rollbackFault == .analysis(.modelLoadError, stage: .modelLoad))
        #expect(evidence.gatesWithoutAPassingResult.contains(.verifiedRollback))
    }

    @Test("Every one of Requirement 14.13's six gates has a recorded outcome")
    func everyGateIsRecorded() async throws {
        let produced = try SampleRelease.produce()
        let evidence = await produced.recorder().recordActivationEvidence(
            of: produced.built.bundleID,
            rollingBackTo: Sample.rollbackBundle(),
            for: produced.context
        )

        #expect(BundleReleaseGate.allCases.count == 6)
        // Every gate resolves to one of the three recorded outcomes, and the two that passed
        // are exactly the two a synthetic bundle can demonstrate.
        #expect(evidence.outcome(of: .releaseSignature) == .passed)
        #expect(evidence.outcome(of: .perArtifactDigests) == .passed)
        #expect(evidence.outcome(of: .compatibility) == .failed)
        #expect(evidence.outcome(of: .releaseSelfTests) == .notExecuted)
        #expect(evidence.outcome(of: .atomicActivation) == .failed)
        #expect(evidence.outcome(of: .verifiedRollback) == .notExecuted)

        // A missing result is listed exactly as a failing one is: Requirement 14.15 treats them
        // the same, and nothing here promotes either to a pass.
        #expect(
            evidence.gatesWithoutAPassingResult
                == [.compatibility, .releaseSelfTests, .atomicActivation, .verifiedRollback]
        )
    }

    // MARK: - Helpers

    /// The file to edit in order to perturb one declared artifact.
    ///
    /// A declared file is edited directly; a declared directory tree is perturbed through one
    /// of its members, which is what an edited artifact inside it looks like from outside.
    private static func perturbationTarget(
        in tree: MaterializedBundle,
        declared: String
    ) throws -> String {
        if tree.files[declared] != nil { return declared }
        let prefix = declared + "/"
        let members = tree.files.keys.filter { $0.hasPrefix(prefix) }.sorted()
        return try #require(members.first)
    }
}
