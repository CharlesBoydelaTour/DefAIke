// The Model Bundle port.
//
// The manager recognizes only locally installed artifacts delivered inside an
// application version or retained as an already app-delivered rollback candidate. There
// is no discovery, fetch, download, or update-check member in this port, and none in the
// production dependency graph, so "no model-update network request" is visible in the
// interface rather than asserted in a comment (Requirements 10.19 and 10.21).

/// What the running build is, for bundle compatibility and gate evaluation.
///
/// Every field is an exact identity the startup preflight matches, never a range or a
/// "minimum" the app could satisfy loosely (Requirements 13.18 through 13.21).
public struct ReleaseContext: Hashable, Sendable {
    /// The device and build this process is running as.
    public let device: DeviceContext

    /// The allowlist entry this device matched. Membership is not approval: the entry's
    /// gates still have to be satisfied.
    public let approvedConfiguration: ApprovedConfigurationID

    /// The signed capability manifest version bound to this build.
    public let capabilityManifestID: ArtifactID

    /// Capabilities actually compiled into this build, as a fact about its module graph.
    ///
    /// Compared against the signed manifest by preflight; a disagreement fails closed
    /// (Requirements 6.2 and 6.3).
    public let compiledCapabilities: Set<CapabilityID>

    /// Creates a context, or `nil` when pixel analysis is absent.
    ///
    /// Pixel analysis is the required Version 1 evidence capability, so a build without
    /// it is not a runnable configuration.
    public init?(
        device: DeviceContext,
        approvedConfiguration: ApprovedConfigurationID,
        capabilityManifestID: ArtifactID,
        compiledCapabilities: Set<CapabilityID>
    ) {
        guard compiledCapabilities.contains(.pixelAnalysis) else { return nil }
        self.device = device
        self.approvedConfiguration = approvedConfiguration
        self.capabilityManifestID = capabilityManifestID
        self.compiledCapabilities = compiledCapabilities
    }

    /// Whether this build links a Content Credential validator.
    public var compilesProvenance: Bool {
        compiledCapabilities.contains(.contentCredentialValidation)
    }
}

/// A verified, activated Model Bundle a session may bind.
///
/// Constructible only from a **bindable** activation receipt, so an unverified,
/// partially verified, or failed candidate is not representable: `signatureOutcome` and
/// `selfTestOutcome` must both have passed, and a missing result is not a pass
/// (Requirements 10.12 and 10.14).
public struct BoundModelBundle: Hashable, Sendable {
    /// The signed manifest that was verified.
    public let manifest: ModelBundleManifest

    /// The bounded integrity projection a session binding and report carry.
    public let integrity: VerifiedBundleIntegrity

    /// Which activation produced this bundle, so two activations are distinguishable.
    public let activationGeneration: PositiveCount

    /// Creates a bound bundle from a manifest and the receipt that verified it, or
    /// `nil` when the two do not describe the same successfully verified bundle.
    ///
    /// Rejects a receipt for a different bundle, a receipt whose signature or self-test
    /// did not pass, and a digest inventory that is empty or names a path twice.
    public init?(manifest: ModelBundleManifest, receipt: ActivationReceipt) {
        guard receipt.bundleID == manifest.bundleID else { return nil }
        guard receipt.isBindable else { return nil }
        guard let integrity = VerifiedBundleIntegrity(
            status: .verified,
            activationReceiptID: receipt.id,
            verificationPolicyID: receipt.verificationPolicy,
            verifiedManifestDigest: receipt.verifiedManifestDigest,
            verifiedArtifactDigests: receipt.verifiedArtifactDigests
        ) else {
            return nil
        }
        self.manifest = manifest
        self.integrity = integrity
        self.activationGeneration = receipt.activationGeneration
    }

    public var bundleID: ModelBundleID { manifest.bundleID }

    public var modelIdentity: ModelIdentity { manifest.modelIdentity }

    /// The six component versions a session binds as one tuple (Requirement 10.7).
    public var componentVersions: BundleComponentVersions { manifest.componentVersions }

    /// Whether this bundle may activate under `context`.
    ///
    /// Exact build membership, capability superset, and operating-system minimum. All
    /// three, every time: a compatible build with a missing required capability is not
    /// compatible (Requirement 10.11).
    public func isCompatible(with context: ReleaseContext) -> Bool {
        manifest.compatibility.compatibleAppBuilds.contains(context.device.appBuild)
            && manifest.compatibility.requiredCapabilities
                .isSubset(of: context.compiledCapabilities)
            && context.device.osVersion >= manifest.compatibility.minimumOS
    }
}

/// Verifies, activates, reports, and rolls back locally installed Model Bundles.
///
/// Activation and rollback run the identical local verification path — "prior" does not
/// imply trusted — and both are atomic: an observer sees either the complete old tuple
/// or the complete new one, never a mixture. Every failure leaves the previous active
/// pointer and loaded bundle unchanged (Requirements 10.12, 10.13, 10.16, and 10.17).
public protocol ModelBundleManaging: Sendable {
    /// The currently active bundle, reverified as compatible with `context`.
    ///
    /// Fails with `.analysis(.modelLoadError, stage: .modelLoad)` when no verified
    /// compatible bundle is active. It never falls back to an older or unverified asset
    /// (Requirement 10.19).
    func verifiedActiveBundle(
        for context: ReleaseContext
    ) async throws(AnalysisFault) -> BoundModelBundle

    /// Verifies a locally installed candidate and atomically makes it active.
    ///
    /// `id` names an artifact already present on the device. There is no URL, no
    /// download, and no remote catalogue.
    func activateLocalCandidate(
        _ id: ModelBundleID,
        context: ReleaseContext
    ) async throws(AnalysisFault) -> BoundModelBundle

    /// Re-verifies a retained app-delivered bundle through the same path and makes it
    /// active.
    func rollback(
        to id: ModelBundleID,
        context: ReleaseContext
    ) async throws(AnalysisFault) -> BoundModelBundle
}
