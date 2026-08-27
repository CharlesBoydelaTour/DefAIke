import Foundation
import Testing

@testable import DefAIkeApplication
@testable import DefAIkeDomain
@testable import DefAIkeProvenanceAPI

// Task 9.9, fusion half: the 15 fusion fixtures driven through the lane-to-report pipeline.
//
// An *integration* test. The fusion table itself is already owned elsewhere, and this file
// references rather than restates:
//
//   * **Property 22** (`DefAIkeDomainTests/ExhaustiveOptionalFusionPropertyTests`) owns
//     exhaustiveness, determinism, and optionality over generated candidate rules, every
//     single-field defect that invalidates one, and the omission of a summary for all 21
//     representable lane pairs.
//   * `DefAIkeDomainTests/ApprovedFusionRuleTests` pins each refusal at one field.
//   * **Property 21** (`EvidenceLaneNoninterferencePropertyTests`, this target) owns lane
//     immutability and noninterference across all 21 lane pairs.
//   * **Property 19** owns capability selection and the pixel-only lane.
//
// None of them builds an `EvidenceReport`. That is what is added here: for each of the 15
// enabled lane combinations a fixture declares, the approved disposition has to survive the
// whole path — an analyzer's state, through `ProvenanceLaneProvider`, into
// `EvidenceLaneJoin`, through `EvidenceCoordinator`, and out as the report's
// `combinedSummary` — with both source-lane fields still holding exactly the values the
// fixture declared (Requirements 7.8, 7.11, 7.13, and 7.14).
//
// # The line this file does not cross
//
// **Which disposition belongs to which combination is an unresolved, externally approved
// input, and nothing here decides one.** Every expected value in every assertion below is
// read from an *artifact*: a `FixtureRecord`'s declared pixel label and provenance state, and
// an `EvidenceFusionRule` entry's declared disposition. The pipeline is the thing under
// test; the artifact is the expectation. No assertion says a mapping is correct, and no
// assertion is derived from what the pipeline produced.
//
// The approved fusion rule and fixture suite are **absent from this repository** at the time
// of writing. So:
//
//   * `approvedFusionFixturesReachTheirApprovedDisposition` is wired to
//     ``ApprovedFusionArtifacts`` and is **skipped, loudly**, until they are installed. It
//     never falls back to the synthetic table below.
//   * `absentApprovedFusionArtifactsAreRecorded` records the absence and requires an empty
//     comparison to be a failure rather than a vacuous pass.
//   * The remaining tests exercise the pipeline against a **clearly synthetic** rule whose
//     dispositions are a mechanical alternating pattern chosen for coverage of both the
//     shown and the omitted case. That pattern is not an approved mapping and must never be
//     copied into a shipping artifact.
//
// # What a host run is not
//
// These run on the development host. Requirement 13.11's provenance comparison is a Device
// Validation Suite gate on an approved physical iPhone under an approved Device Validation
// Plan; a host or simulator pass is a development check and satisfies no device gate. Task
// 14.2 owns the runners that consume a physical-device result.
//
// # The recorded `ProvenanceAnalyzing` conformance gap
//
// The conditional C2PA adapter deliberately does not conform to `ProvenanceAnalyzing`,
// because the port returns `ProvenanceEvidence` unconditionally and cannot express a
// Provenance Feasibility Gate finding. That is a recorded open question, not a defect. Its
// consequence here is stated rather than worked around: the enabled lane in this file comes
// from a recording double standing in for the port, so **this file cannot distinguish a
// provenance-enabled build from a build that linked the adapter**, and it asserts nothing
// about which concrete adapter supplies a conformance. The byte-level half of task 9.9 —
// real fixtures through the real adapter — is in
// `DefAIkeProvenanceC2PATests/OfflineProvenanceFixtureIntegrationTests.swift`, which calls
// the adapter directly for exactly this reason.

// MARK: - The approved artifacts

/// Whether the approved fusion artifacts are installed, and where they were looked for.
enum ApprovedFusionArtifactStatus: Equatable, CustomStringConvertible {
    case absent(searchedPaths: [String])
    case present(rule: EvidenceFusionRule, suite: ReleaseFixtureSuite)
    case unreadable(path: String, reason: String)

    var description: String {
        switch self {
        case let .absent(paths):
            "no approved fusion rule or fixture suite at: \(paths.joined(separator: ", "))"
        case let .present(rule, suite):
            "approved fusion rule \(rule.id.rawValue) against suite \(suite.id.rawValue)"
        case let .unreadable(path, reason):
            "the approved fusion artifacts at \(path) could not be read: \(reason)"
        }
    }
}

/// Locates the approved Evidence Fusion Rule and Release Fixture Suite, read-only.
///
/// One search location, plus an environment override for a runner that installs the
/// artifacts outside the working tree. There is no bundled default and no writer: a build
/// that has not been given the approved artifacts cannot obtain them here, so a missing
/// artifact stays a reported absence instead of becoming a fabricated table.
enum ApprovedFusionArtifacts {
    static let ruleFileName = "evidence-fusion-rule.json"
    static let suiteFileName = "release-fixture-suite.json"
    static let environmentKey = "DEFAIKE_APPROVED_FIXTURE_DIRECTORY"

    static let status: ApprovedFusionArtifactStatus = resolve()

    static var isPresent: Bool {
        if case .present = status { return true }
        return false
    }

    /// The directories that were searched, in search order.
    static var searchedPaths: [String] {
        var paths: [String] = []
        if let installed = ProcessInfo.processInfo.environment[environmentKey] {
            paths.append(installed)
        }
        paths.append(repositoryDirectory.path)
        return paths
    }

    /// Derived from this file's own path so it does not depend on a working directory.
    private static var repositoryDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ApprovedFixtures")
    }

    private static func resolve() -> ApprovedFusionArtifactStatus {
        for path in searchedPaths {
            let directory = URL(fileURLWithPath: path)
            let ruleURL = directory.appendingPathComponent(ruleFileName)
            let suiteURL = directory.appendingPathComponent(suiteFileName)
            let manager = FileManager.default
            guard manager.fileExists(atPath: ruleURL.path),
                  manager.fileExists(atPath: suiteURL.path)
            else {
                continue
            }
            do {
                let decoder = JSONDecoder()
                return .present(
                    rule: try decoder.decode(
                        EvidenceFusionRule.self,
                        from: try Data(contentsOf: ruleURL)
                    ),
                    suite: try decoder.decode(
                        ReleaseFixtureSuite.self,
                        from: try Data(contentsOf: suiteURL)
                    )
                )
            } catch {
                return .unreadable(path: path, reason: "\(error)")
            }
        }
        return .absent(searchedPaths: searchedPaths)
    }
}

// MARK: - The comparison

/// One combination's approved disposition beside what the pipeline actually produced.
///
/// The approved value comes from a rule entry; the fixture supplies the lane values the
/// pipeline is driven with. Neither is derived from the pipeline's own answer, and there is
/// no member that could supply a missing expectation.
struct FusionFixtureComparison: Equatable, CustomStringConvertible {
    enum Obstruction: Equatable, CustomStringConvertible {
        /// The rule holds no entry for this combination.
        case entryMissing
        /// No catalogued fixture declares this combination, so no approved fixture result
        /// exists for it (Requirement 7.15).
        case fixtureNotCatalogued
        /// The report could not be built from these lanes.
        case reportNotBuilt(String)

        var description: String {
            switch self {
            case .entryMissing: "the rule holds no entry for this combination"
            case .fixtureNotCatalogued: "no catalogued fixture declares this combination"
            case let .reportNotBuilt(reason): "the report could not be built: \(reason)"
            }
        }
    }

    let combination: FusionLaneCombination

    /// The fixture the rule entry cites, when one is catalogued.
    let fixture: FixtureID?

    /// The disposition the approved rule entry declares.
    let approved: FusionDisposition?

    /// The summary the report actually carries, or `nil` when it carries none.
    let reportedSummary: CombinedSummary?

    /// Whether both lanes reached the report exactly as the fixture declared them.
    let lanesPreserved: Bool

    let obstruction: Obstruction?

    /// Whether the reported summary is the one the approved disposition calls for.
    ///
    /// An omitting disposition agrees only with no summary at all, and a shown disposition
    /// agrees only with a summary carrying that exact approved copy key. Lane preservation
    /// is part of agreement: a correct sentence beside a rewritten lane is not a correct
    /// report (Requirement 7.13).
    var agrees: Bool {
        guard obstruction == nil, lanesPreserved, let approved else { return false }
        switch approved {
        case .omit:
            return reportedSummary == nil
        case let .show(copyKey):
            return reportedSummary?.copyKey == copyKey
        }
    }

    var description: String {
        if let obstruction {
            return "\(combination.description): \(obstruction)"
        }
        let approvedText: String
        switch approved {
        case .none: approvedText = "none"
        case .omit: approvedText = "omit"
        case let .show(key): approvedText = "show(\(key.rawValue))"
        }
        let reportedText = reportedSummary.map { "show(\($0.copyKey.rawValue))" } ?? "omit"
        return "\(combination.description): approved \(approvedText), reported \(reportedText)"
            + (lanesPreserved ? "" : ", lanes not preserved")
    }
}

/// The result of comparing every enabled lane combination.
struct FusionFixtureComparisonReport: Equatable {
    let comparisons: [FusionFixtureComparison]

    var disagreements: [FusionFixtureComparison] { comparisons.filter { !$0.agrees } }

    var coveredCombinations: Set<String> {
        Set(comparisons.map(\.combination.description))
    }

    /// Passing requires every one of the 15 combinations to have been compared and to agree.
    ///
    /// An empty or short report fails. A comparison that covered 14 combinations has
    /// established nothing about the fifteenth, and Requirement 7.14 is a claim about all 15.
    var outcome: GateOutcome {
        let complete = coveredCombinations
            == Set(FusionLaneCombination.allCombinations.map(\.description))
        return complete && disagreements.isEmpty ? .passed : .failed
    }
}

/// Drives every enabled lane combination through the lane-to-report pipeline.
///
/// The pipeline is the real one: a `ProvenanceAnalyzing` conformance behind
/// `ProvenanceLaneProvider`, then `EvidenceLaneJoin`, then `EvidenceCoordinator`, with the
/// summary resolved by `OptionalFusion` from the rule under comparison. Nothing is
/// short-circuited, and the two lanes are compared against the values the fixture declared
/// rather than against the values the report happens to hold.
struct FusionFixturePipelineRunner {
    let fusion: OptionalFusion
    let rule: EvidenceFusionRule
    let suite: ReleaseFixtureSuite
    let policy: ProvenancePolicy
    let coordinator: EvidenceCoordinator
    let manifest: ReleaseCapabilityManifest

    /// The provenance evidence value a fixture's declared state is driven with.
    ///
    /// A representative payload per state, from `ProvenanceSample`. The payload is not an
    /// approved value and is not asserted about; only the *state* comes from the fixture.
    private func evidence(for state: ProvenanceStateKey) -> ProvenanceEvidence {
        switch state {
        case .validated: ProvenanceSample.validated(policyID: policy.id)
        case .invalid: ProvenanceSample.invalid(policyID: policy.id)
        case .absent: .absent
        case .unsupported: ProvenanceSample.unsupported(policyID: policy.id)
        case .indeterminate: ProvenanceSample.indeterminate(policyID: policy.id)
        }
    }

    func run() async -> FusionFixtureComparisonReport {
        var comparisons: [FusionFixtureComparison] = []
        for combination in FusionLaneCombination.allCombinations {
            comparisons.append(await compare(combination))
        }
        return FusionFixtureComparisonReport(comparisons: comparisons)
    }

    private func compare(
        _ combination: FusionLaneCombination
    ) async -> FusionFixtureComparison {
        guard let entry = rule.entries.first(where: { $0.combination == combination }) else {
            return FusionFixtureComparison(
                combination: combination,
                fixture: nil,
                approved: nil,
                reportedSummary: nil,
                lanesPreserved: false,
                obstruction: .entryMissing
            )
        }
        // Requirement 7.15: the entry's behavior has to be demonstrated by a catalogued
        // fixture that declares *this* combination. A reference is not a result.
        guard let fixture = suite.fixtures.first(where: { $0.id == entry.fixture }),
              fixture.expectations.contains(.pixelLabel(combination.pixel)),
              fixture.expectations.contains(.provenanceState(combination.provenance))
        else {
            return FusionFixtureComparison(
                combination: combination,
                fixture: entry.fixture,
                approved: entry.disposition,
                reportedSummary: nil,
                lanesPreserved: false,
                obstruction: .fixtureNotCatalogued
            )
        }

        // The lane values come from the fixture's own declarations.
        let declaredPixel = combination.pixel.pixelEvidence
        let declaredEvidence = evidence(for: combination.provenance)

        // The full path: analyzer -> provider -> lane -> join -> coordinator -> report.
        let analyzer = RecordingProvenanceAnalyzer(returning: declaredEvidence)
        let provider = ProvenanceLaneProvider.resolve(
            analyzer: analyzer,
            policy: policy,
            manifest: manifest
        )
        let lane = await provider.lane(for: ProvenanceSample.asset())
        guard let lanes = EvidenceLaneJoin.unresolved
            .resolving(pixel: declaredPixel)?
            .resolving(provenance: lane)?
            .resolvedLanes
        else {
            return FusionFixtureComparison(
                combination: combination,
                fixture: fixture.id,
                approved: entry.disposition,
                reportedSummary: nil,
                lanesPreserved: false,
                obstruction: .reportNotBuilt("both lanes could not be joined")
            )
        }

        let summary = fusion.summary(pixel: lanes.pixel, provenance: lanes.provenance)
        do {
            let report = try coordinator.report(
                lanes: lanes,
                combinedSummary: summary,
                bytePreservationStatus: .originalBytes,
                inputQuality: SessionSample.inputQuality,
                onDeviceProcessing: true
            )
            return FusionFixtureComparison(
                combination: combination,
                fixture: fixture.id,
                approved: entry.disposition,
                reportedSummary: report.combinedSummary,
                // Requirement 7.13: both immutable source-lane fields survive beside the
                // summary, holding exactly the fixture-declared values.
                lanesPreserved: report.pixel == declaredPixel
                    && report.provenance == .available(declaredEvidence),
                obstruction: nil
            )
        } catch {
            return FusionFixtureComparison(
                combination: combination,
                fixture: fixture.id,
                approved: entry.disposition,
                reportedSummary: nil,
                lanesPreserved: false,
                obstruction: .reportNotBuilt("\(error)")
            )
        }
    }
}

// MARK: - Approved fusion comparison

@Suite("Approved fusion fixtures through the lane-to-report pipeline")
struct ApprovedFusionFixtureIntegrationTests {
    /// Requirement 7.14, wired to the approved artifacts.
    ///
    /// Skipped, with its reason visible in the run, while the approved artifacts are absent.
    /// When they are installed this validates the approved rule against the installed suite
    /// and drives all 15 combinations through the pipeline, comparing the report's summary
    /// with the disposition the rule entry declares.
    @Test(
        "Every approved fusion combination reaches its approved disposition in the report",
        .enabled(
            if: ApprovedFusionArtifacts.isPresent,
            "the approved fusion rule and fixture suite are not installed"
        )
    )
    func approvedFusionFixturesReachTheirApprovedDisposition() async throws {
        guard case let .present(rule, suite) = ApprovedFusionArtifacts.status else {
            Issue.record("the presence condition guarantees decoded artifacts")
            return
        }

        let runner = try FusionScenario.runner(rule: rule, suite: suite)
        let report = await runner.run()

        #expect(
            report.outcome == .passed,
            Comment(
                rawValue: "every approved combination must reach its approved disposition; "
                    + "disagreements: "
                    + report.disagreements.map(\.description).joined(separator: "; ")
            )
        )
    }

    /// The absence of the approved artifacts is recorded, not filled in.
    ///
    /// Always runs and asserts in both worlds: while absent it requires the searched paths to
    /// be named and an empty or short comparison to fail; once installed it requires the rule
    /// to cover all 15 combinations.
    @Test("Absent approved fusion artifacts are recorded and never report a pass")
    func absentApprovedFusionArtifactsAreRecorded() {
        switch ApprovedFusionArtifacts.status {
        case let .absent(searchedPaths):
            #expect(!searchedPaths.isEmpty, "an absence must name where it looked")
            // The absence describes itself, so an investigator reading a skipped run learns
            // which directories were searched without reading this file.
            let described = ApprovedFusionArtifacts.status.description
            #expect(searchedPaths.allSatisfy { described.contains($0) })

            // A comparison that compared nothing has established nothing.
            #expect(FusionFixtureComparisonReport(comparisons: []).outcome == .failed)

            // And so has one that compared only some of the 15.
            let partial = FusionFixtureComparisonReport(
                comparisons: [
                    FusionFixtureComparison(
                        combination: FusionLaneCombination.allCombinations[0],
                        fixture: nil,
                        approved: .omit,
                        reportedSummary: nil,
                        lanesPreserved: true,
                        obstruction: nil
                    )
                ]
            )
            #expect(partial.comparisons.allSatisfy { $0.agrees })
            #expect(
                partial.outcome == .failed,
                "a comparison covering 1 of 15 combinations is not a pass"
            )

        case let .present(rule, _):
            #expect(
                Set(rule.entries.map(\.combination.description))
                    == Set(FusionLaneCombination.allCombinations.map(\.description))
            )

        case let .unreadable(path, reason):
            Issue.record(
                "the approved fusion artifacts at \(path) are installed but unreadable: \(reason)"
            )
        }
    }

    /// The comparison bites.
    ///
    /// Without this the skipped comparison above could be wired to nothing. A clearly
    /// synthetic rule is driven through the pipeline and every one of the 15 combinations has
    /// to agree; then one entry's disposition is replaced with a *different* approved
    /// disposition while the pipeline keeps resolving against the original table, and the
    /// comparison has to report a disagreement at exactly that combination.
    ///
    /// **The dispositions here are a mechanical alternating pattern, not an approved
    /// mapping.**
    @Test("A disposition the pipeline does not produce is reported as a disagreement")
    func comparisonReportsDisagreement() async throws {
        let baseline = try FusionScenario.runner()
        let agreement = await baseline.run()

        #expect(agreement.outcome == .passed, Comment(
            rawValue: "the synthetic baseline must agree with itself; disagreements: "
                + agreement.disagreements.map(\.description).joined(separator: "; ")
        ))
        #expect(
            agreement.coveredCombinations
                == Set(FusionLaneCombination.allCombinations.map(\.description))
        )
        // Both dispositions occur, so agreement is not the trivial "nothing is ever shown".
        #expect(agreement.comparisons.contains { $0.reportedSummary != nil })
        #expect(agreement.comparisons.contains { $0.reportedSummary == nil })
        #expect(agreement.comparisons.allSatisfy { $0.lanesPreserved })

        // A rule whose expectation for one combination differs from the table the pipeline
        // resolves against. The mismatch is the point.
        let target = FusionLaneCombination.allCombinations[0]
        let flipped = try FusionScenario.candidate(
            dispositions: [target: FusionScenario.oppositeDisposition(for: target)]
        )
        let mismatched = try FusionScenario.runner(comparingAgainst: flipped)
        let disagreement = await mismatched.run()

        #expect(disagreement.outcome == .failed)
        #expect(disagreement.disagreements.count == 1)
        let reported = try #require(disagreement.disagreements.first)
        #expect(reported.combination == target)
    }

    /// A rule entry citing a fixture that does not demonstrate its combination is a failure.
    ///
    /// Requirement 7.15 at the level of this comparison: a `FixtureID` on an entry is a
    /// reference, and a reference with no matching catalogued fixture is not an approved
    /// fixture result. The comparison refuses rather than proceeding on the entry's word.
    @Test("An entry whose fixture does not demonstrate its combination fails the comparison")
    func unfixturedEntryFailsTheComparison() async throws {
        // A suite missing the fixture the first combination's entry cites.
        let target = FusionLaneCombination.allCombinations[0]
        let suite = try FusionScenario.fixtureSuite(omitting: target)
        let runner = try FusionScenario.runner(suite: suite)

        let report = await runner.run()

        #expect(report.outcome == .failed)
        let affected = report.comparisons.filter { $0.combination == target }
        #expect(affected.count == 1)
        let comparison = try #require(affected.first)
        #expect(comparison.obstruction == .fixtureNotCatalogued)
        #expect(comparison.reportedSummary == nil)
    }
}

// MARK: - Invalid tables and the unavailable lane, in a report

@Suite("Invalid fusion tables and the unavailable lane in an Evidence Report")
struct FusionOmissionReportIntegrationTests {
    /// Requirement 7.9, in a report.
    ///
    /// Property 22 shows that a refused candidate omits the summary for every representable
    /// lane pair. The integration form is stronger and is what this asserts: with the
    /// refusal in hand, a report still builds for all 15 enabled pairs, carries no summary,
    /// and keeps both source lanes — so an unusable table costs a sentence and nothing else.
    @Test("A refused fusion table costs the summary and nothing else in the report")
    func refusedTableOmitsOnlyTheSummary() async throws {
        // One combination's shown disposition names a copy key the catalogue has no
        // Combined Summary surface for: free-form copy wearing an identifier.
        let target = FusionLaneCombination.allCombinations.first {
            if case .show = FusionScenario.disposition(for: $0) { return true }
            return false
        }
        let omitted = try #require(target)
        let fusion = OptionalFusion.resolving(
            candidate: try FusionScenario.candidate(),
            verdictCopy: try FusionScenario.copyCatalog(omittingSummarySurfaceFor: omitted),
            fixtures: try FusionScenario.fixtureSuite(),
            evidence: try FusionScenario.evidenceIndex()
        )

        // The refusal is kept rather than discarded.
        let omission = try #require(fusion.omission)
        #expect(omission.rejection != nil)
        #expect(fusion.approvedRule == nil)
        #expect(fusion.boundRuleID == nil)
        #expect(fusion.ruleVersion == nil)

        // A session bound to no rule, because no rule was approved for it.
        let coordinator = try FusionScenario.coordinator(fusionRuleID: nil)
        for combination in FusionLaneCombination.allCombinations {
            let evidence = FusionScenario.evidence(for: combination.provenance)
            let lanes = ResolvedEvidenceLanes(
                pixel: combination.pixel.pixelEvidence,
                provenance: .available(evidence)
            )
            #expect(fusion.summary(pixel: lanes.pixel, provenance: lanes.provenance) == nil)

            let report = try coordinator.report(
                lanes: lanes,
                combinedSummary: nil,
                bytePreservationStatus: .originalBytes,
                inputQuality: SessionSample.inputQuality,
                onDeviceProcessing: true
            )
            #expect(report.combinedSummary == nil)
            #expect(report.pixel == combination.pixel.pixelEvidence)
            #expect(report.provenance == .available(evidence))
        }
    }

    /// Requirement 7.10, in a report holding an approved rule.
    ///
    /// The discriminating pair: the same approved rule first produces a real summary beside
    /// an available lane, and then produces none beside either unavailable reason. So the
    /// omission is a fact about the lane rather than about a rule that never says anything.
    /// And a report *with* a summary beside an unavailable lane is unrepresentable, not
    /// merely avoided.
    @Test("An unavailable lane omits the summary even where an approved rule is bound")
    func unavailableLaneOmitsTheSummaryUnderAnApprovedRule() async throws {
        let fusion = OptionalFusion.approved(try FusionScenario.approvedRule())
        let rule = try #require(fusion.approvedRule)

        // A combination this rule shows, so the rule is known to produce a sentence.
        let shown = try #require(
            FusionLaneCombination.allCombinations.first {
                if case .show = FusionScenario.disposition(for: $0) { return true }
                return false
            }
        )
        let shownEvidence = FusionScenario.evidence(for: shown.provenance)
        let available = ResolvedEvidenceLanes(
            pixel: shown.pixel.pixelEvidence,
            provenance: .available(shownEvidence)
        )
        let producedSummary = try #require(
            fusion.summary(pixel: available.pixel, provenance: available.provenance),
            "the approved rule must show a summary for a combination it shows"
        )
        #expect(producedSummary.fusionRuleID == rule.id)

        let enabledCoordinator = try FusionScenario.coordinator(fusionRuleID: rule.id)
        let enabledReport = try enabledCoordinator.report(
            lanes: available,
            combinedSummary: producedSummary,
            bytePreservationStatus: .originalBytes,
            inputQuality: SessionSample.inputQuality,
            onDeviceProcessing: true
        )
        #expect(enabledReport.combinedSummary == producedSummary)
        #expect(enabledReport.provenance == .available(shownEvidence))

        // The same rule, beside each unavailable reason: no key, no lookup, no summary.
        let pixelOnlyCoordinator = try FusionScenario.coordinator(
            fusionRuleID: rule.id,
            provenancePolicyID: nil
        )
        for reason in UnavailableReason.allCases {
            let lanes = ResolvedEvidenceLanes(
                pixel: shown.pixel.pixelEvidence,
                provenance: .unavailable(reason)
            )
            #expect(lanes.provenance.stateKey == nil, "an unavailable lane has no table key")
            #expect(fusion.attributedEntry(pixel: lanes.pixel, provenance: lanes.provenance) == nil)
            #expect(fusion.summary(pixel: lanes.pixel, provenance: lanes.provenance) == nil)

            let report = try pixelOnlyCoordinator.report(
                lanes: lanes,
                combinedSummary: nil,
                bytePreservationStatus: .originalBytes,
                inputQuality: SessionSample.inputQuality,
                onDeviceProcessing: true
            )
            #expect(report.combinedSummary == nil)
            #expect(report.provenance == .unavailable(reason))

            // Unrepresentable rather than avoided: the report refuses the combination.
            #expect(
                EvidenceReport(
                    binding: report.binding,
                    pixel: lanes.pixel,
                    provenance: lanes.provenance,
                    combinedSummary: producedSummary,
                    apparentInconsistency: nil,
                    bytePreservationStatus: .originalBytes,
                    inputQuality: SessionSample.inputQuality,
                    onDeviceProcessing: true,
                    scope: SessionSample.scope
                ) == nil
            )
        }
    }

    /// The pixel-only composition never reaches a validator, and its lane omits the summary.
    ///
    /// Property 19 owns the general claim over generated compositions. What is added is the
    /// one integration step it does not take: the pixel-only lane travels through the join
    /// into a real report, and the report carries the unavailable lane and no summary.
    @Test("The pixel-only composition produces an unavailable lane and no summary")
    func pixelOnlyCompositionProducesNoSummary() async throws {
        let provider = ProvenanceLaneProvider.pixelOnly
        #expect(!provider.isEnabled)
        #expect(!provider.canProduceCombinedSummary)
        #expect(provider.boundPolicyID == nil)
        #expect(provider.inspectionRequest(for: ProvenanceSample.asset()) == nil)

        let lane = await provider.lane(for: ProvenanceSample.asset())
        #expect(lane == .unavailable(.validatorNotCompiledIntoRelease))

        let coordinator = try FusionScenario.coordinator(
            fusionRuleID: nil,
            provenancePolicyID: nil
        )
        for label in PixelLabelKey.allCases {
            let lanes = try #require(
                EvidenceLaneJoin.unresolved
                    .resolving(pixel: label.pixelEvidence)?
                    .resolving(provenance: lane)?
                    .resolvedLanes
            )
            let report = try coordinator.report(
                lanes: lanes,
                combinedSummary: nil,
                bytePreservationStatus: .originalBytes,
                inputQuality: SessionSample.inputQuality,
                onDeviceProcessing: true
            )
            #expect(report.combinedSummary == nil)
            #expect(report.provenance == .unavailable(.validatorNotCompiledIntoRelease))
            #expect(report.pixel == label.pixelEvidence)
        }
    }
}

// MARK: - Synthetic fusion artifacts

/// A clearly synthetic fusion rule, fixture suite, copy catalogue, and session, plus the
/// pipeline assembled around them.
///
/// **Nothing here is an approved release input.** The disposition pattern is mechanical, the
/// copy keys and fixture identifiers are placeholders, and the approvals are schema shape.
/// They exist so a pipeline that consumes signed artifacts can be driven while the approved
/// artifacts are absent, and no assertion claims any of them is correct.
enum FusionScenario {
    static let ruleIdentifier = "fusion-rule-9901"
    static let suiteIdentifier = "fixture-suite-9901"
    static let approvalIdentifier = "approval-fusion-9901"
    static let fixtureEvidenceIdentifier = "evidence-fixture-9901"

    // MARK: Mechanical disposition pattern

    /// A non-approved disposition for one combination.
    ///
    /// Alternates on the combination's position so roughly half the table shows a summary and
    /// half omits one. The point is coverage of both cases, never a mapping.
    static func disposition(for combination: FusionLaneCombination) -> FusionDisposition {
        let position = FusionLaneCombination.allCombinations.prefix { $0 != combination }.count
        return position.isMultiple(of: 2) ? .show(copyKey(for: combination)) : .omit
    }

    /// The other disposition, for building a deliberate mismatch.
    static func oppositeDisposition(for combination: FusionLaneCombination) -> FusionDisposition {
        switch disposition(for: combination) {
        case .omit: .show(copyKey(for: combination))
        case .show: .omit
        }
    }

    static func copyKey(for combination: FusionLaneCombination) -> ApprovedCopyKey {
        EvidenceSample.copyKey("copy.fusion.\(combination.description)")
    }

    static func fixtureID(for combination: FusionLaneCombination) -> FixtureID {
        guard let id = FixtureID("fixture.fusion.\(combination.description)") else {
            preconditionFailure("the synthetic fusion fixture identifier must be canonical")
        }
        return id
    }

    /// The fixture family a synthetic fixture is filed under for one provenance state.
    ///
    /// Matching the family to the state keeps the samples readable. Nothing asserts a
    /// correspondence.
    static func family(for state: ProvenanceStateKey) -> FixtureFamily {
        switch state {
        case .validated: .provenanceValidSigned
        case .invalid: .provenanceInvalid
        case .absent: .provenanceAbsent
        case .unsupported: .provenanceUnsupported
        case .indeterminate: .provenanceIndeterminate
        }
    }

    /// A representative provenance value for one state.
    static func evidence(for state: ProvenanceStateKey) -> ProvenanceEvidence {
        switch state {
        case .validated: ProvenanceSample.validated()
        case .invalid: ProvenanceSample.invalid()
        case .absent: .absent
        case .unsupported: ProvenanceSample.unsupported()
        case .indeterminate: ProvenanceSample.indeterminate()
        }
    }

    // MARK: Artifacts

    static func fixture(demonstrating combination: FusionLaneCombination) throws -> FixtureRecord {
        guard let path = CanonicalRelativePath(
            "synthetic/fusion/\(combination.description).jpg"
        ) else {
            preconditionFailure("the synthetic fixture asset path must be canonical")
        }
        return try FixtureRecord(
            id: fixtureID(for: combination),
            family: family(for: combination.provenance),
            assetPath: path,
            contentDigest: Fixture.digest("fusion-fixture-\(combination.description)"),
            byteCount: try PositiveByteCount(validating: 64),
            source: Fixture.evidence(fixtureEvidenceIdentifier),
            expectations: [
                .pixelLabel(combination.pixel),
                .provenanceState(combination.provenance),
            ]
        )
    }

    /// A suite holding one fixture per combination, optionally dropping one.
    static func fixtureSuite(
        omitting dropped: FusionLaneCombination? = nil
    ) throws -> ReleaseFixtureSuite {
        try ReleaseFixtureSuite(
            id: Fixture.artifactID(suiteIdentifier),
            schemaVersion: .v1,
            provenanceApplicability: .applicable,
            fixtures: try FusionLaneCombination.allCombinations
                .filter { $0 != dropped }
                .map { try fixture(demonstrating: $0) }
        )
    }

    /// A catalogue covering every unconditional surface, all five states, and every shown key.
    static func copyCatalog(
        omittingSummarySurfaceFor omitted: FusionLaneCombination? = nil
    ) throws -> ApprovedVerdictCopyCatalog {
        var surfaces = VerdictCopySurface.unconditionalSurfaces
        for state in ProvenanceStateKey.allCases {
            surfaces.insert(.provenanceState(state))
        }
        for combination in FusionLaneCombination.allCombinations where combination != omitted {
            if case let .show(key) = disposition(for: combination) {
                surfaces.insert(.combinedSummary(key))
            }
        }
        let entries = surfaces.map { surface in
            VerdictCopyEntry(
                surface: surface,
                localizationKey: EvidenceSample.copyKey(
                    "copy.surface." + surface.description.replacingOccurrences(of: "/", with: ".")
                )
            )
        }
        return try ApprovedVerdictCopyCatalog(
            id: Fixture.artifactID("copy-catalog-9901"),
            schemaVersion: .v1,
            compatibilityID: SessionSample.copyCompatibilityID,
            languageTag: EvidenceSample.text(ApprovedVerdictCopyCatalog.requiredLanguageTag),
            entries: entries,
            approval: approval()
        )
    }

    static func approval(_ decision: ApprovalDecision = .approved) -> ApprovalRecord {
        guard let approver = ApproverID("role.release-owner") else {
            preconditionFailure("the synthetic approver identifier must be canonical")
        }
        return ApprovalRecord(
            source: Fixture.evidence(approvalIdentifier),
            decision: decision,
            approver: approver,
            decidedAt: Date(timeIntervalSince1970: 0)
        )
    }

    static func candidate(
        dispositions overrides: [FusionLaneCombination: FusionDisposition] = [:]
    ) throws -> EvidenceFusionRule {
        try EvidenceFusionRule(
            id: Fixture.artifactID(ruleIdentifier),
            schemaVersion: .v1,
            ruleVersion: EvidenceSample.version("3.4.0"),
            compatibleVerdictCopy: SessionSample.copyCompatibilityID,
            fixtureSuite: Fixture.artifactID(suiteIdentifier),
            entries: FusionLaneCombination.allCombinations.map { combination in
                FusionEntry(
                    combination: combination,
                    disposition: overrides[combination] ?? disposition(for: combination),
                    fixture: fixtureID(for: combination)
                )
            },
            approval: approval()
        )
    }

    static func evidenceIndex() throws -> ReleaseEvidenceIndex {
        try ReleaseEvidenceIndex(
            records: [
                Fixture.evidence(approvalIdentifier),
                Fixture.evidence(fixtureEvidenceIdentifier),
            ]
        )
    }

    static func approvedRule() throws -> ApprovedFusionRule {
        try ApprovedFusionRule(
            validating: try candidate(),
            verdictCopy: try copyCatalog(),
            fixtures: try fixtureSuite(),
            evidence: try evidenceIndex()
        )
    }

    // MARK: The session and its composition

    /// A capability manifest that enables provenance and binds `policy`.
    ///
    /// Required by `ProvenanceLaneProvider.resolve`, so the enabled lane in this file arrives
    /// through the same fail-closed resolution a shipping composition uses rather than being
    /// constructed directly.
    static func capabilityManifest(
        for policy: ProvenancePolicy
    ) throws -> ReleaseCapabilityManifest {
        guard let build = AppBuildID("build-9901"),
              let bundle = ModelBundleID("bundle-9901")
        else {
            preconditionFailure("the synthetic manifest identifiers must be canonical")
        }
        return try ReleaseCapabilityManifest(
            id: Fixture.artifactID("capability-manifest-9901"),
            schemaVersion: .v1,
            appBuild: build,
            compositionIdentifier: EvidenceSample.text("Synthetic provenance composition"),
            // Fusion is compiled here because the manifest requires a bound fusion rule and
            // a compiled fusion capability to agree, and a compiled fusion capability
            // requires a provenance-validating build. That coupling is the manifest's, not
            // this file's: it is why a pixel-only composition can never carry a rule.
            compiledCapabilities: [
                .pixelAnalysis, .contentCredentialValidation, .evidenceFusion,
            ],
            implementationVersions: [
                CapabilityImplementationEntry(
                    capability: .pixelAnalysis,
                    version: EvidenceSample.version("1.0.0")
                ),
                CapabilityImplementationEntry(
                    capability: .contentCredentialValidation,
                    version: policy.validatorImplementationVersion
                ),
                CapabilityImplementationEntry(
                    capability: .evidenceFusion,
                    version: EvidenceSample.version("3.4.0")
                ),
            ],
            approvedConfigurationAllowlist: Fixture.artifactID("allowlist-9901"),
            approvedBundleCatalog: [bundle],
            policyCompatibility: try PolicyCompatibilitySet(
                preprocessingContract: Fixture.artifactID("preprocessing-9901"),
                calibrationPolicy: Fixture.artifactID("calibration-9901"),
                lifecyclePolicy: Fixture.artifactID("lifecycle-9901"),
                extensionExecutionPolicy: Fixture.artifactID("extension-policy-9901"),
                mainApplicationResourceBudget: Fixture.artifactID("budget-main-application"),
                shareExtensionResourceBudget: Fixture.artifactID("budget-share-extension"),
                bundleVerificationPolicy: Fixture.artifactID("bundle-policy-9901"),
                verdictCopyCompatibility: SessionSample.copyCompatibilityID,
                provenancePolicy: .bound(policy.id),
                fusionRule: .bound(Fixture.artifactID(ruleIdentifier))
            ),
            approval: approval()
        )
    }

    /// A coordinator for one session, with no inconsistency classifier.
    ///
    /// Requirement 7.8's notice is Property 21's subject and is deliberately absent here, so
    /// the only thing that can appear beside the two lanes is the Combined Summary under test.
    static func coordinator(
        fusionRuleID: ArtifactID?,
        provenancePolicyID: ArtifactID? = ProvenanceSample.policyID
    ) throws -> EvidenceCoordinator {
        guard let coordinator = EvidenceCoordinator(
            binding: SessionSample.binding(
                provenancePolicyID: provenancePolicyID,
                fusionRuleID: fusionRuleID
            ),
            scope: SessionSample.scope,
            inconsistencyClassifier: nil
        ) else {
            preconditionFailure("the synthetic coordinator must be constructible")
        }
        return coordinator
    }

    /// The pipeline runner for one rule and suite.
    ///
    /// `comparingAgainst` supplies the rule whose entries are the *expectation*, while the
    /// pipeline resolves summaries from the validated baseline table. Passing a different
    /// value there is how a deliberate mismatch is built without making the pipeline itself
    /// inconsistent.
    static func runner(
        rule: EvidenceFusionRule? = nil,
        suite: ReleaseFixtureSuite? = nil,
        comparingAgainst expectation: EvidenceFusionRule? = nil
    ) throws -> FusionFixturePipelineRunner {
        let resolvedRule = try rule ?? candidate()
        let resolvedSuite = try suite ?? fixtureSuite()
        let fusion = OptionalFusion.resolving(
            candidate: resolvedRule,
            verdictCopy: try copyCatalog(),
            fixtures: resolvedSuite,
            evidence: try evidenceIndex()
        )
        let policy = ProvenanceSample.policy()
        return FusionFixturePipelineRunner(
            fusion: fusion,
            rule: expectation ?? resolvedRule,
            suite: resolvedSuite,
            policy: policy,
            coordinator: try coordinator(fusionRuleID: resolvedRule.id),
            manifest: try capabilityManifest(for: policy)
        )
    }
}
