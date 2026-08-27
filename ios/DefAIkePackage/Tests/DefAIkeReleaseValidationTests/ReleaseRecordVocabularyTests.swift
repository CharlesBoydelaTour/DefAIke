import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// The two new gap vocabularies, and what the record cannot be made to do.
//
// Fifteen closed gap vocabularies already exist across the `ios` tree. A release audit pools
// them, so a raw value that collided with one would be two different gaps reported under one
// identifier. This suite checks disjointness against every one, checks that neither vocabulary
// has a case meaning "proceed anyway", and scans this task's sources for the one thing that would
// undo the derived-outcome rule: a stored or handed-in gate outcome.
//
// Comments are stripped before every source scan, because the sources discuss the absence of
// these things by name and a naive substring match would flag the prose.

@Suite("Release record: vocabularies")
struct ReleaseRecordVocabularyTests {

    // MARK: Shape

    @Test("Both vocabularies are closed, ordered, and self-describing")
    func vocabulariesAreClosedAndSelfDescribing() {
        #expect(UnprovisionedReleaseRecordInput.allCases.count == 13)
        #expect(UnobservableReleaseRecordEvidence.allCases.count == 5)
        for input in UnprovisionedReleaseRecordInput.allCases {
            #expect(input.description == input.rawValue)
            #expect(!input.rawValue.isEmpty)
            #expect(input.rawValue == input.rawValue.lowercased())
        }
        for limit in UnobservableReleaseRecordEvidence.allCases {
            #expect(limit.description == limit.rawValue)
            #expect(!limit.rawValue.isEmpty)
            #expect(limit.rawValue == limit.rawValue.lowercased())
        }
        for kind in ReleaseRecordEvidenceKind.allCases {
            #expect(kind.description == kind.rawValue)
        }
    }

    @Test("Raw values are unique inside each vocabulary")
    func rawValuesAreUniqueWithinEachVocabulary() {
        let inputs = Set(UnprovisionedReleaseRecordInput.allCases.map(\.rawValue))
        #expect(inputs.count == UnprovisionedReleaseRecordInput.allCases.count)
        let limits = Set(UnobservableReleaseRecordEvidence.allCases.map(\.rawValue))
        #expect(limits.count == UnobservableReleaseRecordEvidence.allCases.count)
        let kinds = Set(ReleaseRecordEvidenceKind.allCases.map(\.rawValue))
        #expect(kinds.count == ReleaseRecordEvidenceKind.allCases.count)
    }

    @Test("No case means proceed anyway, assume, approximate, skip, or warn")
    func noVocabularyCaseSoftensAFailure() {
        let softening = [
            "proceed", "assume", "approximate", "skip", "warn", "ignore", "acceptable",
            "tolerated", "waive", "override", "best-effort", "partial", "probably",
        ]
        var scanned = 0
        for value in UnprovisionedReleaseRecordInput.allCases.map(\.rawValue)
            + UnobservableReleaseRecordEvidence.allCases.map(\.rawValue)
            + ReleaseRecordEvidenceKind.allCases.map(\.rawValue)
        {
            scanned += 1
            for token in softening {
                #expect(!value.contains(token), "\(value) softens a failing input")
            }
        }
        #expect(scanned == 30)
    }

    // MARK: Disjointness against the fifteen existing vocabularies

    @Test("Raw values are disjoint from every existing gap vocabulary")
    func rawValuesAreDisjointFromEveryExistingVocabulary() {
        var existing: Set<String> = []
        existing.formUnion(UnprovisionedParityInput.allCases.map(\.rawValue))
        existing.formUnion(UnobservableParityEvidence.allCases.map(\.rawValue))
        existing.formUnion(UnprovisionedResourceInput.allCases.map(\.rawValue))
        existing.formUnion(UnobservableResourceEvidence.allCases.map(\.rawValue))
        existing.formUnion(UnprovisionedAccessibilityMatrixInput.allCases.map(\.rawValue))
        existing.formUnion(UnobservableAccessibilityMatrixEvidence.allCases.map(\.rawValue))
        existing.formUnion(UnprovisionedArchiveAuditInput.allCases.map(\.rawValue))
        existing.formUnion(UnobservableArchiveAuditEvidence.allCases.map(\.rawValue))
        existing.formUnion(ArchiveAuditFailingInputClass.allCases.map(\.rawValue))
        // The counts the four sibling tasks recorded, so a vocabulary that shrank is visible
        // here rather than making the disjointness claim weaker.
        #expect(UnprovisionedParityInput.allCases.count == 12)
        #expect(UnobservableParityEvidence.allCases.count == 8)
        #expect(UnprovisionedResourceInput.allCases.count == 12)
        #expect(UnobservableResourceEvidence.allCases.count == 15)
        #expect(UnprovisionedAccessibilityMatrixInput.allCases.count == 12)
        #expect(UnobservableAccessibilityMatrixEvidence.allCases.count == 12)
        #expect(UnprovisionedArchiveAuditInput.allCases.count == 6)
        #expect(UnobservableArchiveAuditEvidence.allCases.count == 8)
        #expect(ArchiveAuditFailingInputClass.allCases.count == 5)
        #expect(existing.count == 90)

        var mine: Set<String> = []
        mine.formUnion(UnprovisionedReleaseRecordInput.allCases.map(\.rawValue))
        mine.formUnion(UnobservableReleaseRecordEvidence.allCases.map(\.rawValue))
        mine.formUnion(ReleaseRecordEvidenceKind.allCases.map(\.rawValue))
        #expect(mine.count == 30)
        #expect(mine.intersection(existing).isEmpty)

        // And disjoint from the two gate vocabularies, so a pooled report cannot read a gap
        // identifier as a gate identifier.
        var gates: Set<String> = []
        gates.formUnion(ReleaseGate.allCases.map(\.rawValue))
        gates.formUnion(DeviceGate.allCases.map(\.rawValue))
        #expect(mine.intersection(gates).isEmpty)
    }

    // MARK: Findings and refusals describe themselves

    @Test("Every finding and refusal renders a nonempty description")
    func findingsAndRefusalsDescribeThemselves() throws {
        let findings: [ReleaseRecordFinding] = [
            .evidenceAbsent(.calibration),
            .contributingResultFailed(.archive, detail: "notice-gap: no root notice"),
            .externalDecisionRejected(.legal),
            .noPassingDeviceConfiguration,
            .deviceConfigurationExcluded(
                ApprovedConfigurationID("configuration.sample")!,
                .notPhysicalDeviceEvidence(.developmentMac)
            ),
            .fixtureFamilyAbsent(.modelParity),
            .modelParityCoverageIncomplete(observed: 0, required: 96),
            .modelBundleOutsideApprovedCatalog(Sample.bundle()),
            .bundleEvidenceNamesAnotherBundle(
                expected: Sample.bundle(),
                found: ModelBundleID("bundle.other")!
            ),
            .claimBindingMismatch(Sample.artifact("claim.sample"), field: "modelBundle"),
            .claimRestsOnExcludedCorpusEntry(count: 3),
            .mandatoryGatingSliceAbsent("contemporary-phone-camera"),
            .conditionalApplicabilityDisagreesWithManifest(
                .provenanceFeasibility,
                compiled: false,
                declared: true
            ),
            .conditionalCapabilityUnbacked(.fusionRuleApproval),
        ]
        #expect(findings.count == 14)
        for finding in findings {
            #expect(!finding.description.isEmpty)
        }

        let refusals: [ReleaseRecordOutputRefusal] = [
            .mandatoryGatesFailing([.archiveAudit]),
            .mandatoryGatesUnresolved([.deviceAllowlist]),
            .gateNamesNoEvidence([.correctionChannel]),
            .noPassingDeviceConfiguration,
            .hardPublicLaunchBlocker([.modelGovernanceDecision]),
            .unprovisionedInputs([.approvedCalibrationRelease]),
        ]
        #expect(refusals.count == 6)
        for refusal in refusals {
            #expect(!refusal.description.isEmpty)
        }

        let exclusions: [DeviceExclusionReason] = [
            .mandatoryGatesUnsatisfied([.rawLogitParity]),
            .notPhysicalDeviceEvidence(.iOSSimulator),
            .duplicateConfigurationIdentity(ApprovedConfigurationID("configuration.sample")!),
            .duplicateConfigurationTriple(Sample.hardware(), .iOS17),
            .entryNotRepresentable("a schema refusal"),
        ]
        #expect(exclusions.count == 5)
        for exclusion in exclusions {
            #expect(!exclusion.description.isEmpty)
        }

        let coherence: [ReleaseRecordCoherenceError] = [
            .configurationMixed(expected: Sample.hardware(), found: DeviceHardwareID("iPhone17.2")!),
            .operatingSystemVersionMixed(expected: .iOS17, found: .iOS17),
            .versionTupleMixed(.device),
            .runEnvironmentMixed(expected: .developmentMac, found: .iOSSimulator),
            .appBuildNotTheManifestBuild(
                expected: Sample.appBuild(),
                found: AppBuildID("build.other")!
            ),
            .configurationAppBuildMismatch(
                expected: Sample.appBuild(),
                found: AppBuildID("build.other")!
            ),
            .capabilityManifestMismatch(
                expected: Sample.artifact("manifest.capability"),
                found: Sample.artifact("manifest.other")
            ),
            .capabilitySetMismatch(expected: ["pixel-analysis"], found: []),
            .capabilityImplementationVersionMismatch(
                capability: .pixelAnalysis,
                expected: Sample.version("1.0.0"),
                found: Sample.version("2.0.0")
            ),
            .modelBundleOutsideApprovedCatalog(Sample.bundle()),
            .fixtureSuiteMismatch(
                expected: Sample.artifact("suite.fixtures"),
                found: Sample.artifact("suite.other")
            ),
            .validationPlanMismatch(
                kind: .accessibility,
                expected: Sample.artifact("plan.device-validation"),
                found: Sample.artifact("plan.other")
            ),
        ]
        #expect(coherence.count == 12)
        for error in coherence {
            #expect(!error.description.isEmpty)
        }
    }
}

// MARK: - Source boundary

/// What this task's sources cannot do, asserted against the sources themselves.
///
/// "The outcome is derived, never stored" and "this module signs nothing and approves nothing"
/// are statements about reachability rather than behaviour: the interesting failure is a future
/// change that adds the capability. So they are scanned the same way
/// ``BundleToolingBoundaryTests`` scans for key custody.
@Suite("Release record: source boundary")
struct ReleaseRecordBoundaryTests {

    static let recordSources = [
        "ReleaseRecordError.swift",
        "ReleaseRecordInputs.swift",
        "ReleaseRecordAssembly.swift",
    ]

    @Test("No gate outcome can be stored or handed in")
    func noGateOutcomeIsStoredOrAccepted() throws {
        // The derived-outcome rule, as a reachability claim. A stored property, an initializer
        // parameter, or an assignment carrying a `GateOutcome` would each be a second place a
        // `passed` could be written down, and that second place is exactly what makes a record
        // claiming a passing gate beside a failing input representable.
        for name in Self.recordSources {
            let code = Self.strippingComments(try Self.source(named: name))
            for token in [
                "let outcome: GateOutcome",
                "var outcome: GateOutcome =",
                "outcome: GateOutcome,",
                "outcome: GateOutcome)",
                "self.outcome =",
            ] {
                #expect(!code.contains(token), "\(name) must not carry a gate outcome (\(token))")
            }
        }
        // And the one member that answers the question is a computed property.
        let inputs = Self.strippingComments(try Self.source(named: "ReleaseRecordInputs.swift"))
        #expect(inputs.contains("public var outcome: GateOutcome {"))
    }

    @Test("Nothing here mints an approval, an applicability decision, or a signature")
    func nothingMintsAnApprovalOrSignature() throws {
        // The same tokens `BundleToolingBoundaryTests` uses, applied to this task's sources so a
        // change that reaches for key custody or supplies a decision fails here rather than in
        // review. An approval arrives inside an approved input and `isApproved` is read.
        for name in Self.recordSources {
            let code = Self.strippingComments(try Self.source(named: name))
            for token in [
                "ApprovalRecord(", "ApprovalDecision(", "ApprovalDecision.approved",
                "ApprovalDecision.rejected", "decision: .", "notApplicable(",
                "GateApplicability(", "isApproved =",
                "SecKey", "Keychain", "keychain", "privateKey", "PrivateKey",
                "func sign(", ".sign(", "signingIdentity", "Curve25519", "P256",
            ] {
                #expect(!code.contains(token), "\(name) must not reference \(token)")
            }
        }
    }

    @Test("Only the assembler can construct a gate evidence value or a release output")
    func recordValuesAreNotClientConstructible() throws {
        // "Generated, not asserted" is structural: the three produced record types keep
        // module-internal initializers, so no caller outside `DefAIkeReleaseValidation` can hand
        // in a finding-free gate, an admitted allowlist, or a release payload.
        let inputs = Self.strippingComments(try Self.source(named: "ReleaseRecordInputs.swift"))
        // `CoherentDeviceEvidence` and the two error-shaped values are client-constructible on
        // purpose: joining evidence is what a caller does, and construction is the check.
        #expect(inputs.contains("public struct ReleaseGateEvidence"))
        #expect(inputs.contains("\n    init(\n        gate: ReleaseGate,"))

        let assembly = Self.strippingComments(
            try Self.source(named: "ReleaseRecordAssembly.swift")
        )
        for declaration in [
            "public struct GeneratedDeviceAllowlist",
            "public struct AssembledReleaseRecord",
            "public struct ReleaseRecordOutput",
        ] {
            #expect(assembly.contains(declaration))
        }
        // Two public initializers in the assembly file: the evidence a caller supplies and the
        // stateless assembler itself.
        let publicInitializers = assembly.components(separatedBy: "public init").count - 1
        #expect(publicInitializers == 2, "only the evidence set and the assembler are public")
        #expect(assembly.contains("public init(\n        recordID: ArtifactID,"))
        #expect(assembly.contains("public init() {}"))
    }

    @Test("The module reads no filesystem path and reaches into no adjacent audit")
    func moduleDoesNotReachOutside() throws {
        for name in Self.recordSources {
            let code = Self.strippingComments(try Self.source(named: name))
            for token in [
                "URL", "FileManager", "URLSession", "import Network", "Process(",
                "sbom", "SBOM", "forbiddenSDK", "networkEndpoint", "exportCompliance",
            ] {
                #expect(!code.contains(token), "\(name) must not reference \(token)")
            }
        }
    }

    // MARK: Helpers

    private static func source(named name: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DefAIkeReleaseValidation")
            .appendingPathComponent(name)
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Removes `//` comment text so a scan reads code rather than documentation.
    private static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let marker = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<marker.lowerBound])
            }
            .joined(separator: "\n")
    }
}
