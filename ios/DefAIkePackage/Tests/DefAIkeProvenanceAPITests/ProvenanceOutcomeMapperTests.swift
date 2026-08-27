import Testing

@testable import DefAIkeDomain
@testable import DefAIkeProvenanceAPI

/// The result mapping contract: one normalized outcome onto exactly one enabled state.
///
/// Two things are being pinned. First, exclusivity and determinism: the policy's status
/// mapping decides the state, and the same outcome always yields the same state and the
/// same bounded details (Requirements 6.9 through 6.14). Second, fail-closed behavior:
/// every condition the approved policy does not answer is a fault, and no branch can
/// reach `validated` from an unmapped status, an unestablished binding, or a failed
/// check.
@Suite("Provenance outcome mapping")
struct ProvenanceOutcomeMapperTests {
    // MARK: Assembling a mapper

    @Test("A mapper needs a policy and copy that were approved together")
    func mapperRequiresAgreeingPolicyAndCopy() {
        let policy = PolicySample.policy()
        let catalog = CopySample.catalog()

        #expect(Self.mapper(policy: policy, catalog: catalog) != nil)

        // Copy validated against a different policy version.
        let otherPolicy = PolicySample.policy(id: "provenance.other")
        let binding = ProvenanceCopyBinding(
            policy: otherPolicy,
            catalog: catalog,
            detailLabels: CopySample.detailLabels(for: otherPolicy)
        )
        #expect(binding != nil)
        #expect(ProvenanceOutcomeMapper(policy: policy, copy: binding!) == nil)
    }

    @Test("A copy binding fails closed on a missing state, label, or approval")
    func copyBindingFailsClosed() {
        let policy = PolicySample.policy()

        for omitted in ProvenanceStateKey.allCases {
            #expect(
                ProvenanceCopyBinding(
                    policy: policy,
                    catalog: CopySample.catalog(omitting: omitted),
                    detailLabels: CopySample.detailLabels(for: policy)
                ) == nil,
                "omitting approved copy for \(omitted.rawValue) must fail closed"
            )
        }

        // Presence is not approval.
        #expect(
            ProvenanceCopyBinding(
                policy: policy,
                catalog: CopySample.catalog(approval: .rejected),
                detailLabels: CopySample.detailLabels(for: policy)
            ) == nil
        )

        // A label short of the policy's displayable fields would silently drop a detail.
        var short = CopySample.detailLabels(for: policy)
        short.removeValue(forKey: .signerIdentity)
        #expect(
            ProvenanceCopyBinding(policy: policy, catalog: CopySample.catalog(), detailLabels: short)
                == nil
        )

        // A label the policy does not permit displaying is an extra field.
        var extra = CopySample.detailLabels(for: policy)
        extra[.validationTime] = CopySample.fieldKey(.validationTime)
        #expect(
            ProvenanceCopyBinding(policy: policy, catalog: CopySample.catalog(), detailLabels: extra)
                == nil
        )

        // One key naming two fields would render the same label twice.
        var duplicated = CopySample.detailLabels(for: policy)
        duplicated[.signerIdentity] = CopySample.fieldKey(.claimGenerator)
        #expect(
            ProvenanceCopyBinding(
                policy: policy,
                catalog: CopySample.catalog(),
                detailLabels: duplicated
            ) == nil
        )
    }

    // MARK: Exclusive mapping

    @Test("Each mapped status produces exactly one state, with the policy's identity")
    func eachStatusMapsToExactlyOneState() throws {
        let policy = PolicySample.policy()
        let mapper = try #require(Self.mapper(policy: policy, catalog: CopySample.catalog()))

        let cases: [(ProvenanceValidatorStatusID, NormalizedProvenanceOutcome, ProvenanceCategory)] = [
            (PolicySample.validatedStatus, Self.validatedOutcome(), .validated),
            (PolicySample.invalidStatus, Self.invalidOutcome(), .invalid),
            (PolicySample.absentStatus, Self.absentOutcome(), .absent),
            (PolicySample.unsupportedStatus, Self.unsupportedOutcome(), .unsupported),
            (PolicySample.indeterminateStatus, Self.indeterminateOutcome(), .indeterminate),
        ]

        for (status, outcome, expected) in cases {
            let evidence = try mapper.evidence(for: outcome)
            #expect(evidence.category == expected, "status \(status.rawValue)")
            // Repeating the same input is the same result: the mapping is pure.
            #expect(try mapper.evidence(for: outcome) == evidence)
        }

        // Every enabled state is reachable, and no two statuses collide on one state.
        let categories = try cases.map { try mapper.evidence(for: $0.1).category }
        #expect(Set(categories).count == ProvenanceCategory.allCases.count)
    }

    @Test("A validated state records binding, the policy version, and approved details")
    func validatedStateCarriesBoundedDetails() throws {
        let policy = PolicySample.policy()
        let mapper = try #require(Self.mapper(policy: policy, catalog: CopySample.catalog()))

        guard case let .validated(summary) = try mapper.evidence(for: Self.validatedOutcome())
        else {
            Issue.record("expected the validated state")
            return
        }

        #expect(summary.provenancePolicyID == policy.id)
        #expect(summary.bindingStatus == .boundToInspectedBytes)
        #expect(
            summary.signerFields.map(\.labelKey) == [
                CopySample.fieldKey(.signerIdentity),
                CopySample.fieldKey(.claimGenerator),
            ]
        )
        #expect(summary.signerFields.map(\.value.rawValue) == ["Sample Signer", "Sample Generator"])
        #expect(summary.assertionFields.map(\.value.rawValue) == ["c2pa.actions", "c2pa.hash.data"])
        #expect(
            summary.assertionFields.allSatisfy {
                $0.labelKey == CopySample.fieldKey(.assertionLabels)
            }
        )
    }

    @Test("Displayed details follow the policy allowlist in a fixed order")
    func detailProjectionIsAllowlistedAndOrdered() throws {
        // The same outcome, reported in a different order, with only one field permitted.
        let restrictive = PolicySample.policy(displayableFields: [.claimGenerator])
        let mapper = try #require(Self.mapper(policy: restrictive, catalog: CopySample.catalog()))

        let reversed = try #require(
            NormalizedProvenanceOutcome(
                status: PolicySample.validatedStatus,
                binding: .boundToInspectedBytes,
                failedCheck: nil,
                signerDetails: [
                    .init(field: .claimGenerator, value: Sample.display("Sample Generator")),
                    .init(field: .signerIdentity, value: Sample.display("Sample Signer")),
                ],
                assertionLabels: [Sample.display("c2pa.actions")]
            )
        )

        guard case let .validated(summary) = try mapper.evidence(for: reversed) else {
            Issue.record("expected the validated state")
            return
        }
        #expect(summary.signerFields.map(\.labelKey) == [CopySample.fieldKey(.claimGenerator)])
        #expect(summary.assertionFields.isEmpty, "assertion labels are not displayable here")

        // Field order comes from the vocabulary, not from the validator's ordering.
        let permissive = PolicySample.policy(
            displayableFields: [.signerIdentity, .claimGenerator, .assertionLabels]
        )
        let orderedMapper = try #require(
            Self.mapper(policy: permissive, catalog: CopySample.catalog())
        )
        guard case let .validated(ordered) = try orderedMapper.evidence(for: reversed) else {
            Issue.record("expected the validated state")
            return
        }
        #expect(
            ordered.signerFields.map(\.labelKey) == [
                CopySample.fieldKey(.signerIdentity),
                CopySample.fieldKey(.claimGenerator),
            ]
        )
    }

    @Test("Invalid, unsupported, and indeterminate carry the approved explanation")
    func nonValidatedStatesCarryApprovedCopy() throws {
        let policy = PolicySample.policy()
        let mapper = try #require(Self.mapper(policy: policy, catalog: CopySample.catalog()))

        guard case let .invalid(invalid) = try mapper.evidence(for: Self.invalidOutcome()) else {
            Issue.record("expected the invalid state")
            return
        }
        #expect(invalid.category == .cryptographic)
        #expect(invalid.explanationKey == CopySample.stateKey(.invalid))
        #expect(invalid.provenancePolicyID == policy.id)

        guard case let .unsupported(unsupported) = try mapper.evidence(
            for: Self.unsupportedOutcome()
        ) else {
            Issue.record("expected the unsupported state")
            return
        }
        #expect(unsupported.explanationKey == CopySample.stateKey(.unsupported))
        #expect(unsupported.unsupportedFeatures.map(\.rawValue) == ["Sample unsupported feature"])

        guard case let .indeterminate(indeterminate) = try mapper.evidence(
            for: Self.indeterminateOutcome()
        ) else {
            Issue.record("expected the indeterminate state")
            return
        }
        #expect(indeterminate.explanationKey == CopySample.stateKey(.indeterminate))
    }

    // MARK: Fail-closed faults

    @Test("An unmapped validator status is a policy gap, not a state")
    func unmappedStatusFailsClosed() throws {
        let mapper = try #require(
            Self.mapper(policy: PolicySample.policy(), catalog: CopySample.catalog())
        )
        let outcome = try #require(
            NormalizedProvenanceOutcome(
                status: PolicySample.unmappedStatus,
                binding: .boundToInspectedBytes,
                failedCheck: nil
            )
        )
        #expect(
            Self.fault(mapper, outcome)
                == .unmappedValidatorStatus(PolicySample.unmappedStatus)
        )
    }

    @Test("A validated status without established binding fails closed")
    func validatedWithoutBindingFailsClosed() throws {
        let mapper = try #require(
            Self.mapper(policy: PolicySample.policy(), catalog: CopySample.catalog())
        )
        for binding in [NormalizedBindingOutcome.notBound, .notDetermined] {
            let outcome = try #require(
                NormalizedProvenanceOutcome(
                    status: PolicySample.validatedStatus,
                    binding: binding,
                    failedCheck: nil
                )
            )
            #expect(
                Self.fault(mapper, outcome)
                    == .bindingInconsistentWithMappedState(
                        status: PolicySample.validatedStatus,
                        state: .validated,
                        binding: binding
                    )
            )
        }
    }

    @Test("A failed check on any non-invalid state fails closed")
    func failedCheckOutsideInvalidFailsClosed() throws {
        let mapper = try #require(
            Self.mapper(policy: PolicySample.policy(), catalog: CopySample.catalog())
        )
        let statuses: [(ProvenanceValidatorStatusID, ProvenanceStateKey)] = [
            (PolicySample.validatedStatus, .validated),
            (PolicySample.absentStatus, .absent),
            (PolicySample.unsupportedStatus, .unsupported),
            (PolicySample.indeterminateStatus, .indeterminate),
        ]
        for (status, state) in statuses {
            let outcome = try #require(
                NormalizedProvenanceOutcome(
                    status: status,
                    binding: .notDetermined,
                    failedCheck: .structural
                )
            )
            #expect(
                Self.fault(mapper, outcome)
                    == .invalidityCategoryOnNonInvalidState(
                        status: status,
                        state: state,
                        category: .structural
                    )
            )
        }
    }

    @Test("An invalid status with no named check fails closed rather than guessing")
    func invalidWithoutCategoryFailsClosed() throws {
        let mapper = try #require(
            Self.mapper(policy: PolicySample.policy(), catalog: CopySample.catalog())
        )
        let outcome = try #require(
            NormalizedProvenanceOutcome(
                status: PolicySample.invalidStatus,
                binding: .notBound,
                failedCheck: nil
            )
        )
        #expect(
            Self.fault(mapper, outcome)
                == .undeterminedInvalidityCategory(status: PolicySample.invalidStatus)
        )
    }

    @Test("A byte-binding failure that also reports binding fails closed")
    func contradictoryByteBindingFailsClosed() throws {
        let mapper = try #require(
            Self.mapper(policy: PolicySample.policy(), catalog: CopySample.catalog())
        )
        let outcome = try #require(
            NormalizedProvenanceOutcome(
                status: PolicySample.invalidStatus,
                binding: .boundToInspectedBytes,
                failedCheck: .byteBinding
            )
        )
        #expect(
            Self.fault(mapper, outcome)
                == .bindingInconsistentWithMappedState(
                    status: PolicySample.invalidStatus,
                    state: .invalid,
                    binding: .boundToInspectedBytes
                )
        )
    }

    @Test("Absence carries no detail and no binding determination")
    func absenceStaysEmpty() throws {
        let mapper = try #require(
            Self.mapper(policy: PolicySample.policy(), catalog: CopySample.catalog())
        )

        let withDetail = try #require(
            NormalizedProvenanceOutcome(
                status: PolicySample.absentStatus,
                binding: .notDetermined,
                failedCheck: nil,
                signerDetails: [
                    .init(field: .signerIdentity, value: Sample.display("Sample Signer"))
                ]
            )
        )
        #expect(
            Self.fault(mapper, withDetail)
                == .detailsReportedForAbsentState(status: PolicySample.absentStatus)
        )

        let withBinding = try #require(
            NormalizedProvenanceOutcome(
                status: PolicySample.absentStatus,
                binding: .boundToInspectedBytes,
                failedCheck: nil
            )
        )
        #expect(
            Self.fault(mapper, withBinding)
                == .bindingInconsistentWithMappedState(
                    status: PolicySample.absentStatus,
                    state: .absent,
                    binding: .boundToInspectedBytes
                )
        )
    }

    @Test("More assertion labels than the policy permits fails closed")
    func assertionLimitFailsClosed() throws {
        let policy = PolicySample.policy(maximumAssertionCount: 2)
        let mapper = try #require(Self.mapper(policy: policy, catalog: CopySample.catalog()))

        let atLimit = try #require(
            NormalizedProvenanceOutcome(
                status: PolicySample.validatedStatus,
                binding: .boundToInspectedBytes,
                failedCheck: nil,
                assertionLabels: [Sample.display("one"), Sample.display("two")]
            )
        )
        #expect(Self.fault(mapper, atLimit) == nil)

        let overLimit = try #require(
            NormalizedProvenanceOutcome(
                status: PolicySample.validatedStatus,
                binding: .boundToInspectedBytes,
                failedCheck: nil,
                assertionLabels: [
                    Sample.display("one"), Sample.display("two"), Sample.display("three"),
                ]
            )
        )
        #expect(Self.fault(mapper, overLimit) == .assertionLimitExceeded(observed: 3, limit: 2))
    }

    // MARK: Helpers

    private static func mapper(
        policy: ProvenancePolicy,
        catalog: ApprovedVerdictCopyCatalog
    ) -> ProvenanceOutcomeMapper? {
        guard let copy = ProvenanceCopyBinding(
            policy: policy,
            catalog: catalog,
            detailLabels: CopySample.detailLabels(for: policy)
        ) else {
            return nil
        }
        return ProvenanceOutcomeMapper(policy: policy, copy: copy)
    }

    /// The fault a mapping produced, or `nil` when it produced a state.
    private static func fault(
        _ mapper: ProvenanceOutcomeMapper,
        _ outcome: NormalizedProvenanceOutcome
    ) -> ProvenanceMappingFault? {
        do {
            _ = try mapper.evidence(for: outcome)
            return nil
        } catch {
            return error
        }
    }

    private static func validatedOutcome() -> NormalizedProvenanceOutcome {
        NormalizedProvenanceOutcome(
            status: PolicySample.validatedStatus,
            binding: .boundToInspectedBytes,
            failedCheck: nil,
            signerDetails: [
                .init(field: .signerIdentity, value: Sample.display("Sample Signer")),
                .init(field: .claimGenerator, value: Sample.display("Sample Generator")),
            ],
            assertionLabels: [Sample.display("c2pa.actions"), Sample.display("c2pa.hash.data")]
        )!
    }

    private static func invalidOutcome() -> NormalizedProvenanceOutcome {
        NormalizedProvenanceOutcome(
            status: PolicySample.invalidStatus,
            binding: .notDetermined,
            failedCheck: .cryptographic
        )!
    }

    private static func absentOutcome() -> NormalizedProvenanceOutcome {
        NormalizedProvenanceOutcome(
            status: PolicySample.absentStatus,
            binding: .notDetermined,
            failedCheck: nil
        )!
    }

    private static func unsupportedOutcome() -> NormalizedProvenanceOutcome {
        NormalizedProvenanceOutcome(
            status: PolicySample.unsupportedStatus,
            binding: .notDetermined,
            failedCheck: nil,
            unsupportedFeatures: [Sample.display("Sample unsupported feature")]
        )!
    }

    private static func indeterminateOutcome() -> NormalizedProvenanceOutcome {
        NormalizedProvenanceOutcome(
            status: PolicySample.indeterminateStatus,
            binding: .notDetermined,
            failedCheck: nil
        )!
    }
}
