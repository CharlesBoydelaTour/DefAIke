import Foundation

// Release validation of the accessibility and Localization Readiness gate matrices.
//
// This is the layer that decides what the matrices *had* to record, and the layers below
// it cannot:
//
//   * ``AccessibilityResultCell`` and ``LocalizationResultCell`` validate one cell: a
//     major iOS version at or above 17, and an approved imported record behind any
//     manual pass.
//   * ``AccessibilityGateMatrix`` validates one artifact: a nonempty configuration list,
//     a nonempty supported-major-version list at or above iOS 17, no repeated entry in
//     either, and no cell key recorded twice. It also reports missing and failing cells
//     against the cross product of the two lists it declares itself.
//
// What none of them can decide:
//
//   * Whether the declared configuration list is the Release Approved iPhone
//     Configuration set. A matrix that lists one configuration and omits three approved
//     ones is internally complete, which is how an approved iPhone ships with no
//     assistive-technology evidence at all (Requirement 12.13).
//   * Whether the declared major versions are the ones this release supports. The list
//     is self-declared, so a release distributed to two major versions can record
//     evidence for one of them and report completeness.
//   * Whether a cell's major version is the version its configuration runs. An allowlist
//     entry names one exact operating-system version, so a cell recorded for that
//     configuration at a different major version describes a run nobody performed.
//   * Whether the cells answer for one application version. Requirements 12.14 and 12.18
//     block "the affected application version", which needs the evidence to belong to
//     one build rather than being pooled across builds (Requirement 13.20).
//   * Whether a cited result or an imported manual approval exists in this release. A
//     cell carries an ``EvidenceSource``, and a reference is not a record.
//
// The required cell set is derived here from the signed allowlist, one position per
// approved configuration at the major iOS version that configuration runs, rather than
// from the matrix's own cross product. The two agree for a release whose approved
// configurations all run one major version, and they differ when they do not: the cross
// product then demands a configuration approved at iOS 17 to have been tested on iOS 18,
// which is not that configuration, so the only ways to satisfy it are to record a run
// that never happened or to block every release. A position that cannot be executed
// cannot be evidence.
//
// ``ValidatedAccessibilityGateMatrix`` is the only way to hold matrices that passed all
// of it. Construction refuses a missing or failing applicable cell outright, because a
// mandatory accessibility or localization failure blocks the application version rather
// than excluding one configuration the way a physical-device gate does
// (Requirements 12.14 and 12.18 against Requirement 13.19).
//
// Deliberately absent: any applicability decision for a workflow, assistive condition,
// or localization variant. Requirements 12.8 and 12.10 through 12.12 make all of them
// mandatory for every distribution, so there is no member a waiver could occupy, and
// nothing here creates a configuration, an approval, or a result.

// MARK: - Approved coverage

/// One approved configuration and the major iOS version it runs.
///
/// A required cell is indexed by a configuration *and* a major version, and an allowlist
/// entry fixes both: it names one exact operating-system version (Requirement 13.1), so
/// the major version is not a free choice the matrix gets to make.
public struct ApprovedMatrixCoverage: Hashable, Sendable {
    public let configuration: ApprovedConfigurationID
    public let osMajorVersion: Int

    public init(configuration: ApprovedConfigurationID, osMajorVersion: Int) {
        self.configuration = configuration
        self.osMajorVersion = osMajorVersion
    }
}

// MARK: - Validated matrix

/// Accessibility and Localization Readiness matrices validated against the signed
/// allowlist they answer for.
///
/// Holding this value means the declared configurations and major versions are exactly
/// the ones this application version is approved for, every workflow was exercised under
/// every assistive condition and every localization variant on each of them, every one of
/// those cells passed, and every result reference and imported manual approval resolves
/// to evidence this release carries.
public struct ValidatedAccessibilityGateMatrix: Hashable, Sendable {
    /// The matrices, unchanged. Validation never repairs, normalizes, or fills a cell.
    public let matrix: AccessibilityGateMatrix

    /// The signed allowlist the required cell set was derived from.
    public let allowlist: ArtifactID

    /// The one application version these results answer for.
    public let appBuild: AppBuildID

    /// The configuration and major-version positions the matrices had to cover,
    /// ascending by configuration identifier.
    public let approvedCoverage: [ApprovedMatrixCoverage]

    /// Validates `matrix` against the allowlist and manifest this release binds.
    ///
    /// Fails closed with one ``ArtifactSchemaError`` naming the offending field or the
    /// exact cell keys, so an audit can point at one position rather than reporting
    /// "incomplete matrix". A failure is never an ``AnalysisError``: matrices that do not
    /// validate leave the application version undistributable instead of producing a
    /// user-facing verdict.
    public init(
        validating matrix: AccessibilityGateMatrix,
        against allowlist: ReleaseApprovedDeviceAllowlist,
        capabilityManifest: ReleaseCapabilityManifest,
        evidence index: ReleaseEvidenceIndex
    ) throws {
        let coverage = try Self.approvedCoverage(
            in: allowlist,
            manifest: capabilityManifest,
            evidence: index
        )
        try Self.validateDeclaredLists(matrix, coverage: coverage)
        try Self.validatePositions(matrix, coverage: coverage, allowlist: allowlist.id)
        try Self.validateApplicableCells(matrix, coverage: coverage)
        try Self.validateEvidence(matrix, against: index)

        self.matrix = matrix
        self.allowlist = allowlist.id
        self.appBuild = capabilityManifest.appBuild
        self.approvedCoverage = coverage
    }

    // MARK: Approved coverage

    /// Requirement 12.13: the positions to cover come from the signed allowlist.
    ///
    /// Every entry bound to this manifest counts, whatever its own gate outcomes say. An
    /// entry's mandatory gates include the two matrix gates themselves, so filtering to
    /// entries that already pass would let a configuration whose accessibility gate
    /// failed drop out of the required set and leave the remainder "complete"
    /// (Requirements 12.14 and 13.19).
    private static func approvedCoverage(
        in allowlist: ReleaseApprovedDeviceAllowlist,
        manifest: ReleaseCapabilityManifest,
        evidence index: ReleaseEvidenceIndex
    ) throws -> [ApprovedMatrixCoverage] {
        try ArtifactSchemaValidation.requireMatchingReference(
            allowlist.id,
            matches: manifest.approvedConfigurationAllowlist,
            field: "matrix.allowlist"
        )
        guard allowlist.approval.isApproved else {
            throw ArtifactSchemaError.forbiddenValue(
                field: "allowlist.approval.decision",
                value: allowlist.approval.decision.rawValue,
                reason: """
                    an unapproved allowlist names no Release Approved iPhone \
                    Configuration to have tested on
                    """
            )
        }
        try index.requireResolved(allowlist.approval.source, field: "allowlist.approval.source")

        // Whether the manifest itself is approved, and whether the module graph matches
        // it, belong to startup preflight and to release readiness. What this validator
        // needs from the manifest is which entries describe this application version.
        let entries = allowlist.entries.filter {
            $0.versionTuple.capabilityManifest == manifest.id
        }
        try ArtifactSchemaValidation.requireNonEmpty(
            entries,
            field: "allowlist.entries[\(manifest.id.rawValue)]"
        )
        for entry in entries {
            try ArtifactSchemaValidation.requireMatchingReference(
                entry.versionTuple.appBuild,
                matches: manifest.appBuild,
                field: "allowlist.entries[\(entry.id.rawValue)].versionTuple.appBuild"
            )
        }
        return entries
            .map {
                ApprovedMatrixCoverage(
                    configuration: $0.id,
                    osMajorVersion: $0.configuration.osVersion.majorVersion
                )
            }
            .sorted { $0.configuration.rawValue < $1.configuration.rawValue }
    }

    // MARK: Declared lists

    /// Requirement 12.13: the self-declared lists are exactly what the release ships.
    ///
    /// Coverage is exact in both directions. An omitted configuration or major version
    /// shrinks the matrix's own required set, and a configuration or version the
    /// allowlist does not approve describes a device this release never distributes to —
    /// evidence for it is not evidence for anything shipped.
    private static func validateDeclaredLists(
        _ matrix: AccessibilityGateMatrix,
        coverage: [ApprovedMatrixCoverage]
    ) throws {
        try ArtifactSchemaValidation.requireExactCoverage(
            matrix.configurations.map(\.rawValue),
            required: Set(coverage.map(\.configuration.rawValue)),
            field: "matrix.configurations"
        )
        try ArtifactSchemaValidation.requireExactCoverage(
            matrix.supportedMajorVersions.map(String.init),
            required: Set(coverage.map { String($0.osMajorVersion) }),
            field: "matrix.supportedMajorVersions"
        )
    }

    // MARK: Positions

    /// Every recorded cell describes an approved configuration at the version it runs.
    ///
    /// The matrix checks its declared lists and its cell keys separately, so nothing
    /// below requires a *cell* to name a listed configuration, and nothing pairs a cell's
    /// major version with the operating-system version its configuration was approved at.
    /// Both mismatches record a run against a configuration that did not perform it.
    private static func validatePositions(
        _ matrix: AccessibilityGateMatrix,
        coverage: [ApprovedMatrixCoverage],
        allowlist: ArtifactID
    ) throws {
        for cell in matrix.accessibilityCells {
            try Self.requireApprovedPosition(
                configuration: cell.configuration,
                osMajorVersion: cell.osMajorVersion,
                coverage: coverage,
                allowlist: allowlist,
                field: "matrix.accessibilityCells[\(cell)]"
            )
        }
        for cell in matrix.localizationCells {
            try Self.requireApprovedPosition(
                configuration: cell.configuration,
                osMajorVersion: cell.osMajorVersion,
                coverage: coverage,
                allowlist: allowlist,
                field: "matrix.localizationCells[\(cell)]"
            )
        }
    }

    private static func requireApprovedPosition(
        configuration: ApprovedConfigurationID,
        osMajorVersion: Int,
        coverage: [ApprovedMatrixCoverage],
        allowlist: ArtifactID,
        field: String
    ) throws {
        guard let approved = coverage.first(where: { $0.configuration == configuration }) else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).configuration",
                expected: "an approved configuration of allowlist \(allowlist.rawValue)",
                found: configuration.rawValue
            )
        }
        guard approved.osMajorVersion == osMajorVersion else {
            throw ArtifactSchemaError.inconsistentReference(
                field: "\(field).osMajorVersion",
                expected: "\(approved.osMajorVersion), the major version "
                    + "\(configuration.rawValue) runs",
                found: "\(osMajorVersion)"
            )
        }
    }

    // MARK: Applicable cells

    /// Requirements 12.13, 12.14, 12.17, and 12.18: every applicable cell is recorded and
    /// passing.
    ///
    /// Completeness is checked before outcomes so an audit hears "these positions have no
    /// result" separately from "this position failed". Both block the application
    /// version, and neither is recoverable here: this validator has no way to record a
    /// result and no way to waive one.
    private static func validateApplicableCells(
        _ matrix: AccessibilityGateMatrix,
        coverage: [ApprovedMatrixCoverage]
    ) throws {
        let missingAccessibility = Self.applicableAccessibilityCellKeys(coverage)
            .subtracting(matrix.accessibilityCells.map(\.description))
        guard missingAccessibility.isEmpty else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: "matrix.accessibilityCells",
                keys: missingAccessibility.sorted()
            )
        }
        let missingLocalization = Self.applicableLocalizationCellKeys(coverage)
            .subtracting(matrix.localizationCells.map(\.description))
        guard missingLocalization.isEmpty else {
            throw ArtifactSchemaError.missingRequiredEntries(
                field: "matrix.localizationCells",
                keys: missingLocalization.sorted()
            )
        }
        for cell in matrix.accessibilityCells {
            try Self.requirePassingOutcome(
                cell.outcome,
                field: "matrix.accessibilityCells[\(cell)]"
            )
        }
        for cell in matrix.localizationCells {
            try Self.requirePassingOutcome(
                cell.outcome,
                field: "matrix.localizationCells[\(cell)]"
            )
        }
    }

    /// A recorded cell that did not pass, reported by which of the two it is.
    ///
    /// A `not-executed` cell is the missing result of Requirements 12.14 and 12.18 written
    /// down rather than omitted, so it is reported as missing evidence; a failure is
    /// reported as a failure. Reaching either from a cell that survived the completeness
    /// check means the position exists and its evidence does not support distribution.
    private static func requirePassingOutcome(_ outcome: GateOutcome, field: String) throws {
        switch outcome {
        case .passed:
            return
        case .notExecuted:
            throw ArtifactSchemaError.missingRequiredEntries(
                field: field,
                keys: ["an executed result"]
            )
        case .failed:
            throw ArtifactSchemaError.forbiddenValue(
                field: "\(field).outcome",
                value: outcome.rawValue,
                reason: """
                    a failed mandatory accessibility or localization result blocks \
                    distribution of this application version
                    """
            )
        }
    }

    // MARK: Evidence

    /// Requirements 12.13 and 12.17: every stored reference names evidence that exists.
    ///
    /// Two references per manual cell, and they are separate questions. The result
    /// reference is the recorded run; the imported approval is the human conclusion about
    /// it. The cell schema already refuses a manual pass whose approval record is a
    /// rejection, so what is added here is existence: an approval nobody can resolve at
    /// the cited version and digest is a synthesized approval, and a manual accessibility
    /// or localization result is exactly what this validator must never manufacture.
    private static func validateEvidence(
        _ matrix: AccessibilityGateMatrix,
        against index: ReleaseEvidenceIndex
    ) throws {
        for cell in matrix.accessibilityCells {
            try Self.validateCellEvidence(
                result: cell.evidence,
                execution: cell.execution,
                field: "matrix.accessibilityCells[\(cell)]",
                against: index
            )
        }
        for cell in matrix.localizationCells {
            try Self.validateCellEvidence(
                result: cell.evidence,
                execution: cell.execution,
                field: "matrix.localizationCells[\(cell)]",
                against: index
            )
        }
    }

    private static func validateCellEvidence(
        result: EvidenceSource,
        execution: MatrixExecutionMode,
        field: String,
        against index: ReleaseEvidenceIndex
    ) throws {
        try index.requireResolved(result, field: "\(field).evidence")
        switch execution {
        case .automated:
            return
        case let .manual(importedEvidence):
            try index.requireResolved(
                importedEvidence.source,
                field: "\(field).execution.importedEvidence.source"
            )
        }
    }
}

// MARK: - Derived cell sets

extension ValidatedAccessibilityGateMatrix {
    /// Every accessibility position this release had to record, for one coverage set.
    ///
    /// Requirements 12.11 and 12.12 fix the workflow set and Requirements 12.8, 12.10,
    /// 12.11, and 12.12 fix the assistive conditions, so both are the whole closed
    /// vocabulary rather than a release choice.
    static func applicableAccessibilityCellKeys(
        _ coverage: [ApprovedMatrixCoverage]
    ) -> Set<String> {
        var keys: Set<String> = []
        for workflow in AccessibilityWorkflow.allCases {
            for condition in AssistiveCondition.allCases {
                for approved in coverage {
                    keys.insert(
                        AccessibilityResultCell.key(
                            workflow: workflow,
                            condition: condition,
                            osMajorVersion: approved.osMajorVersion,
                            configuration: approved.configuration
                        )
                    )
                }
            }
        }
        return keys
    }

    /// Every Localization Readiness position this release had to record, for one coverage
    /// set (Requirements 12.15, 12.16, and 12.17).
    static func applicableLocalizationCellKeys(
        _ coverage: [ApprovedMatrixCoverage]
    ) -> Set<String> {
        var keys: Set<String> = []
        for workflow in AccessibilityWorkflow.allCases {
            for variant in LocalizationTestVariant.allCases {
                for approved in coverage {
                    keys.insert(
                        LocalizationResultCell.key(
                            workflow: workflow,
                            variant: variant,
                            osMajorVersion: approved.osMajorVersion,
                            configuration: approved.configuration
                        )
                    )
                }
            }
        }
        return keys
    }
}

// MARK: - Validated accessors

extension ValidatedAccessibilityGateMatrix {
    /// The matrix artifact identifier, for a release record or an audit trail.
    public var id: ArtifactID { matrix.id }

    /// The approved configurations these matrices cover, ascending by identifier.
    public var coveredConfigurations: [ApprovedConfigurationID] {
        approvedCoverage.map(\.configuration)
    }

    /// The major iOS versions this release supports, ascending.
    ///
    /// Derived from the allowlist rather than read from the matrix, so it is the set of
    /// versions an approved configuration actually runs.
    public var supportedMajorVersions: [Int] {
        Set(approvedCoverage.map(\.osMajorVersion)).sorted()
    }

    /// Every accessibility position this release had to record, all of them passing.
    public var applicableAccessibilityCellKeys: Set<String> {
        Self.applicableAccessibilityCellKeys(approvedCoverage)
    }

    /// Every Localization Readiness position this release had to record, all passing.
    public var applicableLocalizationCellKeys: Set<String> {
        Self.applicableLocalizationCellKeys(approvedCoverage)
    }

    /// Every immutable result reference the two matrices bind, each one resolved.
    ///
    /// A reference rather than a copy of the result: the matrices cite recorded runs at a
    /// fixed version and content digest, and this validator neither reads nor reproduces
    /// what those runs measured.
    public var resultReferences: Set<EvidenceSource> {
        Set(matrix.accessibilityCells.map(\.evidence))
            .union(matrix.localizationCells.map(\.evidence))
    }

    /// The imported approval behind every manually executed cell, each one resolved.
    ///
    /// Empty means every cell was automated, never that a manual result was accepted
    /// without a record.
    public var importedManualApprovals: Set<ApprovalRecord> {
        var approvals: Set<ApprovalRecord> = []
        for execution in matrix.accessibilityCells.map(\.execution)
            + matrix.localizationCells.map(\.execution)
        {
            if case let .manual(importedEvidence) = execution {
                approvals.insert(importedEvidence)
            }
        }
        return approvals
    }

    /// The recorded accessibility result for one position, or `nil` when the position is
    /// not one this release covers.
    ///
    /// Never `nil` for a covered position: construction required every applicable cell to
    /// be present and passing.
    public func accessibilityResult(
        _ workflow: AccessibilityWorkflow,
        _ condition: AssistiveCondition,
        for configuration: ApprovedConfigurationID
    ) -> AccessibilityResultCell? {
        matrix.accessibilityCells.first {
            $0.workflow == workflow
                && $0.condition == condition
                && $0.configuration == configuration
        }
    }

    /// The recorded Localization Readiness result for one position, or `nil` when the
    /// position is not one this release covers.
    public func localizationResult(
        _ workflow: AccessibilityWorkflow,
        _ variant: LocalizationTestVariant,
        for configuration: ApprovedConfigurationID
    ) -> LocalizationResultCell? {
        matrix.localizationCells.first {
            $0.workflow == workflow
                && $0.variant == variant
                && $0.configuration == configuration
        }
    }
}
