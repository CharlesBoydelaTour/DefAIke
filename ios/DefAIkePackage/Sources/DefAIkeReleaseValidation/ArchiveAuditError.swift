import DefAIkeDomain

// Why an archive-audit ingestion cannot be trusted, what the audit is still owed, and what a
// clean audit would not establish even if every artifact arrived.
//
// The same three-vocabulary split the parity, resource, and accessibility-matrix runners use,
// for the same reason: the actions that close the three are different, and a release audit that
// conflates them waits for the wrong thing.
//
//   * ``ArchiveAuditBindingError`` — *the ingested report disagrees with itself or with this
//     module*. The document was produced by a different tool, its schema version is one this
//     revision cannot fully interpret, it claims an outcome its own findings contradict, it
//     names a gate this task does not produce evidence for, or its Software Bill of Materials
//     is not the format and version this module reads. A reconciliation finding: nothing was
//     audited and nothing should be believed.
//   * ``UnprovisionedArchiveAuditInput`` — *a release-controlled input this repository does not
//     carry*. An approved notice artifact, an approved binary-digest baseline, a first-party
//     privacy manifest, a produced Model Bundle artifact tree, a distribution archive.
//     Closing one is a release-artifact or packaging change.
//   * ``UnobservableArchiveAuditEvidence`` — *something the available bytes cannot establish*,
//     so a measurement either cannot be taken or does not establish what its name suggests.
//     Closing one needs different bytes, not more provisioning.
//
// The third vocabulary carries this task's central limits, and they are not small. The archives
// this audit can read are Debug simulator builds: they carry no Model Bundle, no release build
// identity, and no distribution code signature, and the one binary artifact they embed cannot
// be re-verified against the checksum its vendor published because SwiftPM does not retain the
// downloaded archive. Each of those is a value here, each fails its gate closed, and each is
// reported rather than narrowed away.
//
// No vocabulary here has a case meaning "proceed anyway", "assume", "approximate", "skip", or
// "warn". Requirement 14.6 makes an unapproved dependency, an unapproved binary digest, a
// notice gap, a corpus artifact, and a prohibited capability *failing* release-record inputs,
// and a reporting surface that could downgrade one would be how that clause stops holding.

// MARK: - The five failing input classes

/// One class of failing release-record input Requirement 14.6 enumerates.
///
/// The raw values are the class identifiers `ios/Scripts/audit-release-archives.py` tags every
/// finding with, so an ingested report decodes without a translation table in between. That
/// matters more than it looks: a translation table is a second place the five classes are
/// written down, and a class that existed in one place and not the other would be a finding
/// nobody could route to a gate.
public enum ArchiveAuditFailingInputClass: String, Hashable, Sendable, CaseIterable, Codable,
    CustomStringConvertible
{
    /// A package resolved into a build graph that no approved entry names, or one resolved at a
    /// version or revision other than the approved one (Requirement 14.6).
    case unapprovedDependency = "unapproved-dependency"

    /// A shipped binary artifact whose digest does not match its approved value, or one that
    /// carries no checksummed declaration at all (Requirements 14.5, 14.6, 10.5).
    case unapprovedBinaryDigest = "unapproved-binary-digest"

    /// A required attribution or licence notice absent from a distributed bundle
    /// (Requirement 14.5).
    case noticeGap = "notice-gap"

    /// Non-distributable evaluation-corpus content present in a bundle (Requirement 14.6).
    case corpusArtifact = "corpus-artifact"

    /// A capability the Version 1 release forbids, present in a shipped archive: analytics,
    /// advertising, account, custom diagnostic, third-party crash reporting, remote model
    /// update, result export, or a provenance validator in a pixel-only build
    /// (Requirements 9.10 through 9.13, 9.18, 10.19 through 10.21).
    case prohibitedCapability = "prohibited-capability"

    /// The release-readiness gate this class fails.
    ///
    /// Every one of the four is an existing `ReleaseGate` case rather than a new identifier, so
    /// task 14.8 joins this evidence into the record it already assembles instead of learning a
    /// fifth vocabulary. Written without a `default`, so a new class forces a routing decision.
    public var gate: ReleaseGate {
        switch self {
        case .unapprovedDependency, .unapprovedBinaryDigest: .archiveAudit
        case .noticeGap: .dependencyNotices
        case .corpusArtifact: .corpusExclusion
        case .prohibitedCapability: .privacyAudit
        }
    }

    /// Every gate this task produces evidence for, derived rather than listed.
    public static var producedGates: Set<ReleaseGate> {
        Set(allCases.map(\.gate))
    }

    public var description: String { rawValue }
}

// MARK: - Reconciliation findings

/// Why an ingested archive-audit report cannot be bound into release evidence.
public enum ArchiveAuditBindingError: Error, Equatable, Sendable, CustomStringConvertible {

    /// The report was produced by something other than this task's audit script.
    ///
    /// Checked rather than assumed because the report is a file on disk. A document produced by
    /// a different tool could carry the same field names and different semantics, and a gate
    /// outcome derived from it would be a claim about an audit that never ran.
    case unexpectedProducer(String)

    /// The report declares a schema version this revision cannot fully interpret.
    ///
    /// Refused rather than partially read, for the reason every artifact schema in this project
    /// refuses one: ignoring a field you do not understand is how a required semantic becomes
    /// optional.
    case unsupportedSchemaVersion(Int)

    /// The report names a gate this task produces no evidence for.
    ///
    /// A report that carried `device-allowlist` would be claiming an authority this audit does
    /// not have, and silently dropping the entry would let it reach a release record through a
    /// path nobody reviewed.
    case gateNotProducedByThisAudit(String)

    /// The report omits a gate this task must produce evidence for.
    ///
    /// Missing is not pass. A record assembled from a report with no `corpus-exclusion` entry
    /// would have no result for that gate, and `ReleaseGateRecord` would then have to be
    /// constructed with `notExecuted` — which is honest — but only if the omission is *seen*.
    case gateMissingFromReport(ReleaseGate)

    /// The report's stated outcome for one gate disagrees with the outcome its own findings and
    /// owed inputs imply.
    ///
    /// The load-bearing check. ``ArchiveAuditReport/outcome(for:)`` re-derives every outcome
    /// from the findings rather than trusting the stated field, and this error is what a
    /// disagreement produces. A report that said `passed` beside a finding would otherwise be a
    /// passing gate.
    case statedOutcomeContradictsFindings(
        gate: ReleaseGate,
        stated: GateOutcome,
        derived: GateOutcome
    )

    /// A finding carries a class identifier that is not one of the five.
    case unknownFailingInputClass(String)

    /// An owed-input identifier is not one of the enumerated release-controlled inputs.
    case unknownUnprovisionedInput(String)

    /// The report claims archives were inspected but names no inspected bundle.
    ///
    /// An audit that examined nothing reports every gate as passing, because it found nothing.
    /// This is what makes that unrepresentable.
    case archivesClaimedInspectedWithNoBundleInventory

    /// The Software Bill of Materials is not the format this module reads.
    case unsupportedBillOfMaterialsFormat(format: String, specVersion: String)

    /// The Software Bill of Materials lists no component.
    ///
    /// A bill of materials with no entries is not a small bill of materials.
    case billOfMaterialsEmpty

    /// A bill of materials component names a package the report did not reconcile.
    case billOfMaterialsComponentNotReconciled(String)

    public var description: String {
        switch self {
        case let .unexpectedProducer(producer):
            return "the report was produced by \(producer), not by this task's audit script"
        case let .unsupportedSchemaVersion(version):
            return "report schema version \(version) is not interpretable by this revision"
        case let .gateNotProducedByThisAudit(gate):
            return "the report names gate \(gate), which this audit produces no evidence for"
        case let .gateMissingFromReport(gate):
            return "the report carries no entry for gate \(gate.rawValue)"
        case let .statedOutcomeContradictsFindings(gate, stated, derived):
            return "gate \(gate.rawValue) states \(stated.rawValue) and its findings imply "
                + derived.rawValue
        case let .unknownFailingInputClass(identifier):
            return "\(identifier) is not one of the five failing input classes"
        case let .unknownUnprovisionedInput(identifier):
            return "\(identifier) is not an enumerated release-controlled archive-audit input"
        case .archivesClaimedInspectedWithNoBundleInventory:
            return "the report claims archives were inspected and inventories no bundle"
        case let .unsupportedBillOfMaterialsFormat(format, specVersion):
            return "the bill of materials is \(format) \(specVersion), and this module reads "
                + "\(SoftwareBillOfMaterials.supportedFormat) "
                + SoftwareBillOfMaterials.supportedSpecificationVersion
        case .billOfMaterialsEmpty:
            return "the bill of materials lists no component"
        case let .billOfMaterialsComponentNotReconciled(name):
            return "bill-of-materials component \(name) was not reconciled by the report"
        }
    }
}

// MARK: - Release-controlled inputs this repository does not carry

/// One release-controlled input an archive audit needs and this repository does not have.
///
/// A closed, enumerable vocabulary, in the established style, with raw values disjoint from
/// every other gap vocabulary in this repository so a release audit can pool them without two
/// different gaps colliding on one identifier.
///
/// Closing a gap is a release-artifact or packaging change. It is not a change to this file, and
/// no case here is closable by writing code. In particular, none is closable by *this* module
/// writing the artifact: a notice is approved prose, a digest baseline is an approval, and a
/// privacy manifest is a declaration a release makes about itself.
public enum UnprovisionedArchiveAuditInput: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    /// No approved attribution or licence notice artifact exists for any subject.
    ///
    /// Requirement 14.5 requires the notices for the Lowq checkpoint and every bundled
    /// dependency to be included in each distributed application and Model Bundle. Neither
    /// archive contains a notice file of any kind, and the upstream licence files the resolved
    /// checkouts carry — `LICENSE-MIT` and `LICENSE-APACHE` for the validator, `LICENSE.txt`
    /// and `NOTICE.txt` for the three Apple packages — are inputs to a notice rather than one.
    /// Task 14.5's ``ApprovedBundleNoticeSet`` models the Model Bundle's half and states in its
    /// own documentation that the *set's completeness against the archive* is this task's; what
    /// is missing is the approved documents themselves.
    case approvedApplicationNoticeArtifacts = "approved-application-notice-artifacts"

    /// No release owner has approved the shipped binary artifact's digest baseline.
    ///
    /// The audit measures the extracted `C2PAC` slices and compares them against a baseline it
    /// recorded, which catches a substituted or recompiled binary. It is a measurement, not an
    /// approval, and Requirement 14.6's "unapproved binary digest" clause needs the approval.
    case approvedBinaryArtifactDigestBaseline = "approved-binary-artifact-digest-baseline"

    /// Neither shipping target declares a privacy manifest.
    ///
    /// Requirement 9.18 makes the Release Process verify the absence of analytics collection,
    /// custom diagnostic transmission, third-party crash reporting, analytics identifiers, and
    /// advertising identifiers. A `PrivacyInfo.xcprivacy` is where iOS declares exactly that
    /// set, and no first-party one exists, so the absence is established by inspecting bytes
    /// and sources rather than by a platform declaration. The five embedded third-party
    /// manifests were audited and none declares tracking.
    case firstPartyPrivacyManifest = "first-party-privacy-manifest"

    /// No produced Initial Model Bundle artifact tree exists.
    ///
    /// Requirement 14.6 verifies corpus absence from the application *and the Model Bundle*,
    /// and Requirement 14.5 requires notices in both. The application half is measured; the
    /// Model Bundle half has no artifact. Task 14.5 built the creation and verification
    /// tooling, and no produced bundle is embedded in a build — which task 12.5 recorded
    /// independently as `bundled-model-absent`.
    case producedInitialModelBundleArtifactTree = "produced-initial-model-bundle-artifact-tree"

    /// No approved external-dependency allowlist artifact exists.
    ///
    /// The audit's allowlist is a table in a script, cross-checked against `Package.swift` and
    /// the tracked `Package.resolved`. That catches an unreviewed resolve, which is the failure
    /// that happens; it is not a release-signed artifact, and Requirement 14.1 wants gate
    /// evidence to name a source artifact identifier and version.
    case approvedExternalDependencyAllowlistArtifact =
        "approved-external-dependency-allowlist-artifact"

    /// No distribution archive exists to audit.
    ///
    /// Every archive claim available here is about a Debug simulator build. A distribution
    /// archive differs in the ways this audit most wants to read: it is signed, it is thinned
    /// to device architectures, its Swift code is in the main executable rather than a
    /// `.debug.dylib`, and it is the artifact App Review receives.
    case distributionArchive = "distribution-archive"

    public var description: String { rawValue }
}

/// The complete set of release-controlled inputs one archive audit does not have.
public struct UnprovisionedArchiveAudit: Error, Hashable, Sendable {
    public let inputs: [UnprovisionedArchiveAuditInput]

    public init(inputs: [UnprovisionedArchiveAuditInput]) {
        self.inputs = inputs
    }
}

// MARK: - Evidence the available bytes cannot produce

/// Something an archive audit would need that the available artifacts do not expose.
///
/// A separate vocabulary from ``UnprovisionedArchiveAuditInput`` because the two are closed by
/// different work. A missing notice arrives when a release approves one; the fact that SwiftPM
/// does not retain a downloaded xcframework zip does not, because there is no artifact to
/// approve — the acquisition would have to be re-run and recorded differently.
///
/// Nothing here is a defect this module fixes. Each is reported.
public enum UnobservableArchiveAuditEvidence: String, Hashable, Sendable, CaseIterable,
    CustomStringConvertible
{
    /// The vendor-published xcframework checksum cannot be recomputed from a build tree.
    ///
    /// `c2pa-swift`'s manifest declares a SHA-256 for `C2PAC.xcframework.zip`, and SwiftPM
    /// verifies it at acquisition and then keeps only the extracted framework. So the audit can
    /// cross-check the *declared* value against an approved one and can measure the *extracted*
    /// slices, but it cannot re-derive the declared value. A matching slice digest establishes
    /// that these bytes are the bytes previously measured, not that they are the bytes the
    /// vendor published.
    case vendorArchiveChecksumNotRecomputableFromBuildTree =
        "vendor-archive-checksum-not-recomputable-from-build-tree"

    /// No Core ML artifact is inside either archive, so Requirement 10.1's positive claim is
    /// unestablishable from these bytes.
    ///
    /// Only the absence of a fetch path can be established, which the delegated audits do
    /// measure. The compiled model exists in the working tree under untracked `/data/` and its
    /// weight blob digests to exactly Requirement 10.4's value; that is a fact about the
    /// working tree, not about an archive.
    case bundledModelAbsentFromArchive = "bundled-model-absent-from-archive"

    /// The audited archives are Debug simulator builds, not distribution archives.
    ///
    /// Recorded beside every archive claim rather than once, because it narrows all of them:
    /// module code lives in `DefAIke.debug.dylib`, the slices are simulator slices, and no
    /// distribution signature exists.
    case auditedArchivesAreDebugSimulatorBuilds = "audited-archives-are-debug-simulator-builds"

    /// No code signature is verifiable in a simulator build.
    ///
    /// `CODE_SIGNING_ALLOWED=NO` is required to build these archives without a provisioning
    /// profile, so the audit cannot check that the shipped bundles are signed, that the Share
    /// Extension's signature matches the app's team, or that no unsigned payload was inserted.
    case codeSignatureNotVerifiableInSimulatorBuild =
        "code-signature-not-verifiable-in-simulator-build"

    /// No release build identity exists, so no archive claim can be bound to a release version.
    ///
    /// Both targets record `0`/`0.0.0`, which is why every first-party component in the bill of
    /// materials carries `0.0.0` as an observed value rather than an approved one, and why the
    /// document cannot be bound to a release the way Requirement 14.1 requires.
    case noReleaseBuildIdentityToBindTheBillOfMaterialsTo =
        "no-release-build-identity-to-bind-the-bill-of-materials-to"

    /// The corpus content check has no corpus to compare against in a clean checkout.
    ///
    /// `/data/` is untracked, so the content-digest half of corpus exclusion — the half with no
    /// false positives — runs only in a working tree that has downloaded the corpus. The path
    /// fragment and extension halves run everywhere and are weaker.
    case corpusAbsentFromCleanCheckout = "corpus-absent-from-clean-checkout"

    /// The provenance archive's network capability is suppressed by configuration, not absent.
    ///
    /// Not a violation, and deliberately carried here rather than as a finding. The reviewed
    /// validator statically contributes an HTTP client, an HTTP/2 implementation, a TLS
    /// implementation, a root-certificate store, an async runtime, and a compiled-in OCSP
    /// client. Tasks 12.3 and 12.5 measured and classified that as a Provenance Feasibility
    /// Gate input, and this module keeps that classification: the pixel-only composition's
    /// offline guarantee is absence from the shipped bytes, and the provenance composition's is
    /// runtime configuration. An archive audit cannot establish the second by reading bytes.
    case provenanceNetworkCapabilitySuppressedByConfiguration =
        "provenance-network-capability-suppressed-by-configuration"

    /// Symbol counts inside the vendor static archive are lower bounds.
    ///
    /// This toolchain cannot read the bitcode of hundreds of the archive's members, so the
    /// inventory the delegated audit produces establishes that the network stack is present
    /// rather than how much of it there is.
    case vendorStaticArchiveSymbolCountsAreLowerBounds =
        "vendor-static-archive-symbol-counts-are-lower-bounds"

    /// Whether this limit prevents a measurement from being taken at all.
    ///
    /// True for the five that remove a measurement — an absent model, an unrecomputable
    /// checksum, an unsigned build, no version to bind to, no corpus to compare against. False
    /// for the three that narrow what a measurement establishes without preventing it. Written
    /// without a `default`, so a new limit forces a decision about whether it blocks.
    public var blocksEvidence: Bool {
        switch self {
        case .vendorArchiveChecksumNotRecomputableFromBuildTree,
             .bundledModelAbsentFromArchive,
             .codeSignatureNotVerifiableInSimulatorBuild,
             .noReleaseBuildIdentityToBindTheBillOfMaterialsTo,
             .corpusAbsentFromCleanCheckout:
            true
        case .auditedArchivesAreDebugSimulatorBuilds,
             .provenanceNetworkCapabilitySuppressedByConfiguration,
             .vendorStaticArchiveSymbolCountsAreLowerBounds:
            false
        }
    }

    public var description: String { rawValue }
}
