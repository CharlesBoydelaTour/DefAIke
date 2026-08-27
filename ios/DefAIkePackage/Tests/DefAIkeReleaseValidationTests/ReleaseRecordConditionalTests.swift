import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// Conditional provenance and fusion applicability, preserved rather than collapsed.
//
// Requirement 6.1 evaluates the Provenance Feasibility Gate before the enabled capability set is
// chosen; Requirement 6.2 enables the capability when it passes; Requirement 6.3 permits a
// pixel-only release with the provenance lane unavailable and no Combined Summary when it does
// not. Requirements 7.14 through 7.16 do the same for fusion, and Requirement 7.10 forbids a
// Combined Summary without an available provenance lane.
//
// Three things are preserved here rather than reduced to one answer:
//
//   * the two gates stay two separate recorded decisions, so a pixel-only release records *why*
//     each is inapplicable rather than inferring the second from the first;
//   * an absent decision is an owed input, not a default in either direction — this module cannot
//     mint an applicability decision and does not; and
//   * the device-level provenance decision travels from the signed fixture suite through the
//     parity binding into the allowlist entry unchanged.
//
// **No decision here is an approved release decision.** Every applicability value is synthetic
// scaffolding built by `Sample`.

@Suite("Release record: conditional applicability")
struct ReleaseRecordConditionalTests {

    // MARK: The pixel-only release

    @Test("A pixel-only release records both conditional gates as separate decisions")
    func pixelOnlyRecordsTwoSeparateDecisions() throws {
        let assembled = ReleaseRecordAssembler().assemble(try Sample.recordEvidence())
        let provenance = assembled.gate(.provenanceFeasibility)
        let fusion = assembled.gate(.fusionRuleApproval)

        #expect(!provenance.applicability.isApplicable)
        #expect(!fusion.applicability.isApplicable)
        #expect(provenance.outcome == GateOutcome.notExecuted)
        #expect(fusion.outcome == GateOutcome.notExecuted)
        // Both are satisfied by their own approved decision, and each carries its own record
        // rather than one standing in for both.
        #expect(provenance.isSatisfied)
        #expect(fusion.isSatisfied)
        let provenanceDecision = try #require(
            provenance.applicability.inapplicabilityDecision
        )
        let fusionDecision = try #require(fusion.applicability.inapplicabilityDecision)
        #expect(provenanceDecision.isApproved)
        #expect(fusionDecision.isApproved)
        #expect(!assembled.enablesProvenance)
        #expect(!assembled.enablesFusion)
        // A pixel-only release is not blocked by the two conditional gates.
        #expect(!assembled.failingMandatoryGates.contains(.provenanceFeasibility))
        #expect(!assembled.unresolvedMandatoryGates.contains(.provenanceFeasibility))
    }

    @Test("An unapproved waiver waives nothing")
    func aRejectedWaiverIsNotSatisfaction() throws {
        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(
                conditionalApplicability: [
                    .provenanceFeasibility: Sample.notApplicable(.rejected),
                    .fusionRuleApproval: Sample.notApplicable(),
                ]
            )
        )
        let provenance = assembled.gate(.provenanceFeasibility)
        #expect(!provenance.isSatisfied)
        #expect(provenance.outcome == GateOutcome.notExecuted)
        #expect(assembled.failingMandatoryGates.contains(.provenanceFeasibility))
        #expect(!assembled.permitsDistribution)
    }

    @Test("An absent applicability decision is an owed input, not a disabled capability")
    func absentDecisionIsOwedRatherThanDefaulted() throws {
        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(conditionalApplicability: [:])
        )
        for gate in [ReleaseGate.provenanceFeasibility, .fusionRuleApproval] {
            let entry = assembled.gate(gate)
            #expect(entry.outcome == GateOutcome.notExecuted)
            #expect(!entry.evidenceWasProduced)
            #expect(
                entry.unprovisionedInputs.contains(.conditionalCapabilityApplicabilityDecision)
            )
            // Defaulting either way would be this module deciding the capability set.
            #expect(entry.applicability.isApplicable)
            #expect(!entry.isSatisfied)
        }
        #expect(assembled.unresolvedMandatoryGates.contains(.provenanceFeasibility))
        #expect(assembled.unresolvedMandatoryGates.contains(.fusionRuleApproval))
    }

    // MARK: Both directions are faults

    @Test("A pixel-only manifest recording provenance as applicable is a finding")
    func applicableOnAPixelOnlyBuildIsAFinding() throws {
        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(
                capabilityManifest: try Sample.releaseManifest(provenanceEnabled: false),
                conditionalApplicability: [
                    .provenanceFeasibility: .applicable,
                    .fusionRuleApproval: Sample.notApplicable(),
                ]
            )
        )
        let entry = assembled.gate(.provenanceFeasibility)
        #expect(entry.outcome == GateOutcome.failed)
        var disagreements = 0
        var unbacked = 0
        for finding in entry.findings {
            switch finding {
            case let .conditionalApplicabilityDisagreesWithManifest(gate, compiled, declared):
                disagreements += 1
                #expect(gate == ReleaseGate.provenanceFeasibility)
                #expect(!compiled)
                #expect(declared)
            case .conditionalCapabilityUnbacked:
                unbacked += 1
            default:
                Issue.record("an unexpected finding on the provenance gate")
            }
        }
        #expect(disagreements == 1)
        // And a lane this build does not have has nothing behind it either.
        #expect(unbacked == 1)
    }

    @Test("A provenance-enabled manifest recording the gate as waived is a finding")
    func waivedOnAProvenanceBuildIsAFinding() throws {
        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(
                capabilityManifest: try Sample.releaseManifest(provenanceEnabled: true),
                conditionalApplicability: [
                    .provenanceFeasibility: Sample.notApplicable(),
                    .fusionRuleApproval: Sample.notApplicable(),
                ]
            )
        )
        let entry = assembled.gate(.provenanceFeasibility)
        #expect(!entry.applicability.isApplicable)
        #expect(entry.outcome == GateOutcome.notExecuted)
        // The finding is recorded even though the derived outcome is not executed, because a
        // capability with no gate behind it is a fault in the record rather than in the run.
        var disagreements = 0
        for finding in entry.findings {
            if case .conditionalApplicabilityDisagreesWithManifest = finding { disagreements += 1 }
        }
        #expect(disagreements == 1)
    }

    @Test("An applicable provenance gate with no passing device fixture is unbacked")
    func applicableProvenanceNeedsAPassingDeviceFixture() throws {
        let manifest = try Sample.releaseManifest(provenanceEnabled: true)
        let device = try Sample.coherentDeviceEvidence(
            versionTuple: try Sample.joinedTuple(provenanceEnabled: true),
            capabilityManifest: manifest,
            provenanceApplicable: true
        )
        #expect(device.enablesProvenance)
        #expect(device.applicability(of: .provenanceFixtures).isApplicable)
        #expect(device.outcome(of: .provenanceFixtures) == GateOutcome.failed)

        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(
                capabilityManifest: manifest,
                deviceEvidence: [device],
                conditionalApplicability: [
                    .provenanceFeasibility: .applicable,
                    .fusionRuleApproval: Sample.notApplicable(),
                ]
            )
        )
        let entry = assembled.gate(.provenanceFeasibility)
        #expect(entry.outcome == GateOutcome.failed)
        var unbacked = 0
        for finding in entry.findings {
            if case .conditionalCapabilityUnbacked = finding { unbacked += 1 }
        }
        #expect(unbacked == 1)
        // No applicability disagreement: the manifest compiles provenance and the record says so.
        for finding in entry.findings {
            if case .conditionalApplicabilityDisagreesWithManifest = finding {
                Issue.record("the record and the manifest agree and must not disagree")
            }
        }
    }

    // MARK: The device-level decision travels unchanged

    @Test("The device provenance decision comes from the catalogued suite, not from here")
    func deviceProvenanceDecisionTravelsFromTheSuite() throws {
        let pixelOnly = try Sample.coherentDeviceEvidence()
        let suiteDecision = try Sample.catalog().suite.provenanceApplicability
        #expect(pixelOnly.applicability(of: .provenanceFixtures).isApplicable
            == suiteDecision.isApplicable)
        #expect(!pixelOnly.applicability(of: .provenanceFixtures).isApplicable)

        let enabled = try Sample.coherentDeviceEvidence(
            versionTuple: try Sample.joinedTuple(provenanceEnabled: true),
            capabilityManifest: try Sample.releaseManifest(provenanceEnabled: true),
            provenanceApplicable: true
        )
        let enabledSuite = try Sample.catalog(provenanceApplicable: true)
            .suite
            .provenanceApplicability
        #expect(enabled.applicability(of: .provenanceFixtures).isApplicable
            == enabledSuite.isApplicable)
        #expect(enabled.applicability(of: .provenanceFixtures).isApplicable)
    }

    @Test("Fusion applicability is not derived from provenance applicability")
    func fusionIsNotCollapsedIntoProvenance() throws {
        // A provenance-enabled release with fusion still waived is a valid recorded state
        // (Requirement 7.16), and the two gates carry two decisions.
        let manifest = try Sample.releaseManifest(provenanceEnabled: true, fusionEnabled: false)
        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(
                capabilityManifest: manifest,
                conditionalApplicability: [
                    .provenanceFeasibility: .applicable,
                    .fusionRuleApproval: Sample.notApplicable(),
                ]
            )
        )
        #expect(assembled.enablesProvenance)
        #expect(!assembled.enablesFusion)
        // The reverse — fusion applicable while provenance is not — is refused by the record
        // schema itself, which is where Requirement 7.10's coupling lives.
        let inverted = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(
                capabilityManifest: try Sample.releaseManifest(),
                conditionalApplicability: [
                    .provenanceFeasibility: Sample.notApplicable(),
                    .fusionRuleApproval: .applicable,
                ]
            )
        )
        #expect(!inverted.enablesProvenance)
        #expect(inverted.enablesFusion)
        #expect(throws: (any Error).self) { _ = try inverted.releaseOutput() }
    }
}
