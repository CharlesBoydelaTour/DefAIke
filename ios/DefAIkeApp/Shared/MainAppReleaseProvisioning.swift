import DefAIkeDomain
import DefAIkeModelBundle
import DefAIkeSharedTransfer
import Foundation

// Everything the composition root must be given, and the honest statement that it is not.
//
// The startup preflight compares; it never invents. That rule reaches all the way out to
// this file: the identifiers the gate reads, the store it reads them from, the layout that
// locates the compiled model, and the record the disclosure screens quote are all externally
// approved, versioned inputs. None of them has a default here, and none is derived from a
// build setting that happens to be set locally.
//
// So this file has two halves:
//
//   * `MainAppReleaseProvisioning` is the complete set of inputs, as one immutable value.
//     Constructing one is the release build's job.
//   * `UnprovisionedReleaseInput` is the closed vocabulary of inputs this repository does
//     not carry yet. `MainAppReleaseProvisioning.installed(...)` reports them, and the
//     composition root turns that report into a startup refusal that keeps ingest closed.
//
// A gap list is not a failure to implement the graph. The graph is assembled in
// `MainAppComposition.swift` and is complete; what is missing is the signed input set a
// distributed build carries, and the requirements are explicit that a missing approved
// artifact blocks rather than defaults (Requirements 10.8, 14.1, and 14.15).

// MARK: - The provisioned input set

/// The release-controlled inputs the main application's composition root needs.
///
/// Every field is supplied. There is no member with a default, no member derived from
/// another, and no member this type can compute: each one is either a signed artifact, an
/// identifier naming one, or a location one is installed at.
struct MainAppReleaseProvisioning: Sendable {

    /// The embedded signed Release Capability Manifest version.
    ///
    /// The root of the reference graph every other identifier the gate reads is derived
    /// from.
    let capabilityManifest: ArtifactID

    /// The Approved Verdict Copy catalogue shipped with this build.
    ///
    /// Named separately from the manifest's copy *compatibility* identifier: locating the
    /// catalogue stays separate from approving it (Requirement 8.1).
    let verdictCopyCatalog: ArtifactID

    /// The app-delivered Model Bundle this build embeds.
    ///
    /// An identifier for an artifact already inside the application version. There is no
    /// URL, no download, and no remote catalogue (Requirements 10.19 through 10.21).
    let embeddedBundle: ModelBundleID

    /// The registered App Group container identifier both processes share.
    let appGroup: String

    /// Exactly one implementation version per compiled capability.
    ///
    /// Supplied by the release build rather than written as a source literal, because the
    /// startup gate requires set equality against the signed manifest and a source constant
    /// would be a version claim this repository cannot make. The compiled composition
    /// contributes the capability set and the linkage fact; the versions come from here.
    let capabilityImplementationVersions: [CapabilityImplementationEntry]

    /// The signed policy artifacts, read by exact identifier.
    let policies: any PolicyArtifactReading

    /// How iOS data protection is applied to every byte a session retains.
    ///
    /// Supplied rather than defaulted, for the same reason every other member here is: which
    /// applier the composition root uses decides whether Requirement 9.6 holds for this build,
    /// and a default would make that decision invisible. A release build supplies
    /// `PlatformDataProtection()`, which applies the level the signed Extension Execution Policy
    /// names and then verifies it read back, refusing when it did not.
    ///
    /// It is a platform collaborator rather than a signed artifact, so it is not one of the
    /// `UnprovisionedReleaseInput` gaps: there is nothing to approve, only a platform to ask.
    let protection: any DataProtectionApplying

    /// The Model Bundle manager, over its approved verification collaborators.
    let bundles: any ModelBundleManaging

    /// The approved layout naming each bundle artifact's canonical relative path.
    let bundleLayout: ApprovedBundleLayout

    /// Where the embedded bundle's declared relative paths resolve against.
    let installedBundleRoot: URL

    /// The approved release evidence a Calibration Policy's references may resolve to.
    ///
    /// Required rather than optional: without an index no policy can be activated at all,
    /// which is Requirement 5.12 as a construction rule.
    let evidenceIndex: ReleaseEvidenceIndex

    /// The immutable fixture suite used to validate a bound Evidence Fusion Rule.
    /// A build with no fusion rule supplies `nil`.
    let fusionFixtures: ReleaseFixtureSuite?

    /// The auditable record carrying the externally supplied disclosures the
    /// model-information and correction-channel screens quote (Requirements 8.17, 14.9,
    /// and 14.14).
    let release: ReleaseReadinessRecord
}

// MARK: - What this repository does not carry

/// One release-controlled input a distributed build must carry and this repository does not.
///
/// A closed, enumerable vocabulary, in the shape the presentation layer's four gap
/// vocabularies already use: recording a gap as a value is what lets a release audit
/// enumerate what is still owed instead of discovering it at launch.
///
/// None of these is an `AnalysisError`. A build that cannot assemble its provisioning has no
/// Analysis Session, no stage, and nothing to report an evidence outcome about; ingest is
/// simply never exposed (design, error taxonomy).
///
/// Closing a gap is a release-artifact and packaging change. It is not a change to this file.
enum UnprovisionedReleaseInput: String, Hashable, Sendable, CaseIterable, CustomStringConvertible {
    /// No distributed application build identity is recorded in Info.plist.
    ///
    /// `CFBundleVersion` is `0` and `CFBundleShortVersionString` is `0.0.0` in this
    /// repository. Both are local development stand-ins, and reading either as the build
    /// identity would manufacture an `AppBuildID` no allowlist entry can legitimately name.
    case applicationBuildIdentity = "application-build-identity"

    /// The running hardware identifier or operating-system version could not be observed.
    case observedDeviceIdentity = "observed-device-identity"

    /// No embedded signed Release Capability Manifest identifier is recorded.
    case capabilityManifestIdentifier = "capability-manifest-identifier"

    /// No Approved Verdict Copy catalogue artifact identifier is recorded.
    case verdictCopyCatalogIdentifier = "verdict-copy-catalog-identifier"

    /// No embedded Model Bundle identifier is recorded.
    case embeddedModelBundleIdentifier = "embedded-model-bundle-identifier"

    /// No registered App Group container identifier is recorded.
    case appGroupIdentifier = "app-group-identifier"

    /// No per-capability implementation versions are recorded.
    case capabilityImplementationVersions = "capability-implementation-versions"

    /// No signed policy artifact store is installed.
    ///
    /// `PolicyArtifactReading` has no shipping adapter in this repository: the only
    /// implementation is the nonshipping in-memory test store. Until one exists, every
    /// signed policy read fails and the startup gate refuses at its second step.
    case policyArtifactStore = "policy-artifact-store"

    /// No Model Bundle verification collaborators are installed.
    ///
    /// `ModelBundleActivator` requires bundle content reading, signature verification, a
    /// self-test executor, and an activation record store. None has a shipping adapter, so
    /// no candidate bundle can be verified or activated.
    case modelBundleVerification = "model-bundle-verification"

    /// No approved bundle layout artifact is installed, so the compiled model's declared
    /// path cannot be resolved.
    case approvedBundleLayout = "approved-bundle-layout"

    /// No approved release evidence index is installed, so no Calibration Policy can be
    /// activated (Requirement 5.12).
    case releaseEvidenceIndex = "release-evidence-index"

    /// No Release Readiness Record is installed.
    ///
    /// The record is read through `ReleaseEvidenceReading`, which is nonshipping by design,
    /// so a distributed build has to carry the record as an embedded provisioned artifact.
    /// Until it does, the four disclosure destinations cannot be projected.
    case releaseReadinessRecord = "release-readiness-record"

    var description: String { rawValue }
}

/// The complete set of release-controlled inputs this build does not carry.
///
/// A set rather than a single value, because a build with no provisioning is missing several at
/// once and a release audit needs the whole list rather than whichever one was checked first.
struct UnprovisionedRelease: Error, Hashable, Sendable {
    let inputs: [UnprovisionedReleaseInput]
}

// MARK: - Reading what is installed

extension MainAppReleaseProvisioning {

    /// Info.plist keys the release build populates.
    ///
    /// Separate from `CFBundle*` on purpose: these name release-controlled decisions, and a
    /// build-configuration convenience value must never stand in for one.
    enum InfoKey {
        static let capabilityManifest = "DefAIkeCapabilityManifestID"
        static let verdictCopyCatalog = "DefAIkeVerdictCopyCatalogID"
        static let embeddedBundle = "DefAIkeEmbeddedModelBundleID"
        static let appGroup = "DefAIkeAppGroupID"
        static let implementationVersions = "DefAIkeCapabilityImplementationVersions"
    }

    /// The identifiers the running build records, or the ones it does not.
    ///
    /// Reads only. It creates no identifier, substitutes nothing, and treats an absent or
    /// noncanonical value as absent rather than repairing it.
    static func installedIdentifiers(
        bundle: Bundle = .main
    ) -> Result<InstalledIdentifiers, UnprovisionedRelease> {
        var gaps: [UnprovisionedReleaseInput] = []

        let manifest = ArtifactID(string(bundle, InfoKey.capabilityManifest) ?? "")
        if manifest == nil { gaps.append(.capabilityManifestIdentifier) }

        let catalog = ArtifactID(string(bundle, InfoKey.verdictCopyCatalog) ?? "")
        if catalog == nil { gaps.append(.verdictCopyCatalogIdentifier) }

        let embedded = ModelBundleID(string(bundle, InfoKey.embeddedBundle) ?? "")
        if embedded == nil { gaps.append(.embeddedModelBundleIdentifier) }

        // A build setting supplies this one, so an empty value means the setting was never
        // given a value rather than that the key is missing.
        let group = string(bundle, InfoKey.appGroup).flatMap { $0.isEmpty ? nil : $0 }
        if group == nil { gaps.append(.appGroupIdentifier) }

        let versions = implementationVersions(bundle)
        if versions == nil { gaps.append(.capabilityImplementationVersions) }

        guard let manifest, let catalog, let embedded, let group, let versions, gaps.isEmpty else {
            return .failure(UnprovisionedRelease(inputs: gaps))
        }
        return .success(
            InstalledIdentifiers(
                capabilityManifest: manifest,
                verdictCopyCatalog: catalog,
                embeddedBundle: embedded,
                appGroup: group,
                capabilityImplementationVersions: versions
            )
        )
    }

    /// The identifier half of the provisioning, read from the installed build.
    struct InstalledIdentifiers: Hashable, Sendable {
        let capabilityManifest: ArtifactID
        let verdictCopyCatalog: ArtifactID
        let embeddedBundle: ModelBundleID
        let appGroup: String
        let capabilityImplementationVersions: [CapabilityImplementationEntry]
    }

    /// Per-capability implementation versions, as a `capability` to `major.minor.patch` map.
    ///
    /// `nil` for an absent map, an empty map, an unrecognized capability, or a version that
    /// is not canonical. `0.0.0` is rejected by `SchemaSemanticVersion` itself, so the
    /// repository's local placeholder cannot become a recorded implementation version.
    private static func implementationVersions(
        _ bundle: Bundle
    ) -> [CapabilityImplementationEntry]? {
        guard let raw = bundle.object(forInfoDictionaryKey: InfoKey.implementationVersions)
            as? [String: String],
            !raw.isEmpty
        else {
            return nil
        }
        var entries: [CapabilityImplementationEntry] = []
        entries.reserveCapacity(raw.count)
        for (capabilityRaw, versionRaw) in raw {
            guard let capability = CapabilityID(capabilityRaw),
                let version = try? CapabilityImplementationVersion(validating: versionRaw)
            else {
                return nil
            }
            entries.append(CapabilityImplementationEntry(capability: capability, version: version))
        }
        return entries
    }

    private static func string(_ bundle: Bundle, _ key: String) -> String? {
        bundle.object(forInfoDictionaryKey: key) as? String
    }
}

// MARK: - The store that is not there

/// A `PolicyArtifactReading` for a build with no installed signed artifact store.
///
/// Every member reports `ReleaseArtifactError.storeUnavailable`, which is the port's own
/// vocabulary for exactly this condition. That is deliberate and it is not a stub standing in
/// for a reader: there is no path here that returns an artifact value, so no policy, budget,
/// deadline, boundary, allowlist entry, or trust rule can enter the build through it.
///
/// Its effect is the correct one. `StartupPreflight` fails at step 2 with
/// `PreflightFailure.artifactUnavailable(.storeUnavailable)`, ingest is never exposed, and no
/// `ReleaseAdmission` is ever constructed — so the analysis graph downstream of it is
/// unreachable rather than running against invented values.
///
/// Replacing it is `UnprovisionedReleaseInput.policyArtifactStore`: a reader over the embedded
/// signed artifact set, verified against the Bundle Verification Policy.
struct UnprovisionedPolicyArtifactStore: PolicyArtifactReading {

    func capabilityManifest(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> ReleaseCapabilityManifest {
        throw .storeUnavailable
    }

    func deviceAllowlist(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> ReleaseApprovedDeviceAllowlist {
        throw .storeUnavailable
    }

    func lifecyclePolicy(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> DataLifecyclePolicy {
        throw .storeUnavailable
    }

    func extensionExecutionPolicy(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> ExtensionExecutionPolicy {
        throw .storeUnavailable
    }

    func resourceBudgets(
        mainApplication: ArtifactID,
        shareExtension: ArtifactID
    ) async throws(ReleaseArtifactError) -> ResourceBudgetSet {
        throw .storeUnavailable
    }

    func bundleVerificationPolicy(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> BundleVerificationPolicy {
        throw .storeUnavailable
    }

    func preprocessingContract(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> PreprocessingContract {
        throw .storeUnavailable
    }

    func calibrationPolicy(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> CalibrationPolicy {
        throw .storeUnavailable
    }

    func verdictCopyCatalog(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> ApprovedVerdictCopyCatalog {
        throw .storeUnavailable
    }

    func provenancePolicy(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> ProvenancePolicy {
        throw .storeUnavailable
    }

    func fusionRule(
        _ id: ArtifactID
    ) async throws(ReleaseArtifactError) -> EvidenceFusionRule {
        throw .storeUnavailable
    }
}
