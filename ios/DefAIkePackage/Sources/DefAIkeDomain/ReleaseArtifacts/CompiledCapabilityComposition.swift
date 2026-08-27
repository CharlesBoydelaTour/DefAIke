// What the running build actually is, and why a startup gate refused it.
//
// The signed Release Capability Manifest states what a build is *approved* to do. This
// file holds the other half of that comparison: what the linked module graph can
// actually do, and the closed vocabulary a failed comparison reports.
//
// The two halves are kept as separate values on purpose. If the compiled composition
// were derived from the manifest, the manifest would be describing itself and
// Requirements 6.2 and 6.3 would be unenforceable — a pixel-only manifest that ships
// alongside a linked Content Credential validator would look correct. Keeping them
// apart makes the disagreement representable, which is the only way a gate can refuse
// it.

/// What one built application composition can do, as a fact about its module graph.
///
/// Every field is observed rather than declared by policy: the composition identifier
/// and capability set come from the compile-time composition the target was built as,
/// and ``linksContentCredentialValidator`` is whether a provenance validator type is
/// reachable at all. None of it is read from a signed artifact, because the whole point
/// is to have something independent to compare a signed artifact against.
///
/// Holding this value is never approval. A build that links a validator has not been
/// approved to enable Content Credential validation; that needs the Provenance
/// Feasibility Gate and an exact match against the signed manifest (Requirement 6.1).
public struct CompiledCapabilityComposition: Hashable, Sendable {
    /// The compile-time composition identifier, matching the one the manifest names.
    public let compositionIdentifier: ArtifactText

    /// Capabilities this build compiles. Always includes pixel analysis.
    public let capabilities: Set<CapabilityID>

    /// Exactly one implementation version per compiled capability.
    public let implementationVersions: [CapabilityImplementationEntry]

    /// Whether a Content Credential validator is linked and instantiable.
    ///
    /// Deliberately independent of ``capabilities``. A pixel-only composition that can
    /// still instantiate a validator, and a provenance composition that cannot, are
    /// both representable here and both fail preflight (design step 6).
    public let linksContentCredentialValidator: Bool

    /// Creates a composition, or `nil` when it is not a runnable build.
    ///
    /// Refuses a build with no pixel analysis, which is the required Version 1 evidence
    /// capability, and a version list that does not name each compiled capability
    /// exactly once. Neither is a gate decision: they are shapes a real module graph
    /// cannot have, so an inconsistent value never reaches the comparison.
    public init?(
        compositionIdentifier: ArtifactText,
        capabilities: Set<CapabilityID>,
        implementationVersions: [CapabilityImplementationEntry],
        linksContentCredentialValidator: Bool
    ) {
        guard capabilities.contains(.pixelAnalysis) else { return nil }
        var declared: Set<CapabilityID> = []
        for entry in implementationVersions {
            guard declared.insert(entry.capability).inserted else { return nil }
        }
        guard declared == capabilities else { return nil }

        self.compositionIdentifier = compositionIdentifier
        self.capabilities = capabilities
        self.implementationVersions = implementationVersions
        self.linksContentCredentialValidator = linksContentCredentialValidator
    }

    /// The implementation version for one capability, or `nil` when not compiled.
    public func implementationVersion(
        for capability: CapabilityID
    ) -> CapabilityImplementationVersion? {
        implementationVersions.first { $0.capability == capability }?.version
    }

    /// Whether this build compiles Content Credential validation as a capability.
    ///
    /// Separate from ``linksContentCredentialValidator``: this is what the composition
    /// claims, that is what its module graph permits.
    public var compilesProvenance: Bool {
        capabilities.contains(.contentCredentialValidation)
    }

    /// Implementation versions as a comparable, order-independent set.
    var versionSet: Set<CapabilityImplementationEntry> { Set(implementationVersions) }
}

// MARK: - Preflight failures

/// Why a mandatory startup gate refused to expose ingest.
///
/// Deliberately not an ``AnalysisError`` and deliberately not convertible into one. A
/// failed startup gate means no analysis ever began, so it has no stage, no session, and
/// no evidence to report; presenting one as an analysis outcome would be inventing a
/// user-facing evidence-error category the requirements do not define. Requirement 1.3
/// wants ingest unavailable, not a verdict that says so.
///
/// Every case names the exact field or entry that disagreed, so an audit can point at
/// one artifact position rather than reporting "preflight failed". `Equatable` rather
/// than `Hashable`, matching ``ArtifactSchemaError`` and ``ReleaseArtifactError``.
///
/// No case carries an allowlist entry, a candidate device configuration, or a bundle.
/// A failure describes what was refused; it never hands back a configuration value that
/// a caller could mistake for an approved one.
public enum PreflightFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// A required signed artifact was absent, malformed, or incoherent.
    case artifactUnavailable(ReleaseArtifactError)

    /// The signed allowlist approves no configuration at all (Requirement 13.22).
    ///
    /// Distinct from ``deviceNotAllowlisted``: nothing is distributable, whatever
    /// device this is.
    case allowlistApprovesNoConfiguration(allowlist: ArtifactID)

    /// No entry matches this exact hardware identifier, iOS version, and app build.
    ///
    /// The observed identity is reported so an audit can see what was refused. It is
    /// not a candidate entry, and nothing in this module turns it into one: a device
    /// absent from the signed allowlist stays absent (Requirements 1.3 and 13.1).
    case deviceNotAllowlisted(
        hardwareIdentifier: DeviceHardwareID,
        osVersion: PlatformVersion,
        appBuild: AppBuildID
    )

    /// The matched entry has mandatory gates that neither passed on a physical iPhone
    /// nor carry an approved inapplicability decision (Requirements 13.19 and 13.21).
    case unsatisfiedDeviceGates(configuration: ApprovedConfigurationID, gates: [DeviceGate])

    /// Two identities that must be the same version disagree.
    case identityMismatch(field: String, expected: String, found: String)

    /// An artifact this gate depends on carries a decision that is not an approval.
    ///
    /// Presence is not approval: a signed artifact with a rejected approval record is
    /// still a rejected release (Requirement 14.15).
    case unapprovedArtifact(field: String, decision: ApprovalDecision)

    /// Entries bound to this build's capability manifest disagree about a version the
    /// running build cannot resolve on its own (the runtime half of Requirement 13.20).
    case mixedAllowlistVersions(field: String, values: [String])

    /// The compiled capability set or its implementation versions differ from the
    /// signed manifest (Requirement 6.2).
    case capabilitySetMismatch(approved: [String], compiled: [String])

    /// The linked module graph and the manifest disagree about whether a Content
    /// Credential validator exists (Requirements 6.3, 6.19, and 6.20).
    ///
    /// Both directions fail: a provenance-enabled manifest with no linked validator,
    /// and a pixel-only manifest whose graph can still instantiate one.
    case provenanceLinkageMismatch(manifestEnablesProvenance: Bool, linksValidator: Bool)

    /// No verified compatible Model Bundle is active and none could be activated.
    ///
    /// The port's ``AnalysisFault`` is deliberately dropped rather than carried. At
    /// startup its only two possibilities — `model-load-error` and cancellation — mean
    /// the same thing, and embedding an ``AnalysisError`` in a startup failure is an
    /// invitation to report a failed gate as an evidence outcome
    /// (Requirements 10.16 and 10.19).
    case verifiedBundleUnavailable(expected: ModelBundleID)

    /// Startup privacy cleanup did not complete, so material from an interrupted or
    /// abandoned session may still exist (Requirements 9.9 and 11.16).
    case startupCleanupFailed(EphemeralStoreError)

    public var description: String {
        switch self {
        case let .artifactUnavailable(error):
            return "a required release artifact is unavailable: \(error)"
        case let .allowlistApprovesNoConfiguration(allowlist):
            return "allowlist \(allowlist.rawValue) approves no device configuration"
        case let .deviceNotAllowlisted(hardware, osVersion, appBuild):
            return """
                no allowlist entry matches \(hardware.rawValue) on iOS \(osVersion) \
                for build \(appBuild.rawValue)
                """
        case let .unsatisfiedDeviceGates(configuration, gates):
            return """
                allowlist entry \(configuration.rawValue) has unsatisfied gates \
                \(gates.map(\.rawValue).sorted())
                """
        case let .identityMismatch(field, expected, found):
            return "\(field) must be \(expected), found \(found)"
        case let .unapprovedArtifact(field, decision):
            return "\(field) carries the decision \(decision.rawValue) rather than an approval"
        case let .mixedAllowlistVersions(field, values):
            return "\(field) is recorded as more than one version: \(values.sorted())"
        case let .capabilitySetMismatch(approved, compiled):
            return """
                the compiled capability set \(compiled.sorted()) is not the approved set \
                \(approved.sorted())
                """
        case let .provenanceLinkageMismatch(manifestEnables, linksValidator):
            return manifestEnables
                ? "the manifest enables provenance but no validator is linked"
                : """
                    the manifest is pixel-only but a validator is \
                    \(linksValidator ? "linked" : "absent")
                    """
        case let .verifiedBundleUnavailable(expected):
            return "no verified compatible Model Bundle is active; \(expected.rawValue) failed"
        case let .startupCleanupFailed(error):
            return "startup privacy cleanup did not complete: \(error)"
        }
    }
}
