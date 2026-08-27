import DefAIkeDomain

// The closed set of accessibility and Localization Readiness matrix cells a release owes, and
// where each cell's execution mode, evidence, and blockers come from.
//
// Requirement 12.13 requires accessibility tests executed and recorded for every required
// workflow on each supported major iOS version and every Release Approved iPhone
// Configuration. Requirement 12.17 requires the same of the Localization Readiness Suite.
// Requirements 12.14 and 12.18 block distribution of the affected application version when any
// mandatory result is missing or failing.
//
// `AccessibilityWorkflow`, `AssistiveCondition`, and `LocalizationTestVariant` in the domain are
// already exactly the three vocabularies those requirements name, so nothing here invents a
// workflow, an assistive condition, or a localization variant. `AccessibilityResultCell.key` and
// `LocalizationResultCell.key` already fix how a matrix position is spelled, so nothing here
// invents a second spelling either — a required key and a recorded key that disagreed would
// report every cell as missing.
//
// What this file adds is the layout: for a given plan, *which* cells are owed, on *which*
// configuration at *which* major iOS version, executable by *which* means, contributing to
// *which* gate, and blocked by *which* named finding. Every one of those is a total function over
// a closed vocabulary, written without a `default`, so adding a workflow, a condition, or a
// variant to the domain is a compile error here rather than a matrix cell that quietly stops
// being required.
//
// Four rules run through the whole file, and each is structural rather than documentary:
//
//   * **A cell's major iOS version is its configuration's, not a free choice.** A candidate
//     configuration names one exact operating-system version (Requirement 13.1), so
//     ``AccessibilityMatrixCell/osMajorVersion`` is derived from it and there is no parameter a
//     caller could use to record a run at a version that configuration does not run. The domain
//     validator reaches the same conclusion from the other end: a position that cannot be
//     executed cannot be evidence.
//   * **An automated run cannot answer a cell that needs a human.** ``MatrixAutomationSupport``
//     is total over ``MatrixExercise``, and a cell whose support is
//     ``MatrixAutomationSupport/manualOnly(_:)`` refuses an automated observation outright. Two
//     of the five variants this task names are manual-only, and no amount of harness work makes
//     them otherwise: iOS exposes no supported way for a test process to turn VoiceOver or
//     Switch Control on.
//   * **A manual cell needs an imported, versioned, digest-bound reference *and* an approved
//     decision naming that cell.** ``ImportedManualEvidence`` carries both, and
//     ``QualifyingMatrixEvidence`` — whose only initialiser is internal to this module — refuses
//     an approval for another cell, an unapproved decision, and an approval whose own record is
//     the result it approves. So "approved manual portion" is a conjunction the type system
//     checks rather than a convention.
//   * **An observation records where it was produced.** ``MatrixCellObservation`` requires an
//     ``ExecutionEnvironment`` and the configuration and version tuple the run ran under, so a
//     host or simulator run is recordable and honest. Turning one into evidence that satisfies a
//     device gate needs ``QualifyingMatrixEvidence``, which refuses anything but a physical
//     iPhone on a configuration the bound plan enumerates.

// MARK: - What one cell exercises

/// The assistive technology, display condition, or localization variant one cell exercises.
///
/// Two shapes, because the two matrices are separate gates over the same workflow set.
/// Requirements 12.8 and 12.10 through 12.12 fix the four assistive conditions and
/// Requirements 12.15 and 12.16 fix the four localization variants, so both are the whole closed
/// domain vocabulary rather than a release choice.
public enum MatrixExercise: Hashable, Sendable, CustomStringConvertible {
    /// One assistive technology or display condition (Requirement 12.13).
    case assistive(AssistiveCondition)

    /// One Localization Readiness Suite copy variant (Requirement 12.17).
    case localization(LocalizationTestVariant)

    /// The stable key fragment this exercise contributes to a matrix position.
    ///
    /// The two domain vocabularies have disjoint raw values, so one namespace is unambiguous and
    /// a condition key can never be read as a variant key.
    public var key: String {
        switch self {
        case let .assistive(condition): condition.rawValue
        case let .localization(variant): variant.rawValue
        }
    }

    /// The mandatory device gate this exercise's cells are recorded under.
    ///
    /// Two gates, and they are separate because Requirements 12.14 and 12.18 are separate: a
    /// missing accessibility result and a missing Localization Readiness result each block the
    /// affected application version on their own.
    public var gate: DeviceGate {
        switch self {
        case .assistive: .accessibilityMatrix
        case .localization: .localizationReadinessMatrix
        }
    }

    public var description: String { key }

    /// Every exercise a release owes, in a stable order: the four conditions then the four
    /// variants.
    public static var required: [MatrixExercise] {
        AssistiveCondition.allCases.map { MatrixExercise.assistive($0) }
            + LocalizationTestVariant.allCases.map { MatrixExercise.localization($0) }
    }
}

/// One matrix position a release owes: a workflow, an exercise, and a candidate configuration.
///
/// The unit of the closed required set. A run's report holds one outcome per cell and no optional
/// that could be read as "recorded", which is what makes an unexecuted cell a failure
/// structurally rather than by convention.
public struct AccessibilityMatrixCell: Hashable, Sendable, CustomStringConvertible {
    public let workflow: AccessibilityWorkflow
    public let exercise: MatrixExercise

    /// The candidate configuration this position is executed on.
    ///
    /// Carried whole rather than as an identifier, because the major iOS version is read from it
    /// and an identifier would leave the version free to disagree with the device.
    public let configuration: CandidateDeviceConfiguration

    public init(
        workflow: AccessibilityWorkflow,
        exercise: MatrixExercise,
        configuration: CandidateDeviceConfiguration
    ) {
        self.workflow = workflow
        self.exercise = exercise
        self.configuration = configuration
    }

    /// The major iOS version this position is executed at.
    ///
    /// Derived, never supplied. An allowlist entry and a plan candidate each name one exact
    /// operating-system version, so a cell recorded for this configuration at any other major
    /// version would describe a run nobody performed.
    public var osMajorVersion: Int { configuration.osVersion.majorVersion }

    /// The mandatory device gate this cell's result is recorded under.
    public var gate: DeviceGate { exercise.gate }

    /// The matrix position, spelled the way the domain spells it.
    ///
    /// Uses the hardware identifier in place of an ``ApprovedConfigurationID``, because a
    /// *candidate* configuration has no approved identifier yet: the allowlist assigns one after
    /// validation, and a runner that minted one would be naming an approval it cannot make.
    /// ``recordedKey(as:)`` produces the domain spelling once an approved identifier exists.
    public var matrixKey: String {
        "\(workflow.rawValue)/\(exercise.key)/ios\(osMajorVersion)/"
            + configuration.hardwareIdentifier.rawValue
    }

    /// The domain's matrix key for this position, under an approved configuration identifier.
    ///
    /// Delegates to ``AccessibilityResultCell/key(workflow:condition:osMajorVersion:configuration:)``
    /// and ``LocalizationResultCell/key(workflow:variant:osMajorVersion:configuration:)`` rather
    /// than restating either, so a produced position and a required position cannot be spelled
    /// two different ways.
    public func recordedKey(as identifier: ApprovedConfigurationID) -> String {
        switch exercise {
        case let .assistive(condition):
            AccessibilityResultCell.key(
                workflow: workflow,
                condition: condition,
                osMajorVersion: osMajorVersion,
                configuration: identifier
            )
        case let .localization(variant):
            LocalizationResultCell.key(
                workflow: workflow,
                variant: variant,
                osMajorVersion: osMajorVersion,
                configuration: identifier
            )
        }
    }

    /// A stable ordering key, so two runs over the same plan enumerate identically.
    public var orderingKey: String {
        "\(gate.rawValue)\u{1F}\(matrixKey)"
    }

    public var description: String { matrixKey }

    /// Every cell one configuration owes, in a stable order.
    ///
    /// Fifty-six positions: seven workflows against four assistive conditions and four
    /// localization variants. The workflow set comes from the domain rather than from a list
    /// restated here, so the runner and the matrix schema cannot drift about which workflows a
    /// release owes.
    public static func required(
        on configuration: CandidateDeviceConfiguration
    ) -> [AccessibilityMatrixCell] {
        var cells: [AccessibilityMatrixCell] = []
        for workflow in AccessibilityWorkflow.allCases {
            for exercise in MatrixExercise.required {
                cells.append(
                    AccessibilityMatrixCell(
                        workflow: workflow,
                        exercise: exercise,
                        configuration: configuration
                    )
                )
            }
        }
        return cells.sorted { $0.orderingKey < $1.orderingKey }
    }
}

// MARK: - How a cell can be executed at all

/// Whether a cell can be executed by automation, and if not, why.
///
/// Total over ``MatrixExercise``, written without a `default`. The second and third cases are not
/// placeholders: each names a finding this repository already made, and the two are closed by
/// different work. A manual-only cell is executable today by a human whose result is imported; a
/// cell whose automation reaches nothing is not executable at all until the substitution
/// mechanism it exercises actually substitutes something.
public enum MatrixAutomationSupport: Hashable, Sendable, CustomStringConvertible {
    /// A device harness can put the application into this condition and observe the workflow.
    case automatable

    /// A harness can run the variant, and running it exercises nothing.
    ///
    /// Recorded rather than reported as a pass, and blocking: an automated run that substitutes no
    /// rendered string establishes nothing about Requirements 12.15 and 12.16.
    case automatableWithoutEffect(UnobservableAccessibilityMatrixEvidence)

    /// No supported automation can enable this condition, so the cell needs imported human
    /// evidence and an approved decision permitting it.
    case manualOnly(UnobservableAccessibilityMatrixEvidence)

    /// Whether an automated observation may answer a cell with this support.
    ///
    /// False for both non-automatable cases. A manual-only cell refuses an automated observation
    /// rather than accepting one that could not have exercised the condition it names.
    public var admitsAutomatedEvidence: Bool {
        switch self {
        case .automatable: true
        case .automatableWithoutEffect, .manualOnly: false
        }
    }

    /// Whether a cell with this support needs imported manual evidence to be satisfied at all.
    public var requiresImportedManualEvidence: Bool {
        switch self {
        case .manualOnly: true
        case .automatable, .automatableWithoutEffect: false
        }
    }

    /// The finding this support names, when it names one.
    public var limit: UnobservableAccessibilityMatrixEvidence? {
        switch self {
        case .automatable: nil
        case let .automatableWithoutEffect(limit): limit
        case let .manualOnly(limit): limit
        }
    }

    public var description: String {
        switch self {
        case .automatable: "automatable"
        case let .automatableWithoutEffect(limit): "automatable but inert: \(limit.rawValue)"
        case let .manualOnly(limit): "manual only: \(limit.rawValue)"
        }
    }
}

extension MatrixExercise {

    /// Whether this exercise can be automated, and if not, why.
    ///
    /// The answer for each of the five variants Requirement 12.13 and 12.17 span:
    ///
    ///   * *Largest Dynamic Type* and *Reduce Motion* are automatable. Both are display
    ///     conditions a test process can put the application into, and both leave observable
    ///     evidence — reflow without clipping, and a nonmoving state change.
    ///   * *VoiceOver* and *Switch Control* are not. iOS exposes no supported interface for a
    ///     test process to enable either, so the run a matrix cell needs is a human one, and the
    ///     cell is satisfiable only by an imported result with an approved decision behind it.
    ///   * *Every localization variant* is automatable in form and inert in substance. The
    ///     Localization Readiness catalogs hold exactly the three `copy.pixel-label.*` keys, the
    ///     keys any accessible element addresses are disjoint from them, and the single
    ///     renderable element resolves through a fixed-text path that bypasses the catalog
    ///     entirely. So an expansion, long-word, bidirectional, or pseudolocalized run renders
    ///     the same English as the shipped catalog, and the bracket-clipping signal
    ///     pseudolocalization exists to produce cannot appear. Blocked rather than passed.
    public var automationSupport: MatrixAutomationSupport {
        switch self {
        case let .assistive(condition):
            switch condition {
            case .voiceOver:
                return .manualOnly(.voiceOverCannotBeEnabledByAutomation)
            case .switchControl:
                return .manualOnly(.switchControlCannotBeEnabledByAutomation)
            case .largestDynamicType, .reduceMotion:
                return .automatable
            }
        case .localization:
            return .automatableWithoutEffect(.localizationSubstitutionReachesNoRenderedString)
        }
    }
}

extension AccessibilityMatrixCell {

    /// Whether this cell can be executed by automation, and if not, why.
    public var automationSupport: MatrixAutomationSupport { exercise.automationSupport }

    /// The release-controlled input a missing result for this cell is owed from.
    ///
    /// Total, so a gap is always attributable to something a release has to supply rather than to
    /// "no result".
    public var owedReleaseInput: UnprovisionedAccessibilityMatrixInput {
        switch exercise {
        case .localization:
            return .localizationReadinessSuiteProcedure
        case let .assistive(condition):
            switch condition {
            case .voiceOver: return .voiceOverManualRunRecord
            case .switchControl: return .switchControlManualRunRecord
            case .largestDynamicType, .reduceMotion: return .accessibilityMatrixProcedure
            }
        }
    }

    /// Standing findings that qualify — or prevent — what this cell's result establishes.
    ///
    /// Recorded whatever the outcome, because they are properties of the implementation and the
    /// artifact schema rather than of one run: they do not become true when a cell fails and
    /// false when it passes. A finding whose
    /// ``UnobservableAccessibilityMatrixEvidence/blocksExercise`` is true additionally prevents
    /// the cell from being exercised at all.
    ///
    /// Written as an exhaustive switch over workflow and exercise with no `default`, so a new
    /// workflow or condition forces a decision about what qualifies it.
    public var standingLimits: Set<UnobservableAccessibilityMatrixEvidence> {
        // Four findings apply to every cell in both matrices, because all four are properties of
        // the layers a matrix run observes rather than of any one position.
        var limits: Set<UnobservableAccessibilityMatrixEvidence> = [
            .accessibilityMatrixCellHasNoPlanSpecification,
            .assistiveConditionIsAbsentFromThePlanMeasurementKey,
            .supportedMajorVersionSetIsDerivedFromPlanCandidates,
            .workflowOperabilityIsNotReachableFromThisModule,
        ]
        switch workflow {
        case .handoffConsent:
            // Handoff consent lives in the Share Extension, which carries no accessibility
            // projection at all and for which the approved copy surface defines no entry. There
            // is nothing on that side of the boundary for a matrix run to exercise.
            limits.insert(.shareExtensionExposesNoAccessibilityProjection)
        case .retry:
            // The required identity set for the retry workflow names the image-selection
            // control, and the error screen exposes recovery under a different identity. So the
            // one renderable recovery control is credited to no workflow, the retry position is
            // inoperable, and the cell carries no diagnosis of its own. A defect reported here,
            // not fixed here.
            limits.insert(.retryRecoveryControlIsCreditedToNoWorkflow)
        case .ingest, .analysis, .cancellation, .resultReview, .limitationReview:
            break
        }
        switch exercise {
        case let .assistive(condition):
            // Requirement 12.2's programmatic value is satisfied only by its own escape hatch:
            // every projected element exposes no value at all, so the nonempty-value check passes
            // vacuously and a matrix pass under any assistive condition establishes less than its
            // name suggests.
            limits.insert(.everyExposedAccessibilityValueIsAbsent)
            switch condition {
            case .voiceOver:
                limits.insert(.voiceOverCannotBeEnabledByAutomation)
            case .switchControl:
                limits.insert(.switchControlCannotBeEnabledByAutomation)
            case .largestDynamicType, .reduceMotion:
                break
            }
        case .localization:
            limits.insert(.localizationSubstitutionReachesNoRenderedString)
            limits.insert(.localizationCatalogKeysAreDisjointFromAddressedKeys)
            limits.insert(.fixedPixelLabelTextBypassesTheCopyCatalog)
        }
        return limits
    }

    /// The first standing finding that prevents this cell from being exercised, or `nil`.
    ///
    /// Ordered by raw value so two runs over the same cell name the same blocker. Determinism
    /// matters more than which of several blockers is reported first: a cell with any blocker is
    /// not a cell that passed, and the report carries the whole set beside the outcome.
    public var blockingLimit: UnobservableAccessibilityMatrixEvidence? {
        standingLimits
            .sorted { $0.rawValue < $1.rawValue }
            .first { $0.blocksExercise }
    }
}

extension DeviceGate {
    /// The two matrix gates this task records, in declaration order.
    ///
    /// Derived from ``MatrixExercise/required`` rather than restated, so the two cannot drift.
    public static var matrixGates: [DeviceGate] {
        let named = Set(MatrixExercise.required.map(\.gate))
        return DeviceGate.allCases.filter { named.contains($0) }
    }
}

// MARK: - Observations

/// What one matrix run observed about a workflow under one exercise.
///
/// A closed vocabulary with exactly one satisfying case. No boolean, no count, no outcome: a
/// reader states what it saw, and what that means is the run's answer. The failing cases are the
/// clauses Requirements 12.1 through 12.16 impose, one case each, so a failing cell names the
/// clause that failed rather than reporting a bare failure.
public enum ObservedWorkflowCoverage: Hashable, Sendable, CaseIterable, CustomStringConvertible {
    /// Every step of the workflow was reached and the workflow was completed under this exercise
    /// (Requirements 12.11, 12.12).
    ///
    /// The only satisfying observation.
    case workflowCompleted

    /// The workflow was reachable and could not be completed.
    case workflowNotCompleted

    /// A required control or evidence field exposed no label, value, or matching trait
    /// (Requirements 12.1, 12.2, 12.3).
    case semanticsIncomplete

    /// Content was clipped, truncated, or overlapped (Requirements 12.8, 12.15).
    case layoutNotReadable

    /// The reading or action order did not match the displayed order (Requirement 12.4).
    case orderNotPreserved

    /// Accessibility focus moved off an element that remained available (Requirement 12.6).
    case focusNotRetained

    /// An interactive control's activation area was under the required size (Requirement 12.9).
    case activationAreaTooSmall

    /// A status, warning, or outcome was conveyed without text (Requirements 12.5, 12.7, 12.10).
    case statusNotConveyedAsText

    /// The substituted test copy replaced no rendered string (Requirements 12.15, 12.16).
    case substitutedCopyNotRendered

    /// Whether this observation satisfies the clause set the cell is checked against.
    public var completesTheWorkflow: Bool { self == .workflowCompleted }

    public var description: String {
        switch self {
        case .workflowCompleted: "the workflow completed under this exercise"
        case .workflowNotCompleted: "the workflow could not be completed"
        case .semanticsIncomplete: "a required control exposed no label, value, or trait"
        case .layoutNotReadable: "content was clipped, truncated, or overlapped"
        case .orderNotPreserved: "the reading or action order did not match the display"
        case .focusNotRetained: "accessibility focus left an element that remained available"
        case .activationAreaTooSmall: "an activation area was under the required size"
        case .statusNotConveyedAsText: "a status was conveyed without text"
        case .substitutedCopyNotRendered: "the substituted copy replaced no rendered string"
        }
    }
}

/// One imported human result and the approved decision permitting it, for one exact cell.
///
/// The whole of "require explicit imported evidence references for any approved manual portion"
/// in one value, and it is deliberately a conjunction of three independent things:
///
///   1. ``importedResult`` — a versioned, digest-bound ``EvidenceSource`` naming the immutable
///      record of the human run. A reference to fixed bytes, not to a mutable document at an
///      identifier.
///   2. ``authorization`` — an ``ApprovalRecord`` whose decision says the manual portion is
///      permitted. Presence is not approval: a rejection is representable and refused.
///   3. ``cellKey`` — the position the authorization was granted for. A blanket approval for
///      "manual accessibility testing" cannot satisfy a cell it does not name.
///
/// Public and permissive on purpose: a reader states what it imported. What no caller can do is
/// turn one into a satisfied cell — that needs ``QualifyingMatrixEvidence``, whose initialiser is
/// internal to this module and checks all three plus the environment gate.
public struct ImportedManualEvidence: Hashable, Sendable {
    /// The matrix position this evidence was imported for, as ``AccessibilityMatrixCell/matrixKey``
    /// spells it.
    public let cellKey: String

    /// The immutable, versioned, digest-bound record of the human run.
    public let importedResult: EvidenceSource

    /// The approved decision permitting the manual portion at that position.
    public let authorization: ApprovalRecord

    public init(
        cellKey: String,
        importedResult: EvidenceSource,
        authorization: ApprovalRecord
    ) {
        self.cellKey = cellKey
        self.importedResult = importedResult
        self.authorization = authorization
    }
}

/// How one observation was executed.
///
/// Distinct from the domain's `MatrixExecutionMode`, which is what a *recorded* matrix carries. A
/// run supplies this, and the run decides whether the mode is admissible for the cell.
public enum ObservedMatrixExecution: Hashable, Sendable, CustomStringConvertible {
    /// A device harness executed the cell.
    case automated

    /// A human executed the cell, and this is the imported result plus its authorization.
    case manual(ImportedManualEvidence)

    /// The imported evidence, for a manual execution.
    public var importedEvidence: ImportedManualEvidence? {
        switch self {
        case .automated: nil
        case let .manual(evidence): evidence
        }
    }

    public var description: String {
        switch self {
        case .automated: "automated"
        case let .manual(evidence): "manual, imported as \(evidence.importedResult.artifact.rawValue)"
        }
    }
}

/// One observation of one matrix cell, and the exact conditions it was produced under.
///
/// Public and permissive on purpose. A development-Mac or simulator observation is a real thing a
/// run produces and recording it honestly is better than refusing to represent it. What no caller
/// can do is turn one into a satisfied gate: that needs ``QualifyingMatrixEvidence``, and its
/// initialiser is internal to this module.
public struct MatrixCellObservation: Hashable, Sendable {
    /// The cell this observation answers.
    public let cell: AccessibilityMatrixCell

    /// What the run observed.
    public let coverage: ObservedWorkflowCoverage

    /// How the cell was executed.
    public let execution: ObservedMatrixExecution

    /// The immutable, versioned, digest-bound record of this run.
    ///
    /// Required whatever the execution mode. Requirement 12.13 records results; a result nobody
    /// can resolve at a fixed version and digest is not a recorded result, and a matrix cell
    /// citing one would be citing itself.
    public let resultReference: EvidenceSource

    /// Where the observation was produced.
    public let environment: ExecutionEnvironment

    /// The configuration it was produced on.
    public let configuration: CandidateDeviceConfiguration

    /// The exact version tuple the run used (Requirements 13.17 and 13.20).
    public let versionTuple: ValidationVersionTuple

    public init(
        cell: AccessibilityMatrixCell,
        coverage: ObservedWorkflowCoverage,
        execution: ObservedMatrixExecution,
        resultReference: EvidenceSource,
        environment: ExecutionEnvironment,
        configuration: CandidateDeviceConfiguration,
        versionTuple: ValidationVersionTuple
    ) {
        self.cell = cell
        self.coverage = coverage
        self.execution = execution
        self.resultReference = resultReference
        self.environment = environment
        self.configuration = configuration
        self.versionTuple = versionTuple
    }
}

/// Why an imported manual result cannot stand behind a matrix cell.
///
/// Every case is a refusal, and none carries a raw value: these are reasons a run reports, not
/// identifiers a release audit pools with the two gap vocabularies.
public enum NonImportableManualEvidence: Hashable, Sendable, CustomStringConvertible {
    /// The cell needs imported human evidence and the observation was automated.
    case manualEvidenceAbsent

    /// The authorization names a different matrix position.
    case authorizationIsForAnotherCell(authorized: String, required: String)

    /// The authorization record carries a rejection rather than an approval.
    case authorizationDecisionIsNotApproved(ApprovalDecision)

    /// The authorization cites the run it authorizes as its own record.
    ///
    /// An approval and the result it approves are two documents. One record standing for both is
    /// a run approving itself, which is not the human conclusion Requirement 12.13's manual
    /// portion needs.
    case authorizationCitesItsOwnResult

    /// The authorization's record and the imported result are byte-identical content.
    ///
    /// The same finding as ``authorizationCitesItsOwnResult`` reached through the digests rather
    /// than the identifiers, so renaming the artifact does not get past it.
    case authorizationSharesTheResultDigest

    public var description: String {
        switch self {
        case .manualEvidenceAbsent:
            return "this position needs an imported human result and none was supplied"
        case let .authorizationIsForAnotherCell(authorized, required):
            return "the authorization names \(authorized); this position is \(required)"
        case let .authorizationDecisionIsNotApproved(decision):
            return "the authorization records \(decision.rawValue)"
        case .authorizationCitesItsOwnResult:
            return "the authorization cites the run it authorizes as its own record"
        case .authorizationSharesTheResultDigest:
            return "the authorization and the imported result are the same content"
        }
    }
}

/// Proof that the observation behind one matrix cell may back a physical-device gate.
///
/// Requirements 12.13, 12.17, and 13.16 in one type. There is exactly one way to obtain a value:
/// ``init(observation:cell:plan:configuration:versionTuple:)``, which is internal to this module
/// and returns `nil` unless the observation was produced
///
///   1. for the cell it is being used to answer,
///   2. in ``ExecutionEnvironment/physicalIPhone``,
///   3. on the configuration the run is bound to,
///   4. on a configuration the approved plan enumerates as a candidate,
///   5. under the exact version tuple the run is bound to (Requirement 13.20), and
///   6. by a means the cell admits — automated only where automation can enable the condition,
///      and otherwise by an imported human result carrying an approved authorization for *this*
///      position.
///
/// ``MatrixCellAgreement`` can only be built from one of these, and
/// ``AccessibilityMatrixCellOutcome/exercised`` can only be built from a ``MatrixCellAgreement``.
/// So a satisfied matrix cell is not "a cell somebody marked passed": it is a value the type
/// system will not let a host observation, a simulator observation, an automated VoiceOver claim,
/// or an unauthorized manual result produce. A caller outside this module has no initialiser at
/// all, which is why no test in this repository can manufacture one.
public struct QualifyingMatrixEvidence: Hashable, Sendable {
    /// The configuration the observation was produced on.
    public let configuration: CandidateDeviceConfiguration

    /// The version tuple it ran under.
    public let versionTuple: ValidationVersionTuple

    /// The immutable record of the run.
    public let resultReference: EvidenceSource

    /// The approved authorization behind a manual cell, or `nil` for an automated one.
    ///
    /// Never `nil` for a cell whose ``MatrixAutomationSupport/requiresImportedManualEvidence`` is
    /// true: the initialiser refuses that combination.
    public let manualAuthorization: ApprovalRecord?

    /// The imported human result behind a manual cell, or `nil` for an automated one.
    public let importedResult: EvidenceSource?

    /// Always ``ExecutionEnvironment/physicalIPhone``. Retained so a recorded result states its
    /// environment rather than leaving it implied.
    public var environment: ExecutionEnvironment { .physicalIPhone }

    init?(
        observation: MatrixCellObservation,
        cell: AccessibilityMatrixCell,
        plan: DeviceValidationPlan,
        configuration: CandidateDeviceConfiguration,
        versionTuple: ValidationVersionTuple
    ) {
        guard observation.cell == cell else { return nil }
        guard observation.environment.isPhysicalDeviceEvidence else { return nil }
        guard observation.configuration == configuration else { return nil }
        guard plan.candidateConfigurations.contains(configuration) else { return nil }
        guard observation.versionTuple == versionTuple else { return nil }

        let support = cell.automationSupport
        switch observation.execution {
        case .automated:
            guard support.admitsAutomatedEvidence else { return nil }
            self.manualAuthorization = nil
            self.importedResult = nil
        case let .manual(imported):
            guard Self.refusal(for: imported, answering: cell) == nil else { return nil }
            self.manualAuthorization = imported.authorization
            self.importedResult = imported.importedResult
        }
        self.configuration = configuration
        self.versionTuple = versionTuple
        self.resultReference = observation.resultReference
    }

    /// Why one imported manual result cannot answer `cell`, or `nil` when it can.
    ///
    /// Separated from the initialiser so the runner can report the reason rather than a bare
    /// `nil`. Every check is a conjunct of "an approved manual portion", and none of them is
    /// satisfiable by anything the runner produces itself.
    static func refusal(
        for imported: ImportedManualEvidence,
        answering cell: AccessibilityMatrixCell
    ) -> NonImportableManualEvidence? {
        guard imported.cellKey == cell.matrixKey else {
            return .authorizationIsForAnotherCell(
                authorized: imported.cellKey,
                required: cell.matrixKey
            )
        }
        guard imported.authorization.isApproved else {
            return .authorizationDecisionIsNotApproved(imported.authorization.decision)
        }
        guard imported.authorization.source.artifact != imported.importedResult.artifact else {
            return .authorizationCitesItsOwnResult
        }
        guard imported.authorization.source.contentDigest != imported.importedResult.contentDigest
        else {
            return .authorizationSharesTheResultDigest
        }
        return nil
    }
}
