import DefAIkeDomain
import DefAIkeSharedTransfer
import UIKit

// The visible consent action, and the two screens that are not one.
//
// Requirement 2.2 requires a visible user-consent action before the image is handed to the main
// application, and Requirement 11.10 puts that requirement in the Extension Execution Policy. This
// file is the only place in the target that presents anything to a user, and it is built around
// three rules:
//
//   * **Nothing is worded here.** Every sentence on the consent screen is a
//     `PresentableApprovedText`, which can only be constructed from an approved catalogue key that
//     resolves to text this build ships. There is no string literal, no interpolated sentence, no
//     localization key rendered as a fallback, and no symbol standing in for a word.
//   * **Consent is a value the user produces.** The screen returns a `ShareConsentDecision`, and
//     only its `confirmed` case carries a `ConfirmedConsent` — the token that is the sole thing
//     letting `SharedTransferStore` read a byte. A dismissal produces no token, so a byte cannot be
//     read, staging cannot begin, and no session or evidence can exist (Requirement 2.4).
//   * **Failing to present is a dismissal, not an error.** `ShareConsentPresenting` documents that
//     "an implementation that cannot present the action answers cancelled", because a handoff that
//     was never consented to and one whose consent screen never appeared lead to the same place.
//
// The screen shows no image, no thumbnail, no file name, and no host application identity. The
// consent action is about scope, not about content (Requirement 9.11), and rendering a preview would
// additionally mean decoding the shared bytes in the extension.

// MARK: - The presenter

/// Presents the visible consent action and reports what the user chose.
///
/// A `Sendable` value holding the approved wording and the host the screen is presented into. The
/// host is a separate object because the composition root assembles the graph before a view
/// controller exists: the view controller attaches itself once, and a presenter with nothing
/// attached answers `cancelled` rather than waiting forever.
struct ShareConsentPresenter: ShareConsentPresenting {

    /// Approved wording for the consent action and the statement of what it covers.
    let copy: ApprovedShareExtensionCopy

    /// Where the screen is presented. Attached by the view controller after startup.
    let host: ShareConsentHost

    /// `host` has no default: constructing a `ShareConsentHost` requires the main actor, and a
    /// default value evaluated in a nonisolated context could not do that. Requiring it also makes
    /// the wiring explicit — the composition root creates the host, hands it here, and hands the
    /// same one to the view controller to attach.
    init(copy: ApprovedShareExtensionCopy, host: ShareConsentHost) {
        self.copy = copy
        self.host = host
    }

    func presentConsent(for request: ShareConsentRequest) async -> ShareConsentDecision {
        await host.present(request: request, copy: copy)
    }
}

/// The container the consent screen is presented into.
///
/// Main-actor isolated because presenting a view controller is, and a separate object from the
/// presenter because of construction order: the composition root builds the ingest coordinator, and
/// only then does the principal view controller exist to attach.
///
/// A host with nothing attached answers `cancelled`. That is not a silent failure: it is the
/// documented answer for an implementation that cannot present the action, and it means no byte is
/// read.
@MainActor
final class ShareConsentHost {

    private weak var container: UIViewController?

    init() {}

    /// Attaches the container the consent screen is presented into.
    ///
    /// Held weakly: the container owns the graph, and the graph must not own the container back.
    func attach(_ container: UIViewController) {
        self.container = container
    }

    /// Presents the consent action for `request` and waits for the user's answer.
    ///
    /// Called at most once per activation, by the ingest coordinator, and only after the activation
    /// has been shown to offer exactly one item and the pending slot has been shown to be free.
    func present(
        request: ShareConsentRequest,
        copy: ApprovedShareExtensionCopy
    ) async -> ShareConsentDecision {
        guard let container else { return .cancelled }

        return await withCheckedContinuation { continuation in
            let screen = ShareConsentViewController(
                request: request,
                copy: copy,
                clock: SystemSessionClock()
            ) { decision in
                continuation.resume(returning: decision)
            }
            container.addChild(screen)
            screen.view.frame = container.view.bounds
            screen.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.view.addSubview(screen.view)
            screen.didMove(toParent: container)
        }
    }
}

// MARK: - The consent screen

/// The screen that asks for consent and reports one decision.
///
/// It is a plain `UIViewController` rather than a SwiftUI view for one reason: `DefAIkePresentation`
/// is deliberately absent from this target's module closure, so the SwiftUI screens, the accessible
/// semantics projection, and the adaptive layout policy that the main application's views are built
/// on are not reachable here. What that costs is recorded rather than worked around — this screen
/// has no accessibility projection of its own, and the accessibility gate matrix for the Share route
/// remains release evidence this target cannot produce.
///
/// Every string comes from `ApprovedShareExtensionCopy`. The dismissal control is the system's, so
/// its word is UIKit's rather than an DefAIke string; see
/// `UnapprovedShareExtensionSurface.consentDeclineActionLabel`.
private final class ShareConsentViewController: UIViewController {

    private let request: ShareConsentRequest
    private let copy: ApprovedShareExtensionCopy
    private let clock: any SessionClock
    private let answer: (ShareConsentDecision) -> Void

    /// Whether an answer has already been delivered.
    ///
    /// One decision per activation. A second tap, or a dismissal racing a confirmation, must not
    /// resume the continuation twice.
    private var hasAnswered = false

    init(
        request: ShareConsentRequest,
        copy: ApprovedShareExtensionCopy,
        clock: any SessionClock,
        answer: @escaping (ShareConsentDecision) -> Void
    ) {
        self.request = request
        self.copy = copy
        self.clock = clock
        self.answer = answer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // Never instantiated from a storyboard: the screen exists only for one activation and is
        // constructed with the approved wording it renders.
        fatalError("ShareConsentViewController is not decodable from a nib")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let scope = UILabel()
        scope.text = copy.consentScopeStatement.text
        scope.numberOfLines = 0
        // Dynamic Type, so the statement stays readable at accessibility text sizes rather than
        // truncating. The label is the only place the scope is stated, so it must not clip.
        scope.font = .preferredFont(forTextStyle: .body)
        scope.adjustsFontForContentSizeCategory = true
        scope.textAlignment = .natural

        var configuration = UIButton.Configuration.filled()
        configuration.title = copy.consentActionLabel.text
        let confirm = UIButton(configuration: configuration)
        confirm.titleLabel?.adjustsFontForContentSizeCategory = true
        confirm.titleLabel?.numberOfLines = 0
        confirm.addAction(UIAction { [weak self] _ in self?.confirm() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [scope, confirm])
        stack.axis = .vertical
        stack.spacing = 24
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        // The system's own dismissal affordance, as a system bar-button item rather than a symbol
        // button. That choice is deliberate: a system item carries UIKit's localized title *and*
        // UIKit's accessibility label, so the control is operable by assistive technology without
        // this target inventing either. A bare symbol button would have no accessible name, and
        // giving it one would mean writing unapproved user-facing wording.
        let bar = UINavigationBar()
        let item = UINavigationItem()
        item.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismissWithoutDeciding() }
        )
        item.leftBarButtonItem?.accessibilityIdentifier = "defaike.share.consent.dismiss"
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

            // The minimum target size the design fixes for a control on the active path.
            confirm.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        // Diagnostic identifiers, not spoken labels: they carry no user-facing wording and exist so
        // a release audit and a UI test can find the controls.
        confirm.accessibilityIdentifier = "defaike.share.consent.confirm"
        scope.accessibilityIdentifier = "defaike.share.consent.scope"
    }

    /// The user performed the consent action.
    ///
    /// `ConfirmedConsent`'s initializer refuses any item count other than one, so a token for a
    /// multi-item activation is not constructible here even if the screen were somehow reached with
    /// one. A refusal reports `cancelled`: there is no consent, so nothing may be read.
    private func confirm() {
        guard !hasAnswered else { return }
        hasAnswered = true
        guard
            let consent = ConfirmedConsent(
                provider: request.provider,
                extensionExecutionPolicyID: request.extensionExecutionPolicyID,
                confirmedAt: clock.wallClockNow
            )
        else {
            finish(.cancelled)
            return
        }
        finish(.confirmed(consent))
    }

    private func dismissWithoutDeciding() {
        guard !hasAnswered else { return }
        hasAnswered = true
        finish(.cancelled)
    }

    private func finish(_ decision: ShareConsentDecision) {
        willMove(toParent: nil)
        view.removeFromSuperview()
        removeFromParent()
        answer(decision)
    }
}
