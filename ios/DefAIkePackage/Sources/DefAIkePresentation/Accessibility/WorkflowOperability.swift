import DefAIkeDomain

// Whether each required workflow can be completed with assistive technology.
//
// Requirements 12.11 and 12.12 name the same seven workflows twice, once for VoiceOver and once
// for Switch Control: ingest, handoff consent, analysis, cancellation, result review, limitation
// review, and retry. The domain already enumerates them as ``AccessibilityWorkflow``, and the
// release gate matrix already records a pass or fail per workflow, per assistive condition, per
// iOS version, per approved configuration. What has been missing is the thing in between: a
// statement of which elements each workflow actually needs, so a failure is diagnosable as "this
// control is not there" rather than as a red cell.
//
// That is what this file adds, and the honest reading of it is uncomfortable: five of the seven
// workflows cannot be completed with either assistive technology today, because the controls
// they need have no approved label and are therefore not exposed. That is a copy blockage rather
// than an accessibility one - the roles, traits, and activation areas are all in place, and
// ``AccessibleElement`` supplies them the moment a label exists - but it is a blockage, and it is
// better stated as a value an audit can read than discovered on a device.
//
// Two things this file deliberately does not do:
//
//   * **Claim a pass.** ``WorkflowOperability/isOperable`` answers a question about the element
//     set, not about a device. Requirements 12.11 and 12.12 are satisfied by a person completing
//     the workflow with VoiceOver and with Switch Control on an approved configuration, and that
//     evidence lives in the release matrix. What this can do is refuse to claim operability for a
//     workflow whose controls are absent, which is the half a host test can check.
//   * **Distinguish the two technologies by control.** Both need the same thing from this layer:
//     a control that is a real focusable element, carries a nonempty label and the button trait,
//     exposes an activation action, and presents at least a 44 by 44 point target. There is no
//     element that is reachable by one and not the other, so ``AssistiveInteraction`` has one
//     case and the difference between 12.11 and 12.12 is a difference in the evidence, not in
//     the semantics.

/// How an operable element is activated.
///
/// One case by construction. Every control in this application is a native control activated by
/// the platform's own activation action, which is what makes it reachable by VoiceOver's
/// double-tap, by Switch Control's scanner, by Full Keyboard Access, and by Voice Control at the
/// same time. A custom gesture, a drag, a swipe-only affordance, or a control that responds only
/// to a direct touch is not representable, because there is no case for one.
public enum AssistiveInteraction: String, Hashable, Sendable, CaseIterable {
    /// The platform's standard activation action on a native focusable control.
    case nativeActivationAction = "native-activation-action"
}

/// Why one workflow's element is not available.
public enum WorkflowElementStatus: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The element is exposed with complete semantics.
    case exposed

    /// The element is exposed, but a semantic Requirement 12 asks for is still missing.
    case exposedWithUnmetSemantics([UnmetSemanticRequirement])

    /// The element cannot be exposed at all, for the recorded gaps listed.
    case blockedByUnapprovedCopy([BlockedSemanticSurface])

    /// This screen does not contain the element at all.
    ///
    /// Distinct from being blocked: nothing is waiting on an approval, the element belongs to a
    /// different screen family. A workflow is evaluated against one screen, and a progress field
    /// is legitimately absent from a completed report.
    case notPresentOnThisScreen

    /// Whether the element can be used to complete the workflow.
    ///
    /// An unmet semantic does not make a control unusable: a control with a label but no purpose
    /// heading is still focusable, still announced, and still activatable. A blocked one is not
    /// on screen at all.
    public var isUsable: Bool {
        switch self {
        case .exposed, .exposedWithUnmetSemantics: true
        case .blockedByUnapprovedCopy, .notPresentOnThisScreen: false
        }
    }
}

/// Which part of the product presents one workflow.
///
/// Two cases, because two targets present workflows and only one of them is this module. The
/// distinction keeps ``WorkflowOperability/isOperable`` from answering `true` for a workflow this
/// module never shows: an empty required-element list would otherwise satisfy "every element is
/// usable" vacuously, which is exactly the shape of a gate that passes by knowing nothing.
public enum WorkflowPresenter: String, Hashable, Sendable, CaseIterable {
    /// Presented by the main application's screens, which this module owns.
    case mainApplicationScreens = "main-application-screens"

    /// Presented by the Share Extension, a separate target with its own module closure.
    ///
    /// Handoff consent is collected before any transfer is claimed, in a target that cannot
    /// reach this module at all. Its accessibility semantics are that target's, and its release
    /// evidence is recorded against the same workflow in the gate matrix.
    case shareExtension = "share-extension"
}

extension AccessibilityWorkflow {
    /// Which part of the product presents this workflow.
    ///
    /// Total switch over the domain's own vocabulary, so a new workflow has to declare where it
    /// lives.
    public var presenter: WorkflowPresenter {
        switch self {
        case .handoffConsent: .shareExtension
        case .ingest, .analysis, .cancellation, .resultReview, .limitationReview, .retry:
            .mainApplicationScreens
        }
    }
}

/// One element a workflow needs, and whether it is there.
public struct WorkflowElement: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The element the workflow needs.
    public let identity: AccessibleElementIdentity

    /// Whether it is there, and what is missing if not.
    public let status: WorkflowElementStatus

    init(identity: AccessibleElementIdentity, status: WorkflowElementStatus) {
        self.identity = identity
        self.status = status
    }
}

/// Whether one required workflow can be completed on one screen.
public struct WorkflowOperability: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The workflow this describes.
    public let workflow: AccessibilityWorkflow

    /// Every element the workflow needs, in the order it needs them.
    public let requiredElements: [WorkflowElement]

    /// How every control in this workflow is activated. Always the native action.
    public let interaction: AssistiveInteraction

    init(workflow: AccessibilityWorkflow, requiredElements: [WorkflowElement]) {
        self.workflow = workflow
        self.requiredElements = requiredElements
        self.interaction = .nativeActivationAction
    }

    /// Which part of the product presents this workflow.
    public var presenter: WorkflowPresenter { workflow.presenter }

    /// Whether every element this workflow needs is usable.
    ///
    /// Not a claim that the workflow passes its release gate. It is the necessary condition a
    /// host can check: a workflow whose controls are absent cannot be completed by anyone, with
    /// or without assistive technology.
    ///
    /// False for a workflow this module does not present, and false for an empty element list, so
    /// the answer cannot be `true` by virtue of knowing nothing.
    public var isOperable: Bool {
        presenter == .mainApplicationScreens
            && !requiredElements.isEmpty
            && requiredElements.allSatisfy(\.status.isUsable)
    }

    /// Elements this workflow needs and cannot use, in order.
    public var unusableElements: [WorkflowElement] {
        requiredElements.filter { !$0.status.isUsable }
    }

    /// Every recorded gap standing between this workflow and operability, in stable order.
    public var blockingGaps: [BlockedSemanticSurface] {
        var seen: Set<BlockedSemanticSurface> = []
        var ordered: [BlockedSemanticSurface] = []
        for element in requiredElements {
            guard case let .blockedByUnapprovedCopy(surfaces) = element.status else { continue }
            for surface in surfaces where seen.insert(surface).inserted {
                ordered.append(surface)
            }
        }
        return ordered.sorted { $0.stableKey < $1.stableKey }
    }

    /// The assistive conditions this layer answers for.
    ///
    /// VoiceOver and Switch Control only. The largest Dynamic Type size and Reduce Motion are
    /// also recorded conditions in the release matrix, but they are layout and animation
    /// properties rather than element-availability ones, and they are answered by
    /// ``AdaptiveLayoutPolicy`` instead of here.
    public static let coveredConditions: Set<AssistiveCondition> = [.voiceOver, .switchControl]
}

// MARK: - Which elements each workflow needs

extension WorkflowOperability {
    /// The elements one workflow needs, independent of any screen.
    ///
    /// A closed, total mapping over the domain's own workflow vocabulary, so adding a workflow
    /// does not compile until this states what it needs. Empty for handoff consent, whose
    /// presenter is the Share Extension - and an empty list can never read as operable, because
    /// ``isOperable`` refuses both an empty list and a workflow this module does not present.
    public static func requiredIdentities(
        for workflow: AccessibilityWorkflow
    ) -> [AccessibleElementIdentity] {
        switch workflow {
        case .ingest:
            [.imageSelectionControl]
        case .handoffConsent:
            []
        case .analysis:
            [.workProgress]
        case .cancellation:
            [.workProgress, .cancellationControl]
        case .resultReview:
            [
                .pixelEvidenceLabel,
                .pixelEvidenceExplanation,
                .provenanceLaneState,
            ]
        case .limitationReview:
            // The disclosure control is required alongside the statements it reveals. The three
            // paragraphs are now behind it, so a user who cannot operate the control cannot reach
            // them - which makes the control part of what "review the limitations" needs, not an
            // extra beside it.
            [
                .limitationsDisclosure,
                .evidenceScopeLimitation,
                .falseResultLimitation,
                .bytePreservationLimitation,
            ]
        case .retry:
            [.imageSelectionControl]
        }
    }

    /// Whether `workflow` can be completed on the screen `snapshot` describes.
    ///
    /// Reads the snapshot's own element and blocked lists, so it cannot disagree with what the
    /// screen exposes. An identity in neither list is reported as absent from this module rather
    /// than as blocked, because nothing is waiting on an approval for it.
    public static func evaluating(
        _ workflow: AccessibilityWorkflow,
        in snapshot: AccessibilitySemanticsSnapshot
    ) -> WorkflowOperability {
        WorkflowOperability(
            workflow: workflow,
            requiredElements: requiredIdentities(for: workflow).map { identity in
                WorkflowElement(
                    identity: identity,
                    status: status(of: identity, in: snapshot)
                )
            }
        )
    }

    /// Every workflow's operability on one screen, in the domain's declaration order.
    public static func evaluating(
        _ snapshot: AccessibilitySemanticsSnapshot
    ) -> [WorkflowOperability] {
        AccessibilityWorkflow.allCases.map { evaluating($0, in: snapshot) }
    }

    /// The status of one element on one screen.
    private static func status(
        of identity: AccessibleElementIdentity,
        in snapshot: AccessibilitySemanticsSnapshot
    ) -> WorkflowElementStatus {
        if let element = snapshot.element(identity) {
            return element.hasCompleteSemantics
                ? .exposed
                : .exposedWithUnmetSemantics(element.unmetSemantics)
        }
        if let blocked = snapshot.blockedElement(identity) {
            return .blockedByUnapprovedCopy(blocked.blocking)
        }
        return .notPresentOnThisScreen
    }
}
