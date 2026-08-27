import DefAIkeTestSupport
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain

// Design Property 31: accessibility and localization gate matrices fail closed.
//
// The design states it as: for any set of required workflows, supported major iOS
// versions, approved configurations, accessibility results, and Localization Readiness
// results, release approval is false when any required matrix cell is missing or failing
// and can be true only when every applicable cell passes.
//
// ## What "release approval" and "required cell" mean here
//
// Approval is holding a ``ValidatedAccessibilityGateMatrix``. There is no boolean to read
// and no way to construct one around matrices that did not satisfy every clause, so
// "approval is false" is quantified as construction refusing with an
// ``ArtifactSchemaError`` — the strongest available form, because there is no approved
// value to inspect afterwards.
//
// The required cell set is the one task 2.4 derives, and this property quantifies that
// derivation rather than re-litigating it: one position per approved allowlist entry, at
// the major iOS version that entry actually runs. The matrix's own cross product of the
// two lists it declares is *not* the required set, and the difference is observable — for
// a release spanning two major versions the cross product demands that an iOS 17
// configuration have been tested on iOS 18, which is a different configuration, so the
// only ways to satisfy it are to record a run nobody performed or to block every release.
// The valid arm asserts both halves of that on the heterogeneous cases the generator
// produces: the derived set validates, and the artifact reports itself incomplete.
//
// So the property has six arms, and each one is a different way a release could end up
// distributed with an untested workflow:
//
//   * **complete and passing approves**, and everything the validated value reports is
//     the derived coverage, unchanged. Without this the property would pass by refusing
//     everything;
//   * **a removed cell blocks**, at three granularities and in both matrices: one
//     position, a whole workflow across every covered position, and every position of one
//     approved configuration. Each names exactly the keys it dropped;
//   * **a non-passing cell blocks**, quantified over ``GateOutcome`` rather than over two
//     literals. Task 2.4 reports the two non-passing outcomes as *different* findings — a
//     failure is a forbidden value at the cell's outcome, an unexecuted cell is missing
//     evidence at the cell — so the fault, the field, and the reported keys are all
//     derived from the outcome the arm records;
//   * **no cell can be waived.** Requirements 12.8 and 12.10 through 12.12 make every
//     workflow under every assistive condition mandatory, and 12.15 through 12.17 do the
//     same for every localization variant, so there is no applicability member for a
//     waiver to occupy and no declaration that shrinks the required set;
//   * **a manual cell needs a resolvable imported approval**, in both directions: a
//     rejected import cannot be filed as a pass at all, and filed honestly as
//     `not-executed` it still blocks;
//   * **a cell has to sit at an approved position** — an unapproved configuration, or an
//     approved configuration at a major version it does not run, is a record of a run
//     that could not have happened.
//
// ## What this file deliberately does not assert, and why
//
//   * **Whether the allowlist is coherent.** Property 1 quantifies membership,
//     eligibility, and version binding. What is taken from it here is one consequence
//     task 2.4 depends on: every entry bound to this manifest counts toward the required
//     coverage regardless of that entry's own gate outcomes, because an entry's mandatory
//     gates include the two matrix gates themselves. Filtering to already-passing entries
//     would let a configuration whose accessibility gate failed drop out of the required
//     set and leave the remainder looking complete.
//   * **Whether the release as a whole is eligible.** Property 33 is release readiness;
//     this validator approves neither a distribution nor a device.
//   * **The version and content digest a cell cites.** The reference arms move the
//     *artifact* off the release and, for a manual approval, the version. The digest form
//     is the same code path (``ReleaseEvidenceIndex/requireResolved(_:field:)``) reached
//     one branch later, and the fixtures pin ``Sample/evidence(_:)``'s version and digest,
//     so generating those two would mean bypassing the fixtures this task is told to reuse.
//     The artifact identifiers are generated instead, so every case cites a different
//     release.
//   * **Mutation-focused unit tests.** Those are task 2.12's.
//
// ``AccessibilityMatrixValidationTests`` pins each of these refusals at one field with one
// example. This file quantifies the same statement over generated coverage sets.
//
// No value here is an approved iPhone configuration, workflow result, manual accessibility
// conclusion, or supported version. Every hardware identifier, artifact identifier, and
// approval carries the generated seed, and the whole shape exists so that the two matrix
// gates can be asked to refuse it.

extension Tag {
    /// Design Property 31.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property31MatrixGatesFailClosed: Self
}

@Suite(
    "Property 31: accessibility and localization gate matrices fail closed",
    .tags(.property31MatrixGatesFailClosed)
)
struct AccessibilityMatrixGatePropertyTests {
    /// Runs at the library default of 100 generated cases with shrinking, which is the
    /// minimum the design requires; `PropertyToolchainWiringTests` pins that default.
    /// Every generator is composed with `zip`, so the shrinkers compose.
    ///
    /// **Validates: Requirements 12.13, 12.14, 12.17, 12.18**
    @Test("Matrix gates fail closed over generated coverage sets")
    func matrixGatesFailClosed() async {
        let witness = MatrixGateVariationWitness()

        await propertyCheck(input: MatrixShape.generator) { shape in
            witness.record(shape)

            // The coherent baseline is built once per case and every arm mutates one stored
            // table and reassembles from it, so a mutation cannot leave the declared lists,
            // the cell tables, and the evidence index disagreeing about anything except the
            // one thing the arm is about — and so a case pays for one 56-to-112-cell
            // baseline rather than one per arm.
            let scenario: MatrixScenario
            do {
                scenario = try MatrixScenario(shape: shape)
            } catch {
                Issue.record(
                    "a coherent generated matrix was refused: \(error) [\(shape)]"
                )
                return
            }
            witness.recordBaseline(scenario)

            scenario.checkCompletePassingMatrixIsApproved()
            scenario.checkRemovedCellsBlockApproval()
            scenario.checkNonPassingCellsBlockApproval()
            scenario.checkNoCellCanBeWaived()
            scenario.checkManualCellsNeedAResolvableImportedApproval()
            scenario.checkEveryCellSitsAtAnApprovedPosition()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - Generated shape

/// One approved iPhone configuration, as plain data.
///
/// The hardware identifier's major component comes from the configuration's position in
/// the list rather than from a draw, so two configurations of one allowlist can never
/// collide on the uniqueness key ``ReleaseApprovedDeviceAllowlist`` enforces. A baseline
/// that collided by chance would be refused for that reason instead of validating.
///
/// ``majorOffset`` is separate from the position on purpose: it is what makes a release
/// heterogeneous or homogeneous across major iOS versions, which is the one dimension task
/// 2.4's derived-coverage decision is observable on.
private struct ConfigurationShape: Sendable {
    let hardwareDigit: Int
    let majorOffset: Int
    let osMinor: Int
    let osPatch: Int
}

/// Which member of each vocabulary a mutation arm breaks.
///
/// Generated rather than enumerated so the shrinker can reduce a failing arm to one
/// workflow, condition, or variant, and so 100 cases spread across the vocabularies
/// instead of every case paying for all 56 positions.
private struct Selectors: Sendable {
    let workflow: Int
    let condition: Int
    let variant: Int
    let configuration: Int
}

/// Everything the two matrix gates read, as plain data.
///
/// The generator produces data only. Artifacts are built from it inside the property body,
/// where a construction that unexpectedly throws is recorded as a failure rather than
/// escaping: `propertyCheck` discards an error thrown by its body, so a refusal that
/// escaped as a throw would pass vacuously.
///
/// ## How the baseline varies
///
/// A property whose baseline is one constant with a mutation applied asserts one example a
/// hundred times over, so every dimension the arms depend on is generated:
///
///   * one or two approved configurations. Kept small deliberately: a full matrix is 28
///     accessibility cells plus 28 localization cells per position, so the position count
///     multiplies this property's whole cost, and two positions is already enough to
///     express a release spanning two major iOS versions;
///   * each configuration's major iOS version, over the two majors a Version 1 release can
///     span. Two configurations therefore produce a homogeneous release half the time and
///     a heterogeneous one half the time, and the valid arm asserts a different thing in
///     each case;
///   * each configuration's hardware digit and exact operating-system minor and patch;
///   * whether the two selected positions were executed manually, which changes what
///     ``ValidatedAccessibilityGateMatrix/importedManualApprovals`` has to report and puts
///     half the removal and outcome arms on a manual cell;
///   * the workflow, assistive condition, localization variant, and configuration every
///     single-position arm targets;
///   * every artifact identifier — matrix, allowlist, capability manifest, application
///     build, both result references, and both approvals — from ``seed``. Deriving the
///     whole reference set from one number keeps it coherent without a cross-reference
///     table while still varying each reference between cases.
///
/// ``MatrixGateVariationWitness`` checks after the run that this actually happened.
private struct MatrixShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic identifier, so the whole reference set varies together and
    /// stays coherent without a cross-reference table.
    let seed: Int

    let configurations: [ConfigurationShape]

    /// Whether the baseline records the two selected positions manually.
    let manualBaseline: Bool

    let selectors: Selectors

    /// The major iOS versions a Version 1 release can span (Requirement 1.2 fixes the
    /// floor at iOS 17).
    static let majorVersions = [
        PlatformVersion.iOS17.majorVersion,
        PlatformVersion.iOS17.majorVersion + 1,
    ]

    var description: String {
        """
        seed \(seed), \(configurations.count) position(s) at \
        \(configurations.map { Self.majorVersions[$0.majorOffset] }), \
        manual \(manualBaseline)
        """
    }

    // MARK: Generators

    static var generator: Generator<MatrixShape, AnySequence<Any>> {
        zip(Gen.int(in: 0...9_999), configurations, Gen.bool, selectors)
            .map { raw in
                MatrixShape(
                    seed: raw.0,
                    configurations: raw.1,
                    manualBaseline: raw.2,
                    selectors: raw.3
                )
            }
            .eraseToAny()
    }

    private static var configurations: Generator<[ConfigurationShape], AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9),
            Gen.int(in: 0...(majorVersions.count - 1)),
            Gen.int(in: 0...9),
            Gen.int(in: 0...9)
        )
        .map {
            ConfigurationShape(
                hardwareDigit: $0.0,
                majorOffset: $0.1,
                osMinor: $0.2,
                osPatch: $0.3
            )
        }
        .array(of: 1...2)
        .eraseToAny()
    }

    private static var selectors: Generator<Selectors, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...699),
            Gen.int(in: 0...399),
            Gen.int(in: 0...399),
            Gen.int(in: 0...199)
        )
        .map {
            Selectors(workflow: $0.0, condition: $0.1, variant: $0.2, configuration: $0.3)
        }
        .eraseToAny()
    }
}

// MARK: - Scenario

/// A generated shape and the coherent artifacts built from it.
///
/// Built once per case. The two cell tables are stored rather than regenerated, and every
/// mutation arm starts from a stored table so the only difference between the baseline and
/// a mutation is the one position, outcome, declaration, or reference the arm is about.
private struct MatrixScenario {
    let shape: MatrixShape

    /// Builds artifacts from the shape. Stored rather than recreated per access: it caches
    /// the whole validated identifier set for the case.
    let builder: MatrixBuilder

    // Baseline artifacts, all coherent with each other.
    let entries: [ApprovedDeviceConfiguration]
    let coverage: [ApprovedMatrixCoverage]
    let allowlist: ReleaseApprovedDeviceAllowlist
    let manifest: ReleaseCapabilityManifest
    let index: ReleaseEvidenceIndex

    /// The declared lists the baseline carries: exactly the approved coverage, in both
    /// directions.
    let declaredConfigurations: [ApprovedConfigurationID]
    let declaredMajorVersions: [Int]

    /// The coherent cell tables, complete and passing over ``coverage``.
    let accessibilityCells: [AccessibilityResultCell]
    let localizationCells: [LocalizationResultCell]

    let matrix: AccessibilityGateMatrix
    let validated: ValidatedAccessibilityGateMatrix

    // MARK: Construction

    init(shape: MatrixShape) throws {
        let builder = MatrixBuilder(shape: shape)

        // Locals throughout, so no closure captures a partly initialized `self`.
        let entries = try builder.entries()
        let coverage = AccessibilityMatrixSample.coverage(of: entries)
        let declaredConfigurations = coverage.map(\.configuration)
        let declaredMajorVersions = Set(coverage.map(\.osMajorVersion)).sorted()
        let allowlist = try builder.allowlist(entries: entries)
        let manifest = try builder.capabilityManifest()
        let index = try builder.evidenceIndex()

        let manualKeys = shape.manualBaseline
            ? builder.selectedKeys(coverage: coverage)
            : []
        let cells = try builder.baselineCells(coverage: coverage, manual: manualKeys)
        let matrix = try builder.matrix(
            accessibilityCells: cells.accessibility,
            localizationCells: cells.localization,
            configurations: declaredConfigurations,
            supportedMajorVersions: declaredMajorVersions
        )

        self.shape = shape
        self.builder = builder
        self.entries = entries
        self.coverage = coverage
        self.declaredConfigurations = declaredConfigurations
        self.declaredMajorVersions = declaredMajorVersions
        self.allowlist = allowlist
        self.manifest = manifest
        self.index = index
        self.accessibilityCells = cells.accessibility
        self.localizationCells = cells.localization
        self.matrix = matrix
        self.validated = try ValidatedAccessibilityGateMatrix(
            validating: matrix,
            against: allowlist,
            capabilityManifest: manifest,
            evidence: index
        )
    }

    // MARK: Vocabularies

    /// Accessibility positions per approved configuration, from the vocabularies rather
    /// than a literal, so a workflow or assistive condition added to the domain raises the
    /// required count here instead of being skipped.
    static var accessibilityCellsPerPosition: Int {
        AccessibilityWorkflow.allCases.count * AssistiveCondition.allCases.count
    }

    /// Localization Readiness positions per approved configuration.
    static var localizationCellsPerPosition: Int {
        AccessibilityWorkflow.allCases.count * LocalizationTestVariant.allCases.count
    }

    // MARK: Selections

    // Every selection is the builder's, because the builder also decides which positions
    // the baseline records manually — and it has to do that before the scenario exists.
    // Restating the index arithmetic here would let the manual baseline and the arms target
    // different cells without anything failing.

    var selectedWorkflow: AccessibilityWorkflow { builder.selectedWorkflow }

    var selectedCondition: AssistiveCondition { builder.selectedCondition }

    var selectedVariant: LocalizationTestVariant { builder.selectedVariant }

    /// The approved position every single-position arm targets.
    var selectedPosition: ApprovedMatrixCoverage { builder.selectedPosition(coverage) }

    /// The accessibility cell key of the selected position, spelled by the cell's own key
    /// constructor rather than by hand: a required key and a recorded key spelled two ways
    /// would report every cell as missing.
    var selectedAccessibilityKey: String {
        AccessibilityResultCell.key(
            workflow: selectedWorkflow,
            condition: selectedCondition,
            osMajorVersion: selectedPosition.osMajorVersion,
            configuration: selectedPosition.configuration
        )
    }

    var selectedLocalizationKey: String {
        LocalizationResultCell.key(
            workflow: selectedWorkflow,
            variant: selectedVariant,
            osMajorVersion: selectedPosition.osMajorVersion,
            configuration: selectedPosition.configuration
        )
    }

    /// A major iOS version the selected configuration does not run, and still at or above
    /// the iOS 17 floor so the cell itself is representable.
    var unrunMajorVersionOfSelectedPosition: Int {
        selectedPosition.osMajorVersion == MatrixShape.majorVersions[0]
            ? MatrixShape.majorVersions[1]
            : MatrixShape.majorVersions[0]
    }

    /// Whether this release spans more than one major iOS version, which is where the
    /// derived required set and the matrix's own cross product differ.
    var isHeterogeneous: Bool { declaredMajorVersions.count > 1 }

    // MARK: - Valid arm

    /// A complete, passing matrix over the generated coverage validates, and everything
    /// the validated value reports is the derived coverage, unchanged.
    ///
    /// Without this arm the property would pass by refusing everything. It also pins the
    /// arrangement invariant every mutation arm depends on — the two cell tables cover the
    /// derived required set exactly once each — so a workflow, condition, or variant added
    /// to a vocabulary fails here rather than being silently skipped.
    func checkCompletePassingMatrixIsApproved() {
        #expect(validated.id == builder.matrixID)
        #expect(validated.allowlist == builder.allowlistID)
        #expect(validated.appBuild == builder.appBuildID)

        // Bound to a `Bool` before being asserted: a failed `#expect` renders its receiver,
        // and rendering a hundred-cell matrix buries the finding in tens of thousands of
        // characters of artifact dump.
        let matrixUnchanged = validated.matrix == matrix
        #expect(matrixUnchanged, "validation returned a matrix it was not given [\(shape)]")

        // Requirement 12.13: the coverage is the signed allowlist's, one position per
        // approved entry at the major version that entry runs.
        #expect(validated.approvedCoverage == coverage)
        #expect(validated.coveredConfigurations == declaredConfigurations)
        #expect(validated.supportedMajorVersions == declaredMajorVersions)
        #expect(
            validated.coveredConfigurations.count == shape.configurations.count,
            "one covered position per generated configuration [\(shape)]"
        )

        // The derived required set is the whole cross product of the vocabularies with the
        // approved coverage, and it is exactly what the matrices recorded.
        let requiredAccessibility = validated.applicableAccessibilityCellKeys
        let requiredLocalization = validated.applicableLocalizationCellKeys
        #expect(
            requiredAccessibility.count
                == Self.accessibilityCellsPerPosition * coverage.count
        )
        #expect(
            requiredLocalization.count == Self.localizationCellsPerPosition * coverage.count
        )
        #expect(requiredAccessibility == Set(accessibilityCells.map(\.description)))
        #expect(requiredLocalization == Set(localizationCells.map(\.description)))

        // Requirements 12.14 and 12.18: approval means every one of those cells passed.
        #expect(accessibilityCells.allSatisfy { $0.outcome == .passed })
        #expect(localizationCells.allSatisfy { $0.outcome == .passed })
        #expect(matrix.failingCellKeys.isEmpty)

        // Requirements 12.13 and 12.17: every stored reference resolved, and a manual pass
        // reported its imported approval rather than being accepted without a record.
        #expect(
            validated.resultReferences == [
                builder.accessibilityEvidence,
                builder.localizationEvidence,
            ]
        )
        let manualMode = shape.manualBaseline ? "manual" : "automated"
        #expect(
            validated.importedManualApprovals
                == (shape.manualBaseline ? [builder.manualApproval] : []),
            """
            imported manual approvals for a \(manualMode) baseline [\(shape)]
            """
        )

        // The accessor answers for a covered position and only for a covered one.
        let recorded = validated.accessibilityResult(
            selectedWorkflow,
            selectedCondition,
            for: selectedPosition.configuration
        )
        #expect(recorded?.description == selectedAccessibilityKey)
        #expect(recorded?.outcome == .passed)
        let recordedLocalization = validated.localizationResult(
            selectedWorkflow,
            selectedVariant,
            for: selectedPosition.configuration
        )
        #expect(recordedLocalization?.description == selectedLocalizationKey)
        #expect(
            validated.accessibilityResult(
                selectedWorkflow,
                selectedCondition,
                for: builder.unapprovedConfiguration
            ) == nil
        )

        // Task 2.4's derived-coverage decision, asserted where it is observable. The
        // artifact's own required set is the cross product of the two lists it declares,
        // so for a release spanning two major versions it demands positions no
        // configuration can execute — and the artifact reports itself incomplete while the
        // derived coverage validates.
        //
        // Each of these accessors rebuilds a required or recorded key set from scratch, so
        // they are read once into locals: `isComplete` alone recomputes six of them, and
        // the artifact carries up to 112 cells.
        let ownRequiredAccessibility = matrix.requiredAccessibilityCellKeys
        let ownRequiredLocalization = matrix.requiredLocalizationCellKeys
        let ownMissing = matrix.missingCellKeys.count
        let ownComplete = matrix.isComplete
        #expect(
            ownRequiredAccessibility.count
                == Self.accessibilityCellsPerPosition * coverage.count
                    * declaredMajorVersions.count
        )
        if isHeterogeneous {
            #expect(
                ownRequiredAccessibility.count > requiredAccessibility.count,
                "the cross product demands unexecutable positions [\(shape)]"
            )
            #expect(ownMissing > 0, "the artifact reports its unexecutable positions missing")
            #expect(!ownComplete, "a heterogeneous release cannot satisfy its own cross product")
        } else {
            #expect(ownRequiredAccessibility == requiredAccessibility)
            #expect(ownRequiredLocalization == requiredLocalization)
            #expect(ownMissing == 0)
            #expect(ownComplete)
        }
    }

    // MARK: - Removal arm

    /// A required cell with no recorded result blocks approval, at every granularity a
    /// runner could drop one at and in both matrices.
    ///
    /// Three granularities, because they are three different ways of shipping an untested
    /// workflow: one position was never exercised; one workflow was never exercised at all;
    /// one approved iPhone carries no assistive-technology or localization evidence
    /// whatsoever. All three are the same finding at the same field, so the *keys* the
    /// refusal names are asserted too — that is what distinguishes "this one position is
    /// missing" from "these twenty-eight are".
    ///
    /// Each arm also asserts that the table it hands in is genuinely shorter than the
    /// baseline's. A builder that refilled a dropped cell from a fallback would make every
    /// one of these pass vacuously.
    func checkRemovedCellsBlockApproval() {
        // One position.
        let accessibilityKey = selectedAccessibilityKey
        let withoutOneCell = accessibilityCells.filter { $0.description != accessibilityKey }
        #expect(
            withoutOneCell.count == accessibilityCells.count - 1,
            "dropping one accessibility cell removed \(accessibilityCells.count - withoutOneCell.count)"
        )
        expectRefused(
            "an accessibility matrix missing one required position",
            .missingRequiredEntries,
            reportedField: "matrix.accessibilityCells",
            reportedKeys: [accessibilityKey]
        ) {
            _ = try self.validate(try self.rebuilt(accessibilityCells: withoutOneCell))
        }

        let localizationKey = selectedLocalizationKey
        let withoutOneLocalizationCell = localizationCells.filter {
            $0.description != localizationKey
        }
        #expect(withoutOneLocalizationCell.count == localizationCells.count - 1)
        expectRefused(
            "a Localization Readiness matrix missing one required position",
            .missingRequiredEntries,
            reportedField: "matrix.localizationCells",
            reportedKeys: [localizationKey]
        ) {
            _ = try self.validate(
                try self.rebuilt(localizationCells: withoutOneLocalizationCell)
            )
        }

        // One whole workflow, across every covered position: the workflow was never
        // exercised under any assistive condition anywhere.
        let workflow = selectedWorkflow
        let withoutWorkflow = accessibilityCells.filter { $0.workflow != workflow }
        let droppedWorkflowKeys = Set(
            accessibilityCells.filter { $0.workflow == workflow }.map(\.description)
        )
        #expect(
            droppedWorkflowKeys.count == AssistiveCondition.allCases.count * coverage.count,
            "the \(workflow.rawValue) workflow holds \(droppedWorkflowKeys.count) positions"
        )
        expectRefused(
            "an accessibility matrix that never exercised the \(workflow.rawValue) workflow",
            .missingRequiredEntries,
            reportedField: "matrix.accessibilityCells",
            reportedKeys: droppedWorkflowKeys
        ) {
            _ = try self.validate(try self.rebuilt(accessibilityCells: withoutWorkflow))
        }

        let withoutLocalizationWorkflow = localizationCells.filter { $0.workflow != workflow }
        let droppedLocalizationWorkflowKeys = Set(
            localizationCells.filter { $0.workflow == workflow }.map(\.description)
        )
        #expect(
            droppedLocalizationWorkflowKeys.count
                == LocalizationTestVariant.allCases.count * coverage.count
        )
        expectRefused(
            "a Localization Readiness matrix that never exercised the \(workflow.rawValue) "
                + "workflow",
            .missingRequiredEntries,
            reportedField: "matrix.localizationCells",
            reportedKeys: droppedLocalizationWorkflowKeys
        ) {
            _ = try self.validate(
                try self.rebuilt(localizationCells: withoutLocalizationWorkflow)
            )
        }

        // One whole approved configuration. Its cells go; its declaration stays, so this is
        // the completeness finding rather than the declared-list one — an approved iPhone
        // this release still ships to, with no evidence at all.
        let position = selectedPosition
        let withoutPosition = accessibilityCells.filter {
            $0.configuration != position.configuration
        }
        let droppedPositionKeys = Set(
            accessibilityCells
                .filter { $0.configuration == position.configuration }
                .map(\.description)
        )
        #expect(
            droppedPositionKeys.count == Self.accessibilityCellsPerPosition,
            "\(position.configuration.rawValue) holds \(droppedPositionKeys.count) positions"
        )
        expectRefused(
            "an approved configuration with no accessibility evidence at all",
            .missingRequiredEntries,
            reportedField: "matrix.accessibilityCells",
            reportedKeys: droppedPositionKeys
        ) {
            _ = try self.validate(try self.rebuilt(accessibilityCells: withoutPosition))
        }

        let withoutLocalizationPosition = localizationCells.filter {
            $0.configuration != position.configuration
        }
        let droppedLocalizationPositionKeys = Set(
            localizationCells
                .filter { $0.configuration == position.configuration }
                .map(\.description)
        )
        #expect(droppedLocalizationPositionKeys.count == Self.localizationCellsPerPosition)
        expectRefused(
            "an approved configuration with no Localization Readiness evidence at all",
            .missingRequiredEntries,
            reportedField: "matrix.localizationCells",
            reportedKeys: droppedLocalizationPositionKeys
        ) {
            _ = try self.validate(
                try self.rebuilt(localizationCells: withoutLocalizationPosition)
            )
        }
    }

    // MARK: - Outcome arm

    /// A recorded cell that did not pass blocks approval, and the two ways of not passing
    /// are different findings at their own fields.
    ///
    /// Quantified over ``GateOutcome`` rather than over two literals, and the fault, the
    /// field, and the reported keys all come from ``finding(for:)`` — the same switch that
    /// decides whether an outcome is a finding at all. An outcome added to the vocabulary
    /// stops that switch compiling instead of being silently skipped.
    ///
    /// The distinction matters for an audit: a `failed` cell is a forbidden value at the
    /// cell's outcome, because a mandatory accessibility failure blocks the application
    /// version; a `not-executed` cell is a missing result written down rather than omitted,
    /// so it is reported as missing evidence at the cell. Collapsing them would let one
    /// arm's refusal stand in for the other's.
    func checkNonPassingCellsBlockApproval() {
        // Exactly one outcome satisfies a gate, so "can be true only when every applicable
        // cell passes" has one witness value rather than a family of them.
        #expect(GateOutcome.allCases.filter(\.isPassing) == [.passed])

        for outcome in GateOutcome.allCases {
            guard let finding = Self.finding(for: outcome) else {
                #expect(
                    outcome.isPassing,
                    "\(outcome.rawValue) is classified as no finding but does not pass"
                )
                continue
            }
            #expect(
                !outcome.isPassing,
                "\(outcome.rawValue) is classified as a finding but satisfies the gate"
            )

            let accessibilityKey = selectedAccessibilityKey
            expectRefused(
                "an accessibility position recorded as \(outcome.rawValue)",
                finding.fault,
                reportedField: "matrix.accessibilityCells[\(accessibilityKey)]"
                    + finding.fieldSuffix,
                reportedKeys: finding.keys
            ) {
                let replacement = try self.builder.rebuilt(
                    try self.selectedAccessibilityCell(),
                    outcome: outcome
                )
                _ = try self.validate(
                    try self.rebuilt(
                        accessibilityCells: self.replacing(replacement)
                    )
                )
            }

            let localizationKey = selectedLocalizationKey
            expectRefused(
                "a Localization Readiness position recorded as \(outcome.rawValue)",
                finding.fault,
                reportedField: "matrix.localizationCells[\(localizationKey)]"
                    + finding.fieldSuffix,
                reportedKeys: finding.keys
            ) {
                let replacement = try self.builder.rebuilt(
                    try self.selectedLocalizationCell(),
                    outcome: outcome
                )
                _ = try self.validate(
                    try self.rebuilt(
                        localizationCells: self.replacing(replacement)
                    )
                )
            }
        }
    }

    /// What a recorded outcome is reported as, or `nil` when it satisfies the gate.
    ///
    /// One switch decides both whether an outcome is a finding and which finding it is, so
    /// the arm cannot assert a field that belongs to a different outcome. Exhaustive over
    /// ``GateOutcome``: an added case is a compile error here rather than an untested one.
    private static func finding(for outcome: GateOutcome) -> MatrixCellFinding? {
        switch outcome {
        case .passed:
            nil
        case .failed:
            MatrixCellFinding(fault: .forbiddenValue, fieldSuffix: ".outcome", keys: nil)
        case .notExecuted:
            MatrixCellFinding(
                fault: .missingRequiredEntries,
                fieldSuffix: "",
                keys: ["an executed result"]
            )
        }
    }

    // MARK: - No-waiver arm

    /// No matrix cell can be waived, and no declaration shrinks the required set.
    ///
    /// Requirements 12.8 and 12.10 through 12.12 make every workflow under every assistive
    /// condition mandatory for every distribution, and 12.15 through 12.17 do the same for
    /// every localization variant, so there is no applicability waiver anywhere in this
    /// layer. That is asserted three ways:
    ///
    ///   * **by share.** Every member of all three vocabularies holds exactly its full
    ///     share of the required set — no member is under-represented, over-represented,
    ///     or absent. Combined with the removal arm, which shows that dropping the
    ///     selected member is refused and whose selection the witness confirms covered
    ///     every member across the run, no member is waivable;
    ///   * **by representation.** A cell carries no applicability member for a waiver to
    ///     occupy, and ``GateOutcome`` has no not-applicable value. The contrast is
    ///     deliberate: a device gate reference *does* carry a ``GateApplicability``
    ///     decision, so the absence here is a design choice rather than an omission;
    ///   * **by declaration.** Coverage of the two self-declared lists is exact in both
    ///     directions. Declaring fewer configurations or fewer major versions is how a
    ///     release would waive twenty-eight cells at a time while staying internally
    ///     complete, and declaring more claims evidence for a device it never ships to.
    func checkNoCellCanBeWaived() {
        // By share. Counted off the recorded tables, which the valid arm has already tied
        // to the derived required set.
        let positions = coverage.count
        for workflow in AccessibilityWorkflow.allCases {
            let accessibility = accessibilityCells.filter { $0.workflow == workflow }.count
            let localization = localizationCells.filter { $0.workflow == workflow }.count
            #expect(
                accessibility == AssistiveCondition.allCases.count * positions,
                "\(workflow.rawValue) holds \(accessibility) accessibility positions"
            )
            #expect(
                localization == LocalizationTestVariant.allCases.count * positions,
                "\(workflow.rawValue) holds \(localization) localization positions"
            )
        }
        for condition in AssistiveCondition.allCases {
            let owned = accessibilityCells.filter { $0.condition == condition }.count
            #expect(
                owned == AccessibilityWorkflow.allCases.count * positions,
                "\(condition.rawValue) holds \(owned) positions"
            )
        }
        for variant in LocalizationTestVariant.allCases {
            let owned = localizationCells.filter { $0.variant == variant }.count
            #expect(
                owned == AccessibilityWorkflow.allCases.count * positions,
                "\(variant.rawValue) holds \(owned) positions"
            )
        }

        // By representation.
        #expect(Set(GateOutcome.allCases.map(\.rawValue)) == ["passed", "failed", "not-executed"])
        do {
            let accessibilityMembers = try CanonicalArtifactPayload.topLevelKeys(
                try selectedAccessibilityCell()
            )
            let localizationMembers = try CanonicalArtifactPayload.topLevelKeys(
                try selectedLocalizationCell()
            )
            #expect(
                Set(accessibilityMembers) == Self.assertedAccessibilityCellMembers,
                "an accessibility cell member was added or removed: \(accessibilityMembers)"
            )
            #expect(
                Set(localizationMembers) == Self.assertedLocalizationCellMembers,
                "a localization cell member was added or removed: \(localizationMembers)"
            )
            let gateMembers = try CanonicalArtifactPayload.topLevelKeys(
                try builder.deviceGateReference()
            )
            #expect(
                gateMembers.contains("applicability"),
                """
                a device gate reference no longer carries an applicability decision, so the \
                absence of one on a matrix cell no longer distinguishes the two
                """
            )
        } catch {
            Issue.record("a generated cell could not be encoded: \(error) [\(shape)]")
        }

        // By declaration, both directions on both lists.
        expectRefused(
            "a matrix declaring a configuration the allowlist does not approve",
            .unexpectedEntries,
            reportedField: "matrix.configurations",
            reportedKeys: [builder.unapprovedConfiguration.rawValue]
        ) {
            _ = try self.validate(
                try self.rebuilt(
                    configurations: self.declaredConfigurations + [
                        self.builder.unapprovedConfiguration
                    ]
                )
            )
        }
        expectRefused(
            "a matrix declaring a major version no approved configuration runs",
            .unexpectedEntries,
            reportedField: "matrix.supportedMajorVersions",
            reportedKeys: [String(builder.unrunMajorVersion)]
        ) {
            _ = try self.validate(
                try self.rebuilt(
                    supportedMajorVersions: self.declaredMajorVersions + [
                        self.builder.unrunMajorVersion
                    ]
                )
            )
        }

        // By already having failed. An entry's mandatory gates include the two matrix gates
        // themselves, so an entry whose accessibility gate already failed must still
        // contribute its positions: dropping it from the required set is the one waiver that
        // would leave the remainder looking complete while an approved iPhone ships with no
        // evidence. Both directions — the coverage is unchanged, and its cells are still
        // required.
        do {
            let failing = try builder.allowlistFailingTheMatrixGate(
                entries: entries,
                failing: selectedPosition.configuration
            )
            let unsatisfied = failing.entries.flatMap(\.unsatisfiedGates)
            let permitted = failing.permitsDistribution
            #expect(unsatisfied.contains(.accessibilityMatrix), "the entry's matrix gate failed")
            // The entry stays *listed* while its gate is unsatisfied, which is the fact task
            // 2.4 relies on: an allowlist of one failing entry permits no distribution and
            // still names a configuration this matrix had to cover.
            #expect(
                permitted == (coverage.count > 1),
                """
                a \(coverage.count)-entry allowlist with one failing entry reports \
                permitsDistribution \(permitted)
                """
            )
            let stillValidated = try ValidatedAccessibilityGateMatrix(
                validating: matrix,
                against: failing,
                capabilityManifest: manifest,
                evidence: index
            )
            #expect(stillValidated.approvedCoverage == coverage)
            expectRefused(
                "an approved configuration whose accessibility gate already failed dropping out "
                    + "of the required set",
                .missingRequiredEntries,
                reportedField: "matrix.accessibilityCells",
                reportedKeys: Set(
                    accessibilityCells
                        .filter { $0.configuration == selectedPosition.configuration }
                        .map(\.description)
                )
            ) {
                _ = try ValidatedAccessibilityGateMatrix(
                    validating: try self.rebuilt(
                        accessibilityCells: self.accessibilityCells.filter {
                            $0.configuration != self.selectedPosition.configuration
                        }
                    ),
                    against: failing,
                    capabilityManifest: self.manifest,
                    evidence: self.index
                )
            }
        } catch {
            Issue.record(
                "an allowlist with a failing matrix gate was refused: \(error) [\(shape)]"
            )
        }

        if coverage.count > 1 {
            let dropped = selectedPosition.configuration
            expectRefused(
                "a matrix omitting an approved configuration from its declared list",
                .missingRequiredEntries,
                reportedField: "matrix.configurations",
                reportedKeys: [dropped.rawValue]
            ) {
                _ = try self.validate(
                    try self.rebuilt(
                        configurations: self.declaredConfigurations.filter { $0 != dropped }
                    )
                )
            }
        }
        if isHeterogeneous {
            let dropped = selectedPosition.osMajorVersion
            expectRefused(
                "a matrix omitting a supported major version from its declared list",
                .missingRequiredEntries,
                reportedField: "matrix.supportedMajorVersions",
                reportedKeys: [String(dropped)]
            ) {
                _ = try self.validate(
                    try self.rebuilt(
                        supportedMajorVersions: self.declaredMajorVersions.filter {
                            $0 != dropped
                        }
                    )
                )
            }
        }
    }

    /// Every top-level member an ``AccessibilityResultCell`` encodes.
    ///
    /// Compared against ``CanonicalArtifactPayload/topLevelKeys(_:)`` rather than trusted
    /// as a written list, so a member added to the cell — an applicability decision above
    /// all — fails that comparison instead of going unnoticed.
    static let assertedAccessibilityCellMembers: Set<String> = [
        "condition",
        "configuration",
        "evidence",
        "execution",
        "osMajorVersion",
        "outcome",
        "workflow",
    ]

    /// Every top-level member a ``LocalizationResultCell`` encodes.
    static let assertedLocalizationCellMembers: Set<String> = [
        "configuration",
        "evidence",
        "execution",
        "osMajorVersion",
        "outcome",
        "variant",
        "workflow",
    ]

    // MARK: - Manual execution and reference arm

    /// A manually executed pass needs an imported approval this release resolves, and a
    /// recorded result reference has to name evidence this release carries.
    ///
    /// Two references per manual cell and they are separate questions: the result
    /// reference is the recorded run, the imported approval is the human conclusion about
    /// it. Both directions are asserted, because a manual accessibility result is exactly
    /// what this layer must never manufacture:
    ///
    ///   * a rejection cannot be filed as a pass at all — the cell is unrepresentable;
    ///   * a rejection filed honestly as `not-executed` is representable, and still blocks;
    ///   * an approval nobody can resolve, at the wrong version or not at all, is a
    ///     synthesized approval;
    ///   * a manual pass whose approval does resolve validates and is reported, which is
    ///     the positive control this arm needs to not pass by refusing everything.
    func checkManualCellsNeedAResolvableImportedApproval() {
        let accessibilityPosition = "matrix.accessibilityCells[\(selectedAccessibilityKey)]"
        let localizationPosition = "matrix.localizationCells[\(selectedLocalizationKey)]"

        // A rejection cannot be recorded as a pass. Refused by the cell, so there is no
        // matrix to validate — the strongest available form.
        expectRefused(
            "an accessibility pass importing a rejected manual decision",
            .forbiddenValue,
            reportedField: "accessibilityCell.execution"
        ) {
            _ = try self.builder.rebuilt(
                try self.selectedAccessibilityCell(),
                outcome: .passed,
                execution: .manual(importedEvidence: self.builder.rejectedManualApproval)
            )
        }
        expectRefused(
            "a Localization Readiness pass importing a rejected manual decision",
            .forbiddenValue,
            reportedField: "localizationCell.execution"
        ) {
            _ = try self.builder.rebuilt(
                try self.selectedLocalizationCell(),
                outcome: .passed,
                execution: .manual(importedEvidence: self.builder.rejectedManualApproval)
            )
        }

        // The same rejection recorded honestly is representable, and blocks as missing
        // evidence. "A human said no" is not a result.
        expectRefused(
            "a rejected manual decision recorded honestly as not executed",
            .missingRequiredEntries,
            reportedField: accessibilityPosition,
            reportedKeys: ["an executed result"]
        ) {
            let replacement = try self.builder.rebuilt(
                try self.selectedAccessibilityCell(),
                outcome: .notExecuted,
                execution: .manual(importedEvidence: self.builder.rejectedManualApproval)
            )
            _ = try self.validate(
                try self.rebuilt(accessibilityCells: self.replacing(replacement))
            )
        }

        // An approval this release does not carry.
        expectRefused(
            "an accessibility manual pass importing an approval the release does not carry",
            .missingRequiredEntries,
            reportedField: "\(accessibilityPosition).execution.importedEvidence.source",
            reportedKeys: [builder.unresolvableApprovalID.rawValue]
        ) {
            let replacement = try self.builder.rebuilt(
                try self.selectedAccessibilityCell(),
                execution: .manual(importedEvidence: self.builder.unresolvableManualApproval)
            )
            _ = try self.validate(
                try self.rebuilt(accessibilityCells: self.replacing(replacement))
            )
        }
        expectRefused(
            "a Localization Readiness manual pass importing an approval the release does not "
                + "carry",
            .missingRequiredEntries,
            reportedField: "\(localizationPosition).execution.importedEvidence.source",
            reportedKeys: [builder.unresolvableApprovalID.rawValue]
        ) {
            let replacement = try self.builder.rebuilt(
                try self.selectedLocalizationCell(),
                execution: .manual(importedEvidence: self.builder.unresolvableManualApproval)
            )
            _ = try self.validate(
                try self.rebuilt(localizationCells: self.replacing(replacement))
            )
        }

        // The right approval artifact at a version this release does not carry. A different
        // audit finding from an approval nobody can find, which is why the field differs.
        expectRefused(
            "an accessibility manual pass importing an approval at another version",
            .inconsistentReference,
            reportedField: "\(accessibilityPosition).execution.importedEvidence.source.version"
        ) {
            let replacement = try self.builder.rebuilt(
                try self.selectedAccessibilityCell(),
                execution: .manual(importedEvidence: self.builder.mistimedManualApproval)
            )
            _ = try self.validate(
                try self.rebuilt(accessibilityCells: self.replacing(replacement))
            )
        }

        // The recorded run itself. A cell citing a result the release does not carry
        // records no result, whatever outcome it claims.
        expectRefused(
            "an accessibility cell citing a result the release does not carry",
            .missingRequiredEntries,
            reportedField: "\(accessibilityPosition).evidence",
            reportedKeys: [builder.unresolvableEvidenceID.rawValue]
        ) {
            let replacement = try self.builder.rebuilt(
                try self.selectedAccessibilityCell(),
                evidence: self.builder.unresolvableEvidence
            )
            _ = try self.validate(
                try self.rebuilt(accessibilityCells: self.replacing(replacement))
            )
        }
        expectRefused(
            "a Localization Readiness cell citing a result the release does not carry",
            .missingRequiredEntries,
            reportedField: "\(localizationPosition).evidence",
            reportedKeys: [builder.unresolvableEvidenceID.rawValue]
        ) {
            let replacement = try self.builder.rebuilt(
                try self.selectedLocalizationCell(),
                evidence: self.builder.unresolvableEvidence
            )
            _ = try self.validate(
                try self.rebuilt(localizationCells: self.replacing(replacement))
            )
        }

        // Positive control. A manual pass whose imported approval resolves validates, and
        // the approval is reported rather than swallowed.
        do {
            let replacement = try builder.rebuilt(
                try selectedAccessibilityCell(),
                execution: .manual(importedEvidence: builder.manualApproval)
            )
            let approved = try validate(try rebuilt(accessibilityCells: replacing(replacement)))
            #expect(approved.importedManualApprovals.contains(builder.manualApproval))
            #expect(
                approved.accessibilityResult(
                    selectedWorkflow,
                    selectedCondition,
                    for: selectedPosition.configuration
                )?
                .execution == .manual(importedEvidence: builder.manualApproval)
            )
        } catch {
            Issue.record(
                "a manual pass with a resolvable approved import was refused: \(error) [\(shape)]"
            )
        }
    }

    // MARK: - Position arm

    /// Every recorded cell describes an approved configuration at the major version that
    /// configuration runs.
    ///
    /// Neither half is checkable below this layer: the matrix validates its declared lists
    /// and its cell keys separately, so nothing there requires a *cell* to name a listed
    /// configuration and nothing pairs a cell's major version with the operating-system
    /// version its configuration was approved at. Both mismatches record a run against a
    /// configuration that did not perform it, and each one is reported at its own field so
    /// an audit can tell "this device is not ours" from "this device does not run that".
    ///
    /// The stray cells are appended, so the declared lists still cover the approved set
    /// exactly and the refusal comes from the position check rather than from the
    /// declaration check the no-waiver arm owns.
    func checkEveryCellSitsAtAnApprovedPosition() {
        do {
            let strayAccessibility = try builder.accessibilityCell(
                workflow: selectedWorkflow,
                condition: selectedCondition,
                osMajorVersion: selectedPosition.osMajorVersion,
                configuration: builder.unapprovedConfiguration
            )
            expectRefused(
                "an accessibility cell recorded for a configuration the allowlist does not "
                    + "approve",
                .inconsistentReference,
                reportedField: "matrix.accessibilityCells[\(strayAccessibility)].configuration"
            ) {
                _ = try self.validate(
                    try self.rebuilt(
                        accessibilityCells: self.accessibilityCells + [strayAccessibility]
                    )
                )
            }

            let strayLocalization = try builder.localizationCell(
                workflow: selectedWorkflow,
                variant: selectedVariant,
                osMajorVersion: selectedPosition.osMajorVersion,
                configuration: builder.unapprovedConfiguration
            )
            expectRefused(
                "a Localization Readiness cell recorded for a configuration the allowlist does "
                    + "not approve",
                .inconsistentReference,
                reportedField: "matrix.localizationCells[\(strayLocalization)].configuration"
            ) {
                _ = try self.validate(
                    try self.rebuilt(
                        localizationCells: self.localizationCells + [strayLocalization]
                    )
                )
            }

            let mispairedAccessibility = try builder.accessibilityCell(
                workflow: selectedWorkflow,
                condition: selectedCondition,
                osMajorVersion: unrunMajorVersionOfSelectedPosition,
                configuration: selectedPosition.configuration
            )
            expectRefused(
                "an accessibility cell recorded at a major version its configuration does not "
                    + "run",
                .inconsistentReference,
                reportedField: "matrix.accessibilityCells[\(mispairedAccessibility)]"
                    + ".osMajorVersion"
            ) {
                _ = try self.validate(
                    try self.rebuilt(
                        accessibilityCells: self.accessibilityCells + [mispairedAccessibility]
                    )
                )
            }

            let mispairedLocalization = try builder.localizationCell(
                workflow: selectedWorkflow,
                variant: selectedVariant,
                osMajorVersion: unrunMajorVersionOfSelectedPosition,
                configuration: selectedPosition.configuration
            )
            expectRefused(
                "a Localization Readiness cell recorded at a major version its configuration "
                    + "does not run",
                .inconsistentReference,
                reportedField: "matrix.localizationCells[\(mispairedLocalization)]"
                    + ".osMajorVersion"
            ) {
                _ = try self.validate(
                    try self.rebuilt(
                        localizationCells: self.localizationCells + [mispairedLocalization]
                    )
                )
            }
        } catch {
            Issue.record("a stray or mispaired cell could not be built: \(error) [\(shape)]")
        }
    }

    // MARK: - Rebuilders

    /// The stored accessibility cell at the selected position.
    ///
    /// Throwing rather than optional so a lookup miss is recorded by the arm's own helper
    /// instead of silently degrading into a no-op assertion.
    private func selectedAccessibilityCell() throws -> AccessibilityResultCell {
        let key = selectedAccessibilityKey
        guard let cell = accessibilityCells.first(where: { $0.description == key }) else {
            throw MatrixScenarioFault.unrecordedPosition(key)
        }
        return cell
    }

    private func selectedLocalizationCell() throws -> LocalizationResultCell {
        let key = selectedLocalizationKey
        guard let cell = localizationCells.first(where: { $0.description == key }) else {
            throw MatrixScenarioFault.unrecordedPosition(key)
        }
        return cell
    }

    /// The accessibility table with one cell replaced in place.
    ///
    /// In place, because ``ValidatedAccessibilityGateMatrix`` reports the *first* offending
    /// cell it walks: reordering the table would change which position a refusal names and
    /// an arm could then assert a field belonging to a different cell.
    private func replacing(_ replacement: AccessibilityResultCell) -> [AccessibilityResultCell] {
        accessibilityCells.map { $0.description == replacement.description ? replacement : $0 }
    }

    private func replacing(_ replacement: LocalizationResultCell) -> [LocalizationResultCell] {
        localizationCells.map { $0.description == replacement.description ? replacement : $0 }
    }

    /// The matrix, with one stored table or one declared list replaced.
    ///
    /// Every parameter is optional rather than defaulting to an empty collection: an
    /// empty-as-default sentinel would silently restore the baseline table and make every
    /// removal arm pass vacuously.
    private func rebuilt(
        accessibilityCells: [AccessibilityResultCell]? = nil,
        localizationCells: [LocalizationResultCell]? = nil,
        configurations: [ApprovedConfigurationID]? = nil,
        supportedMajorVersions: [Int]? = nil
    ) throws -> AccessibilityGateMatrix {
        try builder.matrix(
            accessibilityCells: accessibilityCells ?? self.accessibilityCells,
            localizationCells: localizationCells ?? self.localizationCells,
            configurations: configurations ?? declaredConfigurations,
            supportedMajorVersions: supportedMajorVersions ?? declaredMajorVersions
        )
    }

    private func validate(
        _ matrix: AccessibilityGateMatrix
    ) throws -> ValidatedAccessibilityGateMatrix {
        try ValidatedAccessibilityGateMatrix(
            validating: matrix,
            against: allowlist,
            capabilityManifest: manifest,
            evidence: index
        )
    }

    // MARK: - Refusal helper

    /// Requires `build` to refuse with a specific fault, recording an issue otherwise.
    ///
    /// Never rethrows. `propertyCheck` discards an error thrown by its body without
    /// recording an issue, so a refusal that escaped as a throw would make this property
    /// pass vacuously — a trap this codebase has already sprung twice.
    ///
    /// `reportedField` is asserted everywhere, because the arms here land on four faults
    /// between them and several arms share one: the case alone would let a removal be
    /// refused for a declaration's reason, or a localization cell's failure stand in for an
    /// accessibility cell's, and still pass. `reportedKeys` is asserted wherever the fault
    /// carries them, which is what separates "one position is missing" from "twenty-eight
    /// are".
    func expectRefused(
        _ what: String,
        _ expected: MatrixFault,
        reportedField: String,
        reportedKeys: Set<String>? = nil,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ build: () throws -> Void
    ) {
        do {
            try build()
            Issue.record("\(what) was accepted [\(shape)]", sourceLocation: sourceLocation)
        } catch let error as ArtifactSchemaError {
            #expect(
                MatrixFault(error) == expected,
                "\(what) was refused as \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
            #expect(
                MatrixFault.reportedField(error) == reportedField,
                "\(what) named \(MatrixFault.reportedField(error)) [\(shape)]",
                sourceLocation: sourceLocation
            )
            if let reportedKeys {
                let named = MatrixFault.reportedKeys(error) ?? []
                #expect(
                    named == reportedKeys,
                    """
                    \(what) named \(named.count) key(s) rather than \(reportedKeys.count): \
                    \(named.symmetricDifference(reportedKeys).sorted()) [\(shape)]
                    """,
                    sourceLocation: sourceLocation
                )
            }
        } catch {
            Issue.record(
                "\(what) failed with a non-schema error \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
        }
    }
}

// MARK: - Cell finding

/// How a non-passing recorded outcome is reported: which fault, at which suffix of the
/// cell's field, naming which keys.
private struct MatrixCellFinding: Sendable {
    let fault: MatrixFault
    let fieldSuffix: String
    let keys: Set<String>?
}

/// Why a scenario could not select a stored cell. Never expected; recorded if it happens.
private enum MatrixScenarioFault: Error, CustomStringConvertible {
    case unrecordedPosition(String)
    case unlistedConfiguration(String)

    var description: String {
        switch self {
        case let .unrecordedPosition(key):
            "the coherent baseline recorded no cell at \(key)"
        case let .unlistedConfiguration(identifier):
            "the generated allowlist carries no entry for \(identifier)"
        }
    }
}

// MARK: - Builder

/// Builds every artifact the property needs from one generated shape.
///
/// Separate from the scenario so the stored baseline and every arm's mutation go through
/// the same construction path: an arm hands in one replaced table or list and gets the
/// same artifacts back otherwise.
private struct MatrixBuilder {
    let shape: MatrixShape
    let seed: Int

    // MARK: Identifiers
    //
    // The fixtures take identifier text and validate it, so both forms are stored where
    // both are needed. Stored rather than computed: this set is read a few hundred times
    // per generated case and every value is validated on construction.

    let matrixIdentifier: String
    let allowlistIdentifier: String
    let manifestIdentifier: String
    let appBuildIdentifier: String
    let allowlistApprovalIdentifier: String
    let accessibilityEvidenceIdentifier: String
    let localizationEvidenceIdentifier: String
    let manualApprovalIdentifier: String

    let matrixID: ArtifactID
    let allowlistID: ArtifactID
    let appBuildID: AppBuildID

    /// An approval artifact this release does not carry, for the manual-import arm.
    let unresolvableApprovalID: ArtifactID

    /// A result artifact this release does not carry, for the reference arm.
    let unresolvableEvidenceID: ArtifactID

    /// A configuration the generated allowlist does not approve.
    let unapprovedConfiguration: ApprovedConfigurationID

    /// A major iOS version at or above the floor that no approved configuration runs.
    let unrunMajorVersion: Int

    /// A schema version this release does not carry, for the mistimed-approval arm.
    let otherVersion: SchemaSemanticVersion

    let accessibilityEvidence: EvidenceSource
    let localizationEvidence: EvidenceSource
    let unresolvableEvidence: EvidenceSource

    let manualApproval: ApprovalRecord
    let rejectedManualApproval: ApprovalRecord
    let unresolvableManualApproval: ApprovalRecord

    /// The right approval artifact at a version the release does not carry.
    let mistimedManualApproval: ApprovalRecord

    init(shape: MatrixShape) {
        let seed = shape.seed
        self.shape = shape
        self.seed = seed

        matrixIdentifier = "matrix.accessibility-\(seed)"
        allowlistIdentifier = "allowlist.devices-\(seed)"
        manifestIdentifier = "manifest.capability-\(seed)"
        appBuildIdentifier = "build.app-\(seed)"
        allowlistApprovalIdentifier = "approval.allowlist-\(seed)"
        accessibilityEvidenceIdentifier = "evidence.accessibility-\(seed)"
        localizationEvidenceIdentifier = "evidence.localization-\(seed)"
        manualApprovalIdentifier = "approval.manual-\(seed)"

        matrixID = Sample.artifact(matrixIdentifier)
        allowlistID = Sample.artifact(allowlistIdentifier)
        appBuildID = Sample.appBuild(appBuildIdentifier)
        unresolvableApprovalID = Sample.artifact("approval.elsewhere-\(seed)")
        unresolvableEvidenceID = Sample.artifact("evidence.elsewhere-\(seed)")
        unapprovedConfiguration = Sample.configuration("configuration.unlisted-\(seed)")

        // Above every major version a generated configuration can run, and above the iOS 17
        // floor, so the version is unrunnable rather than merely unrepresentable.
        unrunMajorVersion = (MatrixShape.majorVersions.max() ?? 17) + 1 + (seed % 5)
        otherVersion = Sample.version("2.\(seed % 1_000).0")

        accessibilityEvidence = Sample.evidence(accessibilityEvidenceIdentifier)
        localizationEvidence = Sample.evidence(localizationEvidenceIdentifier)
        unresolvableEvidence = Sample.evidence("evidence.elsewhere-\(seed)")

        manualApproval = Sample.approval(identifier: manualApprovalIdentifier)
        rejectedManualApproval = Sample.approval(
            .rejected,
            identifier: manualApprovalIdentifier
        )
        unresolvableManualApproval = Sample.approval(
            identifier: "approval.elsewhere-\(seed)"
        )
        mistimedManualApproval = ApprovalRecord(
            source: EvidenceSource(
                artifact: Sample.artifact(manualApprovalIdentifier),
                version: Sample.version("2.\(seed % 1_000).0"),
                contentDigest: Sample.digest()
            ),
            decision: .approved,
            approver: Sample.approver(),
            decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: Approved configurations

    func configurationIdentifier(_ offset: Int) -> String {
        "configuration.approved-\(seed)-\(offset)"
    }

    /// The hardware identifier of the configuration at `offset`.
    ///
    /// The major component is the position, so two configurations of one allowlist never
    /// collide on the hardware, version, and build uniqueness key.
    func hardware(_ offset: Int) -> String {
        "iPhone\(17 + offset).\(shape.configurations[offset].hardwareDigit)"
    }

    /// The exact operating-system version of the configuration at `offset`, whose major
    /// component is what makes this release homogeneous or heterogeneous.
    func osVersion(_ offset: Int) -> PlatformVersion {
        let configuration = shape.configurations[offset]
        let major = MatrixShape.majorVersions[configuration.majorOffset]
        return Sample.platform("\(major).\(configuration.osMinor).\(configuration.osPatch)")
    }

    /// The allowlist entries, every mandatory device gate satisfied.
    ///
    /// Task 2.4 counts every entry bound to this manifest whatever its own gate outcomes
    /// say, so the satisfied gates here are incidental: what matters is that the entry
    /// exists and names this manifest and this application build.
    func entries() throws -> [ApprovedDeviceConfiguration] {
        try shape.configurations.indices.map { offset in
            try AccessibilityMatrixSample.entry(
                identifier: configurationIdentifier(offset),
                hardware: hardware(offset),
                osVersion: osVersion(offset),
                appBuild: appBuildIdentifier,
                capabilityManifest: manifestIdentifier
            )
        }
    }

    func allowlist(
        entries: [ApprovedDeviceConfiguration]
    ) throws -> ReleaseApprovedDeviceAllowlist {
        try AccessibilityMatrixSample.allowlist(
            identifier: allowlistIdentifier,
            entries: entries,
            approvalEvidence: allowlistApprovalIdentifier
        )
    }

    /// The same allowlist with one named entry's own accessibility-matrix gate failed.
    ///
    /// The entry is found by identifier rather than by position, so nothing here depends on
    /// the derived coverage and the entry list happening to be in the same order. It is
    /// rebuilt from the fixture's entry rather than written out again: the identifier, the
    /// candidate configuration, and the version tuple are copied off the stored entry, so
    /// the only difference from the baseline allowlist is the one gate outcome.
    func allowlistFailingTheMatrixGate(
        entries: [ApprovedDeviceConfiguration],
        failing target: ApprovedConfigurationID
    ) throws -> ReleaseApprovedDeviceAllowlist {
        guard let offset = entries.firstIndex(where: { $0.id == target }) else {
            throw MatrixScenarioFault.unlistedConfiguration(target.rawValue)
        }
        let entry = entries[offset]
        var rewritten = entries
        rewritten[offset] = try ApprovedDeviceConfiguration(
            id: entry.id,
            configuration: entry.configuration,
            versionTuple: entry.versionTuple,
            gateEvidence: try Sample.gateReferences(failing: [.accessibilityMatrix])
        )
        return try allowlist(entries: rewritten)
    }

    /// The manifest this application version binds.
    ///
    /// Built here rather than taken from ``Sample/capabilityManifest(capabilities:policyCompatibility:implementationVersions:)``
    /// because the identifier, the application build, and the allowlist reference all have
    /// to carry the generated seed, and that fixture pins all three. Nothing else about it
    /// matters to this layer: the matrix validator reads the identifier, the application
    /// build, and the allowlist reference, and leaves the composition, the capability set,
    /// and the manifest's own approval to startup preflight and release readiness.
    func capabilityManifest() throws -> ReleaseCapabilityManifest {
        try ReleaseCapabilityManifest(
            id: Sample.artifact(manifestIdentifier),
            schemaVersion: .v1,
            appBuild: appBuildID,
            compositionIdentifier: Sample.text("pixel-only"),
            compiledCapabilities: [.pixelAnalysis],
            implementationVersions: [
                CapabilityImplementationEntry(capability: .pixelAnalysis, version: Sample.version())
            ],
            approvedConfigurationAllowlist: allowlistID,
            approvedBundleCatalog: [Sample.bundle("bundle.model-\(seed)")],
            policyCompatibility: try Sample.policyCompatibility(),
            approval: Sample.approval()
        )
    }

    /// The evidence this release carries: the allowlist approval, the two result
    /// references, and the manual approval. Nothing else resolves.
    func evidenceIndex() throws -> ReleaseEvidenceIndex {
        try AccessibilityMatrixSample.evidenceIndex(
            records: [
                Sample.evidence(allowlistApprovalIdentifier),
                accessibilityEvidence,
                localizationEvidence,
                Sample.evidence(manualApprovalIdentifier),
            ]
        )
    }

    // MARK: Cells

    // MARK: Selections
    //
    // The single source for which vocabulary member and which approved position this case's
    // arms target. The builder owns it rather than the scenario because the baseline's
    // manual positions have to be decided before the cell tables exist, and two copies of
    // this arithmetic could target different cells without anything failing.

    var selectedWorkflow: AccessibilityWorkflow {
        AccessibilityWorkflow.allCases[
            shape.selectors.workflow % AccessibilityWorkflow.allCases.count
        ]
    }

    var selectedCondition: AssistiveCondition {
        AssistiveCondition.allCases[shape.selectors.condition % AssistiveCondition.allCases.count]
    }

    var selectedVariant: LocalizationTestVariant {
        LocalizationTestVariant.allCases[
            shape.selectors.variant % LocalizationTestVariant.allCases.count
        ]
    }

    func selectedPosition(_ coverage: [ApprovedMatrixCoverage]) -> ApprovedMatrixCoverage {
        coverage[shape.selectors.configuration % coverage.count]
    }

    /// The two cell keys this case's single-position arms target.
    ///
    /// Used to decide which positions the baseline records manually, so the manual baseline
    /// and the arms agree about which position is manual.
    func selectedKeys(coverage: [ApprovedMatrixCoverage]) -> Set<String> {
        let position = selectedPosition(coverage)
        return [
            AccessibilityResultCell.key(
                workflow: selectedWorkflow,
                condition: selectedCondition,
                osMajorVersion: position.osMajorVersion,
                configuration: position.configuration
            ),
            LocalizationResultCell.key(
                workflow: selectedWorkflow,
                variant: selectedVariant,
                osMajorVersion: position.osMajorVersion,
                configuration: position.configuration
            ),
        ]
    }

    /// The coherent cell tables: every position of every approved configuration, recorded
    /// and passing.
    ///
    /// Built through ``AccessibilityMatrixSample/matrix(coverage:declaredConfigurations:declaredMajorVersions:omitting:outcomes:manual:manualApproval:accessibilityEvidence:localizationEvidence:addingAccessibilityCells:addingLocalizationCells:)``
    /// so this property quantifies what the example tests pin, then reassembled by
    /// ``matrix(accessibilityCells:localizationCells:configurations:supportedMajorVersions:)``
    /// so that the baseline and every mutation take the same construction path and the
    /// matrix identifier can carry the generated seed.
    func baselineCells(
        coverage: [ApprovedMatrixCoverage],
        manual: Set<String>
    ) throws -> (accessibility: [AccessibilityResultCell], localization: [LocalizationResultCell]) {
        let base = try AccessibilityMatrixSample.matrix(
            coverage: coverage,
            manual: manual,
            manualApproval: manualApprovalIdentifier,
            accessibilityEvidence: accessibilityEvidenceIdentifier,
            localizationEvidence: localizationEvidenceIdentifier
        )
        return (base.accessibilityCells, base.localizationCells)
    }

    /// One matrix. Every input is required, so no caller can restore a table by omission.
    func matrix(
        accessibilityCells: [AccessibilityResultCell],
        localizationCells: [LocalizationResultCell],
        configurations: [ApprovedConfigurationID],
        supportedMajorVersions: [Int]
    ) throws -> AccessibilityGateMatrix {
        try AccessibilityGateMatrix(
            id: matrixID,
            schemaVersion: .v1,
            configurations: configurations,
            supportedMajorVersions: supportedMajorVersions,
            accessibilityCells: accessibilityCells,
            localizationCells: localizationCells
        )
    }

    /// One accessibility cell of `cell`'s position, with one field replaced.
    ///
    /// Every other field is copied off the stored cell, so a mutation cannot change the
    /// position, the execution mode, and the reference at once — which would leave a
    /// refusal free to be about any of them.
    func rebuilt(
        _ cell: AccessibilityResultCell,
        outcome: GateOutcome? = nil,
        execution: MatrixExecutionMode? = nil,
        evidence: EvidenceSource? = nil
    ) throws -> AccessibilityResultCell {
        try AccessibilityResultCell(
            workflow: cell.workflow,
            condition: cell.condition,
            osMajorVersion: cell.osMajorVersion,
            configuration: cell.configuration,
            outcome: outcome ?? cell.outcome,
            execution: execution ?? cell.execution,
            evidence: evidence ?? cell.evidence
        )
    }

    func rebuilt(
        _ cell: LocalizationResultCell,
        outcome: GateOutcome? = nil,
        execution: MatrixExecutionMode? = nil,
        evidence: EvidenceSource? = nil
    ) throws -> LocalizationResultCell {
        try LocalizationResultCell(
            workflow: cell.workflow,
            variant: cell.variant,
            osMajorVersion: cell.osMajorVersion,
            configuration: cell.configuration,
            outcome: outcome ?? cell.outcome,
            execution: execution ?? cell.execution,
            evidence: evidence ?? cell.evidence
        )
    }

    /// A passing automated accessibility cell at an arbitrary position, for the arms that
    /// record a position the coverage does not contain.
    func accessibilityCell(
        workflow: AccessibilityWorkflow,
        condition: AssistiveCondition,
        osMajorVersion: Int,
        configuration: ApprovedConfigurationID
    ) throws -> AccessibilityResultCell {
        try AccessibilityResultCell(
            workflow: workflow,
            condition: condition,
            osMajorVersion: osMajorVersion,
            configuration: configuration,
            outcome: .passed,
            execution: .automated,
            evidence: accessibilityEvidence
        )
    }

    func localizationCell(
        workflow: AccessibilityWorkflow,
        variant: LocalizationTestVariant,
        osMajorVersion: Int,
        configuration: ApprovedConfigurationID
    ) throws -> LocalizationResultCell {
        try LocalizationResultCell(
            workflow: workflow,
            variant: variant,
            osMajorVersion: osMajorVersion,
            configuration: configuration,
            outcome: .passed,
            execution: .automated,
            evidence: localizationEvidence
        )
    }

    /// One device gate reference, for the contrast the no-waiver arm draws: a device gate
    /// carries an explicit applicability decision and a matrix cell carries none.
    func deviceGateReference() throws -> GateResultReference {
        try GateResultReference(
            gate: .accessibilityMatrix,
            applicability: .applicable,
            outcome: .passed,
            result: accessibilityEvidence,
            environment: .physicalIPhone
        )
    }
}

// MARK: - Fault classification

/// Which ``ArtifactSchemaError`` a refusal reported, without its value strings.
///
/// Asserting the case rather than the whole value keeps the property about *why* a matrix
/// was refused while leaving the audit message free to change. The field and the reported
/// keys are asserted separately, because several arms here land on the same case.
private enum MatrixFault: Equatable {
    case emptyValue
    case placeholderValue
    case noncanonicalValue
    case valueOutOfRange
    case nonPositiveValue
    case nonFiniteValue
    case duplicateEntry
    case missingRequiredEntries
    case unexpectedEntries
    case fixedValueMismatch
    case forbiddenValue
    case inconsistentReference

    init(_ error: ArtifactSchemaError) {
        switch error {
        case .emptyValue: self = .emptyValue
        case .placeholderValue: self = .placeholderValue
        case .noncanonicalValue: self = .noncanonicalValue
        case .valueOutOfRange: self = .valueOutOfRange
        case .nonPositiveValue: self = .nonPositiveValue
        case .nonFiniteValue: self = .nonFiniteValue
        case .duplicateEntry: self = .duplicateEntry
        case .missingRequiredEntries: self = .missingRequiredEntries
        case .unexpectedEntries: self = .unexpectedEntries
        case .fixedValueMismatch: self = .fixedValueMismatch
        case .forbiddenValue: self = .forbiddenValue
        case .inconsistentReference: self = .inconsistentReference
        }
    }

    /// The artifact field a refusal named. Every case names one.
    static func reportedField(_ error: ArtifactSchemaError) -> String {
        switch error {
        case let .emptyValue(field): field
        case let .placeholderValue(field, _): field
        case let .noncanonicalValue(field, _): field
        case let .valueOutOfRange(field, _, _): field
        case let .nonPositiveValue(field, _): field
        case let .nonFiniteValue(field, _): field
        case let .duplicateEntry(field, _): field
        case let .missingRequiredEntries(field, _): field
        case let .unexpectedEntries(field, _): field
        case let .fixedValueMismatch(field, _, _): field
        case let .forbiddenValue(field, _, _): field
        case let .inconsistentReference(field, _, _): field
        }
    }

    /// The entry keys a refusal named, or `nil` for a fault that names no key set.
    ///
    /// This is what makes a removal arm exact: three of this property's arms report a
    /// missing entry set at one field, and only the keys distinguish one dropped position
    /// from a dropped workflow or a dropped configuration.
    static func reportedKeys(_ error: ArtifactSchemaError) -> Set<String>? {
        switch error {
        case let .duplicateEntry(_, key): [key]
        case let .missingRequiredEntries(_, keys): Set(keys)
        case let .unexpectedEntries(_, keys): Set(keys)
        default: nil
        }
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator actually produced, so the property cannot pass by generating
/// one fixed shape a hundred times.
///
/// A property whose baseline never varies asserts one example a hundred times over. This
/// collects the dimensions the arms depend on and requires each to have been exercised with
/// more than one value. It also counts the coherent baselines that were actually built: a
/// run where every baseline construction threw would otherwise report nothing, because
/// `propertyCheck` discards an error thrown by its body.
private final class MatrixGateVariationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var seeds = Set<Int>()
    private var positionCounts = Set<Int>()
    private var majorVersionSignatures = Set<String>()
    private var twoPositionHeterogeneity = Set<Bool>()
    private var manualBaselines = Set<Bool>()
    private var workflows = Set<AccessibilityWorkflow>()
    private var conditions = Set<AssistiveCondition>()
    private var variants = Set<LocalizationTestVariant>()
    private var selectedPositions = Set<String>()
    private var accessibilityCellCounts = Set<Int>()
    private var localizationCellCounts = Set<Int>()
    private var cases = 0
    private var baselines = 0

    func record(_ shape: MatrixShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        positionCounts.insert(shape.configurations.count)
        manualBaselines.insert(shape.manualBaseline)
        let majors = shape.configurations.map { MatrixShape.majorVersions[$0.majorOffset] }
        majorVersionSignatures.insert(majors.map(String.init).joined(separator: ","))
        if majors.count > 1 {
            twoPositionHeterogeneity.insert(Set(majors).count > 1)
        }
    }

    func recordBaseline(_ scenario: MatrixScenario) {
        lock.lock()
        defer { lock.unlock() }
        baselines += 1
        workflows.insert(scenario.selectedWorkflow)
        conditions.insert(scenario.selectedCondition)
        variants.insert(scenario.selectedVariant)
        selectedPositions.insert(scenario.selectedPosition.configuration.rawValue)
        accessibilityCellCounts.insert(scenario.accessibilityCells.count)
        localizationCellCounts.insert(scenario.localizationCells.count)
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases")
        #expect(baselines == cases, "every generated case built a coherent baseline")
        #expect(seeds.count >= 60, "distinct generated seeds: \(seeds.count)")
        #expect(positionCounts == [1, 2], "generated position counts: \(positionCounts.sorted())")
        #expect(manualBaselines == [false, true], "both baseline execution modes are generated")

        // A homogeneous and a heterogeneous two-position release assert different things in
        // the valid arm, so both have to occur.
        let spans = twoPositionHeterogeneity.map { $0 ? "two majors" : "one major" }.sorted()
        #expect(
            twoPositionHeterogeneity == [false, true],
            """
            two-position releases spanning \(spans.joined(separator: " and "))
            """
        )
        #expect(
            majorVersionSignatures.count >= 4,
            "generated major-version arrangements: \(majorVersionSignatures.sorted())"
        )

        // The single-position arms target one vocabulary member per case, so the removal,
        // outcome, manual, and position arms only cover the vocabularies if the selection
        // did.
        #expect(
            workflows == Set(AccessibilityWorkflow.allCases),
            "workflows targeted: \(workflows.map(\.rawValue).sorted())"
        )
        #expect(
            conditions == Set(AssistiveCondition.allCases),
            "assistive conditions targeted: \(conditions.map(\.rawValue).sorted())"
        )
        #expect(
            variants == Set(LocalizationTestVariant.allCases),
            "localization variants targeted: \(variants.map(\.rawValue).sorted())"
        )
        #expect(selectedPositions.count >= 60, "positions targeted: \(selectedPositions.count)")

        // A baseline is 28 cells per matrix per position, so a run that only ever built one
        // coverage set would show one size.
        #expect(
            accessibilityCellCounts == [
                MatrixScenario.accessibilityCellsPerPosition,
                MatrixScenario.accessibilityCellsPerPosition * 2,
            ],
            "generated accessibility table sizes: \(accessibilityCellCounts.sorted())"
        )
        #expect(
            localizationCellCounts == [
                MatrixScenario.localizationCellsPerPosition,
                MatrixScenario.localizationCellsPerPosition * 2,
            ],
            "generated localization table sizes: \(localizationCellCounts.sorted())"
        )
    }
}
