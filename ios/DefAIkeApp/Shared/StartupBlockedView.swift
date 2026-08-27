import Foundation
import SwiftUI

/// What the application shows when the startup gate has not passed.
///
/// It presents no ingest route, no progress, no evidence, and no Analysis Error category,
/// because none of those exists: a refused gate means no Analysis Session ever began. This view
/// is not a disabled version of the analysis screen — it is a different screen, built in the one
/// branch of `MainAppRootView` where no `AdmittedMainApp` exists, so there is nothing here for an
/// ingest action to be wired to.
///
/// It shows no user-facing sentence about *why*. Approved Verdict Copy has no surface for a
/// startup refusal, the surface vocabulary is closed, and inventing wording here would put
/// unapproved user-facing language on screen — which is exactly what the approved-copy binding
/// exists to prevent (Requirement 8.1). The refusal is carried in the accessibility identifier
/// instead, where a release audit and a UI test can read it and a user is not shown a sentence
/// nobody approved.
///
/// Closing that gap is a release-artifact change: extend the approved surface vocabulary, approve
/// the wording, and add the String Catalog value. It is not a change to this file.
struct StartupBlockedView: View {
    /// Why startup refused, or `nil` before the gate has run.
    let refusal: MainAppStartupRefusal?

    /// The compiled composition identifier, so a build under test is identifiable.
    let compositionIdentifier: String

    var body: some View {
        // No text, no symbol, and no color-only signal. An empty accessible element with a
        // stable identifier is the honest rendering of "nothing approved may be said here".
        Color.clear
            .accessibilityElement()
            .accessibilityIdentifier(identifier)
            .onAppear { reportToDeveloperConsole() }
    }

    /// Writes the refusal's own description to the developer console, in a DEBUG build only.
    ///
    /// This view's stated job is to carry the refusal where a release audit and a UI test can read
    /// it rather than showing a user a sentence nobody approved. The accessibility identifier does
    /// that for a UI test, but it carries one token per cause and drops the detail inside a
    /// `PreflightFailure` — which is the part a developer needs to know *which* comparison
    /// refused.
    ///
    /// So a DEBUG build also writes `MainAppStartupRefusal.description`, which every refusal case
    /// already provides for exactly this purpose. It is not user-facing text and it is not on
    /// screen: standard error is not a surface a user sees, and a Release build compiles no part
    /// of this. Nothing here is localized, and nothing here is approved copy.
    private func reportToDeveloperConsole() {
        #if DEBUG
        guard let refusal else { return }
        DevelopmentDiagnostics.emit("startup-refused.\(compositionIdentifier)", refusal)
        #endif
    }

    /// A stable, non-user-facing identifier naming the state and its cause.
    ///
    /// Not localized and not spoken: it is diagnostic surface for a UI test and a release audit.
    /// It carries no session identifier, no path, and no image-derived value.
    private var identifier: String {
        guard let refusal else {
            return "defaike.startup.pending.\(compositionIdentifier)"
        }
        return "defaike.startup.blocked.\(compositionIdentifier).\(cause(of: refusal))"
    }

    /// One stable token per refusal cause.
    ///
    /// Total over `MainAppStartupRefusal`, with no `default`, so a new refusal cause cannot be
    /// added without naming what this screen reports for it.
    private func cause(of refusal: MainAppStartupRefusal) -> String {
        switch refusal {
        case .releaseInputsUnprovisioned: "release-inputs-unprovisioned"
        case .deviceIdentityUnobservable: "device-identity-unobservable"
        // One token per inconsistency, not one for all three, so a release audit reading the
        // identifier can tell an incoherent capability set from a refused adapter-version pin.
        case .compositionNotRunnable(.compositionIdentifierNotCanonical):
            "composition-identifier-not-canonical"
        case .compositionNotRunnable(.capabilitiesAndVersionsIncoherent):
            "composition-not-runnable"
        case .compositionNotRunnable(.attestedCapabilityNotCompiled):
            "attested-capability-not-compiled"
        case .compositionNotRunnable(.linkedImplementationVersionMismatch):
            "linked-implementation-version-mismatch"
        case .appGroupContainerUnresolvable: "app-group-container-unresolvable"
        case .preflight: "preflight-refused"
        case .sessionStoreNotConfigurable: "session-store-not-configurable"
        case .calibrationPolicyNotActivatable: "calibration-policy-not-activatable"
        case .resourceControllerNotBindable: "resource-controller-not-bindable"
        case .approvedCopyUnreadable: "approved-copy-unreadable"
        }
    }
}
