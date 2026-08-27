import DefAIkeSharedTransfer
import UIKit

// What the extension shows after an activation ends, and what it deliberately does not.
//
// Two screens, split by one question: is there approved wording for this outcome?
//
//   * A **published** or **pending** handoff has approved wording, because the startup gate refused
//     to expose the handoff surface at all unless every surface on that path resolved to renderable
//     approved text. So `HandoffInstructionViewController` renders it.
//   * Every other ending — a refused startup, a refused activation, a decline, a cancellation, a
//     resource breach, an incomplete staging — has none. `HandoffBlockedViewController` therefore
//     renders *no text at all* and carries its cause in a stable accessibility identifier, exactly
//     as the main application's `StartupBlockedView` does for a refused startup.
//
// Rendering nothing is the honest option, not a shortcut. The closed Approved Verdict Copy
// vocabulary has no surface for a handoff refusal — see
// `UnapprovedShareExtensionSurface.handoffRefusalStatement` — so a sentence written here would be
// unapproved user-facing language, and a localization key rendered here would be a raw key on
// screen. Closing that gap is a release-artifact change: extend `VerdictCopySurface`, approve the
// wording, ship the value. It is not a change to this file.

/// The screen shown when no approved wording exists for what happened.
///
/// It presents no ingest route, no progress, no evidence, and no Analysis Error category, because
/// none of those exists: a refused startup or a refused activation staged nothing and created no
/// Analysis Session. This is not a disabled version of the consent screen — it is a different
/// screen, reachable only where no `AdmittedShareExtension` or no published ticket exists, so there
/// is nothing here for a consent action to be wired to.
///
/// The cause travels in the accessibility identifier, where a release audit and a UI test can read
/// it and a user is not shown a sentence nobody approved. The identifier carries no session
/// identifier, no path, no host application identity, and no image-derived value.
final class HandoffBlockedViewController: UIViewController {

    /// A stable, non-user-facing token naming the state and its cause.
    private let cause: String

    /// Called when the user dismisses the screen.
    ///
    /// The screen does not dismiss itself on a timer and the request is not cancelled behind the
    /// user's back. Returning control the instant this appears would make the state unobservable to
    /// a release audit and to a UI test, and the main application takes the same approach: its
    /// `StartupBlockedView` is a screen that stays, not a flash.
    private let dismissed: () -> Void

    init(cause: String, dismissed: @escaping () -> Void) {
        self.cause = cause
        self.dismissed = dismissed
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HandoffBlockedViewController is not decodable from a nib")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // No text, no symbol, and no color-only signal. An empty accessible element with a stable
        // identifier is the honest rendering of "nothing approved may be said here".
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "defaike.share.blocked.\(cause)"

        // The system's own dismissal affordance, so the user is not trapped and so the word on the
        // control is UIKit's rather than an unapproved DefAIke string. A system bar-button item
        // carries UIKit's accessibility label as well, which a bare symbol button would not.
        let bar = UINavigationBar()
        let item = UINavigationItem()
        item.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismissed() }
        )
        item.leftBarButtonItem?.accessibilityIdentifier = "defaike.share.blocked.dismiss"
        bar.items = [item]
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}

/// The screen shown when a handoff committed, or when one is already pending.
///
/// Every sentence is a `PresentableApprovedText`, which cannot be constructed without an approved
/// catalogue key that resolves to text this build ships. There is no literal, no interpolation, and
/// no fallback.
///
/// It shows the manual instruction because nothing else moves the handoff forward: the share
/// extension point cannot open the containing application on iOS, so the user has to. The screen
/// makes no claim that DefAIke was launched and offers no control that would try to launch it.
final class HandoffInstructionViewController: UIViewController {

    private let statements: [PresentableApprovedText]
    private let identifier: String
    private let done: () -> Void

    /// The screen for a published handoff.
    ///
    /// One statement: open DefAIke.
    convenience init(published receipt: ReadyHandoffReceipt, done: @escaping () -> Void) {
        self.init(
            statements: [receipt.instruction],
            identifier: "defaike.share.published",
            done: done
        )
    }

    /// The screen for a handoff that is already pending.
    ///
    /// Two statements: the recovery instruction, then the same manual instruction, because opening
    /// DefAIke is what resolves it. The pending handoff is never replaced (Requirement 11.9's
    /// bound policy fixes the recovery behaviour, and the schema rejects silent replacement).
    convenience init(pending notice: PendingHandoffNotice, done: @escaping () -> Void) {
        self.init(
            statements: [notice.recovery, notice.instruction],
            identifier: "defaike.share.pending",
            done: done
        )
    }

    private init(
        statements: [PresentableApprovedText],
        identifier: String,
        done: @escaping () -> Void
    ) {
        self.statements = statements
        self.identifier = identifier
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HandoffInstructionViewController is not decodable from a nib")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let stack = UIStackView(
            arrangedSubviews: statements.enumerated().map { index, statement in
                let label = UILabel()
                label.text = statement.text
                label.numberOfLines = 0
                label.font = .preferredFont(forTextStyle: .body)
                label.adjustsFontForContentSizeCategory = true
                label.textAlignment = .natural
                label.accessibilityIdentifier = "\(identifier).statement.\(index)"
                return label
            }
        )
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        view.accessibilityIdentifier = identifier

        // The system's own completion affordance, as a system bar-button item: UIKit supplies both
        // its title and its accessibility label, so the control is operable by assistive technology
        // without this target inventing user-facing wording.
        let bar = UINavigationBar()
        let item = UINavigationItem()
        item.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.done() }
        )
        item.rightBarButtonItem?.accessibilityIdentifier = "\(identifier).done"
        bar.items = [item]
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)

        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}

// MARK: - Cause tokens

extension ShareExtensionStartupRefusal {

    /// One stable token per refusal cause.
    ///
    /// Total over the vocabulary, with no `default`, so a new refusal cause cannot be added without
    /// naming what the blocked screen reports for it. Not localized and not spoken: it is diagnostic
    /// surface for a UI test and a release audit.
    var causeToken: String {
        switch self {
        case .releaseInputsUnprovisioned: "release-inputs-unprovisioned"
        case .identityUnobservable: "identity-unobservable"
        case .operatingSystemBelowMinimum: "operating-system-below-minimum"
        case .artifactUnavailable: "artifact-unavailable"
        case .unapprovedArtifact: "unapproved-artifact"
        case .identityMismatch: "identity-mismatch"
        case .allowlistApprovesNoConfiguration: "allowlist-approves-no-configuration"
        case .configurationNotAllowlisted: "configuration-not-allowlisted"
        case .unsatisfiedDeviceGates: "unsatisfied-device-gates"
        case .handoffCopyUnapproved: "handoff-copy-unapproved"
        case .appGroupContainerUnresolvable: "app-group-container-unresolvable"
        case .transferStoreNotConfigurable: "transfer-store-not-configurable"
        case .dataProtectionUnenforced: "data-protection-unenforced"
        case .startupCleanupFailed: "startup-cleanup-failed"
        }
    }
}

extension ShareActivationRefusal {

    /// One stable token per activation refusal.
    ///
    /// The counts travel with the token, because "how many did the host actually offer" is the whole
    /// finding: the activation rule asked for one, and runtime counting is what decided.
    var causeToken: String {
        switch self {
        case .noProviderOffered: "activation-no-provider"
        case let .providerCountUnsupported(count): "activation-provider-count-\(count)"
        case let .itemCountUnsupported(count): "activation-item-count-\(count)"
        }
    }
}

extension ShareStagingFailure {

    /// One stable token per staging failure.
    ///
    /// Total, with no `default`. `cancelled` is deliberately absent from the blocked screen's use of
    /// this: a cancellation is reported as a cancellation, never as a failure category
    /// (Requirement 11.17).
    var causeToken: String {
        switch self {
        case let .consentNotBound(defect): "staging-consent-\(defect.rawValue)"
        case let .activationNotOneItem(count): "staging-item-count-\(count)"
        case let .resourceBreach(metric): "staging-resource-\(metric.rawValue)"
        case .noRepresentationObtained: "staging-no-representation"
        case .pendingHandoffExists: "staging-pending-handoff"
        case .stagingIncomplete: "staging-incomplete"
        case .cancelled: "staging-cancelled"
        }
    }
}
