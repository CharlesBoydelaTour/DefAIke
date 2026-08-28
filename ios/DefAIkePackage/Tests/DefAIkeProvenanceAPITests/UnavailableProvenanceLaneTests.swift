import Testing

@testable import DefAIkeDomain
@testable import DefAIkeProvenanceAPI

/// The unavailable provenance lane: an analyzer that is never invoked, no inspection
/// described, and no Combined Summary.
///
/// These are the four coupled statements of Requirements 6.3, 6.4, 6.19, 6.20, and 7.10.
/// Each test below fixes one of them, and the negative cases are the interesting ones:
/// linking a validator is not approval to use it, so a manifest that does not enable the
/// capability, does not name this policy, does not record this implementation version, or
/// carries a rejected feasibility decision all resolve to the unavailable lane.
///
/// The lane carries *which* link in the chain was missing, and there are three: the module
/// graph, the signed manifest, and the approved decision that supplies an analyzer. The
/// shipping application composition links the reviewed adapter, so a build reporting
/// `validatorNotCompiledIntoRelease` is no longer the common case — it is a claim about a
/// module graph, and this suite keeps all three answers pinned to the condition that
/// actually produces each one.
@Suite("Unavailable provenance lane")
struct UnavailableProvenanceLaneTests {
    // MARK: Each unavailable composition, and the reason it reports

    @Test("A composition that links no validator reports the module-graph reason")
    func validatorNotLinkedLaneReason() async {
        let provider = ProvenanceLaneProvider.validatorNotLinked

        #expect(provider.isEnabled == false)
        #expect(provider.unavailableReason == .validatorNotCompiledIntoRelease)
        #expect(provider.boundPolicyID == nil)
        #expect(provider.canProduceCombinedSummary == false)

        let lane = await provider.lane(for: Sample.asset())
        #expect(lane == .unavailable(.validatorNotCompiledIntoRelease))
        #expect(lane.isAvailable == false)
        #expect(lane.evidence == nil)
        #expect(lane.category == nil)
    }

    @Test("A linked, enabled validator with no analyzer reports the enablement reason")
    func enablementUnapprovedLaneReason() async {
        let provider = ProvenanceLaneProvider.enablementUnapproved

        #expect(provider.isEnabled == false)
        #expect(provider.unavailableReason == .validatorEnablementUnapproved)
        #expect(provider.boundPolicyID == nil)
        #expect(provider.canProduceCombinedSummary == false)

        let lane = await provider.lane(for: Sample.asset())
        #expect(lane == .unavailable(.validatorEnablementUnapproved))
        #expect(lane.isAvailable == false)
        #expect(lane.evidence == nil)
        #expect(lane.category == nil)
    }

    @Test("An unavailable lane describes no inspection")
    func unavailableLaneHasNoInspectionRequest() {
        // Every unavailable provider, not a chosen one: an inspection request that appeared
        // for one reason and not another would be a validator pointed at bytes on a path
        // Requirement 6.19 says is inactive.
        for provider in [
            ProvenanceLaneProvider.validatorNotLinked,
            ProvenanceLaneProvider.capabilityNotEnabled,
            ProvenanceLaneProvider.enablementUnapproved,
        ] {
            #expect(provider.inspectionRequest(for: Sample.asset()) == nil)
        }
    }

    @Test("An unavailable lane has no fusion input and no state key")
    func unavailableLaneBypassesFusion() {
        for reason in UnavailableReason.allCases {
            let lane = ProvenanceLane.unavailable(reason)
            #expect(lane.fusionInput == nil)
            #expect(lane.stateKey == nil)
        }
    }

    // MARK: Every unavailable report omits the Combined Summary

    @Test("An unavailable report is representable only without a Combined Summary")
    func unavailableReportOmitsCombinedSummary() async {
        // Quantified over all three reasons rather than pinned to one, because Requirement
        // 7.10 is about the lane being unavailable and says nothing about why.
        for reason in UnavailableReason.allCases {
            let lane = ProvenanceLane.unavailable(reason)

            let report = ReportSample.report(provenance: lane, combinedSummary: nil)
            #expect(report != nil, "\(reason.rawValue)")
            #expect(report?.combinedSummary == nil, "\(reason.rawValue)")
            #expect(report?.provenance == .unavailable(reason), "\(reason.rawValue)")
            #expect(report?.binding.provenancePolicyID == nil, "\(reason.rawValue)")

            // An unavailable lane bypasses fusion entirely, so a summary beside it is not a
            // value the domain will build.
            let fused = ReportSample.report(
                provenance: lane,
                combinedSummary: CombinedSummary(
                    copyKey: Sample.copyKey("copy.combined.sample"),
                    fusionRuleID: Sample.artifact("fusion.sample")
                )
            )
            #expect(fused == nil, "\(reason.rawValue)")

            // Nor can an unavailable lane be inconsistent with anything.
            let inconsistent = ReportSample.report(
                provenance: lane,
                combinedSummary: nil,
                apparentInconsistency: Sample.copyKey("copy.inconsistency.sample")
            )
            #expect(inconsistent == nil, "\(reason.rawValue)")
        }
    }

    // MARK: Resolution from what a build compiled and what its manifest says

    @Test("No linked validator outranks the manifest, whatever it enables")
    func nonLinkageOutranksTheManifest() {
        let policy = PolicySample.policy()

        let withoutManifestApproval = ProvenanceLaneProvider.resolve(
            linksValidator: false,
            analyzer: nil,
            policy: nil,
            manifest: ManifestSample.pixelOnly
        )
        #expect(withoutManifestApproval.unavailableReason == .validatorNotCompiledIntoRelease)

        // A signed manifest cannot enable a capability whose implementation is absent
        // from the binary, so the manifest does not get to change this answer.
        let withManifestApproval = ProvenanceLaneProvider.resolve(
            linksValidator: false,
            analyzer: nil,
            policy: policy,
            manifest: ManifestSample.provenanceEnabled(for: policy)
        )
        #expect(withManifestApproval.unavailableReason == .validatorNotCompiledIntoRelease)

        // Even handed an invocable analyzer. A build that reports no linkage while holding
        // one is incoherent, and the module-graph fact is the one that decides.
        let contradictory = ProvenanceLaneProvider.resolve(
            linksValidator: false,
            analyzer: RecordingProvenanceAnalyzer(),
            policy: policy,
            manifest: ManifestSample.provenanceEnabled(for: policy)
        )
        #expect(contradictory.unavailableReason == .validatorNotCompiledIntoRelease)
        #expect(contradictory.isEnabled == false)
    }

    @Test("A linked, enabled validator with no analyzer is the shipping app's own state")
    func linkedAndEnabledWithoutAnalyzerIsUnapprovedEnablement() async {
        // The exact configuration `CompiledCapabilityComposition` produces today: the
        // adapter is linked, the manifest enables the capability and binds the policy, and
        // `provenanceAnalyzer(store:policy:)` still returns `nil` because no approved
        // decision maps a Provenance Feasibility Gate finding onto one of the five states.
        let policy = PolicySample.policy()
        let provider = ProvenanceLaneProvider.resolve(
            linksValidator: true,
            analyzer: nil,
            policy: policy,
            manifest: ManifestSample.provenanceEnabled(for: policy)
        )

        #expect(provider.isEnabled == false)
        #expect(provider.unavailableReason == .validatorEnablementUnapproved)
        #expect(provider.boundPolicyID == nil)
        #expect(provider.canProduceCombinedSummary == false)

        let lane = await provider.lane(for: Sample.asset())
        #expect(lane == .unavailable(.validatorEnablementUnapproved))
    }

    @Test("A compiled analyzer the manifest does not enable is never invoked")
    func compiledButNotEnabledAnalyzerIsNotInvoked() async {
        let analyzer = RecordingProvenanceAnalyzer(returning: .absent)
        let provider = ProvenanceLaneProvider.resolve(
            linksValidator: true,
            analyzer: analyzer,
            policy: PolicySample.policy(),
            manifest: ManifestSample.pixelOnly
        )

        #expect(provider.isEnabled == false)
        #expect(provider.unavailableReason == .capabilityNotEnabledByReleaseCapabilityManifest)

        let lane = await provider.lane(for: Sample.asset())
        #expect(lane == .unavailable(.capabilityNotEnabledByReleaseCapabilityManifest))
        #expect(analyzer.callCount == 0)
        #expect(provider.canProduceCombinedSummary == false)
    }

    @Test("A manifest that enables provenance without a bound policy stays unavailable")
    func enabledManifestWithoutPolicyIsUnavailable() {
        let policy = PolicySample.policy()
        let provider = ProvenanceLaneProvider.resolve(
            linksValidator: true,
            analyzer: RecordingProvenanceAnalyzer(),
            policy: nil,
            manifest: ManifestSample.provenanceEnabled(for: policy)
        )
        #expect(provider.unavailableReason == .capabilityNotEnabledByReleaseCapabilityManifest)
    }

    @Test("A manifest bound to a different policy version stays unavailable")
    func mismatchedPolicyIdentifierIsUnavailable() {
        let approved = PolicySample.policy(id: "provenance.approved")
        let other = PolicySample.policy(id: "provenance.other")

        let provider = ProvenanceLaneProvider.resolve(
            linksValidator: true,
            analyzer: RecordingProvenanceAnalyzer(),
            policy: other,
            manifest: ManifestSample.provenanceEnabled(for: approved)
        )
        #expect(provider.unavailableReason == .capabilityNotEnabledByReleaseCapabilityManifest)
        #expect(provider.boundPolicyID == nil)
    }

    @Test("A manifest recording a different implementation version stays unavailable")
    func mismatchedImplementationVersionIsUnavailable() {
        let policy = PolicySample.policy(implementationVersion: "0.0.12")
        let manifest = ManifestSample.manifest(
            capabilities: [.pixelAnalysis, .contentCredentialValidation],
            provenancePolicy: policy.id,
            provenanceImplementationVersion: "0.0.13"
        )

        let provider = ProvenanceLaneProvider.resolve(
            linksValidator: true,
            analyzer: RecordingProvenanceAnalyzer(),
            policy: policy,
            manifest: manifest
        )
        #expect(provider.unavailableReason == .capabilityNotEnabledByReleaseCapabilityManifest)
    }

    @Test("A rejected Provenance Feasibility decision stays unavailable")
    func rejectedFeasibilityIsUnavailable() {
        let policy = PolicySample.policy(feasibility: .rejected)
        let provider = ProvenanceLaneProvider.resolve(
            linksValidator: true,
            analyzer: RecordingProvenanceAnalyzer(),
            policy: policy,
            manifest: ManifestSample.provenanceEnabled(for: policy)
        )
        #expect(provider.unavailableReason == .capabilityNotEnabledByReleaseCapabilityManifest)
    }

    // MARK: The enabled composition, for contrast

    @Test("A complete match enables the lane and inspects the retained bytes")
    func completeMatchEnablesTheLane() async {
        let policy = PolicySample.policy()
        let analyzer = RecordingProvenanceAnalyzer(returning: .absent)
        let provider = ProvenanceLaneProvider.resolve(
            linksValidator: true,
            analyzer: analyzer,
            policy: policy,
            manifest: ManifestSample.provenanceEnabled(for: policy)
        )

        #expect(provider.isEnabled)
        #expect(provider.unavailableReason == nil)
        #expect(provider.boundPolicyID == policy.id)
        #expect(provider.canProduceCombinedSummary)

        let asset = Sample.asset()
        let request = provider.inspectionRequest(for: asset)
        #expect(request?.policyID == policy.id)
        #expect(request?.storageKey == asset.handle.storageKey)
        #expect(request?.inspectsExactly(byteCount: asset.byteCount, sha256: asset.sha256) == true)

        let lane = await provider.lane(for: asset)
        #expect(lane == .available(.absent))
        #expect(lane.fusionInput == .absent)
        #expect(analyzer.inspectedSessions == [asset.sessionID])
    }
}
