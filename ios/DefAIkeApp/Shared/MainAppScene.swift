import DefAIkeApplication
import DefAIkeDomain
import DefAIkePresentation
import DefAIkeSharedTransfer
import Observation
import PhotosUI
import SwiftUI

// The main-actor half of the composition root: what SwiftUI observes, and how it is filled in.
//
// `DefAIkePresentation` depends on `DefAIkeDomain` and nothing else, so it cannot reach the
// Analysis Coordinator, poll a session, or cancel one. Every screen it produces is a pure
// projection of one immutable `CoordinatorSnapshot`. Filling that snapshot in is this file's
// job, and the split is the point: the projection stays reproducible from a value, and the only
// thing that can start or stop a session is the composition root.
//
// Three things this model does, and nothing more:
//
//   1. **Runs startup once.** Until it has, and if it refused, there is no `AdmittedMainApp` and
//      therefore no ingest control to activate.
//   2. **Observes one running session.** The coordinator exposes `activeIdentity()` and
//      `currentStage()` rather than a stream, so observation is a polling loop. The cadence is
//      an observation interval, not a deadline: nothing here derives a terminal outcome, a
//      timeout, or a progress fraction from elapsed time (Requirements 15.8 through 15.10).
//   3. **Applies snapshots to the projector**, which decides which observation wins.
//
// What it deliberately does not do: choose wording, synthesize a completion fraction, or turn an
// ingest-attempt refusal into an Analysis Error.

/// What the application is doing, as one main-actor observable value.
@MainActor
@Observable
final class MainAppModel {

    /// Where startup got to.
    enum Startup {
        /// Startup has not been run yet.
        case pending
        /// Startup ran and refused. There is no ingest surface in this case, at all.
        case blocked(MainAppStartupRefusal)
        /// Every gate passed. This is the only case that carries ingest.
        case ready(AdmittedMainApp)
    }

    /// Startup's outcome. Set once.
    private(set) var startup: Startup = .pending

    /// The screen the application shows, held by the presentation layer's own projector.
    ///
    /// The projector owns the ordering watermark that keeps a superseded attempt off screen, so
    /// this model never compares observations itself.
    let projector = AnalysisViewStateProjector()

    /// The completed report, assembled for the accessibility projection and the views.
    ///
    /// `nil` for every family except completed, and `nil` for a completed screen whose report
    /// could not be assembled — in which case nothing is rendered rather than a partial report.
    private(set) var screenInput: AccessibilityScreenInput?

    /// Ingest attempts that produced no Analysis Session.
    ///
    /// Recorded, never projected. Nothing reads this into a screen, and the presentation layer
    /// has no family that could show one, so an ingest-attempt failure cannot surface as one of
    /// the ten Analysis Error categories.
    private(set) var ingestAttempts: [IngestAttemptRecord] = []

    /// Committed terminal outcomes no approved input lets this build present.
    ///
    /// Recorded for the same reason: the outcome is real, and rendering it would require either
    /// a session binding Requirement 2.19 forbids or copy nobody approved.
    private(set) var unpresentableTerminals: [UnpresentableTerminalOutcome] = []

    /// Copy bindings and evidence scopes captured while their sessions were bound.
    ///
    /// The only way to reach them: a cancelled or failed terminal carries no
    /// `AnalysisSessionBinding`, so the binding has to be read from the binder during the
    /// session rather than recovered from the outcome afterwards.
    private var boundSessions: [AnalysisSessionID: BoundAnalysisSession] = [:]

    /// Whether the picker is presented. Driven by the ingest control, cleared when it closes.
    var isPickerPresented = false

    /// The items the picker binding writes. Registered, then handed to the domain as tokens.
    var pickedItems: [PhotosPickerItem] = []

    /// How often a running session is observed.
    ///
    /// An observation cadence and nothing else. No terminal decision, progress fraction, or
    /// resource verdict is derived from it, and a session that takes minutes simply keeps being
    /// observed (Requirement 15.10).
    private static let observationInterval = Duration.milliseconds(200)

    /// Runs startup once, and never again.
    ///
    /// Idempotent by state rather than by a flag: a second call finds `startup` already decided
    /// and returns, so a second scene appearance cannot run a second startup gate.
    func startIfNeeded<Composition: CapabilityComposition>(
        composition: Composition.Type,
        provisioning: MainAppReleaseProvisioning? = nil
    ) async {
        guard case .pending = startup else { return }
        switch await MainAppComposition.start(
            composition: composition,
            provisioning: provisioning
        ) {
        case let .blocked(refusal):
            startup = .blocked(refusal)
        case let .ready(app):
            startup = .ready(app)
            // The ready screen has to be projected, not assumed. `screenInput` starts `nil`
            // because no observation has happened yet, and `nil` renders nothing — so without
            // this the admitted application shows an empty screen with a working ingest surface
            // behind it and no control to reach it. Applying the idle snapshot is what turns
            // "startup passed" into a screen: it runs through the projector like every other
            // observation, so the ready screen is a projection rather than a special case.
            apply(.idle)
            // Requirement 2.3: a consented handoff is already a pending session, so it is
            // resumed at the first opportunity after the gate rather than waiting for the user
            // to choose an image. It runs after the idle projection and supersedes it, so a
            // pending handoff is not hidden behind a ready screen.
            await resumePendingShareHandoff(app)
        }
    }

    /// The admitted application, or `nil` while startup is pending or refused.
    var admitted: AdmittedMainApp? {
        guard case let .ready(app) = startup else { return nil }
        return app
    }

    // MARK: - Photos route

    /// Presents the picker.
    ///
    /// Reachable only when startup produced an `AdmittedMainApp`, because the view that offers it
    /// is only built in that case.
    func presentPicker() {
        guard admitted != nil, !projector.screen.isWorkInFlight else { return }
        isPickerPresented = true
    }

    /// Runs one ingest attempt over the complete result of one picker presentation.
    ///
    /// The count rule is the ingest coordinator's, applied to whatever the picker returned: an
    /// empty selection is a dismissal and any other count than one is refused before a byte is
    /// read (Requirements 2.7 and 2.18).
    func pickerPresentationEnded() async {
        guard let app = admitted else { return }
        let items = pickedItems
        pickedItems = []

        let selection = await app.pickerItems.register(items)
        guard !selection.isCancellation else {
            await app.pickerItems.clear()
            record(.photos(.pickerCancelled))
            return
        }

        // An ingest attempt is not an Analysis Session. The importing screen carries the route
        // and nothing else: no progress, no cancel control, and no error member.
        apply(.importing(ImportAttemptSnapshot(route: .photosPicker)))

        let outcome = await app.ingestPhotosSelection(selection)
        await app.pickerItems.clear()

        switch outcome {
        case let .sessionCreated(asset):
            await runSession(asset, in: app)
        case let .noSession(refusal):
            // No session, no evidence, and nothing retained. The screen returns to ready, whose
            // payload has no storage, so nothing from this attempt survives it.
            record(.photos(refusal))
            apply(.idle)
        }
    }

    // MARK: - Share route

    /// Claims a pending Share handoff and resumes or terminates its session.
    private func resumePendingShareHandoff(_ app: AdmittedMainApp) async {
        switch await app.resumePendingShareHandoff() {
        case let .sessionResumed(resumed):
            apply(.importing(ImportAttemptSnapshot(route: .shareExtension)))
            await runSession(resumed.asset, in: app)
        case let .sessionFailed(termination):
            // A real Analysis Session with a real error category. Requirement 2.19 requires the
            // category to be produced before Model Bundle binding, and the presentation layer's
            // session snapshot requires a session-bound approved copy binding, which such a
            // session never acquired. Recorded rather than rendered through a binding it does
            // not have.
            unpresentableTerminals.append(
                .handoffErrorBeforeBundleBinding(termination.sessionID)
            )
            reportToDeveloperConsole(
                "unpresentable-terminal",
                UnpresentableTerminalOutcome.handoffErrorBeforeBundleBinding(termination.sessionID)
            )
            apply(.idle)
        case .sessionCancelled:
            // Cancellation is its own terminal and never an error category. With no session
            // binding there is no approved copy to render it through either, so the screen
            // returns to ready.
            apply(.idle)
        case let .noSession(refusal):
            record(.share(refusal))
        }
    }

    // MARK: - Running one session

    /// Starts one session, observes it, and projects its terminal outcome.
    ///
    /// The observation loop exists because the coordinator publishes no stream. It reads recorded
    /// state only: the running attempt, the stage it is in, and the immutable snapshot the binder
    /// holds while the session is bound. It never advances the session and never decides its
    /// outcome.
    private func runSession(_ asset: ImportedEncodedAsset, in app: AdmittedMainApp) async {
        guard let task = await app.coordinator.startAnalysis(of: asset) else {
            // A session is already running. Nothing started, and the running session is
            // untouched, so there is nothing to project.
            return
        }

        let observation = Task { [weak self] in
            while !Task.isCancelled {
                await self?.observeRunningSession(app)
                try? await Task.sleep(for: Self.observationInterval)
            }
        }
        let outcome = await task.value
        observation.cancel()

        guard let completed = outcome.completed else { return }
        project(completed, in: app)
    }

    /// One observation of the running attempt.
    private func observeRunningSession(_ app: AdmittedMainApp) async {
        guard let identity = await app.coordinator.activeIdentity(),
            let stage = await app.coordinator.currentStage()
        else {
            return
        }
        // Captured while the session is bound, because a cancelled or failed terminal carries no
        // binding and the binder releases it on the session's single end path.
        if let bound = await app.binder.boundSession(identity.sessionID) {
            boundSessions[identity.sessionID] = bound
        }
        guard let bound = boundSessions[identity.sessionID],
            let copy = try? app.copyBinding(for: bound.binding)
        else {
            return
        }
        apply(
            .session(
                AnalysisSessionSnapshot(
                    identity: SessionAttemptIdentity(
                        sessionID: identity.sessionID,
                        attemptGeneration: identity.generation
                    ),
                    // Indeterminate, and honestly so: no stage reports a completed-work and
                    // total-work pair for the same measured unit to this layer, and a fraction
                    // synthesized from elapsed time would be an estimate shown as a measurement
                    // (Requirements 15.2 and 15.3).
                    phase: .working(DerivedAnalysisProgress(at: stage).state),
                    copy: copy
                )
            )
        )
    }

    /// Projects one committed terminal outcome.
    private func project(_ completed: CompletedAnalysisSession, in app: AdmittedMainApp) {
        let sessionID = completed.identity.sessionID
        // Every committed terminal, whatever it was. A failed session's screen renders nothing at
        // all in this repository — both elements it exposes address approved *error* copy, which
        // has no String Catalog value — so without this a real error terminal is indistinguishable
        // from a blank screen. Not user-facing, and absent from a Release build.
        #if DEBUG
        reportToDeveloperConsole("terminal-committed", completed.outcome)
        #endif
        defer { boundSessions.removeValue(forKey: sessionID) }

        // A completed report carries its own binding; a cancelled or failed terminal does not, so
        // the one captured during the session is used. When neither exists the terminal is real
        // and unpresentable, and it is recorded rather than rendered through another session's
        // copy.
        let binding = completed.evidenceReport?.binding ?? boundSessions[sessionID]?.binding
        guard let binding, let copy = try? app.copyBinding(for: binding) else {
            if completed.error != nil {
                unpresentableTerminals.append(.handoffErrorBeforeBundleBinding(sessionID))
                reportToDeveloperConsole(
                    "unpresentable-terminal",
                    UnpresentableTerminalOutcome.handoffErrorBeforeBundleBinding(sessionID)
                )
            } else {
                // A committed terminal with no renderable screen and no error: a cancelled
                // session, or a completed one whose copy binding could not be resolved.
                reportToDeveloperConsole("terminal-not-rendered", completed.outcome)
            }
            apply(.idle)
            return
        }

        apply(
            .session(
                AnalysisSessionSnapshot(
                    identity: SessionAttemptIdentity(
                        sessionID: sessionID,
                        attemptGeneration: completed.identity.generation
                    ),
                    phase: .ended(completed.outcome),
                    copy: copy
                )
            )
        )
    }

    // MARK: - Cancellation and recovery

    /// Requests cancellation of the running attempt.
    ///
    /// The coordinator claims the cancelled terminal in the same synchronous step, so evidence
    /// commits are disabled from that instant and a report already being built is refused when it
    /// is offered (Requirements 11.14 and 15.7).
    func requestCancellation() async {
        guard let app = admitted, let identity = await app.coordinator.activeIdentity() else {
            return
        }
        await app.requestCancellation(of: identity)
    }

    /// Returns to the ready screen so the user can select another image.
    ///
    /// Refused by the projector while work is in flight, because replacing an active screen would
    /// take its visible, enabled cancel control off screen while the work continues
    /// (Requirement 15.5). It carries nothing forward: the ready screen has no storage.
    func startNewSelection() {
        projector.startNewSelection()
        screenInput = nil
    }

    // MARK: - Applying a snapshot

    /// Applies one observation and re-derives the rendered input.
    ///
    /// A refused snapshot leaves both the screen and the rendered input exactly as they were.
    private func apply(_ snapshot: CoordinatorSnapshot) {
        guard let projection = try? projector.apply(snapshot), projection.wasAccepted else {
            return
        }
        screenInput = renderableInput(for: projection.screen, snapshot: snapshot)
    }

    /// The accessibility input for one screen, or `nil` when it cannot be assembled.
    ///
    /// Only the completed family needs approved copy, and only its assembly can refuse. A refusal
    /// yields no input rather than a partially populated one, which is the same fail-closed rule
    /// the copy and report layers already follow.
    private func renderableInput(
        for screen: AnalysisScreen,
        snapshot: CoordinatorSnapshot
    ) -> AccessibilityScreenInput? {
        guard case let .session(session) = snapshot else {
            switch screen {
            case let .ready(ready): return .ready(ready)
            case let .importing(importing): return .importing(importing)
            case .active, .completed, .cancelled, .error: return nil
            }
        }
        do {
            return try AccessibilityScreenInput(screen: screen, copy: session.copy)
        } catch {
            // Assembly refused, so nothing is rendered rather than a partial report. The refusal
            // itself is dropped by design — the presentation layer has no surface for it — which
            // makes a completed session indistinguishable from a blank screen during development.
            #if DEBUG
            reportToDeveloperConsole("screen-input-unassemblable.\(screen.family.rawValue)", error)
            #endif
            return nil
        }
    }

    private func record(_ attempt: IngestAttemptRecord) {
        ingestAttempts.append(attempt)
        reportToDeveloperConsole("ingest-attempt-refused", attempt)
    }

    /// Writes one non-projected record to the developer console, in a DEBUG build only.
    ///
    /// These two vocabularies — `IngestAttemptRecord` and `UnpresentableTerminalOutcome` — exist so
    /// a launch can be audited, and they are deliberately never projected onto a screen. That makes
    /// them invisible in a local run: an ingest attempt that produces no session returns the screen
    /// to ready, which looks identical to nothing having happened.
    ///
    /// Standard error is not a user-facing surface and a Release build compiles none of this, so
    /// nothing here puts unapproved wording on screen. It carries no image bytes, no file path, and
    /// no user filename — only the closed-vocabulary value itself.
    private func reportToDeveloperConsole(_ kind: String, _ value: some Any) {
        #if DEBUG
        DevelopmentDiagnostics.emit(kind, value)
        #endif
    }
}

// MARK: - The root view

/// The application's root view.
///
/// Two states, and the split is the structural half of "expose ingest only after all startup
/// gates pass": the ingest control is built inside the `ready` branch, where an
/// `AdmittedMainApp` exists. A blocked startup renders `StartupBlockedView`, which has no
/// picker, no ingest action, and nothing to activate.
struct MainAppRootView<Composition: CapabilityComposition>: View {
    let composition: Composition.Type

    /// The release-controlled input set, when this build carries one.
    ///
    /// `nil` in this repository, which is why startup refuses. It is a parameter rather than a
    /// global so a host or UI check can supply a complete set without touching this view.
    let provisioning: MainAppReleaseProvisioning?

    @State private var model = MainAppModel()

    init(composition: Composition.Type, provisioning: MainAppReleaseProvisioning? = nil) {
        self.composition = composition
        self.provisioning = provisioning
    }

    var body: some View {
        content
            .task {
                await model.startIfNeeded(
                    composition: composition,
                    provisioning: provisioning
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.startup {
        case .pending:
            // No ingest route, no progress, and no evidence: the fail-closed state before the
            // gate has run.
            StartupBlockedView(refusal: nil, compositionIdentifier: composition.identifier)
        case let .blocked(refusal):
            StartupBlockedView(refusal: refusal, compositionIdentifier: composition.identifier)
        case let .ready(app):
            admittedContent(app)
        }
    }

    /// The screen an admitted application shows.
    ///
    /// The ingest control lives here and only here. `AnalysisScreenView` renders whatever the
    /// accessibility projection exposes and resolves every string through the session's approved
    /// copy; an element whose text will not resolve is not rendered.
    @ViewBuilder
    private func admittedContent(_ app: AdmittedMainApp) -> some View {
        VStack(spacing: 0) {
            // Renders nothing in a Release build, and nothing in a DEBUG build whose provisioning
            // did not come from the development seam. It is above the screen rather than beside it
            // so a label cannot be read before the warning that it is not a verdict.
            DevelopmentProvisioningNotice(resolver: app.copyResolver)
            screen(app)
        }
        .photosPicker(
            isPresented: Binding(
                get: { model.isPickerPresented },
                set: { model.isPickerPresented = $0 }
            ),
            selection: Binding(
                get: { model.pickedItems },
                set: { model.pickedItems = $0 }
            ),
            // Requirement 2.6: exactly the Photos Picker and Share Extension routes, and exactly
            // one image per session. Runtime counting stays authoritative anyway — the ingest
            // coordinator refuses any other count before a session can exist.
            maxSelectionCount: PhotosRepresentationRequest.maximumSelectionCount,
            selectionBehavior: .default,
            // Deliberately every image rather than the three supported containers. Whether a
            // container is a Supported Static Image is decided against the actual bytes, so a
            // GIF or a TIFF selected here reaches the Input Validator and is refused with
            // `unsupported-media` or `unsupported-static-format` (Requirements 1.11, 1.13,
            // and 2.15). Filtering here would hide that path rather than implement it.
            matching: .images,
            // The closest a picker request comes to preserving the available encoded bytes.
            // It is a request, not a guarantee: the recorded Byte Preservation Status comes
            // from what the provider actually supplied (Requirement 2.11).
            preferredItemEncoding: .current
        )
        .onChange(of: model.isPickerPresented) { _, isPresented in
            guard !isPresented else { return }
            Task { await model.pickerPresentationEnded() }
        }
    }

    /// The projected screen, or nothing when no screen is renderable.
    @ViewBuilder
    private func screen(_ app: AdmittedMainApp) -> some View {
        Group {
            if let input = model.screenInput {
                AnalysisScreenView(
                    input: input,
                    resolver: app.copyResolver,
                    actions: AnalysisScreenActions(
                        selectImage: { model.presentPicker() },
                        requestCancellation: { Task { await model.requestCancellation() } },
                        // The four disclosure destinations are projected from
                        // `AdmittedMainApp.disclosureInput(for:scope:copy:)`. Navigating to one
                        // needs the Release Readiness Record, which no installed artifact
                        // supplies, so no path is opened rather than a screen being shown with
                        // records it does not have.
                        openDisclosurePath: { _ in }
                    )
                )
            } else {
                // Nothing renderable. Deliberately empty rather than filled with substitute
                // wording: no approved copy exists for the surfaces the projection blocked.
                Color.clear.accessibilityHidden(true)
            }
        }
    }
}
