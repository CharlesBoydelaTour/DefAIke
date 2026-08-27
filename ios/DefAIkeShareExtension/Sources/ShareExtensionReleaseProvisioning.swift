import DefAIkeDomain
import DefAIkeSharedTransfer
import Foundation

// Everything the Share Extension's composition root must be given, and the honest statement
// that it is not.
//
// The same rule the main application's provisioning states applies here, for the same reason:
// the gate compares, it never invents. The extension needs fewer inputs than the app — it
// verifies no Model Bundle, activates no Calibration Policy, and locates no compiled model —
// but every input it does need is an externally approved, versioned artifact, and none of them
// has a default in this file.
//
// Two vocabularies live here, and they record different kinds of gap:
//
//   * `UnprovisionedExtensionReleaseInput` is a *release-controlled input this repository does
//     not carry*: an identifier the Release Process assigns, or a signed artifact store no
//     shipping adapter exists for. It is the extension's counterpart to the main app's
//     `UnprovisionedReleaseInput`, with the app-only entries (embedded Model Bundle, bundle
//     verification collaborators, approved bundle layout, release evidence index, release
//     readiness record, per-capability implementation versions) removed because the extension
//     genuinely does not need them.
//   * `UnapprovedShareExtensionSurface` is a *user-facing surface the closed Approved Verdict
//     Copy vocabulary does not define*. That is a different kind of blocker and it is not
//     closable by packaging: `VerdictCopySurface` has no case for a consent action, a manual
//     "Open DefAIke" instruction, or a pending-handoff recovery instruction, so the wording
//     for them cannot be approved without extending the vocabulary itself.
//
// Neither vocabulary is an `AnalysisError`. A build that cannot assemble its provisioning has
// no Analysis Session, no stage, and nothing to report an evidence outcome about; the handoff
// surface is simply never exposed.

// MARK: - The provisioned input set

/// The release-controlled inputs the Share Extension's composition root needs.
///
/// Every field is supplied. Nothing here has a default, is derived from another field, or is
/// computed from a build setting that happens to be set locally.
struct ShareExtensionReleaseProvisioning: Sendable {

    /// The embedded signed Release Capability Manifest version.
    ///
    /// The root of the reference graph. The extension reads it for the same reason the app
    /// does: every other identifier it needs — the Extension Execution Policy, the Data
    /// Lifecycle Policy, the Share Extension Resource Budget, the device allowlist — is named
    /// by the manifest rather than by a constant in this target.
    let capabilityManifest: ArtifactID

    /// The Approved Verdict Copy catalogue shipped with this build.
    ///
    /// Required even though the extension renders almost nothing: `ReleaseConfiguration`
    /// resolves the catalogue against the compatibility identifier the manifest names, and the
    /// consent action's wording has to come from an approved catalogue or not exist.
    let verdictCopyCatalog: ArtifactID

    /// The registered App Group container identifier both processes share.
    ///
    /// It must be byte-identical to the main application's. A mismatch is not a degraded
    /// handoff, it is two processes writing into two different containers, and the app would
    /// find an empty ready slot forever.
    let appGroup: String

    /// The signed policy artifacts, read by exact identifier.
    let policies: any PolicyArtifactReading
}

/// The approved copy keys the Share Extension's user-facing surfaces resolve through.
///
/// Four surfaces, each mandatory for a different reason:
///
///   * the visible consent action's label and the statement of what it covers, without which no
///     handoff may occur at all (Requirements 2.2 and 11.10);
///   * the explicit "Open DefAIke" instruction, because the share extension point cannot
///     launch the containing application and the handoff would otherwise appear to have done
///     nothing (design, fixed decision 4); and
///   * the recovery instruction shown when a consented handoff is already pending, because the
///     single ready-slot rule refuses to replace it silently.
///
/// Keys, never text. An English sentence compiled into this target would be unapproved
/// user-facing language wearing the shape of an approved one.
///
/// The only way to obtain a value is `resolve(from:resolver:)`, which reads the keys out of the
/// signed Approved Verdict Copy catalogue *and* requires each one to resolve to renderable text.
/// There is deliberately no memberwise initializer: a provisioning field carrying these keys
/// would let a release supply four strings the approved catalogue never covered, and "the
/// catalogue carries approved wording for this surface, and this build ships that wording" is
/// what makes a key safe to render.
///
/// The text travels beside the key rather than replacing it, so a screen can be audited back to
/// the catalogue entry it came from.
struct ApprovedShareExtensionCopy: Hashable, Sendable {
    let consentActionLabel: PresentableApprovedText
    let consentScopeStatement: PresentableApprovedText
    let manualOpenInstruction: PresentableApprovedText
    let pendingHandoffRecovery: PresentableApprovedText

    private init(
        consentActionLabel: PresentableApprovedText,
        consentScopeStatement: PresentableApprovedText,
        manualOpenInstruction: PresentableApprovedText,
        pendingHandoffRecovery: PresentableApprovedText
    ) {
        self.consentActionLabel = consentActionLabel
        self.consentScopeStatement = consentScopeStatement
        self.manualOpenInstruction = manualOpenInstruction
        self.pendingHandoffRecovery = pendingHandoffRecovery
    }

    /// Renderable approved wording for all four surfaces, or the surfaces that failed.
    ///
    /// Three independent things have to hold for a surface, and all three are checked:
    ///
    ///   1. the closed `VerdictCopySurface` vocabulary has to *name* the surface, so a catalogue
    ///      has somewhere to put an approved key for it;
    ///   2. the supplied catalogue has to carry a key under that name; and
    ///   3. the key has to resolve to text this build actually ships.
    ///
    /// Today every one of the four fails at step 1, and would then fail at step 3 as well. Step 1
    /// fails because `VerdictCopySurface` covers the three pixel labels and their explanations,
    /// the five provenance states, the unavailable lane, a Combined Summary, the inconsistency
    /// notice, each Analysis Error and its recovery action, the byte-preservation limitations, the
    /// screenshot explanation, the evidence scope, the false-result limitation, the privacy
    /// explanation, model information, and the correction channel — and nothing for any Share
    /// Extension surface. Step 3 fails because the shipped English String Catalog lives in
    /// `DefAIkePresentation`, which is deliberately absent from this target's module closure.
    ///
    /// So this returns a failure naming all four, and it will keep doing so until the vocabulary
    /// is extended and the wording is approved and shipped. That is the correct behaviour and not
    /// a placeholder: the alternative is wording a consent screen here, which would put an
    /// unapproved sentence in front of the one decision the user is entitled to make with their
    /// eyes open.
    static func resolve(
        from catalog: ApprovedVerdictCopyCatalog,
        resolver: some ShareExtensionCopyResolving
    ) -> Result<Self, UnapprovedHandoffCopy> {
        var missing: Set<UnapprovedShareExtensionSurface> = []
        var resolved: [UnapprovedShareExtensionSurface: PresentableApprovedText] = [:]

        for surface in Self.requiredSurfaces {
            guard let named = surface.verdictCopySurface,
                let key = catalog.localizationKey(for: named),
                let text = PresentableApprovedText(key: key, resolver: resolver)
            else {
                missing.insert(surface)
                continue
            }
            resolved[surface] = text
        }

        guard missing.isEmpty,
            let label = resolved[.consentActionLabel],
            let scope = resolved[.consentScopeStatement],
            let open = resolved[.manualOpenInstruction],
            let recovery = resolved[.pendingHandoffRecoveryInstruction]
        else {
            // A nonempty `missing` names exactly what failed. An empty one cannot happen while
            // every lookup above succeeded, and reporting the whole required set rather than
            // succeeding is the fail-closed answer to a state this function cannot reach.
            return .failure(
                UnapprovedHandoffCopy(
                    surfaces: missing.isEmpty ? Set(Self.requiredSurfaces) : missing
                )
            )
        }
        return .success(
            Self(
                consentActionLabel: label,
                consentScopeStatement: scope,
                manualOpenInstruction: open,
                pendingHandoffRecovery: recovery
            )
        )
    }

    /// The surfaces a handoff cannot proceed without.
    ///
    /// `UnapprovedShareExtensionSurface.handoffRefusalStatement` is deliberately absent: a
    /// refusal renders nothing at all, so a build with no approved refusal wording can still
    /// refuse honestly. The other four are on the path a *successful* handoff takes.
    static let requiredSurfaces: [UnapprovedShareExtensionSurface] = [
        .consentActionLabel,
        .consentScopeStatement,
        .manualOpenInstruction,
        .pendingHandoffRecoveryInstruction,
    ]

    /// The instruction value the transfer coordinator needs, carrying the approved key.
    ///
    /// `ManualOpenInstruction` holds a key rather than text for the same reason this type holds
    /// both: the domain never carries display text. Building it from a resolved surface means the
    /// key it carries is one this build can actually render.
    var manualOpen: ManualOpenInstruction {
        ManualOpenInstruction(copyKey: manualOpenInstruction.key)
    }
}

/// Approved wording this build can actually put on screen.
///
/// The type exists to make one thing unrepresentable: a user-facing string that is not an
/// approved catalogue entry. Its initializer takes a key and a resolver and returns `nil` when
/// the key has no value, so there is no path that produces presentable text from a literal, from
/// a localization key, or from a fallback.
///
/// It is deliberately not `DisplaySafeText`, whose own documentation says display-safe text "is
/// never a claim, a verdict, or approved copy": that type bounds attacker-influenced validator
/// output, and reusing it here would blur the distinction between text that is safe to show and
/// text that is approved to show.
struct PresentableApprovedText: Hashable, Sendable {
    /// The catalogue entry this text came from, so a screen can be audited back to it.
    let key: ApprovedCopyKey

    /// The resolved English value.
    let text: String

    /// Resolves `key`, or `nil` when this build ships no value for it.
    ///
    /// A resolver that returns the key itself is treated as a miss, not a value. That is the
    /// standard localization failure mode, and rendering it would put a raw key on screen.
    init?(key: ApprovedCopyKey, resolver: some ShareExtensionCopyResolving) {
        guard let resolved = resolver.text(for: key),
            !resolved.isEmpty,
            resolved != key.rawValue
        else {
            return nil
        }
        self.key = key
        self.text = resolved
    }
}

/// Resolves an approved copy key to the English value this build ships.
///
/// A port rather than a call, so the fail-closed path is exercisable and so this target does not
/// grow a localization lookup of its own.
protocol ShareExtensionCopyResolving: Sendable {
    /// The approved English value for `key`, or `nil` when this build ships none.
    func text(for key: ApprovedCopyKey) -> String?
}

/// A resolver for a target that ships no approved copy.
///
/// Every lookup returns `nil`. Not a stub: the shipped English String Catalog is a resource of
/// `DefAIkePresentation`, and that module is deliberately absent from this target's module
/// closure — see `ForbiddenExtensionModule.presentation`. Linking it to reach four strings would
/// pull SwiftUI screens, the report cards, and the evidence presentation into the extension, which
/// is the opposite of what the Extension Execution Policy is for.
///
/// Its effect is the correct one: `ApprovedShareExtensionCopy.resolve(from:resolver:)` reports
/// every surface as unresolved, the startup gate refuses, and no consent screen is presented.
///
/// Closing it does not mean linking the presentation module. It means the release supplying this
/// extension's own approved-copy resource, once the surfaces exist in `VerdictCopySurface` and
/// their wording is approved.
struct UnlocalizedShareExtensionCopy: ShareExtensionCopyResolving {
    func text(for key: ApprovedCopyKey) -> String? { nil }
}

// MARK: - What this repository does not carry

/// One release-controlled input a distributed Share Extension must carry and this repository
/// does not.
///
/// A closed, enumerable vocabulary. Recording a gap as a value is what lets a release audit
/// enumerate what is still owed instead of discovering it when a user taps Share.
///
/// Closing a gap is a release-artifact and packaging change. It is not a change to this file.
enum UnprovisionedExtensionReleaseInput: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    /// No distributed application build identity is recorded in the extension's Info.plist.
    ///
    /// The extension's `CFBundleVersion` is `0` and `CFBundleShortVersionString` is `0.0.0`,
    /// exactly as in the containing app. Reading either would manufacture an `AppBuildID` that
    /// no allowlist entry can legitimately name — and here it would additionally be stamped
    /// into every published ticket as `extensionBuildID`, which the claiming app compares
    /// against its own build identity (Requirement 2.19).
    case applicationBuildIdentity = "application-build-identity"

    /// The running hardware identifier or operating-system version could not be observed.
    case observedDeviceIdentity = "observed-device-identity"

    /// No embedded signed Release Capability Manifest identifier is recorded.
    case capabilityManifestIdentifier = "capability-manifest-identifier"

    /// No Approved Verdict Copy catalogue artifact identifier is recorded.
    case verdictCopyCatalogIdentifier = "verdict-copy-catalog-identifier"

    /// No registered App Group container identifier is recorded.
    ///
    /// Supplied by the target's `DEFAIKE_APP_GROUP_ID` build setting through Info.plist. An
    /// empty value means the setting was never given one.
    case appGroupIdentifier = "app-group-identifier"

    /// No signed policy artifact store is installed.
    ///
    /// `PolicyArtifactReading` has no shipping adapter anywhere in this repository — the only
    /// implementation is the nonshipping in-memory test store — so the Extension Execution
    /// Policy, the Data Lifecycle Policy, the Share Extension Resource Budget, and the device
    /// allowlist cannot be read at all. Without them there is no approved staged
    /// data-protection level, no approved cleanup deadline, and no approved encoded-input or
    /// temporary-storage ceiling, so nothing may be staged.
    case policyArtifactStore = "policy-artifact-store"

    var description: String { rawValue }
}

/// The complete set of release-controlled inputs this build does not carry.
///
/// A set rather than a single value, because a build with no provisioning is missing several at
/// once and a release audit needs the whole list rather than whichever one was checked first.
struct UnprovisionedExtensionRelease: Error, Hashable, Sendable {
    let inputs: [UnprovisionedExtensionReleaseInput]
}

/// The complete set of user-facing surfaces a successful handoff needs and this build cannot word.
///
/// A named type rather than a bare `Set`, so it can be the failure of a `Result` and so the reason
/// travels as one value: a build that can word none of the four and a build that can word three are
/// both blocked, and an audit needs to know which.
struct UnapprovedHandoffCopy: Error, Hashable, Sendable {
    let surfaces: Set<UnapprovedShareExtensionSurface>
}

// MARK: - Approved-copy surfaces this vocabulary does not define

/// A user-facing surface the Share Extension needs and the closed Approved Verdict Copy
/// vocabulary does not define.
///
/// The fifth such vocabulary in the repository, and the first outside the presentation layer.
/// It is separate rather than an extension of the four existing ones for a structural reason:
/// `DefAIkePresentation` is deliberately absent from this target's module closure — see
/// `ForbiddenExtensionModule.presentation` — so `UnapprovedViewStateSurface`,
/// `UnapprovedReportSurface`, `UnapprovedAccessibilitySurface`, and
/// `UnapprovedDisclosureSurface` are not reachable from here, and adding a case to one of them
/// would not make it reachable either.
///
/// Every case is a *surface*, never a sentence. Nothing in this target invents wording for one,
/// and nothing renders a localization key in place of one.
///
/// Closing a gap is a release-artifact change with an extra step the other four do not need:
/// `VerdictCopySurface` is a closed enumeration in `DefAIkeDomain`, so a new case has to be
/// added there first, then approved, then given a String Catalog value. It is not a change to
/// this file.
enum UnapprovedShareExtensionSurface: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    /// The visible consent action's own wording.
    ///
    /// The blocking one. Requirement 2.2 requires a visible user-consent action before the
    /// image is handed over, and Requirement 11.10 puts that requirement in the Extension
    /// Execution Policy. A consent action with no words is not a consent action: the user
    /// cannot know what is being agreed to. So this surface's absence keeps the handoff closed
    /// rather than producing a blank screen with a button on it.
    case consentActionLabel = "consent-action-label"

    /// The statement of what the consent action covers.
    ///
    /// The scope the consent screen has to state — that the exact available encoded bytes are
    /// handed to DefAIke, that no analysis happens in the extension, and that nothing leaves
    /// the device. Separate from the action's label because a label alone is not informed
    /// consent.
    case consentScopeStatement = "consent-scope-statement"

    /// The explicit "Open DefAIke" instruction shown after a successful handoff.
    ///
    /// `ManualOpenInstruction` already carries an `ApprovedCopyKey` rather than text, for this
    /// exact reason. The key has no approved value.
    case manualOpenInstruction = "manual-open-instruction"

    /// The label on the control that explicitly declines the handoff.
    ///
    /// Recorded but not blocking. `ShareConsentDecision` keeps `declined` and `cancelled` apart
    /// because refusing a handoff and dismissing a screen are different user acts, and Requirement
    /// 2.4 treats them identically: neither creates a session. With no approved decline wording the
    /// consent screen offers the system's own dismissal affordance, whose word is UIKit's rather
    /// than DefAIke's, and every non-consent path therefore reports `cancelled`.
    ///
    /// What is lost is the audit distinction, not the behaviour. That is why this surface's absence
    /// does not block the handoff the way `consentActionLabel`'s does.
    case consentDeclineActionLabel = "consent-decline-action-label"

    /// The instruction offered when a consented handoff is already pending.
    ///
    /// The single ready-slot rule's user-visible half: open or discard the pending handoff.
    case pendingHandoffRecoveryInstruction = "pending-handoff-recovery-instruction"

    /// Wording for a handoff the extension refused before any consent action.
    ///
    /// A refused activation, a startup refusal, and a resource breach all reach the user as
    /// "nothing happened". None has approved wording, which is why the blocked presentation
    /// renders no text at all and carries its cause in an accessibility identifier.
    case handoffRefusalStatement = "handoff-refusal-statement"

    var description: String { rawValue }

    /// The `VerdictCopySurface` case a catalogue would carry this surface's approved key under.
    ///
    /// `nil` for every case, and that is the finding rather than an omission. The mapping exists
    /// as a total function so the gap is a value a release audit can enumerate and a later
    /// vocabulary extension has exactly one place to land: give a case a non-`nil` answer here,
    /// and `ApprovedShareExtensionCopy.resolve(from:)` starts requiring the catalogue to carry
    /// an approved key for it.
    ///
    /// Written without a `default`, so adding a case to this vocabulary forces a decision about
    /// where its approved wording lives.
    var verdictCopySurface: VerdictCopySurface? {
        switch self {
        case .consentActionLabel:
            // Requirement 2.2's visible consent action. The closed vocabulary has no case for
            // any Share Extension surface at all — its scope is evidence, errors, limitations,
            // and the four disclosure destinations.
            return nil
        case .consentScopeStatement:
            // Closest existing case is `.privacyExplanation`, and it is not this: that surface is
            // the in-application privacy explanation the main app's disclosure destination shows
            // (Requirement 9.16), approved as a description of the whole application's
            // behaviour. Reusing it as the consent screen's scope statement would present
            // approved wording for one purpose as approved wording for another.
            return nil
        case .consentDeclineActionLabel:
            // Same absence as the action label. The system's dismissal affordance stands in, and it
            // is UIKit's word rather than an approved DefAIke string.
            return nil
        case .manualOpenInstruction:
            // Not an error recovery action. `.errorRecovery(.handoffError)` is the recovery
            // offered *after* a failed handoff; this is the instruction shown after a
            // *successful* one, and conflating them would tell a user their handoff failed.
            return nil
        case .pendingHandoffRecoveryInstruction:
            // Also not `.errorRecovery(.handoffError)`: a pending handoff is not an error, and
            // Requirement 11.17 requires every Analysis Error category to stay distinguishable
            // from every non-error terminal state.
            return nil
        case .handoffRefusalStatement:
            // A refused activation produces no Analysis Session, so it is not an Analysis Error
            // and `.analysisError(_:)` does not name it either.
            return nil
        }
    }
}

// MARK: - Reading what is installed

extension ShareExtensionReleaseProvisioning {

    /// Info.plist keys the release build populates.
    ///
    /// The same key names the containing application reads, deliberately: the two processes are
    /// one distributed build, and reading the App Group identifier or the manifest version from
    /// differently named keys would let them drift apart silently.
    enum InfoKey {
        static let capabilityManifest = "DefAIkeCapabilityManifestID"
        static let verdictCopyCatalog = "DefAIkeVerdictCopyCatalogID"
        static let appGroup = "DefAIkeAppGroupID"
    }

    /// The identifiers the running extension records, or the ones it does not.
    ///
    /// Reads only. It creates no identifier, substitutes nothing, and treats an absent or
    /// noncanonical value as absent rather than repairing it.
    static func installedIdentifiers(
        bundle: Bundle = .main
    ) -> Result<InstalledIdentifiers, UnprovisionedExtensionRelease> {
        var gaps: [UnprovisionedExtensionReleaseInput] = []

        let manifest = ArtifactID(string(bundle, InfoKey.capabilityManifest) ?? "")
        if manifest == nil { gaps.append(.capabilityManifestIdentifier) }

        let catalog = ArtifactID(string(bundle, InfoKey.verdictCopyCatalog) ?? "")
        if catalog == nil { gaps.append(.verdictCopyCatalogIdentifier) }

        // A build setting supplies this one, so an empty value means the setting was never
        // given a value rather than that the key is missing.
        let group = string(bundle, InfoKey.appGroup).flatMap { $0.isEmpty ? nil : $0 }
        if group == nil { gaps.append(.appGroupIdentifier) }

        guard let manifest, let catalog, let group, gaps.isEmpty else {
            return .failure(UnprovisionedExtensionRelease(inputs: gaps))
        }
        return .success(
            InstalledIdentifiers(
                capabilityManifest: manifest,
                verdictCopyCatalog: catalog,
                appGroup: group
            )
        )
    }

    /// The identifier half of the provisioning, read from the installed extension.
    struct InstalledIdentifiers: Hashable, Sendable {
        let capabilityManifest: ArtifactID
        let verdictCopyCatalog: ArtifactID
        let appGroup: String
    }

    private static func string(_ bundle: Bundle, _ key: String) -> String? {
        bundle.object(forInfoDictionaryKey: key) as? String
    }
}

// MARK: - The store that is not there

/// A `PolicyArtifactReading` for an extension with no installed signed artifact store.
///
/// Every member reports `ReleaseArtifactError.storeUnavailable`, which is the port's own
/// vocabulary for exactly this condition. It is not a stub standing in for a reader: no path
/// here returns an artifact value, so no policy, budget, deadline, protection level, or
/// allowlist entry can enter this build through it.
///
/// Its effect is the correct one. `ShareExtensionPreflight` fails at its artifact step, no
/// `ShareExtensionAdmission` is constructed, and the staging graph downstream of it is
/// unreachable rather than running against invented values.
///
/// Deliberately a separate type from the main application's equivalent rather than a shared
/// one: the two shipping executables have no source in common, and the module that ships in
/// both — `DefAIkeSharedTransfer` — must not gain a nonshipping reader.
///
/// Replacing it is `UnprovisionedExtensionReleaseInput.policyArtifactStore`: a reader over the
/// embedded signed artifact set, verified against the Bundle Verification Policy.
struct UnprovisionedExtensionPolicyStore: PolicyArtifactReading {

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
