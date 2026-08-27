import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// Requirement 13.20 at the record level: one configuration, one exact version tuple.
//
// The four runner tasks each reconcile a version tuple against their own binding, and 14.9
// measured what that leaves open: `ParityRunBinding` reconciles the fixture suite, plan, bundle,
// manifest, and build and never touches `capabilityImplementationVersions`, so a tuple differing
// only in an implementation version binds. Below `CoherentDeviceEvidence` the clause holds only
// one observation at a time, through whole-tuple equality inside `QualifyingParityEvidence`.
//
// This suite is the record-level enforcement: one join point, checked once for the whole
// configuration, against the signed manifest.
//
// **No value here is an approved release value.** Every plan, tuple, manifest, configuration,
// and result reference is synthetic scaffolding built by `Sample`.

@Suite("Release record: version-tuple coherence")
struct ReleaseRecordCoherenceTests {

    // MARK: The coherent case

    @Test("Three runners on one plan, one configuration, and one tuple join")
    func coherentEvidenceJoins() throws {
        let evidence = try Sample.coherentDeviceEvidence()
        let plan = try Sample.joinedPlan()
        let tuple = try Sample.joinedTuple()
        #expect(evidence.versionTuple == tuple)
        #expect(evidence.configuration == plan.candidateConfigurations[0])
        #expect(evidence.parity.plan == plan.id)
        #expect(evidence.resources.mainApplication.plan == plan.id)
        #expect(evidence.matrix.plan == plan.id)
        // The join proves nothing passed. It is unsatisfiable here, on a host, and the reason
        // travels with the evidence.
        #expect(!evidence.isPassing)
        #expect(!evidence.runEnvironment.isPhysicalDeviceEvidence)
    }

    @Test("Every one of the 22 mandatory device gates is answered by exactly one runner")
    func everyMandatoryDeviceGateIsAnswered() throws {
        let evidence = try Sample.coherentDeviceEvidence()
        #expect(DeviceGate.mandatoryGates.count == 22)
        let parity = Set(DeviceGate.parityGates)
        let resource = Set(DeviceGate.resourceGates)
        let matrix = Set(DeviceGate.matrixGates)
        #expect(parity.union(resource).union(matrix) == DeviceGate.mandatoryGates)
        #expect(parity.intersection(resource).isEmpty)
        #expect(parity.intersection(matrix).isEmpty)
        #expect(resource.intersection(matrix).isEmpty)
        // And the join produces a real answer for each, never an absent one.
        var answered = 0
        for gate in DeviceGate.mandatoryGates {
            answered += 1
            let outcome = evidence.outcome(of: gate)
            let waived = !evidence.applicability(of: gate).isApplicable
            #expect(
                outcome != GateOutcome.notExecuted || waived,
                "\(gate.rawValue) produced no result and is not waived"
            )
        }
        #expect(answered == 22)
    }

    // MARK: The clause no binding layer checks

    @Test("A tuple differing only in a capability implementation version is refused")
    func implementationVersionDisagreementIsRefused() throws {
        // The manifest declares 1.0.0; the evidence ran under 2.0.0. Everything else — build,
        // bundle, suite, plan, manifest identity, capability set — agrees, which is exactly the
        // shape `ParityRunBinding` accepts.
        let drifted = try Sample.joinedTuple(implementationVersion: "2.0.0")
        let binding = try ParityRunBinding(
            plan: try Sample.joinedPlan(),
            catalog: try Sample.catalog(),
            configuration: try Sample.joinedPlan().candidateConfigurations[0],
            versionTuple: drifted
        )
        // The parity layer binds it, which is the defect 14.9 found stated as a fact here.
        #expect(binding.versionTuple.capabilityImplementationVersions.count == 1)

        var refusal: ReleaseRecordCoherenceError?
        do {
            _ = try Sample.coherentDeviceEvidence(versionTuple: drifted)
        } catch {
            refusal = error as? ReleaseRecordCoherenceError
        }
        let recorded = try #require(refusal)
        guard case let .capabilityImplementationVersionMismatch(capability, expected, found) =
            recorded
        else {
            Issue.record("an implementation-version drift must be refused as one")
            return
        }
        #expect(capability == CapabilityID.pixelAnalysis)
        #expect(expected.description == "1.0.0")
        #expect(found.description == "2.0.0")
    }

    @Test("A tuple naming an application build the manifest does not is refused")
    func appBuildDisagreementIsRefused() throws {
        // A plan, a configuration, and a tuple that all agree on one build, and a manifest that
        // names a different one. Every binding layer below accepts this: each compares the
        // configuration against the tuple and neither against the signed manifest.
        let otherBuild = AppBuildID("build.other")!
        let plan = try Sample.resourcePlan(appBuild: otherBuild)
        var refusal: ReleaseRecordCoherenceError?
        do {
            _ = try Sample.coherentDeviceEvidence(
                plan: plan,
                configuration: plan.candidateConfigurations[0],
                versionTuple: try Sample.joinedTuple(appBuild: otherBuild)
            )
        } catch {
            refusal = error as? ReleaseRecordCoherenceError
        }
        let recorded = try #require(refusal)
        guard case let .appBuildNotTheManifestBuild(expected, found) = recorded else {
            Issue.record("a build the manifest does not name must be refused as one")
            return
        }
        #expect(expected == Sample.appBuild())
        #expect(found == otherBuild)
    }

    @Test("Two runners reporting different tuples for one configuration are refused")
    func mixedTuplesAcrossRunnersAreRefused() throws {
        var refusal: ReleaseRecordCoherenceError?
        do {
            _ = try Sample.coherentDeviceEvidence(
                resourceVersionTuple: try Sample.joinedTuple(implementationVersion: "3.0.0")
            )
        } catch {
            refusal = error as? ReleaseRecordCoherenceError
        }
        let recorded = try #require(refusal)
        guard case let .versionTupleMixed(kind) = recorded else {
            Issue.record("two runners under two tuples must be refused as a mixed set")
            return
        }
        #expect(kind == ReleaseRecordEvidenceKind.device)
    }

    @Test("A matrix run under a different tuple is refused and named as the matrix")
    func mixedMatrixTupleIsRefused() throws {
        var refusal: ReleaseRecordCoherenceError?
        do {
            _ = try Sample.coherentDeviceEvidence(
                matrixVersionTuple: try Sample.joinedTuple(implementationVersion: "4.0.0")
            )
        } catch {
            refusal = error as? ReleaseRecordCoherenceError
        }
        let recorded = try #require(refusal)
        guard case let .versionTupleMixed(kind) = recorded else {
            Issue.record("the matrix half must be refused as a mixed set too")
            return
        }
        #expect(kind == ReleaseRecordEvidenceKind.accessibility)
    }

    @Test("A capability set the manifest does not compile is refused")
    func capabilitySetDisagreementIsRefused() throws {
        // The evidence ran with the provenance capability; the manifest is pixel-only.
        var refusal: ReleaseRecordCoherenceError?
        do {
            _ = try Sample.coherentDeviceEvidence(
                versionTuple: try Sample.joinedTuple(provenanceEnabled: true),
                capabilityManifest: try Sample.releaseManifest(provenanceEnabled: false),
                provenanceApplicable: true
            )
        } catch {
            refusal = error as? ReleaseRecordCoherenceError
        }
        let recorded = try #require(refusal)
        guard case let .capabilitySetMismatch(expected, found) = recorded else {
            Issue.record("a capability set the manifest does not compile must be refused")
            return
        }
        #expect(expected == ["pixel-analysis"])
        #expect(found == ["content-credential-validation", "pixel-analysis"])
    }

    @Test("A Model Bundle outside the approved catalogue is refused")
    func bundleOutsideCatalogIsRefused() throws {
        var refusal: ReleaseRecordCoherenceError?
        do {
            _ = try Sample.coherentDeviceEvidence(
                capabilityManifest: try Sample.releaseManifest(
                    approvedBundles: [ModelBundleID("bundle.other")!]
                )
            )
        } catch {
            refusal = error as? ReleaseRecordCoherenceError
        }
        let recorded = try #require(refusal)
        guard case let .modelBundleOutsideApprovedCatalog(bundle) = recorded else {
            Issue.record("a bundle outside the approved catalogue must be refused")
            return
        }
        #expect(bundle == Sample.bundle())
    }

    @Test("A capability manifest other than the signed one is refused")
    func capabilityManifestDisagreementIsRefused() throws {
        // Rebuilt at another identifier, which the plan and tuple do not name.
        let other = try ReleaseCapabilityManifest(
            id: Sample.artifact("manifest.other"),
            schemaVersion: .v1,
            appBuild: Sample.appBuild(),
            compositionIdentifier: Sample.text("sample-composition"),
            compiledCapabilities: [.pixelAnalysis],
            implementationVersions: [
                CapabilityImplementationEntry(
                    capability: .pixelAnalysis,
                    version: Sample.version()
                )
            ],
            approvedConfigurationAllowlist: Sample.artifact("allowlist.approved-configurations"),
            approvedBundleCatalog: [Sample.bundle()],
            policyCompatibility: try Sample.releaseManifest().policyCompatibility,
            approval: Sample.approval(identifier: "approval.capability-manifest")
        )
        var refusal: ReleaseRecordCoherenceError?
        do {
            _ = try Sample.coherentDeviceEvidence(capabilityManifest: other)
        } catch {
            refusal = error as? ReleaseRecordCoherenceError
        }
        let recorded = try #require(refusal)
        guard case let .capabilityManifestMismatch(expected, found) = recorded else {
            Issue.record("a manifest other than the signed one must be refused")
            return
        }
        #expect(expected == Sample.artifact("manifest.other"))
        #expect(found == Sample.artifact("manifest.capability"))
    }

    // MARK: Satisfaction is computed, never read from an entry

    @Test("A configuration whose every gate is declared inapplicable is not satisfied here")
    func waivedEverythingIsNotSatisfied() throws {
        // The shape `GateResultReference.isSatisfied` reports as fully satisfied: an entry whose
        // every mandatory gate carries an approved not-applicable decision, with nothing having
        // run anywhere. It constructs, and `unsatisfiedGates` on the entry reads empty.
        let plan = try Sample.joinedPlan()
        var references: [GateResultReference] = []
        for gate in DeviceGate.allCases {
            references.append(
                try GateResultReference(
                    gate: gate,
                    applicability: Sample.notApplicable(),
                    outcome: .notExecuted,
                    result: Sample.evidence("result.nothing"),
                    environment: .developmentMac
                )
            )
        }
        let entry = try ApprovedDeviceConfiguration(
            id: ApprovedConfigurationID("configuration.waived")!,
            configuration: plan.candidateConfigurations[0],
            versionTuple: try Sample.joinedTuple(),
            gateEvidence: references
        )
        #expect(entry.unsatisfiedGates.isEmpty, "the pinned defect: nothing ran and all satisfied")

        // `CoherentDeviceEvidence` computes satisfaction from the runners' cells instead, so the
        // same nothing-ran state reports 21 of the 22 as unsatisfied.
        //
        // Twenty-one rather than twenty-two, and the twenty-second is the point rather than a
        // shortfall: `provenance-fixtures` is the one conditional device gate, this release's
        // catalogued suite carries an approved decision that provenance does not apply
        // (Requirement 13.5), and an approved waiver on the one waivable gate is satisfaction.
        // The other twenty-one cannot be waived at all, and none of them is satisfied.
        let evidence = try Sample.coherentDeviceEvidence()
        #expect(evidence.unsatisfiedGates.count == 21)
        #expect(!evidence.unsatisfiedGates.contains(.provenanceFixtures))
        #expect(evidence.isSatisfied(.provenanceFixtures))
        #expect(!evidence.applicability(of: .provenanceFixtures).isApplicable)
        #expect(!evidence.isPassing)
    }
}
