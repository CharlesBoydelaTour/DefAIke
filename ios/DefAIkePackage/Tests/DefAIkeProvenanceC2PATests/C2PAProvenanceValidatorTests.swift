import Testing

@testable import DefAIkeDomain
@testable import DefAIkeProvenanceAPI
@testable import DefAIkeProvenanceC2PA

/// What the adapter does end to end: exact bytes in, one state or one finding out.
///
/// Every policy, copy key, and trust value here is synthetic. Nothing in this suite
/// asserts that a mapping is *correct*; the assertions are about the adapter's behavior
/// for a given approved input, and about which conditions refuse to become a state.
@Suite("C2PA provenance validator")
struct C2PAProvenanceValidatorTests {

    // MARK: - Exactly one enabled state per outcome

    @Test("A clean pass with an established binding maps to validated")
    func validatedState() async throws {
        let policy = PolicySample.policy()
        let (validator, reader, asset) = await InspectionSample.validator(
            policy: policy,
            outcome: C2PAReadOutcome(
                status: .readerCondition(.allChecksPassed),
                binding: .boundToInspectedBytes,
                manifestByteCount: 512,
                manifestNestingDepth: 3,
                signerDetails: [
                    C2PARawDetail(field: .signerIdentity, rawValue: "CN=Example Signer"),
                    C2PARawDetail(field: .claimGenerator, rawValue: "Example Generator/1.0"),
                ],
                assertionLabels: ["c2pa.actions"]
            )
        )

        let evidence = try await validator.inspect(asset)

        guard case let .validated(summary) = evidence else {
            Issue.record("expected the validated state, got \(evidence.category)")
            return
        }
        #expect(summary.provenancePolicyID == policy.id)
        #expect(summary.bindingStatus == .boundToInspectedBytes)
        #expect(summary.signerFields.map(\.value.rawValue) == [
            "CN=Example Signer", "Example Generator/1.0",
        ])
        #expect(summary.assertionFields.map(\.value.rawValue) == ["c2pa.actions"])
        #expect(reader.readCount == 1)
    }

    @Test("No Content Credential in the inspected bytes maps to absent")
    func absentState() async throws {
        let (validator, _, asset) = await InspectionSample.validator(
            policy: PolicySample.policy(),
            outcome: C2PAReadOutcome(
                status: .readerCondition(.noManifestFound),
                binding: .notDetermined
            )
        )

        #expect(try await validator.inspect(asset) == .absent)
    }

    @Test(
        "A reported failure maps to invalid with the category of the failing check",
        arguments: [
            (PolicySample.byteBindingFailure, InvalidityCategory.byteBinding),
            (PolicySample.cryptographicFailure, InvalidityCategory.cryptographic),
            (PolicySample.structuralFailure, InvalidityCategory.structural),
        ]
    )
    func invalidState(code: String, category: InvalidityCategory) async throws {
        let policy = PolicySample.policy()
        let (validator, _, asset) = await InspectionSample.validator(
            policy: policy,
            outcome: C2PAReadOutcome(
                status: .libraryStatus(code),
                binding: category == .byteBinding ? .notBound : .notDetermined,
                failedCheck: category
            )
        )

        let evidence = try await validator.inspect(asset)

        guard case let .invalid(summary) = evidence else {
            Issue.record("expected the invalid state, got \(evidence.category)")
            return
        }
        #expect(summary.category == category)
        #expect(summary.explanationKey == CopySample.stateKey(.invalid))
    }

    @Test("A container the validator cannot read maps to unsupported")
    func unsupportedState() async throws {
        let (validator, _, asset) = await InspectionSample.validator(
            policy: PolicySample.policy(),
            outcome: C2PAReadOutcome(
                status: .readerCondition(.containerNotSupported),
                binding: .notDetermined
            )
        )

        let evidence = try await validator.inspect(asset)

        guard case let .unsupported(summary) = evidence else {
            Issue.record("expected the unsupported state, got \(evidence.category)")
            return
        }
        #expect(summary.explanationKey == CopySample.stateKey(.unsupported))
        #expect(summary.unsupportedFeatures.isEmpty)
    }

    @Test("An inconclusive read maps to indeterminate, not to unavailable")
    func indeterminateState() async throws {
        let (validator, _, asset) = await InspectionSample.validator(
            policy: PolicySample.policy(),
            outcome: C2PAReadOutcome(
                status: .readerCondition(.inputNotParsable),
                binding: .notDetermined
            )
        )

        let evidence = try await validator.inspect(asset)

        guard case let .indeterminate(summary) = evidence else {
            Issue.record("expected the indeterminate state, got \(evidence.category)")
            return
        }
        #expect(summary.explanationKey == CopySample.stateKey(.indeterminate))
        // Requirement 6.21: indeterminate is an enabled-validator processing result and
        // is reported through the available lane, never as the unavailable state.
        #expect(ProvenanceLane.available(evidence).isAvailable)
    }

    // MARK: - Requirement 6.6: the exact retained bytes

    @Test("The validator receives the exact retained byte sequence")
    func inspectsExactRetainedBytes() async throws {
        let (validator, reader, asset) = await InspectionSample.validator(
            policy: PolicySample.policy(),
            outcome: C2PAReadOutcome(
                status: .readerCondition(.noManifestFound),
                binding: .notDetermined
            )
        )

        _ = try await validator.inspect(asset)

        #expect(reader.lastReadBytes == InspectionSample.bytes)
    }

    @Test("A stored object whose measurements disagree with the request is not inspected")
    func rejectsMeasurementDisagreement() async throws {
        let policy = PolicySample.policy()
        let asset = InspectionSample.asset()
        let store = StubFinalizedObjectStore()
        // The receipt claims a different digest than the one ingest recorded, which is
        // what a substituted or re-encoded object looks like from here.
        await store.store(
            key: asset.handle.storageKey,
            session: asset.sessionID,
            bytes: InspectionSample.bytes,
            declaredDigest: Sample.digest("f")
        )
        let reader = StubManifestReader(
            returning: C2PAReadOutcome(
                status: .readerCondition(.allChecksPassed),
                binding: .boundToInspectedBytes
            )
        )
        let validator = C2PAProvenanceValidator(
            store: store,
            reader: reader,
            clock: SteppingClock(step: .milliseconds(1)),
            configuration: TrustSample.configuration(for: policy)
        )

        await #expect(throws: ProvenanceFeasibilityFinding.self) {
            try await validator.inspect(asset)
        }
        #expect(reader.readCount == 0, "no state may be reported for bytes that were not inspected")
    }

    @Test("A truncated object is a finding rather than an evidence state")
    func rejectsShortObject() async throws {
        let policy = PolicySample.policy()
        let asset = InspectionSample.asset()
        let store = StubFinalizedObjectStore()
        // The receipt agrees with the request, but the object holds fewer bytes.
        await store.store(
            key: asset.handle.storageKey,
            session: asset.sessionID,
            bytes: Array(InspectionSample.bytes.dropLast(8)),
            declaredByteCount: UInt64(InspectionSample.bytes.count)
        )
        let reader = StubManifestReader(
            returning: C2PAReadOutcome(
                status: .readerCondition(.allChecksPassed),
                binding: .boundToInspectedBytes
            )
        )
        let validator = C2PAProvenanceValidator(
            store: store,
            reader: reader,
            clock: SteppingClock(step: .milliseconds(1)),
            configuration: TrustSample.configuration(for: policy)
        )

        let finding = await capturedFinding {
            try await validator.inspect(asset)
        }
        #expect(finding == .inspectedBytesAreNotTheRetainedBytes(
            expectedByteCount: 64,
            observedByteCount: 56
        ))
        #expect(reader.readCount == 0)
    }

    @Test("An unreadable object is a finding, not absence")
    func unreadableObjectIsNotAbsence() async throws {
        let policy = PolicySample.policy()
        let asset = InspectionSample.asset()
        let store = StubFinalizedObjectStore()
        await store.store(
            key: asset.handle.storageKey,
            session: asset.sessionID,
            bytes: InspectionSample.bytes
        )
        await store.failNextRead(with: .storeUnavailable)
        let validator = C2PAProvenanceValidator(
            store: store,
            reader: StubManifestReader(
                returning: C2PAReadOutcome(
                    status: .readerCondition(.noManifestFound),
                    binding: .notDetermined
                )
            ),
            clock: SteppingClock(step: .milliseconds(1)),
            configuration: TrustSample.configuration(for: policy)
        )

        let finding = await capturedFinding { try await validator.inspect(asset) }
        #expect(finding == .retainedBytesUnreadable(.storeUnavailable))
    }

    @Test("An object the store does not hold is a finding, not absence")
    func missingObjectIsNotAbsence() async throws {
        let policy = PolicySample.policy()
        let asset = InspectionSample.asset()
        let validator = C2PAProvenanceValidator(
            store: StubFinalizedObjectStore(),
            reader: StubManifestReader(
                returning: C2PAReadOutcome(
                    status: .readerCondition(.noManifestFound),
                    binding: .notDetermined
                )
            ),
            clock: SteppingClock(step: .milliseconds(1)),
            configuration: TrustSample.configuration(for: policy)
        )

        let finding = await capturedFinding { try await validator.inspect(asset) }
        #expect(finding == .retainedBytesUnreadable(.notFound(asset.handle.storageKey)))
    }

    // MARK: - No unapproved default resolves a fault

    @Test("A status the policy does not map is a finding, never a state")
    func unmappedStatusIsAFinding() async throws {
        // A policy that maps everything except a clean pass. Nothing about the adapter
        // may substitute a state for the missing entry.
        let policy = PolicySample.policy(
            statusMappings: PolicySample.statusMappings.filter {
                $0.status != PolicySample.readerStatus(.allChecksPassed)
            }
        )
        let (validator, _, asset) = await InspectionSample.validator(
            policy: policy,
            outcome: C2PAReadOutcome(
                status: .readerCondition(.allChecksPassed),
                binding: .boundToInspectedBytes
            )
        )

        let finding = await capturedFinding { try await validator.inspect(asset) }
        #expect(finding == .mappingFault(
            .unmappedValidatorStatus(PolicySample.readerStatus(.allChecksPassed))
        ))
    }

    @Test("An invalid state with no classified failing check is a finding")
    func unclassifiedFailureIsAFinding() async throws {
        let policy = PolicySample.policy()
        let (validator, _, asset) = await InspectionSample.validator(
            policy: policy,
            outcome: C2PAReadOutcome(
                // `general.error` is deliberately absent from the classification table.
                status: .libraryStatus(PolicySample.unclassifiedFailure),
                binding: .notDetermined,
                failedCheck: nil
            )
        )

        let finding = await capturedFinding { try await validator.inspect(asset) }
        #expect(finding == .mappingFault(
            .undeterminedInvalidityCategory(
                status: PolicySample.libraryStatus(PolicySample.unclassifiedFailure)
            )
        ))
    }

    @Test("A clean pass without an established binding cannot become validated")
    func validatedRequiresBinding() async throws {
        let policy = PolicySample.policy()
        let (validator, _, asset) = await InspectionSample.validator(
            policy: policy,
            outcome: C2PAReadOutcome(
                status: .readerCondition(.allChecksPassed),
                binding: .notDetermined
            )
        )

        let finding = await capturedFinding { try await validator.inspect(asset) }
        #expect(finding == .mappingFault(
            .bindingInconsistentWithMappedState(
                status: PolicySample.readerStatus(.allChecksPassed),
                state: .validated,
                binding: .notDetermined
            )
        ))
    }

    @Test("A revocation gap follows the policy's declared behavior")
    func revocationGapFollowsPolicy() async throws {
        let policy = PolicySample.policy(revocationState: .indeterminate)
        let (validator, _, asset) = await InspectionSample.validator(
            policy: policy,
            outcome: C2PAReadOutcome(
                status: .readerCondition(.revocationAnswerUnavailable),
                binding: .notDetermined
            )
        )

        let evidence = try await validator.inspect(asset)

        #expect(evidence.category == .indeterminate)
        #expect(evidence.category != .validated, "a missing revocation answer is not a success")
    }

    @Test("A revocation gap the policy answers two different ways is a finding")
    func revocationDisagreementIsAFinding() async throws {
        // The status mapping says unsupported; the revocation behavior says indeterminate.
        // Two approved fields, one question, no approved resolution.
        let mappings = PolicySample.statusMappings.map { mapping in
            mapping.status == PolicySample.readerStatus(.revocationAnswerUnavailable)
                ? ProvenanceStatusMapping(status: mapping.status, state: .unsupported)
                : mapping
        }
        let policy = PolicySample.policy(revocationState: .indeterminate, statusMappings: mappings)
        let (validator, _, asset) = await InspectionSample.validator(
            policy: policy,
            outcome: C2PAReadOutcome(
                status: .readerCondition(.revocationAnswerUnavailable),
                binding: .notDetermined
            )
        )

        let finding = await capturedFinding { try await validator.inspect(asset) }
        #expect(finding == .revocationBehaviorDisagreesWithStatusMapping(
            status: PolicySample.readerStatus(.revocationAnswerUnavailable),
            mappedState: .unsupported,
            declaredState: .indeterminate
        ))
    }

    // MARK: - Bounded resource controls

    @Test("A manifest larger than the policy permits stops the inspection")
    func manifestByteCeiling() async throws {
        let policy = PolicySample.policy(maximumManifestByteCount: 1_024)
        let (validator, _, asset) = await InspectionSample.validator(
            policy: policy,
            outcome: C2PAReadOutcome(
                status: .readerCondition(.allChecksPassed),
                binding: .boundToInspectedBytes,
                manifestByteCount: 1_025
            )
        )

        let finding = await capturedFinding { try await validator.inspect(asset) }
        #expect(finding == .processingLimitExceeded(
            .manifestByteCount(observed: 1_025, limit: 1_024)
        ))
    }

    @Test("A manifest deeper than the policy permits stops the inspection")
    func manifestDepthCeiling() async throws {
        let policy = PolicySample.policy(maximumNestingDepth: 4)
        let (validator, _, asset) = await InspectionSample.validator(
            policy: policy,
            outcome: C2PAReadOutcome(
                status: .readerCondition(.allChecksPassed),
                binding: .boundToInspectedBytes,
                manifestNestingDepth: 5
            )
        )

        let finding = await capturedFinding { try await validator.inspect(asset) }
        #expect(finding == .processingLimitExceeded(.nestingDepth(observed: 5, limit: 4)))
    }

    @Test("More assertions than the policy permits stops the inspection")
    func assertionCeiling() async throws {
        let policy = PolicySample.policy(maximumAssertionCount: 2)
        let (validator, _, asset) = await InspectionSample.validator(
            policy: policy,
            outcome: C2PAReadOutcome(
                status: .readerCondition(.allChecksPassed),
                binding: .boundToInspectedBytes,
                assertionLabels: ["c2pa.actions", "c2pa.hash.data", "stds.schema-org.CreativeWork"]
            )
        )

        let finding = await capturedFinding { try await validator.inspect(asset) }
        #expect(finding == .processingLimitExceeded(.assertionCount(observed: 3, limit: 2)))
    }

    @Test("Validation slower than the policy's declared maximum is a resource finding")
    func processingDurationCeiling() async throws {
        let policy = PolicySample.policy(maximumProcessingMilliseconds: 10)
        let (validator, _, asset) = await InspectionSample.validator(
            policy: policy,
            outcome: C2PAReadOutcome(
                status: .readerCondition(.allChecksPassed),
                binding: .boundToInspectedBytes
            ),
            clockStep: .milliseconds(25)
        )

        let finding = await capturedFinding { try await validator.inspect(asset) }
        #expect(finding == .processingLimitExceeded(
            .processingDuration(observed: .milliseconds(25), limit: .milliseconds(10))
        ))
    }

    @Test("A limit the validator itself reports is forwarded as that limit")
    func seamLimitBreachIsForwarded() async throws {
        let validator = await failingValidator(
            .limitExceeded(.manifestByteCount(observed: 99_999, limit: 65_536))
        )

        let finding = await capturedFinding { try await validator.0.inspect(validator.1) }
        #expect(finding == .processingLimitExceeded(
            .manifestByteCount(observed: 99_999, limit: 65_536)
        ))
    }

    @Test("A validator that could not be configured produces no state")
    func unconfigurableValidatorIsAFinding() async throws {
        let validator = await failingValidator(.validatorNotConfigurable)

        let finding = await capturedFinding { try await validator.0.inspect(validator.1) }
        #expect(finding == .validatorNotConfigurable)
    }

    /// A validator whose seam always reports `fault`, over a store that holds the bytes.
    private func failingValidator(
        _ fault: C2PAReadFault
    ) async -> (C2PAProvenanceValidator, ImportedEncodedAsset) {
        let policy = PolicySample.policy()
        let asset = InspectionSample.asset()
        let store = StubFinalizedObjectStore()
        await store.store(
            key: asset.handle.storageKey,
            session: asset.sessionID,
            bytes: InspectionSample.bytes
        )
        let validator = C2PAProvenanceValidator(
            store: store,
            reader: StubManifestReader(failingWith: fault),
            clock: SteppingClock(step: .milliseconds(1)),
            configuration: TrustSample.configuration(for: policy)
        )
        return (validator, asset)
    }

    // MARK: - Configuration cannot be assembled without approved trust

    @Test("Trust material from a store the policy did not name cannot configure a validator")
    func rejectsForeignTrustStore() throws {
        let policy = PolicySample.policy()
        let foreignStore = try ProvenanceTrustStoreDescriptor(
            store: Sample.evidence("trust-store.other"),
            anchorCount: try PositiveCount(validating: 3),
            isOfflineOnly: true
        )
        let foreign = C2PAOfflineTrustMaterial(
            descriptor: foreignStore,
            anchorBytes: TrustSample.anchorBytes
        )!

        #expect(
            C2PAValidatorConfiguration(
                mapper: CopySample.mapper(for: policy),
                trust: foreign
            ) == nil
        )
    }

    @Test("Empty trust anchors are not representable")
    func rejectsEmptyAnchors() {
        #expect(
            C2PAOfflineTrustMaterial(
                descriptor: PolicySample.trustStore(),
                anchorBytes: []
            ) == nil
        )
    }
}

// MARK: - Helpers

/// Runs `work` and returns the finding it threw.
///
/// Records an issue and returns `nil` when the work succeeded, so a test that expects a
/// finding cannot pass by producing a state instead.
func capturedFinding(
    _ work: () async throws -> some Any,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> ProvenanceFeasibilityFinding? {
    do {
        let value = try await work()
        Issue.record(
            "expected a feasibility finding, got \(value)",
            sourceLocation: sourceLocation
        )
        return nil
    } catch let finding as ProvenanceFeasibilityFinding {
        return finding
    } catch {
        Issue.record("expected a feasibility finding, got \(error)", sourceLocation: sourceLocation)
        return nil
    }
}
