import DefAIkeDomain
import DefAIkeSharedTransfer
import Foundation

// The Share Extension's fail-closed startup gate, and the only value that permits a handoff.
//
// The main application has `StartupPreflight`, and this is deliberately not it. That gate's
// steps 3 and 6 verify, activate, and bind a Model Bundle and compare a compiled capability
// composition — work the extension must not be able to do, because `DefAIkeModelBundle` and
// `DefAIkeCoreML` are absent from its module closure and because Requirement 11.11 delegates
// all inference to the main application. `StartupPreflight` itself records the split: "the
// bundle steps make this the main-application gate in practice; the Share Extension performs its
// own start-time cleanup through the same port without loading a model".
//
// So the extension runs the subset of gates that govern *its* work, and every one of them
// resolves to a signed artifact:
//
//   1. Observe this extension's own identity, and check the platform floor.
//   2. Load the signed Release Capability Manifest and every policy it names, with the
//      references required to resolve. The extension needs three of them — the Extension
//      Execution Policy, the Data Lifecycle Policy, and the Share Extension Resource Budget —
//      and reads them through the same join the app does, so the two processes cannot disagree
//      about which versions govern one handoff (Requirement 11.9).
//   3. Match an allowlist entry for this exact hardware identifier, operating-system version,
//      and build, with every mandatory gate satisfied. Requirement 11.20 has the Release Process
//      approve Share Extension handoff viability independently, and this is the runtime half:
//      an unapproved configuration stages nothing.
//   4. Bind this target's Resource Budget, checked to be the extension's and to come from the
//      Device Validation Plan the matched entry's evidence was produced under
//      (Requirements 11.1 and 11.3).
//   5. Resolve approved wording for the four surfaces a successful handoff must show. A build
//      that cannot word the visible consent action does not offer the handoff.
//   6. Resolve the registered App Group container and configure protected storage from the bound
//      budget's temporary-storage ceiling.
//   7. Require the platform to actually enforce iOS Data Protection (Requirement 9.6).
//   8. Remove transfer material an interrupted process left behind, before accepting any work
//      (Requirements 9.9 and 11.16).
//
// What this gate is *not*: proof of distribution control, for exactly the reason
// `StartupPreflight` records. Requirement 1.3 is a Release Process obligation, and this runtime
// refusal is defense in depth.
//
// Nothing here creates an allowlist entry, an approval, a deadline, a protection level, or a
// resource limit. Every decision resolves to a signed artifact, and an absent one is a failure
// rather than a default.

// MARK: - The admission

/// Permission to stage a handoff, and everything the staging path binds.
///
/// Constructible only by `ShareExtensionPreflight.run()`: the initializer is `fileprivate` to
/// this file, and this file contains exactly one call to it — inside `run()`, after every gate
/// has passed. So "a handoff is staged only after every startup gate passed" is a fact about the
/// type graph rather than a convention the composition root has to remember, and holding one of
/// these *is* the evidence that all eight gates passed on this device, in this build, against
/// these exact artifact versions.
///
/// It is the same discipline `ReleaseAdmission` uses in the main application, and it is
/// deliberately a separate type: an admission that permits pixel inference and an admission that
/// permits staging a handoff govern different work under different budgets, and one standing in
/// for the other would be exactly the cross-target substitution Requirement 11.1 forbids.
struct ShareExtensionAdmission: Sendable {

    /// The observed identity every published ticket is stamped with.
    ///
    /// `device.appBuild` becomes the ticket's `extensionBuildID`, which the claiming application
    /// compares against its own (Requirement 2.19). It comes from here rather than from a
    /// parameter so a staged ticket cannot carry a build identity no gate checked.
    let device: DeviceContext

    /// Every policy artifact this build is bound to, with its references resolved.
    let configuration: ReleaseConfiguration

    /// The exact allowlist entry this device matched, with its gate evidence.
    let approvedConfiguration: ApprovedDeviceConfiguration

    /// The signed Share Extension Resource Budget. Every ceiling the staging path compares
    /// against comes from here.
    let budget: ResourceBudget

    /// Approved wording for the four surfaces a successful handoff shows.
    let copy: ApprovedShareExtensionCopy

    /// The registered App Group container's `transfers` subtree.
    let transferRoot: URL

    /// Receipts from the startup cleanup that ran before the handoff surface became available.
    ///
    /// Empty means there was nothing abandoned to remove, which is a success. It never means
    /// cleanup was skipped: reaching this value at all required the cleanup call to return
    /// (Requirements 9.9 and 11.16).
    let startupCleanup: [EphemeralDeletionReceipt]

    /// The pending handoff startup cleanup deliberately kept, if any.
    ///
    /// A committed pending handoff is a session the user already consented to, so it survives a
    /// restart until its lifecycle deadline passes. Recorded here so the first activation after a
    /// restart can present the recovery instruction without re-deriving it.
    let retainedPendingTransfer: ShareTransferID?

    /// Which target this admission governs. Fixed, with no initializer parameter for it.
    let target: ExecutionTarget = .shareExtension

    fileprivate init(
        device: DeviceContext,
        configuration: ReleaseConfiguration,
        approvedConfiguration: ApprovedDeviceConfiguration,
        budget: ResourceBudget,
        copy: ApprovedShareExtensionCopy,
        transferRoot: URL,
        startupCleanup: [EphemeralDeletionReceipt],
        retainedPendingTransfer: ShareTransferID?
    ) {
        self.device = device
        self.configuration = configuration
        self.approvedConfiguration = approvedConfiguration
        self.budget = budget
        self.copy = copy
        self.transferRoot = transferRoot
        self.startupCleanup = startupCleanup
        self.retainedPendingTransfer = retainedPendingTransfer
    }

    /// The Extension Execution Policy this build is bound to (Requirement 11.9).
    var extensionPolicy: ExtensionExecutionPolicy { configuration.extensionExecutionPolicy }

    /// The approved data-protection level staged handoff material is created with.
    var stagedFileProtection: FileProtectionLevel { extensionPolicy.stagedFileProtection }

    /// The Device Validation Plan that supplied this target's limits.
    var boundValidationPlan: ArtifactID { budget.validationPlan }
}

// MARK: - Refusals

/// Why the Share Extension did not expose a handoff surface.
///
/// Deliberately not an `AnalysisError`, deliberately not convertible to one, and deliberately
/// carrying no session identifier, stage, or evidence: a refused startup staged nothing and
/// created no Analysis Session, so there is nothing for an evidence outcome to describe.
///
/// Every case names one cause. There is no `unknown`, and no case a caller can relax.
enum ShareExtensionStartupRefusal: Error, Sendable, CustomStringConvertible {

    /// One or more release-controlled inputs are not installed in this build.
    case releaseInputsUnprovisioned([UnprovisionedExtensionReleaseInput])

    /// The running extension's own identity could not be observed.
    case identityUnobservable(ObservedExtensionIdentity.UnobservableIdentity)

    /// The running operating-system version is below the Version 1 minimum (Requirement 1.2).
    ///
    /// Its own case rather than an indistinguishable "no entry matched": an exact allowlist entry
    /// can only exist at iOS 17.0 or later, so checking the floor first names the real cause.
    case operatingSystemBelowMinimum(PlatformVersion)

    /// A signed policy artifact could not be read, or the set did not cohere.
    case artifactUnavailable(ReleaseArtifactError)

    /// An artifact's approval record does not approve it.
    case unapprovedArtifact(field: String)

    /// Two release-controlled values that must be identical are not.
    case identityMismatch(field: String, expected: String, found: String)

    /// The signed allowlist approves no configuration for distribution (Requirement 13.22).
    case allowlistApprovesNoConfiguration(ArtifactID)

    /// This exact hardware identifier, operating-system version, and build are not allowlisted.
    case configurationNotAllowlisted(
        hardwareIdentifier: DeviceHardwareID,
        osVersion: PlatformVersion,
        appBuild: AppBuildID
    )

    /// The matched entry exists but has an unsatisfied or unexecuted mandatory gate.
    ///
    /// Membership is not approval (Requirements 13.19 and 13.21).
    case unsatisfiedDeviceGates(configuration: ApprovedConfigurationID, gates: [DeviceGate])

    /// The closed Approved Verdict Copy vocabulary does not define a surface a successful handoff
    /// must show.
    ///
    /// The consent action is the blocking one: Requirement 2.2 requires a *visible* consent
    /// action before the image is handed over, and a screen with no words is not one. Refusing
    /// here is what keeps this build from presenting an unapproved sentence.
    case handoffCopyUnapproved(Set<UnapprovedShareExtensionSurface>)

    /// The registered App Group container could not be resolved.
    ///
    /// Fail-closed for the reason `AppGroupContainer` gives: an unresolvable container means the
    /// App Group is not registered for this build or the entitlement is missing, and falling back
    /// to a process-private directory would stage encoded image bytes somewhere the main
    /// application will never look and the handoff lifecycle does not own.
    case appGroupContainerUnresolvable(AppGroupContainer.ResolutionError)

    /// The bound Resource Budget defines no approved temporary-storage capacity, so no protected
    /// store can be configured against it.
    case transferStoreNotConfigurable(ProtectedEphemeralFileStore.ConfigurationError)

    /// This platform does not enforce iOS Data Protection.
    ///
    /// Requirement 9.6 is about the whole time an ephemeral analysis file exists. The protection
    /// attribute is accepted and reported off iOS but not backed by Data Protection, so a
    /// platform that does not enforce it may not hold staged encoded image bytes at all.
    case dataProtectionUnenforced

    /// Startup cleanup did not complete, so work is not accepted.
    ///
    /// Unremoved bytes from an interrupted handoff are a privacy failure, and continuing past one
    /// would accept a new handoff with analyzable material still on disk.
    case startupCleanupFailed(EphemeralStoreError)

    var description: String {
        switch self {
        case let .releaseInputsUnprovisioned(inputs):
            return "release inputs are not provisioned: \(inputs.map(\.rawValue).sorted())"
        case let .identityUnobservable(field):
            return "the running extension's \(field.rawValue) could not be observed"
        case let .operatingSystemBelowMinimum(version):
            return "iOS \(version) is below the Version 1 minimum \(PlatformVersion.iOS17)"
        case let .artifactUnavailable(error):
            return "a signed policy artifact could not be read: \(error)"
        case let .unapprovedArtifact(field):
            return "an artifact is not approved: \(field)"
        case let .identityMismatch(field, expected, found):
            return "\(field) is \(found) and must be \(expected)"
        case let .allowlistApprovesNoConfiguration(allowlist):
            return "no configuration is approved for distribution: \(allowlist.rawValue)"
        case let .configurationNotAllowlisted(hardware, osVersion, appBuild):
            return "not allowlisted: \(hardware.rawValue) iOS \(osVersion) \(appBuild.rawValue)"
        case let .unsatisfiedDeviceGates(configuration, gates):
            return "unsatisfied gates for \(configuration.rawValue): \(gates.map(\.rawValue))"
        case let .handoffCopyUnapproved(surfaces):
            return "no approved copy for: \(surfaces.map(\.rawValue).sorted())"
        case let .appGroupContainerUnresolvable(error):
            return "the registered App Group container could not be resolved: \(error)"
        case let .transferStoreNotConfigurable(error):
            return "no approved temporary-storage capacity is available: \(error)"
        case .dataProtectionUnenforced:
            return "this platform does not enforce iOS Data Protection"
        case let .startupCleanupFailed(error):
            return "startup cleanup did not complete: \(error)"
        }
    }
}

// MARK: - The gate

/// Runs the Share Extension's mandatory startup gates.
///
/// A value type holding only the observed identity and the provisioned inputs. It decides
/// nothing: it compares, and the comparison's inputs are one signed artifact set and one
/// observation of the running process.
struct ShareExtensionPreflight: Sendable {

    /// What this process is running as, observed at the platform boundary.
    let device: DeviceContext

    /// The release-controlled input set this build carries.
    let provisioning: ShareExtensionReleaseProvisioning

    init(device: DeviceContext, provisioning: ShareExtensionReleaseProvisioning) {
        self.device = device
        self.provisioning = provisioning
    }

    /// Runs every gate in order and returns permission to stage a handoff.
    ///
    /// Throws on the first failing gate. There is no partial admission, no waiver, and no path
    /// that returns a value with a gate unchecked.
    ///
    /// `protection` and `clock` are injected only so a host check can drive the fail-closed paths
    /// without a device that refuses a protection level. Neither has a configuration that
    /// weakens a production path: `PlatformDataProtection.enforcesDataProtection` is `false` off
    /// iOS, and gate 7 refuses on that basis.
    func run(
        copyResolver: some ShareExtensionCopyResolving = UnlocalizedShareExtensionCopy(),
        protection: any DataProtectionApplying = PlatformDataProtection(),
        clock: any SessionClock = SystemSessionClock()
    ) async throws(ShareExtensionStartupRefusal) -> ShareExtensionAdmission {
        // Gate 1. The platform floor. The observed identity arrives as an input; what this adds
        // is the minimum this release may run on at all.
        guard device.osVersion >= .iOS17 else {
            throw .operatingSystemBelowMinimum(device.osVersion)
        }

        // Gate 2. The signed manifest and every policy it names, with references resolved.
        let configuration: ReleaseConfiguration
        do {
            configuration = try await ReleaseConfiguration.load(
                capabilityManifest: provisioning.capabilityManifest,
                verdictCopyCatalog: provisioning.verdictCopyCatalog,
                from: provisioning.policies
            )
        } catch {
            throw .artifactUnavailable(error)
        }
        let manifest = configuration.capabilityManifest
        try requireApproval(manifest.approval, field: "capabilityManifest.approval")
        try requireIdentity(
            manifest.appBuild,
            matches: device.appBuild,
            field: "capabilityManifest.appBuild"
        )
        try requireApproval(
            configuration.lifecyclePolicy.approval,
            field: "lifecyclePolicy.approval"
        )
        try requireApproval(
            configuration.verdictCopyCatalog.approval,
            field: "verdictCopyCatalog.approval"
        )
        // The compiled capability set is deliberately *not* compared here. A capability is an
        // evidence capability — pixel analysis, Content Credential validation — and this target
        // compiles none of them: that is the whole point of `ForbiddenExtensionModule`. Asserting
        // a capability set from a process that implements no capability would be a claim about
        // the containing application made by the wrong binary. The manifest's compiled-capability
        // and validator-linkage checks belong to the main application's gate, which runs them
        // bidirectionally.

        // Gate 3. An allowlist entry for this exact configuration, with every mandatory gate
        // satisfied.
        let entry = try await matchAllowlistEntry(manifest: manifest)

        // Gate 4. This target's budget, bound to this target and to the matched entry's plan.
        let budget = configuration.resourceBudgets.budget(for: target)
        try requireIdentity(
            budget.target.rawValue,
            matches: target.rawValue,
            field: "resourceBudget.target"
        )
        try requireIdentity(
            budget.validationPlan,
            matches: entry.versionTuple.validationPlan,
            field: "resourceBudget.validationPlan"
        )

        // Gate 5. Approved wording for every surface a successful handoff shows.
        let copy: ApprovedShareExtensionCopy
        switch ApprovedShareExtensionCopy.resolve(
            from: configuration.verdictCopyCatalog,
            resolver: copyResolver
        ) {
        case let .success(resolved):
            copy = resolved
        case let .failure(unapproved):
            throw .handoffCopyUnapproved(unapproved.surfaces)
        }

        // Gate 6. The shared container, and protected storage sized from the bound budget.
        let transferRoot: URL
        do {
            transferRoot = try AppGroupContainer.transferRoot(forAppGroup: provisioning.appGroup)
        } catch {
            throw .appGroupContainerUnresolvable(error)
        }
        let storeConfiguration: ProtectedEphemeralFileStore.Configuration
        do {
            storeConfiguration = try ProtectedEphemeralFileStore.configuration(
                rootDirectory: transferRoot,
                budget: budget,
                containerProtection: configuration.extensionExecutionPolicy.stagedFileProtection
            )
        } catch {
            throw .transferStoreNotConfigurable(error)
        }
        let store = ProtectedEphemeralFileStore(
            configuration: storeConfiguration,
            protection: protection,
            clock: clock
        )

        // Gate 7. The platform has to actually enforce what the policy asked for.
        guard await store.enforcesDataProtection else {
            throw .dataProtectionUnenforced
        }

        // Gate 8. Remove what an interrupted process left, before accepting any work. The
        // transfer store owns this: it knows the one thing a blind sweep would destroy, which is
        // a published handoff the user consented to and whose deadline has not passed.
        let transfers = SharedTransferStore(
            store: store,
            lifecyclePolicy: configuration.lifecyclePolicy,
            extensionPolicy: configuration.extensionExecutionPolicy,
            buildID: device.appBuild,
            clock: clock
        )
        let cleanup: StartupCleanupReport
        do {
            cleanup = try await transfers.runStartupCleanup()
        } catch {
            throw .startupCleanupFailed(Self.storeError(from: error))
        }

        // Every gate passed. This is the only construction of an admission in the target.
        return ShareExtensionAdmission(
            device: device,
            configuration: configuration,
            approvedConfiguration: entry,
            budget: budget,
            copy: copy,
            transferRoot: transferRoot,
            startupCleanup: cleanup.receipts,
            retainedPendingTransfer: cleanup.retainedTransfer
        )
    }

    /// Which target this gate runs in, selecting the Resource Budget.
    private var target: ExecutionTarget { .shareExtension }
}

// MARK: - Gate 3

extension ShareExtensionPreflight {

    /// The one entry matching this configuration exactly, with every gate satisfied.
    ///
    /// Matching is on the exact hardware identifier, the exact operating-system version, and the
    /// exact application build. Never on device family, marketing name, chip generation, or an
    /// inference from capabilities: an unlisted iPhone stays unlisted even when a listed sibling
    /// would pass.
    private func matchAllowlistEntry(
        manifest: ReleaseCapabilityManifest
    ) async throws(ShareExtensionStartupRefusal) -> ApprovedDeviceConfiguration {
        let allowlistID = manifest.approvedConfigurationAllowlist
        let allowlist: ReleaseApprovedDeviceAllowlist
        do {
            allowlist = try await provisioning.policies.deviceAllowlist(allowlistID)
        } catch {
            throw .artifactUnavailable(error)
        }
        guard allowlist.id == allowlistID else {
            throw .artifactUnavailable(
                .identifierMismatch(requested: allowlistID, found: allowlist.id)
            )
        }
        try requireApproval(allowlist.approval, field: "deviceAllowlist.approval")

        // Checked before the device match so "nothing is approved for distribution" is not
        // reported as "this device is not approved" (Requirement 13.22).
        guard allowlist.permitsDistribution else {
            throw .allowlistApprovesNoConfiguration(allowlist.id)
        }
        guard
            let entry = allowlist.entry(
                hardwareIdentifier: device.hardwareIdentifier,
                osVersion: device.osVersion,
                appBuild: device.appBuild
            )
        else {
            throw .configurationNotAllowlisted(
                hardwareIdentifier: device.hardwareIdentifier,
                osVersion: device.osVersion,
                appBuild: device.appBuild
            )
        }
        // Membership is not approval. An entry can exist with a failed or unexecuted mandatory
        // gate, and it is not distributable.
        let unsatisfied = entry.unsatisfiedGates
        guard unsatisfied.isEmpty else {
            throw .unsatisfiedDeviceGates(
                configuration: entry.id,
                gates: unsatisfied.sorted { $0.rawValue < $1.rawValue }
            )
        }
        return entry
    }
}

// MARK: - Shared comparisons

extension ShareExtensionPreflight {

    private func requireIdentity(
        _ found: some CanonicalIdentifier,
        matches expected: some CanonicalIdentifier,
        field: String
    ) throws(ShareExtensionStartupRefusal) {
        guard found.rawValue == expected.rawValue else {
            throw .identityMismatch(
                field: field,
                expected: expected.rawValue,
                found: found.rawValue
            )
        }
    }

    private func requireIdentity(
        _ found: String,
        matches expected: String,
        field: String
    ) throws(ShareExtensionStartupRefusal) {
        guard found == expected else {
            throw .identityMismatch(field: field, expected: expected, found: found)
        }
    }

    private func requireApproval(
        _ record: ApprovalRecord,
        field: String
    ) throws(ShareExtensionStartupRefusal) {
        guard record.isApproved else { throw .unapprovedArtifact(field: field) }
    }

    /// The store fault behind a transfer-store failure.
    ///
    /// Exhaustive on purpose: a new `TransferStoreError` case must stop this compiling rather than
    /// inherit a mapping nobody chose. Only `.store(_:)` carries a store fault; the rest describe
    /// publication outcomes that startup cleanup cannot produce, so they collapse to the
    /// unclassified fault rather than being reported as something more specific than what is
    /// known.
    private static func storeError(from error: TransferStoreError) -> EphemeralStoreError {
        switch error {
        case .store(let underlying):
            return underlying
        case .pendingHandoffExists, .stagingFailed, .manifestTooLarge, .ticketRejected:
            return .storeUnavailable
        }
    }
}
