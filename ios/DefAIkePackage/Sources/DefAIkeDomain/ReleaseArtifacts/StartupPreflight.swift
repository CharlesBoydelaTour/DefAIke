// The fail-closed startup gate, and the only value that permits ingest.
//
// The design fixes a seven-step sequence before either ingest route is exposed, and the
// order is part of the contract rather than an implementation detail: it decides which
// cause an audit is told about. Cleanup runs against the *bound* Data Lifecycle Policy,
// so it has to follow policy validation; the bundle is verified against the *matched*
// allowlist entry, so it has to follow the device match. Running the steps in a different
// order would still fail closed, but it would report the wrong reason.
//
// What this gate is *not*: proof of distribution control. App Store metadata can enforce
// the iPhone family and the iOS 17 minimum, but an exact hardware and operating-system
// allowlist may not be expressible as store compatibility metadata, so a build can reach
// a configuration nobody approved and simply refuse to work there. That is defense in
// depth. Requirement 1.3 is a Release Process obligation, and the Release Process has to
// demonstrate an approved distribution control independently; if it cannot, public
// distribution stays blocked rather than this runtime check standing in for it.
//
// Nothing here creates an allowlist entry, a candidate configuration, an approval, or a
// policy value. Every decision resolves to a signed artifact, and an absent one is a
// failure rather than a default (Requirements 13.18 through 13.22 and 14.15).

/// Permission to expose ingest, and everything the session path binds.
///
/// Constructible only by ``StartupPreflight/run(policies:bundles:cleanup:)``, so "ingest
/// is exposed only after every startup gate passed" is a fact about the type graph
/// rather than a convention a composition root has to remember. A caller that holds one
/// of these holds the evidence that all seven steps passed on this device, in this build,
/// against these exact artifact versions.
public struct ReleaseAdmission: Hashable, Sendable {
    /// The device, matched entry, manifest version, and compiled capability set the
    /// Model Bundle manager and every session binding are evaluated against.
    public let context: ReleaseContext

    /// Every policy artifact this build is bound to, with its references resolved.
    public let configuration: ReleaseConfiguration

    /// The exact allowlist entry this device matched, with its gate evidence.
    public let approvedConfiguration: ApprovedDeviceConfiguration

    /// The verified, activated bundle a session may bind.
    public let bundle: BoundModelBundle

    /// Which target this admission governs, selecting the Resource Budget.
    public let target: ExecutionTarget

    /// Receipts from the startup cleanup that ran before ingest became available.
    ///
    /// Empty means there was nothing abandoned to remove, which is a success. It never
    /// means cleanup was skipped: reaching this value at all required the cleanup call
    /// to return (Requirements 9.9 and 11.16).
    public let startupCleanup: [SessionDeletionReceipt]

    fileprivate init(
        context: ReleaseContext,
        configuration: ReleaseConfiguration,
        approvedConfiguration: ApprovedDeviceConfiguration,
        bundle: BoundModelBundle,
        target: ExecutionTarget,
        startupCleanup: [SessionDeletionReceipt]
    ) {
        self.context = context
        self.configuration = configuration
        self.approvedConfiguration = approvedConfiguration
        self.bundle = bundle
        self.target = target
        self.startupCleanup = startupCleanup
    }

    /// Whether this admission enables on-device Content Credential validation.
    ///
    /// True only when the signed manifest approves the capability, the Provenance Policy
    /// it names resolved, and the module graph links the validator preflight compared it
    /// against. Linking a validator is never approval on its own (Requirement 6.2).
    public var enablesProvenance: Bool { configuration.enablesProvenance }

    /// Whether this admission can produce a Combined Summary (Requirement 7.16).
    public var enablesFusion: Bool { configuration.enablesFusion }

    /// The Release Fixture Suite version the matched entry's gate evidence was produced
    /// against, for traceability in release records.
    public var boundFixtureSuite: ArtifactID {
        approvedConfiguration.versionTuple.fixtureSuite
    }

    /// The Device Validation Plan that supplied this target's limits.
    public var boundValidationPlan: ArtifactID {
        configuration.resourceBudgets.budget(for: target).validationPlan
    }
}

/// The mandatory startup gate that runs before either ingest route exists.
///
/// The observed identity — build, hardware identifier, operating-system version, and
/// compiled composition — is supplied by the platform and the module graph. Everything
/// else is read through the artifact port by exact identifier, so this type decides
/// nothing: it compares.
public struct StartupPreflight: Sendable {
    /// What this process is running as, observed at the platform boundary.
    public let device: DeviceContext

    /// What this build links, observed from its module graph.
    public let composition: CompiledCapabilityComposition

    /// The embedded signed Release Capability Manifest version, the root of the
    /// reference graph every other identifier is derived from.
    public let capabilityManifest: ArtifactID

    /// The Approved Verdict Copy catalog shipped with this build.
    ///
    /// Named separately because the manifest carries the *compatibility* identifier a
    /// catalog has to declare, not the catalog's own artifact identifier. Locating the
    /// catalog stays separate from approving it (Requirement 8.1).
    public let verdictCopyCatalog: ArtifactID

    /// The app-delivered Model Bundle this build embeds.
    ///
    /// Used only when no verified compatible bundle is already active, and only after
    /// the signed manifest is shown to approve it. It is an identifier for an artifact
    /// already inside the application version: there is no URL, no download, and no
    /// remote catalogue (Requirements 10.19 and 10.21).
    public let embeddedBundle: ModelBundleID

    /// Which target this gate is running in, selecting the Resource Budget.
    ///
    /// The bundle steps make this the main-application gate in practice; the Share
    /// Extension performs its own start-time cleanup through the same port without
    /// loading a model (Requirements 11.11 and 11.16).
    public let target: ExecutionTarget

    public init(
        device: DeviceContext,
        composition: CompiledCapabilityComposition,
        capabilityManifest: ArtifactID,
        verdictCopyCatalog: ArtifactID,
        embeddedBundle: ModelBundleID,
        target: ExecutionTarget
    ) {
        self.device = device
        self.composition = composition
        self.capabilityManifest = capabilityManifest
        self.verdictCopyCatalog = verdictCopyCatalog
        self.embeddedBundle = embeddedBundle
        self.target = target
    }

    /// Runs all seven steps in order and returns permission to expose ingest.
    ///
    /// Throws on the first failing gate. There is no partial admission, no waiver, and
    /// no path that returns a value with a gate unchecked (design step 7).
    public func run(
        policies: some PolicyArtifactReading,
        bundles: some ModelBundleManaging,
        cleanup: some SessionDataDeleting
    ) async throws(PreflightFailure) -> ReleaseAdmission {
        // Step 1. Identify the exact build, hardware identifier, and OS version.
        //
        // The values arrive as inputs; what this step adds is the platform floor. An
        // exact allowlist entry can only exist at iOS 17.0 or later, so checking the
        // floor first turns "this OS is too old" into its own finding instead of an
        // indistinguishable "no entry matched" (Requirement 1.2).
        guard device.osVersion >= .iOS17 else {
            throw .identityMismatch(
                field: "device.osVersion",
                expected: "at least \(PlatformVersion.iOS17)",
                found: device.osVersion.description
            )
        }

        // Step 2. Load the signed manifest and find an exact version-bound match.
        let configuration = try await loadConfiguration(policies)
        let manifest = configuration.capabilityManifest
        try requireApproval(manifest.approval, field: "capabilityManifest.approval")
        try requireIdentity(
            manifest.compositionIdentifier.value,
            matches: composition.compositionIdentifier.value,
            field: "capabilityManifest.compositionIdentifier"
        )
        try requireIdentity(
            manifest.appBuild,
            matches: device.appBuild,
            field: "capabilityManifest.appBuild"
        )
        let (allowlist, entry) = try await matchAllowlistEntry(policies, manifest: manifest)
        try requireVersionTuple(
            entry.versionTuple,
            manifest: manifest,
            configuration: configuration
        )
        try requireCoherentEntries(allowlist, manifest: manifest)

        // Step 3. Verify the active bundle, its compatibility, and its copy identifier.
        guard let context = ReleaseContext(
            device: device,
            approvedConfiguration: entry.id,
            capabilityManifestID: manifest.id,
            compiledCapabilities: composition.capabilities
        ) else {
            // Unreachable through `CompiledCapabilityComposition`, which requires pixel
            // analysis. Kept as a refusal rather than a force-unwrap: a build with no
            // evidence capability is not a runnable configuration.
            throw .capabilitySetMismatch(
                approved: manifest.compiledCapabilities.map(\.rawValue).sorted(),
                compiled: composition.capabilities.map(\.rawValue).sorted()
            )
        }
        let bundle = try await activeBundle(bundles, context: context, manifest: manifest)
        try requireBundle(
            bundle,
            context: context,
            entry: entry,
            manifest: manifest,
            configuration: configuration
        )

        // Step 4. Validate the lifecycle policy and this target's Resource Budget.
        //
        // Completeness of a budget and of a validation plan belongs to their own
        // validators. What this step owns is the binding: the budget governing this
        // process is the one for *this* target, and the plan that measured it is the one
        // the matched entry's evidence was produced under (Requirements 11.1 and 15.9).
        try requireApproval(
            configuration.lifecyclePolicy.approval,
            field: "lifecyclePolicy.approval"
        )
        try requireApproval(
            configuration.verdictCopyCatalog.approval,
            field: "verdictCopyCatalog.approval"
        )
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

        // Step 5. Remove abandoned session data before accepting any new input.
        let receipts = try await removeAbandonedData(cleanup, configuration: configuration)

        // Step 6. Confirm the module graph is the one the manifest describes.
        try requireCapabilityComposition(manifest)
        if let fusion = configuration.fusionRule {
            try requireApproval(fusion.approval, field: "fusionRule.approval")
            // One release binds one Release Fixture Suite version (Requirement 13.17),
            // so the suite that demonstrated all 15 fusion dispositions is the suite the
            // device gates ran against. Two versions here means the fusion approval and
            // the device evidence describe different releases (Requirement 13.20).
            try requireIdentity(
                fusion.fixtureSuite,
                matches: entry.versionTuple.fixtureSuite,
                field: "fusionRule.fixtureSuite"
            )
        }
        if let provenance = configuration.provenancePolicy {
            // Requirement 6.1: the Provenance Feasibility Gate is evaluated before the
            // capability is enabled. A policy exists whether or not that gate passed, so
            // a rejected feasibility decision has to block the capability here rather
            // than being read as approval by the policy's mere presence.
            try requireApproval(
                provenance.feasibilityApproval,
                field: "provenancePolicy.feasibilityApproval"
            )
        }

        // Step 7. Only now does ingest become reachable.
        return ReleaseAdmission(
            context: context,
            configuration: configuration,
            approvedConfiguration: entry,
            bundle: bundle,
            target: target,
            startupCleanup: receipts
        )
    }
}

// MARK: - Step 2: artifacts and the device match

extension StartupPreflight {
    private func loadConfiguration(
        _ policies: some PolicyArtifactReading
    ) async throws(PreflightFailure) -> ReleaseConfiguration {
        do {
            return try await ReleaseConfiguration.load(
                capabilityManifest: capabilityManifest,
                verdictCopyCatalog: verdictCopyCatalog,
                from: policies
            )
        } catch {
            throw .artifactUnavailable(error)
        }
    }

    /// The one entry matching this device exactly, with every gate satisfied.
    ///
    /// Matching is on the exact hardware identifier, the exact operating-system version,
    /// and the exact application build. Never on device family, marketing name, chip
    /// generation, or an inference from capabilities: an unlisted iPhone is unlisted even
    /// when a listed sibling would pass (Requirements 1.3 and 13.1).
    private func matchAllowlistEntry(
        _ policies: some PolicyArtifactReading,
        manifest: ReleaseCapabilityManifest
    ) async throws(PreflightFailure) -> (
        allowlist: ReleaseApprovedDeviceAllowlist,
        entry: ApprovedDeviceConfiguration
    ) {
        let allowlistID = manifest.approvedConfigurationAllowlist
        let allowlist: ReleaseApprovedDeviceAllowlist
        do {
            allowlist = try await policies.deviceAllowlist(allowlistID)
        } catch {
            throw .artifactUnavailable(error)
        }
        guard allowlist.id == allowlistID else {
            throw .artifactUnavailable(
                .identifierMismatch(requested: allowlistID, found: allowlist.id)
            )
        }
        try requireApproval(allowlist.approval, field: "deviceAllowlist.approval")

        // Requirement 13.22, checked before the device match so "nothing is approved for
        // distribution" is not reported as "this device is not approved".
        guard allowlist.permitsDistribution else {
            throw .allowlistApprovesNoConfiguration(allowlist: allowlist.id)
        }
        guard let entry = allowlist.entry(
            hardwareIdentifier: device.hardwareIdentifier,
            osVersion: device.osVersion,
            appBuild: device.appBuild
        ) else {
            throw .deviceNotAllowlisted(
                hardwareIdentifier: device.hardwareIdentifier,
                osVersion: device.osVersion,
                appBuild: device.appBuild
            )
        }
        // Membership is not approval. An entry can exist with a failed or unexecuted
        // mandatory gate, and it is not distributable (Requirements 13.19 and 13.21).
        let unsatisfied = entry.unsatisfiedGates
        guard unsatisfied.isEmpty else {
            throw .unsatisfiedDeviceGates(
                configuration: entry.id,
                gates: unsatisfied.sorted { $0.rawValue < $1.rawValue }
            )
        }
        return (allowlist, entry)
    }

    /// Requires every entry bound to this manifest to name one fixture suite and one
    /// validation plan.
    ///
    /// A shipping build binds no fixture suite of its own — fixtures are nonshipping
    /// release evidence, so there is no runtime value to compare the matched entry's
    /// against. What is checkable at runtime is that the signed allowlist does not mix
    /// versions across the entries for *this* build: two fixture-suite or plan versions
    /// under one manifest means the gate evidence was pooled across releases, which
    /// Requirement 13.20 excludes. The full comparison against the recorded device
    /// results belongs to release-record assembly.
    ///
    /// Runs after the matched entry is shown to name this manifest, so the sibling set is
    /// nonempty and the comparison is over entries that describe the same build.
    private func requireCoherentEntries(
        _ allowlist: ReleaseApprovedDeviceAllowlist,
        manifest: ReleaseCapabilityManifest
    ) throws(PreflightFailure) {
        let siblings = allowlist.entries.filter {
            $0.versionTuple.capabilityManifest == manifest.id
        }
        let suites = Set(siblings.map(\.versionTuple.fixtureSuite.rawValue))
        guard suites.count <= 1 else {
            throw .mixedAllowlistVersions(
                field: "deviceAllowlist.entries.versionTuple.fixtureSuite",
                values: suites.sorted()
            )
        }
        let plans = Set(siblings.map(\.versionTuple.validationPlan.rawValue))
        guard plans.count <= 1 else {
            throw .mixedAllowlistVersions(
                field: "deviceAllowlist.entries.versionTuple.validationPlan",
                values: plans.sorted()
            )
        }
    }

    /// Requires the matched entry's version tuple to be exactly this build's.
    ///
    /// Every element of the tuple participates: the manifest version, the capability set,
    /// the per-capability implementation versions, the Model Bundle, and the Device
    /// Validation Plan. The capability set and versions are compared against *both* the
    /// signed manifest and the compiled composition, so evidence produced under a
    /// different capability set cannot admit this build (Requirements 13.17 and 13.18).
    private func requireVersionTuple(
        _ tuple: ValidationVersionTuple,
        manifest: ReleaseCapabilityManifest,
        configuration: ReleaseConfiguration
    ) throws(PreflightFailure) {
        try requireIdentity(
            tuple.capabilityManifest,
            matches: manifest.id,
            field: "allowlistEntry.versionTuple.capabilityManifest"
        )
        guard tuple.capabilities == manifest.compiledCapabilities else {
            throw .capabilitySetMismatch(
                approved: manifest.compiledCapabilities.map(\.rawValue).sorted(),
                compiled: tuple.capabilities.map(\.rawValue).sorted()
            )
        }
        guard tuple.capabilities == composition.capabilities else {
            throw .capabilitySetMismatch(
                approved: tuple.capabilities.map(\.rawValue).sorted(),
                compiled: composition.capabilities.map(\.rawValue).sorted()
            )
        }
        let approvedVersions = Set(manifest.implementationVersions)
        guard Set(tuple.capabilityImplementationVersions) == approvedVersions else {
            throw .capabilitySetMismatch(
                approved: Self.describe(approvedVersions),
                compiled: Self.describe(Set(tuple.capabilityImplementationVersions))
            )
        }
        guard composition.versionSet == approvedVersions else {
            throw .capabilitySetMismatch(
                approved: Self.describe(approvedVersions),
                compiled: Self.describe(composition.versionSet)
            )
        }
        guard manifest.approvedBundleCatalog.contains(tuple.modelBundle) else {
            throw .identityMismatch(
                field: "allowlistEntry.versionTuple.modelBundle",
                expected: "one of \(manifest.approvedBundleCatalog.map(\.rawValue).sorted())",
                found: tuple.modelBundle.rawValue
            )
        }
        try requireIdentity(
            configuration.resourceBudgets.mainApplication.validationPlan,
            matches: tuple.validationPlan,
            field: "resourceBudgets.mainApplication.validationPlan"
        )
    }
}

// MARK: - Step 3: the active Model Bundle

extension StartupPreflight {
    /// The verified active bundle, activating the embedded one when nothing is active.
    ///
    /// The port reports one fault for "nothing is active" and for "what is active is not
    /// usable here", so both take the same path: verify and activate the app-delivered
    /// bundle through the identical local verification path. Activation is atomic and
    /// leaves the previous bundle untouched on failure, so a failed attempt cannot leave
    /// a half-activated tuple behind (Requirements 10.13, 10.16, and 10.17).
    private func activeBundle(
        _ bundles: some ModelBundleManaging,
        context: ReleaseContext,
        manifest: ReleaseCapabilityManifest
    ) async throws(PreflightFailure) -> BoundModelBundle {
        if let active = try? await bundles.verifiedActiveBundle(for: context) {
            return active
        }
        guard manifest.approvedBundleCatalog.contains(embeddedBundle) else {
            throw .identityMismatch(
                field: "preflight.embeddedBundle",
                expected: "one of \(manifest.approvedBundleCatalog.map(\.rawValue).sorted())",
                found: embeddedBundle.rawValue
            )
        }
        do {
            return try await bundles.activateLocalCandidate(embeddedBundle, context: context)
        } catch {
            // The fault is deliberately not carried forward: see
            // `PreflightFailure.verifiedBundleUnavailable`.
            throw .verifiedBundleUnavailable(expected: embeddedBundle)
        }
    }

    /// Requires the bound bundle to be the approved one and to agree with the policies.
    ///
    /// The component versions inside a bundle and the policy artifacts the build reads
    /// are two independently signed statements about the same release. If they disagree,
    /// the model was calibrated and described against different policies than the ones
    /// governing this process (Requirements 10.7, 10.9, and 10.11).
    private func requireBundle(
        _ bundle: BoundModelBundle,
        context: ReleaseContext,
        entry: ApprovedDeviceConfiguration,
        manifest: ReleaseCapabilityManifest,
        configuration: ReleaseConfiguration
    ) throws(PreflightFailure) {
        try requireIdentity(
            bundle.bundleID,
            matches: entry.versionTuple.modelBundle,
            field: "activeBundle.bundleID"
        )
        guard manifest.approvedBundleCatalog.contains(bundle.bundleID) else {
            throw .identityMismatch(
                field: "activeBundle.bundleID",
                expected: "one of \(manifest.approvedBundleCatalog.map(\.rawValue).sorted())",
                found: bundle.bundleID.rawValue
            )
        }
        // The port reverifies compatibility and integrity; asserting both here means an
        // adapter that forgets to cannot admit an unusable bundle. The context is the
        // observed one, which is safe because the allowlist lookup already required the
        // entry's hardware identifier, operating-system version, and build to be exactly
        // these values.
        //
        // `BoundModelBundle` is constructible only from a receipt whose signature and
        // self-test both passed, and the integrity vocabulary has one member, so the
        // status check is structurally satisfied today. It is written out anyway: it is
        // the condition Requirement 10.14 depends on, and a later vocabulary that gains a
        // second member should fail here rather than silently admit it.
        guard bundle.isCompatible(with: context), bundle.integrity.status == .verified else {
            throw .verifiedBundleUnavailable(expected: bundle.bundleID)
        }
        let components = bundle.componentVersions
        try requireIdentity(
            components.preprocessingContract,
            matches: configuration.preprocessingContract.id,
            field: "activeBundle.componentVersions.preprocessingContract"
        )
        try requireIdentity(
            components.calibrationPolicy,
            matches: configuration.calibrationPolicy.id,
            field: "activeBundle.componentVersions.calibrationPolicy"
        )
        try requireIdentity(
            components.verdictCopyCompatibility,
            matches: configuration.verdictCopyCatalog.compatibilityID,
            field: "activeBundle.componentVersions.verdictCopyCompatibility"
        )
    }
}

// MARK: - Step 5: startup cleanup

extension StartupPreflight {
    /// Removes abandoned material under the bound policy and checks the receipts.
    ///
    /// A store failure blocks ingest rather than being reported as an analysis outcome:
    /// unremoved bytes from an interrupted session are a privacy failure, and continuing
    /// past one would accept new work with analyzable material still on disk
    /// (Requirements 9.9 and 11.16).
    private func removeAbandonedData(
        _ cleanup: some SessionDataDeleting,
        configuration: ReleaseConfiguration
    ) async throws(PreflightFailure) -> [SessionDeletionReceipt] {
        let policy = configuration.lifecyclePolicy
        let receipts: [SessionDeletionReceipt]
        do {
            receipts = try await cleanup.deleteAbandonedData(policy: policy)
        } catch {
            throw .startupCleanupFailed(error)
        }
        for receipt in receipts {
            try requireIdentity(
                receipt.lifecyclePolicyID,
                matches: policy.id,
                field: "startupCleanup.receipt.lifecyclePolicyID"
            )
            guard receipt.reason == .abandoned else {
                throw .identityMismatch(
                    field: "startupCleanup.receipt.reason",
                    expected: SessionCleanupReason.abandoned.rawValue,
                    found: receipt.reason.rawValue
                )
            }
            let deadline = policy.deadline(for: .abandoned)
            guard receipt.deadline == deadline else {
                throw .identityMismatch(
                    field: "startupCleanup.receipt.deadline",
                    expected: "\(deadline.milliseconds) ms",
                    found: "\(receipt.deadline.milliseconds) ms"
                )
            }
        }
        return receipts
    }
}

// MARK: - Step 6: the module graph against the manifest

extension StartupPreflight {
    /// Requires the compiled composition to be exactly what the manifest approves.
    ///
    /// Set *equality*, not containment. A build with an extra compiled capability is as
    /// wrong as one missing an approved capability: its gate evidence was produced for a
    /// different capability set (Requirements 6.2 and 13.20).
    ///
    /// The linkage check is separate and bidirectional, because the failure the design
    /// names is not about a declared set at all: a provenance-enabled manifest with no
    /// linked validator cannot do what it claims, and a pixel-only manifest whose graph
    /// can still instantiate a validator ships code that must never run
    /// (Requirements 6.3, 6.19, and 6.20).
    private func requireCapabilityComposition(
        _ manifest: ReleaseCapabilityManifest
    ) throws(PreflightFailure) {
        guard composition.capabilities == manifest.compiledCapabilities else {
            throw .capabilitySetMismatch(
                approved: manifest.compiledCapabilities.map(\.rawValue).sorted(),
                compiled: composition.capabilities.map(\.rawValue).sorted()
            )
        }
        guard composition.versionSet == Set(manifest.implementationVersions) else {
            throw .capabilitySetMismatch(
                approved: Self.describe(Set(manifest.implementationVersions)),
                compiled: Self.describe(composition.versionSet)
            )
        }
        guard composition.linksContentCredentialValidator == manifest.enablesProvenance else {
            throw .provenanceLinkageMismatch(
                manifestEnablesProvenance: manifest.enablesProvenance,
                linksValidator: composition.linksContentCredentialValidator
            )
        }
    }
}

// MARK: - Shared comparisons

extension StartupPreflight {
    private func requireIdentity(
        _ found: some CanonicalIdentifier,
        matches expected: some CanonicalIdentifier,
        field: String
    ) throws(PreflightFailure) {
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
    ) throws(PreflightFailure) {
        guard found == expected else {
            throw .identityMismatch(field: field, expected: expected, found: found)
        }
    }

    private func requireApproval(
        _ record: ApprovalRecord,
        field: String
    ) throws(PreflightFailure) {
        guard record.isApproved else {
            throw .unapprovedArtifact(field: field, decision: record.decision)
        }
    }

    /// Implementation versions as sorted `capability@version` strings, for reporting.
    private static func describe(_ versions: Set<CapabilityImplementationEntry>) -> [String] {
        versions.map { "\($0.capability.rawValue)@\($0.version.description)" }.sorted()
    }
}
