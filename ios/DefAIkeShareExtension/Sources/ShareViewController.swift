import DefAIkeDomain
import DefAIkeSharedTransfer
import UIKit

/// Principal class for the DefAIke Share Extension.
///
/// Scope of this target, and the whole of it: count what the host offered, obtain the visible
/// consent action, stream the consented representation into protected App Group staging, publish
/// exactly one transfer atomically, show the explicit "Open DefAIke" instruction, and complete the
/// request. It performs no model inference and links no Core ML, model-bundle, image-pipeline,
/// provenance, or evidence-coordinator module — see `ShareExtensionModuleClosure`
/// (Extension Execution Policy; Requirements 2.2 through 2.7 and 11.7 through 11.13).
///
/// This file is deliberately thin. Everything that decides anything lives behind the composition
/// root, and this controller does three things:
///
///   1. Turn the host's `NSExtensionItem`s into an activation *without choosing*, so the counts
///      Requirement 2.7 refuses on survive to the refusal.
///   2. Run the startup gate, and hold whatever it returned.
///   3. Render the one outcome and complete or cancel the request.
///
/// MARK: - Why this controller cannot stage without the gate
///
/// There is no member here that reaches the transfer store, the item-provider access, or the consent
/// presenter. The only way to stage is `AdmittedShareExtension.handleActivation(items:)`, and the
/// only way to hold an `AdmittedShareExtension` is `ShareExtensionStartupOutcome.ready`, whose
/// companion `blocked` case carries a refusal and nothing else. So a blocked startup does not have a
/// disabled staging path — it has no staging path, and calling one would not compile.
///
/// MARK: - Why the request is completed and never used to launch the app
///
/// `NSExtensionContext.open` is not supported by the iOS share extension point; Apple documents
/// support for Today and iMessage extensions only. So there is no launch call here, no URL scheme, no
/// universal link, and no responder-chain workaround. `HandoffLaunchMechanism` has one case —
/// `manualUserAction` — which makes a programmatic launch unrepresentable rather than merely
/// discouraged, and the successful ending is an instruction plus `completeRequest`
/// (design, fixed decision 4).
final class ShareViewController: UIViewController {

    /// Why the extension cancelled a request without staging anything.
    ///
    /// A machine-readable code on an `NSError`, and deliberately nothing else: the error carries no
    /// `NSLocalizedDescriptionKey`, because a host may surface a localized description to the user
    /// and the closed Approved Verdict Copy vocabulary defines no wording for a handoff refusal
    /// (`UnapprovedShareExtensionSurface.handoffRefusalStatement`). A sentence here would be
    /// unapproved user-facing language routed through an error object.
    enum CancellationCode: Int {
        /// A mandatory startup gate refused, so no handoff surface was ever exposed.
        case startupRefused = 1

        /// The activation did not offer exactly one item, checked at runtime.
        case activationRefused = 2

        /// The user declined or dismissed the visible consent action.
        case consentNotGiven = 3

        /// Staging began and did not reach publication, so no session exists.
        case stagingIncomplete = 4
    }

    /// Error domain for the codes above. A build constant, never user content.
    static let errorDomain = "dev.defaike.share-extension"

    /// The startup outcome, once the gate has run.
    ///
    /// `nil` before it has. There is no third state and no default that would let staging proceed
    /// while the gate is still running.
    private var startup: ShareExtensionStartupOutcome?

    /// Whether a request has already been completed or cancelled.
    ///
    /// One ending per activation. A second tap, or a dismissal racing a completion, must not call
    /// back into the host twice.
    private var hasEnded = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // Read the offered items before anything else and hold them, so the activation is exactly
        // what the host handed over. Nothing is filtered, sorted, or truncated here: the activation
        // rule limits what a share sheet presents, and runtime counting is authoritative
        // (Requirements 2.6 and 2.7).
        let offered = Self.offeredItems(in: extensionContext)

        Task { [weak self] in
            await self?.begin(with: offered)
        }
    }

    // MARK: - Reading the activation

    /// Every extension item the host offered, mapped without choosing.
    ///
    /// One `NSExtensionItem` becomes one `OfferedExtensionItem`, carrying *all* of that item's
    /// attachments. Both counts therefore reach `ShareActivation.resolvedCandidate` intact, and each
    /// one has its own refusal:
    ///
    ///   * two extension items become two providers, refused as `providerCountUnsupported(2)`;
    ///   * one extension item with three attachments becomes one provider reporting three, refused
    ///     as `itemCountUnsupported(3)`;
    ///   * no items at all is refused as `noProviderOffered`.
    ///
    /// No branch here clamps a count, drops a provider to make a total come out at one, or takes
    /// `first`. That is what keeps one-item enforcement a runtime decision rather than a property
    /// inherited from the Info.plist activation rule.
    private static func offeredItems(in context: NSExtensionContext?) -> [OfferedExtensionItem] {
        guard let context else { return [] }
        return context.inputItems.compactMap { input in
            guard let item = input as? NSExtensionItem else {
                // Not an extension item. It offers no attachment this route can count, so it
                // contributes nothing rather than being counted as one.
                return nil
            }
            let attachments = item.attachments ?? []
            return OfferedExtensionItem(
                attachments: attachments,
                // The type the sole attachment declares first, recorded for the ticket's diagnostic
                // hint and never trusted for classification. Read only when there is exactly one
                // attachment: a hint taken from one of several attachments would describe an item
                // this activation is about to refuse.
                contentTypeHint: attachments.count == 1
                    ? attachments[0].registeredTypeIdentifiers.first.flatMap(ContentTypeHint.init)
                    : nil
            )
        }
    }

    // MARK: - Startup and one activation

    /// Runs the startup gate, then either refuses or handles the activation.
    ///
    /// `provisioning` is `nil` in this repository, so the gate's first step reports the
    /// release-controlled inputs that are not installed and the extension refuses without staging
    /// anything. That is the intended behaviour for an unprovisioned build, and it is not a build
    /// stage placeholder: the graph below is complete, and what is missing is the signed input set a
    /// distributed build carries (`UnprovisionedExtensionReleaseInput`).
    private func begin(with offered: [OfferedExtensionItem]) async {
        let outcome = await ShareExtensionComposition.start()
        startup = outcome

        switch outcome {
        case let .blocked(refusal):
            // No handoff surface exists, so there is nothing to stage and no session to end. The
            // screen stays until the user dismisses it: returning control immediately would make the
            // refusal unobservable, and there is no approved sentence to replace it with.
            present(blocked: refusal.causeToken, endWith: .startupRefused)

        case let .ready(admitted):
            // The consent screen is presented into this controller. Attaching before the activation
            // runs is what lets the coordinator's ordering rule hold: the consent action appears
            // after the counts are checked and before any byte is read.
            admitted.consentHost.attach(self)
            await handle(offered, with: admitted)
        }
    }

    /// Runs one activation and renders its single outcome.
    private func handle(
        _ offered: [OfferedExtensionItem],
        with admitted: AdmittedShareExtension
    ) async {
        switch await admitted.handleActivation(items: offered) {
        case let .published(receipt):
            // One transfer is published and exactly one pending Analysis Session exists, under the
            // candidate identifier the extension allocated while staging. The user has to open
            // DefAIke; nothing here can do it for them (Requirements 2.3 and 11.12).
            present(instruction: HandoffInstructionViewController(published: receipt) { [weak self] in
                self?.complete()
            })

        case let .pendingHandoff(notice):
            // A handoff the user already consented to is still waiting. It is never replaced, and
            // nothing new was staged.
            present(instruction: HandoffInstructionViewController(pending: notice) { [weak self] in
                self?.complete()
            })

        case let .activationRefused(refusal):
            present(blocked: refusal.causeToken, endWith: .activationRefused)

        case .declined, .cancelled:
            // Requirement 2.4: no ready transfer, no Analysis Session, no main-application
            // analysis, and no evidence verdict. Cancellation is not an error category, so nothing
            // here presents one (Requirement 11.17) — and the user has just dismissed the consent
            // screen, so control returns to the host immediately rather than through a second
            // screen they would also have to dismiss.
            cancel(.consentNotGiven)

        case let .failed(failure):
            // Staging began and did not reach publication. The transfer store already removed
            // everything the attempt created, so the container holds nothing for it.
            present(blocked: failure.causeToken, endWith: .stagingIncomplete)
        }
    }

    // MARK: - Presenting

    private func present(blocked cause: String, endWith code: CancellationCode) {
        install(
            HandoffBlockedViewController(cause: cause) { [weak self] in
                self?.cancel(code)
            }
        )
    }

    private func present(instruction: HandoffInstructionViewController) {
        install(instruction)
    }

    private func install(_ child: UIViewController) {
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }

    // MARK: - Ending the request

    /// Returns control to the host after a handoff the user acknowledged.
    private func complete() {
        guard !hasEnded else { return }
        hasEnded = true
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Returns control to the host with a machine-readable code and no user-facing string.
    private func cancel(_ code: CancellationCode) {
        guard !hasEnded else { return }
        hasEnded = true
        extensionContext?.cancelRequest(
            withError: NSError(
                domain: Self.errorDomain,
                code: code.rawValue,
                // Empty on purpose. See `CancellationCode`: a host may show a localized description,
                // and no approved wording for a handoff refusal exists.
                userInfo: [:]
            )
        )
    }
}
