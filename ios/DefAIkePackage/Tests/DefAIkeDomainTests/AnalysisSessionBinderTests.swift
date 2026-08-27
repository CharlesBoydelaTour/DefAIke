import DefAIkeTestSupport
import Foundation
import Testing

@testable import DefAIkeDomain

// Task 6.4: the immutable Analysis Session bundle binding.
//
// Three questions, and they are tested separately because they fail separately:
//
//   * **Completeness.** Does one snapshot carry the whole tuple — bundle version, model
//     identity, Core ML component, preprocessing, calibration, copy compatibility, scope,
//     the integrity receipt projection, and the related policy versions?
//   * **Immutability.** Once taken, can anything change it? Activation and rollback after
//     acceptance, and a second bind for the same session, are the two ways to try.
//   * **Traceability.** Do the same bound identifiers reach report construction, rather
//     than a second description of them?
//
// Property 13 generates activation histories over all of this and belongs to task 6.7.
// What is here is the example-level behavior 6.4 itself owns, plus one refusal per
// admission check.

// MARK: - A bundle manager whose active pointer a test can move

/// The Model Bundle port with a settable active bundle.
///
/// `StubModelBundleManager` keys its catalogue by bundle identifier, so it cannot hold two
/// activations of the same bundle — which is exactly the case that separates "the session
/// kept its snapshot" from "the session happened to re-read the same value". It also
/// cannot report cancellation, and the binder has to forward that unchanged rather than
/// reporting a cancelled session as a model error.
private actor MovableBundleManager: ModelBundleManaging {
    private var active: BoundModelBundle?
    private var programmedFault: AnalysisFault?
    private var reads = 0

    init(active: BoundModelBundle?) {
        self.active = active
    }

    /// Replaces the active bundle, as an activation or a rollback would.
    func makeActive(_ bundle: BoundModelBundle) {
        active = bundle
        programmedFault = nil
    }

    /// Makes the next read report `fault`.
    func fail(with fault: AnalysisFault) {
        programmedFault = fault
    }

    /// How many times the active pointer was read.
    var readCount: Int { reads }

    func verifiedActiveBundle(
        for context: ReleaseContext
    ) throws(AnalysisFault) -> BoundModelBundle {
        reads += 1
        if let programmedFault { throw programmedFault }
        guard let active else { throw .analysis(.modelLoadError, stage: .modelLoad) }
        guard active.isCompatible(with: context) else {
            throw .analysis(.modelLoadError, stage: .modelLoad)
        }
        return active
    }

    func activateLocalCandidate(
        _ id: ModelBundleID,
        context: ReleaseContext
    ) throws(AnalysisFault) -> BoundModelBundle {
        try verifiedActiveBundle(for: context)
    }

    func rollback(
        to id: ModelBundleID,
        context: ReleaseContext
    ) throws(AnalysisFault) -> BoundModelBundle {
        try verifiedActiveBundle(for: context)
    }
}

// MARK: - Fixtures

private enum BindingFixture {

    /// A coherent admission from the real startup gate.
    ///
    /// Deliberately produced by running preflight rather than by constructing a
    /// `ReleaseAdmission` directly: the initializer is `fileprivate` precisely so that
    /// only a passed gate can make one, and a test that bypassed it would be binding
    /// against an admission no build could hold.
    static func admission(
        provenance: Bool = false,
        fusion: Bool = false,
        target: ExecutionTarget = .mainApplication
    ) async throws -> ReleaseAdmission {
        let scenario = try await PreflightSample.scenario(
            provenance: provenance,
            fusion: fusion,
            target: target
        )
        return try await scenario.run()
    }

    /// A verified bundle whose receipt records a later activation of the same bundle.
    ///
    /// Same bundle identifier and the same six component versions, so it is admissible;
    /// a different receipt identity and activation generation, so a snapshot taken from
    /// it is distinguishable from one taken from the first activation.
    static func reactivated(
        _ generation: Int,
        bundleID: String = "bundle.sample"
    ) throws -> BoundModelBundle {
        let receipt = try ActivationReceipt(
            id: Sample.artifact("receipt.activation.\(generation)"),
            schemaVersion: .v1,
            bundleID: Sample.bundle(bundleID),
            verificationPolicy: Sample.artifact("policy.bundle-verification"),
            verifiedManifestDigest: Sample.digest("f"),
            verifiedArtifactDigests: [Sample.digestRecord()],
            signatureOutcome: .passed,
            selfTestOutcome: .passed,
            deviceContext: PreflightSample.device(),
            activationGeneration: Sample.count(generation),
            activatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        return try #require(
            BoundModelBundle(
                manifest: try PreflightSample.bundleManifest(bundleID: bundleID),
                receipt: receipt
            )
        )
    }

    static func asset(_ session: String = "session-0001") -> ImportedEncodedAsset {
        PortValue.asset(route: .photosPicker, sessionID: PortValue.sessionID(session))
    }

    /// A binder over one admission and one active bundle.
    static func binder(
        admission: ReleaseAdmission,
        active: BoundModelBundle?,
        ceiling: Int = AnalysisSessionBinder.defaultMaximumBoundSessionCount
    ) -> (binder: AnalysisSessionBinder, bundles: MovableBundleManager) {
        let bundles = MovableBundleManager(active: active)
        return (
            AnalysisSessionBinder(
                admission: admission,
                bundles: bundles,
                maximumBoundSessionCount: ceiling
            ),
            bundles
        )
    }
}

// MARK: - Completeness

@Suite("Analysis Session bundle binding is complete")
struct SessionBindingCompletenessTests {

    @Test("The snapshot records every component version from one bundle")
    func snapshotCarriesTheWholeTuple() async throws {
        let admission = try await BindingFixture.admission()
        let components = admission.bundle.componentVersions

        let session = try BoundAnalysisSession.snapshot(
            accepting: BindingFixture.asset(),
            of: admission.bundle,
            under: admission
        )
        let binding = session.binding

        #expect(binding.modelBundleID == admission.bundle.bundleID)
        #expect(binding.modelIdentity == RequiredPixelModel.identity)
        #expect(binding.coreMLModelVersion == components.coreMLModel)
        #expect(binding.preprocessingContractID == components.preprocessingContract)
        #expect(binding.calibrationPolicyID == components.calibrationPolicy)
        #expect(binding.verdictCopyCompatibilityID == components.verdictCopyCompatibility)
        #expect(session.scope.id == components.evidenceScope)
    }

    @Test("The snapshot records the session, build, and matched device configuration")
    func snapshotCarriesTheRunningIdentity() async throws {
        let admission = try await BindingFixture.admission()

        let session = try BoundAnalysisSession.snapshot(
            accepting: BindingFixture.asset("session-0007"),
            of: admission.bundle,
            under: admission
        )

        #expect(session.sessionID == PortValue.sessionID("session-0007"))
        #expect(session.binding.appBuildID == admission.context.device.appBuild)
        #expect(session.binding.deviceConfigurationID == admission.approvedConfiguration.id)
        #expect(session.binding.capabilityManifestID == admission.context.capabilityManifestID)
    }

    @Test("The snapshot records the related policy versions")
    func snapshotCarriesRelatedPolicyVersions() async throws {
        let admission = try await BindingFixture.admission()
        let configuration = admission.configuration

        let session = try BoundAnalysisSession.snapshot(
            accepting: BindingFixture.asset(),
            of: admission.bundle,
            under: admission
        )

        #expect(session.binding.lifecyclePolicyID == configuration.lifecyclePolicy.id)
        #expect(
            session.binding.resourceBudgetID
                == configuration.resourceBudgets.mainApplication.id
        )
        #expect(session.resourceBudget.target == .mainApplication)
    }

    @Test("The snapshot carries the bound policy values, not just their identifiers")
    func snapshotCarriesPolicyValues() async throws {
        let admission = try await BindingFixture.admission()

        let session = try BoundAnalysisSession.snapshot(
            accepting: BindingFixture.asset(),
            of: admission.bundle,
            under: admission
        )

        // The validation, preprocessing, and calibration ports each take the artifact
        // they apply as a parameter. Carrying the values means a session applies the
        // versions it bound for its whole lifetime instead of looking them up again.
        #expect(session.preprocessingContract == admission.configuration.preprocessingContract)
        #expect(session.calibrationPolicy == admission.configuration.calibrationPolicy)
        #expect(session.resourceBudget == admission.configuration.resourceBudgets.mainApplication)
    }

    @Test("The snapshot carries the verified integrity receipt projection")
    func snapshotCarriesIntegrityProjection() async throws {
        let admission = try await BindingFixture.admission()

        let session = try BoundAnalysisSession.snapshot(
            accepting: BindingFixture.asset(),
            of: admission.bundle,
            under: admission
        )
        let integrity = session.binding.modelBundleIntegrity

        #expect(session.integrityStatus == .verified)
        #expect(integrity == admission.bundle.integrity)
        #expect(integrity.verifiedArtifactDigests == admission.bundle.integrity.verifiedArtifactDigests)
        #expect(!integrity.verifiedArtifactDigests.isEmpty)
    }

    @Test("The bound scope states every required Version 1 coverage limit")
    func boundScopeStatesTheFixedLimits() async throws {
        let admission = try await BindingFixture.admission()

        let session = try BoundAnalysisSession.snapshot(
            accepting: BindingFixture.asset(),
            of: admission.bundle,
            under: admission
        )

        #expect(
            EvidenceScope.requiredIncludedStatements
                .isSubset(of: session.scope.includedStatements)
        )
        #expect(
            EvidenceScope.requiredExcludedStatements
                .isSubset(of: session.scope.excludedStatements)
        )
    }

    @Test("A pixel-only composition binds no Provenance Policy and no fusion rule")
    func pixelOnlyBindsNoConditionalArtifact() async throws {
        let admission = try await BindingFixture.admission()

        let session = try BoundAnalysisSession.snapshot(
            accepting: BindingFixture.asset(),
            of: admission.bundle,
            under: admission
        )

        #expect(session.provenancePolicy == nil)
        #expect(session.fusionRule == nil)
        #expect(session.binding.provenancePolicyID == nil)
        #expect(session.binding.fusionRuleID == nil)
        #expect(!session.enablesProvenance)
        #expect(!session.enablesFusion)
    }

    @Test("A provenance-enabled composition binds both conditional artifact versions")
    func provenanceCompositionBindsBothConditionalArtifacts() async throws {
        let admission = try await BindingFixture.admission(provenance: true, fusion: true)

        let session = try BoundAnalysisSession.snapshot(
            accepting: BindingFixture.asset(),
            of: admission.bundle,
            under: admission
        )

        #expect(session.provenancePolicy == admission.configuration.provenancePolicy)
        #expect(session.fusionRule == admission.configuration.fusionRule)
        #expect(session.binding.provenancePolicyID == Sample.artifact("policy.provenance"))
        #expect(session.binding.fusionRuleID == Sample.artifact("rule.fusion"))
        #expect(session.enablesProvenance)
        #expect(session.enablesFusion)
    }
}

// MARK: - Immutability

@Suite("A bound session cannot be changed by a later activation")
struct SessionBindingImmutabilityTests {

    @Test("Activating another bundle version leaves the bound snapshot alone")
    func laterActivationDoesNotChangeABoundSession() async throws {
        let admission = try await BindingFixture.admission()
        let first = try BindingFixture.reactivated(1)
        let second = try BindingFixture.reactivated(2)
        let (binder, bundles) = BindingFixture.binder(admission: admission, active: first)

        let bound = try await binder.bind(accepting: BindingFixture.asset())
        #expect(bound.activationGeneration == Sample.count(1))

        await bundles.makeActive(second)

        let observed = try #require(await binder.boundSession(PortValue.sessionID()))
        #expect(observed == bound)
        #expect(observed.activationGeneration == Sample.count(1))
        #expect(observed.binding.modelBundleIntegrity.activationReceiptID
            == Sample.artifact("receipt.activation.1"))
    }

    @Test("Rollback after acceptance leaves the bound snapshot alone")
    func rollbackDoesNotChangeABoundSession() async throws {
        let admission = try await BindingFixture.admission()
        let second = try BindingFixture.reactivated(2)
        let (binder, bundles) = BindingFixture.binder(admission: admission, active: second)

        let bound = try await binder.bind(accepting: BindingFixture.asset())

        // The port runs the identical path for a rollback, so what a session must survive
        // is the same either way: the active pointer moving underneath it.
        _ = try await bundles.rollback(to: second.bundleID, context: admission.context)
        await bundles.makeActive(try BindingFixture.reactivated(3))

        #expect(await binder.boundSession(PortValue.sessionID()) == bound)
    }

    @Test("Reading a bound session never re-reads the active pointer")
    func readingABoundSessionDoesNotConsultThePort() async throws {
        let admission = try await BindingFixture.admission()
        let (binder, bundles) = BindingFixture.binder(
            admission: admission,
            active: try BindingFixture.reactivated(1)
        )

        _ = try await binder.bind(accepting: BindingFixture.asset())
        let readsAfterBinding = await bundles.readCount

        for _ in 0..<4 {
            _ = await binder.boundSession(PortValue.sessionID())
        }

        // The mechanism, not just the outcome: a snapshot that is never re-derived cannot
        // observe an activation, whatever the port would report.
        #expect(await bundles.readCount == readsAfterBinding)
    }

    @Test("A second bind for the same session is refused and changes nothing")
    func rebindingIsRefused() async throws {
        let admission = try await BindingFixture.admission()
        let (binder, bundles) = BindingFixture.binder(
            admission: admission,
            active: try BindingFixture.reactivated(1)
        )
        let asset = BindingFixture.asset()
        let bound = try await binder.bind(accepting: asset)

        await bundles.makeActive(try BindingFixture.reactivated(2))

        await #expect(throws: SessionBindingRefusal.sessionAlreadyBound(asset.sessionID)) {
            try await binder.bind(accepting: asset)
        }
        #expect(await binder.boundSession(asset.sessionID) == bound)
        #expect(await binder.boundSessionCount == 1)
    }

    @Test("A refused rebind does not read the active pointer")
    func refusedRebindShortCircuitsThePort() async throws {
        let admission = try await BindingFixture.admission()
        let (binder, bundles) = BindingFixture.binder(
            admission: admission,
            active: admission.bundle
        )
        let asset = BindingFixture.asset()
        _ = try await binder.bind(accepting: asset)
        let reads = await bundles.readCount

        _ = try? await binder.bind(accepting: asset)

        #expect(await bundles.readCount == reads)
    }

    @Test("A different session binds whatever is active when its input is accepted")
    func aNewSessionBindsTheNewlyActiveBundle() async throws {
        let admission = try await BindingFixture.admission()
        let (binder, bundles) = BindingFixture.binder(
            admission: admission,
            active: try BindingFixture.reactivated(1)
        )
        let first = try await binder.bind(accepting: BindingFixture.asset("session-0001"))

        await bundles.makeActive(try BindingFixture.reactivated(2))
        let second = try await binder.bind(accepting: BindingFixture.asset("session-0002"))

        #expect(first.activationGeneration == Sample.count(1))
        #expect(second.activationGeneration == Sample.count(2))
        #expect(await binder.boundSession(PortValue.sessionID("session-0001")) == first)
        #expect(await binder.boundSessionIDs.count == 2)
    }

    @Test("Releasing a session forgets its binding, and is idempotent")
    func releaseIsIdempotent() async throws {
        let admission = try await BindingFixture.admission()
        let (binder, _) = BindingFixture.binder(admission: admission, active: admission.bundle)
        let asset = BindingFixture.asset()
        let bound = try await binder.bind(accepting: asset)

        #expect(await binder.release(asset.sessionID) == bound)
        #expect(await binder.release(asset.sessionID) == nil)
        #expect(await binder.boundSession(asset.sessionID) == nil)
        #expect(await binder.boundSessionCount == 0)
    }

    @Test("A released session identifier can be bound again")
    func releasedSessionCanBeReboundAfterRetry() async throws {
        let admission = try await BindingFixture.admission()
        let (binder, bundles) = BindingFixture.binder(
            admission: admission,
            active: try BindingFixture.reactivated(1)
        )
        let asset = BindingFixture.asset()
        _ = try await binder.bind(accepting: asset)
        await binder.release(asset.sessionID)

        await bundles.makeActive(try BindingFixture.reactivated(2))
        let rebound = try await binder.bind(accepting: asset)

        // Requirement 3.15: a retry is a fresh session with nothing carried over. The
        // identifier being reusable is what makes "nothing retained" checkable.
        #expect(rebound.activationGeneration == Sample.count(2))
    }
}

// MARK: - Traceability

@Suite("A report exposes exactly the bound identifiers")
struct SessionBindingTraceabilityTests {

    @Test("Report construction carries the snapshot's binding and scope unchanged")
    func reportExposesTheBoundSnapshot() async throws {
        let admission = try await BindingFixture.admission()
        let session = try BoundAnalysisSession.snapshot(
            accepting: BindingFixture.asset(),
            of: admission.bundle,
            under: admission
        )

        let report = try #require(
            EvidenceReport(
                binding: session.binding,
                pixel: .noStrongSignalDetected,
                provenance: .unavailable(.validatorNotCompiledIntoRelease),
                combinedSummary: nil,
                apparentInconsistency: nil,
                bytePreservationStatus: .unknown,
                inputQuality: SessionValue.quality(),
                onDeviceProcessing: true,
                scope: session.scope
            )
        )

        #expect(report.binding == session.binding)
        #expect(report.scope == session.scope)
        #expect(report.binding.modelBundleID == session.modelBundleID)
        #expect(report.binding.modelIdentity == session.modelIdentity)
        #expect(report.binding.modelBundleIntegrity.status == ModelBundleIntegrityStatus.verified)
        #expect(report.binding.coreMLModelVersion == admission.bundle.componentVersions.coreMLModel)
        #expect(
            report.binding.preprocessingContractID
                == admission.bundle.componentVersions.preprocessingContract
        )
        #expect(
            report.binding.calibrationPolicyID
                == admission.bundle.componentVersions.calibrationPolicy
        )
    }

    @Test("The bound policy values stop at the session and never reach the report")
    func policyValuesDoNotReachTheReport() async throws {
        let admission = try await BindingFixture.admission()
        let session = try BoundAnalysisSession.snapshot(
            accepting: BindingFixture.asset(),
            of: admission.bundle,
            under: admission
        )

        // The snapshot deliberately holds artifacts that carry approved decimals — a
        // false-accusation budget and measured resource limits — because the ports that
        // apply them take them as values.
        #expect(!ProhibitedMagnitudeAudit.findings(in: session.calibrationPolicy).isEmpty)

        // What crosses into a report is the identifier projection, so no approved release
        // magnitude becomes a user-facing field (Requirements 8.9 and 8.13).
        #expect(ProhibitedMagnitudeAudit.findings(in: session.binding).isEmpty)
        #expect(ProhibitedMagnitudeAudit.findings(in: session.scope).isEmpty)
    }

    @Test("A loaded model from the bound bundle is accepted")
    func boundModelIsAccepted() async throws {
        let admission = try await BindingFixture.admission()
        let session = try BoundAnalysisSession.snapshot(
            accepting: BindingFixture.asset(),
            of: admission.bundle,
            under: admission
        )
        let model = try #require(
            BoundCoreMLModel(
                bundleID: session.modelBundleID,
                modelIdentity: session.modelIdentity,
                coreMLModelVersion: session.binding.coreMLModelVersion,
                inputContract: try Sample.modelInput(),
                outputContract: try Sample.modelOutput(),
                model: LoadedModelToken(rawValue: 1)
            )
        )

        #expect(session.bindsLoadedModel(model))
        #expect(try session.requireBoundModel(model) == model)
    }

    @Test("A loaded model from another bundle version is refused")
    func unboundModelIsRefused() async throws {
        let admission = try await BindingFixture.admission()
        let session = try BoundAnalysisSession.snapshot(
            accepting: BindingFixture.asset(),
            of: admission.bundle,
            under: admission
        )
        let other = try #require(
            BoundCoreMLModel(
                bundleID: Sample.bundle("bundle.other"),
                modelIdentity: session.modelIdentity,
                coreMLModelVersion: session.binding.coreMLModelVersion,
                inputContract: try Sample.modelInput(),
                outputContract: try Sample.modelOutput(),
                model: LoadedModelToken(rawValue: 2)
            )
        )

        #expect(!session.bindsLoadedModel(other))
        #expect(throws: SessionBindingRefusal.loadedModelNotBoundToSession(
            expected: session.modelBundleID,
            found: Sample.bundle("bundle.other")
        )) {
            try session.requireBoundModel(other)
        }
    }

    @Test("A model whose Core ML component version differs is refused")
    func modelWithDifferentComponentVersionIsRefused() async throws {
        let admission = try await BindingFixture.admission()
        let session = try BoundAnalysisSession.snapshot(
            accepting: BindingFixture.asset(),
            of: admission.bundle,
            under: admission
        )
        let restamped = try #require(
            BoundCoreMLModel(
                bundleID: session.modelBundleID,
                modelIdentity: session.modelIdentity,
                coreMLModelVersion: Sample.artifact("component.coreml.next"),
                inputContract: try Sample.modelInput(),
                outputContract: try Sample.modelOutput(),
                model: LoadedModelToken(rawValue: 3)
            )
        )

        // Two activations can share a bundle identifier, so the identifier alone is not
        // enough: Requirement 4.12 makes the report state the Core ML component version.
        #expect(!session.bindsLoadedModel(restamped))
    }
}

// MARK: - Refusals

@Suite("Binding fails closed")
struct SessionBindingRefusalTests {

    @Test("A Share Extension admission binds no analysis session")
    func extensionAdmissionIsRefused() async throws {
        let admission = try await BindingFixture.admission(target: .shareExtension)

        #expect(throws: SessionBindingRefusal.bindingTargetNotMainApplication(.shareExtension)) {
            try BoundAnalysisSession.snapshot(
                accepting: BindingFixture.asset(),
                of: admission.bundle,
                under: admission
            )
        }
    }

    @Test("No active bundle is model-load-error, and nothing is bound")
    func absentActiveBundleIsRefused() async throws {
        let admission = try await BindingFixture.admission()
        let (binder, _) = BindingFixture.binder(admission: admission, active: nil)

        await #expect(
            throws: SessionBindingRefusal.activeBundleUnavailable(
                .analysis(.modelLoadError, stage: .modelLoad)
            )
        ) {
            try await binder.bind(accepting: BindingFixture.asset())
        }
        #expect(await binder.boundSessionCount == 0)
    }

    @Test("A cancelled read stays cancelled and is not reported as a model error")
    func cancellationIsForwardedUnchanged() async throws {
        let admission = try await BindingFixture.admission()
        let (binder, bundles) = BindingFixture.binder(
            admission: admission,
            active: admission.bundle
        )
        await bundles.fail(with: .cancelled)

        let refusal = await #expect(throws: SessionBindingRefusal.self) {
            try await binder.bind(accepting: BindingFixture.asset())
        }

        // Requirements 11.17 and 11.18: cancellation is a separate terminal outcome, so
        // collapsing it into `model-load-error` would present a cancelled session as a
        // failure category.
        #expect(refusal == .activeBundleUnavailable(.cancelled))
        #expect(refusal?.analysisFault == .cancelled)
        #expect(await binder.boundSessionCount == 0)
    }

    @Test("A bundle the capability manifest does not list is refused")
    func unapprovedBundleIsRefused() async throws {
        let admission = try await BindingFixture.admission()
        let unlisted = try PreflightSample.boundBundle(bundleID: "bundle.unlisted")

        #expect(
            throws: SessionBindingRefusal.activeBundleNotInApprovedCatalog(
                Sample.bundle("bundle.unlisted")
            )
        ) {
            try BoundAnalysisSession.snapshot(
                accepting: BindingFixture.asset(),
                of: unlisted,
                under: admission
            )
        }
    }

    @Test("A bundle the matched device evidence was not produced against is refused")
    func bundleOutsideTheValidatedTupleIsRefused() async throws {
        // Approved for the build, but the allowlist entry's physical-device gates ran
        // against `bundle.sample`, so binding this one would analyze under a version tuple
        // no device evidence covers.
        let scenario = try await PreflightSample.scenario(
            manifest: try PreflightSample.capabilityManifest(
                capabilities: [.pixelAnalysis],
                approvedBundleCatalog: ["bundle.sample", "bundle.second"]
            )
        )
        let admission = try await scenario.run()
        let second = try PreflightSample.boundBundle(bundleID: "bundle.second")

        #expect(
            throws: SessionBindingRefusal.activeBundleNotValidatedForConfiguration(
                configuration: admission.approvedConfiguration.id,
                expected: Sample.bundle("bundle.sample"),
                found: Sample.bundle("bundle.second")
            )
        ) {
            try BoundAnalysisSession.snapshot(
                accepting: BindingFixture.asset(),
                of: second,
                under: admission
            )
        }
    }

    @Test("A bundle incompatible with the running build is refused")
    func incompatibleBundleIsRefused() async throws {
        let admission = try await BindingFixture.admission()
        let incompatible = try PreflightSample.boundBundle(
            compatibleAppBuilds: ["build.other"]
        )

        #expect(
            throws: SessionBindingRefusal.activeBundleNotCompatible(Sample.bundle())
        ) {
            try BoundAnalysisSession.snapshot(
                accepting: BindingFixture.asset(),
                of: incompatible,
                under: admission
            )
        }
    }

    @Test(
        "A component version outside the bound policy set is refused",
        arguments: [
            (
                "boundBundle.componentVersions.preprocessingContract",
                "contract.preprocessing",
                "contract.other"
            ),
            (
                "boundBundle.componentVersions.calibrationPolicy",
                "policy.calibration",
                "policy.other"
            ),
            (
                "boundBundle.componentVersions.verdictCopyCompatibility",
                "copy.compatibility",
                "copy.other"
            ),
        ]
    )
    func mismatchedComponentVersionIsRefused(
        field: String,
        expected: String,
        found: String
    ) async throws {
        let admission = try await BindingFixture.admission()
        let restamped = try PreflightSample.boundBundle(
            componentVersions: PreflightSample.componentVersions(
                preprocessingContract: expected == "contract.preprocessing"
                    ? found
                    : "contract.preprocessing",
                calibrationPolicy: expected == "policy.calibration" ? found : "policy.calibration",
                verdictCopyCompatibility: expected == "copy.compatibility"
                    ? found
                    : "copy.compatibility"
            )
        )

        #expect(
            throws: SessionBindingRefusal.componentVersionNotBound(
                field: field,
                expected: expected,
                found: found
            )
        ) {
            try BoundAnalysisSession.snapshot(
                accepting: BindingFixture.asset(),
                of: restamped,
                under: admission
            )
        }
    }

    @Test("Binding stops at the structural session ceiling")
    func ceilingIsEnforced() async throws {
        let admission = try await BindingFixture.admission()
        let (binder, _) = BindingFixture.binder(
            admission: admission,
            active: admission.bundle,
            ceiling: 2
        )

        _ = try await binder.bind(accepting: BindingFixture.asset("session-0001"))
        _ = try await binder.bind(accepting: BindingFixture.asset("session-0002"))

        await #expect(throws: SessionBindingRefusal.boundSessionCeilingReached(ceiling: 2)) {
            try await binder.bind(accepting: BindingFixture.asset("session-0003"))
        }
        #expect(await binder.boundSessionCount == 2)

        await binder.release(PortValue.sessionID("session-0001"))
        _ = try await binder.bind(accepting: BindingFixture.asset("session-0003"))
        #expect(await binder.boundSessionCount == 2)
    }

    @Test("A nonpositive ceiling still admits one session")
    func ceilingIsClampedToOne() async throws {
        let admission = try await BindingFixture.admission()
        let (binder, _) = BindingFixture.binder(
            admission: admission,
            active: admission.bundle,
            ceiling: 0
        )

        _ = try await binder.bind(accepting: BindingFixture.asset("session-0001"))

        await #expect(throws: SessionBindingRefusal.boundSessionCeilingReached(ceiling: 1)) {
            try await binder.bind(accepting: BindingFixture.asset("session-0002"))
        }
    }

    @Test("Every bundle refusal a session sees is model-load-error at the model-load stage")
    func bundleRefusalsMapToOneCategory() {
        let refusals: [SessionBindingRefusal] = [
            .bindingTargetNotMainApplication(.shareExtension),
            .sessionAlreadyBound(PortValue.sessionID()),
            .boundSessionCeilingReached(ceiling: 8),
            .activeBundleNotInApprovedCatalog(Sample.bundle()),
            .activeBundleNotValidatedForConfiguration(
                configuration: Sample.configuration(),
                expected: Sample.bundle(),
                found: Sample.bundle("bundle.other")
            ),
            .activeBundleNotCompatible(Sample.bundle()),
            .activeBundleIntegrityNotVerified(Sample.bundle()),
            .componentVersionNotBound(field: "f", expected: "a", found: "b"),
            .loadedModelNotBoundToSession(
                expected: Sample.bundle(),
                found: Sample.bundle("bundle.other")
            ),
        ]

        for refusal in refusals {
            #expect(
                refusal.analysisFault == .analysis(.modelLoadError, stage: .modelLoad),
                "\(refusal) must present as model-load-error (Requirement 10.16)"
            )
            #expect(!refusal.description.isEmpty)
        }
    }

    @Test("An unavailable-bundle refusal forwards the port's own fault")
    func unavailableRefusalForwardsThePortFault() {
        let faults: [AnalysisFault] = [
            .cancelled,
            .analysis(.modelLoadError, stage: .modelLoad),
        ]

        for fault in faults {
            #expect(SessionBindingRefusal.activeBundleUnavailable(fault).analysisFault == fault)
        }
    }
}
