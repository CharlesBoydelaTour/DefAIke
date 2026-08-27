import DefAIkeTestSupport
import Foundation
import Testing

@testable import DefAIkeDomain

// Mutation-focused examples for the startup gate and the artifact gates below it.
//
// These are ordinary unit tests, not a design property. Each one starts from a coherent
// artifact or startup scenario, changes exactly one thing, and requires the gate to refuse
// at a named field with a specific fault, so a regression that moves a refusal to a
// different cause fails here instead of passing quietly.
//
// The neighbouring files already pin most of this. What is here is the remainder:
//
//   * ``BoundedArtifactDecodingTests`` sweeps every artifact for "no default is ever
//     substituted", but it mutates payloads through a `JSONSerialization` round trip.
//     That round trip perturbs exact decimals, and a Calibration Policy carries two of
//     them that the schema fixes exactly — the False Accusation Budget and the 95%
//     confidence level — so for that artifact every mutated payload is refused because of
//     the perturbed level rather than because of the removed member, and the sweep's
//     "this field is required" assertions hold vacuously.
//     ``CalibrationPolicyPayloadMutationTests`` proves that, then re-asserts each member
//     by splicing it out of the payload *text* and requiring the fault to name it.
//   * ``StartupPreflightTests`` covers a compiled capability set with an *extra*
//     capability; the missing direction, a rejected verdict-copy or fusion approval, a
//     fusion rule approved against another fixture suite, a mandatory gate with no
//     result, and a cleanup that completed but not under the bound policy are added here.
//
// No value in this file is an approved device, budget, deadline, boundary, key, or
// decision. Every identifier is synthetic and exists so a gate can be asked to refuse it.

// MARK: - Payload text splicing

/// Rewrites one member of a JSON object's *text*, leaving every other byte untouched.
///
/// The companion of ``JSONMemberSplice``, whose range finder this uses. Splicing rather
/// than re-serializing for the reason that file gives: re-serializing moves exact
/// decimals, so a refusal could come from a perturbed number instead of from the change
/// the test made.
enum PolicyPayloadSplice {
    /// Where a spliced duplicate key is placed relative to the original.
    enum Placement: Sendable, CaseIterable {
        case first
        case last
    }

    /// `payload` without its top-level `key` member.
    static func removingTopLevelMember(_ key: String, from payload: String) -> String? {
        JSONMemberSplice.removingTopLevelMember(key, from: payload)
    }

    /// `payload` with the value of its top-level `key` member replaced by `value`.
    ///
    /// `value` is encoded JSON text, so a caller can supply a number, a quoted string, or
    /// `null` — the three shapes a mis-authored artifact reaches a decoder in. Returns
    /// `nil` when there is no such member, so a test cannot assert against an unmutated
    /// payload.
    static func replacingTopLevelMember(
        _ key: String,
        with value: String,
        in payload: String
    ) -> String? {
        guard let range = JSONMemberSplice.topLevelMemberRanges(in: payload)[key] else {
            return nil
        }
        return payload.replacingCharacters(in: range, with: "\"\(key)\":\(value)")
    }

    /// `payload` with a second `key` member carrying `value`.
    ///
    /// A duplicate key cannot be produced through a serializer, whose input is a
    /// dictionary. It has to be spliced in, which is the shape a mis-authored or tampered
    /// artifact arrives in.
    static func duplicatingTopLevelMember(
        _ key: String,
        withValue value: String,
        placing placement: Placement,
        in payload: String
    ) -> String? {
        guard JSONMemberSplice.topLevelMemberRanges(in: payload)[key] != nil,
              payload.hasPrefix("{"),
              payload.hasSuffix("}")
        else {
            return nil
        }
        let member = "\"\(key)\":\(value)"
        switch placement {
        case .first: return "{\(member),\(payload.dropFirst())"
        case .last: return "\(payload.dropLast()),\(member)}"
        }
    }
}

// MARK: - Malformed policy encodings

@Suite("Calibration Policy payload mutations")
struct CalibrationPolicyPayloadMutationTests {
    private let decoder = BoundedArtifactDecoder(limits: .testing())

    /// The fault a payload produced, or a recorded issue when it was accepted.
    private func fault(
        _ bytes: [UInt8],
        using bounded: BoundedArtifactDecoder? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ArtifactDecodingError {
        let outcome: ArtifactDecodingError?
        do {
            _ = try (bounded ?? decoder).decode(CalibrationPolicy.self, from: bytes)
            outcome = nil
        } catch {
            outcome = error
        }
        return try #require(
            outcome,
            "the Calibration Policy accepted the mutated payload",
            sourceLocation: sourceLocation
        )
    }

    private func fault(
        _ payload: String,
        using bounded: BoundedArtifactDecoder? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ArtifactDecodingError {
        try fault(Array(payload.utf8), using: bounded, sourceLocation: sourceLocation)
    }

    @Test("Re-serializing a policy payload is itself a mutation of two governed decimals")
    func reSerializingPerturbsTheGovernedDecimals() throws {
        let policy = try Sample.calibrationPolicy()
        let canonical = try CanonicalArtifactPayload.bytes(policy)

        // The positive control: the encoder's own bytes are the same policy back.
        #expect(try decoder.decode(CalibrationPolicy.self, from: canonical) == policy)

        // The `JSONSerialization` round trip the payload mutators perform, with nothing
        // removed, replaced, or added.
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(canonical)) as? [String: Any]
        )
        let reserialized = Array(
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
        #expect(
            object.keys.sorted() == (try CanonicalArtifactPayload.topLevelKeys(policy)),
            "the round trip changed the key set, so it is not only the decimals"
        )

        // Same members, same key set, and refused anyway: the round trip moved the
        // confidence level off the value Requirement 5.15 predeclares.
        guard case let .schemaViolation(path, error) = try fault(reserialized) else {
            Issue.record("expected the re-serialized payload to be refused")
            return
        }
        #expect(path == "releasePassRule")
        guard case let .fixedValueMismatch(field, expected, found) = error else {
            Issue.record("unexpected fault for the re-serialized payload: \(error)")
            return
        }
        #expect(field == "passRule.confidenceLevel")
        #expect(expected == "\(FalseAccusationPassRule.requiredConfidenceLevel)")
        #expect(found != expected, "the round trip left the level exact after all")

        // So a per-member removal performed through that round trip is refused whether or
        // not the removed member was required, and an assertion that only requires "some
        // decoding error" over it holds vacuously. Every removal below is spliced out of
        // the payload text instead, which leaves the decimals byte-identical.
        let spliced = try #require(
            PolicyPayloadSplice.removingTopLevelMember(
                "boundaries",
                from: try CanonicalArtifactPayload.text(policy)
            )
        )
        #expect(try fault(spliced) == .missingRequiredField(path: "boundaries"))
    }

    @Test("Dropping any member of a policy payload is reported as that member being absent")
    func everyMemberIsRequiredAndNamed() throws {
        let policy = try Sample.calibrationPolicy(qualityRules: [Sample.qualityRule()])
        let payload = try CanonicalArtifactPayload.text(policy)

        // The positive control: the untouched text decodes to the identical policy, so
        // every refusal below is about the member the splice removed.
        #expect(try decoder.decode(CalibrationPolicy.self, from: Array(payload.utf8)) == policy)

        let keys = try CanonicalArtifactPayload.topLevelKeys(policy)
        #expect(keys.count == 17, "a Calibration Policy member was added or removed: \(keys)")

        for key in keys {
            let mutated = try #require(
                PolicyPayloadSplice.removingTopLevelMember(key, from: payload),
                "\(key) was not a top-level member of the encoded policy"
            )
            #expect(
                JSONMemberSplice.topLevelMemberRanges(in: mutated)[key] == nil,
                "splicing left \(key) in the payload"
            )
            #expect(
                try fault(mutated) == .missingRequiredField(path: key),
                "removing \(key) was not reported as \(key) being absent"
            )
        }
    }

    @Test("A duplicated budget key would read as two different budgets, so it is refused")
    func aDuplicatedBudgetKeyIsRefusedAtEitherPlacement() throws {
        let policy = try Sample.calibrationPolicy()
        let payload = try CanonicalArtifactPayload.text(policy)

        // The other spelling is a valid budget too: 1.0% is the ceiling Requirement 5.1
        // fixes, so both occurrences decode and the payload reads as a whole policy
        // either way. That is what makes the duplicate dangerous rather than merely
        // malformed.
        let ceiling = "\(FalseAccusationBudget.maximumRate)"
        var resolved: [CalibrationPolicy] = []

        for placement in PolicyPayloadSplice.Placement.allCases {
            let duplicated = try #require(
                PolicyPayloadSplice.duplicatingTopLevelMember(
                    "falseAccusationBudget",
                    withValue: ceiling,
                    placing: placement,
                    in: payload
                )
            )
            // A general-purpose decoder resolves the duplicate silently and hands back a
            // policy, with no indication that the bytes were ambiguous.
            resolved.append(
                try JSONDecoder().decode(CalibrationPolicy.self, from: Data(duplicated.utf8))
            )
            // The bounded profile refuses it at the key, before any field is read.
            #expect(
                try fault(duplicated)
                    == .duplicateKey(path: "<root>", key: "falseAccusationBudget"),
                "the duplicate at \(placement) was not refused as a duplicate key"
            )
        }

        // Which occurrence won decided the harm-control number, from one key set. A
        // release signature over these bytes would no longer pin the budget.
        #expect(resolved.count == 2)
        #expect(resolved[0] != resolved[1])
        #expect(
            resolved.filter { $0.falseAccusationBudget == policy.falseAccusationBudget }.count
                == 1,
            "exactly one placement should read the signed budget"
        )
    }

    @Test("A weakened or malformed member is refused, and the fault names that member")
    func aMalformedMemberIsRefusedAtThatMember() throws {
        let policy = try Sample.calibrationPolicy()
        let payload = try CanonicalArtifactPayload.text(policy)

        // Requirement 5.9's sub-440 rule, weakened by one pixel. Reported at the document
        // root because the whole-policy invariant is what failed, with the schema fault
        // naming the field.
        #expect(
            try fault(
                try #require(
                    PolicyPayloadSplice.replacingTopLevelMember(
                        "minimumShortEdge",
                        with: "439",
                        in: payload
                    )
                )
            )
                == .schemaViolation(
                    path: "<root>",
                    error: .fixedValueMismatch(
                        field: "minimumShortEdge",
                        expected: "\(CalibrationPolicy.requiredMinimumShortEdge)",
                        found: "439"
                    )
                )
        )

        // Requirement 5.1's ceiling, exceeded. Reported at the member, because the budget
        // validates itself.
        guard case let .schemaViolation(budgetPath, budgetError) = try fault(
            try #require(
                PolicyPayloadSplice.replacingTopLevelMember(
                    "falseAccusationBudget",
                    with: "0.02",
                    in: payload
                )
            )
        ) else {
            Issue.record("expected a budget above the ceiling to be refused")
            return
        }
        #expect(budgetPath == "falseAccusationBudget")
        guard case let .valueOutOfRange(budgetField, _, _) = budgetError else {
            Issue.record("unexpected fault for an over-ceiling budget: \(budgetError)")
            return
        }
        #expect(budgetField == "falseAccusationBudget")

        // Requirement 5.13's compatibility reference, in the three shapes that never form
        // an identifier at all. Each one is a different audit finding: the wrong kind of
        // value, an undecided value, and a value this build cannot interpret.
        guard case let .typeMismatch(mistypedPath, expected) = try fault(
            try #require(
                PolicyPayloadSplice.replacingTopLevelMember(
                    "compatiblePreprocessing",
                    with: "42",
                    in: payload
                )
            )
        ) else {
            Issue.record("expected a numeric compatibility reference to be refused")
            return
        }
        #expect(mistypedPath == "compatiblePreprocessing")
        #expect(expected.contains("String"))

        #expect(
            try fault(
                try #require(
                    PolicyPayloadSplice.replacingTopLevelMember(
                        "compatiblePreprocessing",
                        with: "null",
                        in: payload
                    )
                )
            )
                == .nullRequiredField(path: "compatiblePreprocessing")
        )

        guard case let .valueRejected(rejectedPath, _) = try fault(
            try #require(
                PolicyPayloadSplice.replacingTopLevelMember(
                    "compatiblePreprocessing",
                    with: "\"has space\"",
                    in: payload
                )
            )
        ) else {
            Issue.record("expected a noncanonical compatibility reference to be refused")
            return
        }
        #expect(rejectedPath == "compatiblePreprocessing")
    }

    @Test("The approved payload ceiling is applied before any member is read")
    func theCeilingPrecedesEveryMemberFault() throws {
        let policy = try Sample.calibrationPolicy()
        // A payload that is *also* invalid at a member, so the two layers have something
        // to disagree about.
        let weakened = try #require(
            PolicyPayloadSplice.replacingTopLevelMember(
                "minimumShortEdge",
                with: "439",
                in: try CanonicalArtifactPayload.text(policy)
            )
        )
        let bytes = Array(weakened.utf8)
        let size = UInt64(bytes.count)

        // One byte of ceiling short, and the ceiling is the reported cause.
        #expect(
            try fault(
                bytes,
                using: BoundedArtifactDecoder(limits: .testing(maximumBytes: size - 1))
            )
                == .payloadTooLarge(limitBytes: size - 1, actualBytes: size)
        )

        // One byte more, and the member fault is reported instead, so the ceiling was an
        // earlier gate rather than the only one.
        guard case let .schemaViolation(_, error) = try fault(
            bytes,
            using: BoundedArtifactDecoder(limits: .testing(maximumBytes: size))
        ) else {
            Issue.record("expected the weakened member to be refused inside the ceiling")
            return
        }
        #expect(
            error
                == .fixedValueMismatch(
                    field: "minimumShortEdge",
                    expected: "\(CalibrationPolicy.requiredMinimumShortEdge)",
                    found: "439"
                )
        )
    }
}

// MARK: - Mismatched capability sets

@Suite("Startup preflight capability set mutations")
struct StartupPreflightCapabilitySetMutationTests {
    @Test("A module graph missing an approved capability is refused, like an extra one")
    func aCompositionMissingAnApprovedCapabilityIsRefused() async throws {
        // The manifest approves provenance, the entry's gate evidence was produced with
        // provenance enabled, and the graph links a validator — but the composition does
        // not compile the capability. Set equality is what Requirement 6.2 asks for, so
        // this fails for the same reason an extra capability does (Requirement 1.3: the
        // running build has to be the one the evidence describes).
        let scenario = try await PreflightSample.scenario(
            provenance: true,
            composition: PreflightSample.composition(
                identifier: "pixel-plus-provenance",
                capabilities: [.pixelAnalysis],
                linksValidator: true
            )
        )
        await expectRefusal(scenario) { failure in
            failure
                == .capabilitySetMismatch(
                    approved: ["content-credential-validation", "pixel-analysis"],
                    compiled: ["pixel-analysis"]
                )
        }
    }
}

// MARK: - Mixed version tuples

@Suite("Startup preflight version mixing")
struct StartupPreflightVersionMixingTests {
    @Test("A fusion rule approved against another fixture suite cannot admit this build")
    func aFusionRuleFromAnotherFixtureSuiteIsRefused() async throws {
        // One release binds one Release Fixture Suite version (Requirement 13.17), so the
        // suite that demonstrated all fifteen fusion dispositions is the suite the device
        // gates ran against. Two versions here means the fusion approval and the device
        // evidence describe different releases (Requirement 13.20).
        let scenario = try await PreflightSample.scenario(provenance: true, fusion: true)
        await scenario.policies.register(
            try EvidenceFusionRule(
                id: Sample.artifact("rule.fusion"),
                schemaVersion: .v1,
                ruleVersion: Sample.version(),
                compatibleVerdictCopy: Sample.artifact("copy.compatibility"),
                fixtureSuite: Sample.artifact("suite.other"),
                entries: Sample.fusionEntries(),
                approval: Sample.approval()
            )
        )
        await expectRefusal(scenario) { failure in
            failure
                == .identityMismatch(
                    field: "fusionRule.fixtureSuite",
                    expected: "suite.fixtures",
                    found: "suite.other"
                )
        }
    }
}

// MARK: - Absent approvals

@Suite("Startup preflight approval mutations")
struct StartupPreflightApprovalMutationTests {
    @Test("A rejected Approved Verdict Copy approval blocks ingest")
    func aRejectedCopyApprovalBlocksIngest() async throws {
        // The catalogue resolves, declares the compatibility identifier the manifest
        // names, and carries a rejection. Presence is not approval (Requirement 14.15).
        let scenario = try await PreflightSample.scenario()
        await scenario.policies.register(
            try ApprovedVerdictCopyCatalog(
                id: Sample.artifact("catalog.verdict-copy"),
                schemaVersion: .v1,
                compatibilityID: Sample.artifact("copy.compatibility"),
                languageTag: Sample.text(ApprovedVerdictCopyCatalog.requiredLanguageTag),
                entries: Sample.copyEntries(),
                approval: Sample.approval(.rejected)
            )
        )
        await expectRefusal(scenario) { failure in
            failure
                == .unapprovedArtifact(
                    field: "verdictCopyCatalog.approval",
                    decision: .rejected
                )
        }
    }

    @Test("A rejected Evidence Fusion Rule approval blocks ingest")
    func aRejectedFusionApprovalBlocksIngest() async throws {
        // A rule that is schema-valid and complete over all fifteen combinations still
        // needs its own approval: linking fusion is not approval to enable it.
        let scenario = try await PreflightSample.scenario(provenance: true, fusion: true)
        await scenario.policies.register(
            try EvidenceFusionRule(
                id: Sample.artifact("rule.fusion"),
                schemaVersion: .v1,
                ruleVersion: Sample.version(),
                compatibleVerdictCopy: Sample.artifact("copy.compatibility"),
                fixtureSuite: Sample.artifact("suite.fixtures"),
                entries: Sample.fusionEntries(),
                approval: Sample.approval(.rejected)
            )
        )
        await expectRefusal(scenario) { failure in
            failure == .unapprovedArtifact(field: "fusionRule.approval", decision: .rejected)
        }
    }

    @Test("An applicable mandatory gate with no result, or one recorded off device, blocks")
    func anUnexecutedOrOffDeviceGateBlocksLikeAFailingOne() async throws {
        // Requirement 14.15: a missing applicable mandatory result blocks exactly as a
        // failing one does. Requirement 13.16: a result from anything but a physical
        // iPhone is not release evidence, and recording one honestly leaves the gate
        // unsatisfied rather than making it unrepresentable.
        let gate = DeviceGate.warmAnalysisLatency
        for (outcome, environment) in [
            (GateOutcome.notExecuted, ExecutionEnvironment.physicalIPhone),
            (.failed, .iOSSimulator),
            (.failed, .developmentMac),
        ] as [(GateOutcome, ExecutionEnvironment)] {
            let scenario = try await PreflightSample.scenario(
                allowlist: try PreflightSample.allowlist(
                    entries: [
                        try ApprovedDeviceConfiguration(
                            id: Sample.configuration(),
                            configuration: try PreflightSample.candidate(),
                            versionTuple: try PreflightSample.versionTuple(
                                capabilities: [.pixelAnalysis]
                            ),
                            gateEvidence: try pixelOnlyGateEvidence(
                                replacing: gate,
                                outcome: outcome,
                                environment: environment
                            )
                        ),
                        // A distributable sibling, so Requirement 13.22's whole-set
                        // finding does not pre-empt the one about this device.
                        try PreflightSample.entry(
                            identifier: "configuration.other",
                            capabilities: [.pixelAnalysis],
                            hardware: PreflightSample.unlistedHardware
                        ),
                    ]
                )
            )
            await expectRefusal(scenario) { failure in
                failure
                    == .unsatisfiedDeviceGates(
                        configuration: Sample.configuration(),
                        gates: [gate]
                    )
            }
        }
    }

    /// Coherent pixel-only gate evidence with one applicable gate's result replaced.
    ///
    /// Built here rather than through ``Sample/gateReferences(provenanceEnabled:failing:gates:)``,
    /// which records every applicable gate as passing on a physical iPhone or failing on
    /// one: neither shape can express a gate that was never executed.
    private func pixelOnlyGateEvidence(
        replacing replaced: DeviceGate,
        outcome: GateOutcome,
        environment: ExecutionEnvironment
    ) throws -> [GateResultReference] {
        #expect(
            !replaced.isProvenanceConditional,
            "a pixel-only entry declares the conditional gate inapplicable"
        )
        return try DeviceGate.mandatoryGates.sorted { $0.rawValue < $1.rawValue }.map { gate in
            let applicable = !gate.isProvenanceConditional
            return try GateResultReference(
                gate: gate,
                applicability: applicable ? .applicable : Sample.notApplicable(),
                outcome: gate == replaced
                    ? outcome
                    : (applicable ? .passed : .notExecuted),
                result: Sample.evidence("evidence.device.\(gate.rawValue)"),
                environment: gate == replaced ? environment : .physicalIPhone
            )
        }
    }
}

// MARK: - Missing cleanup completion

/// A cleanup port that returns exactly the receipts a test hands it.
///
/// ``FakeSessionDataDeleter`` derives every receipt from the policy it is passed, so it
/// cannot express a cleanup that completed under different terms. That is the distinction
/// Requirement 9.9 turns on: a call that returned is not the same as material removed
/// under the deadlines this release approved.
private struct FixedReceiptSessionDataDeleter: SessionDataDeleting {
    let receipts: [SessionDeletionReceipt]

    func deleteSession(
        _ id: AnalysisSessionID,
        reason: SessionEndReason,
        policy: DataLifecyclePolicy
    ) async throws(EphemeralStoreError) -> SessionDeletionReceipt {
        // Startup cleanup is a sweep, not a per-session deletion. Failing here rather
        // than succeeding means a gate that called the wrong member is visible.
        throw .storeUnavailable
    }

    func deleteAbandonedData(
        policy: DataLifecyclePolicy
    ) async throws(EphemeralStoreError) -> [SessionDeletionReceipt] {
        receipts
    }
}

@Suite("Startup cleanup completion")
struct StartupCleanupCompletionTests {
    @Test("A sweep that completed under the bound policy admits ingest")
    func aWellFormedReceiptIsAdmitted() async throws {
        // The positive control for every refusal below: only the mutated member differs.
        let scenario = try await PreflightSample.scenario()
        let expected = try receipt()
        let admission = try await run(scenario, returning: [expected])
        #expect(admission.startupCleanup == [expected])
    }

    @Test("A receipt naming another Data Lifecycle Policy keeps ingest closed")
    func aReceiptUnderAnotherPolicyKeepsIngestClosed() async throws {
        let scenario = try await PreflightSample.scenario()
        await expectRefusal(
            scenario,
            returning: [try receipt(lifecyclePolicy: "policy.other")]
        ) { failure in
            failure
                == .identityMismatch(
                    field: "startupCleanup.receipt.lifecyclePolicyID",
                    expected: "policy.lifecycle",
                    found: "policy.other"
                )
        }
    }

    @Test("A receipt for a reason other than abandonment keeps ingest closed")
    func aReceiptForAnotherReasonKeepsIngestClosed() async throws {
        // Startup cleanup removes material found with no live session and no terminal
        // receipt, which is exactly the `abandoned` reason. A receipt under any other
        // reason describes a different deletion, so the sweep this gate required has not
        // been shown to have happened.
        for reason in SessionCleanupReason.allCases where reason != .abandoned {
            let scenario = try await PreflightSample.scenario()
            await expectRefusal(scenario, returning: [try receipt(reason: reason)]) { failure in
                failure
                    == .identityMismatch(
                        field: "startupCleanup.receipt.reason",
                        expected: SessionCleanupReason.abandoned.rawValue,
                        found: reason.rawValue
                    )
            }
        }
    }

    @Test("A receipt under a deadline the bound policy does not set keeps ingest closed")
    func aReceiptUnderAnotherDeadlineKeepsIngestClosed() async throws {
        let scenario = try await PreflightSample.scenario()
        let other = Sample.duration(milliseconds: 60_000)
        #expect(other != Sample.duration())
        await expectRefusal(scenario, returning: [try receipt(deadline: other)]) { failure in
            failure
                == .identityMismatch(
                    field: "startupCleanup.receipt.deadline",
                    expected: "\(Sample.duration().milliseconds) ms",
                    found: "\(other.milliseconds) ms"
                )
        }
    }

    @Test("A store failure keeps ingest closed and reports no analysis outcome")
    func aFailedSweepCarriesNoAnalysisOutcome() async throws {
        // Unremoved bytes from an interrupted session are a privacy failure, not an
        // evidence result. The refusal has to name cleanup and carry nothing a Result
        // Presenter could render (Requirements 9.9 and 11.16).
        let scenario = try await PreflightSample.scenario()
        let failure = try await refusal(scenario, cleanup: FailingSessionDataDeleter())
        #expect(failure == .startupCleanupFailed(.protectionUnavailable(.complete)))
        #expect(EvidenceReachabilityAudit.evidencePaths(in: failure).isEmpty)
        #expect(analysisOutcomePaths(in: failure).isEmpty, "\(failure) exposes an analysis outcome")
    }

    /// A cleanup port that fails the sweep the way a data-protection fault would.
    private struct FailingSessionDataDeleter: SessionDataDeleting {
        func deleteSession(
            _ id: AnalysisSessionID,
            reason: SessionEndReason,
            policy: DataLifecyclePolicy
        ) async throws(EphemeralStoreError) -> SessionDeletionReceipt {
            throw .protectionUnavailable(.complete)
        }

        func deleteAbandonedData(
            policy: DataLifecyclePolicy
        ) async throws(EphemeralStoreError) -> [SessionDeletionReceipt] {
            throw .protectionUnavailable(.complete)
        }
    }

    /// A receipt describing a completed startup sweep, with one member overridable.
    private func receipt(
        session: String = "session.abandoned",
        reason: SessionCleanupReason = .abandoned,
        lifecyclePolicy: String = "policy.lifecycle",
        deadline: ValidatedDuration = Sample.duration()
    ) throws -> SessionDeletionReceipt {
        SessionDeletionReceipt(
            sessionID: try #require(AnalysisSessionID(session)),
            reason: reason,
            lifecyclePolicyID: Sample.artifact(lifecyclePolicy),
            deadline: deadline,
            removedObjectCount: 1,
            completedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
    }

    private func run(
        _ scenario: PreflightScenario,
        returning receipts: [SessionDeletionReceipt]
    ) async throws(PreflightFailure) -> ReleaseAdmission {
        try await scenario.preflight.run(
            policies: scenario.policies,
            bundles: scenario.bundles,
            cleanup: FixedReceiptSessionDataDeleter(receipts: receipts)
        )
    }

    private func expectRefusal(
        _ scenario: PreflightScenario,
        returning receipts: [SessionDeletionReceipt],
        sourceLocation: SourceLocation = #_sourceLocation,
        _ predicate: (PreflightFailure) -> Bool
    ) async {
        do {
            _ = try await run(scenario, returning: receipts)
            Issue.record("expected the startup gate to refuse", sourceLocation: sourceLocation)
        } catch {
            #expect(
                predicate(error),
                "unexpected failure: \(error)",
                sourceLocation: sourceLocation
            )
        }
    }

    private func refusal(
        _ scenario: PreflightScenario,
        cleanup: some SessionDataDeleting
    ) async throws -> PreflightFailure {
        do {
            _ = try await scenario.preflight.run(
                policies: scenario.policies,
                bundles: scenario.bundles,
                cleanup: cleanup
            )
        } catch {
            return error
        }
        throw UnexpectedAdmission()
    }
}

// MARK: - No verified active Model Bundle

@Suite("Startup Model Bundle availability")
struct StartupModelBundleAvailabilityTests {
    @Test("No verified active bundle is a model-load error below the gate and never above it")
    func noVerifiedActiveBundleIsAModelLoadError() async throws {
        let scenario = try await PreflightSample.scenario(activateBundle: false)
        #expect(await scenario.bundles.activeBundle() == nil)

        // Requirement 10.16, at the layer that owns it: with no verified compatible
        // bundle active, the bundle port refuses to supply one and names the single
        // Analysis Error the requirement fixes, at the stage it was detected. Nothing
        // older or unverified is substituted.
        let context = try #require(
            ReleaseContext(
                device: PreflightSample.device(),
                approvedConfiguration: Sample.configuration(),
                capabilityManifestID: Sample.artifact("manifest.capability"),
                compiledCapabilities: [.pixelAnalysis]
            )
        )
        await #expect(throws: AnalysisFault.analysis(.modelLoadError, stage: .modelLoad)) {
            _ = try await scenario.bundles.verifiedActiveBundle(for: context)
        }

        // The positive control for the audit used below: that same port fault *does*
        // carry an analysis outcome and is reported as carrying one, so the emptiness
        // assertions that follow are about the startup failure rather than about a walk
        // that finds nothing anywhere.
        #expect(
            !analysisOutcomePaths(
                in: AnalysisFault.analysis(.modelLoadError, stage: .modelLoad)
            ).isEmpty
        )

        // Above it, the startup gate deliberately drops that fault. A failed gate has no
        // session and no stage, so surfacing one as an analysis outcome would invent a
        // user-facing evidence error the requirements do not define.
        await scenario.bundles.failActivation(of: Sample.bundle(), at: .modelLoad)
        let failure = try await refusal(scenario)
        #expect(failure == .verifiedBundleUnavailable(expected: Sample.bundle()))
        #expect(EvidenceReachabilityAudit.evidencePaths(in: failure).isEmpty)
        #expect(
            analysisOutcomePaths(in: failure).isEmpty,
            "\(failure) exposes an analysis outcome"
        )
        // And nothing became active, so a later inference cannot find a half-activated
        // tuple to use.
        #expect(await scenario.bundles.activeBundle() == nil)
    }

    private func refusal(_ scenario: PreflightScenario) async throws -> PreflightFailure {
        do {
            _ = try await scenario.run()
        } catch {
            return error
        }
        throw UnexpectedAdmission()
    }
}

// MARK: - Shared helpers

/// Raised when a scenario that was expected to be refused was admitted instead.
private struct UnexpectedAdmission: Error {}

/// Runs a scenario and requires it to fail a gate matching `predicate`.
private func expectRefusal(
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

/// Paths at which an analysis outcome is reachable from `value`.
///
/// Declared types count, matching ``EvidenceReachabilityAudit``: the claim is about shape,
/// so a field that *could* carry an Analysis Error is reported even when it holds nothing.
private func analysisOutcomePaths(in value: Any) -> [String] {
    let forbidden: Set<String> = ["AnalysisError", "AnalysisFault", "AnalysisStage"]
    var found: [String] = []
    DomainValueWalk.visit(value, rootName: "failure") { path, child in
        let tokens = DomainValueWalk.typeNameTokens(of: type(of: child))
        if !tokens.isDisjoint(with: forbidden) { found.append(path) }
    }
    return found
}
