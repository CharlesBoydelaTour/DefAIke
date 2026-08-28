import DefAIkeApplication
import DefAIkeCoreML
import DefAIkeDomain
import DefAIkeImagePipeline
import DefAIkeModelBundle
import DefAIkePresentation
import DefAIkeProvenanceAPI
import DefAIkeSharedTransfer
import Foundation

// The main application's composition root.
//
// One place assembles the whole graph, and it is the only place that may: preflight, startup
// cleanup, the Model Bundle manager, the Photos route, the Share claim, the image pipeline,
// pixel analysis, the conditional provenance lane, the session coordinator, and the
// presentation projections. Every library module here already refuses to reach the ones it
// must not; what did not exist until this file is the wiring, and the order it happens in.
//
// MARK: - Why ingest cannot be reached early
//
// "Expose ingest only after all startup gates pass" is made structural three times over, and
// none of the three is a flag a later change could forget to check:
//
//   1. **`ReleaseAdmission` is unforgeable.** Its initializer is `fileprivate` to
//      `StartupPreflight.swift`, so the only way to hold one is to have run all seven gates
//      on this device, in this build, against these exact artifact versions.
//   2. **The ingest surface requires one.** `AdmittedMainApp` has a `private` initializer whose
//      only call site is inside this file, after `run(...)` returned. `AnalysisSessionBinder`
//      and `BoundAnalysisSession.snapshot(...)` separately require the same admission, so even
//      a hand-built coordinator could not bind a session without one.
//   3. **A blocked startup has no ingest value at all.** `MainAppStartupOutcome` is an enum:
//      its blocked case carries a refusal and nothing else. There is no `AdmittedMainApp` to
//      call a method on, so ingest on a blocked app is a compile error rather than a disabled
//      control.
//
// MARK: - Why a startup or ingest-attempt failure is not an Analysis Error
//
// The ten `AnalysisError` categories are closed, and both of these sit outside them by
// construction rather than by convention:
//
//   * A startup refusal is `MainAppStartupRefusal`, which has no case carrying an
//     `AnalysisError` and no conversion to one. A failed gate means no session ever began, so
//     there is no stage, no session identifier, and no evidence to report. `PreflightFailure`
//     is already documented as deliberately not convertible.
//   * An ingest-attempt refusal is `IngestAttemptRecord`, which wraps the application layer's
//     own `PhotosIngestRefusal` and `ShareHandoffRefusal`. Neither reaches a
//     `CoordinatorSnapshot`: the snapshot vocabulary has `idle`, `importing`, and `session`,
//     `ImportAttemptSnapshot` has no error member, and a refused attempt returns the screen to
//     `idle`, whose payload has no storage. `PhotosIngestRefusal.noLocalRepresentation` does
//     carry an `AnalysisError` for audit, and nothing here projects it.
//
// MARK: - What one immutable capability composition drives
//
// `CapabilityComposition` (this target's protocol) is a compile-time fact per build output.
// The one shipping composition compiles both evidence capabilities and links the Content
// Credential validator. The composition contributes its identifier, its capability set, and
// whether a validator is linked, and the preflight compares all three against the signed
// manifest in both directions.
//
// The provenance lane is then resolved from the composition's own analyzer factory *and* its
// linkage fact, because those two answer different questions. Linkage says whether a validator
// could exist in these bytes; the factory says whether an approved decision lets one be built.
// A build that links the adapter and still supplies no analyzer is the state this app is in
// today, and it is reported as `validatorEnablementUnapproved` rather than as an uncompiled
// validator, which would be a false statement about the module graph.

// MARK: - Startup refusals

/// Why the main application did not expose ingest.
///
/// Deliberately not an `AnalysisError`, deliberately not convertible to one, and deliberately
/// carrying no session identifier, stage, or evidence: a refused startup produced no Analysis
/// Session, so there is nothing for an evidence outcome to describe (Requirement 1.3 and the
/// design's error taxonomy).
///
/// Every case names one cause. There is no `unknown`, and no case a caller can relax.
enum MainAppStartupRefusal: Sendable, CustomStringConvertible {

    /// One or more release-controlled inputs are not installed in this build.
    case releaseInputsUnprovisioned([UnprovisionedReleaseInput])

    /// The running build's own identity could not be observed.
    case deviceIdentityUnobservable(ObservedDeviceIdentity.UnobservableIdentity)

    /// The compiled composition is not a runnable build, and which shape it had.
    ///
    /// Three causes, all of them shapes a real module graph plus a real provisioned input set
    /// cannot have, so none is a gate decision: no pixel analysis, an implementation-version
    /// list that does not name each compiled capability exactly once, or a provisioned version
    /// that contradicts what a linked adapter reports about itself. The last one is the
    /// adapter-version pin, and it is refused here — before the signed-manifest comparison —
    /// because the manifest cannot see inside the binary.
    case compositionNotRunnable(CompositionInconsistency)

    /// The registered App Group container could not be resolved.
    ///
    /// Fail-closed for the reason `SessionStorageRoots` gives: an unresolvable container means
    /// the App Group is not registered for this build, and falling back to a process-private
    /// directory would leave session material somewhere this lifecycle does not own.
    case appGroupContainerUnresolvable(AppGroupContainer.ResolutionError)

    /// A mandatory startup gate refused, carrying the gate's own finding unchanged.
    case preflight(PreflightFailure)

    /// The bound Resource Budget defines no approved temporary-storage capacity, so no
    /// session store can be configured against it.
    case sessionStoreNotConfigurable(ProtectedEphemeralFileStore.ConfigurationError)

    /// The session-bound Calibration Policy could not be activated for the verified bundle.
    ///
    /// A policy that does not activate keeps the bundle unusable rather than producing a
    /// user-facing verdict, so it blocks ingest here instead of becoming a
    /// `calibration-input-error` (Requirement 5.13).
    case calibrationPolicyNotActivatable

    /// The main-application Resource Controller could not be bound to this target's budget.
    case resourceControllerNotBindable

    /// The shipped English String Catalog could not be read.
    ///
    /// Approved wording is resolved through it, and a screen that cannot resolve its text is
    /// left unrendered rather than shown with a localization key or an invented sentence.
    case approvedCopyUnreadable(StringCatalogError)

    var description: String {
        switch self {
        case let .releaseInputsUnprovisioned(inputs):
            return "release inputs are not provisioned: \(inputs.map(\.rawValue).sorted())"
        case let .deviceIdentityUnobservable(field):
            return "the running build's \(field.rawValue) could not be observed"
        case let .compositionNotRunnable(inconsistency):
            return "the compiled capability composition is not a runnable build: \(inconsistency)"
        case let .appGroupContainerUnresolvable(error):
            return "the registered App Group container could not be resolved: \(error)"
        case let .preflight(failure):
            return "a mandatory startup gate refused: \(failure)"
        case let .sessionStoreNotConfigurable(error):
            return "no approved temporary-storage capacity is available: \(error)"
        case .calibrationPolicyNotActivatable:
            return "the session-bound Calibration Policy could not be activated"
        case .resourceControllerNotBindable:
            return "the main-application Resource Budget could not be bound"
        case let .approvedCopyUnreadable(error):
            return "the approved English copy catalog could not be read: \(error)"
        }
    }
}

/// What startup produced.
///
/// Two cases, and only one of them carries an ingest surface. That is the whole of "expose
/// ingest only after all startup gates pass": there is no third case, and the blocked case has
/// no member an ingest call could be made through.
enum MainAppStartupOutcome: Sendable {
    /// Ingest was never exposed, and why.
    case blocked(MainAppStartupRefusal)

    /// Every gate passed. This value is the only ingest surface there is.
    case ready(AdmittedMainApp)

    /// The admitted application, or `nil` when startup was refused.
    var admitted: AdmittedMainApp? {
        guard case let .ready(app) = self else { return nil }
        return app
    }

    /// Why startup was refused, or `nil` when it was not.
    var refusal: MainAppStartupRefusal? {
        guard case let .blocked(refusal) = self else { return nil }
        return refusal
    }
}

// MARK: - Non-evidence ingest records

/// An ingest attempt that created no Analysis Session.
///
/// Held so a launch can be audited, and deliberately never projected. The presentation layer
/// has no way to render one: `CoordinatorSnapshot.importing` carries only a route, and a
/// refused attempt returns the screen to `idle`, whose payload has no storage at all. So an
/// ingest-attempt failure cannot appear as one of the ten Analysis Error categories, and the
/// `AnalysisError` that `PhotosIngestRefusal.noLocalRepresentation` carries for audit stays
/// inside this value.
enum IngestAttemptRecord: Hashable, Sendable {
    /// A Photos attempt that produced no session.
    case photos(PhotosIngestRefusal)

    /// A Share activation with nothing claimable pending.
    case share(ShareHandoffRefusal)
}

/// A committed terminal outcome no approved input lets this build present.
///
/// One member today, and it is a recorded blocker rather than a behaviour: a Share handoff that
/// fails verification terminates its session with `handoff-error` *before* Model Bundle
/// binding, which Requirement 2.19 requires. But `AnalysisSessionSnapshot` needs an
/// `ApprovedCopyBinding`, and `ApprovedCopyBinding.bind(catalog:session:capabilities:fusionRule:)`
/// needs an `AnalysisSessionBinding` — which that session, by requirement, never acquired.
///
/// So the terminal is real and unpresentable through the current presentation input model.
/// Recording it keeps the gap auditable instead of resolving it by binding a session to a
/// bundle Requirement 2.19 forbids it from binding, or by inventing copy for it.
enum UnpresentableTerminalOutcome: Hashable, Sendable {
    /// A `handoff-error` terminal with no session binding to resolve approved copy through.
    case handoffErrorBeforeBundleBinding(AnalysisSessionID)
}

// MARK: - The admitted application

/// The assembled graph, and the only ingest surface in the main application.
///
/// Reachable only from `MainAppComposition.start(...)`, and only after every startup gate
/// passed: the initializer is `private` and takes the `ReleaseAdmission` that proves it.
///
/// `Sendable` and immutable. The only mutable state in the graph is inside the actors it holds
/// — the coordinator, the binder, the stores, the governor — each of which owns its own.
final class AdmittedMainApp: Sendable {

    /// Permission to expose ingest, and everything a session binds.
    let admission: ReleaseAdmission

    /// Turns one picker presentation into at most one Analysis Session.
    private let photos: PhotosIngestCoordinator

    /// Resumes at most one pending Share handoff per activation.
    private let share: ShareHandoffIngestCoordinator

    /// Runs one Analysis Session at a time and commits exactly one terminal for it.
    let coordinator: AnalysisCoordinator

    /// Binds each accepted input to the active verified Model Bundle exactly once.
    ///
    /// Held here as well as inside the coordinator for one reason: the presentation layer needs
    /// the session's immutable `AnalysisSessionBinding` to resolve approved copy, and the only
    /// terminal outcome that carries one is a completed report. So the binding is read from the
    /// binder *while* the session is bound, and cached by whoever is observing. See
    /// `MainAppModel` and `UnpresentableTerminalOutcome`.
    let binder: AnalysisSessionBinder

    /// The registry one picker presentation writes its selection into.
    let pickerItems: PhotosPickerItemRegistry

    /// The one Resource Controller for this target, bound to this target's signed budget.
    ///
    /// Owned by the graph rather than constructed per stage, so a reservation can never be
    /// checked against the other target's budget (Requirement 11.1). The validator and the
    /// preprocessor receive the bound `ResourceBudget` directly, so a `resource-limit` reaches
    /// the coordinator as an ordinary port fault from the stage that raised it.
    let resources: ResourceController

    /// The provenance source lane of this composition, resolved once at startup.
    let provenance: ProvenanceLaneProvider

    /// The validated Evidence Fusion Rule, or the recorded reason there is none.
    let fusion: OptionalFusion

    /// The resolver supplying approved English text to the views.
    let copyResolver: AccessibleTextResolver

    /// The record the four disclosure destinations quote.
    private let release: ReleaseReadinessRecord

    /// `fileprivate` rather than `private`, because the only call site is
    /// `MainAppComposition.assemble(...)` a few hundred lines below and Swift scopes `private`
    /// to the enclosing type. The guarantee is unchanged: this file is the composition root, so
    /// no other file can construct an ingest surface, and the required `ReleaseAdmission` cannot
    /// be forged anywhere.
    fileprivate init(
        admission: ReleaseAdmission,
        photos: PhotosIngestCoordinator,
        share: ShareHandoffIngestCoordinator,
        coordinator: AnalysisCoordinator,
        binder: AnalysisSessionBinder,
        pickerItems: PhotosPickerItemRegistry,
        resources: ResourceController,
        provenance: ProvenanceLaneProvider,
        fusion: OptionalFusion,
        copyResolver: AccessibleTextResolver,
        release: ReleaseReadinessRecord
    ) {
        self.admission = admission
        self.photos = photos
        self.share = share
        self.coordinator = coordinator
        self.binder = binder
        self.pickerItems = pickerItems
        self.resources = resources
        self.provenance = provenance
        self.fusion = fusion
        self.copyResolver = copyResolver
        self.release = release
    }

    // MARK: Ingest

    /// Runs one Photos ingest attempt over the complete result of one picker presentation.
    ///
    /// The route's rules are the coordinator's: an empty selection is a dismissal, any count
    /// other than one is refused before a byte is read, and a session exists only once exactly
    /// one local representation has been retained (Requirements 2.1, 2.5, 2.7, 2.18, and 9.4).
    func ingestPhotosSelection(_ selection: PhotosPickerSelection) async -> PhotosIngestOutcome {
        await photos.ingest(selection)
    }

    /// Claims the pending Share handoff, if there is one, and resumes or terminates its session.
    ///
    /// The claim reverifies the byte count, digest, and Byte Preservation Status and binds the
    /// Model Bundle only afterwards, so an unverified handoff cannot reach validation,
    /// provenance, or inference (Requirements 2.3 and 2.19).
    func resumePendingShareHandoff() async -> ShareHandoffIngestOutcome {
        await share.resumePendingHandoff(context: admission.context)
    }

    /// Runs one Analysis Session over an accepted ingest.
    ///
    /// Reachable only with an `ImportedEncodedAsset`, which only the two ingest coordinators
    /// produce. There is no member that starts a session from a path, a selection, or a bare
    /// session identifier.
    func analyze(_ asset: ImportedEncodedAsset) async -> AnalysisSessionOutcome {
        await coordinator.analyze(asset)
    }

    /// Requests cancellation of one running attempt.
    func requestCancellation(of identity: AnalysisSessionIdentity) async {
        await coordinator.requestCancellation(for: identity)
    }

    // MARK: Presentation inputs

    /// Binds this session's approved copy, or reports the copy layer's own refusal.
    ///
    /// Bound per session because the Model Bundle is: a later activation or rollback cannot
    /// change a running session, so its copy is fixed with it (Requirements 8.1 and 10.15).
    func copyBinding(
        for session: AnalysisSessionBinding
    ) throws(PresentationCopyError) -> ApprovedCopyBinding {
        try ApprovedCopyBinding.bind(
            catalog: admission.configuration.verdictCopyCatalog,
            session: session,
            capabilities: admission.configuration.capabilityManifest,
            fusionRule: fusion.approvedRule?.rule
        )
    }

    /// Everything the four disclosure destinations are projected from.
    ///
    /// Assembled from the session's own binding and the release records this build was admitted
    /// under, so a destination reached from a report describes that session rather than whatever
    /// the newest artifact says (Requirement 8.17).
    func disclosureInput(
        for session: AnalysisSessionBinding,
        scope: EvidenceScope,
        copy: ApprovedCopyBinding
    ) -> DisclosureScreenInput {
        DisclosureScreenInput(
            capabilities: admission.configuration.capabilityManifest,
            lifecyclePolicy: admission.configuration.lifecyclePolicy,
            release: release,
            session: session,
            scope: scope,
            copy: copy
        )
    }
}

// MARK: - The composition root

/// Assembles the main application and runs its startup flow.
///
/// A namespace rather than a value: there is one main-application graph per process, and a
/// second one would be a second startup gate.
enum MainAppComposition {

    /// Which target this composition is, selecting the Resource Budget.
    static let target: ExecutionTarget = .mainApplication

    /// Runs startup and returns either a refusal or the one ingest surface.
    ///
    /// The order is the design's, and it is part of the contract rather than an implementation
    /// detail, because it decides which cause an audit is told about:
    ///
    /// 1. Read the release-controlled inputs this build carries. An absent one is named.
    /// 2. Observe the running build's identity. Observation stays separate from comparison.
    /// 3. Build the compiled composition from the module-graph facts and the provisioned
    ///    implementation versions.
    /// 4. Resolve the two app-controlled storage namespaces, so the gate's own cleanup step can
    ///    reach both.
    /// 5. Run the seven-step preflight, which identifies the device, matches the signed
    ///    allowlist, verifies and if necessary activates the embedded bundle, validates the
    ///    lifecycle policy and this target's budget, removes abandoned session data, and
    ///    confirms the module graph is the one the manifest describes. Startup cleanup is
    ///    inside it, at its own step 5, so it cannot be skipped or reordered from here.
    /// 6. Only then assemble the analysis graph and the ingest surface.
    ///
    /// A refusal at any step returns `blocked` and no `AdmittedMainApp` is constructed, so
    /// nothing downstream of the gate exists to be called.
    static func start<Composition: CapabilityComposition>(
        composition: Composition.Type,
        provisioning: MainAppReleaseProvisioning? = nil,
        bundle: Bundle = .main
    ) async -> MainAppStartupOutcome {
        // Step 1. The release-controlled input set.
        guard let provisioning else {
            return .blocked(.releaseInputsUnprovisioned(unprovisionedInputs(bundle: bundle)))
        }

        // Step 2. The running identity, observed rather than declared.
        let device: DeviceContext
        switch ObservedDeviceIdentity.observed(bundle: bundle) {
        case let .success(observed):
            device = observed
        case let .failure(field):
            return .blocked(.deviceIdentityUnobservable(field))
        }

        // Step 3. What this build actually is, as a fact about its module graph — including the
        // adapter-version pin: every capability whose implementation is a linked adapter must
        // have been provisioned as the exact release that adapter reports. A build provisioned
        // as a validator release it does not link is refused here, so the gate never compares a
        // version its own binary contradicts against the signed manifest.
        // Module-qualified, because each build output's own composition enum is also named
        // `CompiledCapabilityComposition` and the unqualified name resolves to that one.
        let compiled: DefAIkeDomain.CompiledCapabilityComposition
        switch composition.compiledComposition(
            implementationVersions: provisioning.capabilityImplementationVersions
        ) {
        case let .success(value):
            compiled = value
        case let .failure(inconsistency):
            return .blocked(.compositionNotRunnable(inconsistency))
        }

        // Step 4. Both app-controlled session namespaces, so startup cleanup covers every one
        // of them. Deletion means removal from all of them, so a namespace that cannot be
        // named is a refusal rather than a namespace quietly skipped.
        let appGroupSessionRoot: URL
        let appGroupTransferRoot: URL
        do {
            appGroupSessionRoot = try SessionStorageRoots.appGroupRoot(
                forAppGroup: provisioning.appGroup
            )
            // The handoff protocol's own subtree, resolved through the module that owns it
            // rather than derived from the session root by path surgery. The two are siblings,
            // so the session lifecycle and the transfer lifecycle cannot delete each other's
            // bytes.
            appGroupTransferRoot = try AppGroupContainer.transferRoot(
                forAppGroup: provisioning.appGroup
            )
        } catch {
            return .blocked(.appGroupContainerUnresolvable(error))
        }

        // Cleanup-only views of those namespaces. Capacity zero, on purpose: this instance is
        // structurally incapable of retaining a byte, so the store the gate sweeps with cannot
        // become the store a session writes to. The container protection is the strictest level
        // available rather than a policy value read from an artifact, because nothing is ever
        // created through these and the bound level is not known until the gate has run.
        let sweepStores = [
            SessionStorageRoots.appPrivateRoot(),
            appGroupSessionRoot,
        ].map { root in
            ProtectedEphemeralFileStore(
                configuration: ProtectedEphemeralFileStore.Configuration(
                    rootDirectory: root,
                    capacityInBytes: 0,
                    containerProtection: .complete
                ),
                protection: provisioning.protection
            )
        }
        // Transfer scopes are deliberately not swept: they belong to the handoff lifecycle, and
        // removing them here would delete a pending handoff the user already consented to.
        let startupCleanup = ProtectedSessionDataDeleter(namespaces: sweepStores)

        // Step 5. The seven-step fail-closed gate.
        let preflight = StartupPreflight(
            device: device,
            composition: compiled,
            capabilityManifest: provisioning.capabilityManifest,
            verdictCopyCatalog: provisioning.verdictCopyCatalog,
            embeddedBundle: provisioning.embeddedBundle,
            target: target
        )
        let admission: ReleaseAdmission
        do {
            admission = try await preflight.run(
                policies: provisioning.policies,
                bundles: provisioning.bundles,
                cleanup: startupCleanup
            )
        } catch {
            return .blocked(.preflight(error))
        }

        // Step 6. Only now is the analysis graph assembled and ingest exposed.
        return assemble(
            admission: admission,
            composition: composition,
            provisioning: provisioning,
            appGroupTransferRoot: appGroupTransferRoot
        )
    }

    /// The inputs this repository does not carry, for a startup with no provisioning.
    ///
    /// Reported as one set rather than one at a time, so a release audit sees everything owed
    /// instead of discovering the gaps across successive launches. The identifier half is read
    /// from the installed build; the artifact half has no shipping reader at all.
    static func unprovisionedInputs(bundle: Bundle = .main) -> [UnprovisionedReleaseInput] {
        var gaps: Set<UnprovisionedReleaseInput> = [
            .policyArtifactStore,
            .modelBundleVerification,
            .approvedBundleLayout,
            .releaseEvidenceIndex,
            .releaseReadinessRecord,
        ]
        if case let .failure(identifierGaps) =
            MainAppReleaseProvisioning.installedIdentifiers(bundle: bundle)
        {
            gaps.formUnion(identifierGaps.inputs)
        }
        if case let .failure(field) = ObservedDeviceIdentity.observed(bundle: bundle) {
            gaps.insert(field == .appBuild ? .applicationBuildIdentity : .observedDeviceIdentity)
        }
        return gaps.sorted { $0.rawValue < $1.rawValue }
    }

    /// Assembles everything downstream of a passed gate.
    ///
    /// Split out so the admission is a parameter: this function cannot run without one, which is
    /// the same structural rule `AdmittedMainApp`'s private initializer states.
    private static func assemble<Composition: CapabilityComposition>(
        admission: ReleaseAdmission,
        composition: Composition.Type,
        provisioning: MainAppReleaseProvisioning,
        appGroupTransferRoot: URL
    ) -> MainAppStartupOutcome {
        let configuration = admission.configuration
        let budget = configuration.resourceBudgets.budget(for: target)

        // The approved protection level for material this process retains. Read from the signed
        // Extension Execution Policy, which is where the design records that choice, and never
        // weakened to make a write succeed (Requirement 9.6).
        let protectionLevel = configuration.extensionExecutionPolicy.stagedFileProtection

        // Capacity comes from the bound budget's temporary-storage limit through the store's own
        // factory, which fails rather than falling back to a number chosen here.
        let sessionConfiguration: ProtectedEphemeralFileStore.Configuration
        let transferConfiguration: ProtectedEphemeralFileStore.Configuration
        do {
            sessionConfiguration = try ProtectedEphemeralFileStore.configuration(
                rootDirectory: SessionStorageRoots.appPrivateRoot(),
                budget: budget,
                containerProtection: protectionLevel
            )
            transferConfiguration = try ProtectedEphemeralFileStore.configuration(
                rootDirectory: appGroupTransferRoot,
                budget: budget,
                containerProtection: protectionLevel
            )
        } catch {
            return .blocked(.sessionStoreNotConfigurable(error))
        }

        // Every retained byte of a session lives here: the encoded copy the validator and the
        // provenance lane both read, addressed by the same key so they cannot see different
        // bytes (Requirements 2.12 and 2.13).
        let sessionStore = ProtectedEphemeralFileStore(
            configuration: sessionConfiguration,
            protection: provisioning.protection
        )
        let transferStore = ProtectedEphemeralFileStore(
            configuration: transferConfiguration,
            protection: provisioning.protection
        )

        guard let resources = ResourceController(
            target: target,
            budgets: configuration.resourceBudgets,
            governor: PlatformResourceGovernor(target: target)
        ) else {
            return .blocked(.resourceControllerNotBindable)
        }

        // The image pipeline's own stores. Each is an actor owning one kind of retained
        // material, released per session on the coordinator's single end path.
        let decodedImages = DecodedImageStore()
        let inputQuality = InputQualityLedger()
        let modelInputs = PreparedModelInputStore()
        let loadedModels = LoadedPixelModelStore()

        let validator = ImageIOInputValidator(
            encodedAssets: sessionStore,
            decodedImages: decodedImages,
            quality: inputQuality
        )
        let preprocessor = ContractImagePreprocessor(
            encodedAssets: sessionStore,
            decodedImages: decodedImages,
            modelInputs: modelInputs
        )

        // The two bridges the module boundaries forbid the libraries from making themselves.
        let modelLoader = CoreMLPixelModelLoader(
            runtimeLoader: CoreMLModelRuntimeLoader(
                locations: BundleCompiledModelLocator(
                    layout: provisioning.bundleLayout,
                    installedRoot: provisioning.installedBundleRoot
                )
            ),
            loadedModels: loadedModels
        )
        let analyzer = CoreMLPixelAnalyzer(
            loadedModels: loadedModels,
            preparedPixels: PreparedModelInputBridge(store: modelInputs)
        )

        // The Calibration Policy is activated for the bundle this build was admitted under. A
        // policy that does not activate blocks ingest rather than producing a verdict.
        guard let activated = try? ValidatedCalibrationPolicy(
            activating: configuration.calibrationPolicy,
            for: admission.bundle.manifest,
            evidence: provisioning.evidenceIndex
        ) else {
            return .blocked(.calibrationPolicyNotActivatable)
        }
        let calibrator = CalibrationEvaluator(activatedWith: activated)

        // The conditional provenance lane.
        //
        // `linksValidator` is passed separately from the analyzer, and that separation is the
        // point: this composition links the reviewed adapter, so a `nil` analyzer no longer
        // means "no validator was compiled in" and must not be reported as such. The provider
        // needs both facts to name the right reason — the module graph, then the manifest, then
        // whether an approved decision supplies an analyzer at all. Every path short of all
        // three is the unavailable lane, and none of them can reach a validator.
        let provenance = ProvenanceLaneProvider.resolve(
            linksValidator: composition.linksProvenanceValidator,
            analyzer: composition.provenanceAnalyzer(
                store: sessionStore,
                policy: configuration.provenancePolicy
            ),
            policy: configuration.provenancePolicy,
            manifest: configuration.capabilityManifest
        )

        // The optional Combined Summary. A rule that cannot be validated costs the summary and
        // nothing else (Requirement 7.16), so this never blocks startup. Validating a candidate
        // rule needs the Release Fixture Suite and the release evidence index it names, and
        // fixtures are nonshipping release evidence a distributed build does not carry — so a
        // bound rule stays omitted here until an approved runtime validation input exists.
        let fusion: OptionalFusion = .omitted(.noRuleBound)

        let copyResolver: AccessibleTextResolver
        do {
            copyResolver = try AccessibleTextResolver.shipped()
        } catch {
            return .blocked(.approvedCopyUnreadable(error))
        }

        let binder = AnalysisSessionBinder(admission: admission, bundles: provisioning.bundles)
        let coordinator = AnalysisCoordinator(
            binder: binder,
            validator: validator,
            preprocessor: preprocessor,
            modelLoader: modelLoader,
            analyzer: analyzer,
            calibrator: calibrator,
            provenance: provenance,
            fuser: fusion.approvedRule,
            // No apparent-inconsistency classifier is declared by any installed artifact. A
            // release that declares none passes `nil`, and the Evidence Report then carries no
            // notice rather than one worded here.
            inconsistencyClassifier: nil,
            cleanup: SessionTerminalCleanup(
                deleter: ProtectedSessionDataDeleter(namespaces: [sessionStore]),
                policy: configuration.lifecyclePolicy
            ),
            // Serial, because concurrency is authorized only when the bound Device Validation
            // Plan approves that execution policy for this exact configuration, and no
            // installed plan does. Serial is the conservative reading rather than an assumption
            // that lower wall time is safer than lower peak memory.
            branchExecution: ApprovedEvidenceBranchExecution(
                execution: .serial,
                validationPlan: admission.boundValidationPlan
            )
        )

        let pickerItems = PhotosPickerItemRegistry()
        let photos = PhotosIngestCoordinator(
            importer: PhotosImportAdapter(
                access: PhotosPickerRepresentationAccess(
                    registry: pickerItems,
                    protectionLevel: protectionLevel,
                    protection: provisioning.protection
                ),
                store: sessionStore,
                sessionFileProtection: protectionLevel
            )
        )

        let share = ShareHandoffIngestCoordinator(
            claiming: ShareHandoffClaimAdapter(
                transfers: SharedTransferStore(
                    store: transferStore,
                    lifecyclePolicy: configuration.lifecyclePolicy,
                    extensionPolicy: configuration.extensionExecutionPolicy,
                    buildID: admission.context.device.appBuild
                ),
                sessionStore: sessionStore,
                sessionFileProtection: protectionLevel
            ),
            bundles: provisioning.bundles
        )

        return .ready(
            AdmittedMainApp(
                admission: admission,
                photos: photos,
                share: share,
                coordinator: coordinator,
                binder: binder,
                pickerItems: pickerItems,
                resources: resources,
                provenance: provenance,
                fusion: fusion,
                copyResolver: copyResolver,
                release: provisioning.release
            )
        )
    }
}
