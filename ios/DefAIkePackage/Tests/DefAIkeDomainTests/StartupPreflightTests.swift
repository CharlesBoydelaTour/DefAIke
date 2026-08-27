import DefAIkeTestSupport
import Foundation
import Testing

@testable import DefAIkeDomain

// Tests for the fail-closed startup gate.
//
// Two claims are worth more than the individual cases, and both need a coherent baseline
// to mean anything:
//
//   * exactness. A device is matched by its hardware identifier, operating-system
//     version, and application build, and by nothing else. A sibling iPhone that would
//     pass every gate is still not this iPhone, so it stays refused.
//   * no invention. A refusal never produces an allowlist entry, an approval, a policy
//     value, or an evidence result. Two reflection audits assert that over every failure,
//     because a doc comment cannot hold that line and a "we do not construct one" claim
//     is exactly the kind that rots.
//
// Coherent-device-allowlisting as a *property* over generated version tuples belongs to
// spec task 2.6. These are examples: one broken field at a time, each naming the finding
// an audit would see.

// MARK: - Compiled composition

@Suite("Compiled capability composition")
struct CompiledCapabilityCompositionTests {
    @Test("A build with no pixel analysis is not a runnable composition")
    func pixelAnalysisRequired() {
        #expect(
            PreflightSample.composition(capabilities: [.shareExtensionHandoff]) == nil
        )
        #expect(PreflightSample.composition(capabilities: [.pixelAnalysis]) != nil)
    }

    @Test("Each compiled capability declares exactly one implementation version")
    func versionCoverageIsExact() {
        let capabilities: Set<CapabilityID> = [.pixelAnalysis, .shareExtensionHandoff]
        // Missing one.
        #expect(
            PreflightSample.composition(
                capabilities: capabilities,
                implementationVersions: [
                    CapabilityImplementationEntry(
                        capability: .pixelAnalysis,
                        version: Sample.version()
                    )
                ]
            ) == nil
        )
        // Naming one twice.
        #expect(
            PreflightSample.composition(
                capabilities: [.pixelAnalysis],
                implementationVersions: [
                    CapabilityImplementationEntry(
                        capability: .pixelAnalysis,
                        version: Sample.version()
                    ),
                    CapabilityImplementationEntry(
                        capability: .pixelAnalysis,
                        version: Sample.version("2.0.0")
                    ),
                ]
            ) == nil
        )
        // Naming one that is not compiled.
        #expect(
            PreflightSample.composition(
                capabilities: [.pixelAnalysis],
                implementationVersions: PreflightSample.implementationVersions(
                    for: capabilities
                )
            ) == nil
        )
        #expect(PreflightSample.composition(capabilities: capabilities) != nil)
    }

    @Test("Linkage is recorded independently of the declared capability set")
    func linkageIsIndependentOfDeclaration() throws {
        // Both disagreements have to be representable, or the gate in step 6 would have
        // nothing to refuse.
        let pixelOnlyWithValidator = try #require(
            PreflightSample.composition(capabilities: [.pixelAnalysis], linksValidator: true)
        )
        #expect(!pixelOnlyWithValidator.compilesProvenance)
        #expect(pixelOnlyWithValidator.linksContentCredentialValidator)

        let provenanceWithoutValidator = try #require(
            PreflightSample.composition(
                capabilities: [.pixelAnalysis, .contentCredentialValidation],
                linksValidator: false
            )
        )
        #expect(provenanceWithoutValidator.compilesProvenance)
        #expect(!provenanceWithoutValidator.linksContentCredentialValidator)
    }
}

// MARK: - Admission

@Suite("Startup preflight admission")
struct StartupPreflightAdmissionTests {
    @Test("A coherent pixel-only release is admitted with provenance unavailable")
    func coherentPixelOnly() async throws {
        let scenario = try await PreflightSample.scenario()
        let admission = try await scenario.run()

        #expect(admission.context.device == PreflightSample.device())
        #expect(admission.context.approvedConfiguration == Sample.configuration())
        #expect(admission.context.capabilityManifestID == scenario.manifest.id)
        #expect(admission.context.compiledCapabilities == [.pixelAnalysis])
        #expect(admission.bundle.bundleID == Sample.bundle())
        #expect(admission.target == .mainApplication)
        #expect(!admission.enablesProvenance)
        #expect(!admission.enablesFusion)
        #expect(admission.configuration.provenancePolicy == nil)
        #expect(admission.boundFixtureSuite == Sample.artifact("suite.fixtures"))
        #expect(admission.boundValidationPlan == Sample.artifact("plan.device-validation"))
    }

    @Test("A coherent provenance and fusion release is admitted with both enabled")
    func coherentProvenanceAndFusion() async throws {
        let scenario = try await PreflightSample.scenario(provenance: true, fusion: true)
        let admission = try await scenario.run()

        #expect(admission.enablesProvenance)
        #expect(admission.enablesFusion)
        #expect(
            admission.context.compiledCapabilities
                == [.pixelAnalysis, .contentCredentialValidation, .evidenceFusion]
        )
    }

    @Test("Startup cleanup runs before admission and reports under the bound policy")
    func cleanupRunsBeforeAdmission() async throws {
        let abandoned = try #require(AnalysisSessionID("session.abandoned"))
        let scenario = try await PreflightSample.scenario(abandonedSessions: [abandoned])
        #expect(await !scenario.ephemeral.occupiedScopes().isEmpty)

        let admission = try await scenario.run()

        #expect(scenario.recorder.didCall(PortCall.deleteAbandonedData))
        #expect(await scenario.ephemeral.occupiedScopes().isEmpty)
        let receipt = try #require(admission.startupCleanup.first)
        #expect(receipt.sessionID == abandoned)
        #expect(receipt.reason == .abandoned)
        #expect(receipt.lifecyclePolicyID == Sample.artifact("policy.lifecycle"))
        #expect(receipt.deadline == Sample.duration())
        #expect(receipt.removedObjectCount == 1)
    }

    @Test("Nothing abandoned is still a completed cleanup, not a skipped one")
    func emptyCleanupIsSuccess() async throws {
        let admission = try await PreflightSample.scenario().run()
        #expect(admission.startupCleanup.isEmpty)
    }

    @Test("The bound target selects that target's Resource Budget")
    func targetSelectsBudget() async throws {
        let scenario = try await PreflightSample.scenario(target: .shareExtension)
        let admission = try await scenario.run()
        #expect(admission.target == .shareExtension)
        #expect(
            admission.configuration.resourceBudgets.budget(for: .shareExtension).id
                == Sample.artifact("budget.share-extension")
        )
    }
}

// MARK: - Exact device matching

@Suite("Startup preflight device matching")
struct StartupPreflightDeviceMatchingTests {
    @Test("An operating system below iOS 17 is refused before anything is matched")
    func belowMinimumOS() async throws {
        let scenario = try await PreflightSample.scenario(
            device: PreflightSample.device(osVersion: Sample.platform("16.7.0"))
        )
        await expectFailure(scenario) { failure in
            guard case let .identityMismatch(field, _, found) = failure else { return false }
            return field == "device.osVersion" && found == "16.7.0"
        }
    }

    @Test("An unlisted hardware identifier is refused even when a sibling passes")
    func hardwareIdentifierIsExact() async throws {
        // The listed entry passes every mandatory gate. Matching by family, marketing
        // name, or "close enough" would admit this device; matching the exact identifier
        // does not (Requirements 1.3 and 13.1).
        let scenario = try await PreflightSample.scenario(
            device: PreflightSample.device(hardware: PreflightSample.unlistedHardware)
        )
        await expectFailure(scenario) { failure in
            guard case let .deviceNotAllowlisted(hardware, _, _) = failure else { return false }
            return hardware == Sample.hardware(PreflightSample.unlistedHardware)
        }
    }

    @Test("A listed device on an unlisted iOS version is refused")
    func osVersionIsExact() async throws {
        let scenario = try await PreflightSample.scenario(
            device: PreflightSample.device(osVersion: Sample.platform("17.4.0"))
        )
        await expectFailure(scenario) { failure in
            guard case let .deviceNotAllowlisted(_, osVersion, _) = failure else { return false }
            return osVersion == Sample.platform("17.4.0")
        }
    }

    @Test("A listed device running an unlisted build is refused")
    func appBuildIsExact() async throws {
        // Caught one step before the allowlist: the embedded manifest describes a build
        // that is not the one running, so nothing it says applies to this binary. The
        // finding names the artifact, because the running build is the fact and the
        // manifest is the thing that can be wrong.
        let scenario = try await PreflightSample.scenario(
            device: PreflightSample.device(appBuild: "build.other")
        )
        await expectFailure(scenario) { failure in
            failure == .identityMismatch(
                field: "capabilityManifest.appBuild",
                expected: "build.other",
                found: "build.sample"
            )
        }
    }

    @Test("An entry with one failing mandatory gate is not approval")
    func failingGateBlocks() async throws {
        let scenario = try await PreflightSample.scenario(
            allowlist: PreflightSample.allowlist(
                entries: [
                    PreflightSample.entry(
                        capabilities: [.pixelAnalysis],
                        failing: [.rawLogitParity]
                    )
                ]
            )
        )
        await expectFailure(scenario) { failure in
            // Requirement 13.22 fires first here, because the only entry is not
            // distributable, which is the more accurate finding.
            guard case let .allowlistApprovesNoConfiguration(allowlist) = failure else {
                return false
            }
            return allowlist == Sample.artifact("allowlist.devices")
        }
    }

    @Test("A failing gate on this device is named when another entry is distributable")
    func failingGateOnMatchedEntry() async throws {
        let scenario = try await PreflightSample.scenario(
            allowlist: PreflightSample.allowlist(
                entries: [
                    PreflightSample.entry(
                        identifier: "configuration.other",
                        capabilities: [.pixelAnalysis],
                        hardware: PreflightSample.unlistedHardware
                    ),
                    PreflightSample.entry(
                        capabilities: [.pixelAnalysis],
                        failing: [.interruptionCleanup]
                    ),
                ]
            )
        )
        await expectFailure(scenario) { failure in
            guard case let .unsatisfiedDeviceGates(configuration, gates) = failure else {
                return false
            }
            return configuration == Sample.configuration() && gates == [.interruptionCleanup]
        }
    }

    @Test("An empty allowlist blocks distribution rather than admitting anything")
    func emptyAllowlistBlocks() async throws {
        let scenario = try await PreflightSample.scenario(
            allowlist: PreflightSample.allowlist(entries: [])
        )
        await expectFailure(scenario) { failure in
            guard case .allowlistApprovesNoConfiguration = failure else { return false }
            return true
        }
    }

    @Test("Entries for one manifest cannot mix fixture suite or plan versions")
    func mixedEvidenceVersionsBlock() async throws {
        for (field, suite, plan) in [
            ("deviceAllowlist.entries.versionTuple.fixtureSuite", "suite.other", nil as String?),
            ("deviceAllowlist.entries.versionTuple.validationPlan", nil as String?, "plan.other"),
        ] as [(String, String?, String?)] {
            let scenario = try await PreflightSample.scenario(
                allowlist: PreflightSample.allowlist(
                    entries: [
                        PreflightSample.entry(capabilities: [.pixelAnalysis]),
                        PreflightSample.entry(
                            identifier: "configuration.other",
                            capabilities: [.pixelAnalysis],
                            hardware: PreflightSample.unlistedHardware,
                            fixtureSuite: suite ?? "suite.fixtures",
                            validationPlan: plan ?? "plan.device-validation"
                        ),
                    ]
                )
            )
            await expectFailure(scenario) { failure in
                guard case let .mixedAllowlistVersions(reported, _) = failure else { return false }
                return reported == field
            }
        }
    }

    @Test("An entry bound to another capability manifest cannot admit this build")
    func entryMustNameThisManifest() async throws {
        let scenario = try await PreflightSample.scenario(
            allowlist: PreflightSample.allowlist(
                entries: [
                    PreflightSample.entry(
                        capabilities: [.pixelAnalysis],
                        capabilityManifest: "manifest.other"
                    )
                ]
            )
        )
        await expectFailure(scenario) { failure in
            guard case let .identityMismatch(field, _, found) = failure else { return false }
            return field == "allowlistEntry.versionTuple.capabilityManifest"
                && found == "manifest.other"
        }
    }

    @Test("An entry whose Model Bundle the manifest does not approve is refused")
    func entryBundleMustBeApproved() async throws {
        let scenario = try await PreflightSample.scenario(
            allowlist: PreflightSample.allowlist(
                entries: [
                    PreflightSample.entry(
                        capabilities: [.pixelAnalysis],
                        modelBundle: "bundle.other"
                    )
                ]
            )
        )
        await expectFailure(scenario) { failure in
            guard case let .identityMismatch(field, _, found) = failure else { return false }
            return field == "allowlistEntry.versionTuple.modelBundle" && found == "bundle.other"
        }
    }

    @Test("An entry validated under another Device Validation Plan is refused")
    func entryPlanMustMatchBudgets() async throws {
        let scenario = try await PreflightSample.scenario(
            allowlist: PreflightSample.allowlist(
                entries: [
                    PreflightSample.entry(
                        capabilities: [.pixelAnalysis],
                        validationPlan: "plan.other"
                    )
                ]
            )
        )
        await expectFailure(scenario) { failure in
            guard case let .identityMismatch(field, expected, _) = failure else { return false }
            return field == "resourceBudgets.mainApplication.validationPlan"
                && expected == "plan.other"
        }
    }

    @Test("Gate evidence produced under another capability set cannot admit this build")
    func entryCapabilitiesMustMatch() async throws {
        // The manifest and the module graph are pixel-only; the entry's evidence was
        // recorded with the handoff capability enabled (Requirement 13.20).
        let scenario = try await PreflightSample.scenario(
            allowlist: PreflightSample.allowlist(
                entries: [
                    PreflightSample.entry(
                        capabilities: [.pixelAnalysis, .shareExtensionHandoff]
                    )
                ]
            )
        )
        await expectFailure(scenario) { failure in
            guard case let .capabilitySetMismatch(_, compiled) = failure else { return false }
            return compiled.sorted() == ["pixel-analysis", "share-extension-handoff"]
        }
    }

    @Test("Gate evidence recorded at another implementation version is refused")
    func entryImplementationVersionsMustMatch() async throws {
        let scenario = try await PreflightSample.scenario(
            allowlist: PreflightSample.allowlist(
                entries: [
                    PreflightSample.entry(
                        capabilities: [.pixelAnalysis],
                        implementationVersions: [
                            CapabilityImplementationEntry(
                                capability: .pixelAnalysis,
                                version: Sample.version("2.0.0")
                            )
                        ]
                    )
                ]
            )
        )
        await expectFailure(scenario) { failure in
            guard case let .capabilitySetMismatch(_, compiled) = failure else { return false }
            return compiled == ["pixel-analysis@2.0.0"]
        }
    }
}

// MARK: - Capability composition against the manifest

@Suite("Startup preflight capability composition")
struct StartupPreflightCompositionTests {
    @Test("A pixel-only manifest that can instantiate a validator fails")
    func pixelOnlyWithLinkedValidator() async throws {
        // Requirement 6.3 and 6.19: the pixel-only archive must not contain the
        // validator at all, so a graph that can instantiate one is a build that shipped
        // code it may never run.
        let scenario = try await PreflightSample.scenario(
            composition: PreflightSample.composition(
                capabilities: [.pixelAnalysis],
                linksValidator: true
            )
        )
        await expectFailure(scenario) { failure in
            failure == .provenanceLinkageMismatch(
                manifestEnablesProvenance: false,
                linksValidator: true
            )
        }
    }

    @Test("A provenance-enabled manifest with no linked validator fails")
    func provenanceManifestWithoutValidator() async throws {
        let scenario = try await PreflightSample.scenario(
            provenance: true,
            composition: PreflightSample.composition(
                identifier: "pixel-plus-provenance",
                capabilities: [.pixelAnalysis, .contentCredentialValidation],
                linksValidator: false
            )
        )
        await expectFailure(scenario) { failure in
            failure == .provenanceLinkageMismatch(
                manifestEnablesProvenance: true,
                linksValidator: false
            )
        }
    }

    @Test("An extra compiled capability is as wrong as a missing one")
    func compiledSetMustEqualApprovedSet() async throws {
        let scenario = try await PreflightSample.scenario(
            composition: PreflightSample.composition(
                capabilities: [.pixelAnalysis, .shareExtensionHandoff]
            )
        )
        await expectFailure(scenario) { failure in
            guard case let .capabilitySetMismatch(approved, compiled) = failure else {
                return false
            }
            return approved == ["pixel-analysis"]
                && compiled.sorted() == ["pixel-analysis", "share-extension-handoff"]
        }
    }

    @Test("A compiled implementation version the manifest does not approve fails")
    func compiledVersionMustMatch() async throws {
        let scenario = try await PreflightSample.scenario(
            composition: PreflightSample.composition(
                capabilities: [.pixelAnalysis],
                implementationVersions: [
                    CapabilityImplementationEntry(
                        capability: .pixelAnalysis,
                        version: Sample.version("1.0.1")
                    )
                ]
            )
        )
        await expectFailure(scenario) { failure in
            guard case let .capabilitySetMismatch(approved, compiled) = failure else {
                return false
            }
            return approved == ["pixel-analysis@1.0.0"] && compiled == ["pixel-analysis@1.0.1"]
        }
    }

    @Test("A build whose composition identifier is not the manifest's fails")
    func compositionIdentifierMustMatch() async throws {
        let scenario = try await PreflightSample.scenario(
            composition: PreflightSample.composition(
                identifier: "pixel-plus-provenance",
                capabilities: [.pixelAnalysis]
            )
        )
        await expectFailure(scenario) { failure in
            guard case let .identityMismatch(field, expected, found) = failure else {
                return false
            }
            return field == "capabilityManifest.compositionIdentifier"
                && expected == "pixel-plus-provenance"
                && found == "pixel-only"
        }
    }

    @Test("A rejected Provenance Feasibility decision blocks the capability")
    func rejectedFeasibilityBlocks() async throws {
        let scenario = try await PreflightSample.scenario(
            provenance: true,
            provenanceFeasibility: .rejected
        )
        await expectFailure(scenario) { failure in
            failure == .unapprovedArtifact(
                field: "provenancePolicy.feasibilityApproval",
                decision: .rejected
            )
        }
    }
}

// MARK: - Model Bundle and policy binding

@Suite("Startup preflight bundle binding")
struct StartupPreflightBundleTests {
    @Test("With no active bundle the embedded one is verified and activated")
    func embeddedBundleIsActivated() async throws {
        let scenario = try await PreflightSample.scenario(activateBundle: false)
        #expect(await scenario.bundles.activeBundle() == nil)

        let admission = try await scenario.run()

        #expect(scenario.recorder.didCall(.activateLocalCandidate(Sample.bundle())))
        #expect(admission.bundle.bundleID == Sample.bundle())
        #expect(await scenario.bundles.activeBundle()?.bundleID == Sample.bundle())
    }

    @Test("An embedded bundle the manifest does not approve is refused unactivated")
    func embeddedBundleMustBeApproved() async throws {
        let other = try PreflightSample.boundBundle(bundleID: "bundle.other")
        let scenario = try await PreflightSample.scenario(
            bundle: other,
            activateBundle: false,
            embeddedBundle: "bundle.other"
        )
        await expectFailure(scenario) { failure in
            guard case let .identityMismatch(field, _, found) = failure else { return false }
            return field == "preflight.embeddedBundle" && found == "bundle.other"
        }
        // Refused before activation was attempted, so nothing became active.
        #expect(!scenario.recorder.didCall(.activateLocalCandidate(Sample.bundle("bundle.other"))))
        #expect(await scenario.bundles.activeBundle() == nil)
    }

    @Test("An unactivatable embedded bundle blocks ingest with no analysis error")
    func unactivatableBundleBlocks() async throws {
        let scenario = try await PreflightSample.scenario(activateBundle: false)
        await scenario.bundles.failActivation(of: Sample.bundle(), at: .selfTests)
        await expectFailure(scenario) { failure in
            failure == .verifiedBundleUnavailable(expected: Sample.bundle())
        }
        #expect(await scenario.bundles.activeBundle() == nil)
    }

    @Test("An active bundle incompatible with this build is not admitted")
    func incompatibleBundleBlocks() async throws {
        let incompatible = try PreflightSample.boundBundle(
            compatibleAppBuilds: ["build.other"]
        )
        let scenario = try await PreflightSample.scenario(bundle: incompatible)
        await expectFailure(scenario) { failure in
            failure == .verifiedBundleUnavailable(expected: Sample.bundle())
        }
    }

    @Test("A bundle requiring a capability this build does not compile is not admitted")
    func bundleRequiredCapabilitiesRespected() async throws {
        let demanding = try PreflightSample.boundBundle(
            requiredCapabilities: [.pixelAnalysis, .contentCredentialValidation]
        )
        let scenario = try await PreflightSample.scenario(bundle: demanding)
        await expectFailure(scenario) { failure in
            failure == .verifiedBundleUnavailable(expected: Sample.bundle())
        }
    }

    @Test("An approved bundle that is not the validated one for this device is refused")
    func activeBundleMustBeTheValidatedOne() async throws {
        // Both bundles are in the manifest's approved catalogue, so "approved" is not the
        // question. The device's gate evidence was produced against one of them, and only
        // that one can admit this device (Requirement 13.17).
        let second = try PreflightSample.boundBundle(bundleID: "bundle.second")
        let scenario = try await PreflightSample.scenario(
            manifest: PreflightSample.capabilityManifest(
                capabilities: [.pixelAnalysis],
                approvedBundleCatalog: ["bundle.sample", "bundle.second"]
            ),
            bundle: second
        )
        await expectFailure(scenario) { failure in
            failure == .identityMismatch(
                field: "activeBundle.bundleID",
                expected: "bundle.sample",
                found: "bundle.second"
            )
        }
    }

    @Test("A bundle's component versions must be the policies this build is bound to")
    func componentVersionsMustAgreeWithPolicies() async throws {
        for (field, versions) in [
            (
                "activeBundle.componentVersions.preprocessingContract",
                PreflightSample.componentVersions(preprocessingContract: "contract.other")
            ),
            (
                "activeBundle.componentVersions.calibrationPolicy",
                PreflightSample.componentVersions(calibrationPolicy: "policy.other")
            ),
            (
                "activeBundle.componentVersions.verdictCopyCompatibility",
                PreflightSample.componentVersions(verdictCopyCompatibility: "copy.other")
            ),
        ] {
            let bundle = try PreflightSample.boundBundle(componentVersions: versions)
            let scenario = try await PreflightSample.scenario(bundle: bundle)
            await expectFailure(scenario) { failure in
                guard case let .identityMismatch(reported, _, _) = failure else { return false }
                return reported == field
            }
        }
    }
}

// MARK: - Approvals, cleanup, and absent artifacts

@Suite("Startup preflight fail-closed inputs")
struct StartupPreflightFailClosedTests {
    @Test("A rejected capability manifest approval blocks ingest")
    func rejectedManifestApproval() async throws {
        let scenario = try await PreflightSample.scenario(
            manifest: PreflightSample.capabilityManifest(
                capabilities: [.pixelAnalysis],
                approval: .rejected
            )
        )
        await expectFailure(scenario) { failure in
            failure == .unapprovedArtifact(
                field: "capabilityManifest.approval",
                decision: .rejected
            )
        }
    }

    @Test("A rejected allowlist approval blocks ingest")
    func rejectedAllowlistApproval() async throws {
        let scenario = try await PreflightSample.scenario(
            allowlist: PreflightSample.allowlist(
                entries: [PreflightSample.entry(capabilities: [.pixelAnalysis])],
                approval: .rejected
            )
        )
        await expectFailure(scenario) { failure in
            failure == .unapprovedArtifact(field: "deviceAllowlist.approval", decision: .rejected)
        }
    }

    @Test("A rejected Data Lifecycle Policy approval blocks ingest")
    func rejectedLifecycleApproval() async throws {
        let scenario = try await PreflightSample.scenario(
            lifecyclePolicy: PreflightSample.lifecyclePolicy(approval: .rejected)
        )
        await expectFailure(scenario) { failure in
            failure == .unapprovedArtifact(field: "lifecyclePolicy.approval", decision: .rejected)
        }
    }

    @Test("Failed startup cleanup blocks ingest instead of reporting an analysis error")
    func cleanupFailureBlocks() async throws {
        let abandoned = try #require(AnalysisSessionID("session.abandoned"))
        let scenario = try await PreflightSample.scenario(abandonedSessions: [abandoned])
        await scenario.ephemeral.failNextOperation(with: .storeUnavailable)

        await expectFailure(scenario) { failure in
            failure == .startupCleanupFailed(.storeUnavailable)
        }
        // The material is still there, which is exactly why ingest stays unavailable.
        #expect(await !scenario.ephemeral.occupiedScopes().isEmpty)
    }

    @Test("An absent required policy blocks ingest rather than being defaulted")
    func absentPolicyBlocks() async throws {
        for absent in [
            "policy.lifecycle",
            "budget.main-application",
            "budget.share-extension",
            "contract.preprocessing",
            "policy.calibration",
            "catalog.verdict-copy",
            "manifest.capability",
        ] {
            let scenario = try await PreflightSample.scenario()
            let identifier = Sample.artifact(absent)
            await scenario.policies.forgetPolicyArtifact(identifier)
            await expectFailure(scenario) { failure in
                failure == .artifactUnavailable(.notFound(identifier))
            }
        }
    }

    @Test("An absent device allowlist blocks ingest")
    func absentAllowlistBlocks() async throws {
        let scenario = try await PreflightSample.scenario()
        let identifier = Sample.artifact("allowlist.devices")
        await scenario.policies.forgetPolicyArtifact(identifier)
        await expectFailure(scenario) { failure in
            failure == .artifactUnavailable(.notFound(identifier))
        }
    }

    @Test("A failed gate produces no evidence result of any kind")
    func failuresProduceNoEvidence() async throws {
        // The composition disagrees with the manifest, which is step 6 — after the
        // bundle and cleanup steps have already run — so this is the latest a refusal
        // can happen and the case most likely to have something to report.
        let scenario = try await PreflightSample.scenario(
            composition: PreflightSample.composition(
                capabilities: [.pixelAnalysis],
                linksValidator: true
            )
        )
        let failure = try await capturedFailure(scenario)
        // A preflight failure is not a session outcome: no Analysis Error, no Evidence
        // Report, and nothing a Result Presenter could render as one.
        #expect(EvidenceReachabilityAudit.evidencePaths(in: failure).isEmpty)
    }

    @Test("A refusal never hands back an allowlist entry or an approved configuration")
    func failuresCarryNoDeviceConfiguration() async throws {
        // "We do not invent an unapproved device entry" has to be checkable. Every
        // failure is walked for a reachable candidate or approved configuration, a
        // version tuple, an approval record, or a bundle, because any of those coming
        // back from a refusal is a value a caller could mistake for an approved one.
        let scenarios: [PreflightScenario] = [
            try await PreflightSample.scenario(
                device: PreflightSample.device(hardware: PreflightSample.unlistedHardware)
            ),
            try await PreflightSample.scenario(
                allowlist: PreflightSample.allowlist(entries: [])
            ),
            try await PreflightSample.scenario(
                allowlist: PreflightSample.allowlist(
                    entries: [
                        PreflightSample.entry(
                            identifier: "configuration.other",
                            capabilities: [.pixelAnalysis],
                            hardware: PreflightSample.unlistedHardware
                        ),
                        PreflightSample.entry(
                            capabilities: [.pixelAnalysis],
                            failing: [.categoricalAgreement]
                        ),
                    ]
                )
            ),
            try await PreflightSample.scenario(
                composition: PreflightSample.composition(
                    capabilities: [.pixelAnalysis],
                    linksValidator: true
                )
            ),
            try await PreflightSample.scenario(activateBundle: false, embeddedBundle: "bundle.x"),
        ]
        for scenario in scenarios {
            let failure = try await capturedFailure(scenario)
            let forbidden: Set<String> = [
                "ApprovedDeviceConfiguration",
                "CandidateDeviceConfiguration",
                "ValidationVersionTuple",
                "ApprovalRecord",
                "BoundModelBundle",
                "ReleaseAdmission",
            ]
            var found: [String] = []
            DomainValueWalk.visit(failure, rootName: "failure") { path, value in
                let tokens = DomainValueWalk.typeNameTokens(of: type(of: value))
                if !tokens.isDisjoint(with: forbidden) { found.append(path) }
            }
            #expect(found.isEmpty, "\(failure) exposes \(found)")
        }
    }
}

// MARK: - Helpers

/// Runs a scenario and requires it to fail a gate matching `predicate`.
private func expectFailure(
    _ scenario: PreflightScenario,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ predicate: (PreflightFailure) -> Bool
) async {
    do {
        _ = try await scenario.run()
        Issue.record("expected the startup gate to refuse", sourceLocation: sourceLocation)
    } catch {
        #expect(predicate(error), "unexpected failure: \(error)", sourceLocation: sourceLocation)
    }
}

/// Raised when a scenario that was expected to be refused was admitted instead.
private struct UnexpectedAdmission: Error {}

/// The failure a scenario produces, for structural audits over it.
private func capturedFailure(
    _ scenario: PreflightScenario
) async throws -> PreflightFailure {
    do {
        _ = try await scenario.run()
    } catch {
        return error
    }
    throw UnexpectedAdmission()
}
