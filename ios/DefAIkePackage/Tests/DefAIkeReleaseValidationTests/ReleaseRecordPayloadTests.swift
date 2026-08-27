import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// The one place a release payload is reached, and exactly what it took to get there.
//
// # Why this suite exists
//
// Task 14.8 recorded that no successful `releaseOutput()` existed anywhere: every path through it
// refuses, so ``ReleaseReadinessRecord`` construction, ``CanonicalArtifactEncoding`` over a record
// and an allowlist, and byte-reproducibility of the payload were exercised only as far as the
// first refusal. This suite closes that, and says precisely what it had to use.
//
// # THE DISCLOSURE
//
// **No evidence in this repository makes an iPhone configuration pass a device gate, and this
// suite does not pretend otherwise.** ``ReleasePipelineBaselineTests`` is the honest assembly: a
// complete synthetic evidence set reaches 21 of the 24 unconditional record gates and refuses on
// `device-allowlist`, `accessibility-matrix`, and `localization-readiness-matrix`, because every
// runner's gate result consults ``ObservedParityEnvironment/current``.
//
// The payload below is reached instead through **a defect this task pins and does not fix**:
//
//   * ``GateResultReference/isSatisfied`` answers `decision.isApproved` for a not-applicable gate;
//     and
//   * ``GateResultReference`` has **no** equivalent of ``ReleaseGateRecord``'s "an unconditional
//     gate cannot be declared not applicable" check.
//
// So an ``ApprovedDeviceConfiguration`` whose 22 mandatory gates are *all* declared inapplicable
// with an approved synthetic waiver constructs, reports `unsatisfiedGates.isEmpty`, and makes
// ``ReleaseApprovedDeviceAllowlist/permitsDistribution`` answer `true` while nothing ran anywhere.
// ``ReleaseRecordAssembler`` sidesteps the defect by minting ``GateApplicability/applicable`` for
// the 21 unconditional device gates, so **the generator cannot produce this entry** — it is built
// here by hand, through the schema, for the sole purpose of reaching the writer behind the
// refusals.
//
// What the payload therefore is: evidence that the record schema, the canonical writer, and the
// byte reproducibility work. What it is **not**: evidence that any device gate, legal decision,
// governance decision, trust decision, or fusion decision passed. Every approval in it is
// synthetic; nothing is signed; no key is selected; and the signature construction available here
// is `sha256(keyMaterial ‖ message)`, which verifies under every declared algorithm and is not a
// scheme.

// MARK: - The hand-built passing record

extension PipelineSample {

    /// An allowlist entry admitted only by the pinned waiver defect.
    ///
    /// Every one of the 22 mandatory device gates carries an approved synthetic not-applicable
    /// decision and a `not-executed` outcome, which the schema accepts and reports as satisfied.
    /// The environment is recorded honestly as the development Mac, because a passing reference
    /// on a non-iPhone environment *is* refused — the waiver path is the only way through, and
    /// that asymmetry is the defect.
    static func entryAdmittedOnlyByThePinnedWaiverDefect(
        configurationID: String = "configuration.waiver-defect"
    ) throws -> ApprovedDeviceConfiguration {
        let plan = try Sample.joinedPlan()
        let tuple = try Sample.joinedTuple()
        var references: [GateResultReference] = []
        for gate in DeviceGate.mandatoryGates.sorted(by: { $0.rawValue < $1.rawValue }) {
            references.append(
                try GateResultReference(
                    gate: gate,
                    applicability: notApplicable(identifier: "approval.waiver.\(gate.rawValue)"),
                    outcome: .notExecuted,
                    result: evidence("result.nothing-ran"),
                    environment: .developmentMac
                )
            )
        }
        return try ApprovedDeviceConfiguration(
            id: ApprovedConfigurationID(configurationID)!,
            configuration: plan.candidateConfigurations[0],
            versionTuple: tuple,
            gateEvidence: references
        )
    }

    /// A generated-allowlist value that permits distribution, for the reason above only.
    static func allowlistAdmittedOnlyByThePinnedWaiverDefect() throws -> GeneratedDeviceAllowlist {
        let manifest = try Sample.releaseManifest()
        let entry = try entryAdmittedOnlyByThePinnedWaiverDefect()
        let artifact = try ReleaseApprovedDeviceAllowlist(
            id: manifest.approvedConfigurationAllowlist,
            schemaVersion: .v1,
            entries: [entry],
            approval: approval(identifier: "approval.device-allowlist")
        )
        return GeneratedDeviceAllowlist(
            appBuild: manifest.appBuild,
            allowlist: artifact,
            admitted: [entry.id],
            excluded: []
        )
    }

    /// One record gate's evidence, passing, built through the module-internal initialiser.
    ///
    /// There is no `outcome:` parameter: the outcome is computed from the absence of findings and
    /// owed inputs, which is the derived-outcome rule holding even here.
    static func passingGateEvidence(_ gate: ReleaseGate) -> ReleaseGateEvidence {
        ReleaseGateEvidence(
            gate: gate,
            applicability: gate.isConditional
                ? notApplicable(identifier: "approval.waiver.\(gate.rawValue)")
                : .applicable,
            citation: evidence("result.\(gate.rawValue)"),
            contributingKinds: gate.contributingEvidenceKinds,
            findings: [],
            unprovisionedInputs: [],
            evidenceWasProduced: true
        )
    }

    /// A complete record whose every gate is satisfied, over the defect-admitted allowlist.
    ///
    /// Assembled through ``AssembledReleaseRecord``'s module-internal initialiser rather than by
    /// ``ReleaseRecordAssembler``, because the assembler cannot produce this: three of its record
    /// gates read runners whose cells consult the compiled environment, and its allowlist
    /// generator mints `.applicable` for the 21 unconditional device gates.
    static func recordReachingAPayload() throws -> AssembledReleaseRecord {
        var gates: [ReleaseGateEvidence] = []
        for gate in ReleaseGate.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            gates.append(passingGateEvidence(gate))
        }
        return AssembledReleaseRecord(
            evidence: try PipelineBaseline.evidence(),
            gateEvidence: gates,
            allowlist: try allowlistAdmittedOnlyByThePinnedWaiverDefect()
        )
    }

    // MARK: The evidence index the record's citations resolve in

    /// Every artifact the payload's record and allowlist cite, as an approved release index.
    ///
    /// This is the input ``EligibleRelease`` additionally requires and which task 14.8's assembler
    /// does not build: the assembler produces citations and never checks that each resolves at its
    /// exact version and digest. Built here from the same ``PipelineSample/evidence(_:)`` helper
    /// the citations come from, so a citation that named another version or digest would not
    /// resolve.
    static func payloadEvidenceIndex(
        omitting omitted: Set<String> = []
    ) throws -> ReleaseEvidenceIndex {
        var identifiers: [String] = []
        for gate in ReleaseGate.allCases {
            identifiers.append("result.\(gate.rawValue)")
            if gate.isConditional { identifiers.append("approval.waiver.\(gate.rawValue)") }
        }
        for gate in DeviceGate.mandatoryGates {
            identifiers.append("approval.waiver.\(gate.rawValue)")
        }
        identifiers.append(contentsOf: [
            "result.nothing-ran",
            "approval.device-allowlist",
            "approval.repository-code-license",
            "approval.dataset-terms",
            "approval.model-governance",
        ])
        var unique: [String] = []
        for identifier in identifiers where !unique.contains(identifier) {
            unique.append(identifier)
        }
        return try ReleaseEvidenceIndex(
            records: unique.filter { !omitted.contains($0) }.map { evidence($0) }
        )
    }
}

// MARK: - The pinned defect

/// The defect the payload depends on, stated as a live demonstration rather than as a claim.
@Suite("Release payload: the pinned waiver defect")
struct PinnedWaiverDefectTests {

    @Test("An entry whose 22 mandatory gates are all waived reports every gate satisfied")
    func aFullyWaivedEntryReportsEverythingSatisfied() throws {
        let entry = try PipelineSample.entryAdmittedOnlyByThePinnedWaiverDefect()
        #expect(entry.gateEvidence.count == 22)
        #expect(entry.gateEvidence.count == DeviceGate.mandatoryGates.count)
        // The defect, in two halves. There is no "an unconditional gate cannot be declared not
        // applicable" check on `GateResultReference`, so the entry constructs; and `isSatisfied`
        // answers `decision.isApproved` for a not-applicable gate, so it reads as satisfied.
        #expect(entry.unsatisfiedGates.isEmpty)
        var waived = 0
        var unconditionalWaived = 0
        for reference in entry.gateEvidence {
            #expect(!reference.applicability.isApplicable)
            #expect(reference.outcome == GateOutcome.notExecuted)
            #expect(reference.isSatisfied)
            #expect(!reference.environment.isPhysicalDeviceEvidence)
            waived += 1
            if !reference.gate.isProvenanceConditional { unconditionalWaived += 1 }
        }
        #expect(waived == 22)
        // Twenty-one of the twenty-two are gates no requirement permits waiving at all.
        #expect(unconditionalWaived == 21)
    }

    @Test("The corresponding record-gate schema does refuse the same shape")
    func theRecordGateSchemaRefusesTheSameShape() throws {
        // The asymmetry that makes this a defect rather than a design choice.
        // `ReleaseGateRecord` refuses a not-applicable unconditional gate; `GateResultReference`
        // has no such check. The two vocabularies are different, but the rule ought not be.
        #expect(throws: (any Error).self) {
            _ = try ReleaseGateRecord(
                gate: .repositoryCodeLicense,
                applicability: PipelineSample.notApplicable(identifier: "approval.waiver.licence"),
                outcome: .notExecuted,
                evidence: PipelineSample.evidence("result.repository-code-license")
            )
        }
        // And the conditional one is accepted, which is what the check is for.
        let conditional = try ReleaseGateRecord(
            gate: .provenanceFeasibility,
            applicability: PipelineSample.notApplicable(
                identifier: "approval.waiver.provenance-feasibility"
            ),
            outcome: .notExecuted,
            evidence: PipelineSample.evidence("result.provenance-feasibility")
        )
        #expect(conditional.isSatisfied)
    }

    @Test("A passing reference on a non-iPhone environment is still refused")
    func aPassingReferenceIsStillRefused() throws {
        // The barrier that does hold. The waiver path is the only way a host-produced entry reads
        // as satisfied, which is exactly why the defect matters: it is the one door left open.
        #expect(throws: (any Error).self) {
            _ = try GateResultReference(
                gate: .rawLogitParity,
                applicability: .applicable,
                outcome: .passed,
                result: PipelineSample.evidence("result.host"),
                environment: .developmentMac
            )
        }
    }

    @Test("The assembler cannot generate the defect-admitted entry")
    func theAssemblerCannotGenerateIt() throws {
        // The generator mints `.applicable` for the 21 unconditional device gates and carries the
        // catalogued suite's approved decision for the one conditional gate, so the shape above is
        // unreachable through ``ReleaseRecordAssembler``. That is the mitigation 14.8 built, and
        // it is why the payload below had to be hand-assembled.
        let assembled = try PipelineBaseline.assembled()
        #expect(assembled.allowlist.isEmpty)
        #expect(!assembled.allowlist.permitsDistribution)
        let evidence = try Sample.coherentDeviceEvidence()
        var applicable = 0
        for gate in DeviceGate.mandatoryGates where !gate.isProvenanceConditional {
            #expect(evidence.applicability(of: gate).isApplicable)
            applicable += 1
        }
        #expect(applicable == 21)
    }
}

// MARK: - The payload

/// The writer behind the refusals: a record, an allowlist, and reproducible canonical bytes.
@Suite("Release payload: the writer behind the refusals")
struct ReleaseRecordPayloadTests {

    @Test("The hand-built record permits distribution and emits a payload")
    func theHandBuiltRecordEmitsAPayload() throws {
        let record = try PipelineSample.recordReachingAPayload()
        #expect(record.unresolvedMandatoryGates.isEmpty)
        #expect(record.failingMandatoryGates.isEmpty)
        #expect(record.gatesNamingNoEvidence.isEmpty)
        #expect(record.allowlist.permitsDistribution)
        #expect(record.permitsDistribution)
        #expect(record.unprovisionedInputs.isEmpty)

        let output = try record.releaseOutput()
        // What `releaseOutput()` produced, stated field by field. This is the first successful
        // call anywhere in the repository.
        #expect(output.record.id == Sample.artifact("record.release-readiness"))
        #expect(output.record.gateRecords.count == 26)
        #expect(output.record.appBuild == Sample.appBuild())
        #expect(output.record.modelBundle == Sample.bundle())
        #expect(output.record.unresolvedMandatoryGates.isEmpty)
        #expect(output.record.failingMandatoryGates.isEmpty)
        #expect(output.allowlist.entries.count == 1)
        #expect(output.allowlistedConfigurations.count == 1)
        #expect(!output.canonicalRecordBytes.isEmpty)
        #expect(!output.canonicalAllowlistBytes.isEmpty)
        // A pixel-only release: both conditional gates waived, and the record schema's own
        // coupling between them satisfied.
        #expect(!output.record.enablesProvenance)
        #expect(!output.record.enablesFusion)
    }

    @Test("The payload states what it does not establish")
    func thePayloadStatesItsStandingLimits() throws {
        let output = try PipelineSample.recordReachingAPayload().releaseOutput()
        let limits = Set(output.standingLimits)
        // The disclosure this whole suite rests on, carried by the payload itself rather than
        // only by this file's comments.
        #expect(limits.contains(.signatureStandInVerifiesUnderEveryDeclaredAlgorithm))
        #expect(limits.contains(.noJointlySatisfiableMandatoryDeviceGateSetExists))
        #expect(limits.contains(.dataLifecycleDeadlinesAreNotBoundToAnyRecordGate))
        #expect(limits.count == 4)
    }

    @Test("Two emissions over the same record produce byte-identical payloads")
    func thePayloadIsByteReproducible() throws {
        // Byte reproducibility is what makes a published record comparable as bytes rather than by
        // inspection, and it is the property a signature would cover.
        let record = try PipelineSample.recordReachingAPayload()
        let first = try record.releaseOutput()
        let second = try record.releaseOutput()
        #expect(first.canonicalRecordBytes == second.canonicalRecordBytes)
        #expect(first.canonicalAllowlistBytes == second.canonicalAllowlistBytes)

        // And over two independently built records with the same content, which is the stronger
        // claim: the bytes depend on the content rather than on the object.
        let rebuilt = try PipelineSample.recordReachingAPayload().releaseOutput()
        #expect(rebuilt.canonicalRecordBytes == first.canonicalRecordBytes)
        #expect(rebuilt.canonicalAllowlistBytes == first.canonicalAllowlistBytes)
    }

    @Test("The canonical bytes are well-formed JSON with sorted object keys")
    func theCanonicalBytesAreCanonical() throws {
        let output = try PipelineSample.recordReachingAPayload().releaseOutput()
        for bytes in [output.canonicalRecordBytes, output.canonicalAllowlistBytes] {
            let text = String(decoding: bytes, as: UTF8.self)
            #expect(text.hasPrefix("{"))
            #expect(text.hasSuffix("}"))
            // Re-canonicalising already canonical bytes is a fixed point, which is the property
            // that makes the writer a canonical form rather than one formatting among several.
            let again = try CanonicalArtifactEncoding.canonicalized(bytes)
            #expect(again == bytes)
        }
    }

    @Test("The payload's record round-trips through its own canonical bytes")
    func theRecordRoundTrips() throws {
        let output = try PipelineSample.recordReachingAPayload().releaseOutput()
        let decoded = try JSONDecoder().decode(
            ReleaseReadinessRecord.self,
            from: Data(output.canonicalRecordBytes)
        )
        #expect(decoded == output.record)
        let decodedAllowlist = try JSONDecoder().decode(
            ReleaseApprovedDeviceAllowlist.self,
            from: Data(output.canonicalAllowlistBytes)
        )
        #expect(decodedAllowlist == output.allowlist)
    }

    @Test("Changing one gate's citation changes the canonical bytes")
    func oneCitationChangeChangesTheBytes() throws {
        // The bytes have to depend on the content they cover, or byte comparison would establish
        // nothing about the record. One citation redirected, and nothing else.
        let baseline = try PipelineSample.recordReachingAPayload().releaseOutput()
        var gates: [ReleaseGateEvidence] = []
        for gate in ReleaseGate.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            if gate == .archiveAudit {
                gates.append(
                    ReleaseGateEvidence(
                        gate: gate,
                        applicability: .applicable,
                        citation: PipelineSample.evidence("result.archive-audit-elsewhere"),
                        contributingKinds: gate.contributingEvidenceKinds,
                        findings: [],
                        unprovisionedInputs: [],
                        evidenceWasProduced: true
                    )
                )
            } else {
                gates.append(PipelineSample.passingGateEvidence(gate))
            }
        }
        let mutated = AssembledReleaseRecord(
            evidence: try PipelineBaseline.evidence(),
            gateEvidence: gates,
            allowlist: try PipelineSample.allowlistAdmittedOnlyByThePinnedWaiverDefect()
        )
        let output = try mutated.releaseOutput()
        #expect(output.canonicalRecordBytes != baseline.canonicalRecordBytes)
        // The allowlist is untouched, so its bytes are unchanged — the two artifacts are encoded
        // independently and a change to one does not perturb the other.
        #expect(output.canonicalAllowlistBytes == baseline.canonicalAllowlistBytes)
    }
}

// MARK: - The evidence index

/// The check ``EligibleRelease`` additionally makes and the assembler does not: citations resolve.
@Suite("Release payload: the release evidence index")
struct ReleaseEvidenceIndexTests {

    @Test("Every citation in the payload resolves at its exact version and digest")
    func everyCitationResolves() throws {
        // Task 14.8's assembler produces citations and never builds or checks an index, so this is
        // the gap that suite named. Requirement 14.1's mapping is only a mapping if the artifact
        // it names exists at the version and digest it names.
        let output = try PipelineSample.recordReachingAPayload().releaseOutput()
        let index = try PipelineSample.payloadEvidenceIndex()
        var checked = 0
        for entry in output.record.gateRecords {
            checked += 1
            #expect(index.resolves(entry.evidence))
            if let decision = entry.applicability.inapplicabilityDecision {
                checked += 1
                #expect(index.resolves(decision.source))
            }
        }
        // 26 gate citations plus the two conditional waivers.
        #expect(checked == 28)

        // The allowlist's approval and every one of its 22 gate references, too.
        #expect(index.resolves(output.allowlist.approval.source))
        var references = 0
        for entry in output.allowlist.entries {
            for reference in entry.gateEvidence {
                references += 1
                #expect(index.resolves(reference.result))
                let decision = try #require(reference.applicability.inapplicabilityDecision)
                #expect(index.resolves(decision.source))
            }
        }
        #expect(references == 22)

        // And the three externally decided records the record carries.
        for source in [
            output.record.distributionRights.repositoryCodeLicense.source,
            output.record.distributionRights.datasetDistributionTerms.source,
            output.record.modelGovernance.decision.source,
        ] {
            #expect(index.resolves(source))
        }
    }

    @Test("Removing one indexed artifact makes exactly that citation unresolvable")
    func removingOneArtifactUnresolvesExactlyThatCitation() throws {
        var probes = 0
        for gate in ReleaseGate.allCases {
            probes += 1
            let identifier = "result.\(gate.rawValue)"
            let reduced = try PipelineSample.payloadEvidenceIndex(omitting: [identifier])
            let citation = PipelineSample.evidence(identifier)
            #expect(!reduced.resolves(citation))
            var caught: (any Error)?
            do {
                try reduced.requireResolved(citation, field: "release.gateRecords[\(gate.rawValue)]")
            } catch {
                caught = error
            }
            let recorded = try #require(caught)
            let text = "\(recorded)"
            #expect(text.contains(identifier))
            // Every other gate's citation still resolves, so the probe isolates one artifact.
            for other in ReleaseGate.allCases where other != gate {
                #expect(reduced.resolves(PipelineSample.evidence("result.\(other.rawValue)")))
            }
        }
        #expect(probes == 26)
    }

    @Test("A citation at another version or digest does not resolve")
    func aWrongVersionOrDigestDoesNotResolve() throws {
        // A reference is not a record. Three separate disagreements, each reported separately,
        // because a wrong version and a wrong digest are different audit findings from an artifact
        // that does not exist.
        let index = try PipelineSample.payloadEvidenceIndex()
        let indexed = PipelineSample.evidence("result.archive-audit")
        #expect(index.resolves(indexed))

        let wrongVersion = EvidenceSource(
            artifact: indexed.artifact,
            version: Sample.version("2.0.0"),
            contentDigest: indexed.contentDigest
        )
        #expect(!index.resolves(wrongVersion))
        var versionFault: (any Error)?
        do {
            try index.requireResolved(wrongVersion, field: "release.citation")
        } catch {
            versionFault = error
        }
        let versionText = "\(try #require(versionFault))"
        #expect(versionText.contains("version"))

        let wrongDigest = EvidenceSource(
            artifact: indexed.artifact,
            version: indexed.version,
            contentDigest: Sample.digest(0xFFF)
        )
        #expect(!index.resolves(wrongDigest))
        var digestFault: (any Error)?
        do {
            try index.requireResolved(wrongDigest, field: "release.citation")
        } catch {
            digestFault = error
        }
        let digestText = "\(try #require(digestFault))"
        #expect(digestText.contains("contentDigest"))
    }

    @Test("The index refuses an empty record set and a repeated artifact")
    func theIndexRefusesAnEmptyOrAmbiguousSet() throws {
        // One artifact resolves to one approved version: two records for the same artifact would
        // let two references to "the same" evidence read as different content, which is the
        // ambiguity a signed release exists to remove.
        #expect(throws: (any Error).self) {
            _ = try ReleaseEvidenceIndex(records: [])
        }
        #expect(throws: (any Error).self) {
            _ = try ReleaseEvidenceIndex(
                records: [
                    PipelineSample.evidence("result.archive-audit"),
                    EvidenceSource(
                        artifact: Sample.artifact("result.archive-audit"),
                        version: Sample.version("2.0.0"),
                        contentDigest: Sample.digest(0xFFE)
                    ),
                ]
            )
        }
    }

    @Test("The assembled honest record's citations also resolve in an index built for them")
    func thehonestRecordsCitationsResolve() throws {
        // The honest assembly cannot emit a payload, but its citations are still checkable, and a
        // release that later closes the device gates would need exactly this. 14.8's assembler
        // supplies them from `Sample.matrixEvidence`, so the index is built from the same helper.
        let assembled = try PipelineBaseline.assembled()
        var records: [EvidenceSource] = []
        for gate in ReleaseGate.allCases {
            records.append(Sample.matrixEvidence("result.\(gate.rawValue)", digest: 0xC0))
        }
        let index = try ReleaseEvidenceIndex(records: records)
        var checked = 0
        for entry in assembled.gateEvidence {
            let citation = try #require(entry.citation)
            checked += 1
            #expect(index.resolves(citation))
        }
        #expect(checked == 26)
    }

    @Test("Reaching EligibleRelease additionally needs a validated accessibility matrix")
    func eligibleReleaseNeedsAValidatedMatrix() throws {
        // What blocked feeding the payload to ``EligibleRelease``, stated rather than skipped.
        // Its initialiser requires a ``ValidatedAccessibilityGateMatrix``, which requires an
        // ``AccessibilityGateMatrix`` covering every configuration and supported major iOS version
        // position derived from the signed allowlist. Building one is task 14.4's surface and is
        // not synthesised here; what this task did build and check is the evidence index, which is
        // the other input ``EligibleRelease`` needs and the one 14.8's assembler omitted.
        //
        // The two record-level checks `EligibleRelease` would additionally apply are asserted
        // directly instead, over the payload the writer produced.
        let output = try PipelineSample.recordReachingAPayload().releaseOutput()
        let manifest = try Sample.releaseManifest()

        // Requirement 14.1: the record answers for an approved capability set at this build,
        // bundle, and allowlist.
        #expect(manifest.approval.isApproved)
        #expect(output.record.capabilityManifest == manifest.id)
        #expect(output.record.appBuild == manifest.appBuild)
        #expect(manifest.approvedBundleCatalog.contains(output.record.modelBundle))
        #expect(output.record.deviceAllowlist == manifest.approvedConfigurationAllowlist)

        // Requirements 6.2 and 6.3: each conditional gate's applicability is the compiled set.
        #expect(output.record.enablesProvenance == manifest.enablesProvenance)
        #expect(output.record.enablesFusion == manifest.enablesFusion)

        // Requirement 14.9: the disclosures are the ones this release has to disclose, and the
        // decision beside them is a separate synthetic record rather than derived from them.
        let governance = output.record.modelGovernance
        #expect(governance.modelIdentity == RequiredPixelModel.identity)
        #expect(governance.isIndependentNonPeerReviewed)
        #expect(!governance.redTeamValidationValid)
        #expect(governance.decision.isApproved)

        // And every gate outcome agrees with the decision the record carries beside it, which is
        // the drift `EligibleRelease` exists to catch.
        for (gate, approval) in [
            (ReleaseGate.repositoryCodeLicense, output.record.distributionRights.repositoryCodeLicense),
            (.dataDistributionRights, output.record.distributionRights.datasetDistributionTerms),
            (.modelGovernanceDecision, governance.decision),
        ] {
            #expect(approval.isApproved)
            #expect(output.record.record(for: gate).outcome == GateOutcome.passed)
        }
    }
}
