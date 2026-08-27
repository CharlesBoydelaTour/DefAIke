import Testing

@testable import DefAIkeDomain
@testable import DefAIkeProvenanceAPI

/// The pixel-only composition: an unavailable provenance lane, an analyzer that is never
/// invoked, and no Combined Summary.
///
/// These are the four coupled statements of Requirements 6.3, 6.4, 6.19, 6.20, and 7.10.
/// Each test below fixes one of them, and the negative cases are the interesting ones:
/// linking a validator is not approval to use it, so a manifest that does not enable the
/// capability, does not name this policy, does not record this implementation version, or
/// carries a rejected feasibility decision all resolve to the unavailable lane.
@Suite("Pixel-only unavailable provenance lane")
struct UnavailableProvenanceLaneTests {
    // MARK: The pixel-only composition

    @Test("The pixel-only composition reports the validator is not compiled in")
    func pixelOnlyLaneReason() async {
        let provider = ProvenanceLaneProvider.pixelOnly

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

    @Test("An unavailable lane describes no inspection")
    func unavailableLaneHasNoInspectionRequest() {
        #expect(ProvenanceLaneProvider.pixelOnly.inspectionRequest(for: Sample.asset()) == nil)
        #expect(
            ProvenanceLaneProvider.capabilityNotEnabled
                .inspectionRequest(for: Sample.asset()) == nil
        )
    }

    @Test("An unavailable lane has no fusion input and no state key")
    func unavailableLaneBypassesFusion() {
        for reason in UnavailableReason.allCases {
            let lane = ProvenanceLane.unavailable(reason)
            #expect(lane.fusionInput == nil)
            #expect(lane.stateKey == nil)
        }
    }

    // MARK: Every pixel-only report omits the Combined Summary

    @Test("A pixel-only report is representable only without a Combined Summary")
    func pixelOnlyReportOmitsCombinedSummary() async {
        let lane = await ProvenanceLaneProvider.pixelOnly.lane(for: Sample.asset())

        let report = ReportSample.report(provenance: lane, combinedSummary: nil)
        #expect(report != nil)
        #expect(report?.combinedSummary == nil)
        #expect(report?.provenance == .unavailable(.validatorNotCompiledIntoRelease))
        #expect(report?.binding.provenancePolicyID == nil)

        // An unavailable lane bypasses fusion entirely, so a summary beside it is not a
        // value the domain will build.
        let fused = ReportSample.report(
            provenance: lane,
            combinedSummary: CombinedSummary(
                copyKey: Sample.copyKey("copy.combined.sample"),
                fusionRuleID: Sample.artifact("fusion.sample")
            )
        )
        #expect(fused == nil)

        // Nor can an unavailable lane be inconsistent with anything.
        let inconsistent = ReportSample.report(
            provenance: lane,
            combinedSummary: nil,
            apparentInconsistency: Sample.copyKey("copy.inconsistency.sample")
        )
        #expect(inconsistent == nil)
    }

    // MARK: Resolution from what a build compiled and what its manifest says

    @Test("No compiled analyzer is the pixel-only lane, whatever the manifest says")
    func absentAnalyzerIsPixelOnly() {
        let policy = PolicySample.policy()

        let withoutManifestApproval = ProvenanceLaneProvider.resolve(
            analyzer: nil,
            policy: nil,
            manifest: ManifestSample.pixelOnly
        )
        #expect(withoutManifestApproval.unavailableReason == .validatorNotCompiledIntoRelease)

        // A signed manifest cannot enable a capability whose implementation is absent
        // from the binary.
        let withManifestApproval = ProvenanceLaneProvider.resolve(
            analyzer: nil,
            policy: policy,
            manifest: ManifestSample.provenanceEnabled(for: policy)
        )
        #expect(withManifestApproval.unavailableReason == .validatorNotCompiledIntoRelease)
    }

    @Test("A compiled analyzer the manifest does not enable is never invoked")
    func compiledButNotEnabledAnalyzerIsNotInvoked() async {
        let analyzer = RecordingProvenanceAnalyzer(returning: .absent)
        let provider = ProvenanceLaneProvider.resolve(
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
