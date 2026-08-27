import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// Generating allowlist entries only for exact coherent passing tuples.
//
// Requirement 13.18 admits a configuration that passes every mandatory gate with matching
// device, operating-system, application-build, Model Bundle, fixture-suite, plan,
// enabled-capability, and implementation versions; Requirement 13.19 excludes one whose result is
// missing or failing; Requirement 13.21 excludes one whose parity fails a plan limit; and
// Requirement 13.22 blocks distribution when none passes.
//
// Two structural claims this suite checks, both about what the generator *cannot* emit:
//
//   * **Two entries that disagree about the application build.** There is one `AppBuildID` in
//     scope for a whole generation, read from the signed manifest, and every candidate's tuple is
//     compared against it. So a disagreeing pair is not detected and rejected — it cannot be
//     assembled, because there is no per-entry build to disagree with.
//   * **An entry in which nothing ran claiming every gate satisfied.** The generator mints
//     `.applicable` for the 21 unconditional device gates, so a generated entry can never carry
//     a not-applicable reference for one — which is the shape that makes
//     `GateResultReference.isSatisfied` report an entry where nothing ran as fully satisfied.
//
// **No value here is an approved release value**, and no test here makes a device gate
// satisfiable. Only the iOS 26.5 simulator runtime exists, so the generated allowlist is empty
// and this suite asserts that as the correct reported state.

@Suite("Release record: allowlist generation")
struct DeviceAllowlistGenerationTests {

    // MARK: Today's state

    @Test("Zero passing device configurations produces an empty allowlist that blocks")
    func hostEvidenceProducesAnEmptyAllowlist() throws {
        let device = try Sample.coherentDeviceEvidence()
        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(deviceEvidence: [device])
        )
        let allowlist = assembled.allowlist
        #expect(allowlist.isEmpty)
        #expect(allowlist.admitted.isEmpty)
        #expect(!allowlist.permitsDistribution)
        #expect(allowlist.excluded.count == 1)

        // The exclusion names the environment rather than a bare failure, so an audit reads why.
        let exclusion = try #require(allowlist.excluded.first)
        guard case let .notPhysicalDeviceEvidence(environment) = exclusion.reason else {
            Issue.record("host evidence must be excluded as non-physical-device evidence")
            return
        }
        #expect(!environment.isPhysicalDeviceEvidence)
        #expect(exclusion.configurationID.rawValue == "configuration.sample")
    }

    @Test("The generated allowlist names the manifest's allowlist artifact and build")
    func generationIsBoundToTheSignedManifest() throws {
        let manifest = try Sample.releaseManifest()
        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(capabilityManifest: manifest)
        )
        #expect(assembled.allowlist.appBuild == manifest.appBuild)
        #expect(assembled.allowlist.allowlist.id == manifest.approvedConfigurationAllowlist)
        #expect(assembled.appBuild == manifest.appBuild)
    }

    @Test("Every admitted entry names the one application build the manifest names")
    func admittedEntriesShareTheManifestBuild() throws {
        // The invariant, asserted over the admitted set rather than argued. It holds vacuously
        // today, and the structural reason it will keep holding is that `appBuild` is read from
        // the manifest once for the whole generation.
        let device = try Sample.coherentDeviceEvidence()
        let manifest = try Sample.releaseManifest()
        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(capabilityManifest: manifest, deviceEvidence: [device])
        )
        var builds: Set<String> = []
        for entry in assembled.allowlist.allowlist.entries {
            builds.insert(entry.versionTuple.appBuild.rawValue)
            builds.insert(entry.configuration.appBuild.rawValue)
        }
        #expect(builds.count <= 1)
        for build in builds { #expect(build == manifest.appBuild.rawValue) }
        // And the generator's single source for that build is the manifest, so a pair that
        // disagreed would have to come from two manifests, which one assembly cannot hold.
        #expect(assembled.allowlist.appBuild == manifest.appBuild)
    }

    @Test("A candidate whose evidence names another build never reaches the generator")
    func aDisagreeingBuildIsRefusedBeforeGeneration() throws {
        // The generator is never handed the disagreeing candidate at all: coherence refuses it,
        // so the exclusion list is not where a build disagreement shows up. That is the point —
        // an excluded entry is still an entry someone could read as "considered".
        let otherBuild = AppBuildID("build.other")!
        let plan = try Sample.resourcePlan(appBuild: otherBuild)
        #expect(throws: ReleaseRecordCoherenceError.self) {
            _ = try Sample.coherentDeviceEvidence(
                plan: plan,
                configuration: plan.candidateConfigurations[0],
                versionTuple: try Sample.joinedTuple(appBuild: otherBuild)
            )
        }
    }

    @Test("Two evidence sets for one configuration identity admit at most one")
    func duplicateConfigurationIdentityIsExcluded() throws {
        let first = try Sample.coherentDeviceEvidence()
        let second = try Sample.coherentDeviceEvidence()
        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(deviceEvidence: [first, second])
        )
        // Both are excluded here for the environment, which is checked first so the honest reason
        // is the one recorded. The uniqueness rule is what keeps two sets from pooling.
        #expect(assembled.allowlist.excluded.count == 2)
        #expect(assembled.allowlist.isEmpty)
        let identifiers = Set(assembled.allowlist.excluded.map(\.configurationID.rawValue))
        #expect(identifiers == Set(["configuration.sample"]))
    }

    // MARK: What a generated entry cannot look like

    @Test("A generated entry mints applicable for every unconditional device gate")
    func generatedEntriesNeverWaiveAnUnconditionalGate() throws {
        let evidence = try Sample.coherentDeviceEvidence()
        var waivable = 0
        var applicable = 0
        for gate in DeviceGate.allCases {
            let value = evidence.applicability(of: gate)
            if gate.isProvenanceConditional {
                waivable += 1
                // Carried from the catalogued suite's approved decision, not decided here.
                #expect(!value.isApplicable)
            } else {
                applicable += 1
                #expect(
                    value.isApplicable,
                    "\(gate.rawValue) is not provenance-conditional and cannot be waived"
                )
            }
        }
        #expect(waivable == 1)
        #expect(applicable == 21)
    }

    @Test("A passing reference is refused unless the environment is a physical iPhone")
    func aPassingReferenceNeedsAPhysicalIPhone() throws {
        // The second barrier, restated at the schema. A development-Mac measurement is
        // classified rather than discarded: it constructs as a failure and refuses as a pass.
        #expect(throws: (any Error).self) {
            _ = try GateResultReference(
                gate: .rawLogitParity,
                applicability: .applicable,
                outcome: .passed,
                result: Sample.evidence("result.mac"),
                environment: .developmentMac
            )
        }
        let classified = try GateResultReference(
            gate: .rawLogitParity,
            applicability: .applicable,
            outcome: .failed,
            result: Sample.evidence("result.mac"),
            environment: .developmentMac
        )
        #expect(!classified.isSatisfied)
        #expect(classified.environment == ExecutionEnvironment.developmentMac)
    }

    @Test("A screenshot-fidelity gate cannot pass whatever is measured")
    func threeMandatoryDeviceGatesAreUnsatisfiableByConstruction() throws {
        // Not a defect this task fixes, and the reason an empty allowlist here is
        // over-determined: it would stay empty with a physical iPhone and a complete plan.
        let evidence = try Sample.coherentDeviceEvidence()
        for gate in [
            DeviceGate.screenshotFidelity, .cancellationResidualWork, .interruptionCleanup,
        ] {
            #expect(
                evidence.outcome(of: gate) == GateOutcome.failed,
                "\(gate.rawValue) is unsatisfiable by construction and must read failed"
            )
        }
        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(deviceEvidence: [evidence])
        )
        #expect(
            assembled.standingLimits.contains(
                .noJointlySatisfiableMandatoryDeviceGateSetExists
            )
        )
    }

    // MARK: The record's own device gate

    @Test("The device-allowlist gate reports every exclusion and the zero-passing block")
    func theDeviceGateReportsEveryExclusion() throws {
        let evidence = try Sample.coherentDeviceEvidence()
        let assembled = ReleaseRecordAssembler().assemble(
            try Sample.recordEvidence(deviceEvidence: [evidence])
        )
        let entry = assembled.gate(.deviceAllowlist)
        #expect(entry.outcome == GateOutcome.failed)
        #expect(entry.evidenceWasProduced)
        var exclusions = 0
        var blocks = 0
        for finding in entry.findings {
            switch finding {
            case .deviceConfigurationExcluded: exclusions += 1
            case .noPassingDeviceConfiguration: blocks += 1
            default: Issue.record("the device gate recorded an unexpected finding")
            }
        }
        #expect(exclusions == 1)
        #expect(blocks == 1)
    }

    @Test("With no device evidence at all the gate is unresolved and owes the evidence set")
    func noDeviceEvidenceIsUnresolvedRatherThanFailing() throws {
        let assembled = ReleaseRecordAssembler().assemble(try Sample.recordEvidence())
        let entry = assembled.gate(.deviceAllowlist)
        #expect(!entry.evidenceWasProduced)
        #expect(entry.outcome == GateOutcome.notExecuted)
        #expect(entry.unprovisionedInputs == [.coherentPhysicalDeviceEvidenceSet])
        // Missing and failing stay distinguishable, and both block.
        #expect(assembled.unresolvedMandatoryGates.contains(.deviceAllowlist))
        #expect(!assembled.failingMandatoryGates.contains(.deviceAllowlist))
        #expect(!assembled.permitsDistribution)
    }
}
