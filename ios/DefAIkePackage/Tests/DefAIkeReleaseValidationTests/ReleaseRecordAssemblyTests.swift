import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// Joining twelve kinds of evidence into one release record, and what the record says today.
//
// The sibling tasks each produce one kind of evidence. This suite tests the *join*: which gate
// reads which evidence, what an absent kind does to the gate that reads it, whether a passing
// gate can sit beside a failing input, and what the record reports in the state this repository
// is actually in.
//
// **No identifier, version, approval, tolerance, limit, sample count, configuration, or version
// tuple anywhere in this file is an approved release value.** Every one is synthetic scaffolding
// built by `Sample`. There is no approved `DeviceValidationPlan`, no signed
// `ReleaseFixtureSuite`, none of the 96 model-parity fixtures, no signed Model Bundle, no
// approved calibration release, no root licence file, no governance decision, and no physical
// iPhone: only the iOS 26.5 simulator runtime exists. So every device gate is genuinely
// unsatisfiable and the generated allowlist is genuinely empty, and this suite asserts that as
// the correct reported state rather than working around it.

// MARK: - Gate routing

/// Which evidence answers which gate, and that the routing is total.
@Suite("Release record: gate routing")
struct ReleaseRecordGateRoutingTests {

    @Test("Every release gate reads at least one of the twelve joined evidence kinds")
    func everyGateReadsAJoinedKind() {
        #expect(ReleaseRecordEvidenceKind.allCases.count == 12)
        #expect(ReleaseGate.allCases.count == 26)
        for gate in ReleaseGate.allCases {
            let kinds = gate.contributingEvidenceKinds
            #expect(!kinds.isEmpty, "\(gate.rawValue) reads no evidence")
        }
    }

    @Test("Every one of the twelve kinds is read by at least one gate")
    func everyKindIsRead() {
        var read: Set<ReleaseRecordEvidenceKind> = []
        for gate in ReleaseGate.allCases {
            read.formUnion(gate.contributingEvidenceKinds)
        }
        let unread = Set(ReleaseRecordEvidenceKind.allCases).subtracting(read)
        #expect(unread.isEmpty, "an evidence kind no gate reads is a kind nothing gates on")
    }

    @Test("Every release gate attributes an absent result to a release-controlled input")
    func everyGateNamesTheInputItIsOwed() {
        var owed: Set<UnprovisionedReleaseRecordInput> = []
        for gate in ReleaseGate.allCases {
            owed.insert(gate.owedReleaseRecordInput)
        }
        // One case is not reachable through a gate: a gate that has its evidence and no citation
        // is owed the citation, which is recorded alongside whatever else that gate owes.
        let unreachable = Set(UnprovisionedReleaseRecordInput.allCases).subtracting(owed)
        let expected: Set<UnprovisionedReleaseRecordInput> = [.releaseGateEvidenceCitation]
        #expect(unreachable == expected)
    }

    @Test("The four bundle gates cover all six recorded bundle results exactly once")
    func bundleGateMappingIsTotalAndDisjoint() {
        var seen: [BundleReleaseGate] = []
        for gate in ReleaseGate.allCases {
            seen.append(contentsOf: gate.contributingBundleGates)
        }
        #expect(seen.count == BundleReleaseGate.allCases.count)
        #expect(Set(seen) == Set(BundleReleaseGate.allCases))
        // Requirement 14.13 names six recorded results; a mapping that dropped one would let a
        // failing self-test, activation, or rollback reach a record with nothing reading it.
        #expect(seen.count == 6)
    }
}

// MARK: - Fail-closed on an absent artifact

/// What an absent evidence kind does to the gates that read it.
@Suite("Release record: absent evidence fails closed")
struct ReleaseRecordAbsentEvidenceTests {

    @Test("With no evidence at all, every applicable mandatory gate is unresolved")
    func nothingSuppliedLeavesEveryGateUnresolved() throws {
        let assembled = ReleaseRecordAssembler().assemble(try Sample.recordEvidence())

        // Two gates read only the signed manifest, which is a required input, so they are the
        // only two that can produce a result with nothing else supplied.
        let manifestBacked: Set<ReleaseGate> = [.capabilityManifestMatch]
        for entry in assembled.gateEvidence where entry.applicability.isApplicable {
            if manifestBacked.contains(entry.gate) { continue }
            #expect(
                entry.outcome == GateOutcome.notExecuted,
                "\(entry.gate.rawValue) produced a result with no evidence"
            )
        }
        #expect(!assembled.permitsDistribution)
    }

    @Test("An absent kind names the release-controlled input it is owed from")
    func absentKindNamesItsOwedInput() throws {
        let assembled = ReleaseRecordAssembler().assemble(try Sample.recordEvidence())
        let owed = Set(assembled.unprovisionedInputs)
        let expected: Set<UnprovisionedReleaseRecordInput> = [
            .approvedCalibrationRelease,
            .regeneratedCorpusRemediationEvidence,
            .producedModelBundleReleaseEvidence,
            .archiveAuditReleaseInputDocument,
            .accessibilityAndLocalizationMatrixRun,
            .coherentPhysicalDeviceEvidenceSet,
            .approvedDistributionRightsRecords,
            .recordedModelGovernanceDecision,
            .signedReleaseFixtureSuiteInventory,
            .publishedLimitationsAndCorrectionChannel,
        ]
        #expect(owed == expected)
        // The manifest is supplied, so its input is not owed; the citations are supplied, so
        // neither is theirs.
        #expect(!owed.contains(.signedReleaseCapabilityManifest))
        #expect(!owed.contains(.releaseGateEvidenceCitation))
    }

    @Test("A gate with evidence but no citation is unresolved and owes the citation")
    func evidenceWithoutACitationIsUnresolved() throws {
        var citations: [ReleaseGate: EvidenceSource] = [:]
        for gate in ReleaseGate.allCases where gate != .capabilityManifestMatch {
            citations[gate] = Sample.matrixEvidence("result.\(gate.rawValue)", digest: 0xC0)
        }
        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(gateCitations: citations)
        )
        let entry = assembled.gate(.capabilityManifestMatch)
        #expect(entry.citation == nil)
        #expect(entry.outcome == GateOutcome.notExecuted)
        #expect(entry.unprovisionedInputs.contains(.releaseGateEvidenceCitation))
        let unwritable = assembled.gatesNamingNoEvidence
        #expect(unwritable == Set([ReleaseGate.capabilityManifestMatch]))
    }

    @Test("An absent legal or governance record leaves its gate unresolved, never passing")
    func absentExternalRecordIsNeverAPass() throws {
        let assembled = ReleaseRecordAssembler().assemble(try Sample.recordEvidence())
        for gate in [
            ReleaseGate.repositoryCodeLicense,
            .dataDistributionRights,
            .modelGovernanceDecision,
        ] {
            let entry = assembled.gate(gate)
            #expect(entry.outcome == GateOutcome.notExecuted)
            #expect(!entry.isSatisfied)
        }
        // Two of the three are hard public-launch blockers by name; all three block by
        // Requirement 14.15 regardless.
        #expect(
            assembled.blockingHardPublicLaunchBlockers.contains(.modelGovernanceDecision)
        )
    }

    @Test("A rejected legal decision fails its gate rather than leaving it unresolved")
    func rejectedDecisionFailsRatherThanMissing() throws {
        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(
                distributionRights: Sample.distributionRights(codeLicense: .rejected)
            )
        )
        let licence = assembled.gate(.repositoryCodeLicense)
        #expect(licence.outcome == GateOutcome.failed)
        #expect(!licence.isSatisfied)
        let terms = assembled.gate(.dataDistributionRights)
        #expect(terms.outcome == GateOutcome.passed)
        // A rejection is a failure, not a missing result, and the two stay distinguishable.
        #expect(assembled.failingMandatoryGates.contains(.repositoryCodeLicense))
        #expect(!assembled.unresolvedMandatoryGates.contains(.repositoryCodeLicense))
    }

    @Test("An unconditional gate cannot be satisfied by a waiver")
    func unconditionalGateCannotBeWaived() throws {
        // Every gate the assembler produces for an unconditional case is applicable, and
        // `isSatisfied` refuses a waiver for one even if a future change supplied it.
        let waived = ReleaseGateEvidence(
            gate: .repositoryCodeLicense,
            applicability: Sample.notApplicable(),
            citation: Sample.evidence("result.licence"),
            contributingKinds: [.legal],
            findings: [],
            unprovisionedInputs: [],
            evidenceWasProduced: true
        )
        #expect(waived.outcome == GateOutcome.notExecuted)
        #expect(!waived.isSatisfied)
        // And the schema refuses the entry outright, which is the second barrier.
        #expect(throws: (any Error).self) { try waived.releaseGateRecord() }
    }
}

// MARK: - A passing gate cannot sit beside a failing input

/// The structural claim: the outcome and the findings are one expression.
@Suite("Release record: a passing gate beside a failing input is unrepresentable")
struct ReleaseRecordDerivedOutcomeTests {

    /// Assemblies spanning every combination of "this kind is supplied" that the samples can
    /// build without an approved artifact.
    static func assemblies() throws -> [AssembledReleaseRecord] {
        let assembler = ReleaseRecordAssembler()
        var built: [AssembledReleaseRecord] = []
        built.append(assembler.assemble(try Sample.recordEvidence()))
        built.append(
            assembler.assemble(
                try Sample.recordEvidence(archive: Sample.archiveAuditReport())
            )
        )
        built.append(
            assembler.assemble(
                try Sample.recordEvidence(
                    archive: Sample.archiveAuditReport(
                        findings: [
                            ArchiveAuditFinding(
                                failingInputClass: .noticeGap,
                                detail: "DefAIke.app carries no notice file"
                            )
                        ]
                    )
                )
            )
        )
        built.append(
            assembler.assemble(
                try Sample.recordEvidence(archive: Sample.archiveAuditReport(inspected: false))
            )
        )
        built.append(
            assembler.assemble(
                try Sample.recordEvidence(
                    distributionRights: Sample.distributionRights(),
                    activeLimitations: Sample.evidence("document.limitations"),
                    correctionChannel: Sample.evidence("document.correction-channel")
                )
            )
        )
        let device = try Sample.coherentDeviceEvidence()
        built.append(
            assembler.assemble(
                try Sample.recordEvidence(
                    matrix: try Sample.joinedMatrixReport(
                        plan: try Sample.joinedPlan(),
                        versionTuple: try Sample.joinedTuple()
                    ),
                    deviceEvidence: [device]
                )
            )
        )
        return built
    }

    @Test("A gate reads passed if and only if it has a citation, a result, and no failing input")
    func passingIsExactlyTheAbsenceOfAFailingInput() throws {
        var examined = 0
        var passing = 0
        var failing = 0
        var missing = 0
        for assembled in try Self.assemblies() {
            for entry in assembled.gateEvidence {
                examined += 1
                let clean = entry.findings.isEmpty
                    && entry.unprovisionedInputs.isEmpty
                    && entry.citation != nil
                    && entry.evidenceWasProduced
                switch entry.outcome {
                case .passed:
                    passing += 1
                    #expect(clean, "\(entry.gate.rawValue) passed beside a failing input")
                    #expect(entry.applicability.isApplicable)
                case .failed:
                    failing += 1
                    #expect(!clean, "\(entry.gate.rawValue) failed with nothing failing")
                    #expect(entry.applicability.isApplicable)
                case .notExecuted:
                    missing += 1
                    let waived = !entry.applicability.isApplicable
                    #expect(
                        waived || entry.citation == nil || !entry.evidenceWasProduced,
                        "\(entry.gate.rawValue) has a result and is still not executed"
                    )
                }
            }
        }
        // Counted-work floors, so a change that made the loop examine nothing is a failure
        // rather than a pass. Twenty-six gates over six assemblies.
        #expect(examined == 26 * 6)
        #expect(passing + failing + missing == examined)
        #expect(passing > 0, "no gate passed in any assembly, so the pass arm never ran")
        #expect(failing > 0, "no gate failed in any assembly, so the fail arm never ran")
        #expect(missing > 0, "no gate was missing in any assembly")
    }

    @Test("Adding one archive finding turns exactly that gate from passed to failed")
    func oneFindingFlipsExactlyOneGate() throws {
        let assembler = ReleaseRecordAssembler()
        let clean = assembler.assemble(
            try Sample.recordEvidence(archive: Sample.archiveAuditReport())
        )
        #expect(clean.gate(.dependencyNotices).outcome == GateOutcome.passed)
        #expect(clean.gate(.archiveAudit).outcome == GateOutcome.passed)

        let withGap = assembler.assemble(
            try Sample.recordEvidence(
                archive: Sample.archiveAuditReport(
                    findings: [
                        ArchiveAuditFinding(
                            failingInputClass: .noticeGap,
                            detail: "no root notice file"
                        )
                    ]
                )
            )
        )
        #expect(withGap.gate(.dependencyNotices).outcome == GateOutcome.failed)
        #expect(withGap.gate(.archiveAudit).outcome == GateOutcome.passed)
        #expect(withGap.gate(.corpusExclusion).outcome == GateOutcome.passed)
        #expect(withGap.gate(.privacyAudit).outcome == GateOutcome.passed)
        // The audit's own class identifier travels verbatim rather than being re-templated.
        let detail = withGap.gate(.dependencyNotices).findings.map(\.description).joined()
        #expect(detail.contains("notice-gap"))
        #expect(detail.contains("no root notice file"))
    }

    @Test("An audit that inspected nothing yields no result rather than a pass over nothing")
    func anAuditThatInspectedNothingCannotPass() throws {
        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(archive: Sample.archiveAuditReport(inspected: false))
        )
        for gate in [
            ReleaseGate.archiveAudit, .dependencyNotices, .corpusExclusion, .privacyAudit,
        ] {
            let entry = assembled.gate(gate)
            #expect(entry.outcome == GateOutcome.notExecuted)
            #expect(!entry.isSatisfied)
        }
    }

    @Test("This module's archive gate outcomes agree with task 14.6's derived outcomes")
    func archiveRoutingAgreesWithTheAuditsOwnDerivation() throws {
        let report = Sample.archiveAuditReport(
            findings: [
                ArchiveAuditFinding(failingInputClass: .corpusArtifact, detail: "corpus present"),
                ArchiveAuditFinding(
                    failingInputClass: .prohibitedCapability,
                    detail: "analytics symbol present"
                ),
            ]
        )
        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(archive: report)
        )
        // Two authorities on one measurement would be one too many, so the record's outcome is
        // required to equal the audit's own derived outcome gate by gate.
        for recorded in report.gates {
            let entry = assembled.gate(recorded.gate)
            #expect(
                entry.outcome == recorded.outcome,
                "\(recorded.gate.rawValue) disagrees with the audit's derived outcome"
            )
        }
        #expect(assembled.gate(.corpusExclusion).outcome == GateOutcome.failed)
        #expect(assembled.gate(.privacyAudit).outcome == GateOutcome.failed)
    }
}

// MARK: - Release output

/// When a record becomes a distributable payload, and when it refuses to.
@Suite("Release record: output is blocked while anything blocks")
struct ReleaseRecordOutputTests {

    @Test("With nothing supplied, the output refuses and names an unresolved gate")
    func nothingSuppliedRefusesTheOutput() throws {
        let assembled = ReleaseRecordAssembler().assemble(try Sample.recordEvidence())
        var refusal: ReleaseRecordOutputRefusal?
        do {
            _ = try assembled.releaseOutput()
        } catch {
            refusal = error as? ReleaseRecordOutputRefusal
        }
        let recorded = try #require(refusal)
        guard case let .mandatoryGatesUnresolved(gates) = recorded else {
            Issue.record("the first refusal must be the unresolved mandatory gates")
            return
        }
        #expect(!gates.isEmpty)
        #expect(gates.contains(.deviceAllowlist))
        #expect(gates.contains(.initialModelBundleSignature))
    }

    @Test("A gate naming no evidence refuses before any outcome is considered")
    func anUncitedGateRefusesFirst() throws {
        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(gateCitations: [:])
        )
        var refusal: ReleaseRecordOutputRefusal?
        do {
            _ = try assembled.releaseOutput()
        } catch {
            refusal = error as? ReleaseRecordOutputRefusal
        }
        let recorded = try #require(refusal)
        guard case let .gateNamesNoEvidence(gates) = recorded else {
            Issue.record("a gate with no citation must refuse before an outcome is read")
            return
        }
        #expect(gates.count == 26)
    }

    @Test("Zero passing device configurations blocks the output today")
    func zeroPassingConfigurationsBlocks() throws {
        let device = try Sample.coherentDeviceEvidence()
        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(deviceEvidence: [device])
        )
        #expect(assembled.allowlist.isEmpty)
        #expect(!assembled.allowlist.permitsDistribution)
        #expect(!assembled.permitsDistribution)
        let entry = assembled.gate(.deviceAllowlist)
        #expect(entry.outcome == GateOutcome.failed)
        let reasons = entry.findings.map(\.description).joined(separator: " | ")
        #expect(reasons.contains("no candidate iPhone configuration passes"))
    }

    @Test("The record states what it would not establish even with nothing blocking")
    func standingLimitsAreCarried() throws {
        let bare = ReleaseRecordAssembler().assemble(try Sample.recordEvidence())
        let bareLimits = Set(bare.standingLimits)
        let alwaysApplicable: Set<UnobservableReleaseRecordEvidence> = [
            .signatureStandInVerifiesUnderEveryDeclaredAlgorithm,
            .noJointlySatisfiableMandatoryDeviceGateSetExists,
            .dataLifecycleDeadlinesAreNotBoundToAnyRecordGate,
        ]
        #expect(bareLimits == alwaysApplicable)

        let device = try Sample.coherentDeviceEvidence()
        let withDevice = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(deviceEvidence: [device])
        )
        let deviceLimits = Set(withDevice.standingLimits)
        #expect(
            deviceLimits.contains(
                .recordCompletenessStatisticsCountReturnedRatherThanQualifyingSamples
            )
        )
        #expect(deviceLimits.count == 4)
    }
}
