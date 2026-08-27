import Foundation

@testable import DefAIkeDomain

// A coherent synthetic accessibility and Localization Readiness matrix, and one knob per
// thing that can go wrong.
//
// The shape every test here takes is: build an allowlist, a capability manifest, an
// evidence index, and a pair of matrices that all agree; change exactly one of them; and
// require validation to refuse. That only works if the baseline is genuinely coherent, so
// the cells are derived from the same approved coverage the validator derives its required
// set from, and a knob is exposed only for the single thing a test means to break.
//
// None of these values is an approved device, workflow result, or accessibility
// conclusion. The hardware identifiers are synthetic, and every approval is a synthetic
// record whose decision the test sets.

enum AccessibilityMatrixSample {
    static let matrixIdentifier = "matrix.accessibility"
    static let allowlistIdentifier = "allowlist.devices"
    static let manifestIdentifier = "manifest.capability"
    static let appBuildIdentifier = "build.sample"

    /// The one approved configuration the coherent baseline covers.
    static let baselineConfigurationIdentifier = "configuration.sample"

    /// The evidence artifacts the baseline cells cite.
    static let accessibilityEvidenceIdentifier = "evidence.accessibility"
    static let localizationEvidenceIdentifier = "evidence.localization"

    /// The approval a manually executed cell imports.
    static let manualApprovalIdentifier = "approval.manual-accessibility"

    /// The approval record the baseline allowlist carries.
    static let allowlistApprovalIdentifier = "approval.sample"

    // MARK: - Evidence index

    /// The release evidence the coherent baseline cites, plus anything a test adds.
    static func evidenceIndex(records: [EvidenceSource]? = nil) throws -> ReleaseEvidenceIndex {
        try ReleaseEvidenceIndex(
            records: records
                ?? [
                    Sample.evidence(allowlistApprovalIdentifier),
                    Sample.evidence(accessibilityEvidenceIdentifier),
                    Sample.evidence(localizationEvidenceIdentifier),
                    Sample.evidence(manualApprovalIdentifier),
                ]
        )
    }

    // MARK: - Allowlist

    /// One allowlist entry, with every mandatory device gate satisfied.
    static func entry(
        identifier: String = AccessibilityMatrixSample.baselineConfigurationIdentifier,
        hardware: String = "iPhone17.1",
        osVersion: PlatformVersion = .iOS17,
        appBuild: String = AccessibilityMatrixSample.appBuildIdentifier,
        capabilityManifest: String = AccessibilityMatrixSample.manifestIdentifier
    ) throws -> ApprovedDeviceConfiguration {
        try ApprovedDeviceConfiguration(
            id: Sample.configuration(identifier),
            configuration: CandidateDeviceConfiguration(
                deviceModel: Sample.text("Sample iPhone"),
                hardwareIdentifier: Sample.hardware(hardware),
                osVersion: osVersion,
                appBuild: Sample.appBuild(appBuild),
                isAppleNeuralEngineCapable: true
            ),
            versionTuple: ValidationVersionTuple(
                appBuild: Sample.appBuild(appBuild),
                modelBundle: Sample.bundle(),
                fixtureSuite: Sample.artifact("suite.fixtures"),
                validationPlan: Sample.artifact("plan.device-validation"),
                capabilityManifest: Sample.artifact(capabilityManifest),
                capabilities: [.pixelAnalysis],
                capabilityImplementationVersions: [
                    CapabilityImplementationEntry(
                        capability: .pixelAnalysis,
                        version: Sample.version()
                    )
                ]
            ),
            gateEvidence: Sample.gateReferences()
        )
    }

    static func allowlist(
        identifier: String = AccessibilityMatrixSample.allowlistIdentifier,
        entries: [ApprovedDeviceConfiguration]? = nil,
        approval: ApprovalDecision = .approved,
        approvalEvidence: String = AccessibilityMatrixSample.allowlistApprovalIdentifier
    ) throws -> ReleaseApprovedDeviceAllowlist {
        try ReleaseApprovedDeviceAllowlist(
            id: Sample.artifact(identifier),
            schemaVersion: .v1,
            entries: try entries ?? [entry()],
            approval: Sample.approval(approval, identifier: approvalEvidence)
        )
    }

    /// The coverage the validator derives from an allowlist: one position per entry, at
    /// the major iOS version that entry runs.
    static func coverage(
        of entries: [ApprovedDeviceConfiguration]
    ) -> [ApprovedMatrixCoverage] {
        entries
            .map {
                ApprovedMatrixCoverage(
                    configuration: $0.id,
                    osMajorVersion: $0.configuration.osVersion.majorVersion
                )
            }
            .sorted { $0.configuration.rawValue < $1.configuration.rawValue }
    }

    static var baselineCoverage: [ApprovedMatrixCoverage] {
        [
            ApprovedMatrixCoverage(
                configuration: Sample.configuration(baselineConfigurationIdentifier),
                osMajorVersion: PlatformVersion.iOS17.majorVersion
            )
        ]
    }

    // MARK: - Matrices

    /// Both matrices, complete and passing over `coverage` unless a test breaks one cell.
    ///
    /// `omitting`, `outcomes`, and `manual` are keyed by the cell key the matrix indexes a
    /// position by, so a test names exactly the position it changes.
    static func matrix(
        coverage: [ApprovedMatrixCoverage]? = nil,
        declaredConfigurations: [ApprovedConfigurationID]? = nil,
        declaredMajorVersions: [Int]? = nil,
        omitting omitted: Set<String> = [],
        outcomes: [String: GateOutcome] = [:],
        manual: Set<String> = [],
        manualApproval: String = AccessibilityMatrixSample.manualApprovalIdentifier,
        accessibilityEvidence: String = AccessibilityMatrixSample.accessibilityEvidenceIdentifier,
        localizationEvidence: String = AccessibilityMatrixSample.localizationEvidenceIdentifier,
        addingAccessibilityCells added: [AccessibilityResultCell] = [],
        addingLocalizationCells addedLocalization: [LocalizationResultCell] = []
    ) throws -> AccessibilityGateMatrix {
        let positions = coverage ?? baselineCoverage
        let execution = { (key: String) -> MatrixExecutionMode in
            manual.contains(key)
                ? .manual(importedEvidence: Sample.approval(identifier: manualApproval))
                : .automated
        }

        var accessibilityCells: [AccessibilityResultCell] = []
        for position in positions {
            for workflow in AccessibilityWorkflow.allCases {
                for condition in AssistiveCondition.allCases {
                    let key = AccessibilityResultCell.key(
                        workflow: workflow,
                        condition: condition,
                        osMajorVersion: position.osMajorVersion,
                        configuration: position.configuration
                    )
                    guard !omitted.contains(key) else { continue }
                    accessibilityCells.append(
                        try AccessibilityResultCell(
                            workflow: workflow,
                            condition: condition,
                            osMajorVersion: position.osMajorVersion,
                            configuration: position.configuration,
                            outcome: outcomes[key] ?? .passed,
                            execution: execution(key),
                            evidence: Sample.evidence(accessibilityEvidence)
                        )
                    )
                }
            }
        }

        var localizationCells: [LocalizationResultCell] = []
        for position in positions {
            for workflow in AccessibilityWorkflow.allCases {
                for variant in LocalizationTestVariant.allCases {
                    let key = LocalizationResultCell.key(
                        workflow: workflow,
                        variant: variant,
                        osMajorVersion: position.osMajorVersion,
                        configuration: position.configuration
                    )
                    guard !omitted.contains(key) else { continue }
                    localizationCells.append(
                        try LocalizationResultCell(
                            workflow: workflow,
                            variant: variant,
                            osMajorVersion: position.osMajorVersion,
                            configuration: position.configuration,
                            outcome: outcomes[key] ?? .passed,
                            execution: execution(key),
                            evidence: Sample.evidence(localizationEvidence)
                        )
                    )
                }
            }
        }

        return try AccessibilityGateMatrix(
            id: Sample.artifact(matrixIdentifier),
            schemaVersion: .v1,
            configurations: declaredConfigurations ?? positions.map(\.configuration),
            supportedMajorVersions: declaredMajorVersions
                ?? Set(positions.map(\.osMajorVersion)).sorted(),
            accessibilityCells: accessibilityCells + added,
            localizationCells: localizationCells + addedLocalization
        )
    }

    // MARK: - Validation

    /// The validated baseline, or the same validation with one input replaced.
    static func validated(
        matrix replacement: AccessibilityGateMatrix? = nil,
        allowlist replacementAllowlist: ReleaseApprovedDeviceAllowlist? = nil,
        manifest: ReleaseCapabilityManifest? = nil,
        evidence index: ReleaseEvidenceIndex? = nil
    ) throws -> ValidatedAccessibilityGateMatrix {
        try ValidatedAccessibilityGateMatrix(
            validating: try replacement ?? matrix(),
            against: try replacementAllowlist ?? allowlist(),
            capabilityManifest: try manifest ?? Sample.capabilityManifest(),
            evidence: try index ?? evidenceIndex()
        )
    }

    /// One accessibility cell key of the baseline coverage, for a test that breaks a
    /// single position.
    static func accessibilityKey(
        workflow: AccessibilityWorkflow = .analysis,
        condition: AssistiveCondition = .voiceOver,
        osMajorVersion: Int = PlatformVersion.iOS17.majorVersion,
        configuration: String = AccessibilityMatrixSample.baselineConfigurationIdentifier
    ) -> String {
        AccessibilityResultCell.key(
            workflow: workflow,
            condition: condition,
            osMajorVersion: osMajorVersion,
            configuration: Sample.configuration(configuration)
        )
    }

    /// One Localization Readiness cell key of the baseline coverage.
    static func localizationKey(
        workflow: AccessibilityWorkflow = .resultReview,
        variant: LocalizationTestVariant = .expansion,
        osMajorVersion: Int = PlatformVersion.iOS17.majorVersion,
        configuration: String = AccessibilityMatrixSample.baselineConfigurationIdentifier
    ) -> String {
        LocalizationResultCell.key(
            workflow: workflow,
            variant: variant,
            osMajorVersion: osMajorVersion,
            configuration: Sample.configuration(configuration)
        )
    }
}
