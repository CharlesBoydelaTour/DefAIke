import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// The release-pipeline gate, probed one field at a time (task 14.10).
//
// # The shape
//
// A clean synthetic baseline plus one mutation per field, each required to flip exactly the gate
// it should and no other. That is the standard the audit scripts in this project already set —
// 12.3 fires 13 of 13 planted violations, 12.5 fires 12/12 static and 8/8 product, 14.6 fires 7/7
// and 16/16, 15.1 fires 42/42 and 28/28 — and the load-bearing half of it is the *baseline*: a
// mutation suite with no verified clean baseline proves nothing, because every probe would
// "detect" a failure that was already there. ``ReleasePipelineBaselineTests`` verifies the
// baseline first, and every probe below asserts the symmetric difference against it.
//
// # What is synthetic, and what that costs
//
// **No approval, digest, key, licence, device configuration, or fusion decision in this suite is
// real.** See the header of `ReleasePipelineGateSamples.swift` for the itemised statement. The one
// point worth repeating here: the signature construction available in this repository is
// `sha256(keyMaterial ‖ message)`, so one value verifies under every `SignatureAlgorithm` the
// schema can name. Nothing here verifies a signature, and a pass over that construction would not
// be cryptographic evidence.
//
// # The honest ceiling on a "passing" record
//
// A synthetic record here reaches 21 of the 24 unconditional record gates passing, and the three
// it cannot are all one fact: every device runner's gate result consults
// ``ObservedParityEnvironment/current``, compiled from the platform with no parameter, so a host
// `swift test` run fails `device-allowlist`, `accessibility-matrix`, and
// `localization-readiness-matrix` whatever is measured. The two conditional gates are satisfied
// by synthetic waivers and block nothing. So `releaseOutput()` refuses on exactly those three,
// and this suite asserts that refusal as the correct reported state rather than working around
// it. ``ReleaseRecordPayloadTests`` is where a payload is reached at all, and it says exactly what
// it had to use to get there.

// MARK: - The baseline

/// The complete synthetic evidence set, and one knob per probe.
///
/// Everything a probe does not override is the baseline value, so a probe that changes one field
/// cannot leave a second disagreement behind and flip a gate for the wrong reason.
enum PipelineBaseline {

    /// The one plan, tuple, and manifest the device half is bound to.
    static func plan() throws -> DeviceValidationPlan { try Sample.joinedPlan() }

    static func tuple() throws -> ValidationVersionTuple { try Sample.joinedTuple() }

    static func manifest() throws -> ReleaseCapabilityManifest { try Sample.releaseManifest() }

    /// The complete synthetic evidence set: every one of the twelve joined kinds present.
    ///
    /// 14.8's `Sample.recordEvidence` defaults every optional kind to absent, which is the honest
    /// default for that suite. This one supplies all of them, because the join is only observable
    /// once a kind is present — an absent kind exercises exactly one arm.
    static func evidence(
        capabilityManifest: ReleaseCapabilityManifest? = nil,
        modelBundle: ModelBundleID? = nil,
        calibration: ApprovedCalibrationRelease?? = nil,
        corpus: CorpusRemediation?? = nil,
        bundle: BundleActivationEvidence?? = nil,
        archive: ArchiveAuditReport?? = nil,
        matrix: AccessibilityMatrixReport?? = nil,
        deviceEvidence: [CoherentDeviceEvidence]? = nil,
        distributionRights: DistributionRightsRecord?? = nil,
        modelGovernance: ModelGovernanceDecisionRecord?? = nil,
        activeLimitations: EvidenceSource?? = nil,
        correctionChannel: EvidenceSource?? = nil,
        benchmarkClaims: [BenchmarkClaimRecord]? = nil,
        conditionalApplicability: [ReleaseGate: GateApplicability]? = nil,
        gateCitations: [ReleaseGate: EvidenceSource]? = nil
    ) throws -> ReleaseRecordEvidence {
        let resolvedManifest = try capabilityManifest ?? manifest()
        let resolvedPlan = try plan()
        let resolvedTuple = try tuple()
        let device = try deviceEvidence ?? [
            try Sample.coherentDeviceEvidence(capabilityManifest: resolvedManifest)
        ]
        return try Sample.recordEvidence(
            capabilityManifest: resolvedManifest,
            modelBundle: modelBundle,
            calibration: try calibration ?? PipelineSample.approvedCalibration(),
            corpus: try corpus ?? CorpusSample.remediation(),
            bundle: bundle ?? PipelineSample.bundleEvidence(),
            archive: archive ?? Sample.archiveAuditReport(),
            matrix: try matrix ?? Sample.joinedMatrixReport(
                plan: resolvedPlan,
                versionTuple: resolvedTuple
            ),
            deviceEvidence: device,
            distributionRights: distributionRights ?? PipelineSample.distributionRights(),
            modelGovernance: try modelGovernance ?? PipelineSample.governance(),
            activeLimitations: activeLimitations ?? PipelineSample.activeLimitations(),
            correctionChannel: correctionChannel ?? PipelineSample.correctionChannel(),
            benchmarkClaims: benchmarkClaims ?? [],
            conditionalApplicability: conditionalApplicability,
            gateCitations: gateCitations
        )
    }

    /// The assembled clean baseline.
    static func assembled() throws -> AssembledReleaseRecord {
        ReleaseRecordAssembler().assemble(try evidence())
    }

    /// The clean baseline publishes no benchmark claim, and that is not a gap.
    ///
    /// An empty claim list is a valid recorded state — a release may publish no benchmark claim —
    /// and it is deliberately the baseline here for a measured reason rather than a convenient
    /// one. Task 14.7's synthetic corpus remediation leaves two regenerated comparisons naming an
    /// origin the approved dispositions excluded, and its comparison set cannot be reduced: the
    /// remediation requires exact coverage of the correction's reattributions and refuses a
    /// filtered list outright. Requirement 14.7 forbids using such a comparison in a release
    /// claim, so `benchmark-claim-bindings` cannot pass beside *any* claim in this repository,
    /// whatever that claim's bindings are.
    ///
    /// Making the baseline claim-free is what keeps the four binding probes meaningful: each is
    /// measured against ``claimBearing()``, at finding granularity, so a redirect is observed as
    /// the one finding it adds rather than being lost inside a failure that was already there.
    static func claimBearing() throws -> AssembledReleaseRecord {
        ReleaseRecordAssembler().assemble(
            try evidence(benchmarkClaims: [try PipelineSample.benchmarkClaim()])
        )
    }

    // MARK: The three gates a host run cannot satisfy

    /// The record gates no synthetic evidence on a host can make pass.
    ///
    /// All three read a runner's cells, and every runner's cell outcome consults
    /// ``ObservedParityEnvironment/current``. There is no parameter, artifact, or approval that
    /// changes it, which is what makes Requirement 13.16 structural rather than advisory.
    static let physicalDeviceBlockedGates: Set<ReleaseGate> = [
        .deviceAllowlist,
        .accessibilityMatrix,
        .localizationReadinessMatrix,
    ]

    /// The gates the clean baseline passes: every unconditional gate except the three above.
    static var passingGates: Set<ReleaseGate> {
        Set(ReleaseGate.allCases.filter { !$0.isConditional })
            .subtracting(physicalDeviceBlockedGates)
    }
}

// MARK: - Probe machinery

/// One gate's answers in one assembly, as a probe compares them.
struct GateReading: Hashable {
    let gate: ReleaseGate
    let outcome: GateOutcome
    let isSatisfied: Bool
}

extension AssembledReleaseRecord {
    /// Every gate's outcome and satisfaction, keyed by gate.
    var readings: [ReleaseGate: GateReading] {
        var map: [ReleaseGate: GateReading] = [:]
        for entry in gateEvidence {
            map[entry.gate] = GateReading(
                gate: entry.gate,
                outcome: entry.outcome,
                isSatisfied: entry.isSatisfied
            )
        }
        return map
    }
}

/// The gates whose reading differs between two assemblies.
///
/// Both halves of a reading are compared, not just satisfaction: a gate that went from `passed` to
/// `notExecuted` changed even though both are "not failing", and a probe that only compared
/// satisfaction would call that no change.
func gatesThatChanged(
    from baseline: AssembledReleaseRecord,
    to mutated: AssembledReleaseRecord
) -> Set<ReleaseGate> {
    let before = baseline.readings
    let after = mutated.readings
    var changed: Set<ReleaseGate> = []
    for gate in ReleaseGate.allCases where before[gate] != after[gate] {
        changed.insert(gate)
    }
    return changed
}

/// Runs one probe and requires it to flip exactly `expected` relative to the clean baseline.
///
/// Returns the mutated assembly so a probe can additionally assert *how* the gate changed, which
/// is the half a symmetric-difference check cannot see.
@discardableResult
func probe(
    flips expected: Set<ReleaseGate>,
    _ label: Comment,
    against baseline: AssembledReleaseRecord? = nil,
    building mutation: () throws -> ReleaseRecordEvidence,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> AssembledReleaseRecord {
    let assembler = ReleaseRecordAssembler()
    let reference = try baseline ?? PipelineBaseline.assembled()
    let mutated = assembler.assemble(try mutation())
    let changed = gatesThatChanged(from: reference, to: mutated)
    #expect(changed == expected, label, sourceLocation: sourceLocation)
    return mutated
}

/// Every finding one gate carries, rendered, so a probe can compare finding sets.
///
/// Used where a gate already fails in the reference for an unrelated and unremovable reason, and
/// the observable effect of a mutation is the one finding it adds. Weaker than a reading flip and
/// stated as such at each call site.
func findingDescriptions(
    of gate: ReleaseGate,
    in record: AssembledReleaseRecord
) -> Set<String> {
    var rendered: Set<String> = []
    for finding in record.gate(gate).findings {
        rendered.insert(finding.description)
    }
    return rendered
}

// MARK: - The clean baseline

/// The baseline every probe is measured against, verified before any probe runs.
@Suite("Release pipeline: the clean synthetic baseline")
struct ReleasePipelineBaselineTests {

    @Test("Every joined evidence kind is present in the baseline")
    func baselineSuppliesEveryJoinedKind() throws {
        let evidence = try PipelineBaseline.evidence()
        #expect(evidence.calibration != nil)
        #expect(evidence.corpus != nil)
        #expect(evidence.bundle != nil)
        #expect(evidence.archive != nil)
        #expect(evidence.matrix != nil)
        #expect(evidence.deviceEvidence.count == 1)
        #expect(evidence.distributionRights != nil)
        #expect(evidence.modelGovernance != nil)
        #expect(evidence.activeLimitations != nil)
        #expect(evidence.correctionChannel != nil)
        // The one deliberate absence, and it is a valid recorded state rather than a gap. See
        // ``PipelineBaseline/claimBearing()`` for why the baseline publishes no claim.
        #expect(evidence.benchmarkClaims.isEmpty)
        #expect(evidence.conditionalApplicability.count == 2)
        #expect(evidence.gateCitations.count == 26)
    }

    @Test("The baseline owes no release-controlled input")
    func baselineOwesNothing() throws {
        let assembled = try PipelineBaseline.assembled()
        let owed = assembled.unprovisionedInputs
        #expect(owed.isEmpty, "a baseline that still owes an input cannot isolate a mutation")
        #expect(assembled.gatesNamingNoEvidence.isEmpty)
    }

    @Test("The baseline passes 21 of the 24 unconditional gates and fails exactly three")
    func baselinePassesEveryGateAHostRunCanPass() throws {
        let assembled = try PipelineBaseline.assembled()
        var passed: Set<ReleaseGate> = []
        var failed: Set<ReleaseGate> = []
        var notExecuted: Set<ReleaseGate> = []
        for entry in assembled.gateEvidence {
            switch entry.outcome {
            case .passed: passed.insert(entry.gate)
            case .failed: failed.insert(entry.gate)
            case .notExecuted: notExecuted.insert(entry.gate)
            }
        }
        #expect(passed == PipelineBaseline.passingGates)
        #expect(passed.count == 21)
        #expect(failed == PipelineBaseline.physicalDeviceBlockedGates)
        // The two conditional gates: waived by a synthetic approved decision, so not executed and
        // satisfied. They are the only two that may be `notExecuted` in a clean baseline.
        let conditional: Set<ReleaseGate> = [.provenanceFeasibility, .fusionRuleApproval]
        #expect(notExecuted == conditional)
        #expect(assembled.unresolvedMandatoryGates.isEmpty)
        #expect(assembled.failingMandatoryGates == PipelineBaseline.physicalDeviceBlockedGates)
    }

    @Test("The three failing baseline gates fail for the physical-device reason and only that")
    func theThreeFailuresAreThePhysicalDeviceOne() throws {
        let assembled = try PipelineBaseline.assembled()
        let allowlist = assembled.gate(.deviceAllowlist)
        var environmentExclusions = 0
        var zeroPassingBlocks = 0
        for finding in allowlist.findings {
            switch finding {
            case let .deviceConfigurationExcluded(_, reason):
                if case .notPhysicalDeviceEvidence = reason { environmentExclusions += 1 }
            case .noPassingDeviceConfiguration:
                zeroPassingBlocks += 1
            default:
                Issue.record("the baseline device gate recorded an unexpected finding")
            }
        }
        #expect(environmentExclusions == 1)
        #expect(zeroPassingBlocks == 1)

        // The two matrix gates fail on unsatisfied matrix positions, which is the same fact: the
        // matrix runner's cells consult the compiled environment.
        for gate in [ReleaseGate.accessibilityMatrix, .localizationReadinessMatrix] {
            let entry = assembled.gate(gate)
            #expect(!entry.findings.isEmpty)
            #expect(entry.unprovisionedInputs.isEmpty)
            for finding in entry.findings {
                guard case .contributingResultFailed = finding else {
                    Issue.record("a matrix gate recorded something other than a failed result")
                    continue
                }
            }
        }
        #expect(!ObservedParityEnvironment.canProducePhysicalDeviceEvidence)
    }

    @Test("The baseline's release output refuses on exactly the three device-shaped gates")
    func baselineOutputRefusesOnTheThreeDeviceGates() throws {
        let assembled = try PipelineBaseline.assembled()
        #expect(!assembled.permitsDistribution)
        var refusal: ReleaseRecordOutputRefusal?
        do {
            _ = try assembled.releaseOutput()
        } catch {
            refusal = error as? ReleaseRecordOutputRefusal
        }
        let recorded = try #require(refusal)
        guard case let .mandatoryGatesFailing(gates) = recorded else {
            Issue.record("a baseline with no unresolved gate must refuse on the failing ones")
            return
        }
        #expect(Set(gates) == PipelineBaseline.physicalDeviceBlockedGates)
        #expect(gates.count == 3)
    }

    @Test("The baseline carries every standing limit its evidence qualifies")
    func baselineCarriesItsStandingLimits() throws {
        let assembled = try PipelineBaseline.claimBearing()
        let limits = Set(assembled.standingLimits)
        #expect(limits.count == 5)
        // Including the one that says the signature construction here is not a scheme, which is
        // the disclosure this whole suite depends on being made.
        #expect(limits.contains(.signatureStandInVerifiesUnderEveryDeclaredAlgorithm))
        #expect(limits.contains(.noJointlySatisfiableMandatoryDeviceGateSetExists))
        #expect(limits.contains(.dataLifecycleDeadlinesAreNotBoundToAnyRecordGate))
        #expect(limits.contains(.publishedClaimCoverageIsNotReconciledAgainstSliceMeasurements))
        #expect(
            limits.contains(
                .recordCompletenessStatisticsCountReturnedRatherThanQualifyingSamples
            )
        )
    }
}

// MARK: - Calibration

/// Requirement 5.22's three calibration gates, and what one field does to them.
@Suite("Release pipeline: calibration probes")
struct ReleasePipelineCalibrationProbeTests {

    static let calibrationGates: Set<ReleaseGate> = [
        .calibrationSliceBudgets,
        .contemporaryPhoneCameraSlice,
        .populationSeparation,
    ]

    @Test("An absent calibration release unresolves its three gates and the claim gate")
    func absentCalibrationUnresolvesFourGates() throws {
        let mutated = try probe(
            flips: Self.calibrationGates.union([.benchmarkClaimBindings]),
            "an absent calibration release must unresolve exactly its four readers"
        ) {
            try PipelineBaseline.evidence(calibration: .some(nil))
        }
        for gate in Self.calibrationGates {
            let entry = mutated.gate(gate)
            #expect(entry.outcome == GateOutcome.notExecuted)
            #expect(entry.unprovisionedInputs == [.approvedCalibrationRelease])
        }
        #expect(mutated.unresolvedMandatoryGates.contains(.calibrationSliceBudgets))
    }

    @Test("A calibration release answering for another bundle fails its three gates")
    func calibrationForAnotherBundleFailsThreeGates() throws {
        // The policy activates against another bundle, so the approval answers for that bundle
        // and the record distributes this one. Everything else is the baseline.
        let other = ModelBundleID("bundle.other")!
        let mutated = try probe(
            flips: Self.calibrationGates,
            "a calibration release for another bundle must fail exactly its three gates"
        ) {
            let policy = try PipelineSample.validatedPolicy(bundleID: other)
            let baseline = try PipelineSample.CalibrationBaseline(policy: policy)
            return try PipelineBaseline.evidence(calibration: try baseline.approve())
        }
        for gate in Self.calibrationGates {
            let entry = mutated.gate(gate)
            #expect(entry.outcome == GateOutcome.failed)
            var mismatches = 0
            for finding in entry.findings {
                if case let .bundleEvidenceNamesAnotherBundle(expected, found) = finding {
                    mismatches += 1
                    #expect(expected == Sample.bundle())
                    #expect(found == other)
                }
            }
            #expect(mismatches == 1)
        }
    }

    @Test("A slice set with no contemporary phone-camera slice never reaches a record gate")
    func theContemporaryPhoneCameraRecordFindingIsUnreachable() throws {
        // Requirement 5.20's slice is required by the *approval*, so a slice set without it is
        // refused before an `ApprovedCalibrationRelease` exists. The record gate's own
        // `mandatoryGatingSliceAbsent` finding is therefore defensive and unreachable through the
        // domain's approval path, which is worth stating as a fact rather than leaving as an
        // untested branch.
        var refusal: (any Error)?
        do {
            let baseline = try PipelineSample.CalibrationBaseline(
                slices: [try PipelineSample.gatingSlice(PipelineSample.generalSliceIdentifier)]
            )
            _ = try baseline.approve()
        } catch {
            refusal = error
        }
        let recorded = try #require(refusal)
        let text = "\(recorded)"
        #expect(text.contains("phone-camera"))

        // And the baseline's approval does carry one, so the gate has something to read.
        let approved = try PipelineSample.approvedCalibration()
        #expect(approved.contemporaryPhoneCameraSlices.count == 1)
    }

    @Test("A failed content-level separation result refuses the approval outright")
    func failedContentLevelSeparationRefusesApproval() throws {
        // Requirement 5.23 rejects the affected Calibration Policy, so this is a refusal rather
        // than a record finding. The probe is that the refusal names the pair and the level.
        let key = PipelineSample.pairKey(.heldOutCalibration, .productThresholdEvaluation)
        var refusal: (any Error)?
        do {
            let baseline = try PipelineSample.CalibrationBaseline(
                lineage: try PipelineSample.lineage(
                    results: try PipelineSample.separationResults(
                        contentLevel: [key: .failed]
                    )
                )
            )
            _ = try baseline.approve()
        } catch {
            refusal = error
        }
        let recorded = try #require(refusal)
        let text = "\(recorded)"
        #expect(text.contains("contentLevelOutcome"))
        #expect(text.contains(key))
    }

    @Test("A slice over the budget refuses the approval, so no record gate can pass over it")
    func aSliceOverTheBudgetRefusesApproval() throws {
        // 60 positive labels of 1,000 eligible real images is 6%, well past the 0.5% placeholder
        // budget and past Requirement 5.1's 1.0% ceiling. Requirement 5.22 blocks the affected
        // bundle and application combination, and the approval is where that happens.
        var refusal: (any Error)?
        do {
            let policy = try PipelineSample.validatedPolicy()
            let slices = [
                try PipelineSample.gatingSlice(
                    PipelineSample.phoneCameraSliceIdentifier,
                    isContemporaryPhoneCamera: true
                ),
                try PipelineSample.gatingSlice(PipelineSample.generalSliceIdentifier),
            ]
            let overBudget = try PipelineSample.sliceCounts(
                realPositive: 60,
                realNonPositive: 840,
                realInsufficient: 100
            )
            let measurements = [
                try PipelineSample.measurement(
                    slices[0],
                    counts: overBudget,
                    against: policy
                ),
                try PipelineSample.measurement(slices[1], against: policy),
            ]
            let baseline = try PipelineSample.CalibrationBaseline(
                policy: policy,
                slices: slices,
                measurements: measurements,
                reports: [
                    PipelineSample.sliceReport(
                        of: measurements[0],
                        falsePositiveRate: Decimal(sign: .plus, exponent: -2, significand: 6),
                        coverage: Decimal(sign: .plus, exponent: -4, significand: 8583)
                    ),
                    PipelineSample.sliceReport(of: measurements[1]),
                ]
            )
            _ = try baseline.approve()
        } catch {
            refusal = error
        }
        let recorded = try #require(refusal)
        let text = "\(recorded)"
        #expect(text.contains(PipelineSample.phoneCameraSliceIdentifier))
    }

    @Test("An unresolvable calibration citation refuses the approval")
    func anUnresolvableCitationRefusesApproval() throws {
        var refusal: (any Error)?
        do {
            let baseline = try PipelineSample.CalibrationBaseline(
                index: try PipelineSample.calibrationIndex(
                    omitting: [PipelineSample.separationIdentifier]
                )
            )
            _ = try baseline.approve()
        } catch {
            refusal = error
        }
        let recorded = try #require(refusal)
        let text = "\(recorded)"
        #expect(text.contains(PipelineSample.separationIdentifier))
    }
}

// MARK: - Bundle

/// Requirement 14.13's six recorded results, one mutation each.
@Suite("Release pipeline: bundle probes")
struct ReleasePipelineBundleProbeTests {

    static let bundleGates: Set<ReleaseGate> = [
        .initialModelBundleSignature,
        .initialModelBundleSelfTests,
        .bundleActivation,
        .bundleRollback,
    ]

    /// The record gate each of the six recorded bundle results is routed to.
    static let routing: [(BundleReleaseGate, ReleaseGate)] = [
        (.releaseSignature, .initialModelBundleSignature),
        (.perArtifactDigests, .initialModelBundleSignature),
        (.compatibility, .initialModelBundleSignature),
        (.releaseSelfTests, .initialModelBundleSelfTests),
        (.atomicActivation, .bundleActivation),
        (.verifiedRollback, .bundleRollback),
    ]

    @Test("Absent bundle evidence unresolves exactly the four bundle gates")
    func absentBundleEvidenceUnresolvesFourGates() throws {
        let mutated = try probe(
            flips: Self.bundleGates,
            "absent bundle evidence must unresolve exactly the four bundle gates"
        ) {
            try PipelineBaseline.evidence(bundle: .some(nil))
        }
        for gate in Self.bundleGates {
            let entry = mutated.gate(gate)
            #expect(entry.outcome == GateOutcome.notExecuted)
            #expect(entry.unprovisionedInputs == [.producedModelBundleReleaseEvidence])
            // Every one of the four is a hard public-launch blocker (Requirement 14.16).
            #expect(assembledBlocks(mutated, gate))
        }
        #expect(mutated.blockingHardPublicLaunchBlockers.count >= 4)
    }

    @Test("Each of the six recorded bundle results flips exactly its own record gate")
    func eachRecordedBundleResultFlipsItsOwnGate() throws {
        var probes = 0
        for (recorded, expectedGate) in Self.routing {
            probes += 1
            let mutated = try probe(
                flips: [expectedGate],
                "one failing recorded bundle result must flip exactly one record gate"
            ) {
                try PipelineBaseline.evidence(
                    bundle: PipelineSample.bundleEvidence(
                        releaseSignature: recorded == .releaseSignature ? .failed : .passed,
                        perArtifactDigests: recorded == .perArtifactDigests ? .failed : .passed,
                        compatibility: recorded == .compatibility ? .failed : .passed,
                        releaseSelfTests: recorded == .releaseSelfTests ? .failed : .passed,
                        atomicActivation: recorded == .atomicActivation ? .failed : .passed,
                        verifiedRollback: recorded == .verifiedRollback ? .failed : .passed
                    )
                )
            }
            let entry = mutated.gate(expectedGate)
            #expect(entry.outcome == GateOutcome.failed)
            let detail = entry.findings.map(\.description).joined(separator: " | ")
            #expect(detail.contains(recorded.rawValue))
        }
        // Counted-work floor: six recorded results, all six probed.
        #expect(probes == 6)
        #expect(probes == BundleReleaseGate.allCases.count)
    }

    @Test("Bundle evidence answering for another bundle fails all four bundle gates")
    func bundleEvidenceForAnotherBundleFailsFourGates() throws {
        let other = ModelBundleID("bundle.other")!
        let mutated = try probe(
            flips: Self.bundleGates,
            "bundle evidence for another bundle must fail exactly the four bundle gates"
        ) {
            try PipelineBaseline.evidence(bundle: PipelineSample.bundleEvidence(bundleID: other))
        }
        for gate in Self.bundleGates {
            var mismatches = 0
            for finding in mutated.gate(gate).findings {
                if case .bundleEvidenceNamesAnotherBundle = finding { mismatches += 1 }
            }
            #expect(mismatches == 1)
        }
    }

    private func assembledBlocks(_ record: AssembledReleaseRecord, _ gate: ReleaseGate) -> Bool {
        record.unresolvedMandatoryGates.contains(gate)
            || record.failingMandatoryGates.contains(gate)
    }
}

// MARK: - Rights, notices, corpus, privacy, accessibility, governance

/// The archive-audit half: notices, corpus exclusion, privacy, and the audit itself.
@Suite("Release pipeline: archive-derived probes")
struct ReleasePipelineArchiveProbeTests {

    static let archiveGates: Set<ReleaseGate> = [
        .privacyAudit, .archiveAudit, .dependencyNotices, .corpusExclusion,
    ]

    @Test("Each failing input class flips exactly the record gate it routes to")
    func eachFailingInputClassFlipsItsOwnGate() throws {
        var probes = 0
        for inputClass in ArchiveAuditFailingInputClass.allCases {
            probes += 1
            let mutated = try probe(
                flips: [inputClass.gate],
                "one archive finding must flip exactly the gate its class routes to"
            ) {
                try PipelineBaseline.evidence(
                    archive: Sample.archiveAuditReport(
                        findings: [
                            ArchiveAuditFinding(
                                failingInputClass: inputClass,
                                detail: "synthetic planted \(inputClass.rawValue)"
                            )
                        ]
                    )
                )
            }
            let entry = mutated.gate(inputClass.gate)
            #expect(entry.outcome == GateOutcome.failed)
            // The audit's own class identifier and detail travel verbatim rather than reworded.
            let detail = entry.findings.map(\.description).joined(separator: " | ")
            #expect(detail.contains(inputClass.rawValue))
            #expect(detail.contains("synthetic planted"))
        }
        #expect(probes == 5)
        #expect(probes == ArchiveAuditFailingInputClass.allCases.count)
    }

    @Test("An absent archive audit unresolves exactly the four archive gates")
    func absentArchiveAuditUnresolvesFourGates() throws {
        let mutated = try probe(
            flips: Self.archiveGates,
            "an absent archive audit must unresolve exactly its four gates"
        ) {
            try PipelineBaseline.evidence(archive: .some(nil))
        }
        for gate in Self.archiveGates {
            let entry = mutated.gate(gate)
            #expect(entry.outcome == GateOutcome.notExecuted)
            #expect(entry.unprovisionedInputs == [.archiveAuditReleaseInputDocument])
        }
    }

    @Test("An audit that inspected nothing unresolves the four gates rather than passing them")
    func anAuditThatInspectedNothingCannotPass() throws {
        let mutated = try probe(
            flips: Self.archiveGates,
            "an audit that inspected nothing must unresolve its four gates"
        ) {
            try PipelineBaseline.evidence(archive: Sample.archiveAuditReport(inspected: false))
        }
        for gate in Self.archiveGates {
            #expect(mutated.gate(gate).outcome == GateOutcome.notExecuted)
            #expect(!mutated.gate(gate).isSatisfied)
        }
    }

    @Test("An owed archive input fails the archive gate rather than leaving it unresolved")
    func anOwedArchiveInputFailsTheArchiveGate() throws {
        var probes = 0
        for owed in UnprovisionedArchiveAuditInput.allCases {
            probes += 1
            let mutated = try probe(
                flips: [.archiveAudit],
                "one owed archive input must fail exactly the archive-audit gate"
            ) {
                try PipelineBaseline.evidence(
                    archive: Sample.archiveAuditReport(owed: [owed])
                )
            }
            let entry = mutated.gate(.archiveAudit)
            #expect(entry.outcome == GateOutcome.failed)
            let detail = entry.findings.map(\.description).joined(separator: " | ")
            #expect(detail.contains(owed.rawValue))
        }
        #expect(probes == 6)
        #expect(probes == UnprovisionedArchiveAuditInput.allCases.count)
    }
}

/// The corpus remediation half (Requirements 14.7 and 14.8).
@Suite("Release pipeline: corpus probes")
struct ReleasePipelineCorpusProbeTests {

    static let corpusGates: Set<ReleaseGate> = [
        .corpusIdentifierCorrection, .duplicateHashDisposition,
    ]

    @Test("Absent corpus remediation unresolves exactly its two gates")
    func absentCorpusUnresolvesTwoGates() throws {
        let mutated = try probe(
            flips: Self.corpusGates,
            "absent corpus remediation must unresolve exactly its two gates"
        ) {
            try PipelineBaseline.evidence(corpus: .some(nil))
        }
        for gate in Self.corpusGates {
            let entry = mutated.gate(gate)
            #expect(entry.outcome == GateOutcome.notExecuted)
            #expect(entry.unprovisionedInputs == [.regeneratedCorpusRemediationEvidence])
        }
    }

    @Test("A present remediation passes both corpus gates")
    func presentRemediationPassesBothGates() throws {
        let assembled = try PipelineBaseline.assembled()
        for gate in Self.corpusGates {
            #expect(assembled.gate(gate).outcome == GateOutcome.passed)
        }
        #expect(assembled.gate(.benchmarkClaimBindings).outcome == GateOutcome.passed)
    }

    @Test("Two standing excluded comparisons block any published claim")
    func standingExcludedComparisonsBlockAnyClaim() throws {
        // Requirement 14.7 forbids using a regenerated comparison in a release claim before every
        // affected artifact is regenerated, and task 14.7's synthetic remediation leaves two
        // comparisons naming an origin the approved dispositions excluded. So publishing any claim
        // fails the claim gate whatever that claim's bindings are, and the claim-free baseline is
        // the honest clean state rather than a convenience.
        let remediation = try CorpusSample.remediation()
        let standing = remediation.comparisonsNamingExcludedEntries
        #expect(standing.count == 2)

        let claimBearing = try PipelineBaseline.claimBearing()
        let entry = claimBearing.gate(.benchmarkClaimBindings)
        #expect(entry.outcome == GateOutcome.failed)
        var rested = 0
        for finding in entry.findings {
            if case let .claimRestsOnExcludedCorpusEntry(count) = finding {
                rested += 1
                #expect(count == 2)
            }
        }
        #expect(rested == 1)
        #expect(entry.findings.count == 1)
    }
}

/// The two externally decided rights gates and the governance gate (Requirements 14.2-14.4,
/// 14.9, 14.10, 14.17).
@Suite("Release pipeline: rights and governance probes")
struct ReleasePipelineRightsProbeTests {

    @Test("Each rights decision flips exactly its own gate when rejected")
    func eachRightsDecisionFlipsItsOwnGate() throws {
        var probes = 0
        for gate in [ReleaseGate.repositoryCodeLicense, .dataDistributionRights] {
            probes += 1
            let mutated = try probe(
                flips: [gate],
                "one rejected rights decision must flip exactly its own gate"
            ) {
                try PipelineBaseline.evidence(
                    distributionRights: PipelineSample.distributionRights(
                        codeLicense: gate == .repositoryCodeLicense ? .rejected : .approved,
                        datasetTerms: gate == .dataDistributionRights ? .rejected : .approved
                    )
                )
            }
            let entry = mutated.gate(gate)
            #expect(entry.outcome == GateOutcome.failed)
            var rejections = 0
            for finding in entry.findings {
                if case let .externalDecisionRejected(kind) = finding {
                    rejections += 1
                    #expect(kind == ReleaseRecordEvidenceKind.legal)
                }
            }
            #expect(rejections == 1)
            // A rejection is a failure, never a missing result, and the two stay distinguishable.
            #expect(mutated.failingMandatoryGates.contains(gate))
            #expect(!mutated.unresolvedMandatoryGates.contains(gate))
        }
        #expect(probes == 2)
    }

    @Test("An absent rights record unresolves both rights gates at once")
    func absentRightsRecordUnresolvesBoth() throws {
        let mutated = try probe(
            flips: [.repositoryCodeLicense, .dataDistributionRights],
            "an absent rights record must unresolve exactly its two gates"
        ) {
            try PipelineBaseline.evidence(distributionRights: .some(nil))
        }
        for gate in [ReleaseGate.repositoryCodeLicense, .dataDistributionRights] {
            let entry = mutated.gate(gate)
            #expect(entry.outcome == GateOutcome.notExecuted)
            #expect(entry.unprovisionedInputs == [.approvedDistributionRightsRecords])
            #expect(!entry.isSatisfied)
        }
    }

    @Test("A rejected governance decision fails its gate and reports the hard blocker")
    func rejectedGovernanceIsAHardBlocker() throws {
        let mutated = try probe(
            flips: [.modelGovernanceDecision],
            "a rejected governance decision must flip exactly the governance gate"
        ) {
            try PipelineBaseline.evidence(
                modelGovernance: try PipelineSample.governance(decision: .rejected)
            )
        }
        let entry = mutated.gate(.modelGovernanceDecision)
        #expect(entry.outcome == GateOutcome.failed)
        var rejections = 0
        for finding in entry.findings {
            if case let .externalDecisionRejected(kind) = finding {
                rejections += 1
                #expect(kind == ReleaseRecordEvidenceKind.governance)
            }
        }
        #expect(rejections == 1)
        // Requirement 14.17 makes this one a hard public-launch blocker by name.
        #expect(mutated.blockingHardPublicLaunchBlockers.contains(.modelGovernanceDecision))
    }

    @Test("An absent governance decision unresolves its gate and is still a hard blocker")
    func absentGovernanceIsAlsoAHardBlocker() throws {
        let mutated = try probe(
            flips: [.modelGovernanceDecision],
            "an absent governance decision must unresolve exactly the governance gate"
        ) {
            try PipelineBaseline.evidence(modelGovernance: .some(nil))
        }
        let entry = mutated.gate(.modelGovernanceDecision)
        #expect(entry.outcome == GateOutcome.notExecuted)
        #expect(entry.unprovisionedInputs == [.recordedModelGovernanceDecision])
        #expect(mutated.blockingHardPublicLaunchBlockers.contains(.modelGovernanceDecision))
    }

    @Test("An unapproved capability manifest fails the capability gate only")
    func anUnapprovedManifestFailsTheCapabilityGate() throws {
        let mutated = try probe(
            flips: [.capabilityManifestMatch],
            "an unapproved capability manifest must flip exactly the capability gate"
        ) {
            try PipelineBaseline.evidence(
                capabilityManifest: try Sample.releaseManifest(
                    approval: Sample.approval(.rejected, identifier: "approval.capability-manifest")
                )
            )
        }
        let entry = mutated.gate(.capabilityManifestMatch)
        #expect(entry.outcome == GateOutcome.failed)
        var rejections = 0
        for finding in entry.findings {
            if case let .externalDecisionRejected(kind) = finding {
                rejections += 1
                #expect(kind == ReleaseRecordEvidenceKind.capability)
            }
        }
        #expect(rejections == 1)
    }
}

/// The accessibility and Localization Readiness gates (Requirements 12.13, 12.14, 12.18).
@Suite("Release pipeline: accessibility and localization probes")
struct ReleasePipelineAccessibilityProbeTests {

    static let matrixGates: Set<ReleaseGate> = [.accessibilityMatrix, .localizationReadinessMatrix]

    @Test("An absent matrix run turns both gates from failing to unresolved")
    func absentMatrixUnresolvesBothGates() throws {
        // Both gates already fail in the baseline for the physical-device reason, so what the
        // probe shows is the change of *kind*: failing becomes unresolved, and the two stay
        // distinguishable, which is what Requirement 14.15 needs in order to name a blocker.
        let mutated = try probe(
            flips: Self.matrixGates,
            "an absent matrix run must change exactly the two matrix gates"
        ) {
            try PipelineBaseline.evidence(matrix: .some(nil))
        }
        for gate in Self.matrixGates {
            let entry = mutated.gate(gate)
            #expect(entry.outcome == GateOutcome.notExecuted)
            #expect(entry.unprovisionedInputs == [.accessibilityAndLocalizationMatrixRun])
            #expect(mutated.unresolvedMandatoryGates.contains(gate))
            #expect(!mutated.failingMandatoryGates.contains(gate))
        }
    }

    @Test("A matrix run with no observations fails both gates rather than unresolving them")
    func anEmptyMatrixRunFailsBothGates() throws {
        // A run that produced reports and no admissible observation is a run that happened, so it
        // fails; a run that never happened is unresolved. The record keeps them apart.
        let mutated = try probe(
            flips: [],
            "an empty matrix run reads the same as the baseline's on a host"
        ) {
            try PipelineBaseline.evidence(
                matrix: try Sample.joinedMatrixReport(
                    plan: try PipelineBaseline.plan(),
                    versionTuple: try PipelineBaseline.tuple(),
                    complete: false
                )
            )
        }
        for gate in Self.matrixGates {
            #expect(mutated.gate(gate).outcome == GateOutcome.failed)
        }
    }
}

// MARK: - Conditional capabilities

/// Provenance applicability and fusion, preserved as two separate recorded decisions
/// (Requirements 6.1-6.3, 7.14-7.16).
@Suite("Release pipeline: conditional applicability probes")
struct ReleasePipelineConditionalProbeTests {

    @Test("Each conditional gate declared applicable on a pixel-only build flips only itself")
    func eachConditionalDeclaredApplicableFlipsOnlyItself() throws {
        var probes = 0
        for gate in [ReleaseGate.provenanceFeasibility, .fusionRuleApproval] {
            probes += 1
            let mutated = try probe(
                flips: [gate],
                "one conditional gate declared applicable must flip exactly itself"
            ) {
                try PipelineBaseline.evidence(
                    conditionalApplicability: [
                        .provenanceFeasibility: gate == .provenanceFeasibility
                            ? .applicable
                            : PipelineSample.notApplicable(identifier: "approval.no-provenance"),
                        .fusionRuleApproval: gate == .fusionRuleApproval
                            ? .applicable
                            : PipelineSample.notApplicable(identifier: "approval.no-fusion"),
                    ]
                )
            }
            let entry = mutated.gate(gate)
            #expect(entry.outcome == GateOutcome.failed)
            var disagreements = 0
            var unbacked = 0
            for finding in entry.findings {
                switch finding {
                case let .conditionalApplicabilityDisagreesWithManifest(named, compiled, declared):
                    disagreements += 1
                    #expect(named == gate)
                    #expect(!compiled)
                    #expect(declared)
                case .conditionalCapabilityUnbacked:
                    unbacked += 1
                default:
                    Issue.record("an unexpected finding on a conditional gate")
                }
            }
            #expect(disagreements == 1)
            // A lane this build does not compile has nothing behind it either, so both fire.
            #expect(unbacked == 1)
        }
        #expect(probes == 2)
    }

    @Test("An absent applicability decision unresolves both conditional gates")
    func absentApplicabilityUnresolvesBoth() throws {
        let mutated = try probe(
            flips: [.provenanceFeasibility, .fusionRuleApproval],
            "an absent applicability decision must change exactly the two conditional gates"
        ) {
            try PipelineBaseline.evidence(conditionalApplicability: [:])
        }
        for gate in [ReleaseGate.provenanceFeasibility, .fusionRuleApproval] {
            let entry = mutated.gate(gate)
            #expect(entry.outcome == GateOutcome.notExecuted)
            #expect(
                entry.unprovisionedInputs.contains(.conditionalCapabilityApplicabilityDecision)
            )
            // Absent is not "disabled": the assembler mints `.applicable` so the gate reads as
            // unresolved rather than waived, and cannot be satisfied.
            #expect(entry.applicability.isApplicable)
            #expect(!entry.isSatisfied)
            #expect(mutated.unresolvedMandatoryGates.contains(gate))
        }
    }

    @Test("An unapproved waiver waives nothing")
    func anUnapprovedWaiverWaivesNothing() throws {
        var probes = 0
        for gate in [ReleaseGate.provenanceFeasibility, .fusionRuleApproval] {
            probes += 1
            let mutated = try probe(
                flips: [gate],
                "one rejected waiver must flip exactly its own conditional gate"
            ) {
                try PipelineBaseline.evidence(
                    conditionalApplicability: [
                        .provenanceFeasibility: PipelineSample.notApplicable(
                            gate == .provenanceFeasibility ? .rejected : .approved,
                            identifier: "approval.no-provenance"
                        ),
                        .fusionRuleApproval: PipelineSample.notApplicable(
                            gate == .fusionRuleApproval ? .rejected : .approved,
                            identifier: "approval.no-fusion"
                        ),
                    ]
                )
            }
            let entry = mutated.gate(gate)
            #expect(entry.outcome == GateOutcome.notExecuted)
            #expect(!entry.isSatisfied)
            #expect(mutated.failingMandatoryGates.contains(gate))
        }
        #expect(probes == 2)
    }

    @Test("A provenance-enabled manifest keeps the two decisions separate")
    func provenanceAndFusionStaySeparateDecisions() throws {
        // Requirement 7.16 permits a provenance-enabled release with no Combined Summary, so the
        // two gates carry two decisions and neither is inferred from the other.
        let manifest = try Sample.releaseManifest(provenanceEnabled: true, fusionEnabled: false)
        let assembled = ReleaseRecordAssembler().assemble(
            try PipelineBaseline.evidence(
                capabilityManifest: manifest,
                deviceEvidence: [
                    try Sample.coherentDeviceEvidence(
                        versionTuple: try Sample.joinedTuple(provenanceEnabled: true),
                        capabilityManifest: manifest,
                        provenanceApplicable: true
                    )
                ],
                conditionalApplicability: [
                    .provenanceFeasibility: .applicable,
                    .fusionRuleApproval: PipelineSample.notApplicable(
                        identifier: "approval.no-fusion"
                    ),
                ]
            )
        )
        #expect(assembled.enablesProvenance)
        #expect(!assembled.enablesFusion)
        // The provenance gate is applicable and unbacked, because the device provenance fixture
        // gate cannot pass on a host. That is the honest reading, not an approval.
        let provenance = assembled.gate(.provenanceFeasibility)
        #expect(provenance.outcome == GateOutcome.failed)
        var unbacked = 0
        for finding in provenance.findings {
            if case .conditionalCapabilityUnbacked = finding { unbacked += 1 }
        }
        #expect(unbacked == 1)
    }
}

// MARK: - Allowlisting

/// The device-allowlist gate (Requirements 13.18-13.22).
@Suite("Release pipeline: allowlisting probes")
struct ReleasePipelineAllowlistProbeTests {

    @Test("Absent device evidence unresolves the allowlist and fixture gates")
    func absentDeviceEvidenceUnresolvesTwoGates() throws {
        let mutated = try probe(
            flips: [.deviceAllowlist, .fixtureSuiteCompleteness],
            "absent device evidence must change exactly the allowlist and fixture gates"
        ) {
            try PipelineBaseline.evidence(deviceEvidence: [])
        }
        let allowlist = mutated.gate(.deviceAllowlist)
        #expect(allowlist.outcome == GateOutcome.notExecuted)
        #expect(allowlist.unprovisionedInputs == [.coherentPhysicalDeviceEvidenceSet])
        // The fixture gate reads the catalogue that arrives with the device evidence, so it is
        // owed the signed suite inventory rather than reporting a complete suite over nothing.
        let fixtures = mutated.gate(.fixtureSuiteCompleteness)
        #expect(fixtures.outcome == GateOutcome.notExecuted)
        #expect(fixtures.unprovisionedInputs == [.signedReleaseFixtureSuiteInventory])
    }

    @Test("A second evidence set for one configuration identity adds exactly one exclusion")
    func aDuplicateConfigurationAddsOneExclusion() throws {
        // The allowlist gate already fails in the baseline, so the reading does not change; what
        // changes is the exclusion count, which the probe asserts directly.
        let mutated = try probe(
            flips: [],
            "a duplicate configuration changes the exclusion list, not a gate reading"
        ) {
            try PipelineBaseline.evidence(
                deviceEvidence: [
                    try Sample.coherentDeviceEvidence(),
                    try Sample.coherentDeviceEvidence(),
                ]
            )
        }
        #expect(mutated.allowlist.excluded.count == 2)
        #expect(mutated.allowlist.isEmpty)
        #expect(!mutated.allowlist.permitsDistribution)
        var exclusions = 0
        for finding in mutated.gate(.deviceAllowlist).findings {
            if case .deviceConfigurationExcluded = finding { exclusions += 1 }
        }
        #expect(exclusions == 2)
    }

    @Test("The allowlist is empty for the environment reason before any gate outcome matters")
    func exclusionIsAttributedToTheEnvironmentFirst() throws {
        let assembled = try PipelineBaseline.assembled()
        let exclusion = try #require(assembled.allowlist.excluded.first)
        guard case let .notPhysicalDeviceEvidence(environment) = exclusion.reason else {
            Issue.record("host evidence must be excluded as non-physical-device evidence first")
            return
        }
        #expect(!environment.isPhysicalDeviceEvidence)
        // And the over-determination stands beside it: three of the 22 mandatory device gates
        // cannot pass whatever is measured, so the allowlist would stay empty on a real iPhone.
        #expect(
            assembled.standingLimits.contains(.noJointlySatisfiableMandatoryDeviceGateSetExists)
        )
    }

    @Test("The generated allowlist is bound to the signed manifest's artifact and build")
    func generationIsBoundToTheSignedManifest() throws {
        let manifest = try PipelineBaseline.manifest()
        let assembled = try PipelineBaseline.assembled()
        #expect(assembled.allowlist.appBuild == manifest.appBuild)
        #expect(assembled.allowlist.allowlist.id == manifest.approvedConfigurationAllowlist)
        #expect(assembled.appBuild == manifest.appBuild)
    }
}

// MARK: - Published claims

/// Requirement 14.12's claim bindings, one redirect each.
@Suite("Release pipeline: published-claim binding probes")
struct ReleasePipelineClaimProbeTests {

    @Test("Publishing one claim flips exactly the claim gate")
    func publishingOneClaimFlipsOnlyTheClaimGate() throws {
        // The reading flip, measured against the claim-free baseline: adding a claim changes one
        // gate and nothing else. What makes it fail is Requirement 14.7's standing corpus
        // exclusions rather than the claim's bindings, which the previous suite pins.
        try probe(
            flips: [.benchmarkClaimBindings],
            "publishing one claim must change exactly the claim gate"
        ) {
            try PipelineBaseline.evidence(benchmarkClaims: [try PipelineSample.benchmarkClaim()])
        }
    }

    @Test("Each claim binding redirected elsewhere adds exactly its own binding finding")
    func eachClaimBindingAddsExactlyOneFinding() throws {
        // Measured at finding granularity against the claim-bearing reference rather than as a
        // reading flip, because that gate already fails there for the corpus reason and no
        // available remediation removes it. Each probe therefore asserts that exactly one
        // `claimBindingMismatch` appears, at exactly the redirected field, and that nothing else
        // in the record moves.
        let reference = try PipelineBaseline.claimBearing()
        let referenceFindings = findingDescriptions(of: .benchmarkClaimBindings, in: reference)
        let elsewhere = PipelineSample.evidence("document.somewhere-else")
        let mutations: [(String, () throws -> BenchmarkClaimRecord)] = [
            ("modelBundle", { try PipelineSample.benchmarkClaim(
                modelBundle: ModelBundleID("bundle.other")!
            ) }),
            ("calibrationPolicy", { try PipelineSample.benchmarkClaim(
                calibrationPolicy: "policy.other-calibration"
            ) }),
            ("activeLimitations", { try PipelineSample.benchmarkClaim(
                activeLimitations: elsewhere
            ) }),
            ("correctionChannel", { try PipelineSample.benchmarkClaim(
                correctionChannel: elsewhere
            ) }),
        ]
        var probes = 0
        for (field, build) in mutations {
            probes += 1
            let mutated = try probe(
                flips: [],
                "a redirected binding must not change any other gate's reading",
                against: reference
            ) {
                try PipelineBaseline.evidence(benchmarkClaims: [try build()])
            }
            let entry = mutated.gate(.benchmarkClaimBindings)
            #expect(entry.outcome == GateOutcome.failed)
            var mismatches = 0
            for finding in entry.findings {
                if case let .claimBindingMismatch(claim, named) = finding {
                    mismatches += 1
                    #expect(claim == Sample.artifact(PipelineSample.claimIdentifier))
                    #expect(named == field)
                }
            }
            #expect(mismatches == 1)
            // Exactly one finding more than the reference, and it is the redirected binding.
            let added = findingDescriptions(of: .benchmarkClaimBindings, in: mutated)
                .subtracting(referenceFindings)
            #expect(added.count == 1)
            let removed = referenceFindings
                .subtracting(findingDescriptions(of: .benchmarkClaimBindings, in: mutated))
            #expect(removed.isEmpty)
        }
        #expect(probes == 4)
    }

    @Test("An absent limitations document or correction channel unresolves two gates")
    func absentPublicationUnresolvesTwoGates() throws {
        var probes = 0
        for gate in [ReleaseGate.activeLimitationsPublication, .correctionChannel] {
            probes += 1
            let mutated = try probe(
                flips: [gate, .benchmarkClaimBindings],
                "an absent published document must change its own gate and the claim gate"
            ) {
                try PipelineBaseline.evidence(
                    activeLimitations: gate == .activeLimitationsPublication
                        ? .some(nil)
                        : PipelineSample.activeLimitations(),
                    correctionChannel: gate == .correctionChannel
                        ? .some(nil)
                        : PipelineSample.correctionChannel()
                )
            }
            let entry = mutated.gate(gate)
            #expect(entry.outcome == GateOutcome.notExecuted)
            #expect(entry.unprovisionedInputs == [.publishedLimitationsAndCorrectionChannel])
            // Requirement 14.12 binds every claim to both, so the claim gate cannot resolve
            // either — a claim bound to a document the release does not publish is unbindable.
            let claim = mutated.gate(.benchmarkClaimBindings)
            #expect(claim.outcome == GateOutcome.notExecuted)
        }
        #expect(probes == 2)
    }

    @Test("A release publishing no claim passes the claim gate")
    func publishingNoClaimIsValid() throws {
        // An empty claim list is a valid recorded state: a release may publish no benchmark
        // claim. It is not the gate being skipped.
        let assembled = try PipelineBaseline.assembled()
        #expect(assembled.gate(.benchmarkClaimBindings).outcome == GateOutcome.passed)
        #expect(assembled.evidence.benchmarkClaims.isEmpty)
        // And the standing limit about unreconciled claim coverage applies only where a claim
        // exists, so it drops away with the claim rather than being carried over nothing.
        #expect(
            !assembled.standingLimits.contains(
                .publishedClaimCoverageIsNotReconciledAgainstSliceMeasurements
            )
        )
        #expect(assembled.standingLimits.count == 4)
    }
}

// MARK: - Citations

/// Requirement 14.1's mapping: every gate names an immutable source artifact.
@Suite("Release pipeline: gate citation probes")
struct ReleasePipelineCitationProbeTests {

    @Test("Removing one gate's citation unresolves exactly that gate")
    func removingOneCitationUnresolvesExactlyThatGate() throws {
        var probes = 0
        // Every gate, one at a time. This is the one probe that is total over `ReleaseGate`,
        // because Requirement 14.1's mapping is a property of every entry rather than of a kind.
        for gate in ReleaseGate.allCases {
            probes += 1
            var citations: [ReleaseGate: EvidenceSource] = [:]
            for other in ReleaseGate.allCases where other != gate {
                citations[other] = Sample.matrixEvidence("result.\(other.rawValue)", digest: 0xC0)
            }
            let assembled = ReleaseRecordAssembler().assemble(
                try PipelineBaseline.evidence(gateCitations: citations)
            )
            let entry = assembled.gate(gate)
            #expect(entry.citation == nil)
            #expect(entry.outcome == GateOutcome.notExecuted)
            #expect(entry.unprovisionedInputs.contains(.releaseGateEvidenceCitation))
            let unwritable = assembled.gatesNamingNoEvidence
            #expect(unwritable == Set([gate]))

            // And the output refuses on the uncited gate before any outcome is considered.
            var refusal: ReleaseRecordOutputRefusal?
            do {
                _ = try assembled.releaseOutput()
            } catch {
                refusal = error as? ReleaseRecordOutputRefusal
            }
            guard case let .gateNamesNoEvidence(named) = try #require(refusal) else {
                Issue.record("an uncited gate must refuse the output first")
                continue
            }
            #expect(named == [gate])
        }
        #expect(probes == 26)
        #expect(probes == ReleaseGate.allCases.count)
    }
}
