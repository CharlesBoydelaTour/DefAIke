import Foundation

// Accessibility and Localization Readiness gate matrices.
//
// Requirement 12.13 requires accessibility tests recorded for every required workflow on
// each supported major iOS version and every approved configuration, and Requirement
// 12.17 requires the Localization Readiness Suite recorded for every required workflow.
// Requirements 12.14 and 12.18 block distribution when any mandatory result is missing or
// failing.
//
// The matrix is therefore built from the required cell set rather than from whatever
// results happen to exist, and a cell is either present with an outcome or reported as
// missing. Manual execution is representable, but only with an imported approval record:
// an unexecuted cell can never be marked as passed.

/// A workflow that must be operable with assistive technology (Requirements 12.11, 12.12).
public enum AccessibilityWorkflow: String, Codable, Sendable, Hashable, CaseIterable {
    case ingest
    case handoffConsent = "handoff-consent"
    case analysis
    case cancellation
    case resultReview = "result-review"
    case limitationReview = "limitation-review"
    case retry
}

/// The assistive technology or display condition a cell exercises.
public enum AssistiveCondition: String, Codable, Sendable, Hashable, CaseIterable {
    case voiceOver = "voice-over"
    case switchControl = "switch-control"
    case largestDynamicType = "largest-dynamic-type"
    case reduceMotion = "reduce-motion"
}

/// A Localization Readiness Suite copy variant (Requirements 12.15 and 12.16).
public enum LocalizationTestVariant: String, Codable, Sendable, Hashable, CaseIterable {
    case expansion
    case longWord = "long-word"
    case bidirectional
    case pseudolocalized
}

/// How a matrix cell was executed.
///
/// A manual cell carries the imported evidence approval, so a human result is traceable
/// and cannot be synthesized by the runner.
public enum MatrixExecutionMode: Hashable, Codable, Sendable {
    case automated
    case manual(importedEvidence: ApprovalRecord)

    /// Whether a recorded pass for this mode is admissible.
    public var isAdmissible: Bool {
        switch self {
        case .automated: true
        case let .manual(evidence): evidence.isApproved
        }
    }
}

/// One accessibility matrix cell.
public struct AccessibilityResultCell: Hashable, Codable, Sendable, CustomStringConvertible {
    public let workflow: AccessibilityWorkflow
    public let condition: AssistiveCondition
    public let osMajorVersion: Int
    public let configuration: ApprovedConfigurationID
    public let outcome: GateOutcome
    public let execution: MatrixExecutionMode
    public let evidence: EvidenceSource

    public init(
        workflow: AccessibilityWorkflow,
        condition: AssistiveCondition,
        osMajorVersion: Int,
        configuration: ApprovedConfigurationID,
        outcome: GateOutcome,
        execution: MatrixExecutionMode,
        evidence: EvidenceSource
    ) throws {
        guard osMajorVersion >= PlatformVersion.iOS17.majorVersion else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "accessibilityCell.osMajorVersion",
                value: "\(osMajorVersion)",
                allowed: "at least \(PlatformVersion.iOS17.majorVersion)"
            )
        }
        if outcome.isPassing, !execution.isAdmissible {
            throw ArtifactSchemaError.forbiddenValue(
                field: "accessibilityCell.execution",
                value: "unapproved manual evidence",
                reason: "a manual pass needs an approved imported result"
            )
        }
        self.workflow = workflow
        self.condition = condition
        self.osMajorVersion = osMajorVersion
        self.configuration = configuration
        self.outcome = outcome
        self.execution = execution
        self.evidence = evidence
    }

    /// Stable key identifying this cell's position in the matrix.
    public var description: String {
        Self.key(
            workflow: workflow,
            condition: condition,
            osMajorVersion: osMajorVersion,
            configuration: configuration
        )
    }

    /// The matrix key for one accessibility position, with or without a result.
    ///
    /// Deriving the required cell set names positions that may have no recorded result
    /// at all, so the key has to be constructible from the position alone. Sharing it
    /// with ``description`` keeps a required key and a recorded key spelled the same
    /// way; two spellings would report every cell as missing (Requirement 12.13).
    public static func key(
        workflow: AccessibilityWorkflow,
        condition: AssistiveCondition,
        osMajorVersion: Int,
        configuration: ApprovedConfigurationID
    ) -> String {
        "\(workflow.rawValue)/\(condition.rawValue)/ios\(osMajorVersion)/\(configuration.rawValue)"
    }

    private enum CodingKeys: String, CodingKey {
        case workflow, condition, osMajorVersion, configuration, outcome, execution, evidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                workflow: container.decode(AccessibilityWorkflow.self, forKey: .workflow),
                condition: container.decode(AssistiveCondition.self, forKey: .condition),
                osMajorVersion: container.decode(Int.self, forKey: .osMajorVersion),
                configuration: container.decode(
                    ApprovedConfigurationID.self,
                    forKey: .configuration
                ),
                outcome: container.decode(GateOutcome.self, forKey: .outcome),
                execution: container.decode(MatrixExecutionMode.self, forKey: .execution),
                evidence: container.decode(EvidenceSource.self, forKey: .evidence)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// One Localization Readiness matrix cell.
public struct LocalizationResultCell: Hashable, Codable, Sendable, CustomStringConvertible {
    public let workflow: AccessibilityWorkflow
    public let variant: LocalizationTestVariant
    public let osMajorVersion: Int
    public let configuration: ApprovedConfigurationID
    public let outcome: GateOutcome
    public let execution: MatrixExecutionMode
    public let evidence: EvidenceSource

    public init(
        workflow: AccessibilityWorkflow,
        variant: LocalizationTestVariant,
        osMajorVersion: Int,
        configuration: ApprovedConfigurationID,
        outcome: GateOutcome,
        execution: MatrixExecutionMode,
        evidence: EvidenceSource
    ) throws {
        guard osMajorVersion >= PlatformVersion.iOS17.majorVersion else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "localizationCell.osMajorVersion",
                value: "\(osMajorVersion)",
                allowed: "at least \(PlatformVersion.iOS17.majorVersion)"
            )
        }
        if outcome.isPassing, !execution.isAdmissible {
            throw ArtifactSchemaError.forbiddenValue(
                field: "localizationCell.execution",
                value: "unapproved manual evidence",
                reason: "a manual pass needs an approved imported result"
            )
        }
        self.workflow = workflow
        self.variant = variant
        self.osMajorVersion = osMajorVersion
        self.configuration = configuration
        self.outcome = outcome
        self.execution = execution
        self.evidence = evidence
    }

    public var description: String {
        Self.key(
            workflow: workflow,
            variant: variant,
            osMajorVersion: osMajorVersion,
            configuration: configuration
        )
    }

    /// The matrix key for one Localization Readiness position, with or without a result.
    public static func key(
        workflow: AccessibilityWorkflow,
        variant: LocalizationTestVariant,
        osMajorVersion: Int,
        configuration: ApprovedConfigurationID
    ) -> String {
        "\(workflow.rawValue)/\(variant.rawValue)/ios\(osMajorVersion)/\(configuration.rawValue)"
    }

    private enum CodingKeys: String, CodingKey {
        case workflow, variant, osMajorVersion, configuration, outcome, execution, evidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                workflow: container.decode(AccessibilityWorkflow.self, forKey: .workflow),
                variant: container.decode(LocalizationTestVariant.self, forKey: .variant),
                osMajorVersion: container.decode(Int.self, forKey: .osMajorVersion),
                configuration: container.decode(
                    ApprovedConfigurationID.self,
                    forKey: .configuration
                ),
                outcome: container.decode(GateOutcome.self, forKey: .outcome),
                execution: container.decode(MatrixExecutionMode.self, forKey: .execution),
                evidence: container.decode(EvidenceSource.self, forKey: .evidence)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// The complete accessibility and localization gate matrix for one release.
///
/// The required cell set is derived from the declared configurations and supported major
/// iOS versions, so a missing cell is visible as missing instead of simply absent.
public struct AccessibilityGateMatrix: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// Configurations the matrix must cover. Never empty.
    public let configurations: [ApprovedConfigurationID]

    /// Supported major iOS versions the matrix must cover. Never empty.
    public let supportedMajorVersions: [Int]

    public let accessibilityCells: [AccessibilityResultCell]
    public let localizationCells: [LocalizationResultCell]

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        configurations: [ApprovedConfigurationID],
        supportedMajorVersions: [Int],
        accessibilityCells: [AccessibilityResultCell],
        localizationCells: [LocalizationResultCell]
    ) throws {
        try ArtifactSchemaValidation.requireNonEmpty(configurations, field: "matrix.configurations")
        try ArtifactSchemaValidation.requireUniqueKeys(
            configurations.map(\.rawValue),
            field: "matrix.configurations"
        )
        try ArtifactSchemaValidation.requireNonEmpty(
            supportedMajorVersions,
            field: "matrix.supportedMajorVersions"
        )
        try ArtifactSchemaValidation.requireUniqueKeys(
            supportedMajorVersions.map(String.init),
            field: "matrix.supportedMajorVersions"
        )
        for version in supportedMajorVersions where version < PlatformVersion.iOS17.majorVersion {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "matrix.supportedMajorVersions",
                value: "\(version)",
                allowed: "at least \(PlatformVersion.iOS17.majorVersion)"
            )
        }
        try ArtifactSchemaValidation.requireUniqueKeys(
            accessibilityCells.map(\.description),
            field: "matrix.accessibilityCells"
        )
        try ArtifactSchemaValidation.requireUniqueKeys(
            localizationCells.map(\.description),
            field: "matrix.localizationCells"
        )
        self.id = id
        self.schemaVersion = schemaVersion
        self.configurations = configurations
        self.supportedMajorVersions = supportedMajorVersions
        self.accessibilityCells = accessibilityCells
        self.localizationCells = localizationCells
    }

    /// Every accessibility cell key this release must record.
    public var requiredAccessibilityCellKeys: Set<String> {
        var keys: Set<String> = []
        for workflow in AccessibilityWorkflow.allCases {
            for condition in AssistiveCondition.allCases {
                for version in supportedMajorVersions {
                    for configuration in configurations {
                        keys.insert(
                            AccessibilityResultCell.key(
                                workflow: workflow,
                                condition: condition,
                                osMajorVersion: version,
                                configuration: configuration
                            )
                        )
                    }
                }
            }
        }
        return keys
    }

    /// Every localization cell key this release must record.
    public var requiredLocalizationCellKeys: Set<String> {
        var keys: Set<String> = []
        for workflow in AccessibilityWorkflow.allCases {
            for variant in LocalizationTestVariant.allCases {
                for version in supportedMajorVersions {
                    for configuration in configurations {
                        keys.insert(
                            LocalizationResultCell.key(
                                workflow: workflow,
                                variant: variant,
                                osMajorVersion: version,
                                configuration: configuration
                            )
                        )
                    }
                }
            }
        }
        return keys
    }

    /// Required cell keys with no recorded result.
    public var missingCellKeys: Set<String> {
        let recordedAccessibility = Set(accessibilityCells.map(\.description))
        let recordedLocalization = Set(localizationCells.map(\.description))
        return requiredAccessibilityCellKeys.subtracting(recordedAccessibility)
            .union(requiredLocalizationCellKeys.subtracting(recordedLocalization))
    }

    /// Recorded cells that did not pass.
    public var failingCellKeys: Set<String> {
        Set(accessibilityCells.filter { !$0.outcome.isPassing }.map(\.description))
            .union(localizationCells.filter { !$0.outcome.isPassing }.map(\.description))
    }

    /// Whether every required cell is recorded and passing (Requirements 12.14, 12.18).
    public var isComplete: Bool { missingCellKeys.isEmpty && failingCellKeys.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, configurations, supportedMajorVersions, accessibilityCells
        case localizationCells
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                configurations: container.decode(
                    [ApprovedConfigurationID].self,
                    forKey: .configurations
                ),
                supportedMajorVersions: container.decode(
                    [Int].self,
                    forKey: .supportedMajorVersions
                ),
                accessibilityCells: container.decode(
                    [AccessibilityResultCell].self,
                    forKey: .accessibilityCells
                ),
                localizationCells: container.decode(
                    [LocalizationResultCell].self,
                    forKey: .localizationCells
                )
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}
