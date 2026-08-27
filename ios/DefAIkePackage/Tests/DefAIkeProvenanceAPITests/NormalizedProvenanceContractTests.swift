import Testing

@testable import DefAIkeDomain
@testable import DefAIkeProvenanceAPI

/// The normalized input and output values a validator adapter speaks through.
///
/// Both sides are bounded at construction rather than at display time, because manifest
/// content is attacker-influenced: an outcome that cannot be built is one the projection
/// never has to defend against. The input side pins Requirement 6.6 — an inspection is
/// described by the retained bytes' own measurements, so a transformed copy cannot be
/// passed off as the analyzed representation.
@Suite("Normalized provenance contract")
struct NormalizedProvenanceContractTests {
    // MARK: Input

    @Test("An inspection request describes the retained bytes and the policy's limits")
    func requestDerivesFromAssetAndPolicy() {
        let policy = PolicySample.policy()
        let asset = Sample.asset(byteCount: 12_345, digestCharacter: "9")
        let request = ProvenanceInspectionRequest(asset: asset, policy: policy)

        #expect(request.sessionID == asset.sessionID)
        #expect(request.storageKey == asset.handle.storageKey)
        #expect(request.byteCount == 12_345)
        #expect(request.sha256 == asset.sha256)
        #expect(request.preservationStatus == asset.preservationStatus)
        #expect(request.policyID == policy.id)
        #expect(request.limits == policy.processingLimits)
    }

    @Test("Only the exact retained bytes satisfy an inspection request")
    func requestRejectsOtherBytes() {
        let asset = Sample.asset(byteCount: 4_096, digestCharacter: "b")
        let request = ProvenanceInspectionRequest(asset: asset, policy: PolicySample.policy())

        #expect(request.inspectsExactly(byteCount: 4_096, sha256: Sample.digest("b")))
        // A different digest is a different representation, even at the same length.
        #expect(request.inspectsExactly(byteCount: 4_096, sha256: Sample.digest("c")) == false)
        // A truncated or extended read is not the retained representation either.
        #expect(request.inspectsExactly(byteCount: 4_095, sha256: Sample.digest("b")) == false)
    }

    // MARK: Output

    @Test("A normalized outcome accepts bounded, unambiguous details")
    func outcomeAcceptsBoundedDetails() {
        let outcome = NormalizedProvenanceOutcome(
            status: PolicySample.validatedStatus,
            binding: .boundToInspectedBytes,
            failedCheck: nil,
            signerDetails: [
                .init(field: .signerIdentity, value: Sample.display("Sample Signer")),
                .init(field: .bindingStatus, value: Sample.display("Bound")),
            ],
            assertionLabels: [Sample.display("c2pa.actions")],
            unsupportedFeatures: []
        )
        #expect(outcome != nil)
        #expect(outcome?.reportsAnyDetail == true)

        let bare = NormalizedProvenanceOutcome(
            status: PolicySample.absentStatus,
            binding: .notDetermined,
            failedCheck: nil
        )
        #expect(bare?.reportsAnyDetail == false)
    }

    @Test("A repeated signer field is not representable")
    func outcomeRejectsRepeatedSignerField() {
        #expect(
            NormalizedProvenanceOutcome(
                status: PolicySample.validatedStatus,
                binding: .boundToInspectedBytes,
                failedCheck: nil,
                signerDetails: [
                    .init(field: .signerIdentity, value: Sample.display("First")),
                    .init(field: .signerIdentity, value: Sample.display("Second")),
                ]
            ) == nil
        )
    }

    @Test("Assertion labels arrive through exactly one field")
    func outcomeRejectsAssertionLabelsAsSignerDetail() {
        #expect(
            NormalizedProvenanceOutcome(
                status: PolicySample.validatedStatus,
                binding: .boundToInspectedBytes,
                failedCheck: nil,
                signerDetails: [
                    .init(field: .assertionLabels, value: Sample.display("c2pa.actions"))
                ]
            ) == nil
        )
    }

    @Test("Duplicate labels and features are not representable")
    func outcomeRejectsDuplicateRows() {
        #expect(
            NormalizedProvenanceOutcome(
                status: PolicySample.validatedStatus,
                binding: .boundToInspectedBytes,
                failedCheck: nil,
                assertionLabels: [Sample.display("c2pa.actions"), Sample.display("c2pa.actions")]
            ) == nil
        )
        #expect(
            NormalizedProvenanceOutcome(
                status: PolicySample.unsupportedStatus,
                binding: .notDetermined,
                failedCheck: nil,
                unsupportedFeatures: [Sample.display("same"), Sample.display("same")]
            ) == nil
        )
    }

    @Test("Detail lists are bounded by the structural ceiling")
    func outcomeRejectsUnboundedDetailLists() {
        let ceiling = NormalizedProvenanceOutcome.maximumDetailCount
        let atCeiling = (0..<ceiling).map { Sample.display("label-\($0)") }
        let overCeiling = (0...ceiling).map { Sample.display("label-\($0)") }

        #expect(
            NormalizedProvenanceOutcome(
                status: PolicySample.validatedStatus,
                binding: .boundToInspectedBytes,
                failedCheck: nil,
                assertionLabels: atCeiling
            ) != nil
        )
        #expect(
            NormalizedProvenanceOutcome(
                status: PolicySample.validatedStatus,
                binding: .boundToInspectedBytes,
                failedCheck: nil,
                assertionLabels: overCeiling
            ) == nil
        )
        #expect(
            NormalizedProvenanceOutcome(
                status: PolicySample.unsupportedStatus,
                binding: .notDetermined,
                failedCheck: nil,
                unsupportedFeatures: overCeiling
            ) == nil
        )
    }

    @Test("The normalized status vocabulary carries no evidence state of its own")
    func normalizedValuesCarryNoState() {
        // A normalized outcome names a validator status and what was observed. The state
        // is the policy's decision, so nothing in the outcome type can spell one.
        let outcome = NormalizedProvenanceOutcome(
            status: PolicySample.validatedStatus,
            binding: .boundToInspectedBytes,
            failedCheck: nil
        )
        #expect(outcome?.status == PolicySample.validatedStatus)
        #expect(NormalizedBindingOutcome.allCases.count == 3)
    }
}
