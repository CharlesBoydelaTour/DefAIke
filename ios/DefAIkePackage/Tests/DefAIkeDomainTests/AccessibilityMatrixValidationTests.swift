import Foundation
import Testing

@testable import DefAIkeDomain

// Example tests for the accessibility and Localization Readiness gate-matrix layer.
//
// Every test builds the coherent baseline, breaks exactly one thing, and requires the
// validator to refuse. What each one is really asserting is that a specific way of
// shipping an application version with an untested workflow, an untested approved iPhone,
// an unexecutable recorded position, or an unsupported manual approval is not available.
//
// The exhaustive generated coverage belongs to Property 31 (accessibility and localization
// gate matrices fail closed) in its own task. These examples pin the individual refusals
// so a regression names one field.

@Suite("Validated accessibility gate matrix")
struct ValidatedAccessibilityGateMatrixTests {
    /// Workflows times assistive conditions, and workflows times localization variants.
    static let cellsPerConfiguration = 28

    @Test("A complete passing matrix validates and reports its derived coverage")
    func coherentMatrixValidates() throws {
        let validated = try AccessibilityMatrixSample.validated()

        #expect(validated.id == Sample.artifact(AccessibilityMatrixSample.matrixIdentifier))
        #expect(
            validated.allowlist
                == Sample.artifact(AccessibilityMatrixSample.allowlistIdentifier)
        )
        #expect(validated.appBuild == Sample.appBuild())
        #expect(
            validated.coveredConfigurations == [
                Sample.configuration(AccessibilityMatrixSample.baselineConfigurationIdentifier)
            ]
        )
        #expect(validated.supportedMajorVersions == [PlatformVersion.iOS17.majorVersion])
        #expect(validated.applicableAccessibilityCellKeys.count == Self.cellsPerConfiguration)
        #expect(validated.applicableLocalizationCellKeys.count == Self.cellsPerConfiguration)

        // Every applicable position is recorded, and nothing else is.
        #expect(
            validated.applicableAccessibilityCellKeys
                == Set(validated.matrix.accessibilityCells.map(\.description))
        )
        #expect(
            validated.applicableLocalizationCellKeys
                == Set(validated.matrix.localizationCells.map(\.description))
        )
    }

    @Test("Every applicable position resolves to its stored immutable result reference")
    func storedResultReferencesResolve() throws {
        let validated = try AccessibilityMatrixSample.validated()
        let configuration = Sample.configuration(
            AccessibilityMatrixSample.baselineConfigurationIdentifier
        )

        for workflow in AccessibilityWorkflow.allCases {
            for condition in AssistiveCondition.allCases {
                let cell = try #require(
                    validated.accessibilityResult(workflow, condition, for: configuration)
                )
                #expect(cell.outcome == .passed)
                #expect(
                    cell.evidence
                        == Sample.evidence(
                            AccessibilityMatrixSample.accessibilityEvidenceIdentifier
                        )
                )
            }
            for variant in LocalizationTestVariant.allCases {
                let cell = try #require(
                    validated.localizationResult(workflow, variant, for: configuration)
                )
                #expect(cell.outcome == .passed)
            }
        }

        #expect(
            validated.accessibilityResult(
                .retry,
                .reduceMotion,
                for: Sample.configuration("configuration.unlisted")
            ) == nil
        )
        #expect(validated.resultReferences.count == 2)
        #expect(validated.importedManualApprovals.isEmpty)
    }

    // MARK: Derived coverage

    @Test("A release spanning two major versions covers each configuration at its own")
    func heterogeneousReleaseValidates() throws {
        let entries = try [
            AccessibilityMatrixSample.entry(),
            AccessibilityMatrixSample.entry(
                identifier: "configuration.second",
                hardware: "iPhone18.1",
                osVersion: Sample.platform("18.1.0")
            ),
        ]
        let coverage = AccessibilityMatrixSample.coverage(of: entries)
        let matrix = try AccessibilityMatrixSample.matrix(coverage: coverage)
        let validated = try AccessibilityMatrixSample.validated(
            matrix: matrix,
            allowlist: try AccessibilityMatrixSample.allowlist(entries: entries)
        )

        #expect(validated.supportedMajorVersions == [17, 18])
        #expect(
            validated.applicableAccessibilityCellKeys.count == 2 * Self.cellsPerConfiguration
        )

        // The artifact's own required set is the cross product of the two lists it
        // declares, so it demands the iOS 17 configuration to have been tested on iOS 18
        // and vice versa. Those positions cannot be executed, which is why the applicable
        // set is derived from the allowlist instead.
        #expect(matrix.requiredAccessibilityCellKeys.count == 4 * Self.cellsPerConfiguration)
        #expect(!matrix.isComplete)
    }

    // MARK: Missing and failing cells

    @Test("An omitted accessibility or localization cell is refused")
    func omittedCellRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                matrix: try AccessibilityMatrixSample.matrix(
                    omitting: [AccessibilityMatrixSample.accessibilityKey()]
                )
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                matrix: try AccessibilityMatrixSample.matrix(
                    omitting: [AccessibilityMatrixSample.localizationKey()]
                )
            )
        }
    }

    @Test("Omitting one workflow leaves every one of its positions missing")
    func omittedWorkflowRefused() throws {
        for workflow in AccessibilityWorkflow.allCases {
            let omitted = Set(
                AssistiveCondition.allCases.map {
                    AccessibilityMatrixSample.accessibilityKey(workflow: workflow, condition: $0)
                }
            )
            #expect(throws: ArtifactSchemaError.self) {
                try AccessibilityMatrixSample.validated(
                    matrix: try AccessibilityMatrixSample.matrix(omitting: omitted)
                )
            }
        }
    }

    @Test("A failed accessibility or localization cell is refused")
    func failedCellRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                matrix: try AccessibilityMatrixSample.matrix(
                    outcomes: [AccessibilityMatrixSample.accessibilityKey(): .failed]
                )
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                matrix: try AccessibilityMatrixSample.matrix(
                    outcomes: [AccessibilityMatrixSample.localizationKey(): .failed]
                )
            )
        }
    }

    @Test("A cell recorded as not executed is refused")
    func notExecutedCellRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                matrix: try AccessibilityMatrixSample.matrix(
                    outcomes: [AccessibilityMatrixSample.accessibilityKey(): .notExecuted]
                )
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                matrix: try AccessibilityMatrixSample.matrix(
                    outcomes: [AccessibilityMatrixSample.localizationKey(): .notExecuted]
                )
            )
        }
    }

    // MARK: The approved configuration set

    @Test("An unapproved allowlist names no configuration to have tested on")
    func unapprovedAllowlistRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                allowlist: try AccessibilityMatrixSample.allowlist(approval: .rejected)
            )
        }
    }

    @Test("An allowlist approval citing evidence the release does not carry is refused")
    func unresolvableAllowlistApprovalRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                allowlist: try AccessibilityMatrixSample.allowlist(
                    approvalEvidence: "approval.elsewhere"
                )
            )
        }
    }

    @Test("An allowlist the signed manifest does not name is refused")
    func allowlistOutsideTheManifestRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                allowlist: try AccessibilityMatrixSample.allowlist(
                    identifier: "allowlist.other"
                )
            )
        }
    }

    @Test("An allowlist with no entry for this manifest is refused")
    func noEntryForThisManifestRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                allowlist: try AccessibilityMatrixSample.allowlist(
                    entries: [
                        try AccessibilityMatrixSample.entry(capabilityManifest: "manifest.other")
                    ]
                )
            )
        }
    }

    @Test("Coverage pooled across two application builds is refused")
    func mixedApplicationBuildsRefused() throws {
        let entries = try [
            AccessibilityMatrixSample.entry(),
            AccessibilityMatrixSample.entry(
                identifier: "configuration.second",
                hardware: "iPhone18.1",
                osVersion: Sample.platform("18.1.0"),
                appBuild: "build.other"
            ),
        ]
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                matrix: try AccessibilityMatrixSample.matrix(
                    coverage: AccessibilityMatrixSample.coverage(of: entries)
                ),
                allowlist: try AccessibilityMatrixSample.allowlist(entries: entries)
            )
        }
    }

    // MARK: Declared lists

    @Test("A matrix omitting an approved configuration is refused")
    func omittedConfigurationRefused() throws {
        let entries = try [
            AccessibilityMatrixSample.entry(),
            AccessibilityMatrixSample.entry(
                identifier: "configuration.second",
                hardware: "iPhone18.1",
                osVersion: Sample.platform("18.1.0")
            ),
        ]
        let allowlist = try AccessibilityMatrixSample.allowlist(entries: entries)

        // Declaring and recording only the first configuration is internally complete and
        // still leaves an approved iPhone with no assistive-technology evidence.
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                matrix: try AccessibilityMatrixSample.matrix(
                    coverage: AccessibilityMatrixSample.coverage(of: [entries[0]])
                ),
                allowlist: allowlist
            )
        }
    }

    @Test("A matrix declaring a configuration the allowlist does not approve is refused")
    func unapprovedDeclaredConfigurationRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                matrix: try AccessibilityMatrixSample.matrix(
                    declaredConfigurations: [
                        Sample.configuration(
                            AccessibilityMatrixSample.baselineConfigurationIdentifier
                        ),
                        Sample.configuration("configuration.unlisted"),
                    ]
                )
            )
        }
    }

    @Test("A matrix declaring a major version no approved configuration runs is refused")
    func unsupportedDeclaredMajorVersionRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                matrix: try AccessibilityMatrixSample.matrix(
                    declaredMajorVersions: [PlatformVersion.iOS17.majorVersion, 18]
                )
            )
        }
    }

    // MARK: Recorded positions

    @Test("A cell recorded for a configuration the allowlist does not approve is refused")
    func cellForUnapprovedConfigurationRefused() throws {
        let stray = try AccessibilityResultCell(
            workflow: .analysis,
            condition: .voiceOver,
            osMajorVersion: PlatformVersion.iOS17.majorVersion,
            configuration: Sample.configuration("configuration.unlisted"),
            outcome: .passed,
            execution: .automated,
            evidence: Sample.evidence(AccessibilityMatrixSample.accessibilityEvidenceIdentifier)
        )
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                matrix: try AccessibilityMatrixSample.matrix(addingAccessibilityCells: [stray])
            )
        }
    }

    @Test("A cell recorded at a major version its configuration does not run is refused")
    func cellAtUnrunMajorVersionRefused() throws {
        let configuration = Sample.configuration(
            AccessibilityMatrixSample.baselineConfigurationIdentifier
        )
        let mispaired = try AccessibilityResultCell(
            workflow: .analysis,
            condition: .voiceOver,
            osMajorVersion: 18,
            configuration: configuration,
            outcome: .passed,
            execution: .automated,
            evidence: Sample.evidence(AccessibilityMatrixSample.accessibilityEvidenceIdentifier)
        )
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                matrix: try AccessibilityMatrixSample.matrix(addingAccessibilityCells: [mispaired])
            )
        }

        let mispairedLocalization = try LocalizationResultCell(
            workflow: .resultReview,
            variant: .expansion,
            osMajorVersion: 18,
            configuration: configuration,
            outcome: .passed,
            execution: .automated,
            evidence: Sample.evidence(AccessibilityMatrixSample.localizationEvidenceIdentifier)
        )
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                matrix: try AccessibilityMatrixSample.matrix(
                    addingLocalizationCells: [mispairedLocalization]
                )
            )
        }
    }

    // MARK: Result references and manual approvals

    @Test("A cell citing a result the release does not carry is refused")
    func unresolvableResultReferenceRefused() throws {
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                matrix: try AccessibilityMatrixSample.matrix(
                    accessibilityEvidence: "evidence.elsewhere"
                )
            )
        }
        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                matrix: try AccessibilityMatrixSample.matrix(
                    localizationEvidence: "evidence.elsewhere"
                )
            )
        }
    }

    @Test("A manual pass carries an imported approval this release resolves")
    func manualPassNeedsResolvableApproval() throws {
        let manual: Set<String> = [
            AccessibilityMatrixSample.accessibilityKey(),
            AccessibilityMatrixSample.localizationKey(),
        ]
        let validated = try AccessibilityMatrixSample.validated(
            matrix: try AccessibilityMatrixSample.matrix(manual: manual)
        )
        #expect(
            validated.importedManualApprovals == [
                Sample.approval(identifier: AccessibilityMatrixSample.manualApprovalIdentifier)
            ]
        )

        #expect(throws: ArtifactSchemaError.self) {
            try AccessibilityMatrixSample.validated(
                matrix: try AccessibilityMatrixSample.matrix(
                    manual: manual,
                    manualApproval: "approval.elsewhere"
                )
            )
        }
    }
}
